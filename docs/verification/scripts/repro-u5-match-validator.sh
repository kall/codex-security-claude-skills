#!/usr/bin/env bash
# U5 재현 스크립트: 매칭 검증기(validate_matches.py)가 상류 0.1.29~0.4.0 호스트 조정
# (sdk/typescript/src/scan-comparison.ts 의 matchScanFindingsInternal /
#  reconcileComparison / validateComparison, finding-catalogue.ts 의 groupFindings /
#  findingCatalogue / compactFinding) 을 그대로 재현하는지 자기 채점한다.
#
#   A~Q  기존 형태의 회귀 — 느슨한 단계 거부 규칙과 입력·오류 봉투 방어
#   R    상류 테스트에서 옮긴 픽스처(docs/verification/fixtures/scan-match/*.json)
#   S    상류 dist 실측 대조 — 가짜 codex 로 matchScanFindingsInternal 을 돌린 결과와 비교
#   T    프롬프트 한도 측정(measure) — 동등성 한도와 실행 한도
#   U    워크벤치 왕복 — 봉인 스캔 3개로 catalogue → finalize → save-scan-comparison
#   V    0.4.0 정합 — validateComparison 강제 분기 삭제(2b759675b)와 병합에 의한 모순 해소
#
# 종료코드: 0 = 전부 통과 / 2 = INCOMPLETE(전제 부족: node·상류 dist·플러그인 없음) / 1 = 단언 실패.
# exit 2 는 통과가 아니다.
#
# 사용법: bash repro-u5-match-validator.sh
#   PYTHON=<python3>  NODE=<node>  CODEX_SECURITY_PLUGIN_DIR=<_bundled_plugin 경로>
#   (플러그인 경로를 주지 않으면 `npm root -g` 의 @openai/codex-security 를 찾는다.
#    상류 dist 는 그 패키지의 dist/ 이다.)
set -u -o pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# cd 실패로 WORK가 비면 아래 rm -rf 가 루트 수준 경로를 지운다. set -u 는
# set-but-empty 에 발동하지 않으므로 명시적으로 가드한다.
: "${WORK:?WORK 경로 해석 실패 — 중단}"
# 검증 대상: 이 저장소의 매칭 검증기(스크립트 위치 기준 상대 경로).
VALIDATOR="${CODEX_SECURITY_MATCH_VALIDATOR:-$WORK/../../../skills/codex-security-scan-match/scripts/validate_matches.py}"
if [ ! -f "$VALIDATOR" ]; then
  echo "오류: 검증기를 찾지 못했습니다: $VALIDATOR" >&2
  exit 1
fi

# 픽스처·산출물은 저장소 밖 임시 디렉터리에 쓴다(레포 오염 방지).
RUN="$(mktemp -d)"
# mktemp 실패로 RUN 이 비면 아래 픽스처 쓰기가 `/input.json` 처럼 루트로 향한다.
# set -u 는 set-but-empty 에 발동하지 않으므로 명시적으로 가드한다.
: "${RUN:?임시 디렉터리 생성 실패 — 중단}"
trap 'rm -rf "$RUN"' EXIT

# 스킬 디렉터리에 __pycache__ 를 남기지 않는다 (레포는 읽기 전용으로 유지).
export PYTHONDONTWRITEBYTECODE=1

# Python: PYTHON 환경변수 → python3 → python. 버전 매니저 환경이면
#   PYTHON="$(mise which python3)" bash repro-u5-match-validator.sh
PYTHON_BIN="${PYTHON:-$(command -v python3 || command -v python)}"
: "${PYTHON_BIN:?Python 3.10+ 인터프리터를 찾지 못했습니다. PYTHON=<경로> 로 지정하세요.}"
PY() { "$PYTHON_BIN" "$@"; }

FAILED=0
step() { printf '\n=== %s ===\n' "$1"; }
# 형제 스크립트(u1/u4/u7)와 같은 헬퍼를 둔다. 없으면 `ok`/`bad` 를 쓴 단언이
# "명령을 찾을 수 없음"으로 조용히 넘어가 FAILED 를 올리지 않는다(실측).
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }
expect_exit() { # expect_exit <expected> <actual> <label>
  if [ "$2" = "$1" ]; then
    printf 'OK   %s: exit %s (expected %s)\n' "$3" "$2" "$1"
  else
    printf 'FAIL %s: exit %s (expected %s)\n' "$3" "$2" "$1"
    FAILED=$((FAILED + 1))
  fi
}
# 검증기가 exit 1 을 내는 이유는 두 가지다 — 규칙이 거부한 것과, 입력을 읽지
# 못한 것(픽스처 생성 실패·경로 오류). 후자도 `{"ok": false, ...}` 를 내므로
# ok 필드만 봐서는 갈라지지 않는다. 종료코드만 보면 규칙이 한 번도 실행되지
# 않은 채 "정상 거부"로 집계돼 초록불이 된다.
INFRA_ERROR_MARK='입력 읽기/파싱 실패'
# check 는 "거부됐다"만이 아니라 **의도한 규칙이 거부했는가**까지 본다.
# 사유를 보지 않으면 픽스처가 목표 규칙에 도달하기 전에 다른(주로 스키마) 규칙에
# 걸려도 초록불이 된다 — 키 오타 한 글자로 E1b 가 그룹 규칙 대신 키집합 규칙으로
# 통과한 것이 실측됐다. 이번 PR 이 닫으려던 false-green 과 같은 부류다.
# 5번째 인자로 기대 사유(부분문자열)를 주면 그 규칙이 실제로 발동했는지 확인한다.
check() { # check <expected-exit> <label> <input-json> <matches-json> [기대사유] [추가 인자...]
  local expected="$1" label="$2" input="$3" matches="$4" want_reason="${5:-}"
  shift 4
  # 5번째 인자는 **항상** 기대사유로 소비된다. 검증기 플래그를 함께 주려면
  # 사유를 빈 문자열("")로 명시해야 한다 — 그러지 않으면 플래그가 사유로 먹혀
  # 조용히 사라지고 없는 FAIL 이 하나 붙는다.
  [ $# -gt 0 ] && shift
  local out code _out_is_infra _out_has_ok_false
  out="$(PY "$VALIDATOR" finalize --input-json "$input" --matches-json "$matches" "$@" 2>&1)"
  code=$?
  expect_exit "$expected" "$code" "$label"
  # 파이프로 grep -q 에 넘기지 않는다 — grep 이 일치 즉시 종료하면 printf 가
  # SIGPIPE(141)를 받고 pipefail 이 그것을 파이프라인 실패로 만든다(실측). 지금
  # 출력 크기에서는 발동하지 않지만 잠재 함정이므로 case 패턴으로 검사한다.
  case "$out" in
    *"$INFRA_ERROR_MARK"*) _out_is_infra=1 ;;
    *) _out_is_infra=0 ;;
  esac
  case "$out" in
    *'"ok": false'*) _out_has_ok_false=1 ;;
    *) _out_has_ok_false=0 ;;
  esac
  if [ "$_out_is_infra" = 1 ]; then
    printf 'FAIL %s: 규칙 판정이 아니라 입력 읽기 실패입니다 — 이 단언은 아무것도 검증하지 못했습니다\n' "$label"
    FAILED=$((FAILED + 1))
  elif [ "$code" = 1 ] && [ "$_out_has_ok_false" = 0 ]; then
    # 기대값이 아니라 **실제** 종료코드로 갈라야 한다. 기대값으로 갈리면
    # argparse exit 2 나 규칙 미발동(exit 0)에도 "크래시 의심" 오진이 붙는다.
    printf 'FAIL %s: exit 1 이지만 정상 거부 형상("ok": false)이 아닙니다(크래시 의심)\n' "$label"
    FAILED=$((FAILED + 1))
  fi
  # `case` 패턴은 글로브다 — `grep -qF`(고정 문자열)와 달리 `*`·`?`·`[` 가 든
  # 기대 사유는 의미가 조용히 달라진다. 현재 8개 호출부에는 없지만, 앞으로 넣으면
  # 단언이 느슨해지므로 여기서 끊는다. (변수는 인용해 두었으니 패턴 확장은
  # 일어나지 않지만, 그렇기 때문에 오히려 글로브를 의도한 사람이 속는다.)
  case "$want_reason" in
    *'*'*|*'?'*|*'['*)
      printf 'FAIL %s: 기대 사유에 글로브 문자(* ? [)가 있습니다 — case 패턴과 고정 문자열의 의미가 달라집니다: %s\n' \
        "$label" "$want_reason"
      FAILED=$((FAILED + 1)) ;;
  esac
  if [ -n "$want_reason" ] && { case "$out" in *"$want_reason"*) false ;; *) true ;; esac; }; then
    printf 'FAIL %s: 거부는 됐으나 사유가 기대 규칙이 아닙니다(다른 규칙이 먼저 걸렸습니다). 기대: %s\n' \
      "$label" "$want_reason"
    FAILED=$((FAILED + 1))
  fi
  printf '     %s\n' "$out"
}

# assert_json <label> <json 파일> <파이썬 식(d = 문서)> <기대 JSON>
# 식의 값을 정규화(sort_keys)한 JSON 문자열로 비교한다. 파일이 없거나 JSON 이 아니면
# 그 자체로 FAIL 이다 — 값 비교를 건너뛰어 초록불이 되지 않게 한다.
assert_json() {
  local label="$1" file="$2" expr="$3" want="$4" got
  got="$(PY - "$file" "$expr" <<'PYEOF' 2>&1
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError) as error:
    print(f"<읽기 실패: {error}>")
    raise SystemExit(0)
print(json.dumps(eval(sys.argv[2]), ensure_ascii=False, sort_keys=True))
PYEOF
)"
  local norm
  norm="$(PY -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), ensure_ascii=False, sort_keys=True))' "$want")"
  if [ "$got" = "$norm" ]; then
    ok "$label"
  else
    bad "$label — 기대 $norm / 실제 $got"
  fi
}

# 픽스처 생성 실패는 위 검사에 걸리지만, 그때는 이미 "무엇을 검증하려 했는지"가
# 사라진다. 생성 직후 바로 끊어 INCOMPLETE 로 알린다.
need_fixture() { # need_fixture <경로> [경로...]
  local f
  for f in "$@"; do
    if [ ! -s "$f" ]; then
      printf 'INCOMPLETE — 픽스처 생성 실패: %s\n' "$f" >&2
      exit 2
    fi
  done
}

# ---------------------------------------------------------------------------
# 매칭 입력 픽스처 — before/after 각 3건, findingId 는 양쪽이 서로 다르게 둔다
# (같은 findingId 가 양쪽에 있으면 기확정 그룹 규칙이 매칭을 강제하므로).
# ---------------------------------------------------------------------------
cat >"$RUN/input.json" <<'EOF'
{
  "matchingInputs": {
    "before": [
      {"occurrenceId": "b1", "findingId": "f1", "title": "archive extraction path traversal"},
      {"occurrenceId": "b2", "findingId": "f2", "title": "missing authz on admin route"},
      {"occurrenceId": "b3", "findingId": "f3", "title": "log injection"}
    ],
    "after": [
      {"occurrenceId": "a1", "findingId": "g1", "title": "tar extractall without member check"},
      {"occurrenceId": "a2", "findingId": "g2", "title": "admin route lacks role guard"},
      {"occurrenceId": "a3", "findingId": "g3", "title": "unsanitised log record"}
    ]
  }
}
EOF

# f1(before) 과 g1(after) 가 이전 비교에서 같은 finding 으로 확정된 입력.
PY - "$RUN/input.json" "$RUN/input-known-cross.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
data["matchingInputs"]["knownFindingGroups"] = [["f1", "g1"]]
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
EOF
need_fixture "$RUN/input-known-cross.json"

# f1 과 f2(둘 다 before 쪽) 가 같은 finding 으로 확정된 입력.
PY - "$RUN/input.json" "$RUN/input-known-before.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
data["matchingInputs"]["knownFindingGroups"] = [["f1", "f2"]]
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
EOF
need_fixture "$RUN/input-known-before.json"

# ---------------------------------------------------------------------------
# A. 기존 회귀 4종 — 미지 식별자 / 확정 매칭 중복 / uncertain before 기매칭 /
#    confidence 가 high 아님. 새 규칙이 이 판정을 바꾸면 안 된다.
# ---------------------------------------------------------------------------
step "A. 기존 거부 회귀 4종"

cat >"$RUN/bad-unknown-id.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a9"],
     "confidence": "high", "reason": "same root cause"}
  ],
  "uncertain": []
}
EOF
check 1 "A1 미지 after occurrenceId" "$RUN/input.json" "$RUN/bad-unknown-id.json"

cat >"$RUN/bad-duplicate.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "same root cause"},
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a2"],
     "confidence": "high", "reason": "same root cause again"}
  ],
  "uncertain": []
}
EOF
check 1 "A2 before occurrence 중복 확정" "$RUN/input.json" "$RUN/bad-duplicate.json"

# A1·A2 는 after 미지 / before 중복만 덮는다. 반대 축도 규칙이 살아 있는지 본다.
cat >"$RUN/bad-unknown-before.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["nope"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "미지 before 식별자"}
  ],
  "uncertain": []
}
EOF
check 1 "A1b 미지 before occurrenceId" "$RUN/input.json" "$RUN/bad-unknown-before.json" \
  "미지의 before occurrence"

cat >"$RUN/bad-duplicate-after.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "첫 그룹"},
    {"beforeOccurrenceIds": ["b2"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "같은 after 를 재사용"}
  ],
  "uncertain": []
}
EOF
check 1 "A2b after occurrence 중복 확정" "$RUN/input.json" "$RUN/bad-duplicate-after.json" \
  "after occurrence 가 두 번 이상"

cat >"$RUN/bad-empty-ids.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": [], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "빈 before 배열"}
  ],
  "uncertain": []
}
EOF
check 1 "A5 beforeOccurrenceIds 빈 배열" "$RUN/input.json" "$RUN/bad-empty-ids.json" \
  "beforeOccurrenceIds 는 비어 있지 않은"

cat >"$RUN/bad-missing-uncertain.json" <<'EOF'
{
  "matches": []
}
EOF
check 1 "A6 uncertain 키 누락" "$RUN/input.json" "$RUN/bad-missing-uncertain.json" \
  "matches / uncertain 이 배열이 아닙니다"

cat >"$RUN/bad-uncertain-matched.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "same root cause"}
  ],
  "uncertain": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a2", "reason": "maybe"}
  ]
}
EOF
check 1 "A3 uncertain before 가 기매칭" "$RUN/input.json" "$RUN/bad-uncertain-matched.json"

cat >"$RUN/bad-confidence.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "medium", "reason": "same root cause"}
  ],
  "uncertain": []
}
EOF
check 1 "A4 confidence != high" "$RUN/input.json" "$RUN/bad-confidence.json"

# ---------------------------------------------------------------------------
# B. matches[].reason — 누락 / 빈 문자열 / 공백뿐이면 거부 (R7)
# ---------------------------------------------------------------------------
step "B. matches[].reason 비어 있지 않은 문자열 (R7)"

cat >"$RUN/bad-reason-missing.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"], "confidence": "high"}
  ],
  "uncertain": []
}
EOF
check 1 "B1 matches reason 누락" "$RUN/input.json" "$RUN/bad-reason-missing.json"

cat >"$RUN/bad-reason-empty.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": ""}
  ],
  "uncertain": []
}
EOF
check 1 "B2 matches reason 빈 문자열" "$RUN/input.json" "$RUN/bad-reason-empty.json"

cat >"$RUN/bad-reason-blank.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "   \t "}
  ],
  "uncertain": []
}
EOF
check 1 "B3 matches reason 공백뿐" "$RUN/input.json" "$RUN/bad-reason-blank.json"

# ---------------------------------------------------------------------------
# C. 원소 키 집합 — 쌍은 정확히 3키, matches 는 정확히 4키 (TS strict, R8)
# ---------------------------------------------------------------------------
step "C. 원소 키 집합 엄격 검사 (R8)"

cat >"$RUN/bad-pair-extra-key.json" <<'EOF'
{
  "matches": [],
  "uncertain": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a1",
     "reason": "maybe", "note": "extra"}
  ]
}
EOF
check 1 "C1 uncertain 원소 여분 키" "$RUN/input.json" "$RUN/bad-pair-extra-key.json"

cat >"$RUN/bad-pair-missing-key.json" <<'EOF'
{
  "matches": [],
  "uncertain": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a1"}
  ]
}
EOF
check 1 "C2 uncertain 원소 reason 누락" "$RUN/input.json" "$RUN/bad-pair-missing-key.json"

cat >"$RUN/bad-match-extra-key.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "same root cause", "score": 0.9}
  ],
  "uncertain": []
}
EOF
check 1 "C3 matches 원소 여분 키" "$RUN/input.json" "$RUN/bad-match-extra-key.json"

cat >"$RUN/bad-related-extra-key.json" <<'EOF'
{
  "matches": [],
  "uncertain": [],
  "related": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a1",
     "reason": "adjacent", "kind": "related"}
  ]
}
EOF
check 1 "C4 related 원소 여분 키" "$RUN/input.json" "$RUN/bad-related-extra-key.json"

# ---------------------------------------------------------------------------
# D. 최상위 키 허용 집합 — matches/uncertain/related 외 키는 거부 (R8)
# ---------------------------------------------------------------------------
step "D. 최상위 키 허용 집합 (R8)"

cat >"$RUN/bad-top-extra-key.json" <<'EOF'
{
  "matches": [],
  "uncertain": [],
  "notes": "여분 최상위 키"
}
EOF
check 1 "D1 최상위 알 수 없는 키" "$RUN/input.json" "$RUN/bad-top-extra-key.json"

# ---------------------------------------------------------------------------
# E. related 쌍 — before/after 가 같은 확정 매칭 그룹이면 거부 (R9)
# ---------------------------------------------------------------------------
step "E. related 가 같은 확정 매칭 그룹 (R9)"

cat >"$RUN/bad-related-same-group.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "same root cause"}
  ],
  "uncertain": [],
  "related": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a1", "reason": "adjacent"}
  ]
}
EOF
check 1 "E1 related 가 확정 그룹과 동일 쌍" "$RUN/input.json" "$RUN/bad-related-same-group.json" "related 쌍입니다: (b1, a1)"

# E1 은 매칭 쌍과 완전히 같은 쌍이라, 그룹 동일성이 아니라 쌍 동등성만 비교하는
# 잘못된 구현도 통과한다. 다중 occurrence 그룹의 '다른 쌍'으로 그룹 의미를 가른다.
cat >"$RUN/bad-related-crosspair.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1", "b2"], "afterOccurrenceIds": ["a1", "a2"],
     "confidence": "high", "reason": "same root cause"}
  ],
  "uncertain": [],
  "related": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a2", "reason": "adjacent"}
  ]
}
EOF
check 1 "E1b related 가 같은 확정 그룹의 다른 쌍 (그룹 의미 단독 검증)" \
  "$RUN/input.json" "$RUN/bad-related-crosspair.json" "related 쌍입니다: (b1, a2)"

# 대조군: 서로 다른 확정 그룹이면 related 가 허용돼야 한다 — E1b 가 "related 는
# 매칭된 occurrence 를 못 쓴다"로 과잉 해석되지 않았음을 확인한다.
cat >"$RUN/ok-related-crossgroup.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "group one"},
    {"beforeOccurrenceIds": ["b2"], "afterOccurrenceIds": ["a2"],
     "confidence": "high", "reason": "group two"}
  ],
  "uncertain": [],
  "related": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a2", "reason": "다른 그룹 — 인접 이슈"}
  ]
}
EOF
check 0 "E1c 대조군: 서로 다른 확정 그룹의 related 는 통과" \
  "$RUN/input.json" "$RUN/ok-related-crossgroup.json"

cat >"$RUN/bad-related-unknown-id.json" <<'EOF'
{
  "matches": [],
  "uncertain": [],
  "related": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a9", "reason": "adjacent"}
  ]
}
EOF
check 1 "E2 related 미지 after occurrenceId" "$RUN/input.json" "$RUN/bad-related-unknown-id.json"

# ---------------------------------------------------------------------------
# F. related 쌍이 uncertain 쌍과 동일하면 거부 (R9)
# ---------------------------------------------------------------------------
step "F. related == uncertain 쌍 (R9)"

cat >"$RUN/bad-related-eq-uncertain.json" <<'EOF'
{
  "matches": [],
  "uncertain": [
    {"beforeOccurrenceId": "b2", "afterOccurrenceId": "a2", "reason": "maybe"}
  ],
  "related": [
    {"beforeOccurrenceId": "b2", "afterOccurrenceId": "a2", "reason": "adjacent"}
  ]
}
EOF
check 1 "F1 related 가 uncertain 쌍과 동일" "$RUN/input.json" "$RUN/bad-related-eq-uncertain.json"

# ---------------------------------------------------------------------------
# G. related 쌍끼리 중복이면 거부 (R9)
# ---------------------------------------------------------------------------
step "G. related 쌍 중복 (R9)"

cat >"$RUN/bad-related-dup.json" <<'EOF'
{
  "matches": [],
  "uncertain": [],
  "related": [
    {"beforeOccurrenceId": "b3", "afterOccurrenceId": "a3", "reason": "adjacent"},
    {"beforeOccurrenceId": "b3", "afterOccurrenceId": "a3", "reason": "adjacent again"}
  ]
}
EOF
check 1 "G1 related 쌍 중복" "$RUN/input.json" "$RUN/bad-related-dup.json"

# ---------------------------------------------------------------------------
# H. 쌍 원소의 reason 이 공백뿐이면 거부 (R8)
# ---------------------------------------------------------------------------
step "H. 쌍 원소 reason 공백뿐 (R8)"

cat >"$RUN/bad-uncertain-blank-reason.json" <<'EOF'
{
  "matches": [],
  "uncertain": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a1", "reason": "   "}
  ]
}
EOF
check 1 "H1 uncertain reason 공백뿐" "$RUN/input.json" "$RUN/bad-uncertain-blank-reason.json"

cat >"$RUN/bad-related-blank-reason.json" <<'EOF'
{
  "matches": [],
  "uncertain": [],
  "related": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a1", "reason": "\n"}
  ]
}
EOF
check 1 "H2 related reason 공백뿐" "$RUN/input.json" "$RUN/bad-related-blank-reason.json"

# ---------------------------------------------------------------------------
# I. 기확정 그룹은 호스트가 먼저 카드 한 장으로 접는다 (P6-KTD3) — 서브에이전트는
#    대표 카드 ID 로만 판정할 수 있으므로, 접힌 occurrence 를 직접 가리켜 그룹을
#    흩으려는 판정은 느슨한 단계에서 "미지의 before" 로 거부된다. P5 에서는 같은
#    페이로드가 기확정 그룹 모순으로 거부됐다 — 거부 자체는 같고 거부 지점이 앞당겨졌다.
# ---------------------------------------------------------------------------
step "I. 기확정 그룹 선병합 — 접힌 occurrence 로는 그룹을 흩을 수 없다 (P6-KTD3)"

cat >"$RUN/scatter.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "same root cause"},
    {"beforeOccurrenceIds": ["b2"], "afterOccurrenceIds": ["a2"],
     "confidence": "high", "reason": "other root cause"}
  ],
  "uncertain": []
}
EOF
check 1 "I1 f1·f2 확정 그룹의 접힌 occurrence(b1)를 따로 매칭하면 거부" \
  "$RUN/input-known-before.json" "$RUN/scatter.json" "느슨한 단계] 미지의 before occurrence"
# 거부 사유가 대표 카드 ID 를 알려 줘야 재판정이 한 번에 수렴한다.
check 1 "I1b 거부 사유가 대표 카드 ID(b2)를 안내" \
  "$RUN/input-known-before.json" "$RUN/scatter.json" "대표 카드 'b2'"
check 0 "I2 대조군: knownFindingGroups 없으면 같은 페이로드 통과" \
  "$RUN/input.json" "$RUN/scatter.json"

# ---------------------------------------------------------------------------
# J. 신원(같은 findingId·기확정 그룹)만으로 이어진 그룹은 판정에 없어도 저장된다.
#    P5 에서는 "기확정 그룹 양쪽 존재 + 미매칭" 을 거부했다. 0.1.29 는 호스트가
#    그 그룹을 기본 사유 문장으로 직접 채운다(reconcileComparison).
# ---------------------------------------------------------------------------
step "J. 신원 전용 그룹은 기본 사유로 저장되고, 그룹 안 uncertain 은 조용히 빠진다"

cat >"$RUN/no-match.json" <<'EOF'
{
  "matches": [],
  "uncertain": []
}
EOF
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input-known-cross.json" \
  --matches-json "$RUN/no-match.json" --payload-out "$RUN/j1-payload.json" 2>&1)"
expect_exit 0 "$?" "J1 f1·g1 확정 그룹은 판정이 비어도 통과"
printf '     %s\n' "$out"
assert_json "J1b 저장 페이로드에 신원 매칭(b1→a1)이 상류 기본 사유로 실린다" "$RUN/j1-payload.json" \
  'd["matches"]' \
  '[{"afterOccurrenceIds": ["a1"], "beforeOccurrenceIds": ["b1"], "confidence": "high", "reason": "The findings share a stable identity or a previously confirmed link."}]'
check 0 "J2 대조군: knownFindingGroups 없으면 빈 매칭도 통과" \
  "$RUN/input.json" "$RUN/no-match.json"

cat >"$RUN/known-uncertain.json" <<'EOF'
{
  "matches": [],
  "uncertain": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a1", "reason": "maybe"}
  ]
}
EOF
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input-known-cross.json" \
  --matches-json "$RUN/known-uncertain.json" --payload-out "$RUN/j3-payload.json" 2>&1)"
expect_exit 0 "$?" "J3 확정 그룹 안의 uncertain 은 오류 없이 제거되고 나머지는 저장"
printf '     %s\n' "$out"
assert_json "J3b 제거된 uncertain 은 페이로드에 없다" "$RUN/j3-payload.json" 'd["uncertain"]' '[]'

# ---------------------------------------------------------------------------
# K. knownFindingGroups 없는 정상 페이로드 통과 (R11)
# ---------------------------------------------------------------------------
step "K. 정상 페이로드 통과 (R11)"

cat >"$RUN/ok-baseline.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "동일 근본 원인 — 같은 helper 로 수렴"}
  ],
  "uncertain": [
    {"beforeOccurrenceId": "b2", "afterOccurrenceId": "a2", "reason": "그럴듯하나 확신 없음"}
  ]
}
EOF
check 0 "K1 knownFindingGroups 없는 정상 페이로드" "$RUN/input.json" "$RUN/ok-baseline.json"
check 0 "K2 knownFindingGroups 를 지키는 정상 페이로드" \
  "$RUN/input-known-cross.json" "$RUN/ok-baseline.json"

# ---------------------------------------------------------------------------
# L. related 를 포함한 정상 페이로드 통과
# ---------------------------------------------------------------------------
step "L. related 포함 정상 페이로드 통과"

cat >"$RUN/ok-related.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "동일 근본 원인 — 같은 helper 로 수렴"}
  ],
  "uncertain": [
    {"beforeOccurrenceId": "b2", "afterOccurrenceId": "a2", "reason": "그럴듯하나 확신 없음"}
  ],
  "related": [
    {"beforeOccurrenceId": "b3", "afterOccurrenceId": "a3", "reason": "인접 이슈 — 같은 모듈"}
  ]
}
EOF
# 성공 경로가 종료코드만 보면, 성공 출력의 카운트가 상수로 회귀해도 통과한다
# (예: relatedCount 가 항상 0). 유일한 related 성공 케이스이므로 여기서 못 박는다.
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input.json" --matches-json "$RUN/ok-related.json" 2>&1)"
expect_exit 0 "$?" "L1 related 포함 정상 페이로드"
printf '     %s\n' "$out"
# 세 키를 **각각 독립적으로** 본다. 하나의 `*A*B*C*` 패턴으로 합치면 출력에서
# 그 순서로 나타날 것을 요구하게 되어, 성공 dict 의 키 순서만 바꾸는 동작 보존
# 리팩터가 "인벤토리가 페이로드와 다릅니다"라는 **거짓 FAIL** 을 낸다(실측).
# 원래의 독립 `grep -q` 3개와 의미를 맞춘다.
_l2_ok=1
for _l2_want in '"matchCount": 1' '"uncertainCount": 1' '"relatedCount": 1'; do
  case "$out" in
    *"$_l2_want"*) ;;
    *) _l2_ok=0 ;;
  esac
done
if [ "$_l2_ok" = 1 ]; then
  printf 'OK   L2: 성공 출력 인벤토리가 페이로드와 일치 (1/1/1)\n'
else
  printf 'FAIL L2: 성공 출력 인벤토리가 페이로드와 다릅니다\n'
  FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------------------
# M. 같은 findingId 가 before·after 양쪽에만 있으면 신원만으로 완결된다 (R10).
#    카탈로그 단계가 complete=true 와 저장 페이로드를 바로 내고, finalize 는
#    서브에이전트 판정을 받지 않는다(받으면 상류와 다른 저장 결과가 된다).
# ---------------------------------------------------------------------------
step "M. 신원만으로 완결 — 서브에이전트 호출 없음 (R10)"

cat >"$RUN/input-shared-finding.json" <<'EOF'
{
  "before": [{"occurrenceId": "b1", "findingId": "shared"}],
  "after": [{"occurrenceId": "a1", "findingId": "shared"}]
}
EOF
out="$(PY "$VALIDATOR" catalogue --input-json "$RUN/input-shared-finding.json" \
  --catalogue-out "$RUN/m-catalogue.json" --payload-out "$RUN/m-payload.json" 2>&1)"
expect_exit 0 "$?" "M1 같은 findingId 만 있는 입력의 카탈로그 생성"
printf '     %s\n' "$out"
printf '%s' "$out" >"$RUN/m-out.json"
assert_json "M1b complete=true" "$RUN/m-out.json" 'd["complete"]' 'true'
assert_json "M1c 저장 페이로드가 바로 나온다" "$RUN/m-payload.json" \
  '[m["beforeOccurrenceIds"] + m["afterOccurrenceIds"] for m in d["matches"]]' '[["b1", "a1"]]'

cat >"$RUN/ok-shared-finding.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "같은 findingId — 이월 파인딩"}
  ],
  "uncertain": []
}
EOF
check 1 "M2 완결 입력에 서브에이전트 판정을 넣으면 거부(카탈로그 페이로드를 저장해야 한다)" \
  "$RUN/input-shared-finding.json" "$RUN/ok-shared-finding.json" "신원만으로 완결"

# ---------------------------------------------------------------------------
# N. union-find 이행적 병합 — 두 그룹이 제3의 findingId 로만 이어진 경우.
#
#    knownFindingGroups = [["f1","z9"], ["z9","f2"]] 이고 z9 는 이번 비교의
#    어느 쪽에도 없다. 이행적으로 병합해야만 f1·f2 가 한 카드로 접힌다 — 이 블록이
#    groupFindings 의 병합을 단독으로 검증한다.
# ---------------------------------------------------------------------------
step "N. union-find 이행적 병합 — 대표 카드 접기"

PY - "$RUN/input.json" "$RUN/input-known-bridge.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
data["matchingInputs"]["knownFindingGroups"] = [["f1", "z9"], ["z9", "f2"]]
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
EOF
need_fixture "$RUN/input-known-bridge.json"

out="$(PY "$VALIDATOR" catalogue --input-json "$RUN/input-known-bridge.json" \
  --catalogue-out "$RUN/n-catalogue.json" 2>&1)"
expect_exit 0 "$?" "N0 이어진 그룹의 카탈로그 생성"
printf '%s' "$out" >"$RUN/n-out.json"
assert_json "N1 제3 findingId 로만 이어진 b1·b2 가 대표 카드 b2 한 장으로 접힌다" "$RUN/n-out.json" \
  '[(r["id"], r["occurrenceIds"]) for r in d["trusted"]["beforeRepresentatives"]]' \
  '[["b2", ["b1", "b2"]], ["b3", ["b3"]]]'
check 1 "N1b 접힌 b1 로 매칭하면 거부" \
  "$RUN/input-known-bridge.json" "$RUN/scatter.json" "느슨한 단계] 미지의 before occurrence"

# 대조군: 병합을 하지 않으면(공유 findingId 없음) 두 카드가 그대로 남는다.
PY - "$RUN/input.json" "$RUN/input-known-nobridge.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
data["matchingInputs"]["knownFindingGroups"] = [["f1", "z9"], ["z8", "f2"]]
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
EOF
need_fixture "$RUN/input-known-nobridge.json"
check 0 "N2 대조군: 이어지지 않은 두 그룹이면 같은 페이로드가 통과" \
  "$RUN/input-known-nobridge.json" "$RUN/scatter.json"

cat >"$RUN/ok-bridge.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b2"], "afterOccurrenceIds": ["a1", "a2"],
     "confidence": "high", "reason": "이전 비교들에서 같은 finding 으로 확정된 이월분"}
  ],
  "uncertain": []
}
EOF
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input-known-bridge.json" \
  --matches-json "$RUN/ok-bridge.json" --payload-out "$RUN/n3-payload.json" 2>&1)"
expect_exit 0 "$?" "N3 대표 카드 b2 로 매칭하면 통과"
printf '     %s\n' "$out"
assert_json "N3b 대표 ID 가 그룹의 모든 before occurrence 로 펼쳐진다" "$RUN/n3-payload.json" \
  'd["matches"][0]["beforeOccurrenceIds"]' '["b1", "b2"]'

# ---------------------------------------------------------------------------
# O. stdin 경로(`-`)와 --allow-historical 회귀.
# ---------------------------------------------------------------------------
step "O. stdin 입력 / --allow-historical 회귀"
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input.json" --matches-json - \
  <"$RUN/ok-related.json" 2>&1)"
expect_exit 0 "$?" "O1 matches-json 을 stdin 으로"
printf '     %s\n' "$out"
check 1 "O2 input/matches 동시 stdin 금지" "-" "-"
# 부속명령 없는 옛 호출 형태(P5)는 finalize 의 별칭으로 남긴다 — 옛 문서·스크립트가
# 부르던 형태가 argparse 오류(exit 2)로 바뀌면 "검증 실패"와 "호출 형태 오류"가 섞인다.
out="$(PY "$VALIDATOR" --input-json "$RUN/input.json" --matches-json "$RUN/ok-related.json" 2>&1)"
expect_exit 0 "$?" "O2b 부속명령 없는 옛 호출 형태는 finalize 로 동작"
case "$out" in
  *'"payload"'*) ok "O2c 옛 호출 형태도 저장 페이로드를 낸다" ;;
  *) bad "O2c 옛 호출 형태의 출력에 payload 가 없습니다: ${out%%$'\n'*}" ;;
esac

cat >"$RUN/historical-uncertain.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "동일 근본 원인"}
  ],
  "uncertain": [
    {"beforeOccurrenceId": "b2", "afterOccurrenceId": "a1", "reason": "이력상 후보"}
  ]
}
EOF
# 상류 저장 단계는 이 형상을 무조건 거부한다(--allow-historical 대응 옵션 없음).
# 그래서 이 검증기도 완화 옵션을 제공하지 않는다 — 통과시키면 "검증 통과"가
# 저장 가능을 뜻하지 않게 된다.
check 1 "O3 uncertain after 가 기매칭이면 항상 거부" \
  "$RUN/input.json" "$RUN/historical-uncertain.json"
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input.json" \
  --matches-json "$RUN/historical-uncertain.json" --allow-historical 2>&1)"
code=$?
case "$out" in
  *allow-historical*) _o4_mentions=1 ;;
  *) _o4_mentions=0 ;;
esac
if [ "$code" != "0" ] && [ "$_o4_mentions" = 1 ]; then
  printf 'OK   O4: --allow-historical 이 더 이상 받아들여지지 않음 (상류 저장 규칙과 정합)\n'
else
  printf 'FAIL O4: --allow-historical 가 아직 동작합니다 (exit %s) — 저장 불가 페이로드를 통과시킵니다\n' "$code"
  FAILED=$((FAILED + 1))
fi

# 입력 원소가 부분적으로 망가진 경우: 조용히 건너뛰지 않고 실패해야 한다.
PY - "$RUN/input.json" "$RUN/input-broken-row.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
data["matchingInputs"]["before"].append({"findingId": "f1"})  # occurrenceId 없음
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
EOF
need_fixture "$RUN/input-broken-row.json"
check 1 "O5 occurrenceId 없는 입력 행은 조용히 건너뛰지 않고 거부" \
  "$RUN/input-broken-row.json" "$RUN/ok-baseline.json" \
  "문자열 occurrenceId 가 없습니다"

# ---------------------------------------------------------------------------
# P. P5 의 blockedByPriorGroup(저장 중단 신호)은 폐기됐다 (P6-KTD4). 호스트가 먼저
#    병합하므로 서브에이전트가 기확정 그룹과 모순되는 판정을 낼 방법이 없다.
#    우려는 priorGroupConcerns 로 보고하고 저장은 진행한다. 옛 키가 실려 오면
#    새 키로 옮기라는 안내와 함께 거부한다(조용히 지우면 우려가 사라진다).
# ---------------------------------------------------------------------------
step "P. blockedByPriorGroup 폐기 → priorGroupConcerns (P6-KTD4)"

cat >"$RUN/blocked.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b2"], "afterOccurrenceIds": ["a2"],
     "confidence": "high", "reason": "admin 라우트 권한 검사 누락이 그대로 남음"}
  ],
  "uncertain": [],
  "blockedByPriorGroup": "그룹 [f1, g1] 은 근본 원인이 다릅니다 — 이전 비교의 오판으로 봅니다."
}
EOF
check 1 "P1 blockedByPriorGroup 이 실리면 priorGroupConcerns 로 옮기라고 안내하며 거부" \
  "$RUN/input-known-cross.json" "$RUN/blocked.json" "priorGroupConcerns"

cat >"$RUN/concern.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b2"], "afterOccurrenceIds": ["a2"],
     "confidence": "high", "reason": "admin 라우트 권한 검사 누락이 그대로 남음"}
  ],
  "uncertain": [],
  "priorGroupConcerns": [
    {"issueId": "f1", "reason": "그룹 [f1, g1] 은 근본 원인이 다릅니다 — 이전 비교의 오판으로 봅니다."}
  ]
}
EOF
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input-known-cross.json" \
  --matches-json "$RUN/concern.json" --payload-out "$RUN/p2-payload.json" 2>&1)"
expect_exit 0 "$?" "P2 같은 우려를 priorGroupConcerns 로 보내면 저장은 진행 (AE3)"
printf '     %s\n' "$out"
printf '%s' "$out" >"$RUN/p2-out.json"
assert_json "P2b 우려는 분리되어 반환되고 신뢰 식별자(그룹 occurrence)가 붙는다" "$RUN/p2-out.json" \
  '[(c["issueId"], c["beforeOccurrenceIds"], c["afterOccurrenceIds"]) for c in d["priorGroupConcerns"]]' \
  '[["f1", ["b1"], ["a1"]]]'
assert_json "P2c 저장 페이로드에는 priorGroupConcerns 가 없다" "$RUN/p2-payload.json" \
  'sorted(d)' '["matches", "uncertain"]'
assert_json "P2d 기확정 그룹(b1→a1)은 여전히 저장된다 — 우려는 저장을 막지 않는다" "$RUN/p2-payload.json" \
  '[m["beforeOccurrenceIds"] + m["afterOccurrenceIds"] for m in d["matches"]]' '[["b2", "a2"], ["b1", "a1"]]'

# ---------------------------------------------------------------------------
# Q. _safe_repr — 미신뢰 값을 오류 문장에 실을 때의 두 방어.
#
#    매칭 입력은 대상 저장소 코드에서 파생된 자유 텍스트다. 무제한으로 실으면
#    finding 본문이 통째로 부모 세션 컨텍스트로 흘러들고, f-string 은 ValueError
#    생성 **전에** 평가되므로 깊게 중첩된 값은 repr 재귀 폭주로 main() 의 except 를
#    지나쳐 stdout 이 비고 트레이스백만 남는다 — "exit 1 + {ok:false}" 계약이 깨진다.
#    두 방어 모두 회귀로 고정한다.
# ---------------------------------------------------------------------------
step "Q. _safe_repr 길이 한도와 repr 재귀 방어"

# Q1: 거대한 행 → 오류 문장이 절단된다.
PY - "$RUN/input-huge-row.json" <<'EOF'
import json, sys
data = {"matchingInputs": {
    "before": [{"findingId": "f1", "title": "x" * 100000}],   # occurrenceId 없음 → 거부 경로
    "after": [{"occurrenceId": "a1", "findingId": "g1"}],
}}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(data))
EOF
need_fixture "$RUN/input-huge-row.json"
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input-huge-row.json" --matches-json "$RUN/no-match.json" 2>&1)"
code=$?
expect_exit 1 "$code" "Q1 거대한 행은 거부"
q1_len=${#out}
# 길이만 보면 **어떤 짧은 거부든** 통과한다 — 픽스처의 100KB 본문을 "x" 로 줄여도
# 초록이었다(실측). 절단 표식을 양성으로 요구해야 "한도에 도달했고 잘렸다"가 고정된다.
case "$out" in
  *"…(절단)"*)
    if [ "$q1_len" -lt 4000 ]; then
      ok "Q1b: 절단 표식 + 짧은 문장 (${q1_len}자)"
    else
      bad "Q1b: 절단 표식은 있으나 ${q1_len}자 — 한도가 커졌습니다"
    fi ;;
  *)
    bad "Q1b: 절단 표식이 없습니다 (${q1_len}자) — 픽스처가 길이 한도에 도달하지 못했거나 한도가 사라졌습니다" ;;
esac

# Q2: 깊게 중첩된 값 → 어떤 깊이에서도 JSON 봉투(exit 1 + {"ok": false})가 유지된다.
#
#     0.2.0 때부터 실패하던 옛 Q2b 는 "JSON 으로는 읽히지만 repr 이 재귀 한도에 걸리는
#     깊이"를 전제했다. 실측하면 그런 깊이가 없다. CPython 3.12+ 는 json 스캐너가 repr
#     보다 먼저 한도에 걸린다(3.12.15: 5천 중첩은 둘 다 통과, 1만은 json.loads 가
#     RecursionError. 3.14.8: 5만은 둘 다 통과, 8만은 json.loads 가 RecursionError).
#     그래서 종단 픽스처로는 _safe_repr 의 RecursionError 분기에 닿을 수 없다. 단언을
#     둘로 나눈다.
#       Q2a/Q2b — 종단: 어느 지원 버전에서나 읽히는 깊이(900)는 _side 거부 문장으로, 파서
#                 한도를 넘는 깊이(100만)는 main() 의 중첩 한도 분기로 각각 봉투를 유지한다.
#                 (길이 절단은 Q1 이 고정한다.)
#       Q2c     — 단위: repr 이 RecursionError 를 내는 값을 _side 거부 경로에 직접 넣어
#                 _safe_repr 방어가 발동하고 ValueError(재판정 사유)로 끝나는지 본다.
PY - "$RUN/input-deep-row.json" "$RUN/input-deeper-row.json" <<'EOF'
import sys
for path, n in ((sys.argv[1], 900), (sys.argv[2], 1000000)):
    deep = "[" * n + "]" * n
    open(path, "w", encoding="utf-8").write(
        '{"matchingInputs":{"before":[' + deep + '],'
        '"after":[{"occurrenceId":"a1","findingId":"g1"}]}}'
    )
EOF
need_fixture "$RUN/input-deep-row.json"
need_fixture "$RUN/input-deeper-row.json"
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input-deep-row.json" --matches-json "$RUN/no-match.json" 2>&1)"
code=$?
expect_exit 1 "$code" "Q2 깊게 중첩된 행은 거부"
# `"ok": false` 는 모든 거부 경로가 낸다. 이 행이 파서를 지나 실제로 occurrenceId 검사(_side)에
# 닿았는지까지 요구한다. 파이프로 grep -q 에 넘기지 않는다(SIGPIPE/pipefail 함정).
case "$out" in
  *'"ok": false'*"'before'[0] 에 문자열 occurrenceId 가 없습니다: [[[["*)
    ok "Q2a: 읽히는 깊이 — JSON 봉투 유지, _side 거부 경로 도달" ;;
  *"repr 재귀 한도 초과"*)
    ok "Q2a: 읽히는 깊이 — 이 Python 은 repr 이 먼저 한도에 걸렸고 _safe_repr 방어가 발동" ;;
  *)
    bad "Q2a: 봉투 또는 _side 거부 근거가 없습니다"
    printf '     %s\n' "${out:0:300}" ;;
esac
out="$(PY "$VALIDATOR" finalize --input-json "$RUN/input-deeper-row.json" --matches-json "$RUN/no-match.json" 2>&1)"
code=$?
expect_exit 1 "$code" "Q2 파서 한도를 넘는 행은 거부"
case "$out" in
  '{"ok": false, "error": "입력 읽기/파싱 실패(중첩 한도): '*)
    ok "Q2b: 파서 한도 초과 — 트레이스백 없이 중첩 한도 봉투" ;;
  *)
    bad "Q2b: 중첩 한도 봉투가 아닙니다"
    printf '     %s\n' "${out:0:300}" ;;
esac
PY - "$VALIDATOR" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("validate_matches", sys.argv[1])
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


class ReprBomb:
    def __repr__(self) -> str:
        raise RecursionError("maximum recursion depth exceeded while getting the repr of an object")


failures = 0
marker = vm._safe_repr(ReprBomb())
if marker != "<ReprBomb: repr 재귀 한도 초과>":
    print(f"FAIL Q2c _safe_repr 표식: {marker!r}"); failures += 1
try:
    vm._side({"before": [ReprBomb()]}, "before")
    print("FAIL Q2c _side 가 거부하지 않았습니다"); failures += 1
except ValueError as error:
    good = "문자열 occurrenceId 가 없습니다" in str(error) and "repr 재귀 한도 초과" in str(error)
    print(("OK   " if good else "FAIL ") + f"Q2c: repr 재귀 방어 발동 → ValueError(재판정 사유): {error}")
    failures += 0 if good else 1
except RecursionError as error:
    print(f"FAIL Q2c: repr 재귀가 ValueError 생성 전에 새어 나왔습니다: {error}"); failures += 1
# 대조군: 방어가 없으면(repr 직접 호출) 같은 값이 RecursionError 를 낸다 — 픽스처가 실제로 그 경로를 친다.
try:
    repr(ReprBomb())
    print("FAIL Q2c 대조군: repr 이 실패하지 않았습니다 — 픽스처가 재귀 경로를 치지 않습니다"); failures += 1
except RecursionError:
    print("OK   Q2c 대조군: 방어 없는 repr 은 RecursionError")
raise SystemExit(1 if failures else 0)
EOF
[ $? = 0 ] || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------------------
# 상류 전제 탐색 — S(dist 대조)와 U(워크벤치 왕복)에만 쓴다. 없으면 두 블록을
# 건너뛰고 끝에서 INCOMPLETE(exit 2)로 알린다. 통과로 세지 않는다.
# ---------------------------------------------------------------------------
MISSING=""
missing() { MISSING="${MISSING}${MISSING:+; }$1"; printf 'INCOMPLETE — %s\n' "$1"; }
PLUGIN="${CODEX_SECURITY_PLUGIN_DIR:-${CODEX_SECURITY_PLUGIN_ROOT:-}}"
if [ -z "$PLUGIN" ]; then
  NPM_BIN="$(command -v npm || true)"
  if [ -n "$NPM_BIN" ] && NPM_ROOT="$("$NPM_BIN" root -g 2>/dev/null)" && \
     [ -f "$NPM_ROOT/@openai/codex-security/_bundled_plugin/.codex-plugin/plugin.json" ]; then
    PLUGIN="$NPM_ROOT/@openai/codex-security/_bundled_plugin"
  fi
fi
if [ -n "$PLUGIN" ] && [ ! -f "$PLUGIN/scripts/workbench_db.py" ]; then
  missing "플러그인 경로에 scripts/workbench_db.py 가 없습니다: $PLUGIN"
  PLUGIN=""
fi
# 상류 dist: npm 패키지 레이아웃(<pkg>/_bundled_plugin 의 형제 <pkg>/dist)만 자동 인식한다.
DIST="${CODEX_SECURITY_SDK_DIST:-}"
if [ -z "$DIST" ] && [ -n "$PLUGIN" ] && [ -f "$PLUGIN/../dist/scan-comparison.js" ]; then
  DIST="$(cd "$PLUGIN/../dist" && pwd -P)"
fi
NODE_BIN="${NODE:-$(command -v node || true)}"
FIXTURES="$WORK/../fixtures/scan-match"
if [ ! -d "$FIXTURES" ] || [ -z "$(find "$FIXTURES" -name '*.json' -print -quit)" ]; then
  printf 'INCOMPLETE — 픽스처 디렉터리가 없습니다: %s\n' "$FIXTURES" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# R. 상류 테스트에서 옮긴 픽스처 — catalogue / finalize 를 픽스처마다 돌려
#    기록된 상류 결과(upstream 필드: npm 0.1.29 dist 를 가짜 codex 로 돌린 값)와
#    문자 단위로 대조한다. U5 Test scenarios 대응:
#      AE2 완결 단축 ................ identity-complete/*
#      3 occurrence 접기·중복 제거 ... catalogue-cards/fold-three-same-finding-id
#      대표 ID 펼침 ................. reconcile/split-confirmed-historical-group, catalogue-cards/*
#      신원 그룹 카드 포함 + 새 ID 합류 reconcile/cross-side-alias-extended
#      한 그룹에 걸친 두 매칭 병합 ..... reconcile/later-side-aliases-merge-two-matches
#      그룹 안 uncertain·related 제거 . reconcile/cross-side-alias-*, same-stable-finding-uncertain-dropped
#      최종 단계 잔여 모순 거부 ........ reconcile/known-*-uncertain-residual
#      priorGroupConcerns 분리 (AE3) .. extensions/prior-group-concerns
#      evidenceNeeded → 페이로드 없음 . extensions/evidence-needed
#      기존 거부 4종 + P5 규칙 ......... rejections/rejects-table (+ 위 A~H)
# ---------------------------------------------------------------------------
step "R. 상류 테스트 이식 픽스처 대조"

cat >"$RUN/fixture_runner.py" <<'PYEOF'
"""픽스처마다 validate_matches.py catalogue / finalize 를 돌려 기대값과 대조한다."""

import json
import subprocess
import sys
from pathlib import Path

validator, fixtures_dir, work = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
failures = 0
checks = 0
ours: dict[str, dict] = {}
EXT_KEYS = ("priorGroupConcerns", "evidenceNeeded")


def ok(label: str) -> None:
    global checks
    checks += 1
    print(f"OK   {label}")


def bad(label: str) -> None:
    global checks, failures
    checks += 1
    failures += 1
    print(f"FAIL {label}")


def expect(condition: bool, label: str, detail: str = "") -> None:
    if condition:
        ok(label)
    else:
        bad(f"{label}{(' — ' + detail) if detail else ''}")


def run(args: list[str]) -> tuple[int, dict | None, str]:
    proc = subprocess.run(
        [sys.executable, validator, *args], capture_output=True, text=True, encoding="utf-8"
    )
    try:
        doc = json.loads(proc.stdout)
    except ValueError:
        doc = None
    return proc.returncode, doc, (proc.stdout + proc.stderr)[:600]


def short(value: object) -> str:
    text = json.dumps(value, ensure_ascii=False)
    return text if len(text) <= 400 else text[:400] + "…"


index = 0
for path in sorted(fixtures_dir.glob("*.json")):
    for fixture in json.loads(path.read_text(encoding="utf-8"))["fixtures"]:
        index += 1
        name = f"{path.stem}/{fixture['name']}"
        base = work / f"fx{index}"
        base.mkdir()
        input_file = base / "input.json"
        input_file.write_text(json.dumps(fixture["input"], ensure_ascii=False), encoding="utf-8")
        catalogue_file = base / "catalogue.json"
        payload_file = base / "payload.json"
        expected = fixture["catalogue"]
        upstream = fixture["upstream"]
        code, doc, raw = run([
            "catalogue", "--input-json", str(input_file),
            "--catalogue-out", str(catalogue_file), "--payload-out", str(payload_file),
        ])
        record: dict = {"catalogue": {"exit": code}, "cases": []}
        ours[fixture["name"]] = record
        if "exit" in expected:
            expect(code == expected["exit"], f"{name}: catalogue exit {code} (기대 {expected['exit']})", raw)
            expect(doc is not None and expected["reason"] in str(doc.get("error")),
                   f"{name}: 입력 거부 사유", raw)
            expect("error" in upstream, f"{name}: 상류도 입력을 거부", short(upstream))
            continue
        if code != 0 or doc is None:
            bad(f"{name}: catalogue exit {code} — {raw}")
            continue
        complete = doc.get("complete")
        record["catalogue"]["complete"] = complete
        expect(complete is expected["complete"], f"{name}: complete={complete} (기대 {expected['complete']})")
        expect(complete == (upstream["threads"] == 0),
               f"{name}: complete 가 상류의 codex 미호출 여부(threads={upstream['threads']})와 일치")
        if complete:
            payload = json.loads(payload_file.read_text(encoding="utf-8")) if payload_file.exists() else None
            record["catalogue"]["payload"] = payload
            expect(payload == upstream["result"], f"{name}: 완결 페이로드 == 상류 결과",
                   f"우리 {short(payload)} / 상류 {short(upstream['result'])}")
            expect(doc.get("payload") == payload, f"{name}: stdout payload 와 --payload-out 파일이 같다")
            continue
        expect(not payload_file.exists(), f"{name}: 미완결이면 카탈로그 단계가 페이로드 파일을 만들지 않는다")
        text = catalogue_file.read_text(encoding="utf-8") if catalogue_file.exists() else ""
        record["catalogue"]["catalogueLine"] = text
        record["catalogue"]["identityComparison"] = doc.get("identityComparison")
        expect(text == upstream.get("catalogueLine"), f"{name}: 카탈로그 JSON 이 상류 프롬프트 마지막 줄과 문자 단위로 같다",
               f"우리 {text[:300]} / 상류 {str(upstream.get('catalogueLine'))[:300]}")
        expect(doc.get("catalogueCharacters") == len(text),
               f"{name}: catalogueCharacters 가 코드포인트 수와 같다")
        expect(doc.get("identityComparison") == upstream["result"],
               f"{name}: 신원 선조정 결과 == 상류(빈 판정) 결과",
               f"우리 {short(doc.get('identityComparison'))} / 상류 {short(upstream['result'])}")
        reps = doc["trusted"]["beforeRepresentatives"]
        if "beforeCardIds" in expected:
            got = [rep["id"] for rep in reps]
            expect(got == expected["beforeCardIds"], f"{name}: 대표 카드 ID {got}")
        for rep_id, occurrence_ids in expected.get("representativeOccurrences", {}).items():
            got = next((rep["occurrenceIds"] for rep in reps if rep["id"] == rep_id), None)
            expect(got == occurrence_ids, f"{name}: 대표 {rep_id} 의 occurrence {got}")
        cards = {card["occurrenceId"]: card for card in json.loads(text)["findings"]["before"]} if text else {}
        for card_id, fields in expected.get("cards", {}).items():
            for key, value in fields.items():
                got = cards.get(card_id, {}).get(key)
                expect(got == value, f"{name}: 카드 {card_id}.{key} = {short(got)}", f"기대 {short(value)}")
        for card_id, keys in expected.get("absentCardKeys", {}).items():
            for key in keys:
                expect(key not in cards.get(card_id, {"__missing__": 1}) and card_id in cards,
                       f"{name}: 카드 {card_id} 에 {key} 가 없다")
        for needle in expected.get("catalogueExcludes", []):
            expect(needle not in text, f"{name}: 카탈로그에 전체 증거 '{needle}' 가 실리지 않는다")
        after_ids = [row["occurrenceId"] for row in fixture["input"]["after"]]
        expect(doc["trusted"]["afterIds"] == after_ids, f"{name}: 신뢰 블록 after ID 가 입력 순서 그대로")

        for number, case in enumerate(fixture.get("cases", []), 1):
            label = f"{name} #{number} {case['label']}"
            response_file = base / f"response{number}.json"
            response_file.write_text(json.dumps(case["response"], ensure_ascii=False), encoding="utf-8")
            case_payload = base / f"payload{number}.json"
            code, doc, raw = run([
                "finalize", "--input-json", str(input_file), "--matches-json", str(response_file),
                "--payload-out", str(case_payload),
            ])
            want = case["expect"]
            got_payload = (
                json.loads(case_payload.read_text(encoding="utf-8")) if case_payload.exists() else None
            )
            record["cases"].append({"exit": code, "payload": got_payload})
            expect(code == want["exit"], f"{label}: exit {code} (기대 {want['exit']})", raw)
            if doc is None:
                bad(f"{label}: stdout 이 JSON 이 아닙니다 — {raw}")
                continue
            if "reason" in want:
                expect(want["reason"] in str(doc.get("error")), f"{label}: 사유에 '{want['reason']}'", raw)
            case_upstream = case["upstream"]
            if want["exit"] == 0:
                expect(got_payload == case_upstream.get("result"), f"{label}: 저장 페이로드 == 상류 결과",
                       f"우리 {short(got_payload)} / 상류 {short(case_upstream)}")
                expect(got_payload is not None and not any(key in got_payload for key in EXT_KEYS),
                       f"{label}: 페이로드에 우리 선택 키가 없다")
                concerns = doc.get("priorGroupConcerns", [])
                expect(len(concerns) == want.get("priorGroupConcerns", 0),
                       f"{label}: priorGroupConcerns {len(concerns)}건")
            else:
                expect(got_payload is None, f"{label}: 거부·중단이면 페이로드 파일이 없다")
                expect("payload" not in doc, f"{label}: 거부·중단이면 stdout 에 payload 가 없다")
                if "oursOnly" not in case:
                    expect("error" in case_upstream, f"{label}: 상류도 저장하지 않는다", short(case_upstream))
            if want["exit"] == 3:
                expect("scans match --all" in str(case_upstream.get("error")),
                       f"{label}: 상류 단일 턴 모드도 증거 요청이면 저장 없이 끝난다")
                expect(len(doc.get("evidenceNeeded", [])) == want.get("evidenceNeeded", -1),
                       f"{label}: 증거 필요 쌍 {len(doc.get('evidenceNeeded', []))}건 보고")

(work / "ours.json").write_text(json.dumps(ours, ensure_ascii=False), encoding="utf-8")
print(f"RUNNER checks={checks} failures={failures}")
PYEOF

mkdir -p "$RUN/fixtures-work"
runner_out="$(PY "$RUN/fixture_runner.py" "$VALIDATOR" "$FIXTURES" "$RUN/fixtures-work" 2>&1)"
runner_code=$?
printf '%s\n' "$runner_out"
case "$runner_out" in
  *"RUNNER checks="*" failures=0"*)
    [ "$runner_code" = 0 ] && ok "R: 픽스처 대조 전부 통과" || bad "R: 러너 exit $runner_code" ;;
  *"RUNNER checks="*)
    _r_fail="${runner_out##*failures=}"
    FAILED=$((FAILED + ${_r_fail%%[!0-9]*}))
    printf 'FAIL R: 픽스처 대조 실패 %s건\n' "${_r_fail%%[!0-9]*}" ;;
  *) bad "R: 러너가 요약 줄 없이 끝났습니다(크래시 의심, exit $runner_code)" ;;
esac

# ---------------------------------------------------------------------------
# S. 상류 dist 실측 대조 — 기록된 upstream 필드가 설치된 dist 와 아직 같은지(드리프트),
#    그리고 우리 결과가 dist 결과와 그룹 집합까지 같은지 본다. 가짜 codex 는 픽스처
#    응답을 그대로 돌려준다. singleTurn=true 로 페이지·증거 루프를 끈다(우리와 같은 조건).
# ---------------------------------------------------------------------------
step "S. 상류 dist 실측 대조 (matchScanFindingsInternal + 가짜 codex)"

if [ -z "$NODE_BIN" ]; then
  missing "node 를 찾지 못해 상류 dist 대조를 건너뜁니다 (NODE=<경로>)"
elif [ -z "$DIST" ] || [ ! -f "$DIST/scan-comparison.js" ]; then
  missing "상류 dist(scan-comparison.js)를 찾지 못해 대조를 건너뜁니다 (CODEX_SECURITY_SDK_DIST=<dist 경로>)"
else
  cat >"$RUN/parity.mjs" <<'JSEOF'
// 상류 dist 의 matchScanFindingsInternal 을 가짜 codex 로 돌려 픽스처별 결과를 낸다.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [distDir, ...files] = process.argv.slice(2);
const { matchScanFindingsInternal } = await import(
  pathToFileURL(`${distDir}/scan-comparison.js`).href
);
const OUR_KEYS = ["priorGroupConcerns", "evidenceNeeded"];
async function run(input, response) {
  const prompts = [];
  let threads = 0;
  const codex = {
    startThread() {
      threads += 1;
      return {
        async run(prompt) {
          prompts.push(prompt);
          return { finalResponse: JSON.stringify(response) };
        },
      };
    },
  };
  const out = {};
  try {
    out.result = await matchScanFindingsInternal(
      structuredClone(input),
      { codex },
      { surface: "sdk", singleTurn: true },
    );
  } catch (error) {
    out.error = String(error?.message ?? error);
  }
  out.threads = threads;
  if (prompts.length > 0)
    out.catalogueLine = prompts[0].slice(prompts[0].lastIndexOf("\n") + 1);
  return out;
}
const report = {};
for (const file of files) {
  const doc = JSON.parse(readFileSync(file, "utf8"));
  for (const fixture of doc.fixtures) {
    const entry = {
      catalogue: await run(fixture.input, { matches: [], uncertain: [] }),
      cases: [],
    };
    for (const item of fixture.cases ?? []) {
      let response = item.upstreamResponse;
      if (response === undefined) {
        response = { ...item.response };
        for (const key of OUR_KEYS) delete response[key];
      }
      const result = await run(fixture.input, response);
      delete result.catalogueLine;
      delete result.threads;
      entry.cases.push(result);
    }
    report[fixture.name] = entry;
  }
}
process.stdout.write(JSON.stringify(report) + "\n");
JSEOF
  "$NODE_BIN" "$RUN/parity.mjs" "$DIST" "$FIXTURES"/*.json >"$RUN/live.json" 2>"$RUN/live.err"
  live_code=$?
  if [ "$live_code" != 0 ] || [ ! -s "$RUN/live.json" ]; then
    bad "S0: 상류 dist 실행 실패 (exit $live_code): $(head -c 400 "$RUN/live.err")"
  else
    ok "S0: 상류 dist 실행 ($DIST)"
    PY - "$FIXTURES" "$RUN/live.json" "$RUN/fixtures-work/ours.json" <<'PYEOF'
import json, sys
from pathlib import Path

fixtures_dir, live_path, ours_path = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
live = json.load(open(live_path, encoding="utf-8"))
ours = json.load(open(ours_path, encoding="utf-8"))
failures = 0
group_parity = 0


def say(passed: bool, label: str) -> None:
    global failures
    if not passed:
        failures += 1
    print(("OK   " if passed else "FAIL ") + label)


def groups(result: dict) -> set:
    """매칭을 (before 집합, after 집합) 그룹 집합으로 정규화한다 — 순서 무관 비교."""
    return {
        (frozenset(m["beforeOccurrenceIds"]), frozenset(m["afterOccurrenceIds"]))
        for m in result["matches"]
    }


for path in sorted(fixtures_dir.glob("*.json")):
    for fixture in json.loads(path.read_text(encoding="utf-8"))["fixtures"]:
        name = fixture["name"]
        now, mine = live[name], ours.get(name, {})
        recorded = fixture["upstream"]
        say(now["catalogue"] == recorded,
            f"S1 {name}: 기록된 상류 카탈로그 결과가 설치된 dist 와 같다(드리프트 없음)")
        for number, (case, now_case) in enumerate(zip(fixture.get("cases", []), now["cases"]), 1):
            say(now_case == case["upstream"], f"S1 {name} #{number}: 기록된 상류 결과가 dist 와 같다")
        # 우리 결과를 dist 실측과 직접 대조한다.
        if mine.get("catalogue", {}).get("complete"):
            say(mine["catalogue"].get("payload") == now["catalogue"].get("result"),
                f"S2 {name}: 완결 페이로드 == dist 결과")
            if "result" in now["catalogue"] and groups(mine["catalogue"]["payload"]) == groups(now["catalogue"]["result"]):
                group_parity += 1
        elif "catalogueLine" in mine.get("catalogue", {}):
            say(mine["catalogue"]["catalogueLine"] == now["catalogue"].get("catalogueLine"),
                f"S2 {name}: 카탈로그 JSON == dist 프롬프트 마지막 줄")
        for number, (case, mine_case, now_case) in enumerate(
            zip(fixture.get("cases", []), mine.get("cases", []), now["cases"]), 1
        ):
            if mine_case["exit"] == 0:
                same = "result" in now_case and mine_case["payload"] == now_case["result"]
                say(same, f"S2 {name} #{number}: 저장 페이로드 == dist 결과")
                if same and groups(mine_case["payload"]) == groups(now_case["result"]):
                    group_parity += 1
            elif "oursOnly" not in case:
                say("error" in now_case, f"S2 {name} #{number}: 우리가 거부·중단하면 dist 도 저장하지 않는다")
say(group_parity >= 3, f"S3 dist 와 그룹 집합이 같은 픽스처 {group_parity}건 (최소 3)")
print(f"PARITY failures={failures}")
raise SystemExit(1 if failures else 0)
PYEOF
    [ $? = 0 ] || FAILED=$((FAILED + 1))
  fi
fi

# ---------------------------------------------------------------------------
# T. 프롬프트 한도 (P6-KTD5) — 조립한 프롬프트의 Unicode 코드포인트 수를 잰다.
#    동등성 한도 1,048,576(상류 MAX_CODEX_INPUT_CHARACTERS)과 실행 한도 중 작은 값을
#    넘으면 exit 3(저장 없이 중단)이다. 분할·재시도는 없다(R13).
# ---------------------------------------------------------------------------
step "T. 프롬프트 한도 측정 (measure)"

PY -c 'import sys; open(sys.argv[1], "w", encoding="utf-8").write("🙂" * 1000)' "$RUN/prompt-emoji.txt"
need_fixture "$RUN/prompt-emoji.txt"
out="$(PY "$VALIDATOR" measure --prompt-file "$RUN/prompt-emoji.txt" --execution-limit 1000 2>&1)"
expect_exit 0 "$?" "T1 한도와 같은 크기(코드포인트 1000)는 통과"
printf '%s' "$out" >"$RUN/t1.json"
assert_json "T1b 이모지를 UTF-16 단위가 아니라 코드포인트로 센다" "$RUN/t1.json" \
  '[d["characters"], d["limit"], d["withinLimit"]]' '[1000, 1000, true]'
out="$(PY "$VALIDATOR" measure --prompt-file "$RUN/prompt-emoji.txt" --execution-limit 999 2>&1)"
expect_exit 3 "$?" "T2 한도를 1자 넘으면 exit 3 (서브에이전트를 부르지 않고 중단)"
printf '%s' "$out" >"$RUN/t2.json"
assert_json "T2b 중단 출력에 초과 사실과 수치가 있다" "$RUN/t2.json" \
  '[d["ok"], d["withinLimit"], d["characters"], d["limit"]]' '[false, false, 1000, 999]'
out="$(PY "$VALIDATOR" measure --prompt-file "$RUN/prompt-emoji.txt" --execution-limit 5000000 2>&1)"
printf '%s' "$out" >"$RUN/t3.json"
assert_json "T3 실행 한도가 동등성 한도보다 커도 실효 한도는 1,048,576" "$RUN/t3.json" \
  '[d["equivalenceLimit"], d["limit"]]' '[1048576, 1048576]'
out="$(PY "$VALIDATOR" measure --prompt-file "$RUN/prompt-emoji.txt" 2>&1)"
printf '%s' "$out" >"$RUN/t4.json"
assert_json "T4 기본 실행 한도는 스킬 문서와 같은 값" "$RUN/t4.json" 'd["executionLimit"]' '80000'
PY -c 'import sys; open(sys.argv[1], "w", encoding="utf-8").write("x" * 80001)' "$RUN/prompt-over.txt"
out="$(PY "$VALIDATOR" measure --prompt-file "$RUN/prompt-over.txt" 2>&1)"
expect_exit 3 "$?" "T5 기본 실행 한도 초과(80,001자)는 exit 3"
out="$(PY "$VALIDATOR" measure --prompt-file "$RUN/prompt-over.txt" --execution-limit 0 2>&1)"
expect_exit 1 "$?" "T6 0 이하 실행 한도는 입력 오류(exit 1)"
# 스킬은 틀(frame.txt)과 catalogue.json 을 따로 두고 함께 잰다 — 카탈로그를 두 번 쓰지 않게.
PY -c 'import sys; open(sys.argv[1], "w", encoding="utf-8").write("🙂" * 499)' "$RUN/prompt-half.txt"
out="$(PY "$VALIDATOR" measure --prompt-file "$RUN/prompt-half.txt" --prompt-file "$RUN/prompt-emoji.txt" \
  --execution-limit 1500 2>&1)"
expect_exit 0 "$?" "T7 두 조각은 줄바꿈 하나로 이어 붙인 크기(499 + 1 + 1000)로 잰다"
printf '%s' "$out" >"$RUN/t7.json"
assert_json "T7b 합계 1500 = 한도" "$RUN/t7.json" '[d["characters"], d["files"]]' '[1500, 2]'
out="$(PY "$VALIDATOR" measure --prompt-file "$RUN/prompt-half.txt" --prompt-file "$RUN/prompt-emoji.txt" \
  --execution-limit 1499 2>&1)"
expect_exit 3 "$?" "T7c 합계가 한도를 1자 넘으면 exit 3"

# ---------------------------------------------------------------------------
# V. 0.4.0 정합 — enforceConfirmedIdentities 분기 삭제 (상류 2b759675b, #1364)
#    0.2.0 까지 상류 validateComparison 에는 조정 뒤에만 켜는 강제 분기(기확정 그룹
#    흩어짐·부분 매칭·양쪽 미매칭, 같은 findingId 의 uncertain, 같은 기확정 그룹의
#    related)가 있었다. reconcile 의 신원 그룹 병합이 그 모순을 먼저 없애므로 도달할 수
#    없었고, 0.4.0 은 그 분기를 지웠다. 검증기도 지웠다. 여기서는 두 가지를 고정한다.
#      - validate_comparison 은 단일 규칙이다(enforce 인자 없음). 옛 강제 분기 입력은
#        validate_comparison 단독으로는 통과한다(0.4.0 상류와 같다).
#      - 같은 입력을 reconcile_comparison 에 넣으면 병합이 모순을 해소한다 — 흩어진 그룹은
#        한 매칭으로 합쳐지고, 양쪽 미매칭 그룹은 신원 사유로 매칭되고, 같은 그룹의
#        uncertain·related 는 빠진다. 이것이 분기를 지워도 결과가 같은 근거다.
# ---------------------------------------------------------------------------
step "V. 0.4.0 정합 — 강제 분기 삭제와 병합에 의한 모순 해소"
PY - "$VALIDATOR" <<'PYEOF'
import importlib.util, inspect, sys
spec = importlib.util.spec_from_file_location("validate_matches", sys.argv[1])
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)
before = [{"occurrenceId": "b1", "findingId": "f1"}, {"occurrenceId": "b2", "findingId": "f2"}]
after = [{"occurrenceId": "a1", "findingId": "g1"}, {"occurrenceId": "a2", "findingId": "g2"}]
m = lambda b, a: {"beforeOccurrenceIds": b, "afterOccurrenceIds": a, "confidence": "high", "reason": "r"}
p = lambda b, a: {"beforeOccurrenceId": b, "afterOccurrenceId": a, "reason": "r"}
groups = lambda c: sorted(sorted(x["beforeOccurrenceIds"] + x["afterOccurrenceIds"]) for x in c["matches"])
failures = 0


def check(label, good, detail):
    global failures
    print(("OK   " if good else "FAIL ") + f"{label}: {detail}")
    failures += 0 if good else 1


params = inspect.signature(vm.validate_comparison).parameters
check("V0 validate_comparison 에 enforce 인자가 없다", "enforce" not in params, list(params))
check("V0 단계 표식은 느슨한/최종 두 개", (vm._LOOSE, vm._FINAL) == ("[느슨한 단계] ", "[최종 단계] "),
      [vm._LOOSE, vm._FINAL])
cases = [
    ("V1 기확정 그룹이 두 매칭 그룹으로 흩어짐", before, after, [["f1", "f2"]],
     {"matches": [m(["b1"], ["a1"]), m(["b2"], ["a2"])], "uncertain": []},
     lambda c: groups(c) == [["a1", "a2", "b1", "b2"]]),
    ("V2 기확정 그룹 일부만 매칭", before, after, [["f1", "f2"]],
     {"matches": [m(["b1"], ["a1"])], "uncertain": []},
     lambda c: groups(c) == [["a1", "b1", "b2"]]),
    ("V3 기확정 그룹이 양쪽에 있는데 미매칭", before, after, [["f1", "g1"]],
     {"matches": [], "uncertain": []},
     lambda c: c["matches"] == [{**m(["b1"], ["a1"]), "reason": vm.IDENTITY_REASON}]),
    ("V4 같은 기확정 그룹의 related", before, after, [["f2", "g2"]],
     {"matches": [m(["b1"], ["a1"])], "uncertain": [], "related": [p("b2", "a2")]},
     lambda c: c["related"] == [] and groups(c) == [["a1", "b1"], ["a2", "b2"]]),
    ("V5 같은 findingId 의 uncertain", [{"occurrenceId": "b", "findingId": "s"}],
     [{"occurrenceId": "a", "findingId": "s"}], [],
     {"matches": [], "uncertain": [p("b", "a")]},
     lambda c: c["uncertain"] == [] and groups(c) == [["a", "b"]]),
]
for label, b, a, known, response, expected in cases:
    try:
        vm.validate_comparison(b, a, known, response, stage=vm._FINAL)
        check(label, True, "validate_comparison 단독 통과(0.4.0 상류와 같음)")
    except ValueError as error:
        check(label, False, f"옛 강제 분기가 남아 거부했습니다: {error}")
    try:
        comparison, _ = vm.reconcile_comparison(b, a, known, response)
        check(label + " → 조정", expected(comparison), f"병합이 모순을 해소: {groups(comparison)}")
    except ValueError as error:
        check(label + " → 조정", False, f"조정이 거부했습니다: {error}")
raise SystemExit(1 if failures else 0)
PYEOF
[ $? = 0 ] || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------------------
# U. 워크벤치 왕복 — 실제 봉인 스캔 3개로 상류 저장 단계가 우리 페이로드를 받는지 본다.
#      S1 {traversal, authz}  S2 {traversal, authz-renamed}  S3 {traversal, authz-renamed}
#    (S2,S3): 모든 findingId 공유 → catalogue 완결 → 서브에이전트 없이 저장 (AE2)
#    (S1,S2): authz ↔ authz-renamed 는 findingId 가 달라 미완결 → 대표 ID 판정 → finalize → 저장
#    (S1,S3): 앞의 두 저장으로 knownFindingGroups 가 생긴다 → 신원만으로 완결
# ---------------------------------------------------------------------------
step "U. 워크벤치 save-scan-comparison 왕복"

if [ -z "$PLUGIN" ]; then
  missing "번들 플러그인을 찾지 못해 워크벤치 왕복을 건너뜁니다 (CODEX_SECURITY_PLUGIN_DIR=<경로>)"
elif ! command -v git >/dev/null 2>&1; then
  missing "git 이 없어 워크벤치 왕복을 건너뜁니다"
else
  WB_STATE="$RUN/wb-state"
  mkdir -p "$WB_STATE"; chmod 700 "$WB_STATE"
  wb() { CODEX_SECURITY_STATE_DIR="$WB_STATE" PY "$PLUGIN/scripts/workbench_db.py" "$@"; }
  WB_REPO="$RUN/wb-repo"
  mkdir -p "$WB_REPO/src"
  (
    cd "$WB_REPO" || exit 1
    git -c init.defaultBranch=main init -q .
    git config user.email u5@example.com
    git config user.name u5
    printf 'def extract(path):\n    return open(path).read()\n' > src/extract.py
    printf 'def admin(request):\n    return True\n' > src/admin.py
    git add -A
    git commit -qm initial
  ) || bad "U0: 합성 git 저장소 생성 실패"
  cat >"$RUN/wb-draft.py" <<'PYEOF'
"""get-scan 계약 값만으로 finding 을 지정한 미봉인 초안 3종을 쓴다(repro-u3 와 같은 형상)."""

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

scan_dir, doc, plugin_dir = Path(sys.argv[1]), json.load(open(sys.argv[2])), Path(sys.argv[3])
keys = sys.argv[4].split(",")
scan = doc["scan"]
target_contract = scan["contract"]["target"]
scope_contract = scan["contract"]["scope"]
version = json.loads((plugin_dir / ".codex-plugin" / "plugin.json").read_text())["version"]
kind = target_contract["allowedKinds"][0]
target = {"kind": kind, "targetId": target_contract["targetId"], "displayName": target_contract["displayName"]}
if kind in ("git_revision", "git_worktree"):
    target["revision"] = scan["targetRevision"]
if "requiredSnapshotDigest" in target_contract:
    target["snapshotDigest"] = target_contract["requiredSnapshotDigest"]
include = scope_contract.get("requiredIncludePaths", [scope_contract["requestedPath"]])
exclude = scope_contract["requiredExcludePaths"]
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
CATALOG = {
    "traversal": ("path-traversal.unvalidated-read", "Unvalidated path reaches a filesystem read",
                  "src/extract.py", "path-traversal", "CWE-22"),
    "authz": ("authz.missing-check", "Admin route has no authorization check",
              "src/admin.py", "access-control", "CWE-862"),
    "authz-renamed": ("authz.role-guard", "Admin handler lacks a role guard",
                      "src/admin.py", "access-control", "CWE-285"),
}
findings = []
for key in keys:
    rule, title, path, category, cwe = CATALOG[key]
    findings.append({
        "ruleId": rule, "title": title, "summary": title + ".", "remediation": f"Fix {key}.",
        "severity": {"level": "high"}, "confidence": {"level": "high", "rationale": "Direct trace."},
        "identity": {"anchor": key}, "taxonomy": {"category": category, "cwe": [cwe]},
        "locations": [{"path": path, "role": "root_control", "startLine": 1, "endLine": 2}],
        "provenance": {"source": "local_plugin"}, "extensions": {}, "attackPath": None, "validation": None,
    })
documents = {
    "scan-manifest.json": {
        "documentType": "codex-security.scan-manifest", "schemaVersion": "1.0",
        "scan": {"id": scan["scanId"], "status": "completed", "startedAt": now, "completedAt": now,
                 "producer": {"name": "codex-security-plugin", "version": version}, "target": target,
                 "scope": {"includePaths": include, "excludePaths": exclude},
                 "findingsRef": "findings.json", "coverageRef": "coverage.json"},
    },
    "findings.json": {"documentType": "codex-security.findings", "schemaVersion": "1.0",
                      "scanId": scan["scanId"], "findings": findings},
    "coverage.json": {"documentType": "codex-security.coverage", "schemaVersion": "1.0",
                      "scanId": scan["scanId"], "mode": "repository", "completeness": "complete",
                      "inventoryStrategy": "repository", "includePaths": include, "excludePaths": exclude,
                      "explicitExclusions": [], "deferred": [],
                      "surfaces": [{"id": "surface_all", "label": "All sources", "disposition": "reported",
                                    "receiptRefs": []}]},
}
for name, payload in documents.items():
    (scan_dir / name).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
  wb_recipe() {
    PY -c 'import json,sys; print(json.dumps({"repository": sys.argv[1], "mode": "standard", "config": {}, "target": {"kind": "repository", "paths": []}}))' "$1"
  }
  wb_scan() { # wb_scan <이름> <finding 키 목록> — 봉인·완료된 scanId 를 출력한다
    local dir="$RUN/$1" sid
    mkdir -p "$dir"; chmod 700 "$dir"
    sid="$(wb register-cli-scan --scan-dir "$dir" --repository "$WB_REPO" --recipe-json "$(wb_recipe "$WB_REPO")" \
      | PY -c 'import json,sys; print(json.load(sys.stdin)["scanId"])')" || return 1
    wb get-scan --scan-id "$sid" >"$dir.get.json" || return 1
    PY "$RUN/wb-draft.py" "$dir" "$dir.get.json" "$PLUGIN" "$2" || return 1
    PY "$PLUGIN/scripts/finalize_scan_contract.py" --scan-dir "$dir" >"$dir.seal.out" 2>&1 || return 1
    wb complete-scan --scan-id "$sid" >"$dir.complete.out" 2>&1 || return 1
    printf '%s' "$sid"
  }
  S1="$(wb_scan wb-s1 traversal,authz)" || S1=""
  S2="$(wb_scan wb-s2 traversal,authz-renamed)" || S2=""
  S3="$(wb_scan wb-s3 traversal,authz-renamed)" || S3=""
  if [ -z "$S1" ] || [ -z "$S2" ] || [ -z "$S3" ]; then
    bad "U0: 봉인 스캔 생성 실패 (S1=$S1 S2=$S2 S3=$S3): $(cat "$RUN"/wb-s*.seal.out "$RUN"/wb-s*.complete.out 2>/dev/null | head -c 600)"
  else
    ok "U0: 봉인 스캔 3개 생성"
    wb_inputs() { # wb_inputs <before> <after> <출력> — matchingInputs 만 추출
      wb compare-scans --before-scan-id "$1" --after-scan-id "$2" --include-matching-inputs >"$3.full" \
        && PY -c 'import json,sys; d=json.load(open(sys.argv[1])); json.dump(d["matchingInputs"], open(sys.argv[2], "w"))' "$3.full" "$3"
    }
    wb_save() { # wb_save <before> <after> <페이로드 파일> <라벨>
      local out code
      out="$(wb save-scan-comparison --before-scan-id "$1" --after-scan-id "$2" --matches-json-stdin <"$3" 2>&1)"
      code=$?
      expect_exit 0 "$code" "$4"
      [ "$code" = 0 ] || printf '     %s\n' "${out:0:600}"
      printf '%s' "$out" >"$3.saved"
    }

    # U1 (S2,S3) — AE2: 완결이면 서브에이전트 없이 저장
    wb_inputs "$S2" "$S3" "$RUN/u1-input.json" || bad "U1: compare-scans 실패"
    out="$(PY "$VALIDATOR" catalogue --input-json "$RUN/u1-input.json" \
      --catalogue-out "$RUN/u1-catalogue.json" --payload-out "$RUN/u1-payload.json" 2>&1)"
    expect_exit 0 "$?" "U1 (S2,S3) 카탈로그 생성"
    printf '%s' "$out" >"$RUN/u1-out.json"
    assert_json "U1b 모든 findingId 공유 → complete=true (AE2)" "$RUN/u1-out.json" 'd["complete"]' 'true'
    wb_save "$S2" "$S3" "$RUN/u1-payload.json" "U1c 완결 페이로드를 save-scan-comparison 이 받는다"
    assert_json "U1d 저장 뒤 compare-scans 가 이월 2건으로 렌더링" "$RUN/u1-payload.json.saved" \
      'd["summary"]["persisting"]' '2'

    # U2 (S1,S2) — 미완결: 대표 ID 로 판정 → finalize → 저장
    wb_inputs "$S1" "$S2" "$RUN/u2-input.json" || bad "U2: compare-scans 실패"
    out="$(PY "$VALIDATOR" catalogue --input-json "$RUN/u2-input.json" \
      --catalogue-out "$RUN/u2-catalogue.json" --payload-out "$RUN/u2-cat-payload.json" 2>&1)"
    expect_exit 0 "$?" "U2 (S1,S2) 카탈로그 생성"
    printf '%s' "$out" >"$RUN/u2-out.json"
    assert_json "U2b authz ↔ authz-renamed 는 findingId 가 달라 미완결" "$RUN/u2-out.json" 'd["complete"]' 'false'
    # 서브에이전트 역할: 신뢰 블록의 대표 ID 로만 판정한다. traversal 은 신원으로 이미 이어졌으므로
    # 판정하지 않아도 저장된다 — 여기서는 authz 쌍만 매칭하고, 우려 한 건을 보고한다.
    PY - "$RUN/u2-out.json" "$RUN/u2-input.json" "$RUN/u2-response.json" <<'PYEOF'
import json, sys
out = json.load(open(sys.argv[1])); inputs = json.load(open(sys.argv[2]))
titles = {row["occurrenceId"]: row["title"] for row in inputs["before"] + inputs["after"]}
linked = {b for link in out["trusted"]["appliedIdentityLinks"] for b in link["beforeRepresentativeIds"]}
before = [rep["id"] for rep in out["trusted"]["beforeRepresentatives"] if rep["id"] not in linked]
linked_after = {a for link in out["trusted"]["appliedIdentityLinks"] for a in link["afterOccurrenceIds"]}
after = [a for a in out["trusted"]["afterIds"] if a not in linked_after]
assert len(before) == 1 and len(after) == 1, (before, after)
issue = next(rep["issueId"] for rep in out["trusted"]["beforeRepresentatives"] if rep["id"] in linked)
json.dump({
    "matches": [{"beforeOccurrenceIds": before, "afterOccurrenceIds": after, "confidence": "high",
                 "reason": f"{titles[before[0]]} and {titles[after[0]]} share the missing admin guard."}],
    "uncertain": [],
    "priorGroupConcerns": [{"issueId": issue, "reason": "Synthetic concern for the report section."}],
}, open(sys.argv[3], "w"))
PYEOF
    out="$(PY "$VALIDATOR" finalize --input-json "$RUN/u2-input.json" \
      --matches-json "$RUN/u2-response.json" --payload-out "$RUN/u2-payload.json" 2>&1)"
    expect_exit 0 "$?" "U2c finalize 가 저장 페이로드를 낸다"
    printf '%s' "$out" >"$RUN/u2-final.json"
    assert_json "U2d 신원 매칭(traversal)과 판정 매칭(authz)이 모두 실린다" "$RUN/u2-payload.json" \
      'len(d["matches"])' '2'
    assert_json "U2e priorGroupConcerns 는 페이로드 밖에서 1건 반환" "$RUN/u2-final.json" \
      '[len(d["priorGroupConcerns"]), "priorGroupConcerns" in d["payload"]]' '[1, false]'
    wb_save "$S1" "$S2" "$RUN/u2-payload.json" "U2f finalize 페이로드를 save-scan-comparison 이 받는다"
    assert_json "U2g 저장 뒤 해결·신규 없이 이월 2건" "$RUN/u2-payload.json.saved" \
      '[d["summary"]["persisting"], d["summary"]["resolved"], d["summary"]["new"]]' '[2, 0, 0]'

    # U3 (S1,S3) — 앞의 저장이 knownFindingGroups 를 만든다 → 신원만으로 완결
    wb_inputs "$S1" "$S3" "$RUN/u3-input.json" || bad "U3: compare-scans 실패"
    assert_json "U3 knownFindingGroups 가 실려 온다 (스캔 3개 + 다른 쌍의 저장 비교)" "$RUN/u3-input.json" \
      '"knownFindingGroups" in d' 'true'
    out="$(PY "$VALIDATOR" catalogue --input-json "$RUN/u3-input.json" \
      --catalogue-out "$RUN/u3-catalogue.json" --payload-out "$RUN/u3-payload.json" 2>&1)"
    expect_exit 0 "$?" "U3b (S1,S3) 카탈로그 생성"
    printf '%s' "$out" >"$RUN/u3-out.json"
    assert_json "U3c 기확정 그룹으로 authz ↔ authz-renamed 가 이어져 complete=true" "$RUN/u3-out.json" \
      'd["complete"]' 'true'
    wb_save "$S1" "$S3" "$RUN/u3-payload.json" "U3d 기확정 그룹 완결 페이로드를 save-scan-comparison 이 받는다"
  fi
fi

printf '\n=== 결과 ===\n'
if [ "$FAILED" -ne 0 ]; then
  echo "FAILED ASSERTIONS: $FAILED"
  exit 1
fi
if [ -n "$MISSING" ]; then
  echo "INCOMPLETE — 전제 부족으로 일부 블록을 건너뛰었습니다: $MISSING"
  exit 2
fi
echo "ALL ASSERTIONS PASSED"
exit 0
