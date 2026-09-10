#!/usr/bin/env bash
# U5 재현 스크립트: 매칭 사전 검증기(validate_matches.py)가 상류 TS 판정 계층
# (sdk/typescript/src/scan-comparison.ts 의 validateComparison / unionFindingGroups)
# 규칙을 전부 재현하는지 자기 채점한다.
# 사용법: bash repro-u5-match-validator.sh
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
  out="$(PY "$VALIDATOR" --input-json "$input" --matches-json "$matches" "$@" 2>&1)"
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
# I. 기확정 그룹의 발생들이 서로 다른 매칭 그룹으로 흩어지면 거부 (R10)
# ---------------------------------------------------------------------------
step "I. 기확정 그룹 흩어짐 (R10)"

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
check 1 "I1 f1·f2 확정 그룹이 두 매칭 그룹으로 흩어짐" \
  "$RUN/input-known-before.json" "$RUN/scatter.json"
check 0 "I2 대조군: knownFindingGroups 없으면 같은 페이로드 통과" \
  "$RUN/input.json" "$RUN/scatter.json"

# ---------------------------------------------------------------------------
# J. 기확정 그룹이 before·after 양쪽에 있는데 미매칭이 남으면 거부 (R10)
# ---------------------------------------------------------------------------
step "J. 기확정 그룹 양쪽 존재 + 미매칭 (R10)"

cat >"$RUN/no-match.json" <<'EOF'
{
  "matches": [],
  "uncertain": []
}
EOF
check 1 "J1 f1·g1 확정 그룹인데 아무것도 매칭 안 됨" \
  "$RUN/input-known-cross.json" "$RUN/no-match.json"
check 0 "J2 대조군: knownFindingGroups 없으면 빈 매칭도 통과" \
  "$RUN/input.json" "$RUN/no-match.json"

cat >"$RUN/bad-known-uncertain.json" <<'EOF'
{
  "matches": [],
  "uncertain": [
    {"beforeOccurrenceId": "b1", "afterOccurrenceId": "a1", "reason": "maybe"}
  ]
}
EOF
check 1 "J3 확정 그룹을 uncertain 으로 격하하면 거부" \
  "$RUN/input-known-cross.json" "$RUN/bad-known-uncertain.json"

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
out="$(PY "$VALIDATOR" --input-json "$RUN/input.json" --matches-json "$RUN/ok-related.json" 2>&1)"
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
# M. findingId 싱글턴만으로도 R10 이 발동한다 — knownFindingGroups 가 없어도
#    같은 findingId 가 before·after 양쪽에 있으면 매칭이 강제된다(TS unionFindingGroups
#    가 각 findingId 싱글턴을 확정 그룹에 넣는다).
# ---------------------------------------------------------------------------
step "M. findingId 싱글턴 확정 그룹 (R10)"

cat >"$RUN/input-shared-finding.json" <<'EOF'
{
  "before": [{"occurrenceId": "b1", "findingId": "shared"}],
  "after": [{"occurrenceId": "a1", "findingId": "shared"}]
}
EOF
check 1 "M1 같은 findingId 양쪽 존재 + 미매칭" \
  "$RUN/input-shared-finding.json" "$RUN/no-match.json"

cat >"$RUN/ok-shared-finding.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "같은 findingId — 이월 파인딩"}
  ],
  "uncertain": []
}
EOF
check 0 "M2 같은 findingId 를 매칭하면 통과" \
  "$RUN/input-shared-finding.json" "$RUN/ok-shared-finding.json"

# ---------------------------------------------------------------------------
# N. union-find 이행적 병합 — 두 그룹이 제3의 findingId 로만 이어진 경우.
#
#    knownFindingGroups = [["f1","z9"], ["z9","f2"]] 이고 z9 는 이번 비교의
#    어느 쪽에도 없다(그 사이에 있던 다른 스캔의 findingId). 그룹을 각각 따로
#    보면 각 그룹에 이번 입력의 occurrence 가 1개뿐이라 흩어짐이 보이지 않는다.
#    이행적으로 병합해야만 f1·f2 가 한 그룹이라는 사실이 드러난다 — 이 블록만이
#    _union_finding_groups 의 병합을 단독으로 검증한다.
# ---------------------------------------------------------------------------
step "N. union-find 이행적 병합 (R10)"

PY - "$RUN/input.json" "$RUN/input-known-bridge.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
data["matchingInputs"]["knownFindingGroups"] = [["f1", "z9"], ["z9", "f2"]]
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
EOF
need_fixture "$RUN/input-known-bridge.json"

check 1 "N1 제3 findingId 로만 이어진 f1·f2 가 두 그룹으로 흩어짐" \
  "$RUN/input-known-bridge.json" "$RUN/scatter.json" "기확정 finding 그룹과 모순"

# 대조군: 병합을 하지 않으면 N1 이 통과해 버린다는 것을 확인한다.
# 각 그룹을 따로 두면(공유 findingId 없음) 같은 페이로드가 통과해야 한다.
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
    {"beforeOccurrenceIds": ["b1", "b2"], "afterOccurrenceIds": ["a1", "a2"],
     "confidence": "high", "reason": "이전 비교들에서 같은 finding 으로 확정된 이월분"}
  ],
  "uncertain": []
}
EOF
check 0 "N3 병합된 그룹을 한 매칭 그룹에 담으면 통과" \
  "$RUN/input-known-bridge.json" "$RUN/ok-bridge.json"

# ---------------------------------------------------------------------------
# O. stdin 경로(`-`)와 --allow-historical 회귀.
# ---------------------------------------------------------------------------
step "O. stdin 입력 / --allow-historical 회귀"
out="$(PY "$VALIDATOR" --input-json "$RUN/input.json" --matches-json - \
  <"$RUN/ok-related.json" 2>&1)"
expect_exit 0 "$?" "O1 matches-json 을 stdin 으로"
printf '     %s\n' "$out"
check 1 "O2 input/matches 동시 stdin 금지" "-" "-"

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
out="$(PY "$VALIDATOR" --input-json "$RUN/input.json" \
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
# P. blockedByPriorGroup 은 중단 신호다 — 통과시키지 않고 거부하며, 거부 사유에
#    해제 절차를 안내한다. 미지 키로 뭉개면 부모가 필드를 지워 우회한다.
# ---------------------------------------------------------------------------
step "P. blockedByPriorGroup 거부 (기확정 그룹 오판 신고)"

cat >"$RUN/blocked.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "제약을 맞추려 꾸민 매칭"}
  ],
  "uncertain": [],
  "blockedByPriorGroup": "그룹 [f1, g1] 은 근본 원인이 다릅니다 — 이전 비교의 오판으로 봅니다."
}
EOF
out="$(PY "$VALIDATOR" --input-json "$RUN/input-known-cross.json" \
  --matches-json "$RUN/blocked.json" 2>&1)"
expect_exit 1 "$?" "P1 blockedByPriorGroup 이 실리면 거부"
printf '     %s\n' "$out"
case "$out" in
  *"기확정 그룹이 틀렸다고 판단될 때"*) _p2_ok=1 ;;
  *) _p2_ok=0 ;;
esac
if [ "$_p2_ok" = 1 ]; then
  printf 'OK   P2: 거부 사유가 해제 절차를 가리킴\n'
else
  printf 'FAIL P2: 거부 사유에 해제 절차 안내가 없습니다\n'
  FAILED=$((FAILED + 1))
fi
# 같은 페이로드에서 그 필드만 빼면 통과한다 — 즉 거부는 그 필드 때문이다.
cat >"$RUN/blocked-stripped.json" <<'EOF'
{
  "matches": [
    {"beforeOccurrenceIds": ["b1"], "afterOccurrenceIds": ["a1"],
     "confidence": "high", "reason": "제약을 맞추려 꾸민 매칭"}
  ],
  "uncertain": []
}
EOF
check 0 "P3 대조군: 필드만 빼면 통과 (그래서 지우는 것을 금지한다)" \
  "$RUN/input-known-cross.json" "$RUN/blocked-stripped.json"

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
out="$(PY "$VALIDATOR" --input-json "$RUN/input-huge-row.json" --matches-json "$RUN/no-match.json" 2>&1)"
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

# Q2: 깊게 중첩된 값 → repr 재귀 폭주에도 JSON 봉투가 유지된다.
#     json.loads 는 통과하지만 repr 이 실패하는 깊이를 쓴다.
PY - "$RUN/input-deep-row.json" <<'EOF'
import sys
n = 50000
deep = "[" * n + "]" * n
open(sys.argv[1], "w", encoding="utf-8").write(
    '{"matchingInputs":{"before":[' + deep + '],'
    '"after":[{"occurrenceId":"a1","findingId":"g1"}]}}'
)
EOF
need_fixture "$RUN/input-deep-row.json"
out="$(PY "$VALIDATOR" --input-json "$RUN/input-deep-row.json" --matches-json "$RUN/no-match.json" 2>&1)"
code=$?
expect_exit 1 "$code" "Q2 깊게 중첩된 행은 거부"
# `"ok": false` 는 입력 파싱 실패 등 **모든** 거부 경로가 낸다 — 5만 중첩을 평범한
# 불량 행으로 바꿔도 초록이었다(실측). 방어의 고유 문구를 함께 요구한다. 그리고
# 파이프로 grep -q 에 넘기지 않는다(u7 이 같은 커밋에서 제거한 SIGPIPE/pipefail 함정).
case "$out" in
  *'"ok": false'*"repr 재귀 한도 초과"*)
    ok "Q2b: JSON 봉투 유지 + repr 재귀 방어가 실제로 발동" ;;
  *)
    bad "Q2b: 봉투 또는 repr 재귀 방어 근거가 없습니다 — 픽스처가 repr 경로에 도달하지 못했거나 방어가 사라졌습니다"
    printf '     %s\n' "${out%%$'\n'*}" ;;
esac

printf '\n=== 결과 ===\n'
if [ "$FAILED" -eq 0 ]; then
  echo "ALL ASSERTIONS PASSED"
  exit 0
fi
echo "FAILED ASSERTIONS: $FAILED"
exit 1
