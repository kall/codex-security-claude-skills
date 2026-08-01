#!/usr/bin/env python3
"""매칭 판정 사전 검증기 (Phase 4 U1).

격리 서브에이전트가 반환한 매칭 JSON을 `save-scan-comparison` 저장 전에 검증한다.
`sdk/typescript/src/scan-comparison.ts` 의 `validateComparison` 규칙을 그대로 재현한다:

스키마:
  { "matches":   [{ "beforeOccurrenceIds": [str≥1], "afterOccurrenceIds": [str≥1],
                     "confidence": "high", "reason"?: str }],
    "uncertain": [{ "beforeOccurrenceId": str, "afterOccurrenceId": str, "reason"?: str }] }

규칙:
  - matches 의 각 occurrenceId 는 매칭 입력의 before/after 집합에 존재해야 한다(미지 거부).
  - 확정 매칭에서 각 before/after occurrenceId 는 **1회만** 사용(중복 거부).
  - uncertain 의 before 는 알려져 있고 **아직 확정 매칭되지 않아야** 한다.
  - uncertain 의 after 는 알려져 있고, `--allow-historical` 이 아니면 **아직 확정 매칭되지 않아야** 한다.
  - 중복 uncertain 쌍 거부.

입력:
  --input-json   compare-scans --include-matching-inputs 의 matchingInputs (before/after 배열,
                 각 원소에 occurrenceId). `-` 는 stdin.
  --matches-json 서브에이전트가 반환한 매칭 JSON. `-` 는 stdin(단, input-json 과 동시에 stdin 금지).
  --allow-historical  uncertain 의 after 가 이미 확정 매칭된 경우도 허용(TS allowHistoricalUncertainty).

성공 시 exit 0 + `{"ok": true}`, 위반 시 exit 1 + `{"ok": false, "error": ...}`.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _read(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text(encoding="utf-8")


def _occurrence_ids(container: dict, key: str) -> set[str]:
    rows = container.get(key)
    if not isinstance(rows, list):
        raise ValueError(f"매칭 입력에 '{key}' 배열이 없습니다.")
    ids: set[str] = set()
    for row in rows:
        if isinstance(row, dict) and isinstance(row.get("occurrenceId"), str):
            ids.add(row["occurrenceId"])
    return ids


def _validate_schema(data: object) -> dict:
    if not isinstance(data, dict):
        raise ValueError("매칭 결과 최상위가 객체가 아닙니다.")
    matches = data.get("matches")
    uncertain = data.get("uncertain")
    if not isinstance(matches, list) or not isinstance(uncertain, list):
        raise ValueError("matches / uncertain 이 배열이 아닙니다(스키마 위반).")
    for m in matches:
        if not isinstance(m, dict):
            raise ValueError("matches 원소가 객체가 아닙니다.")
        b = m.get("beforeOccurrenceIds")
        a = m.get("afterOccurrenceIds")
        if not (isinstance(b, list) and b and all(isinstance(x, str) for x in b)):
            raise ValueError("beforeOccurrenceIds 는 비어 있지 않은 문자열 배열이어야 합니다.")
        if not (isinstance(a, list) and a and all(isinstance(x, str) for x in a)):
            raise ValueError("afterOccurrenceIds 는 비어 있지 않은 문자열 배열이어야 합니다.")
        if m.get("confidence") != "high":
            raise ValueError("confidence 는 리터럴 'high' 여야 합니다(TS 스키마).")
    for u in uncertain:
        if not isinstance(u, dict):
            raise ValueError("uncertain 원소가 객체가 아닙니다.")
        if not isinstance(u.get("beforeOccurrenceId"), str) or not isinstance(
            u.get("afterOccurrenceId"), str
        ):
            raise ValueError("uncertain 은 beforeOccurrenceId/afterOccurrenceId 문자열이 필요합니다.")
    return data


def validate(matches_doc: dict, before_ids: set[str], after_ids: set[str], allow_historical: bool) -> None:
    matched_before: set[str] = set()
    matched_after: set[str] = set()

    for match in matches_doc["matches"]:
        for side, values, expected, used in (
            ("before", match["beforeOccurrenceIds"], before_ids, matched_before),
            ("after", match["afterOccurrenceIds"], after_ids, matched_after),
        ):
            for occ in values:
                if occ not in expected:
                    raise ValueError(f"미지의 {side} occurrence 를 참조했습니다: {occ}")
                if occ in used:
                    raise ValueError(f"{side} occurrence 가 두 번 이상 매칭되었습니다: {occ}")
                used.add(occ)

    seen_pairs: set[tuple[str, str]] = set()
    for cand in matches_doc["uncertain"]:
        b = cand["beforeOccurrenceId"]
        a = cand["afterOccurrenceId"]
        if (
            b not in before_ids
            or b in matched_before
            or a not in after_ids
            or (not allow_historical and a in matched_after)
        ):
            raise ValueError(f"유효하지 않은 uncertain 쌍입니다: ({b}, {a})")
        pair = (b, a)
        if pair in seen_pairs:
            raise ValueError(f"중복된 uncertain 쌍입니다: ({b}, {a})")
        seen_pairs.add(pair)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-json", required=True, help="compare-scans matchingInputs (before/after)")
    parser.add_argument("--matches-json", required=True, help="서브에이전트 반환 매칭 JSON")
    parser.add_argument("--allow-historical", action="store_true")
    args = parser.parse_args(argv)

    if args.input_json == "-" and args.matches_json == "-":
        print(json.dumps({"ok": False, "error": "input-json 과 matches-json 을 동시에 stdin 으로 받을 수 없습니다."}, ensure_ascii=False))
        return 1
    try:
        raw_input = json.loads(_read(args.input_json))
        raw_matches = json.loads(_read(args.matches_json))
    except (OSError, json.JSONDecodeError) as error:
        print(json.dumps({"ok": False, "error": f"입력 읽기/파싱 실패: {error}"}, ensure_ascii=False))
        return 1

    # matchingInputs 는 {before:[...], after:[...]} 또는 {matchingInputs:{before,after}} 형태일 수 있다.
    container = raw_input.get("matchingInputs") if isinstance(raw_input, dict) and "matchingInputs" in raw_input else raw_input
    try:
        before_ids = _occurrence_ids(container, "before")
        after_ids = _occurrence_ids(container, "after")
        matches_doc = _validate_schema(raw_matches)
        validate(matches_doc, before_ids, after_ids, args.allow_historical)
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1

    print(json.dumps({
        "ok": True,
        "matchCount": len(matches_doc["matches"]),
        "uncertainCount": len(matches_doc["uncertain"]),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
