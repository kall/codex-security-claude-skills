#!/usr/bin/env python3
"""매칭 판정 사전 검증기 (Phase 4 U1 / Phase 5 U2).

격리 서브에이전트가 반환한 매칭 JSON을 `save-scan-comparison` 저장 전에 검증한다.
정본은 `sdk/typescript/src/scan-comparison.ts` 의 `comparisonSchema` +
`validateComparison()` + `unionFindingGroups()` 다. 상류 저장 단계(플러그인의
`workbench_scan_history.py`)는 이보다 느슨하므로, **엄격한 TS 계층을 기준으로**
규칙을 재현한다(P5-KTD4: 판정 규칙은 SKILL.md, 검증 규칙은 이 코드가 소유).

스키마(모든 객체는 TS `.strict()` — 키 집합이 정확히 일치해야 한다):
  { "matches":   [{ "beforeOccurrenceIds": [str≥1], "afterOccurrenceIds": [str≥1],
                     "confidence": "high", "reason": str }],
    "uncertain": [{ "beforeOccurrenceId": str, "afterOccurrenceId": str, "reason": str }],
    "related"?:  [{ "beforeOccurrenceId": str, "afterOccurrenceId": str, "reason": str }] }
  - 최상위 허용 키는 `matches`/`uncertain`/`related` 뿐이며 앞의 둘은 필수다.
  - `reason` 은 세 곳 모두 **필수**이고 공백만으로 이루어질 수 없다.

규칙(TS `validateComparison` 순서 그대로):
  1. matches 의 각 occurrenceId 는 매칭 입력의 before/after 집합에 존재해야 한다(미지 거부).
  2. 확정 매칭에서 각 before/after occurrenceId 는 **1회만** 사용(중복 거부).
  3. 기확정 finding 그룹(`knownFindingGroups` + 각 `findingId` 싱글턴을 union-find 로 병합)과
     모순되면 거부 — 한 확정 그룹의 발생들이 서로 다른 매칭 그룹으로 흩어지거나,
     그룹이 before·after 양쪽에 있는데 미매칭 발생이 남는 경우.
     **상류 저장 단계는 이 검사를 하지 않으므로 이 검증기가 유일한 방어선이다.**
  4. uncertain 의 before 는 알려져 있고 **아직 확정 매칭되지 않아야** 한다.
  5. uncertain 의 after 는 알려져 있고 **아직 확정 매칭되지 않아야** 한다.
  6. 중복 uncertain 쌍 거부.
  7. related 의 양쪽 식별자는 알려져 있어야 하고, before 가 속한 확정 매칭 그룹이
     after 의 것과 같으면 거부하며, uncertain 쌍·다른 related 쌍과 중복되면 거부.

입력:
  --input-json   compare-scans --include-matching-inputs 의 matchingInputs
                 (before/after 배열 — 각 원소에 `occurrenceId`, 선택적으로 `findingId`;
                 선택 키 `knownFindingGroups` = findingId 배열의 배열). `-` 는 stdin.
  --matches-json 서브에이전트가 반환한 매칭 JSON. `-` 는 stdin(단, input-json 과 동시에 stdin 금지).

상류 TS 에는 `allowHistoricalUncertainty` 옵션이 있지만 이 검증기는 제공하지 않는다.
그 옵션은 상류 `scans match` 의 **다중 before-scan** 흐름에서만 쓰이고, 거기서도 저장
직전에 쌍 단위로 다시 강제된다. 반면 상류 저장 단계(`workbench_scan_history.py`
save_scan_comparison)는 `pair[1] in consumed["after"]` 를 **무조건** 거부한다 —
대응 옵션이 없다. 이 스킬은 항상 단일 before/after 쌍만 다루므로, 그 완화를 제공하면
"검증 통과"가 저장 가능을 뜻하지 않는 페이로드를 만들어 낸다(실측 확인). 이 검증기의
존재 이유가 그 신호이므로 옵션을 두지 않는다.

성공 시 exit 0 + `{"ok": true}`, 위반 시 exit 1 + `{"ok": false, "error": ...}`.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_TOP_LEVEL_KEYS = {"matches", "uncertain", "related"}
# 서브에이전트가 기확정 그룹이 틀렸다고 판단했을 때 담는 필드. 저장 대상이 아니라
# 중단 신호이므로, 실려 있으면 통과시키지 않고 명시적으로 거부한다 — 이 필드를
# 미지 키로 뭉개면 "왜 거부됐는지"가 사라져 부모가 우회를 시도하게 된다.
_BLOCKED_KEY = "blockedByPriorGroup"
_MATCH_KEYS = {"beforeOccurrenceIds", "afterOccurrenceIds", "confidence", "reason"}
_PAIR_KEYS = {"beforeOccurrenceId", "afterOccurrenceId", "reason"}


def _read(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text(encoding="utf-8")


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


def _occurrences(container: object, key: str) -> tuple[set[str], dict[str, str]]:
    """매칭 입력의 한쪽(before/after)에서 occurrenceId 집합과 findingId 대응을 모은다."""
    rows = container.get(key) if isinstance(container, dict) else None
    if not isinstance(rows, list):
        raise ValueError(f"매칭 입력에 '{key}' 배열이 없습니다.")
    ids: set[str] = set()
    finding_ids: dict[str, str] = {}
    for index, row in enumerate(rows):
        # 조용히 건너뛰면 식별자 우주가 줄어들어 기확정 그룹 검사가 상류보다
        # 약해진다 — 상류 TS 는 모든 원소를 무조건 담으므로, 부분적으로 망가진
        # 입력에서 "우리는 통과, 상류는 거부"가 된다(실측). 명확히 실패시킨다.
        if not isinstance(row, dict) or not isinstance(row.get("occurrenceId"), str):
            raise ValueError(
                f"매칭 입력 '{key}'[{index}] 에 문자열 occurrenceId 가 없습니다: "
                f"{_safe_repr(row)}"
            )
        occurrence_id = row["occurrenceId"]
        ids.add(occurrence_id)
        if isinstance(row.get("findingId"), str):
            finding_ids[occurrence_id] = row["findingId"]
    return ids, finding_ids


def _known_finding_groups(container: object) -> list[list[str]]:
    """선택 키 `knownFindingGroups` 를 읽는다(없으면 빈 목록 — R11: 있어도 중단하지 않는다)."""
    groups = container.get("knownFindingGroups") if isinstance(container, dict) else None
    if groups is None:
        return []
    if not isinstance(groups, list) or not all(
        isinstance(group, list) and all(isinstance(item, str) for item in group)
        for group in groups
    ):
        raise ValueError("knownFindingGroups 는 문자열 배열의 배열이어야 합니다.")
    return [list(group) for group in groups]


def _union_finding_groups(groups: list[list[str]]) -> list[list[str]]:
    """TS `unionFindingGroups` 재현 — findingId 그룹들을 union-find 로 병합한다."""
    parents: dict[str, str] = {}

    def representative(identity: str) -> str:
        root = identity
        while parents[root] != root:
            root = parents[root]
        current = identity
        while parents[current] != root:
            parents[current], current = root, parents[current]
        return root

    for group in groups:
        if not group:
            continue
        first, rest = group[0], group[1:]
        parents.setdefault(first, first)
        first_root = representative(first)
        for identity in rest:
            parents.setdefault(identity, identity)
            parents[representative(identity)] = first_root

    united: dict[str, list[str]] = {}
    for identity in list(parents):
        united.setdefault(representative(identity), []).append(identity)
    return list(united.values())


def _non_blank(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _validate_pairs(rows: object, label: str) -> list[dict]:
    if not isinstance(rows, list):
        raise ValueError(f"{label} 이 배열이 아닙니다(스키마 위반).")
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError(f"{label} 원소가 객체가 아닙니다.")
        if set(row) != _PAIR_KEYS:
            raise ValueError(
                f"{label} 원소의 키는 정확히 {sorted(_PAIR_KEYS)} 여야 합니다: {sorted(row)}"
            )
        if not all(_non_blank(value) for value in row.values()):
            raise ValueError(f"{label} 원소의 세 값은 모두 공백이 아닌 문자열이어야 합니다.")
    return rows


def _validate_schema(data: object) -> dict:
    if not isinstance(data, dict):
        raise ValueError("매칭 결과 최상위가 객체가 아닙니다.")
    if _BLOCKED_KEY in data:
        raise ValueError(
            f"서브에이전트가 {_BLOCKED_KEY} 를 반환했습니다 — 기확정 그룹이 틀렸다는 신고이며 "
            "저장 대상이 아닙니다. 이 필드를 지우고 통과시키지 말고, 근원 비교를 다시 판정하거나 "
            "매칭 저장을 중단하고 사유를 보고하세요(SKILL.md 「기확정 그룹이 틀렸다고 판단될 때」). "
            # 이 값은 미신뢰 저장소 내용을 읽은 서브에이전트가 채운 자유 텍스트다.
            f"신고 내용: {_safe_repr(data[_BLOCKED_KEY])}"
        )
    unknown = set(data) - _TOP_LEVEL_KEYS
    if unknown:
        raise ValueError(f"매칭 결과에 허용되지 않은 최상위 키가 있습니다: {sorted(unknown)}")
    matches = data.get("matches")
    if not isinstance(matches, list) or not isinstance(data.get("uncertain"), list):
        raise ValueError("matches / uncertain 이 배열이 아닙니다(스키마 위반).")
    for m in matches:
        if not isinstance(m, dict):
            raise ValueError("matches 원소가 객체가 아닙니다.")
        if set(m) != _MATCH_KEYS:
            raise ValueError(
                f"matches 원소의 키는 정확히 {sorted(_MATCH_KEYS)} 여야 합니다: {sorted(m)}"
            )
        b = m["beforeOccurrenceIds"]
        a = m["afterOccurrenceIds"]
        if not (isinstance(b, list) and b and all(isinstance(x, str) for x in b)):
            raise ValueError("beforeOccurrenceIds 는 비어 있지 않은 문자열 배열이어야 합니다.")
        if not (isinstance(a, list) and a and all(isinstance(x, str) for x in a)):
            raise ValueError("afterOccurrenceIds 는 비어 있지 않은 문자열 배열이어야 합니다.")
        if m["confidence"] != "high":
            raise ValueError("confidence 는 리터럴 'high' 여야 합니다(TS 스키마).")
        if not _non_blank(m["reason"]):
            raise ValueError("matches 의 reason 은 공백이 아닌 문자열이어야 합니다.")
    _validate_pairs(data.get("uncertain"), "uncertain")
    _validate_pairs(data.get("related", []), "related")
    return data


def _check_confirmed_groups(
    matched_before: dict[str, int],
    matched_after: dict[str, int],
    before_ids: set[str],
    after_ids: set[str],
    finding_ids: dict[str, str],
    known_groups: list[list[str]],
) -> None:
    """기확정 finding 그룹과의 모순을 검사한다(TS validateComparison 중단부 재현)."""
    confirmed = _union_finding_groups(
        known_groups + [[finding_id] for finding_id in dict.fromkeys(finding_ids.values())]
    )
    for group in confirmed:
        members = set(group)
        known_before = [occ for occ in before_ids if finding_ids.get(occ, "") in members]
        known_after = [occ for occ in after_ids if finding_ids.get(occ, "") in members]
        matched_groups = {
            matched_before.get(occ, matched_after.get(occ))
            for occ in (*known_before, *known_after)
        }
        if len(matched_groups) > 1 or (
            known_before and known_after and None in matched_groups
        ):
            raise ValueError(
                f"기확정 finding 그룹과 모순되는 매칭입니다: {sorted(members)}"
            )


def validate(
    matches_doc: dict,
    before_ids: set[str],
    after_ids: set[str],
    finding_ids: dict[str, str],
    known_groups: list[list[str]],
) -> None:
    """매칭 페이로드를 상류 TS 판정 규칙 기준으로 검증한다(위반 시 ValueError).

    `finding_ids` 와 `known_groups` 는 **필수**다. 기본값을 두면 호출자가 빠뜨렸을 때
    기확정 그룹 검사가 조용히 건너뛰어지고, 그러면 검증기를 통과했다는 사실이
    "모순 없음을 확인했다"는 뜻이 아니게 된다.
    """
    matched_before: dict[str, int] = {}
    matched_after: dict[str, int] = {}

    for group, match in enumerate(matches_doc["matches"]):
        for side, values, expected, used in (
            ("before", match["beforeOccurrenceIds"], before_ids, matched_before),
            ("after", match["afterOccurrenceIds"], after_ids, matched_after),
        ):
            for occ in values:
                if occ not in expected:
                    raise ValueError(f"미지의 {side} occurrence 를 참조했습니다: {occ}")
                if occ in used:
                    raise ValueError(f"{side} occurrence 가 두 번 이상 매칭되었습니다: {occ}")
                used[occ] = group

    _check_confirmed_groups(
        matched_before,
        matched_after,
        before_ids,
        after_ids,
        finding_ids,
        known_groups,
    )

    uncertain_pairs: set[tuple[str, str]] = set()
    for cand in matches_doc["uncertain"]:
        b = cand["beforeOccurrenceId"]
        a = cand["afterOccurrenceId"]
        if (
            b not in before_ids
            or b in matched_before
            or a not in after_ids
            or a in matched_after
        ):
            raise ValueError(f"유효하지 않은 uncertain 쌍입니다: ({b}, {a})")
        pair = (b, a)
        if pair in uncertain_pairs:
            raise ValueError(f"중복된 uncertain 쌍입니다: ({b}, {a})")
        uncertain_pairs.add(pair)

    related_pairs: set[tuple[str, str]] = set()
    for cand in matches_doc.get("related", []):
        b = cand["beforeOccurrenceId"]
        a = cand["afterOccurrenceId"]
        pair = (b, a)
        before_group = matched_before.get(b)
        if (
            b not in before_ids
            or a not in after_ids
            or (before_group is not None and before_group == matched_after.get(a))
            or pair in uncertain_pairs
            or pair in related_pairs
        ):
            raise ValueError(f"유효하지 않은 related 쌍입니다: ({b}, {a})")
        related_pairs.add(pair)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-json", required=True, help="compare-scans matchingInputs (before/after)")
    parser.add_argument("--matches-json", required=True, help="서브에이전트 반환 매칭 JSON")
    args = parser.parse_args(argv)

    if args.input_json == "-" and args.matches_json == "-":
        print(json.dumps({"ok": False, "error": "input-json 과 matches-json 을 동시에 stdin 으로 받을 수 없습니다."}, ensure_ascii=False))
        return 1
    try:
        raw_input = json.loads(_read(args.input_json))
        raw_matches = json.loads(_read(args.matches_json))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        print(json.dumps({"ok": False, "error": f"입력 읽기/파싱 실패: {error}"}, ensure_ascii=False))
        return 1

    # matchingInputs 는 {before:[...], after:[...]} 또는 {matchingInputs:{before,after}} 형태일 수 있다.
    container = raw_input.get("matchingInputs") if isinstance(raw_input, dict) and "matchingInputs" in raw_input else raw_input
    try:
        before_ids, before_finding_ids = _occurrences(container, "before")
        after_ids, after_finding_ids = _occurrences(container, "after")
        known_groups = _known_finding_groups(container)
        matches_doc = _validate_schema(raw_matches)
        validate(
            matches_doc,
            before_ids,
            after_ids,
            {**before_finding_ids, **after_finding_ids},
            known_groups,
        )
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1

    print(json.dumps({
        "ok": True,
        "matchCount": len(matches_doc["matches"]),
        "uncertainCount": len(matches_doc["uncertain"]),
        "relatedCount": len(matches_doc.get("related", [])),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
