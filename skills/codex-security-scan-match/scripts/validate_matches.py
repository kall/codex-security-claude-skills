#!/usr/bin/env python3
"""매칭 카탈로그·호스트 조정 검증기 (Phase 4 U1 / Phase 5 U2 / Phase 6 U5).

상류 npm 0.1.29 의 스캔 매칭 호스트 조정을 표준 라이브러리만으로 옮긴다. 정본:
  - `sdk/typescript/src/finding-catalogue.ts` — groupFindings / findingCatalogue / compactFinding
  - `sdk/typescript/src/scan-comparison.ts` — matchScanFindingsInternal / reconcileComparison /
    validateComparison / validateComparisonInput / unionFindingGroups
  (upstream tag npm-v0.1.29, commit 6620a380f86c26d6c6428a660b2a90c3b5a1fa45)
판정 규칙(서브에이전트 프롬프트 문장)은 SKILL.md 가, 검증·조정 규칙은 이 코드가 소유한다(P5-KTD4).

흐름(상류 matchScanFindingsInternal 과 같은 순서, P6-KTD3):
  1. catalogue — before 를 groupFindings 규칙(같은 findingId + 기확정 그룹)으로 묶어 그룹마다
     최신 occurrence 를 대표 카드로 만들고, 빈 판정으로 조정을 한 번 돌린다. 신원만으로 모든
     그룹이 끝나면 complete=true 와 저장 페이로드를 낸다(서브에이전트 호출 없음, R10).
     아니면 전체 카탈로그(before 대표 카드 전부 + after 카드 전부)를 --catalogue-out 에 쓴다.
     그 파일 내용은 상류 comparisonPrompt() 마지막 줄 JSON 과 문자 단위로 같다.
  2. finalize — 서브에이전트 반환(대표 카드 ID 기준)을 받는다.
       a. 스키마 검사(상류 comparisonSchema .strict() + 우리 선택 키 두 개)
       b. 선택 키 분리: priorGroupConcerns(보고 전용, P6-KTD4) / evidenceNeeded(비어 있지 않으면
          저장 없이 중단, P6-KTD5) — 둘 다 저장 페이로드에 싣지 않는다
       c. 느슨한 단계: 카탈로그 기준 validateComparison(enforceConfirmedIdentities=false)
       d. before 대표 ID → 그룹의 모든 occurrence 로 펼침
       e. reconcileComparison: 느슨한 검증 → 신원 그룹 병합(한 그룹에 걸친 매칭은 하나로,
          신원 전용 그룹은 상류 기본 사유로) → 같은 그룹 안 uncertain·related 제거 → 강제 단계
          (enforceConfirmedIdentities=true)
       f. `workbench_db.py save-scan-comparison --matches-json-stdin` 이 받는 페이로드를 낸다
  3. measure — 조립한 프롬프트의 Unicode 코드포인트 수를 한도와 비교한다(P6-KTD5, R13).

상류 옵션 `allowHistoricalUncertainty` 는 제공하지 않는다(항상 false). 그 옵션은 상류
`scans match --all` 다중 before-scan 흐름 전용이고, 단일 쌍 `scans match` 는 기본값 false 를
쓴다. 상류 저장 단계(workbench_scan_history.py save_scan_comparison)도 uncertain 의 after
재사용을 무조건 거부하므로, 완화하면 "검증 통과"가 저장 가능을 뜻하지 않게 된다.

출력 규약: 모든 결과는 stdout 의 JSON 한 줄이다.
  exit 0 = 성공 / exit 1 = 거부·입력 오류(`{"ok": false, "error": ...}`, finalize 거부는 재판정 대상)
  exit 3 = 저장 없이 중단(evidenceNeeded 가 있음, 또는 프롬프트가 한도를 넘음 — 분할·재시도 없음)
  exit 2 = 호출 형태 오류(argparse)
부속명령 없이 `--input-json … --matches-json …` 로 부르면 finalize 로 처리한다(P5 호출 형태 호환).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

# 상류 MAX_CODEX_INPUT_CHARACTERS(1 << 20). 동등성 기준이다(P6-KTD5).
EQUIVALENCE_LIMIT = 1 << 20
# 실행 기준 기본값. 부모 세션이 조립한 프롬프트 전문을 Agent 호출 인자로 **한 번에 출력**해야
# 하므로, 한 응답의 출력 토큰 상한이 실제 병목이다. 근거와 측정 절차는 SKILL.md
# 「프롬프트 한도」에 있다. 실측으로 바꾸면 SKILL.md 와 repro-u5 의 T4 를 같이 고친다.
DEFAULT_EXECUTION_LIMIT = 80_000
# 상류 reconcileComparison 의 신원 전용 그룹 사유 — 영문 원문 그대로(저장 결과 동등성).
IDENTITY_REASON = "The findings share a stable identity or a previously confirmed link."

_TOP_LEVEL_KEYS = {"matches", "uncertain", "related"}
_CONCERNS_KEY = "priorGroupConcerns"
_EVIDENCE_KEY = "evidenceNeeded"
_OPTIONAL_KEYS = {_CONCERNS_KEY, _EVIDENCE_KEY}
# P5 의 중단 신호 키. P6-KTD4 로 폐기됐다 — 실려 오면 새 키로 옮기라고 안내한다.
_RETIRED_KEY = "blockedByPriorGroup"
_MATCH_KEYS = {"beforeOccurrenceIds", "afterOccurrenceIds", "confidence", "reason"}
_PAIR_KEYS = {"beforeOccurrenceId", "afterOccurrenceId", "reason"}
_CONCERN_KEYS = {"issueId", "reason"}
_LOOSE = "[느슨한 단계] "
_ENFORCED = "[강제 단계] "
_SUBCOMMANDS = {"catalogue", "finalize", "measure"}


class Abort(Exception):
    """저장 없이 중단해야 하는 결과(exit 3). 재판정 대상이 아니다."""

    def __init__(self, document: dict) -> None:
        super().__init__(document.get("error", ""))
        self.document = document


# ---------------------------------------------------------------------------
# 입출력
# ---------------------------------------------------------------------------


def _reject_constant(value: str) -> float:
    # JSON.parse 는 NaN/Infinity 를 받지 않는다. Python json 은 받으므로 여기서 막는다.
    raise ValueError(f"JSON 이 아닌 수치 상수입니다: {value}")


def _read_json(path: str) -> object:
    text = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8")
    try:
        return json.loads(text, parse_constant=_reject_constant)
    except json.JSONDecodeError:
        raise
    except ValueError as error:  # _reject_constant
        raise json.JSONDecodeError(str(error), text, 0) from error


def _write_text(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def _emit(document: dict) -> None:
    print(json.dumps(document, ensure_ascii=False))


def _safe_repr(value: object, limit: int = 2000) -> str:
    """미신뢰 값을 오류 문장에 실을 때 쓰는 표현.

    두 가지를 함께 막는다:
      - **길이** — 매칭 입력은 대상 저장소 코드에서 파생된 자유 텍스트다(제목·설명·
        코드 발췌). 무제한으로 실으면 finding 본문이 통째로 부모 세션 컨텍스트로
        흘러든다(실측: 상류 finding 스키마의 현실적인 한 행 — 30줄 코드 발췌 2개면
        7.4KB, source/propagator/sink 3개면 9.6KB).
      - **repr 자체의 재귀 폭주** — f-string 은 ValueError 를 만들기 **전에**
        평가되므로, 깊게 중첩된 값이 오면 main() 의 except 가 잡지 못하고
        stdout 이 비어 트레이스백만 남는다. 그러면 "exit 1 + {ok:false}" 계약이
        깨져 재판정 루프가 사유를 잃는다(실측).
    """
    try:
        text = repr(value)
    except RecursionError:
        return f"<{type(value).__name__}: repr 재귀 한도 초과>"
    return text if len(text) <= limit else text[:limit] + "…(절단)"


def _short(value: object, limit: int = 200) -> str:
    """서브에이전트가 쓴 식별자를 오류 문장에 실을 때 쓴다(문자열은 따옴표 없이)."""
    text = value if isinstance(value, str) else _safe_repr(value, limit)
    return text if len(text) <= limit else text[:limit] + "…(절단)"


# ---------------------------------------------------------------------------
# JavaScript JSON.stringify 재현 — 카탈로그 JSON 을 상류 프롬프트와 문자 단위로 맞추고,
# earlierDescriptions 비교·중복 제거를 상류와 같은 기준으로 하려고 쓴다.
# ---------------------------------------------------------------------------


def _js_number(value: float) -> str:
    """ECMAScript Number::toString (JSON.stringify 의 수치 표현)."""
    if math.isnan(value) or math.isinf(value):
        return "null"
    if value == 0:
        return "0"
    sign = "-" if value < 0 else ""
    mantissa, _, exponent = repr(abs(value)).partition("e")
    integer, _, fraction = mantissa.partition(".")
    digits = integer + fraction
    point = len(integer) + (int(exponent) if exponent else 0)
    stripped = digits.lstrip("0")
    point -= len(digits) - len(stripped)
    digits = stripped.rstrip("0") or "0"
    k, n = len(digits), point
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * (-n) + digits
    e = n - 1
    tail = ("+" if e >= 0 else "-") + str(abs(e))
    return sign + (digits if k == 1 else digits[0] + "." + digits[1:]) + "e" + tail


def _js_string(value: str) -> str:
    out = ['"']
    for char in value:
        code = ord(char)
        if char == '"':
            out.append('\\"')
        elif char == "\\":
            out.append("\\\\")
        elif char == "\b":
            out.append("\\b")
        elif char == "\f":
            out.append("\\f")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif code < 0x20 or 0xD800 <= code <= 0xDFFF:
            # 제어 문자와 짝 없는 서로게이트(well-formed JSON.stringify).
            out.append(f"\\u{code:04x}")
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def _is_array_index(key: str) -> bool:
    return key.isdigit() and key.isascii() and (key == "0" or key[0] != "0") and int(key) < 2**32 - 1


def _js_keys(value: dict) -> list[str]:
    # JS 객체는 배열 인덱스 모양 키를 오름차순으로 먼저, 나머지를 삽입 순서로 둔다.
    indexes = sorted((key for key in value if _is_array_index(key)), key=int)
    return indexes + [key for key in value if not _is_array_index(key)]


def js_stringify(value: object) -> str:
    """JSON.stringify(value) 와 같은 문자열(값은 JSON.parse 로 읽을 수 있는 형태만)."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        # JS 수치는 배정밀도다. 2**53 을 넘는 정수는 상류에서 이미 반올림된다.
        return str(value) if abs(value) <= 2**53 else _js_number(float(value))
    if isinstance(value, float):
        return _js_number(value)
    if isinstance(value, str):
        return _js_string(value)
    if isinstance(value, list):
        return "[" + ",".join(js_stringify(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(
            _js_string(key) + ":" + js_stringify(value[key]) for key in _js_keys(value)
        ) + "}"
    raise TypeError(f"JSON 값이 아닙니다: {type(value).__name__}")


def _js_to_string(value: object) -> str:
    """String(value) — compactFinding 의 location role 비교에만 쓴다."""
    if value is None:
        return "undefined"
    if isinstance(value, list):
        return ",".join("" if item is None else _js_to_string(item) for item in value)
    if isinstance(value, dict):
        return "[object Object]"
    if value is True or value is False:
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return _js_number(float(value)) if isinstance(value, float) else str(value)
    return str(value)


def characters(text: str) -> int:
    """상류 characterCount — Unicode 코드포인트 수."""
    return len(text)


# ---------------------------------------------------------------------------
# finding-catalogue.ts 이식
# ---------------------------------------------------------------------------


def _record(value: object) -> dict | None:
    return value if isinstance(value, dict) else None


def _present(value: dict) -> dict:
    return {
        key: item
        for key, item in value.items()
        if item is not None
        and not (isinstance(item, str) and item == "")
        and not (isinstance(item, list) and len(item) == 0)
        and not (isinstance(item, dict) and len(item) == 0)
    }


def _pick(value: object, fields: tuple[str, ...]) -> object:
    if isinstance(value, str):
        return value
    obj = _record(value)
    if obj is None:
        return None
    return _present({field: obj.get(field) for field in fields})


def _coalesce(*values: object) -> object:
    """JS `a ?? b ?? c` — null·undefined 만 건너뛴다."""
    for value in values:
        if value is not None:
            return value
    return None


def compact_finding(finding: dict) -> dict:
    """상류 compactFinding — 카드에 싣는 필드만 고르고 전체 증거는 뺀다."""
    root_cause = _coalesce(finding.get("rootCause"), finding.get("root_cause"))
    attack_path = _record(finding.get("attackPath"))
    data_flow = None
    reachability = None
    if attack_path is not None:
        data_flow = _coalesce(
            attack_path.get("dataFlow"), attack_path.get("data_flow"), attack_path.get("dataflow")
        )
        reachability = attack_path.get("reachability")
    raw_locations = finding.get("locations")
    locations = (
        [location for location in raw_locations if _record(location) is not None]
        if isinstance(raw_locations, list)
        else []
    )
    controls = [location for location in locations if location.get("role") == "root_control"]
    if not controls:
        controls = [
            location
            for location in locations
            if _js_to_string(location.get("role")) in ("expected_control", "concrete_implementation")
        ]
    if not controls:
        controls = locations[:1]
    if isinstance(root_cause, str):
        cause = root_cause
    else:
        cause_record = _record(root_cause)
        cause = cause_record.get("summary") if cause_record is not None else None
    cause = _coalesce(cause, finding.get("summary"))
    return {
        "occurrenceId": finding["occurrenceId"],
        **_present({
            "findingId": finding.get("findingId"),
            "title": finding.get("title"),
            "identity": _pick(finding.get("identity"), ("anchor", "instance")),
            "ruleId": finding.get("ruleId"),
            "taxonomy": _pick(finding.get("taxonomy"), ("category", "cwe")),
            "rootCause": cause,
            "remediation": finding.get("remediation"),
            "locations": [
                _pick(location, ("path", "startLine", "endLine", "role")) for location in controls
            ],
            "attackPath": _present({
                "dataFlow": _pick(data_flow, ("source", "sink")),
                "reachability": _pick(reachability, ("attacker", "entrypoint")),
            }),
            "affectedComponent": finding.get("affectedComponent"),
            "boundaryCrossed": finding.get("boundaryCrossed"),
        }),
    }


def _stable_id(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def group_findings(
    findings: list[dict],
    known_groups: list[list[str]],
    occurrence_groups: list[list[str]] = (),  # type: ignore[assignment]
) -> list[list[dict]]:
    """상류 groupFindings — findingId·기확정 그룹·occurrence 묶음을 union-find 로 병합한다."""
    parents: dict[str, str] = {}

    def root(value: str) -> str:
        path = []
        current = value
        while current in parents:
            path.append(current)
            current = parents[current]
        for item in path:
            parents[item] = current
        return current

    def link(first: str, second: str) -> None:
        previous, current = root(first), root(second)
        if previous != current:
            parents[current] = previous

    for prefix, groups in (("finding", known_groups), ("occurrence", occurrence_groups)):
        for group in groups:
            identities = [item for item in group if item.strip()] if prefix == "finding" else list(group)
            if not identities:
                continue
            for value in identities[1:]:
                link(f"{prefix}:{identities[0]}", f"{prefix}:{value}")
    for finding in findings:
        if _stable_id(finding.get("findingId")):
            link(f"finding:{finding['findingId']}", f"occurrence:{finding['occurrenceId']}")

    grouped: dict[str, list[dict]] = {}
    for finding in findings:
        grouped.setdefault(root(f"occurrence:{finding['occurrenceId']}"), []).append(finding)
    return list(grouped.values())


def finding_catalogue(findings: list[dict], known_groups: list[list[str]]) -> dict[str, dict]:
    """상류 findingCatalogue — 대표 occurrenceId → {card, occurrences}."""
    catalogue: dict[str, dict] = {}
    for occurrences in group_findings(findings, known_groups):
        latest = occurrences[-1]
        card = compact_finding(latest)
        if len(occurrences) > 1:

            def description(finding: dict) -> dict:
                value = dict(compact_finding(finding))
                value.pop("occurrenceId", None)
                value.pop("findingId", None)
                return value

            current = description(latest)
            seen: set[str] = set()
            aliases = []
            for finding in occurrences[:-1]:
                value = {
                    field: item
                    for field, item in description(finding).items()
                    if field not in current or js_stringify(item) != js_stringify(current[field])
                }
                if not value:
                    continue
                key = js_stringify(value)
                if key in seen:
                    continue
                seen.add(key)
                aliases.append(value)
            card["occurrenceCount"] = len(occurrences)
            if aliases:
                card["earlierDescriptions"] = aliases
        if _stable_id(occurrences[0].get("findingId")):
            card["issueId"] = occurrences[0]["findingId"]
        catalogue[latest["occurrenceId"]] = {"card": card, "occurrences": occurrences}
    return catalogue


# ---------------------------------------------------------------------------
# scan-comparison.ts 이식
# ---------------------------------------------------------------------------


def union_finding_groups(groups: list[list[str]]) -> list[list[str]]:
    """상류 unionFindingGroups — findingId 그룹들을 union-find 로 병합한다(공백 ID 제외)."""
    parents: dict[str, str] = {}

    def representative(identity: str) -> str:
        root = identity
        while parents[root] != root:
            root = parents[root]
        current = identity
        while parents[current] != current:
            parents[current], current = root, parents[current]
        return root

    for group in groups:
        identities = [identity for identity in group if identity.strip()]
        if not identities:
            continue
        first, rest = identities[0], identities[1:]
        parents.setdefault(first, first)
        first_root = representative(first)
        for identity in rest:
            parents.setdefault(identity, identity)
            parents[representative(identity)] = first_root

    united: dict[str, list[str]] = {}
    for identity in list(parents):
        united.setdefault(representative(identity), []).append(identity)
    return list(united.values())


def _finding_ids(rows: list[dict]) -> dict[str, str]:
    return {
        row["occurrenceId"]: row["findingId"] for row in rows if _stable_id(row.get("findingId"))
    }


def validate_comparison(
    before: list[dict],
    after: list[dict],
    known_groups: list[list[str]],
    response: dict,
    *,
    enforce: bool,
    stage: str,
    hints: dict[str, str] | None = None,
) -> None:
    """상류 validateComparison(allowHistoricalUncertainty=false). 위반 시 ValueError.

    `enforce` 는 상류 enforceConfirmedIdentities 다. 느슨한 단계(False)는 서브에이전트
    반환을 카탈로그 기준으로, 강제 단계(True)는 조정이 끝난 결과를 전체 입력 기준으로 본다.
    """
    before_ids = {row["occurrenceId"] for row in before}
    after_ids = {row["occurrenceId"] for row in after}
    finding_ids = _finding_ids(before + after)
    matched_before: dict[str, int] = {}
    matched_after: dict[str, int] = {}

    for group, match in enumerate(response["matches"]):
        for side, values, expected, used in (
            ("before", match["beforeOccurrenceIds"], before_ids, matched_before),
            ("after", match["afterOccurrenceIds"], after_ids, matched_after),
        ):
            for occurrence in values:
                if occurrence not in expected:
                    hint = (hints or {}).get(occurrence) if side == "before" else None
                    suffix = (
                        f" (대표 카드 ID 가 아닙니다 — 이 occurrence 는 대표 카드 '{hint}' 로 접혔습니다."
                        " before 는 신뢰 블록의 대표 카드 ID 로만 가리키세요)"
                        if hint
                        else ""
                    )
                    raise ValueError(
                        f"{stage}미지의 {side} occurrence 를 참조했습니다: {_short(occurrence)}{suffix}"
                    )
                if occurrence in used:
                    raise ValueError(
                        f"{stage}{side} occurrence 가 두 번 이상 매칭되었습니다: {_short(occurrence)}"
                    )
                used[occurrence] = group

    confirmed = union_finding_groups(
        known_groups + [[finding_id] for finding_id in dict.fromkeys(finding_ids.values())]
    )
    if enforce:
        occurrences_by_finding: dict[str, list[str]] = {}
        for occurrence, finding_id in finding_ids.items():
            occurrences_by_finding.setdefault(finding_id, []).append(occurrence)
        for known in confirmed:
            known_occurrences = [
                occurrence
                for finding_id in known
                for occurrence in occurrences_by_finding.get(finding_id, [])
            ]
            matched_groups = {
                matched_before.get(occurrence, matched_after.get(occurrence))
                for occurrence in known_occurrences
                if occurrence in matched_before or occurrence in matched_after
            }
            unmatched = any(
                occurrence not in matched_before and occurrence not in matched_after
                for occurrence in known_occurrences
            )
            both_sides = any(o in before_ids for o in known_occurrences) and any(
                o in after_ids for o in known_occurrences
            )
            if (
                len(matched_groups) > 1
                or (len(matched_groups) == 1 and unmatched)
                or (both_sides and not matched_groups)
            ):
                raise ValueError(f"{stage}기확정 finding 그룹과 모순되는 매칭입니다: {sorted(known)}")

    uncertain_pairs: set[tuple[str, str]] = set()
    for candidate in response["uncertain"]:
        b, a = candidate["beforeOccurrenceId"], candidate["afterOccurrenceId"]
        before_finding, after_finding = finding_ids.get(b), finding_ids.get(a)
        if (
            b not in before_ids
            or b in matched_before
            or a not in after_ids
            or (enforce and before_finding is not None and before_finding == after_finding)
            or a in matched_after
        ):
            raise ValueError(f"{stage}유효하지 않은 uncertain 쌍입니다: ({_short(b)}, {_short(a)})")
        if (b, a) in uncertain_pairs:
            raise ValueError(f"{stage}중복된 uncertain 쌍입니다: ({_short(b)}, {_short(a)})")
        uncertain_pairs.add((b, a))

    known_group_by_finding = {
        finding_id: index for index, group in enumerate(confirmed) for finding_id in group
    }
    related_pairs: set[tuple[str, str]] = set()
    for candidate in response.get("related", []):
        b, a = candidate["beforeOccurrenceId"], candidate["afterOccurrenceId"]
        before_group = matched_before.get(b)
        before_finding, after_finding = finding_ids.get(b), finding_ids.get(a)
        known_before = None if before_finding is None else known_group_by_finding.get(before_finding)
        known_after = None if after_finding is None else known_group_by_finding.get(after_finding)
        if (
            b not in before_ids
            or a not in after_ids
            or (before_group is not None and before_group == matched_after.get(a))
            or (enforce and known_before is not None and known_before == known_after)
            or (b, a) in uncertain_pairs
            or (b, a) in related_pairs
        ):
            raise ValueError(f"{stage}유효하지 않은 related 쌍입니다: ({_short(b)}, {_short(a)})")
        related_pairs.add((b, a))


def reconcile_comparison(
    before: list[dict],
    after: list[dict],
    known_groups: list[list[str]],
    response: dict,
) -> tuple[dict, bool]:
    """상류 reconcileComparison — (저장 결과, 신원만으로 완결 여부)."""
    validate_comparison(before, after, known_groups, response, enforce=False, stage=_LOOSE)
    before_ids = {row["occurrenceId"] for row in before}
    after_ids = {row["occurrenceId"] for row in after}
    groups = group_findings(
        before + after,
        known_groups,
        [m["beforeOccurrenceIds"] + m["afterOccurrenceIds"] for m in response["matches"]],
    )
    group_by_occurrence = {
        row["occurrenceId"]: index for index, group in enumerate(groups) for row in group
    }
    semantic: dict[int, list[dict]] = {}
    for match in response["matches"]:
        semantic.setdefault(group_by_occurrence[match["beforeOccurrenceIds"][0]], []).append(match)
    matches = []
    for index in dict.fromkeys([*semantic, *range(len(groups))]):
        semantic_matches = semantic.get(index, [])
        ids = [row["occurrenceId"] for row in groups[index]]
        before_side = list(dict.fromkeys(
            [x for m in semantic_matches for x in m["beforeOccurrenceIds"]]
            + [x for x in ids if x in before_ids]
        ))
        after_side = list(dict.fromkeys(
            [x for m in semantic_matches for x in m["afterOccurrenceIds"]]
            + [x for x in ids if x in after_ids]
        ))
        if not before_side or not after_side:
            continue
        reasons = list(dict.fromkeys(m["reason"] for m in semantic_matches))
        matches.append({
            "beforeOccurrenceIds": before_side,
            "afterOccurrenceIds": after_side,
            "confidence": "high",
            "reason": " ".join(reasons) if reasons else IDENTITY_REASON,
        })

    def separate(pairs: list[dict]) -> list[dict]:
        return [
            pair
            for pair in pairs
            if group_by_occurrence.get(pair["beforeOccurrenceId"])
            != group_by_occurrence.get(pair["afterOccurrenceId"])
        ]

    comparison: dict = {"matches": matches, "uncertain": separate(response["uncertain"])}
    if "related" in response:
        comparison["related"] = separate(response["related"])
    validate_comparison(before, after, known_groups, comparison, enforce=True, stage=_ENFORCED)
    return comparison, len(matches) == len(groups)


# ---------------------------------------------------------------------------
# 입력 해석
# ---------------------------------------------------------------------------


def _side(container: dict, key: str) -> list[dict]:
    rows = container.get(key)
    if not isinstance(rows, list):
        raise ValueError(f"매칭 입력에 '{key}' 배열이 없습니다.")
    for index, row in enumerate(rows):
        # 조용히 건너뛰면 식별자 우주가 줄어들어 기확정 그룹 검사가 상류보다 약해진다 —
        # 상류 TS 는 모든 원소를 무조건 담으므로 "우리는 통과, 상류는 거부"가 된다(실측).
        if not isinstance(row, dict) or not isinstance(row.get("occurrenceId"), str):
            raise ValueError(
                f"매칭 입력 '{key}'[{index}] 에 문자열 occurrenceId 가 없습니다: {_safe_repr(row)}"
            )
    return rows


def _load_input(raw: object) -> tuple[list[dict], list[dict], list[list[str]]]:
    """matchingInputs 를 읽고 상류 validateComparisonInput 을 적용한다."""
    # {before, after} 또는 {matchingInputs: {before, after}} (compare-scans 전체 출력) 모두 받는다.
    container = raw.get("matchingInputs") if isinstance(raw, dict) and "matchingInputs" in raw else raw
    if not isinstance(container, dict):
        raise ValueError("매칭 입력 최상위가 객체가 아닙니다.")
    before, after = _side(container, "before"), _side(container, "after")
    seen: set[str] = set()
    for row in before + after:
        occurrence = row["occurrenceId"]
        if not occurrence.strip() or occurrence in seen:
            raise ValueError(
                "매칭 입력의 occurrenceId 는 비어 있지 않고 전역에서 유일해야 합니다: "
                f"{_short(occurrence)}"
            )
        seen.add(occurrence)
    known = container.get("knownFindingGroups")
    if known is None:
        known = []
    if not isinstance(known, list) or not all(
        isinstance(group, list) and all(isinstance(item, str) for item in group) for group in known
    ):
        raise ValueError("knownFindingGroups 는 문자열 배열의 배열이어야 합니다.")
    return before, after, [list(group) for group in known]


def _non_blank(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _validate_pairs(rows: object, label: str, keys: set[str] = _PAIR_KEYS) -> list[dict]:
    if not isinstance(rows, list):
        raise ValueError(f"{label} 이 배열이 아닙니다(스키마 위반).")
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError(f"{label} 원소가 객체가 아닙니다.")
        if set(row) != keys:
            raise ValueError(f"{label} 원소의 키는 정확히 {sorted(keys)} 여야 합니다: {sorted(row)}")
        if not all(_non_blank(value) for value in row.values()):
            count = {2: "두", 3: "세"}[len(keys)]
            raise ValueError(f"{label} 원소의 {count} 값은 모두 공백이 아닌 문자열이어야 합니다.")
    return rows


def _validate_schema(data: object) -> tuple[dict, list[dict], list[dict]]:
    """상류 comparisonSchema(.strict()) + 우리 선택 키. (판정, 우려, 증거 요청) 을 돌려준다."""
    if not isinstance(data, dict):
        raise ValueError("매칭 결과 최상위가 객체가 아닙니다.")
    if _RETIRED_KEY in data:
        raise ValueError(
            f"{_RETIRED_KEY} 는 더 이상 쓰지 않습니다(P6-KTD4). 호스트가 기확정 그룹을 먼저 병합하므로 "
            f"판정을 막지 않습니다 — 그룹이 틀렸다고 보면 {_CONCERNS_KEY}: "
            '[{"issueId": "<그룹의 findingId>", "reason": "<근거>"}] 로 보고하고 판정은 그대로 반환하세요.'
        )
    unknown = set(data) - _TOP_LEVEL_KEYS - _OPTIONAL_KEYS
    if unknown:
        raise ValueError(f"매칭 결과에 허용되지 않은 최상위 키가 있습니다: {sorted(unknown)}")
    matches = data.get("matches")
    if not isinstance(matches, list) or not isinstance(data.get("uncertain"), list):
        raise ValueError("matches / uncertain 이 배열이 아닙니다(스키마 위반).")
    for match in matches:
        if not isinstance(match, dict):
            raise ValueError("matches 원소가 객체가 아닙니다.")
        if set(match) != _MATCH_KEYS:
            raise ValueError(
                f"matches 원소의 키는 정확히 {sorted(_MATCH_KEYS)} 여야 합니다: {sorted(match)}"
            )
        for key in ("beforeOccurrenceIds", "afterOccurrenceIds"):
            values = match[key]
            if not (isinstance(values, list) and values and all(isinstance(x, str) for x in values)):
                raise ValueError(f"{key} 는 비어 있지 않은 문자열 배열이어야 합니다.")
        if match["confidence"] != "high":
            raise ValueError("confidence 는 리터럴 'high' 여야 합니다(TS 스키마).")
        if not _non_blank(match["reason"]):
            raise ValueError("matches 의 reason 은 공백이 아닌 문자열이어야 합니다.")
    _validate_pairs(data["uncertain"], "uncertain")
    if "related" in data:
        _validate_pairs(data["related"], "related")
    concerns = _validate_pairs(data.get(_CONCERNS_KEY, []), _CONCERNS_KEY, _CONCERN_KEYS)
    evidence = _validate_pairs(data.get(_EVIDENCE_KEY, []), _EVIDENCE_KEY)
    result = {key: data[key] for key in ("matches", "uncertain", "related") if key in data}
    return result, concerns, evidence


# ---------------------------------------------------------------------------
# 부속명령
# ---------------------------------------------------------------------------


def _prepare(raw_input: object) -> dict:
    """카탈로그와 신원 선조정을 만든다(상류 matchScanFindingsInternal 앞부분)."""
    before, after, known = _load_input(raw_input)
    state: dict = {"before": before, "after": after, "known": known}
    if not before or not after:
        # 상류: 한쪽이 비면 모델 없이 빈 결과를 돌려준다.
        state.update(complete=True, identity={"matches": [], "uncertain": []}, catalogue={})
        return state
    identity, complete = reconcile_comparison(before, after, known, {"matches": [], "uncertain": []})
    catalogue = finding_catalogue(before, known)
    state.update(complete=complete, identity=identity, catalogue=catalogue)
    return state


def _catalogue_line(state: dict) -> str:
    """상류 comparisonPrompt() 마지막 줄 — JSON.stringify({page, pageCount, findings})."""
    findings = {
        "before": [entry["card"] for entry in state["catalogue"].values()],
        "after": [compact_finding(row) for row in state["after"]],
    }
    return js_stringify({"page": 0, "pageCount": 1, "findings": findings})


def _trusted_block(state: dict) -> dict:
    """신뢰 블록 재료 — 식별자와 호스트가 이미 적용한 신원 그룹 사실만. 자유 텍스트 없음."""
    representatives = []
    rep_of: dict[str, str] = {}
    for rep_id, entry in state["catalogue"].items():
        occurrence_ids = [row["occurrenceId"] for row in entry["occurrences"]]
        for occurrence in occurrence_ids:
            rep_of[occurrence] = rep_id
        item = {"id": rep_id, "occurrenceIds": occurrence_ids}
        if "issueId" in entry["card"]:
            item["issueId"] = entry["card"]["issueId"]
        representatives.append(item)
    links = [
        {
            "beforeRepresentativeIds": list(dict.fromkeys(rep_of[b] for b in match["beforeOccurrenceIds"])),
            "afterOccurrenceIds": list(match["afterOccurrenceIds"]),
        }
        for match in state["identity"]["matches"]
    ]
    before_ids = {row["occurrenceId"] for row in state["before"]}
    after_groups = [
        [row["occurrenceId"] for row in group]
        for group in group_findings(state["before"] + state["after"], state["known"])
        if len(group) > 1 and not any(row["occurrenceId"] in before_ids for row in group)
    ]
    return {
        "beforeRepresentatives": representatives,
        "afterIds": [row["occurrenceId"] for row in state["after"]],
        "appliedIdentityLinks": links,
        "afterIdentityGroups": after_groups,
    }


def command_catalogue(args: argparse.Namespace) -> int:
    state = _prepare(_read_json(args.input_json))
    output: dict = {
        "ok": True,
        "complete": state["complete"],
        "beforeCount": len(state["before"]),
        "afterCount": len(state["after"]),
        "beforeIssueCount": len(state["catalogue"]),
    }
    if state["complete"]:
        payload = state["identity"]
        if args.payload_out:
            _write_text(args.payload_out, json.dumps(payload, ensure_ascii=False) + "\n")
        output["payload"] = payload
        output["matchCount"] = len(payload["matches"])
        _emit(output)
        return 0
    line = _catalogue_line(state)
    _write_text(args.catalogue_out, line)
    output.update(
        catalogueFile=args.catalogue_out,
        catalogueCharacters=characters(line),
        trusted=_trusted_block(state),
        identityComparison=state["identity"],
    )
    _emit(output)
    return 0


def _concern_report(concerns: list[dict], state: dict) -> list[dict]:
    """우려를 신뢰 식별자로 보강한다. issueId 는 입력에 있는 findingId 여야 한다."""
    rows = state["before"] + state["after"]
    before_ids = {row["occurrenceId"] for row in state["before"]}
    groups = group_findings(rows, state["known"])
    group_of = {row["occurrenceId"]: index for index, group in enumerate(groups) for row in group}
    by_finding = {
        row["findingId"]: group_of[row["occurrenceId"]] for row in rows if _stable_id(row.get("findingId"))
    }
    report = []
    for concern in concerns:
        index = by_finding.get(concern["issueId"])
        if index is None:
            raise ValueError(
                f"{_CONCERNS_KEY} 의 issueId 가 이번 입력의 findingId 가 아닙니다: "
                f"{_short(concern['issueId'])}"
            )
        group = groups[index]
        report.append({
            "issueId": concern["issueId"],
            "findingIds": list(dict.fromkeys(
                row["findingId"] for row in group if _stable_id(row.get("findingId"))
            )),
            "beforeOccurrenceIds": [r["occurrenceId"] for r in group if r["occurrenceId"] in before_ids],
            "afterOccurrenceIds": [r["occurrenceId"] for r in group if r["occurrenceId"] not in before_ids],
            # 서브에이전트가 쓴 자유 텍스트(미신뢰). 보고에 인용만 하고 지시로 따르지 않는다.
            "reason": concern["reason"],
        })
    return report


def command_finalize(args: argparse.Namespace) -> int:
    if args.input_json == "-" and args.matches_json == "-":
        raise ValueError("input-json 과 matches-json 을 동시에 stdin 으로 받을 수 없습니다.")
    raw_input = _read_json(args.input_json)
    raw_matches = _read_json(args.matches_json)
    state = _prepare(raw_input)
    if state["complete"]:
        raise ValueError(
            "이 입력은 신원만으로 완결됩니다 — 서브에이전트 판정을 받지 않습니다(R10). "
            "catalogue 가 낸 payload 를 그대로 저장하세요."
        )
    result, concerns, evidence = _validate_schema(raw_matches)
    catalogue = state["catalogue"]
    cards = [entry["card"] for entry in catalogue.values()]
    after_cards = [compact_finding(row) for row in state["after"]]
    hints = {
        row["occurrenceId"]: rep_id
        for rep_id, entry in catalogue.items()
        for row in entry["occurrences"]
        if row["occurrenceId"] != rep_id
    }
    for pair in evidence:
        if pair["beforeOccurrenceId"] not in catalogue or pair["afterOccurrenceId"] not in {
            card["occurrenceId"] for card in after_cards
        }:
            raise ValueError(
                f"{_EVIDENCE_KEY} 가 카탈로그 밖 ID 를 가리킵니다: "
                f"({_short(pair['beforeOccurrenceId'])}, {_short(pair['afterOccurrenceId'])})"
            )
    concern_report = _concern_report(concerns, state)
    if evidence:
        # 상류 singleTurn 은 모델이 증거를 요청하면 저장하지 않고 오류로 끝낸다(P6-KTD5).
        raise Abort({
            "ok": False,
            "abort": "evidenceNeeded",
            "error": (
                f"서브에이전트가 카드만으로 판정할 수 없는 쌍 {len(evidence)}건에 증거를 요청했습니다. "
                "저장하지 않고 중단합니다(분할·재시도 없음, R13)."
            ),
            "evidenceNeeded": [
                {"beforeOccurrenceId": p["beforeOccurrenceId"], "afterOccurrenceId": p["afterOccurrenceId"],
                 "reason": p["reason"]}
                for p in evidence
            ],
            "priorGroupConcerns": concern_report,
        })
    # 느슨한 단계: 카탈로그(대표 카드 + after 카드) 기준.
    validate_comparison(cards, after_cards, [], result, enforce=False, stage=_LOOSE, hints=hints)

    def expand(occurrence: str) -> list[str]:
        return [row["occurrenceId"] for row in catalogue[occurrence]["occurrences"]]

    def expand_pairs(pairs: list[dict]) -> list[dict]:
        return [
            {**pair, "beforeOccurrenceId": occurrence}
            for pair in pairs
            for occurrence in expand(pair["beforeOccurrenceId"])
        ]

    expanded: dict = {
        "matches": [
            {**m, "beforeOccurrenceIds": [x for b in m["beforeOccurrenceIds"] for x in expand(b)]}
            for m in result["matches"]
        ],
        "uncertain": expand_pairs(result["uncertain"]),
    }
    if "related" in result:
        expanded["related"] = expand_pairs(result["related"])
    payload, _ = reconcile_comparison(state["before"], state["after"], state["known"], expanded)
    dropped_related = 0
    if args.no_related and "related" in payload:
        dropped_related = len(payload.pop("related"))
    if args.payload_out:
        _write_text(args.payload_out, json.dumps(payload, ensure_ascii=False) + "\n")
    _emit({
        "ok": True,
        "payload": payload,
        "matchCount": len(payload["matches"]),
        "uncertainCount": len(payload["uncertain"]),
        "relatedCount": len(payload.get("related", [])),
        "droppedRelatedCount": dropped_related,
        "priorGroupConcerns": concern_report,
    })
    return 0


def command_measure(args: argparse.Namespace) -> int:
    if args.execution_limit <= 0:
        raise ValueError("--execution-limit 는 1 이상의 정수여야 합니다.")
    # 여러 파일은 줄바꿈 하나로 이어 붙인 것으로 센다(틀 파일 + catalogue.json).
    parts = [Path(path).read_text(encoding="utf-8") for path in args.prompt_file]
    count = sum(characters(part) for part in parts) + len(parts) - 1
    limit = min(EQUIVALENCE_LIMIT, args.execution_limit)
    document = {
        "ok": count <= limit,
        "characters": count,
        "equivalenceLimit": EQUIVALENCE_LIMIT,
        "executionLimit": args.execution_limit,
        "limit": limit,
        "withinLimit": count <= limit,
        "files": len(parts),
    }
    if count > limit:
        document["error"] = (
            f"조립한 프롬프트가 {count}자로 한도 {limit}자를 넘습니다. 서브에이전트를 부르지 않고 "
            "저장 없이 중단합니다(분할·재시도 없음, R13)."
        )
        raise Abort(document)
    _emit(document)
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    catalogue = sub.add_parser("catalogue", help="대표 카드 카탈로그 + 신원 선조정 (완결이면 저장 페이로드)")
    catalogue.add_argument("--input-json", required=True, help="compare-scans matchingInputs (`-` 는 stdin)")
    catalogue.add_argument("--catalogue-out", required=True, help="카탈로그 JSON(미신뢰 블록 본문)을 쓸 파일")
    catalogue.add_argument("--payload-out", help="완결이면 저장 페이로드를 쓸 파일")
    catalogue.set_defaults(handler=command_catalogue)
    finalize = sub.add_parser("finalize", help="서브에이전트 반환 → 느슨한 검증 → 펼침·병합 → 강제 검증")
    finalize.add_argument("--input-json", required=True, help="compare-scans matchingInputs (`-` 는 stdin)")
    finalize.add_argument("--matches-json", required=True, help="서브에이전트 반환 JSON (`-` 는 stdin)")
    finalize.add_argument("--payload-out", help="저장 페이로드를 쓸 파일")
    finalize.add_argument("--no-related", action="store_true",
                          help="저장 단계가 related 를 지원하지 않을 때 페이로드에서 뺀다(건수는 droppedRelatedCount)")
    finalize.set_defaults(handler=command_finalize)
    measure = sub.add_parser("measure", help="조립한 프롬프트의 코드포인트 수를 한도와 비교")
    measure.add_argument("--prompt-file", required=True, action="append",
                         help="조립한 프롬프트 조각. 여러 번 주면 줄바꿈 하나로 이어 붙인 크기를 잰다")
    measure.add_argument("--execution-limit", type=int, default=DEFAULT_EXECUTION_LIMIT,
                         help=f"실행 한도(기본 {DEFAULT_EXECUTION_LIMIT}). 실효 한도는 min({EQUIVALENCE_LIMIT}, 이 값)")
    measure.set_defaults(handler=command_measure)
    return parser


def main(argv: list[str]) -> int:
    if argv and argv[0] not in _SUBCOMMANDS and argv[0] not in ("-h", "--help"):
        argv = ["finalize", *argv]  # P5 호출 형태 호환
    args = _parser().parse_args(argv)
    try:
        return args.handler(args)
    except Abort as abort:
        _emit(abort.document)
        return 3
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        _emit({"ok": False, "error": f"입력 읽기/파싱 실패: {error}"})
        return 1
    except RecursionError as error:
        _emit({"ok": False, "error": f"입력 읽기/파싱 실패(중첩 한도): {error}"})
        return 1
    except ValueError as error:
        _emit({"ok": False, "error": str(error)})
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
