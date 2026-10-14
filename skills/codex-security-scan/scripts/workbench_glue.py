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
  - 상속된 `CODEX_SECURITY_GIT` 도 제거한다(상류 SDK 도 사용자 값을 쓰지 않는다).
  - `--claim-token` 은 어떤 명령에도 노출하지 않는다(R4, CLI 등록 스캔 경로).

입력: bootstrap.py 가 출력한 JSON(`--bootstrap <파일|->`)에서 pluginRoot/python/
stateDir/scanDir/repoRoot 를 읽는다.

성공/실패 모두 stdout 에 JSON 1건을 내고, 프로세스 종료코드로 성공 여부를 알린다
(0=ok, 1=실패). complete 의 게이트 실패는 종료코드 0 + `{"ok": false, ...}` 로
"명령은 정상 수행됐고 게이트가 막았다"를 구분한다.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

STATE_DIR_ENV = "CODEX_SECURITY_STATE_DIR"
# CODEX_SECURITY_GIT: npm 0.1.32부터 플러그인 스크립트는 이 값이 있으면 그 Git 을 쓰고, 없으면
# PATH 에서 대상 저장소 밖의 Git 을 찾는다. 상류 SDK 는 사용자 값을 버리고 자기가 고른 Git 으로
# 덮어쓴다(runtime.ts environmentWithGit). 우리는 고르지 않으므로 상속값을 지워 PATH 탐색에 맡긴다.
STRIP_ENV = ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_SECURITY_GIT")
FEEDBACK_RELATIVE = Path("artifacts") / "01_context" / "false_positive_feedback.json"
MODES = ("standard", "diff", "deep")


class GlueError(Exception):
    """글루 계층 실패.

    `kind` 는 실패의 성격을 구분한다 — 호출자가 사용자에게 줄 안내가 다르다.
      "gate"  : 상류 명령이 정상 실행됐고 스스로 거부했다(전제 불충족).
      "infra" : 상류 명령을 실행조차 못했거나 출력이 계약을 벗어났다.
    둘을 뭉치면 프로세스 기동 실패에 "전제를 확인하세요" 안내가 붙어
    사용자가 없는 문제를 쫓게 된다.
    """

    def __init__(self, message: str, detail: str | None = None, kind: str = "gate"):
        super().__init__(message)
        self.detail = detail
        self.kind = kind


def emit(payload: dict, ok: bool) -> int:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if ok else 1


def load_bootstrap(path: str) -> dict:
    raw = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as error:
        raise GlueError(f"bootstrap JSON 파싱 실패: {path} ({error})", kind="infra") from error
    if not isinstance(data, dict) or not data.get("ok"):
        raise GlueError("bootstrap JSON 이 성공 상태가 아닙니다(ok!=true).", kind="infra")
    for key in ("pluginRoot", "stateDir", "repoRoot"):
        if not isinstance(data.get(key), str) or not data[key]:
            raise GlueError(f"bootstrap JSON 에 {key} 가 없습니다.", kind="infra")
        # 이 게이트는 **분류의 전제가 아니다.** 분류(_failure_kind)는 실제 개행만
        # 보므로 경로 문자에 흔들리지 않는다. 여기서 막는 이유는 좁다:
        #   - `\x00` 은 argv 에 들어가면 subprocess 가 ValueError 를 던지고 그것은
        #     run_workbench 의 except 에 잡히지 않아 트레이스백으로 새어 나간다.
        #   - `\n`·`\r` 은 상류 오류 메시지를 여러 줄로 만들어 `reason` 추출
        #     (detail.splitlines()[-1])이 사유를 절단한다.
        # 사용자가 고칠 수 있는 입력 문제이므로 gate 다.
        if any(ch in data[key] for ch in "\n\r\x00"):
            raise GlueError(
                f"bootstrap JSON 의 {key} 에 개행·NUL 이 있습니다: {data[key]!r}. "
                "경로에 그런 문자가 있으면 상류 오류 메시지가 여러 줄이 되어 실패 원인을 "
                "가릴 수 있습니다 — 경로를 바꾼 뒤 다시 실행하세요."
            )
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
        raise GlueError("내부 오류: --claim-token 은 전달할 수 없습니다(R4).", kind="infra")
    script = str(Path(boot["pluginRoot"]) / "scripts" / "workbench_db.py")
    # bootstrap 은 매니페스트 존재만 검사하고 이 스크립트의 실존은 보지 않는다.
    # 없으면 인터프리터는 정상 기동한 뒤 rc=2 로 끝나므로 아래 비-0 분기로 흘러
    # "게이트 거부"로 오분류된다 — 여기서 infra 로 못 박는다.
    if not Path(script).is_file():
        raise GlueError(
            f"플러그인 사본에 workbench_db.py 가 없습니다: {script}", kind="infra"
        )
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
        raise GlueError(f"workbench_db.py 실행 실패: {error}", kind="infra") from error


# 상류의 출력 규약(실물 workbench_db.py 를 서브커맨드별로 실행해 확립):
#   거부 = raise SystemExit("한 줄 문구") → rc=1, stdout 공백, stderr 1줄 평문
#   성공 = stdout 에 JSON 1건, rc=0
# 즉 stdout 은 **성공에만** 쓰인다. 초기 구현은 "stdout 이 있으면 상류가 판단해
# 거부한 것"이라고 봤는데 정반대였다 — 비-0 인데 stdout 이 있으면 성공 페이로드를
# 쓰다 죽은 것이므로 infra 다.
#
# 그래서 1차 판정은 어휘가 아니라 **형상**으로 한다. 서드파티 stderr 문자열
# 매칭만으로는 끝이 없다 — 최상위 SyntaxError 는 CPython 이 Traceback 헤더를
# 찍지 않고(실측), 시그널 사망과 무출력 종료는 어떤 문구도 남기지 않는다.
# 마커 문자열 목록은 두지 않는다. 화이트리스트 순서상 도달 불가한 데드 코드가
# 되기 때문이다(실측: 모든 후보 마커가 앞선 rc·줄수 규칙에서 이미 걸린다 —
# `can't open file`·`invalid choice` 는 rc=2, `Traceback`·`ModuleNotFoundError`·
# `SyntaxError`·`database is locked` 는 4줄 stderr). 남는 것은 false-infra 위험뿐이다:
# 정상 거부 문장이 우연히 마커를 포함하면 뒤집힌다. `Permission denied` 를 뺀 것과
# 같은 이유이므로 목록 자체를 없앤다.
#
# 그 대가로 판별하지 못하는 것: 상류가 `ContractError` 를 `SystemExit(str(exc))` 로
# 재포장하는 사이트(플랫폼 비호환 등)는 rc=1 + 1줄 stderr 라 gate 로 분류된다.
# 형상이 정상 거부와 같아 규칙으로는 가를 수 없다 — gate 안내가 "상류가 남긴 사유를
# 먼저 읽으세요"로 시작하는 이유다.


def _failure_kind(completed: subprocess.CompletedProcess[str]) -> str:
    """비-0 종료를 gate(상류가 거부) / infra(상류가 깨짐)로 분류한다.

    **화이트리스트**다 — 거부의 형상을 정의하고 벗어나는 것은 전부 infra 로 본다.
    gate 를 폴백으로 두면 모델링하지 않은 실패가 전부 "전제 불충족"으로 새어
    사용자가 없는 문제를 쫓는다(실측: rc=1 인터프리터 래퍼 파손, rc=120 stdout
    플러시 실패가 둘 다 gate 로 샜다).

    상류 거부의 형상(실물 사본 전수 확인):
      - rc=1 — `raise SystemExit("한 줄")` 뿐이다. 리터럴 `SystemExit(2)` 는 없고,
        rc=2 는 argparse 사용법 오류, rc<0 은 시그널, rc=120 은 stdout 플러시 실패다.
      - stdout 공백 — stdout 은 성공 페이로드에만 쓴다(쓰기 지점 전부 result 확정 후).
      - stderr 정확히 1줄 — SystemExit 335건·ContractError 150건 중 개행을 담은
        메시지가 0건이다. 여러 줄이면 래퍼나 인터프리터가 낸 것이다.

    판별 불가로 남는 것: 상류가 `sys.exit("한 줄")` 로 깨지면 정상 거부와 형상이
    완전히 같다. 어떤 규칙으로도 가를 수 없어 문서화 대상이다.
    """
    if completed.returncode != 1:
        return "infra"
    out = (completed.stdout or "").strip()
    err = (completed.stderr or "").strip()
    if out:
        # 비-0 인데 stdout 이 있다 = 성공 페이로드를 쓰다 죽었다.
        return "infra"
    if not err:
        # 거부는 항상 사유를 남긴다. 말없이 비-0 이면 거부가 아니다.
        return "infra"
    # `splitlines()` 를 쓰면 안 된다 — 그것은 `\x0b \x0c \x1c \x1d \x1e \x85`
    # `U+2028 U+2029` 에서도 쪼갠다. 상류는 거부 메시지에 경로를 보간하므로
    # (workbench_db.py:270), 그 문자가 든 경로면 정상 거부가 여러 줄로 세어져
    # infra 로 뒤집힌다 — 8문자 전수 확인했다. 진입 시점에 문자를 막는 접근은
    # 필연적으로 불완전하다(막을 목록을 늘려도 다음 문자가 남는다). 분류가
    # **실제 개행만** 보게 하는 것이 옳은 층이다.
    if "\n" in err or "\r" in err:
        return "infra"
    return "gate"


def workbench_json(boot: dict, args: list[str]) -> dict:
    completed = run_workbench(boot, args)
    if completed.returncode != 0:
        raise GlueError(
            f"workbench {args[0]} 실패(exit {completed.returncode})",
            detail=(completed.stderr or completed.stdout).strip(),
            kind=_failure_kind(completed),
        )
    text = completed.stdout.strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise GlueError(
            f"workbench {args[0]} 가 JSON 이 아닌 출력을 냄", detail=str(error), kind="infra"
        ) from error


# --------------------------------------------------------------------------
# 서브커맨드
# --------------------------------------------------------------------------
def cmd_register(boot: dict, args: argparse.Namespace) -> int:
    if args.mode == "deep":
        # 상류는 레시피 mode=deep 스캔을 종결하기 전에 공식 deep 코디네이터가 만드는 deep_scan_runs
        # 행(succeeded + manifest)을 요구한다(deep_scan_workbench.py, npm 0.1.29~0.2.0). deep-lite 는 그
        # 행을 만들지 않으므로 이 모드로 등록하면 complete 가 항상 거부되고 행은 running 으로 남는다.
        raise GlueError(
            "register --mode deep 은 쓰지 않습니다. deep-lite 는 표준 모드(--mode standard, 기본값)로 "
            "등록합니다 — 상류는 mode=deep 스캔을 공식 deep 코디네이터의 실행 기록 없이 종결하지 않습니다."
        )
    paths = args.paths or []
    recipe = {
        "repository": boot["repoRoot"],
        "mode": args.mode,
        "config": {},
        "target": {"kind": "repository", "paths": paths},
    }
    if args.mode == "diff":
        # 상류 레시피의 mode 는 standard·deep 만 받는다(상류 최초 태그부터. 0.1.25·0.1.32 실측:
        # "Scan launch recipe mode must be standard or deep."). diff 는 mode 가 아니라
        # target.kind(refs/working_tree)로 표현하고, 상류가 거기서 mode=diff 를 유도한다.
        if not args.diff_target or not args.base:
            raise GlueError("register --mode diff 에는 --diff-target 과 --base 가 필요합니다.")
        if paths:
            raise GlueError("diff 스캔은 --paths 를 받지 않습니다(상류: scoped 레시피만 경로를 가진다).")
        recipe["mode"] = "standard"
        recipe["target"] = {
            "kind": args.diff_target,
            "paths": [],
            "base": args.base,
            "head": args.head or "HEAD",
        }
    elif args.diff_target or args.base or args.head:
        raise GlueError("--diff-target·--base·--head 는 --mode diff 에서만 씁니다.")
    scan_dir = Path(boot.get("scanDir") or "")
    if not scan_dir or not scan_dir.is_dir():
        # bootstrap 출력 계약 위반이다 — load_bootstrap 의 키 누락과 같은 등급.
        raise GlueError("bootstrap 의 scanDir 가 없거나 디렉터리가 아닙니다.", kind="infra")
    existing = [p for p in os.listdir(str(scan_dir))]
    if existing:
        raise GlueError(
            f"scan-dir 가 비어 있지 않습니다({len(existing)}개 항목): {scan_dir}. "
            "register 는 스캔 작업 전에, 빈 디렉터리에서 호출해야 합니다."
        )
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
        # 상류 응답이 계약을 벗어났다(스캔 전제 문제가 아니다).
        raise GlueError(
            "register-cli-scan 이 scanId 를 반환하지 않았습니다.",
            detail=json.dumps(result),
            kind="infra",
        )
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
    diff_target = contract.get("diffTarget")
    if isinstance(diff_target, dict):
        fields["diffTarget"] = diff_snapshot_fields(diff_target)
    return emit({"ok": True, "contract": fields, "raw": scan}, True)


def committed_diff_snapshot_digest(kind: str, base_revision: str, head_revision: str) -> str:
    """상류 `workbench_target.committed_diff_snapshot_digest()`와 같은 식.

    출처: 태그 npm-v0.1.32 = 커밋 7c19cce7224af29628cd10c218444d5c0e8fdd1c 의
    `plugins/codex-security/scripts/workbench_target.py`(상류 8c78e655에서 도입). 그 전에도
    `workbench_saved_results.py`가 같은 식을 인라인으로 썼다. `repro-u7` I17이 상류 봉인 결과와 대조한다.
    태그 npm-v0.2.0 = 커밋 4949af70fcfadff154f6e8fdf100faa5bf2f8169 에서도 이 함수는 같다.
    """
    digest = hashlib.sha256(
        f"codex-security-diff/v1\0{kind}\0{base_revision}\0{head_revision}".encode()
    ).hexdigest()
    return f"codex-security-snapshot/v1:sha256:{digest}"


def diff_snapshot_fields(diff_target: dict) -> dict:
    """get-scan 의 diffTarget 을 draft 의 `scan.target` 좌표로 옮긴다.

    snapshotDigest 는 상류 `diff_snapshot_digest()` 규칙을 따른다 — working_tree 는 등록 시점
    contentDigest, commit·range 는 base/head 에서 유도한 값이다.
    """
    kind = diff_target.get("kind")
    base = diff_target.get("baseRevision")
    head = diff_target.get("headRevision")
    fields = {"kind": kind, "baseRevision": base, "headRevision": head}
    if kind == "working_tree":
        fields["snapshotDigest"] = diff_target.get("contentDigest")
    elif kind in ("commit", "range") and isinstance(base, str) and isinstance(head, str):
        fields["snapshotDigest"] = committed_diff_snapshot_digest(kind, base, head)
    else:
        fields["snapshotDigest"] = None
    return fields


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


def _split_lines(text: str) -> list[str]:
    """상류 메시지를 **실제 줄**로만 자른다.

    `str.splitlines()` 를 쓰면 안 된다 — `\x0b \x0c \x1c \x1d \x1e \x85`
    U+2028 U+2029 까지 줄 구분자로 취급하므로, 상류가 저장소에서 온 문자열(파일
    경로·설정 값)을 메시지에 보간하면 저장소가 줄 나누기를 통제하게 된다. 실측:
    `detail = "not a readable local directory: /tmp/a\x0bsrc/app.py"` 에서
    `splitlines()[-1]` 은 `"src/app.py"` 로 **사유 전체를 절단**하고,
    `_extract_changed_files` 는 **존재하지 않는 워킹트리 변경을 날조**한다.
    `reason` 은 SKILL.md 가 에이전트에게 먼저 읽으라고 지시하는 단 하나의 필드다.
    """
    return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


def _extract_changed_files(text: str) -> list[str]:
    files: list[str] = []
    for line in _split_lines(text):
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
    _kind = _failure_kind(completed)
    return emit(
        {
            "ok": False,
            # complete 는 게이트 실패를 예외가 아니라 구조화 결과로 돌려주므로
            # GlueError 를 타지 않는다. failureKind 를 여기서도 실어야 SKILL.md 의
            # R6 3선택지 분기가 "게이트가 막았다"와 "상류가 깨졌다"를 가를 수 있다.
            "failureKind": _kind,
            # **분류마다 다른 안내다.** `cmd_recover` 가 `error.kind` 로 힌트를
            # 분기하는 것과 같은 이유다 — 두 분류에 같은 문장을 실으면 프로세스
            # 기동 실패에 "변경을 되돌리세요"가 붙어 사용자가 없는 문제를 쫓는다.
            # 문안은 SKILL.md R6 의 두 항목과 정합해야 한다: infra 는 3선택지를
            # 제시하지 않고 changedFiles 를 신뢰하지 않으며, gate 는 3선택지를
            # 적용한다. (npm 배포본에는 `require_unchanged_target` 이 없어 gate
            # 분류가 실제 워킹트리 게이트가 아닐 수 있다 — 그래서 gate 안내도
            # reason/detail 을 먼저 읽으라고 말한다. R6 에도 명기했다.)
            "hint": (
                (
                    "상류 complete-scan 을 계약대로 완료하지 못했습니다 — 워킹트리 "
                    "게이트 문제가 아닙니다. 3선택지를 제시하지 마세요. 플러그인 사본, "
                    "Python 실행 경로, 상태 DB 잠금·타임아웃을 점검하세요. 이 분류에서는 "
                    "changedFiles 를 신뢰하지 마세요(트레이스백의 경로 줄이 섞입니다)."
                )
                if _kind == "infra"
                else (
                    "상류가 남긴 reason/detail 을 먼저 읽고, R6 의 3선택지(변경 되돌린 뒤 "
                    "재시도 / fail 기록 / 보류)를 적용하세요. 스캔 행은 running 으로 "
                    "남습니다 — 자동 실패 처리 금지. npm 배포본에는 워킹트리 불변 게이트가 "
                    "없어 changedFiles 가 비어 있을 수 있으니, 그때는 reason 이 지목하는 "
                    "전제를 확인하세요."
                )
            ),
            "reason": _split_lines(detail)[-1] if detail else "complete-scan 실패",
            "changedFiles": _extract_changed_files(detail),
            "detail": detail,
        },
        True,  # 명령 자체는 수행됨 — SKILL.md 가 분기하도록 exit 0
    )


def cmd_fail(boot: dict, args: argparse.Namespace) -> int:
    """명시적 실패 종결(KTD4 — 사용자가 선택할 때만)."""
    result = workbench_json(boot, ["fail-scan", "--scan-id", args.scan_id, "--message", args.message])
    return emit({"ok": True, "raw": result}, True)


def cmd_recover(boot: dict, args: argparse.Namespace) -> int:
    """recover-scan-results — 자동 종결된 스캔의 보존 체크포인트 재발행(P5-KTD8).

    상류 recover_scan_results 는 `status == "failed"` 이고 취소되지 않은 스캔만 받는다.
    워킹트리 게이트 실패로 행이 `running` 으로 남은 경우는 대상이 아니다 — 그때는
    `complete` 재시도·`fail`·보류 3선택지를 쓴다. 자동 종결(계약 오류 또는 deep 모드)로
    행이 `failed` 가 된 경우에만 이 명령이 의미가 있다.

    실패는 게이트 실패와 같은 형태로 구조화 반환한다(exit 0 + ok:false) — 비가역
    작업이 아니므로 사용자가 다른 선택지로 넘어갈 수 있어야 한다(계약 6 승계).
    """
    try:
        result = workbench_json(boot, ["recover-scan-results", "--scan-id", args.scan_id])
    except GlueError as error:
        detail = error.detail or str(error)
        if error.kind == "infra":
            # 상류가 거부한 것이 아니다 — 전제 안내를 붙이면 사용자가 엉뚱한 곳을 본다.
            hint = (
                "상류 recover-scan-results 를 계약대로 완료하지 못했습니다"
                "(스캔 전제 문제가 아닙니다). 플러그인 사본과 Python 실행 경로, "
                "그리고 상태 DB 잠금·타임아웃 여부를 확인하세요."
            )
        else:
            hint = (
                "상류가 남긴 사유(reason/detail)를 먼저 읽으세요 — 권한·디스크 같은 "
                "환경 문제도 이 경로로 옵니다. 스캔 전제 문제라면: 복구는 "
                "status=failed 이고 취소되지 않은 스캔만 대상이고, running 행은 "
                "complete 재시도·fail·보류 중에서 고르세요."
            )
        return emit(
            {
                "ok": False,
                "failureKind": error.kind,
                "reason": _split_lines(detail)[-1] if detail else "recover-scan-results 실패",
                "detail": detail,
                "hint": hint,
            },
            True,
        )
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
    p.add_argument("--diff-target", choices=("refs", "working_tree"), default=None,
                   help="--mode diff 의 대상 종류(refs=커밋·브랜치, working_tree=로컬 패치)")
    p.add_argument("--base", default=None, help="--mode diff 의 base 리비전")
    p.add_argument("--head", default=None,
                   help="--mode diff 의 head 리비전(기본 HEAD. working_tree 는 현재 HEAD 여야 한다)")
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

    p = sub.add_parser(
        "recover",
        help="recover-scan-results (자동 종결된 failed 스캔의 보존 체크포인트 재발행)",
    )
    p.add_argument("--scan-id", required=True)
    p.set_defaults(func=cmd_recover)

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
        # kind 를 버리면 recover 이외의 서브커맨드에서는 게이트/인프라 구분이
        # 소비자에게 닿지 않는다(register/contract/feedback/fail/check-running/
        # list-stale/close-stale). complete 는 게이트 실패를 예외가 아니라 구조화
        # 결과로 돌려주므로 여기가 아니라 cmd_complete 안에서 실어 준다.
        payload = {"ok": False, "failureKind": error.kind, "error": str(error)}
        if error.detail:
            payload["detail"] = error.detail
        return emit(payload, False)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
