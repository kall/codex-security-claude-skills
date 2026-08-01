#!/usr/bin/env python3
"""커버리지 정산(R9)과 finding 경로 검사(R10) 게이트.

`bind-repo-scopes` 다음, `finalize_scan_contract.py` 직전에 실행한다(KTD7).
플러그인 finalizer가 강제하지 않는 두 가지 정직성 속성만 담당하며,
finalizer가 이미 검증하는 항목(스키마, scope 일치, receiptRefs 실존,
surface id 중복)은 중복 검사하지 않는다.

R9  커버리지 정산
    `in_scope_files.txt`(리뷰 대상 목록)와 `review_log.jsonl`(실제 리뷰 기록)을
    대조해, 리뷰 완료 파일이 목록에 미달하면 `coverage.json`의
    `completeness`를 `partial`로 강제하고 미완 파일을 `deferred`에 기록한다.
    `review_log.jsonl` 부재 자체가 정직성 위반이다 — 리뷰 기록 없는 스캔은
    complete를 주장할 수 없다.

R10 finding 경로 실존
    `findings.json`의 모든 `locations[].path`(및 있으면 `codeEvidence[].path`)를
    소스 루트 기준 realpath로 정규화해 루트 하위 실존 파일인지 검사한다.
    finalizer는 경로 *형태*만 보고 파일시스템에 접근하지 않으므로
    (Phase 0 U4 프로브 D 실증) 이 스크립트가 안전망이다.

종료 코드
    0  정산 성공(무변경 또는 정직한 하향 수정) + 모든 경로 유효
    1  정직성 위반 — 리뷰 로그 부재, 또는 유효하지 않은 finding 경로
    2  CLI 오사용(argparse)
    3  입력 오류 — 필수 산출물 부재, JSON/JSONL 파싱 실패

이 스크립트는 `--scan-dir` 하위의 `coverage.json` 외에는 아무것도 쓰지 않는다.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
from dataclasses import dataclass, field
from typing import Any

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_USAGE = 2
EXIT_INPUT_ERROR = 3

DISCOVERY_SUBDIR = os.path.join("artifacts", "02_discovery")
IN_SCOPE_BASENAME = "in_scope_files.txt"
REVIEW_LOG_BASENAME = "review_log.jsonl"

#: 정산이 생성/갱신하는 deferred 항목의 고정 id. 재실행 시 이 id를 갱신하므로
#: 리페어 루프에서 여러 번 돌려도 항목이 누적되지 않는다.
DEFERRED_ID = "unreviewed-in-scope-files"

#: `deferred[].paths`에 남기는 미리뷰 경로 최대 개수(그 이상은 reason에 총계로 표기).
MAX_DEFERRED_PATHS = 50

#: 이 outcome 은 "리뷰 완료"로 세지 않는다. 리뷰를 시도했다는 기록일 뿐이므로
#: 커버리지 주장의 근거가 될 수 없다.
NOT_REVIEWED_OUTCOMES = frozenset(
    {
        "aborted",
        "cancelled",
        "canceled",
        "deferred",
        "error",
        "failed",
        "failure",
        "incomplete",
        "not_reviewed",
        "pending",
        "skip",
        "skipped",
        "timeout",
        "unreviewed",
    }
)

MAX_REPORTED_LINES = 5


class ReconcileError(Exception):
    """사용자에게 그대로 보여줄 한국어 메시지와 종료 코드를 담은 오류."""

    def __init__(self, message: str, exit_code: int) -> None:
        super().__init__(message)
        self.message = message
        self.exit_code = exit_code


# --------------------------------------------------------------------------- #
# 경로 정규화
# --------------------------------------------------------------------------- #


def _canonical(raw: str, root_real: str) -> tuple[str | None, str]:
    """`raw`를 소스 루트 기준 POSIX 상대 경로로 정규화한다.

    반환값은 `(루트 하위 상대 경로 또는 None, realpath)`. 루트를 이탈하면
    첫 값이 None이다. 심볼릭 링크는 realpath 단계에서 해소되므로 루트 밖을
    가리키는 링크도 이탈로 잡힌다. 파일 실존 여부는 판단하지 않는다.
    """
    candidate = raw if os.path.isabs(raw) else os.path.join(root_real, raw)
    real = os.path.realpath(candidate)
    try:
        rel = os.path.relpath(real, root_real)
    except ValueError:  # 다른 드라이브(Windows)
        return None, real
    if rel == os.curdir:
        return None, real
    if rel == os.pardir or rel.startswith(os.pardir + os.sep) or os.path.isabs(rel):
        return None, real
    return rel.replace(os.sep, "/"), real


def _has_parent_segment(raw: str) -> bool:
    """경로 문자열에 `..` 세그먼트가 들어 있는지 본다(구분자 종류 무관)."""
    return any(part == os.pardir for part in raw.replace("\\", "/").split("/"))


# --------------------------------------------------------------------------- #
# 입력 로딩
# --------------------------------------------------------------------------- #


def _resolve_artifact(
    scan_dir: str, override: str | None, basename: str
) -> tuple[str | None, list[str]]:
    """산출물 경로를 해석한다. 반환값은 `(발견된 경로 또는 None, 탐색한 후보들)`."""
    if override is not None:
        return (override if os.path.exists(override) else None), [override]
    candidates = [
        os.path.join(scan_dir, DISCOVERY_SUBDIR, basename),
        os.path.join(scan_dir, basename),
    ]
    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate, candidates
    return None, candidates


def _read_text(path: str, label: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        raise ReconcileError(f"{label} 을 읽을 수 없습니다: {path} ({exc})", EXIT_INPUT_ERROR)
    except UnicodeDecodeError as exc:
        raise ReconcileError(f"{label} 이 UTF-8 이 아닙니다: {path} ({exc})", EXIT_INPUT_ERROR)


def _load_json_object(path: str, label: str) -> dict[str, Any]:
    text = _read_text(path, label)
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ReconcileError(
            f"{label} JSON 파싱 실패: {path} ({exc.lineno}행 {exc.colno}열: {exc.msg})",
            EXIT_INPUT_ERROR,
        )
    if not isinstance(data, dict):
        raise ReconcileError(f"{label} 의 최상위가 객체가 아닙니다: {path}", EXIT_INPUT_ERROR)
    return data


def _load_in_scope(path: str, root_real: str) -> tuple[list[str], list[str]]:
    """in_scope 목록을 정규화한다. 반환값은 `(루트 하위 경로 키, 이탈 경로 원문)`."""
    keys: list[str] = []
    seen: set[str] = set()
    outside: list[str] = []
    for raw_line in _read_text(path, "in_scope_files.txt").splitlines():
        entry = raw_line.strip()
        if not entry:
            continue
        key, _real = _canonical(entry, root_real)
        if key is None:
            outside.append(entry)
            continue
        if key not in seen:
            seen.add(key)
            keys.append(key)
    return keys, outside


@dataclass
class ReviewLog:
    reviewed: set[str] = field(default_factory=set)
    total_rows: int = 0
    not_reviewed_rows: int = 0
    outside_root_rows: list[str] = field(default_factory=list)


def _load_review_log(path: str, root_real: str) -> ReviewLog:
    log = ReviewLog()
    malformed: list[str] = []
    for lineno, raw_line in enumerate(
        _read_text(path, "review_log.jsonl").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line:
            continue
        log.total_rows += 1
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            malformed.append(f"{lineno}행: JSON 파싱 실패 ({exc.msg})")
            continue
        if not isinstance(row, dict):
            malformed.append(f"{lineno}행: 객체가 아님")
            continue
        raw_path = row.get("path")
        if not isinstance(raw_path, str) or not raw_path.strip():
            malformed.append(f"{lineno}행: path 필드가 비어 있거나 문자열이 아님")
            continue
        outcome = row.get("outcome")
        if isinstance(outcome, str) and outcome.strip().lower() in NOT_REVIEWED_OUTCOMES:
            log.not_reviewed_rows += 1
            continue
        key, _real = _canonical(raw_path.strip(), root_real)
        if key is None:
            log.outside_root_rows.append(raw_path.strip())
            continue
        log.reviewed.add(key)
    if malformed:
        shown = "\n".join(f"  - {item}" for item in malformed[:MAX_REPORTED_LINES])
        more = (
            f"\n  ... 그 외 {len(malformed) - MAX_REPORTED_LINES}건"
            if len(malformed) > MAX_REPORTED_LINES
            else ""
        )
        raise ReconcileError(
            f"review_log.jsonl 에 해석할 수 없는 행이 {len(malformed)}건 있습니다: {path}\n"
            f"{shown}{more}\n"
            "  각 행은 {\"path\": ..., \"reviewed_at\": ..., \"outcome\": ...} 형태여야 합니다.",
            EXIT_INPUT_ERROR,
        )
    return log


# --------------------------------------------------------------------------- #
# R9 — 커버리지 정산
# --------------------------------------------------------------------------- #


@dataclass
class Reconciliation:
    in_scope_count: int = 0
    reviewed_count: int = 0
    unreviewed: list[str] = field(default_factory=list)
    changes: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    completeness_before: str | None = None
    completeness_after: str | None = None


def _needs_follow_up_surfaces(coverage: dict[str, Any]) -> list[str]:
    surfaces = coverage.get("surfaces")
    if not isinstance(surfaces, list):
        return []
    ids: list[str] = []
    for surface in surfaces:
        if not isinstance(surface, dict):
            continue
        if surface.get("disposition") == "needs_follow_up":
            surface_id = surface.get("id")
            ids.append(surface_id if isinstance(surface_id, str) else "<id 없음>")
    return ids


def _upsert_deferred(coverage: dict[str, Any], unreviewed: list[str], in_scope: int) -> str:
    """미리뷰 파일에 대한 deferred 항목을 생성하거나 갱신하고, 변경 설명을 반환한다."""
    truncated = len(unreviewed) > MAX_DEFERRED_PATHS
    reason = (
        f"in_scope_files.txt 의 {in_scope}개 파일 중 {len(unreviewed)}개가 "
        f"review_log.jsonl 에 리뷰 완료로 기록되지 않았습니다. "
        "커버리지 정산(R9)이 completeness 를 partial 로 강제했습니다."
    )
    if truncated:
        reason += f" paths 에는 앞선 {MAX_DEFERRED_PATHS}개만 기록했습니다."
    entry = {
        "id": DEFERRED_ID,
        "reason": reason,
        "paths": unreviewed[:MAX_DEFERRED_PATHS],
    }

    deferred = coverage.get("deferred")
    if not isinstance(deferred, list):
        deferred = []
        coverage["deferred"] = deferred

    for index, existing in enumerate(deferred):
        if isinstance(existing, dict) and existing.get("id") == DEFERRED_ID:
            if existing == entry:
                return f"deferred[{index}] ({DEFERRED_ID}) 는 이미 최신 상태 — 변경 없음"
            deferred[index] = entry
            return f"deferred[{index}] ({DEFERRED_ID}) 갱신 — 미리뷰 {len(unreviewed)}개"
    deferred.append(entry)
    return (
        f"deferred 에 {DEFERRED_ID} 항목 추가 — 미리뷰 {len(unreviewed)}개 "
        f"(기존 항목 {len(deferred) - 1}개 보존)"
    )


def reconcile_coverage(
    coverage: dict[str, Any], in_scope: list[str], log: ReviewLog
) -> Reconciliation:
    """coverage 딕셔너리를 제자리에서 정산한다(파일 쓰기는 호출자 책임)."""
    result = Reconciliation(in_scope_count=len(in_scope))
    in_scope_set = set(in_scope)
    reviewed_in_scope = log.reviewed & in_scope_set
    result.reviewed_count = len(reviewed_in_scope)
    result.unreviewed = [key for key in in_scope if key not in reviewed_in_scope]

    before = coverage.get("completeness")
    result.completeness_before = before if isinstance(before, str) else None

    if not in_scope:
        # 빈 인벤토리로 complete 를 주장하면 대개 2단계 인벤토리(rg/git ls-files)
        # 실패의 신호다. 정산은 인벤토리를 다시 만들지 않으므로 하드 실패시키지
        # 않되, 근거 없는 완결성 주장을 놓치지 않도록 경고한다.
        result.warnings.append(
            "in_scope_files.txt 가 비어 있습니다 — 인벤토리 단계가 파일을 하나도 찾지 못한 "
            "것일 수 있습니다. 스코프·rg/git ls-files 결과를 확인하세요(정산은 인벤토리를 "
            "재생성하지 않습니다)."
        )

    extra = len(log.reviewed - in_scope_set)
    if extra:
        result.warnings.append(
            f"review_log.jsonl 에 in_scope 목록에 없는 파일 {extra}개가 기록되어 있습니다 "
            "(정산 집계에서 제외했습니다)."
        )
    if log.outside_root_rows:
        result.warnings.append(
            f"review_log.jsonl 의 경로 {len(log.outside_root_rows)}건이 소스 루트를 "
            f"벗어나 집계에서 제외했습니다 (예: {log.outside_root_rows[0]})."
        )
    if log.not_reviewed_rows:
        result.warnings.append(
            f"review_log.jsonl 의 {log.not_reviewed_rows}행은 outcome 이 미완료 상태여서 "
            "리뷰 완료로 세지 않았습니다."
        )
    if in_scope and not isinstance(coverage.get("surfaces"), list):
        result.warnings.append("coverage.surfaces 가 배열이 아닙니다 — finalizer 가 거부합니다.")
    elif in_scope and not coverage.get("surfaces"):
        result.warnings.append(
            "coverage.surfaces 가 비어 있습니다 — 리뷰한 표면을 기록하지 않으면 "
            "커버리지 원장이 근거를 갖지 못합니다."
        )

    if result.unreviewed:
        # 리뷰 로그가 뒷받침하지 않는 완결성 주장을 하향 조정한다.
        if before != "partial":
            coverage["completeness"] = "partial"
            result.changes.append(
                f"completeness: {before!r} -> 'partial' (리뷰 완료 "
                f"{result.reviewed_count}/{result.in_scope_count})"
            )
        result.changes.append(
            _upsert_deferred(coverage, result.unreviewed, result.in_scope_count)
        )
    else:
        # 전 파일 리뷰됨 — completeness 는 모델이 쓴 값을 존중한다. 단
        # 'complete' 인데 deferred/needs_follow_up 이 남아 있으면 스키마가
        # 거부하므로 정직한 방향(partial)으로만 내린다.
        blockers: list[str] = []
        deferred = coverage.get("deferred")
        if isinstance(deferred, list) and deferred:
            blockers.append(f"deferred {len(deferred)}건")
        follow_up = _needs_follow_up_surfaces(coverage)
        if follow_up:
            blockers.append(f"needs_follow_up surface {len(follow_up)}건 ({', '.join(follow_up)})")
        if before == "complete" and blockers:
            coverage["completeness"] = "partial"
            result.changes.append(
                f"completeness: 'complete' -> 'partial' ({', '.join(blockers)} 이 남아 있음)"
            )

    after = coverage.get("completeness")
    result.completeness_after = after if isinstance(after, str) else None
    return result


def write_coverage(path: str, coverage: dict[str, Any]) -> None:
    """coverage.json 을 원자적으로 덮어쓴다(기존 퍼미션 유지, 기본 0600)."""
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except OSError:
        mode = 0o600
    tmp_path = f"{path}.reconcile.tmp"
    payload = json.dumps(coverage, indent=2, ensure_ascii=False) + "\n"
    try:
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        finally:
            os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    except OSError as exc:
        if os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        raise ReconcileError(f"coverage.json 을 쓸 수 없습니다: {path} ({exc})", EXIT_INPUT_ERROR)


# --------------------------------------------------------------------------- #
# R10 — finding 경로 실존
# --------------------------------------------------------------------------- #


@dataclass
class PathViolation:
    finding_index: int
    title: str
    field_path: str
    raw_path: str
    reason: str

    def render(self) -> str:
        return (
            f'  - findings[{self.finding_index}] "{self.title}"\n'
            f"      {self.field_path} = {self.raw_path}\n"
            f"      → {self.reason}"
        )


def _check_path(raw: str, root_real: str) -> str | None:
    """경로 하나를 검사해 위반 사유를 반환한다(유효하면 None)."""
    entry = raw.strip()
    if not entry:
        return "빈 문자열입니다."
    if os.path.isabs(entry):
        return (
            "절대 경로입니다 — locations[].path 는 소스 루트 기준 상대 POSIX 경로여야 "
            "합니다(finalizer 도 절대 경로를 거부합니다)."
        )
    if _has_parent_segment(entry):
        return "'..' 세그먼트로 소스 루트를 이탈하려 합니다."
    key, real = _canonical(entry, root_real)
    if key is None:
        return f"정규화 결과가 소스 루트 밖을 가리킵니다 (realpath: {real}) — 루트 밖 심볼릭 링크일 수 있습니다."
    if not os.path.exists(real):
        return f"소스 루트 하위에 존재하지 않습니다 (검사 경로: {real})."
    if os.path.isdir(real):
        return f"디렉터리입니다 — 파일이어야 합니다 (검사 경로: {real})."
    if not os.path.isfile(real):
        return f"일반 파일이 아닙니다 (검사 경로: {real})."
    return None


def _count_lines(real_path: str) -> int | None:
    try:
        with open(real_path, "rb") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return None


def check_finding_paths(
    findings_doc: dict[str, Any], root_real: str
) -> tuple[list[PathViolation], int, list[str]]:
    """모든 finding 경로를 검사한다. 반환값은 `(위반 목록, 검사한 경로 수, 경고)`."""
    findings = findings_doc.get("findings")
    if findings is None:
        raise ReconcileError(
            "findings.json 에 'findings' 키가 없습니다 — 취약점이 없더라도 빈 배열이 필요합니다.",
            EXIT_INPUT_ERROR,
        )
    if not isinstance(findings, list):
        raise ReconcileError("findings.json 의 'findings' 가 배열이 아닙니다.", EXIT_INPUT_ERROR)

    violations: list[PathViolation] = []
    warnings: list[str] = []
    checked = 0

    for index, finding in enumerate(findings):
        if not isinstance(finding, dict):
            raise ReconcileError(
                f"findings.json 의 findings[{index}] 가 객체가 아닙니다.", EXIT_INPUT_ERROR
            )
        raw_title = finding.get("title")
        title = raw_title if isinstance(raw_title, str) and raw_title else "<제목 없음>"

        for group, required in (("locations", True), ("codeEvidence", False)):
            entries = finding.get(group)
            if entries is None:
                if required:
                    violations.append(
                        PathViolation(index, title, group, "<없음>", "필수 배열이 없습니다.")
                    )
                continue
            if not isinstance(entries, list):
                violations.append(
                    PathViolation(index, title, group, "<배열 아님>", "배열이어야 합니다.")
                )
                continue
            if required and not entries:
                violations.append(
                    PathViolation(index, title, group, "<빈 배열>", "최소 1개가 필요합니다.")
                )
                continue
            for entry_index, entry in enumerate(entries):
                field_path = f"{group}[{entry_index}].path"
                if not isinstance(entry, dict):
                    violations.append(
                        PathViolation(index, title, field_path, "<객체 아님>", "객체여야 합니다.")
                    )
                    continue
                raw_path = entry.get("path")
                if not isinstance(raw_path, str):
                    violations.append(
                        PathViolation(
                            index, title, field_path, repr(raw_path), "문자열이어야 합니다."
                        )
                    )
                    continue
                checked += 1
                reason = _check_path(raw_path, root_real)
                if reason is not None:
                    violations.append(
                        PathViolation(index, title, field_path, raw_path, reason)
                    )
                    continue
                # 경로가 유효할 때만 라인 범위를 확인한다. finalizer 도 보지 않는
                # 항목이지만 게이트 실패로 다루지는 않는다(경고만).
                start_line = entry.get("startLine")
                if isinstance(start_line, int) and not isinstance(start_line, bool):
                    _key, real = _canonical(raw_path.strip(), root_real)
                    total = _count_lines(real)
                    if total is not None and start_line > max(total, 1):
                        warnings.append(
                            f"findings[{index}] \"{title}\" {field_path.rsplit('.', 1)[0]}"
                            f".startLine={start_line} 이 파일 실제 라인 수({total})를 "
                            f"초과합니다: {raw_path}"
                        )
    return violations, checked, warnings


# --------------------------------------------------------------------------- #
# 실행
# --------------------------------------------------------------------------- #


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="coverage_reconcile.py",
        description=(
            "커버리지 정산(R9)과 finding 경로 검사(R10). "
            "bind-repo-scopes 다음, finalize_scan_contract.py 직전에 실행한다."
        ),
    )
    parser.add_argument("--scan-dir", required=True, help="스캔 산출물 디렉터리")
    parser.add_argument("--source-root", required=True, help="스캔 대상 저장소 루트")
    parser.add_argument(
        "--in-scope-file",
        help=(
            "in_scope_files.txt 경로 명시 지정. 기본값은 "
            "<scan-dir>/artifacts/02_discovery/in_scope_files.txt, 없으면 <scan-dir>/in_scope_files.txt"
        ),
    )
    parser.add_argument(
        "--review-log",
        help=(
            "review_log.jsonl 경로 명시 지정. 기본값은 "
            "<scan-dir>/artifacts/02_discovery/review_log.jsonl, 없으면 <scan-dir>/review_log.jsonl"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="coverage.json 을 쓰지 않고 무엇이 바뀔지만 보고한다.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="as_json",
        help="stdout 에 결과 JSON 을 출력한다(사람용 요약은 stderr 로 보낸다).",
    )
    return parser


def run(args: argparse.Namespace, out) -> tuple[int, dict[str, Any]]:
    scan_dir = os.path.abspath(args.scan_dir)
    if not os.path.isdir(scan_dir):
        raise ReconcileError(f"--scan-dir 이 디렉터리가 아닙니다: {scan_dir}", EXIT_INPUT_ERROR)
    source_root = os.path.abspath(args.source_root)
    if not os.path.isdir(source_root):
        raise ReconcileError(
            f"--source-root 이 디렉터리가 아닙니다: {source_root}", EXIT_INPUT_ERROR
        )
    root_real = os.path.realpath(source_root)

    # --- 입력 해석 --------------------------------------------------------- #
    in_scope_path, in_scope_candidates = _resolve_artifact(
        scan_dir, args.in_scope_file, IN_SCOPE_BASENAME
    )
    if in_scope_path is None:
        tried = "\n".join(f"  - {candidate}" for candidate in in_scope_candidates)
        raise ReconcileError(
            "in_scope_files.txt 를 찾을 수 없습니다 — 인벤토리 단계가 완료되지 않았습니다.\n"
            f"다음 경로를 찾아봤습니다:\n{tried}",
            EXIT_INPUT_ERROR,
        )

    review_log_path, review_log_candidates = _resolve_artifact(
        scan_dir, args.review_log, REVIEW_LOG_BASENAME
    )
    if review_log_path is None:
        tried = "\n".join(f"  - {candidate}" for candidate in review_log_candidates)
        raise ReconcileError(
            "[R9 위반] review_log.jsonl 이 없습니다. 파일별 리뷰 기록이 없는 스캔은 "
            "커버리지 완결성을 주장할 수 없습니다(리뷰 로그 부재 자체가 정직성 위반).\n"
            f"다음 경로를 찾아봤습니다:\n{tried}\n"
            "리뷰한 파일마다 {\"path\": ..., \"reviewed_at\": ..., \"outcome\": ...} 를 "
            "한 줄씩 추가하세요.",
            EXIT_VIOLATION,
        )

    coverage_path = os.path.join(scan_dir, "coverage.json")
    if not os.path.exists(coverage_path):
        raise ReconcileError(
            f"coverage.json 이 없습니다: {coverage_path}", EXIT_INPUT_ERROR
        )
    findings_path = os.path.join(scan_dir, "findings.json")
    if not os.path.exists(findings_path):
        raise ReconcileError(
            f"findings.json 이 없습니다: {findings_path}", EXIT_INPUT_ERROR
        )

    coverage = _load_json_object(coverage_path, "coverage.json")
    findings_doc = _load_json_object(findings_path, "findings.json")

    in_scope, in_scope_outside = _load_in_scope(in_scope_path, root_real)
    review_log = _load_review_log(review_log_path, root_real)

    # --- R9 --------------------------------------------------------------- #
    recon = reconcile_coverage(coverage, in_scope, review_log)
    if in_scope_outside:
        recon.warnings.insert(
            0,
            f"in_scope_files.txt 의 {len(in_scope_outside)}개 항목이 소스 루트를 벗어나 "
            f"집계에서 제외했습니다 (예: {in_scope_outside[0]}).",
        )

    coverage_written = False
    if recon.changes and not args.dry_run:
        write_coverage(coverage_path, coverage)
        coverage_written = True

    # --- R10 -------------------------------------------------------------- #
    violations, checked_paths, path_warnings = check_finding_paths(findings_doc, root_real)

    # --- 보고 -------------------------------------------------------------- #
    print("=== 커버리지 정산 (R9) ===", file=out)
    print(f"  in_scope 목록: {in_scope_path}", file=out)
    print(f"  리뷰 로그   : {review_log_path} ({review_log.total_rows}행)", file=out)
    print(
        f"  리뷰 완료   : {recon.reviewed_count}/{recon.in_scope_count} "
        f"(미리뷰 {len(recon.unreviewed)}개)",
        file=out,
    )
    print(
        f"  completeness: {recon.completeness_before!r} -> {recon.completeness_after!r}",
        file=out,
    )
    if recon.changes:
        for change in recon.changes:
            print(f"  변경: {change}", file=out)
        print(
            "  coverage.json 재작성: "
            + ("생략(--dry-run)" if args.dry_run else f"완료 ({coverage_path})"),
            file=out,
        )
    else:
        print("  변경: 없음 — 리뷰 로그가 기존 커버리지 주장을 뒷받침합니다.", file=out)
    if recon.unreviewed:
        preview = ", ".join(recon.unreviewed[:3])
        suffix = " ..." if len(recon.unreviewed) > 3 else ""
        print(f"  미리뷰 예시: {preview}{suffix}", file=out)

    print("", file=out)
    print("=== finding 경로 검사 (R10) ===", file=out)
    findings_count = len(findings_doc.get("findings") or [])
    print(f"  finding {findings_count}건 / 경로 {checked_paths}개 검사", file=out)
    print(f"  소스 루트: {root_real}", file=out)
    if violations:
        print(f"  위반 {len(violations)}건:", file=out)
        for violation in violations:
            print(violation.render(), file=out)
    else:
        print("  위반 없음 — 모든 경로가 소스 루트 하위 실존 파일입니다.", file=out)

    all_warnings = recon.warnings + path_warnings
    if all_warnings:
        print("", file=out)
        print("=== 경고 (게이트 실패 아님) ===", file=out)
        for warning in all_warnings:
            print(f"  - {warning}", file=out)

    exit_code = EXIT_VIOLATION if violations else EXIT_OK
    print("", file=out)
    if exit_code == EXIT_OK:
        print(
            "판정: 통과 — 커버리지가 리뷰 로그와 일치하고 모든 finding 경로가 유효합니다. "
            "finalize_scan_contract.py 를 진행하세요.",
            file=out,
        )
    else:
        print(
            f"판정: 실패 — finding 경로 위반 {len(violations)}건. draft 를 수정한 뒤 "
            "이 스크립트를 다시 실행하세요(finalize 로 넘기지 마세요).",
            file=out,
        )

    summary = {
        "status": "pass" if exit_code == EXIT_OK else "fail",
        "exitCode": exit_code,
        "scanDir": scan_dir,
        "sourceRoot": root_real,
        "coverage": {
            "path": coverage_path,
            "inScopeFile": in_scope_path,
            "reviewLog": review_log_path,
            "inScopeCount": recon.in_scope_count,
            "reviewedCount": recon.reviewed_count,
            "unreviewedCount": len(recon.unreviewed),
            "completenessBefore": recon.completeness_before,
            "completenessAfter": recon.completeness_after,
            "changes": recon.changes,
            "written": coverage_written,
        },
        "locations": {
            "findingsPath": findings_path,
            "findingCount": findings_count,
            "checkedPathCount": checked_paths,
            "violations": [
                {
                    "findingIndex": violation.finding_index,
                    "title": violation.title,
                    "field": violation.field_path,
                    "path": violation.raw_path,
                    "reason": violation.reason,
                }
                for violation in violations
            ],
        },
        "warnings": all_warnings,
    }
    return exit_code, summary


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    out = sys.stderr if args.as_json else sys.stdout
    try:
        exit_code, summary = run(args, out)
    except ReconcileError as exc:
        print(f"coverage_reconcile.py: 오류: {exc.message}", file=sys.stderr)
        return exc.exit_code
    if args.as_json:
        json.dump(summary, sys.stdout, indent=2, ensure_ascii=False, sort_keys=True)
        sys.stdout.write("\n")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
