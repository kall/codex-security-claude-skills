#!/usr/bin/env python3
"""워크벤치 수명주기 래퍼 (Phase 2).

codex-security 번들 플러그인의 `scripts/workbench_db.py` 를 감싸, Claude 로컬
스캔이 스캔 이력·false-positive 피드백을 공식 CLI(`npx codex-security scans …`,
`findings false-positive`)와 호환되게 등록·종결한다.

권위 순서(KTD1): register → get-scan(contract) → feedback → (스캔·draft) →
finalize → complete. 워킹트리 불변 게이트는 우회 불가하므로 finalize 를 complete
앞에 둔다(finalize-first). complete 실패는 예외가 아니라 구조화 결과로 돌려주어
SKILL.md 가 R6 분기(재시도/실패기록/보류)를 수행하게 한다.

호출 규약(runtime.ts runWorkbench 동일):
  - 항상 bootstrap 이 해석한 플러그인의 `scripts/workbench_db.py` 를 `python -I -B` 로 실행.
  - `CODEX_SECURITY_STATE_DIR` 를 정확한 대문자 이름으로 주입(R13).
  - `OPENAI_API_KEY` / `CODEX_API_KEY` 는 자식 환경에서 제거(무인증).
  - `--claim-token` 은 어떤 명령에도 노출하지 않는다(R4, CLI 등록 스캔 경로).

입력: bootstrap.py 가 출력한 JSON(`--bootstrap <파일|->`)에서 pluginRoot/python/
stateDir/scanDir/repoRoot 를 읽는다.

성공/실패 모두 stdout 에 JSON 1건을 내고, 프로세스 종료코드로 성공 여부를 알린다
(0=ok, 1=실패). complete 의 게이트 실패는 종료코드 0 + `{"ok": false, ...}` 로
"명령은 정상 수행됐고 게이트가 막았다"를 구분한다.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

STATE_DIR_ENV = "CODEX_SECURITY_STATE_DIR"
STRIP_ENV = ("OPENAI_API_KEY", "CODEX_API_KEY")
FEEDBACK_RELATIVE = Path("artifacts") / "01_context" / "false_positive_feedback.json"
MODES = ("standard", "diff", "deep")


class GlueError(Exception):
    def __init__(self, message: str, detail: str | None = None):
        super().__init__(message)
        self.detail = detail


def emit(payload: dict, ok: bool) -> int:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if ok else 1


def load_bootstrap(path: str) -> dict:
    raw = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as error:
        raise GlueError(f"bootstrap JSON 파싱 실패: {path} ({error})") from error
    if not isinstance(data, dict) or not data.get("ok"):
        raise GlueError("bootstrap JSON 이 성공 상태가 아닙니다(ok!=true).")
    for key in ("pluginRoot", "stateDir", "repoRoot"):
        if not isinstance(data.get(key), str) or not data[key]:
            raise GlueError(f"bootstrap JSON 에 {key} 가 없습니다.")
    return data


def child_env(state_dir: str) -> dict:
    env = {k: v for k, v in os.environ.items() if k.upper() not in STRIP_ENV}
    env[STATE_DIR_ENV] = state_dir
    # 플러그인 디렉터리에 __pycache__ 를 남기지 않는다(레포 읽기 전용 유지).
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def python_argv(boot: dict) -> list[str]:
    python = (boot.get("python") or {}).get("path") if isinstance(boot.get("python"), dict) else None
    if isinstance(python, str) and python:
        return [python]
    # bootstrap 이 --skip-python 등으로 인터프리터를 안 준 경우의 폴백.
    return [sys.executable or "python3"]


def run_workbench(boot: dict, args: list[str]) -> subprocess.CompletedProcess[str]:
    """workbench_db.py <args> 를 -I -B 로 실행. claim-token 은 호출자가 절대 넣지 않는다."""
    if any(a == "--claim-token" for a in args):
        raise GlueError("내부 오류: --claim-token 은 전달할 수 없습니다(R4).")
    script = str(Path(boot["pluginRoot"]) / "scripts" / "workbench_db.py")
    cmd = [*python_argv(boot), "-I", "-B", script, *args]
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            env=child_env(boot["stateDir"]),
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise GlueError(f"workbench_db.py 실행 실패: {error}") from error


def workbench_json(boot: dict, args: list[str]) -> dict:
    completed = run_workbench(boot, args)
    if completed.returncode != 0:
        raise GlueError(
            f"workbench {args[0]} 실패(exit {completed.returncode})",
            detail=(completed.stderr or completed.stdout).strip(),
        )
    text = completed.stdout.strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise GlueError(f"workbench {args[0]} 가 JSON 이 아닌 출력을 냄", detail=str(error)) from error


# --------------------------------------------------------------------------
# 서브커맨드
# --------------------------------------------------------------------------
def cmd_register(boot: dict, args: argparse.Namespace) -> int:
    scan_dir = Path(boot.get("scanDir") or "")
    if not scan_dir or not scan_dir.is_dir():
        raise GlueError("bootstrap 의 scanDir 가 없거나 디렉터리가 아닙니다.")
    existing = [p for p in os.listdir(str(scan_dir))]
    if existing:
        raise GlueError(
            f"scan-dir 가 비어 있지 않습니다({len(existing)}개 항목): {scan_dir}. "
            "register 는 스캔 작업 전에, 빈 디렉터리에서 호출해야 합니다."
        )
    paths = args.paths or []
    recipe = {
        "repository": boot["repoRoot"],
        "mode": args.mode,
        "config": {},
        "target": {"kind": "repository", "paths": paths},
    }
    result = workbench_json(
        boot,
        [
            "register-cli-scan",
            "--scan-dir", str(scan_dir),
            "--repository", boot["repoRoot"],
            "--recipe-json", json.dumps(recipe),
        ],
    )
    scan_id = result.get("scanId") or result.get("scan_id")
    target_id = result.get("targetId") or result.get("target_id")
    if not scan_id:
        raise GlueError("register-cli-scan 이 scanId 를 반환하지 않았습니다.", detail=json.dumps(result))
    return emit({"ok": True, "scanId": scan_id, "targetId": target_id, "raw": result}, True)


def cmd_contract(boot: dict, args: argparse.Namespace) -> int:
    """draft 가 사전 일치시켜야 하는 계약 필드만 추출해 돌려준다(R3)."""
    scan = workbench_json(boot, ["get-scan", "--scan-id", args.scan_id])
    node = scan.get("scan") if isinstance(scan.get("scan"), dict) else scan
    contract = node.get("contract") if isinstance(node.get("contract"), dict) else {}
    target_c = contract.get("target") if isinstance(contract.get("target"), dict) else {}
    scope_c = contract.get("scope") if isinstance(contract.get("scope"), dict) else {}
    fields = {
        "producer": {
            "name": "codex-security-plugin",
            # Phase 0 U3: producer.version 은 get-scan 이 아니라 플러그인 매니페스트에서 온다.
            # bootstrap 이 이미 읽어둔 pluginVersion 을 그대로 쓴다(하드코딩 금지).
            "version": boot.get("pluginVersion")
            or node.get("producerVersion")
            or (contract.get("producer") or {}).get("version"),
        },
        "target": {
            "allowedKinds": target_c.get("allowedKinds"),
            "targetId": target_c.get("targetId"),
            "displayName": target_c.get("displayName"),
            "revision": node.get("targetRevision"),
            "requiredSnapshotDigest": target_c.get("requiredSnapshotDigest"),
        },
        "scope": {
            "requiredIncludePaths": scope_c.get("requiredIncludePaths"),
            "requestedPath": scope_c.get("requestedPath"),
            "requiredExcludePaths": scope_c.get("requiredExcludePaths"),
        },
        "mode": node.get("mode"),
        "scanId": node.get("scanId") or args.scan_id,
    }
    return emit({"ok": True, "contract": fields, "raw": scan}, True)


def cmd_feedback(boot: dict, args: argparse.Namespace) -> int:
    """get-scan-feedback 결과를 O_EXCL·0600 으로 01_context 에 기록(R8)."""
    result = workbench_json(boot, ["get-scan-feedback", "--scan-id", args.scan_id])
    entries = result.get("falsePositives") or result.get("false_positives") or result.get("feedback") or []
    if not entries:
        return emit({"ok": True, "written": False, "count": 0}, True)
    scan_dir = Path(boot.get("scanDir") or "")
    dest = scan_dir / FEEDBACK_RELATIVE
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(str(dest.parent), 0o700)
    except OSError:
        pass
    payload = json.dumps(result, ensure_ascii=False, indent=2).encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    try:
        fd = os.open(str(dest), flags, 0o600)
    except FileExistsError as error:
        raise GlueError(f"피드백 파일이 이미 존재합니다(재작성 금지): {dest}") from error
    try:
        os.write(fd, payload)
    finally:
        os.close(fd)
    return emit({"ok": True, "written": True, "count": len(entries), "path": str(dest)}, True)


def _extract_changed_files(text: str) -> list[str]:
    files: list[str] = []
    for line in text.splitlines():
        stripped = line.strip().lstrip("-*• ").strip()
        # 게이트 메시지는 변경 파일을 목록으로 나열한다. 경로처럼 보이는 줄만 수집.
        if stripped and ("/" in stripped or stripped.endswith((".py", ".js", ".ts", ".md", ".json"))) \
                and " " not in stripped:
            files.append(stripped)
    return files


def cmd_complete(boot: dict, args: argparse.Namespace) -> int:
    """complete-scan. 게이트 실패는 exit 0 + {ok:false, reason, changedFiles} 로 반환(R6).

    플러그인 사본에 따라 워킹트리 변경의 처리가 다르다(실측):
      - 하드 게이트 사본: `require_unchanged_target` 이 있어 변경 시 complete 가 실패한다.
      - 경고 사본(npm 배포본): 변경을 `warnings` 로만 남기고 성공 종결한다.
    후자를 조용히 성공으로 보고하면 부정직하므로 `warnings` 를 최상위로 올려
    SKILL.md 가 최종 보고에 반드시 싣게 한다.
    """
    completed = run_workbench(boot, ["complete-scan", "--scan-id", args.scan_id])
    if completed.returncode == 0:
        try:
            raw = json.loads(completed.stdout.strip() or "{}")
        except json.JSONDecodeError:
            raw = {}
        # 경고 위치는 플러그인 사본에 따라 다르다: 실측상 complete-scan 응답의
        # `scan.warnings`(npm 배포본 scan_context). 최상위도 함께 본다.
        warnings: list = []
        if isinstance(raw, dict):
            for holder in (raw.get("scan"), raw):
                if isinstance(holder, dict) and isinstance(holder.get("warnings"), list):
                    warnings = holder["warnings"]
                    break
        return emit(
            {
                "ok": True,
                "status": raw.get("status", "complete"),
                "warnings": [w for w in warnings if isinstance(w, str)],
                "raw": raw,
            },
            True,
        )
    detail = (completed.stderr or completed.stdout).strip()
    return emit(
        {
            "ok": False,
            "reason": detail.splitlines()[-1] if detail else "complete-scan 실패",
            "changedFiles": _extract_changed_files(detail),
            "detail": detail,
        },
        True,  # 명령 자체는 수행됨 — SKILL.md 가 분기하도록 exit 0
    )


def cmd_fail(boot: dict, args: argparse.Namespace) -> int:
    """명시적 실패 종결(KTD4 — 사용자가 선택할 때만)."""
    result = workbench_json(boot, ["fail-scan", "--scan-id", args.scan_id, "--message", args.message])
    return emit({"ok": True, "raw": result}, True)


def _running_rows(boot: dict, repository: str | None) -> list[dict]:
    args = ["list-scans", "--status", "running"]
    if repository:
        args += ["--repository", repository]
    result = workbench_json(boot, args)
    rows = result.get("scans") if isinstance(result, dict) else result
    return [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []


def cmd_check_running(boot: dict, args: argparse.Namespace) -> int:
    rows = _running_rows(boot, boot["repoRoot"])
    return emit(
        {"ok": True, "running": [{"scanId": r.get("scanId") or r.get("id"),
                                   "startedAt": r.get("startedAt") or r.get("started_at"),
                                   "repository": r.get("repository")} for r in rows],
         "count": len(rows)},
        True,
    )


def cmd_list_stale(boot: dict, args: argparse.Namespace) -> int:
    """N시간 이상 running 인 행을 나열만 한다(상태 변경 없음, R7)."""
    from datetime import datetime, timezone

    rows = _running_rows(boot, args.repository)
    stale: list[dict] = []
    cutoff = args.hours * 3600
    now = datetime.now(timezone.utc).timestamp()
    for r in rows:
        started = r.get("startedAt") or r.get("started_at")
        age = None
        if isinstance(started, str):
            try:
                ts = datetime.fromisoformat(started.replace("Z", "+00:00")).timestamp()
                age = now - ts
            except ValueError:
                age = None
        if age is None or age >= cutoff:
            stale.append({"scanId": r.get("scanId") or r.get("id"), "startedAt": started,
                          "repository": r.get("repository"), "ageSeconds": age})
    return emit({"ok": True, "stale": stale, "count": len(stale),
                 "note": "close-stale <scanId> 로 명시적으로만 종결하세요."}, True)


def cmd_close_stale(boot: dict, args: argparse.Namespace) -> int:
    """명시된 scanId 만 fail-scan 으로 종결(R7)."""
    message = args.message or "stale running scan closed by workbench_glue close-stale"
    result = workbench_json(boot, ["fail-scan", "--scan-id", args.scan_id, "--message", message])
    return emit({"ok": True, "closed": args.scan_id, "raw": result}, True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap", required=True, help="bootstrap.py 출력 JSON 파일 경로(- 는 stdin)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("register", help="register-cli-scan (빈 scan-dir)")
    p.add_argument("--mode", choices=MODES, default="standard")
    p.add_argument("--paths", nargs="*", default=[], help="scoped-path 스캔의 대상 경로들")
    p.set_defaults(func=cmd_register)

    p = sub.add_parser("contract", help="get-scan → draft 반영 필드")
    p.add_argument("--scan-id", required=True)
    p.set_defaults(func=cmd_contract)

    p = sub.add_parser("feedback", help="get-scan-feedback → 01_context 기록")
    p.add_argument("--scan-id", required=True)
    p.set_defaults(func=cmd_feedback)

    p = sub.add_parser("complete", help="complete-scan (게이트 실패는 구조화 반환)")
    p.add_argument("--scan-id", required=True)
    p.set_defaults(func=cmd_complete)

    p = sub.add_parser("fail", help="fail-scan (사용자 명시 선택 시에만)")
    p.add_argument("--scan-id", required=True)
    p.add_argument("--message", required=True)
    p.set_defaults(func=cmd_fail)

    p = sub.add_parser("check-running", help="시작 시 같은 저장소 running 행 advisory")
    p.set_defaults(func=cmd_check_running)

    p = sub.add_parser("list-stale", help="N시간 이상 running 행 나열(변경 없음)")
    p.add_argument("--hours", type=float, default=6.0)
    p.add_argument("--repository", default=None)
    p.set_defaults(func=cmd_list_stale)

    p = sub.add_parser("close-stale", help="명시된 scanId 만 종결")
    p.add_argument("--scan-id", required=True)
    p.add_argument("--message", default=None)
    p.set_defaults(func=cmd_close_stale)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        boot = load_bootstrap(args.bootstrap)
        return args.func(boot, args)
    except GlueError as error:
        payload = {"ok": False, "error": str(error)}
        if error.detail:
            payload["detail"] = error.detail
        return emit(payload, False)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
