#!/usr/bin/env bash
# U7·U8 재현 스크립트: 신규 스킬 두 개(codex-security-policy, codex-security-classify-severity)의 **결정론 부분**을
# 자기 채점한다. 서브에이전트 단계 자체는 돌리지 않는다 — 단계 결과는 미리 만든(canned) JSON 을 쓴다.
#
#   ── 정책 블록(U7: skills/codex-security-policy) ──────────────────────────────
#   P0  전제: 부트스트랩이 Node·SECURITY.md 헬퍼·상류 dist 를 해석하는가
#   P1  digest 벡터 — workflow_digest.mjs digest 가 상류 workflowDigest 규칙(키 JS 정렬 + JSON.stringify
#       + SHA-256)과 같은 값을 내는가. Python json.dumps 와 갈라지는 벡터 포함
#   P2  스냅샷 벡터 — inheritedPolicySha256 / previousPolicySha256 이 상류 규칙으로 독립 계산한 기대값과
#       같은가(조상 정책 0개·1개·링크). 대상 해석은 상류 CLI `policy --dry-run --json` 과 대조
#   P3  출력 디렉터리 — 위치·0700·0600·previous-SECURITY.md 선기록, 저장소 안 상태 디렉터리 거부(저장소 무변경)
#   P4  1 MiB 초과 정책은 해결 전에 보고
#   P5  헬퍼 없는 플러그인 사본 → 부트스트랩 available:false + prepare 중단 안내
#   P6  저장 전 검사·반환 처리 — 허용 루트 밖 절대 경로·개인 키 머리글 등 거부, 깨끗한 문서 수용,
#       비덮어쓰기, strict 스키마, blockedReason, 빈 markdown, 재시도 한도
#   P7  프롬프트 — 상류 리터럴 드리프트(설치된 dist 와 대조), 난수 표식, 미신뢰 구획, 소유자 답 형식
#   P8  마무리 — 스냅샷 불변이면 매니페스트(completed)·threatmodel.md·diff, 바뀌면 매니페스트는 threat_model_ready 그대로(AE4)
#   P9  실행 형태 — env -i 로 NODE_OPTIONS 주입이 끊기고, 남아 있으면 스크립트가 거부
#   P10 종단 결정론 흐름 — 파일 5개 0600, 저장소 밖, 대상 저장소 git status 깨끗
#   ── 심각도 블록(U8: skills/codex-security-classify-severity) ─────────────────────
#   S0  합성 봉인 스캔 — 격리 HOME/CODEX_HOME/STATE 로 `scan import --json`(예제 finding + 합성 finding 1개)
#   S1  첫 통합 단언 — 고정 반환값으로 prepare → apply 후 상류 dist readScanSeverityClassification 이
#       전부 읽는다. 대조군: 저장 행 inputSha256 첫 글자를 **다른** 글자로 바꾸면 같은 경로가 실패.
#       publish scan --dry-run 도 결과를 받아들인다(excluded 는 이슈에서 빠짐)
#   S2  AE5 같은 루브릭 재실행 → 판정 0회(전부 재사용)
#   S3  AE5 루브릭 한 글자 변경 → 전부 재판정. prepare 는 워크벤치를 쓰지 않는다(begin 미호출)
#   S4  --reprocess → 전부 재판정
#   S5  잘못된 반환(assessed+level null / 여분 키 / findingId 불일치) 거부, 1회 재판정 후 중단,
#       앞선 체크포인트 유지
#   S6  시작 전 거부 — 없는 finding ID, 스캔 입력 개수, 반환 파일 누락, prepare 이후 입력 변경
#   S7  루브릭 없음 → (0.5.1 이하) 상류 CLI 위임, 결과가 스킬 stateDir 워크벤치에 저장(대조군: STATE_DIR 누락)
#       (0.6.0) inherit 거부 + 상류 기본 루브릭 경로(rubricSha256 = workflowDigest([기본 루브릭]))
#   S8  대상 저장소 node_modules/.bin/node 가 PATH 맨 앞이어도 어떤 호출도 실행하지 않음
#   S9  NODE_OPTIONS 거부 · 셰뱅 없음
#   S10 조립 프롬프트 80,000자 상한 → 시작 전 거부   S11 PDF·DOCX 지식 베이스 거부
#   S12 상류 리터럴 드리프트(설치된 dist 대조), 난수 표식, 신뢰/미신뢰 구획 = 상류 프롬프트 원문
#   S13 npm 0.6.0 계약(#1765) — 리뷰 횟수(--runs, 기본 3)·작업 항목 = finding × run·상류 reviewSeverity 다수결
#       (2:1, 3자 동률 → 높은 심각도·assessed 우선)·리뷰 하나 무효면 finding 미저장·runs 불일치는 재사용 안 함·
#       --runs 범위 검사. 0.5.1 이하에서는 --runs 거부만 확인한다
#   심각도 블록의 버전 분기: 설치된 dist 에 default-severity-rubric.js 가 있으면 0.6.0 계약(SEV060=true)이다.
#   그 경우 S7 은 "inherit 거부 + 루브릭 생략 = 상류 기본 루브릭으로 서브에이전트 판정"을 확인하고,
#   S1~S6 의 작업 항목 수는 finding × 3 이다. 0.5.1 이하에서는 기존 단언(작업 항목 = finding, CLI 위임)을 유지한다.
#
# 종료코드: 0 = 전부 통과 / 2 = INCOMPLETE(전제 부족: node·상류 dist·헬퍼 없음) / 1 = 단언 실패.
# exit 2 는 통과가 아니다.
#
# 사용법: PYTHON="$(mise which python3)" bash repro-u8-policy-severity.sh
#   PYTHON=<python3>  CODEX_SECURITY_PLUGIN_ROOT=<_bundled_plugin 경로>(선택)
#   Node·플러그인·dist 는 이 저장소의 bootstrap.py 가 해석한다(스킬과 같은 경로).
set -u -o pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
: "${WORK:?WORK 경로 해석 실패 — 중단}"
SKILLS="$WORK/../../../skills"
BOOTSTRAP="$SKILLS/codex-security-scan/scripts/bootstrap.py"
DIGEST="$SKILLS/codex-security-scan/scripts/workflow_digest.mjs"
POLICY="$SKILLS/codex-security-policy/scripts/policy_draft.mjs"
for f in "$BOOTSTRAP"; do
  [ -f "$f" ] || { echo "오류: 필요한 파일이 없습니다: $f" >&2; exit 1; }
done

RUN="$(mktemp -d)"
: "${RUN:?임시 디렉터리 생성 실패 — 중단}"
trap 'rm -rf "$RUN"' EXIT
chmod 700 "$RUN"
export PYTHONDONTWRITEBYTECODE=1

PYTHON_BIN="${PYTHON:-$(command -v python3 || command -v python)}"
: "${PYTHON_BIN:?Python 3.10+ 인터프리터를 찾지 못했습니다. PYTHON=<경로> 로 지정하세요.}"
PY() { "$PYTHON_BIN" "$@"; }

FAILED=0
MISSING=""
step() { printf '\n=== %s ===\n' "$1"; }
ok()  { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }
missing() { MISSING="${MISSING}${MISSING:+; }$1"; printf 'INCOMPLETE — %s\n' "$1"; }
expect_exit() { # expect_exit <expected> <actual> <label>
  if [ "$2" = "$1" ]; then ok "$3: exit $2"; else bad "$3: exit $2 (expected $1)"; fi
}
expect_eq() { # expect_eq <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got [$2] expected [$1]"; fi
}
contains() { # contains <haystack> <needle> <label>
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3: [$2] 없음"; printf '     %s\n' "${1%%$'\n'*}" ;; esac
}
not_contains() {
  case "$1" in *"$2"*) bad "$3: [$2] 가 있으면 안 됨" ;; *) ok "$3" ;; esac
}
# jget <json 파일> <python 식(d 가 파싱된 값)> — 값 하나를 출력한다.
jget() { PY -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print(v if isinstance(v,str) else json.dumps(v))' "$1" "$2"; }
fmode() { PY -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))' "$1"; }
sha() { PY -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

GITC=(git -c user.email=repro@example.invalid -c user.name=repro -c commit.gpgsign=false)
mkrepo() { # mkrepo <dir> — 빈 git 저장소
  mkdir -p "$1" && "${GITC[@]}" -C "$1" init -q && return 0
}
commit_all() { "${GITC[@]}" -C "$1" add -A && "${GITC[@]}" -C "$1" commit -qm fixture --allow-empty; }

STATE="$RUN/state"

# ---------------------------------------------------------------------------
# P0. 전제 — 부트스트랩으로 Node·헬퍼·dist·trustedChildEnv 를 얻는다(스킬과 같은 경로)
# ---------------------------------------------------------------------------
step "P0. 부트스트랩 전제"
BOOT_REPO="$RUN/repos/boot"
mkrepo "$BOOT_REPO"
boot() { # boot <repo> <out.json> — 성공하면 0
  CODEX_SECURITY_STATE_DIR="$STATE" PY "$BOOTSTRAP" --target-repo "$1" --no-scan-dir >"$2" 2>"$2.err"
}
if ! boot "$BOOT_REPO" "$RUN/boot.json"; then
  missing "bootstrap 실패: $(head -c 400 "$RUN/boot.json")"
  echo "INCOMPLETE — 전제 부족: $MISSING"; exit 2
fi
HELPER_OK="$(jget "$RUN/boot.json" 'd["securityMdHelper"]["available"]')"
NODE_B="$(jget "$RUN/boot.json" '(d["node"] or {}).get("path") or ""')"
DIST="$(jget "$RUN/boot.json" 'd["sdk"]["dist"] or ""')"
SDK_CLI="$(jget "$RUN/boot.json" 'd["sdk"]["cli"] or ""')"
PLUGIN_ROOT="$(jget "$RUN/boot.json" 'd["pluginRoot"]')"
PLUGIN_VERSION="$(jget "$RUN/boot.json" 'd["pluginVersion"]')"
PLUGIN_SOURCE="$(jget "$RUN/boot.json" 'd["pluginSource"]')"
PYTHON_B="$(jget "$RUN/boot.json" '(d["python"] or {}).get("path") or ""')"
# 정책 리터럴과 threatmodel.md 투영은 npm 0.2.0 계약이다(상류 #1133). 0.1.32 이하 사본은 상류 policy
# 지시 첫 문장이 다르고 finalizer 에 --write-threat-model 이 없다. 그 사본에서는 해당 단언 대신 NOTE 를
# 낸다(repro-u4 I9·I13 과 같은 규약). 판별은 같은 릴리즈의 스키마 변경을 보는 부트스트랩 필드로 한다.
POLICY_020="$(jget "$RUN/boot.json" 'd.get("threatModelMarkdown")')"
note020() { printf 'NOTE %s: 이 플러그인 사본은 npm 0.2.0 이전이라 0.2.0 정책 계약 단언 대상이 아닙니다\n' "$1"; }
[ "$HELPER_OK" = "true" ] || missing "SECURITY.md 헬퍼 불가: $(jget "$RUN/boot.json" 'd["securityMdHelper"]["reason"]')"
[ -n "$DIST" ] || missing "상류 dist 없음(소스 체크아웃?): $(jget "$RUN/boot.json" 'd["sdk"]["reason"]')"
[ -n "$NODE_B" ] || missing "신뢰 Node 없음"
if [ -n "$MISSING" ]; then echo "INCOMPLETE — 전제 부족: $MISSING"; exit 2; fi
mapfile -d '' -t ENVV < <(PY -c 'import json,sys; [sys.stdout.write(e+"\0") for e in json.load(open(sys.argv[1]))["trustedChildEnv"]]' "$RUN/boot.json")
ok "node=$NODE_B plugin=$PLUGIN_VERSION dist=$DIST env=${#ENVV[@]}개"

# 스킬과 같은 호출 형태: env -i <trusted_child_env> <node> <script> …
RD() { env -i "${ENVV[@]}" "$NODE_B" "$DIGEST" "$@"; }
RP() { env -i "${ENVV[@]}" "$NODE_B" "$POLICY" "$@"; }
PREP_ARGS=(--sdk-dist "$DIST" --plugin-root "$PLUGIN_ROOT" --plugin-version "$PLUGIN_VERSION"
           --plugin-source "$PLUGIN_SOURCE" --state-dir "$STATE")

if [ ! -f "$DIGEST" ]; then bad "workflow_digest.mjs 가 없다: $DIGEST"; fi
if [ ! -f "$POLICY" ]; then bad "policy_draft.mjs 가 없다: $POLICY"; fi

# ---------------------------------------------------------------------------
# P1. digest 벡터 — 기대값은 상류 규칙을 Python 으로 독립 계산하거나, JS 의미가 갈라지는
#     지점은 JS JSON 문자열을 리터럴로 적어 SHA-256 한다.
# ---------------------------------------------------------------------------
step "P1. digest 벡터(상류 workflowDigest 규칙)"
digest_case() { # digest_case <label> <value-json> <expected-canonical-json-string>
  local out code want got
  printf '{"value": %s}' "$2" >"$RUN/dv.json"
  out="$(RD digest --sdk-dist "$DIST" --json-file "$RUN/dv.json")"; code=$?
  expect_exit 0 "$code" "P1 $1 실행"
  printf '%s' "$out" >"$RUN/dv.out"
  got="$(jget "$RUN/dv.out" 'd.get("sha256","")')"
  want="$(PY -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "$3")"
  expect_eq "$want" "$got" "P1 $1 digest 일치"
}
digest_case "키 재귀 정렬" '{"b":1,"a":[{"d":2,"c":1},"x"]}' '{"a":[{"c":1,"d":2},"x"],"b":1}'
digest_case "숫자 표기(1.0→1, Python 은 1.0)" '{"n":1.0,"m":1e21}' '{"m":1e+21,"n":1}'
digest_case "정수형 키 순서(JS 객체 규칙)" '{"10":1,"9":2,"a":3}' '{"9":2,"10":1,"a":3}'
digest_case "astral 키 UTF-16 정렬" '{"ﬁ":2,"😀":1}' "$(printf '{"\xf0\x9f\x98\x80":1,"\xef\xac\x81":2}')"
digest_case "스칼라 null" 'null' 'null'
# 대조군: Python json.dumps(sort_keys) 는 숫자·astral 벡터에서 다른 값을 낸다 — 위 벡터가 의미 있음을 확인
PYD="$(PY -c 'import hashlib,json; print(hashlib.sha256(json.dumps({"n":1.0,"m":1e21},sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
printf '{"value": {"n":1.0,"m":1e21}}' >"$RUN/dv.json"
RD digest --sdk-dist "$DIST" --json-file "$RUN/dv.json" >"$RUN/dv.out"
if [ "$(jget "$RUN/dv.out" 'd.get("sha256","")')" != "$PYD" ]; then ok "P1 대조군: Python json.dumps 결과와 다르다(재구현하면 어긋남)"; else bad "P1 대조군이 같다 — 벡터가 JS/Python 차이를 드러내지 못함"; fi
out="$(RD digest --json '{"value":1}')"; code=$?
expect_exit 1 "$code" "P1 --sdk-dist 누락은 사용법 오류"
contains "$out" "sdk.dist" "P1 --sdk-dist 누락 안내가 sdk.dist 를 가리킨다"

# ---------------------------------------------------------------------------
# P2. 스냅샷 벡터 — 상류 readSecurityPolicySnapshot 규칙을 Python 으로 독립 계산
#     inherited = sha256(JSON.stringify([[경로, sha256(내용) | "link:"+sha256(JSON.stringify({links,destination}))], …]))
#     조상 = 저장소 루트부터 컴포넌트의 부모까지(컴포넌트 자신은 제외). 링크가 정규 파일로 풀리면 항목이 하나 더 붙는다.
# ---------------------------------------------------------------------------
step "P2. 스냅샷 벡터(inheritedPolicySha256 / previousPolicySha256)"
R2="$RUN/repos/snap"
mkrepo "$R2"
mkdir -p "$R2/svc/api" "$R2/docs"
printf '# root policy\n' >"$R2/SECURITY.md"
printf '# svc policy\n' >"$R2/svc/SECURITY.md"
printf 'print(1)\n' >"$R2/svc/api/app.py"
commit_all "$R2"
snap() { # snap <repo> <path> <out>
  RD policy-snapshot --sdk-dist "$DIST" --repository "$1" --path "$2" >"$3"
}
expected_inherited() { # expected_inherited <json 배열 문자열(python 식)>
  PY - "$1" <<'PYEOF'
import hashlib, json, sys
d = lambda s: hashlib.sha256(s.encode("utf-8")).hexdigest()
entries = eval(sys.argv[1], {"d": d, "json": json})
print(d(json.dumps(entries, separators=(",", ":"), ensure_ascii=False)))
PYEOF
}
# (a) 조상 0개: scope "."
snap "$R2" . "$RUN/s0.json"; expect_exit 0 $? "P2a scope '.' 스냅샷"
expect_eq "$(expected_inherited '[]')" "$(jget "$RUN/s0.json" 'd["inheritedPolicySha256"]')" "P2a 조상 0개 → sha256('[]')"
expect_eq "$(PY -c 'import hashlib; print(hashlib.sha256(b"# root policy\n").hexdigest())')" \
  "$(jget "$RUN/s0.json" 'd["previousPolicySha256"]')" "P2a previousPolicySha256 = sha256(대상 내용)"
# (b) 조상 1개: scope "svc" → 루트 SECURITY.md 하나
snap "$R2" svc "$RUN/s1.json"; expect_exit 0 $? "P2b scope 'svc' 스냅샷"
expect_eq "$(expected_inherited '[["SECURITY.md", d("# root policy\n")]]')" \
  "$(jget "$RUN/s1.json" 'd["inheritedPolicySha256"]')" "P2b 조상 1개"
# (c) 조상 2개 + 대상 없음: scope "svc/api"
snap "$R2" svc/api "$RUN/s2.json"; expect_exit 0 $? "P2c scope 'svc/api' 스냅샷"
expect_eq "$(expected_inherited '[["SECURITY.md", d("# root policy\n")], ["svc/SECURITY.md", d("# svc policy\n")]]')" \
  "$(jget "$RUN/s2.json" 'd["inheritedPolicySha256"]')" "P2c 조상 2개"
expect_eq "null" "$(jget "$RUN/s2.json" 'd["previousPolicySha256"]')" "P2c 대상 정책이 없으면 previousPolicySha256 = null"
expect_eq "false" "$(jget "$RUN/s2.json" 'd["previousPresent"]')" "P2c previousPresent=false"
expect_eq "svc/api" "$(jget "$RUN/s2.json" 'd["target"]["scope"]')" "P2c scope 는 저장소 상대 경로"
# 상류 CLI 대조: policy --dry-run --json 이 같은 대상을 해석한다(인증·모델 호출 없음)
if [ -n "$SDK_CLI" ]; then
  env -i "${ENVV[@]}" CODEX_SECURITY_STATE_DIR="$STATE" CODEX_HOME="$STATE" "$NODE_B" "$SDK_CLI" \
    policy "$R2" --path svc/api --dry-run --headless --json >"$RUN/dry.json" 2>"$RUN/dry.err"
  if [ $? -eq 0 ]; then
    for k in repository scope targetPath; do
      expect_eq "$(jget "$RUN/dry.json" "d['$k']")" "$(jget "$RUN/s2.json" "d['target']['$k']")" "P2c 상류 CLI dry-run 과 $k 일치"
    done
  else
    bad "P2c 상류 CLI policy --dry-run 실패: $(head -c 300 "$RUN/dry.err")"
  fi
else
  missing "상류 CLI(sdk.cli) 없음 — dry-run 대조 생략"
fi
# (d) 링크: 루트 SECURITY.md → docs/SECURITY.md 심링크. 링크 항목 + 해석된 파일 항목 두 개.
R2L="$RUN/repos/snaplink"
mkrepo "$R2L"
mkdir -p "$R2L/svc" "$R2L/docs"
printf '# shared policy\n' >"$R2L/docs/SECURITY.md"
ln -s docs/SECURITY.md "$R2L/SECURITY.md"
commit_all "$R2L"
snap "$R2L" svc "$RUN/s3.json"; expect_exit 0 $? "P2d 링크 조상 스냅샷"
expect_eq "$(expected_inherited '[["SECURITY.md", "link:" + d(json.dumps({"links": [["SECURITY.md", "docs/SECURITY.md"]], "destination": "docs/SECURITY.md"}, separators=(",", ":"))) ], ["SECURITY.md", d("# shared policy\n")]]')" \
  "$(jget "$RUN/s3.json" 'd["inheritedPolicySha256"]')" "P2d 링크 조상(링크 digest + 파일 digest)"
# (e) 안정성: 같은 입력이면 같은 값, 조상 내용이 바뀌면 다른 값
snap "$R2" svc/api "$RUN/s2b.json"
expect_eq "$(jget "$RUN/s2.json" 'd["inheritedPolicySha256"]')" "$(jget "$RUN/s2b.json" 'd["inheritedPolicySha256"]')" "P2e 반복 계산 안정"
printf '# svc policy v2\n' >"$R2/svc/SECURITY.md"
snap "$R2" svc/api "$RUN/s2c.json"
if [ "$(jget "$RUN/s2.json" 'd["inheritedPolicySha256"]')" != "$(jget "$RUN/s2c.json" 'd["inheritedPolicySha256"]')" ]; then ok "P2e 조상 변경 → digest 변경"; else bad "P2e 조상 변경이 digest 에 반영되지 않음"; fi
"${GITC[@]}" -C "$R2" checkout -q -- svc/SECURITY.md

# ---------------------------------------------------------------------------
# P3. 출력 디렉터리 규칙
# ---------------------------------------------------------------------------
step "P3. 출력 디렉터리"
R3="$RUN/repos/outdir"
mkrepo "$R3"; mkdir -p "$R3/app"; printf '# app policy\n' >"$R3/app/SECURITY.md"; printf 'x\n' >"$R3/app/main.py"; commit_all "$R3"
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R3" --repository "$R3" --path app >"$RUN/p3.json"; code=$?
expect_exit 0 "$code" "P3 prepare"
OUT3="$(jget "$RUN/p3.json" 'd.get("outputDir","")')"
case "$OUT3" in
  "$(cd "$STATE" && pwd -P)/policies/outdir/codex-security-outdir-policy-"??????) ok "P3 위치 <stateDir>/policies/<repo>/codex-security-<repo>-policy-XXXXXX" ;;
  *) bad "P3 출력 디렉터리 위치: $OUT3" ;;
esac
[ -d "$OUT3" ] && expect_eq "0o700" "$(fmode "$OUT3")" "P3 출력 디렉터리 0700"
expect_eq "0o600" "$(fmode "$OUT3/previous-SECURITY.md" 2>/dev/null)" "P3 previous-SECURITY.md 0600"
expect_eq "$(sha "$R3/app/SECURITY.md")" "$(sha "$OUT3/previous-SECURITY.md" 2>/dev/null)" "P3 previous-SECURITY.md = 원래 대상 정책"
expect_eq "previous-SECURITY.md" "$(ls -A "$OUT3" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" "P3 준비 직후 출력 디렉터리에는 previous-SECURITY.md 하나뿐"
WORK3="$(jget "$RUN/p3.json" 'd.get("workDir","")')"
expect_eq "0o700" "$(fmode "$WORK3" 2>/dev/null)" "P3 작업 디렉터리 0700"
expect_eq "" "$("${GITC[@]}" -C "$R3" status --porcelain)" "P3 대상 저장소 무변경"
# 상태 디렉터리가 대상 저장소 안이면 거부 — 그리고 저장소 안에 아무 디렉터리도 만들지 않는다
RP prepare --sdk-dist "$DIST" --plugin-root "$PLUGIN_ROOT" --plugin-version "$PLUGIN_VERSION" \
  --plugin-source "$PLUGIN_SOURCE" --state-dir "$R3/.state" --bootstrap-repo-root "$R3" \
  --repository "$R3" --path app >"$RUN/p3b.json"; code=$?
expect_exit 2 "$code" "P3 저장소 안 상태 디렉터리 거부"
contains "$(cat "$RUN/p3b.json")" "outside" "P3 거부 사유(상류 OutputInsideProtectedRoot 계열)"
[ -e "$R3/.state" ] && bad "P3 거부했는데 저장소 안에 디렉터리를 만들었다" || ok "P3 거부 시 저장소 안에 아무것도 만들지 않음"
expect_eq "" "$("${GITC[@]}" -C "$R3" status --porcelain --ignored)" "P3 거부 후에도 저장소 무변경(무시 파일 포함)"
# 상위가 group-writable(스티키 없음)이면 상류 requireSecureOutputAncestry 가 거부
mkdir -p "$RUN/gw/state"; chmod 770 "$RUN/gw"; chmod 700 "$RUN/gw/state"
RP prepare --sdk-dist "$DIST" --plugin-root "$PLUGIN_ROOT" --plugin-version "$PLUGIN_VERSION" \
  --plugin-source "$PLUGIN_SOURCE" --state-dir "$RUN/gw/state" --bootstrap-repo-root "$R3" \
  --repository "$R3" --path app >"$RUN/p3c.json"; code=$?
expect_exit 2 "$code" "P3 group-writable 상위 거부"
contains "$(cat "$RUN/p3c.json")" "group- or world-writable" "P3 거부 사유(상류 문구)"
chmod 700 "$RUN/gw"
# 부트스트랩 신뢰 경계보다 넓은 worktree 는 거부(부트스트랩을 하위 디렉터리로 돌린 경우)
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R3/app" --repository "$R3" --path app >"$RUN/p3d.json"; code=$?
expect_exit 2 "$code" "P3 부트스트랩 대상이 worktree 루트보다 좁으면 거부"
contains "$(cat "$RUN/p3d.json")" "--target-repo" "P3 재부트스트랩 안내"
# 신뢰 게이트는 코드 실행보다 먼저다: 대상 저장소 안의 --plugin-root / --sdk-dist 는 그 안의
# mcp/helpers.mjs 나 dist 모듈을 실행·import 하기 **전에** 거부한다. 심은 코드는 실행되면 표식 파일을 만든다.
R3T="$RUN/repos/trustgate"
mkrepo "$R3T"; mkdir -p "$R3T/app"; printf 'x\n' >"$R3T/app/main.py"; commit_all "$R3T"
cp -R "$PLUGIN_ROOT" "$R3T/planted-plugin"
MARK_PLUGIN="$RUN/marker-plugin"
printf 'import { writeFileSync } from "node:fs";\nwriteFileSync(%s, "executed");\nprocess.stdout.write("[]");\n' \
  "$(PY -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MARK_PLUGIN")" >"$R3T/planted-plugin/mcp/helpers.mjs"
RP prepare --sdk-dist "$DIST" --plugin-root "$R3T/planted-plugin" --plugin-version "$PLUGIN_VERSION" \
  --plugin-source CODEX_SECURITY_PLUGIN_ROOT --state-dir "$STATE" --bootstrap-repo-root "$R3T" \
  --repository "$R3T" --path app >"$RUN/p3e.json"; code=$?
expect_exit 2 "$code" "P3 대상 저장소 안 --plugin-root 거부"
contains "$(cat "$RUN/p3e.json")" "신뢰 게이트 거부" "P3 --plugin-root 거부 사유(신뢰 게이트)"
[ -e "$MARK_PLUGIN" ] && bad "P3 거부 전에 저장소 안 helpers.mjs 를 실행했다" || ok "P3 저장소 안 helpers.mjs 미실행(표식 없음)"
mkdir -p "$R3T/planted-dist"
MARK_DIST="$RUN/marker-dist"
: >"$R3T/planted-dist/finding-workflow.js"
printf 'import { writeFileSync } from "node:fs";\nwriteFileSync(%s, "executed");\n' \
  "$(PY -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MARK_DIST")" >"$R3T/planted-dist/security-policy.js"
RP prepare --sdk-dist "$R3T/planted-dist" --plugin-root "$PLUGIN_ROOT" --plugin-version "$PLUGIN_VERSION" \
  --plugin-source "$PLUGIN_SOURCE" --state-dir "$STATE" --bootstrap-repo-root "$R3T" \
  --repository "$R3T" --path app >"$RUN/p3f.json"; code=$?
expect_exit 2 "$code" "P3 대상 저장소 안 --sdk-dist 거부"
contains "$(cat "$RUN/p3f.json")" "신뢰 게이트 거부" "P3 --sdk-dist 거부 사유(신뢰 게이트)"
[ -e "$MARK_DIST" ] && bad "P3 거부 전에 저장소 안 dist 모듈을 import 했다" || ok "P3 저장소 안 dist 모듈 미실행(표식 없음)"

# ---------------------------------------------------------------------------
# P4. 1 MiB 초과 정책 — 해결 전에 보고
# ---------------------------------------------------------------------------
step "P4. 1 MiB 초과 정책"
R4="$RUN/repos/big"
mkrepo "$R4"; mkdir -p "$R4/svc/deep" "$R4/other"
head -c 1100000 /dev/zero | tr '\0' 'x' >"$R4/svc/deep/SECURITY.md"
head -c 1100000 /dev/zero | tr '\0' 'y' >"$R4/other/SECURITY.md"
printf 'ok\n' >"$R4/svc/main.py"; commit_all "$R4"
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R4" --repository "$R4" --path svc >"$RUN/p4.json"; code=$?
expect_exit 2 "$code" "P4 컴포넌트 안 1 MiB 초과 정책이면 중단"
P4OUT="$(cat "$RUN/p4.json")"
contains "$P4OUT" "svc/deep/SECURITY.md" "P4 초과 정책 경로를 보고"
contains "$P4OUT" "1 MiB" "P4 1 MiB 사유"
[ -e "$STATE/policies/big" ] && bad "P4 해결 전 중단인데 출력 루트가 생김" || ok "P4 해결 전 중단 — 출력 디렉터리 미생성"
# 관계없는 컴포넌트의 초과 정책은 막지 않고 참고로만 보고한다
mkdir -p "$R4/web"; printf 'w\n' >"$R4/web/index.js"
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R4" --repository "$R4" --path web >"$RUN/p4b.json"; code=$?
expect_exit 0 "$code" "P4 관계없는 초과 정책은 중단 사유가 아님"
contains "$(cat "$RUN/p4b.json")" "other/SECURITY.md" "P4 관계없는 초과 정책도 참고로 보고"
RP cleanup --output-dir "$(jget "$RUN/p4b.json" 'd.get("outputDir","")')" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# P5. 헬퍼 없는 플러그인 사본
# ---------------------------------------------------------------------------
step "P5. 헬퍼 없는 플러그인 사본"
COPY="$RUN/plugin-copy/_bundled_plugin"
mkdir -p "$RUN/plugin-copy"
cp -R "$PLUGIN_ROOT" "$COPY"
rm -rf "$COPY/mcp"
CODEX_SECURITY_PLUGIN_ROOT="$COPY" CODEX_SECURITY_STATE_DIR="$STATE" PY "$BOOTSTRAP" --target-repo "$R3" --no-scan-dir >"$RUN/p5boot.json" 2>/dev/null
expect_eq "false" "$(jget "$RUN/p5boot.json" 'd["securityMdHelper"]["available"]')" "P5 부트스트랩 securityMdHelper.available=false"
contains "$(jget "$RUN/p5boot.json" 'd["securityMdHelper"]["reason"]')" "헬퍼 파일 없음" "P5 사유 = 헬퍼 파일 없음"
RP prepare --sdk-dist "$DIST" --plugin-root "$COPY" --plugin-version "$PLUGIN_VERSION" \
  --plugin-source CODEX_SECURITY_PLUGIN_ROOT --state-dir "$STATE" --bootstrap-repo-root "$R3" \
  --repository "$R3" --path app >"$RUN/p5.json"; code=$?
expect_exit 2 "$code" "P5 prepare 중단"
contains "$(cat "$RUN/p5.json")" "mcp/helpers.mjs" "P5 없는 파일을 지목"
contains "$(cat "$RUN/p5.json")" "npm install -g @openai/codex-security" "P5 한국어 설치 안내"

# ---------------------------------------------------------------------------
# P6. 저장 전 검사와 반환 처리 (P3 에서 만든 출력 디렉터리를 쓴다)
# ---------------------------------------------------------------------------
step "P6. 저장 전 검사·반환 처리"
stage_json() { # stage_json <file> <markdown> [questions-json] [reviewNotes-json] [blocked-json]
  PY - "$@" <<'PYEOF'
import json, sys
path, md = sys.argv[1], sys.argv[2]
q = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []
r = json.loads(sys.argv[4]) if len(sys.argv) > 4 else []
b = json.loads(sys.argv[5]) if len(sys.argv) > 5 else None
open(path, "w").write(json.dumps({"markdown": md, "questions": q, "reviewNotes": r, "blockedReason": b}))
PYEOF
}
ARCH_FILE="$(jget "$RUN/p3.json" 'd["stageResultFiles"]["architecture"]')"
save() { RP save-stage --output-dir "$OUT3" --stage "$1" >"$RUN/save.json"; }
# 허용 루트 밖 절대 경로 인용
stage_json "$ARCH_FILE" "# Spec
Reads \`$HOME/.ssh/config:3\` and \`$R3/../snap/SECURITY.md\`."
save architecture; expect_exit 2 $? "P6 허용 루트 밖 절대 경로 → 저장 거부"
contains "$(cat "$RUN/save.json")" "absolute-path-outside-allowed-roots" "P6 사유 종류"
[ -e "$OUT3/project-spec.md" ] && bad "P6 거부했는데 저장됨" || ok "P6 거부 시 미저장"
# 개인 키 머리글(질문 필드에 숨김) — 비밀 값 자체는 보고에 싣지 않는다
stage_json "$ARCH_FILE" "# Spec" '["Is -----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXk= expected?"]'
save architecture; expect_exit 2 $? "P6 개인 키 머리글 → 저장 거부"
contains "$(cat "$RUN/save.json")" "private-key-header" "P6 사유 종류(private-key-header)"
not_contains "$(cat "$RUN/save.json")" "b3BlbnNzaC1rZXk" "P6 보고에 비밀 값을 싣지 않음"
# 재시도 한도: 거부 3회째면 최종 거부
stage_json "$ARCH_FILE" "# Spec see .git/config and AKIAABCDEFGHIJKLMNOP"
save architecture; expect_exit 2 $? "P6 .git/·AWS 키 → 저장 거부"
S6="$(cat "$RUN/save.json")"
contains "$S6" "git-metadata-path" "P6 사유 종류(git-metadata-path)"
contains "$S6" "aws-access-key-id" "P6 사유 종류(aws-access-key-id)"
contains "$S6" '"retryAllowed": false' "P6 3회 거부면 재시도 불가"
# 거부 기록을 지우고(테스트 전용) 정상 흐름을 이어간다
rm -f "$WORK3"/architecture.rejected-*.json "$WORK3"/architecture.rejection.json
# strict 스키마: 여분 키 거부
printf '{"markdown":"# S","questions":[],"reviewNotes":[],"blockedReason":null,"extra":1}' >"$ARCH_FILE"
save architecture; expect_exit 2 $? "P6 여분 키 → invalid document response"
contains "$(cat "$RUN/save.json")" "invalid document response" "P6 상류 오류 문구"
rm -f "$WORK3"/architecture.rejected-*.json "$WORK3"/architecture.rejection.json
# 빈 markdown → 오류, 파일 없음
stage_json "$ARCH_FILE" "   "
save architecture; expect_exit 2 $? "P6 빈 markdown → 오류"
contains "$(cat "$RUN/save.json")" "returned an empty document" "P6 상류 빈 문서 문구"
rm -f "$WORK3"/architecture.rejected-*.json "$WORK3"/architecture.rejection.json
# 로컬 배치 접두어가 아니어도 `:줄번호` 절대 인용이면 허용 루트 밖을 읽은 흔적이다
stage_json "$ARCH_FILE" "# Spec
Config at \`/etc/nginx/nginx.conf:12\`."
save architecture; expect_exit 2 $? "P6 절대 경로 줄 인용 → 저장 거부"
contains "$(cat "$RUN/save.json")" "/etc/nginx/nginx.conf:12" "P6 거부한 경로를 보고"
rm -f "$WORK3"/architecture.rejected-*.json "$WORK3"/architecture.rejection.json
# `file:///절대경로` 와 `키:/절대경로` 형태도 절대 경로로 검사한다(홈 디렉터리 = 로컬 배치 접두어)
PW_HOME="$(PY -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
stage_json "$ARCH_FILE" "# Spec
Credentials come from file://$PW_HOME/.aws/credentials."
save architecture; expect_exit 2 $? "P6 file:// URL 의 홈 경로 → 저장 거부"
contains "$(cat "$RUN/save.json")" "$PW_HOME/.aws/credentials" "P6 file:// 뒤 경로를 보고"
rm -f "$WORK3"/architecture.rejected-*.json "$WORK3"/architecture.rejection.json
stage_json "$ARCH_FILE" "# Spec
Deploy key path:$PW_HOME/.ssh/id_rsa is used."
save architecture; expect_exit 2 $? "P6 키:/절대경로 형태의 홈 경로 → 저장 거부"
contains "$(cat "$RUN/save.json")" "$PW_HOME/.ssh/id_rsa" "P6 콜론 뒤 경로를 보고"
rm -f "$WORK3"/architecture.rejected-*.json "$WORK3"/architecture.rejection.json
# 깨끗한 문서 수용 — 일반 시스템 경로·API 경로·URL 은 허용
stage_json "$ARCH_FILE" "# Project spec
Entry point \`app/main.py:1\`. Path traversal could reach /etc/passwd via /api/v1/files. See https://example.com/docs/a.
Mirror: ssh://git.example.com/org/repo.git and https://docs.example.com/guide/setup.html:12." \
  '["Is the service internet-facing?","Who can call /admin?","Are tenants isolated?","Is TLS terminated upstream?"]' '["Deployment unknown"]'
save architecture; expect_exit 0 $? "P6 깨끗한 문서 저장"
expect_eq "0o600" "$(fmode "$OUT3/project-spec.md" 2>/dev/null)" "P6 project-spec.md 0600"
expect_eq "4" "$(jget "$RUN/save.json" 'len(d["questions"])')" "P6 질문 4개 반환"
expect_eq "[3, 1]" "$(jget "$RUN/save.json" '[len(b) for b in d["questionBatches"]]')" "P6 질문은 3개씩 묶음"
# 비덮어쓰기: 이미 저장된 단계는 다시 저장하지 않는다(내용 불변)
BEFORE="$(sha "$OUT3/project-spec.md")"
stage_json "$ARCH_FILE" "# replaced"
save architecture; expect_exit 2 $? "P6 이미 있는 파일은 덮어쓰지 않음"
expect_eq "$BEFORE" "$(sha "$OUT3/project-spec.md")" "P6 기존 파일 내용 불변"
# 순서: policy 단계는 threat_model 없이 저장할 수 없다
stage_json "$(jget "$RUN/p3.json" 'd["stageResultFiles"]["policy"]')" "# Policy"
save policy; expect_exit 2 $? "P6 단계 순서 강제"
# blockedReason: markdown 이 있으면 먼저 저장하고 멈춘다. 이후 단계는 진행하지 않는다.
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R3" --repository "$R3" --path app >"$RUN/p6b.json"
OUT6B="$(jget "$RUN/p6b.json" 'd["outputDir"]')"
stage_json "$(jget "$RUN/p6b.json" 'd["stageResultFiles"]["architecture"]')" "# Partial spec" '[]' '[]' '"could not read app/"'
RP save-stage --output-dir "$OUT6B" --stage architecture >"$RUN/save.json"; expect_exit 2 $? "P6 blockedReason → 실패 종료"
expect_eq "blocked" "$(jget "$RUN/save.json" 'd["status"]')" "P6 status=blocked"
contains "$(cat "$RUN/save.json")" "stage could not inspect the required evidence: could not read app/" "P6 상류 blocked 문구"
[ -f "$OUT6B/project-spec.md" ] && ok "P6 blocked 전에 문서를 먼저 저장" || bad "P6 blocked 문서 미저장"
RP prompt --output-dir "$OUT6B" --stage threat_model >/dev/null; expect_exit 2 $? "P6 blocked 이후 단계 진행 불가"
RP cleanup --output-dir "$OUT6B" >/dev/null
# 거부 뒤의 프롬프트에는 거부 종류가 재시도 안내로 들어간다(값은 싣지 않는다)
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R3" --repository "$R3" --path app >"$RUN/p6c.json"
OUT6C="$(jget "$RUN/p6c.json" 'd["outputDir"]')"
stage_json "$(jget "$RUN/p6c.json" 'd["stageResultFiles"]["architecture"]')" "# Spec token ghp_abcdefghijklmnopqrstuvwxyz0123456789AB"
RP save-stage --output-dir "$OUT6C" --stage architecture >/dev/null
RP prompt --output-dir "$OUT6C" --stage architecture >"$RUN/pr6c.txt"
contains "$(cat "$RUN/pr6c.txt")" "Retry notice" "P6 거부 후 프롬프트에 재시도 안내"
contains "$(cat "$RUN/pr6c.txt")" "a GitHub token" "P6 재시도 안내에 거부 종류"
not_contains "$(cat "$RUN/pr6c.txt")" "ghp_abcdefghij" "P6 재시도 안내에 거부된 값 없음"
RP cleanup --output-dir "$OUT6C" >/dev/null
# threat_model 단계의 blockedReason: 매니페스트는 status=blocked 로 남고 이후 단계·마무리는 진행하지 않는다.
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R3" --repository "$R3" --path app >"$RUN/p6d.json"
OUT6D="$(jget "$RUN/p6d.json" 'd["outputDir"]')"
stage_json "$(jget "$RUN/p6d.json" 'd["stageResultFiles"]["architecture"]')" "# Spec"
RP save-stage --output-dir "$OUT6D" --stage architecture >/dev/null; expect_exit 0 $? "P6d architecture 저장"
stage_json "$(jget "$RUN/p6d.json" 'd["stageResultFiles"]["threat_model"]')" "# Partial model" '[]' '[]' '"could not read app/"'
RP save-stage --output-dir "$OUT6D" --stage threat_model --python "$PYTHON_B" >"$RUN/s6d.json"; expect_exit 2 $? "P6d threat_model blockedReason → 실패 종료"
expect_eq "blocked" "$(jget "$RUN/s6d.json" 'd["status"]')" "P6d 응답 status=blocked"
expect_eq "blocked|# Partial model" "$(jget "$OUT6D/policy-draft.json" 'd["status"] + "|" + d["threatModel"]["content"]')" "P6d 매니페스트 status=blocked·모델 유지"
# blocked 로 멈춘 단계를 다시 저장해도 매니페스트를 바꾸지 않고 거부한다(수용된 단계와 같은 규칙).
M6D_BEFORE="$(sha "$OUT6D/policy-draft.json")"
stage_json "$(jget "$RUN/p6d.json" 'd["stageResultFiles"]["threat_model"]')" "# Other model"
RP save-stage --output-dir "$OUT6D" --stage threat_model --python "$PYTHON_B" >/dev/null 2>&1; expect_exit 2 $? "P6d blocked 단계 재저장 거부"
expect_eq "$M6D_BEFORE" "$(sha "$OUT6D/policy-draft.json")" "P6d 재저장 시도 뒤 policy-draft.json 불변"
RP prompt --output-dir "$OUT6D" --stage policy >/dev/null 2>&1; expect_exit 2 $? "P6d blocked 이후 policy 단계 진행 불가"
RP finish --output-dir "$OUT6D" --python "$PYTHON_B" >/dev/null 2>&1; expect_exit 2 $? "P6d blocked 세션은 finish 거부"
expect_eq "blocked" "$(jget "$OUT6D/policy-draft.json" 'd["status"]')" "P6d finish 거부 뒤에도 status=blocked"
RP cleanup --output-dir "$OUT6D" >/dev/null
# threatmodel.md 투영 실패: 쓸 수 없는 인터프리터를 주면 상류 resolvePluginPython 이 거부한다. 저장은 성공하고
# threatModelPath 는 null, 경고가 실리며 정본(매니페스트 threatModel)은 남는다. 버전과 무관하게 일어난다.
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R3" --repository "$R3" --path app >"$RUN/p6e.json"
OUT6E="$(jget "$RUN/p6e.json" 'd["outputDir"]')"
stage_json "$(jget "$RUN/p6e.json" 'd["stageResultFiles"]["architecture"]')" "# Spec"
RP save-stage --output-dir "$OUT6E" --stage architecture >/dev/null; expect_exit 0 $? "P6e architecture 저장"
stage_json "$(jget "$RUN/p6e.json" 'd["stageResultFiles"]["threat_model"]')" "# Model"
RP save-stage --output-dir "$OUT6E" --stage threat_model --python "$RUN/no-such-python" >"$RUN/s6e.json"; expect_exit 0 $? "P6e 투영 실패여도 threat_model 저장 성공"
expect_eq "None" "$(jget "$RUN/s6e.json" 'repr(d["path"])')" "P6e path=null"
contains "$(jget "$RUN/s6e.json" 'd["threatModelWarning"] or ""')" "Could not save threatmodel.md" "P6e 투영 실패 경고"
[ -e "$OUT6E/threatmodel.md" ] && bad "P6e threatmodel.md 가 생김" || ok "P6e threatmodel.md 없음"
expect_eq "threat_model_ready|# Model" "$(jget "$OUT6E/policy-draft.json" 'd["status"] + "|" + d["threatModel"]["content"]')" "P6e 정본은 매니페스트에 남음"
RP cleanup --output-dir "$OUT6E" >/dev/null

# ---------------------------------------------------------------------------
# P7. 프롬프트
# ---------------------------------------------------------------------------
step "P7. 프롬프트"
RP upstream-literals >"$RUN/lit.json"; expect_exit 0 $? "P7 리터럴 목록"
PY - "$RUN/lit.json" "$DIST/security-policy.js" "$DIST/security-policy-cli.js" <<'PYEOF' >"$RUN/lit.check"
import json, sys
lit = json.load(open(sys.argv[1]))
src = open(sys.argv[2], encoding="utf-8").read()
cli = open(sys.argv[3], encoding="utf-8").read()
frags = lit["fragments"] + lit["cliFragments"]
miss = [f for f in lit["fragments"] if f not in src] + [f for f in lit["cliFragments"] if f not in cli]
print(len(frags), len(miss))
for f in miss: print("MISSING:", f[:120])
PYEOF
read -r NFRAG NMISS <"$RUN/lit.check"
if [ "$POLICY_020" != "true" ]; then note020 "P7 리터럴 드리프트"; elif [ "${NFRAG:-0}" -ge 25 ] && [ "${NMISS:-1}" = "0" ]; then ok "P7 상류 리터럴 ${NFRAG}조각이 설치된 dist/security-policy.js 에 문자 그대로 있음"; else bad "P7 리터럴 드리프트: $(cat "$RUN/lit.check")"; fi
RP prompt --output-dir "$OUT3" --stage threat_model >"$RUN/pr1.txt"; expect_exit 0 $? "P7 threat_model 프롬프트(헤드리스)"
RP prompt --output-dir "$OUT3" --stage threat_model >"$RUN/pr2.txt"
PR1="$(cat "$RUN/pr1.txt")"
contains "$PR1" "No additional owner clarification was supplied." "P7 답 없음 → 상류 헤드리스 문구"
contains "$PR1" "do not inspect sibling source or Git metadata" "P7 상류 머리말 원문 유지(npm 0.5.1 문구)"
contains "$PR1" "Allowed read roots" "P7 대체 조치: 허용 읽기 루트 명시"
contains "$PR1" "artifact-storage.md" "P7 저장 정책 비적용 지시(P6-KTD8)"
M1="$(PY -c 'import re,sys; m=re.search(r"\[TRUSTED_INSTRUCTIONS ([0-9a-f]{16})\]", open(sys.argv[1]).read()); print(m.group(1) if m else "")' "$RUN/pr1.txt")"
M2="$(PY -c 'import re,sys; m=re.search(r"\[TRUSTED_INSTRUCTIONS ([0-9a-f]{16})\]", open(sys.argv[1]).read()); print(m.group(1) if m else "")' "$RUN/pr2.txt")"
[ -n "$M1" ] && [ "$M1" != "$M2" ] && ok "P7 호출마다 새 난수 표식" || bad "P7 표식: [$M1] [$M2]"
# 미신뢰 데이터(질문 문자열·정책 내용)는 미신뢰 구획 안에만 있다
PY - "$RUN/pr1.txt" "$M1" <<'PYEOF' >"$RUN/pr1.check"
import sys
text, m = open(sys.argv[1]).read(), sys.argv[2]
start = text.index(f"[UNTRUSTED_EVIDENCE {m}]"); end = text.index(f"[/UNTRUSTED_EVIDENCE {m}]")
outside = text[:start] + text[end:]
inside = text[start:end]
bad = [s for s in ("Is the service internet-facing?", "# app policy") if s in outside or s not in inside]
defense = text.count(f"<<< {m}")
print("ok" if not bad and defense == 2 else f"bad {bad} defense={defense}")
PYEOF
expect_eq "ok" "$(cat "$RUN/pr1.check")" "P7 미신뢰 구획 분리 + 방어 문구 앞뒤 2회"
# 소유자 답: 상류 형식("질문\n답"을 빈 줄로 연결, 3개 묶음 단위)
printf '["Yes, public.","","Row-level checks.","TLS at LB."]' >"$(jget "$RUN/p3.json" 'd["ownerAnswersFile"]')"
RP prompt --output-dir "$OUT3" --stage threat_model >"$RUN/pr3.txt"; expect_exit 0 $? "P7 답이 있는 threat_model 프롬프트"
PY - "$RUN/pr3.txt" <<'PYEOF' >"$RUN/pr3.check"
import json, re, sys
text = open(sys.argv[1]).read()
m = re.search(r'item "ownerClarification" \(JSON-encoded data\):\n(.*)\n', text)
want = [{"questions": ["Is the service internet-facing?", "Who can call /admin?", "Are tenants isolated?"],
         "answer": "Is the service internet-facing?\nYes, public.\n\nAre tenants isolated?\nRow-level checks."},
        {"questions": ["Is TLS terminated upstream?"], "answer": "Is TLS terminated upstream?\nTLS at LB."}]
print("ok" if m and json.loads(m.group(1)) == want and "No additional owner clarification" not in text else "bad")
PYEOF
expect_eq "ok" "$(cat "$RUN/pr3.check")" "P7 소유자 답 상류 형식·3개 묶음"
RP prompt --output-dir "$OUT3" --stage policy >/dev/null 2>&1; expect_exit 2 $? "P7 앞 단계 없이 policy 프롬프트 불가"

# ---------------------------------------------------------------------------
# P8. 마무리 — 스냅샷 불변/변경(AE4)
# ---------------------------------------------------------------------------
step "P8. 마무리"
run_stages() { # run_stages <prepare.json> — canned 3단계 저장
  local p="$1" od
  od="$(jget "$p" 'd["outputDir"]')"
  stage_json "$(jget "$p" 'd["stageResultFiles"]["architecture"]')" "# Spec
\`app/main.py:1\`" '["Q1?"]' '["N1"]'
  RP save-stage --output-dir "$od" --stage architecture >/dev/null || return 1
  stage_json "$(jget "$p" 'd["stageResultFiles"]["threat_model"]')" "# Threat model" '["TQ?"]' '["TN"]'
  RP save-stage --output-dir "$od" --stage threat_model --python "$PYTHON_B" >/dev/null || return 1
  stage_json "$(jget "$p" 'd["stageResultFiles"]["policy"]')" "# Security Policy
New draft." '[]' '["N1","PN"]'
  RP save-stage --output-dir "$od" --stage policy >/dev/null || return 1
}
# (a) 불변 → 매니페스트 + diff
R8="$RUN/repos/finish"
mkrepo "$R8"; mkdir -p "$R8/app"; printf '# root\n' >"$R8/SECURITY.md"; printf '# old app policy\n' >"$R8/app/SECURITY.md"; printf 'x\n' >"$R8/app/main.py"; commit_all "$R8"
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R8" --repository "$R8" --path app >"$RUN/p8.json"
run_stages "$RUN/p8.json"; expect_exit 0 $? "P8a 3단계 저장"
OUT8="$(jget "$RUN/p8.json" 'd["outputDir"]')"
# 비덮어쓰기(threat_model): 수용된 단계를 다시 저장하면 부작용 없이 거부한다. 매니페스트·threatmodel.md
# 가 바뀌거나 blocked 기록이 생기면 수용된 세션이 다른 모델로 초안을 쓰거나 finish 에서 거부된다.
M8_BEFORE="$(sha "$OUT8/policy-draft.json")"
TM8_BEFORE="$( [ -f "$OUT8/threatmodel.md" ] && sha "$OUT8/threatmodel.md" || echo none)"
stage_json "$(jget "$RUN/p8.json" 'd["stageResultFiles"]["threat_model"]')" "# replaced model" '[]' '[]' '"re-run"'
RP save-stage --output-dir "$OUT8" --stage threat_model --python "$PYTHON_B" >"$RUN/s8re.json"; expect_exit 2 $? "P8a 수용된 threat_model 재저장 거부"
expect_eq "$M8_BEFORE" "$(sha "$OUT8/policy-draft.json")" "P8a 재저장 시도 뒤 policy-draft.json 불변"
expect_eq "$TM8_BEFORE" "$( [ -f "$OUT8/threatmodel.md" ] && sha "$OUT8/threatmodel.md" || echo none)" "P8a 재저장 시도 뒤 threatmodel.md 불변"
RP finish --output-dir "$OUT8" --python "$PYTHON_B" >"$RUN/f8.json"; expect_exit 0 $? "P8a finish"
expect_eq "0o600" "$(fmode "$OUT8/policy-draft.json" 2>/dev/null)" "P8a policy-draft.json 0600"
PY - "$OUT8/policy-draft.json" "$R8" "$(jget "$RUN/p8.json" 'd["inheritedPolicySha256"]')" "$(sha "$R8/app/SECURITY.md")" "$PLUGIN_VERSION" <<'PYEOF' >"$RUN/m8.check"
import json, sys
m = json.load(open(sys.argv[1]))
keys = ["documentType","schemaVersion","repository","scope","createdAt","revision","previousPolicySha256","inheritedPolicySha256","model","reasoningEffort","pluginVersion","customPlugin","status","threatModel","reviewNotes"]
problems = []
if list(m) != keys: problems.append(f"keys {list(m)}")
if m.get("documentType") != "codex-security.policy-draft" or m.get("schemaVersion") != "1.0": problems.append("type")
if m.get("repository") != sys.argv[2] or m.get("scope") != "app": problems.append("target")
if m.get("inheritedPolicySha256") != sys.argv[3]: problems.append("inherited")
if m.get("previousPolicySha256") != sys.argv[4]: problems.append("previous")
if m.get("pluginVersion") != sys.argv[5]: problems.append("pluginVersion")
if "claude" not in str(m.get("model","")).lower(): problems.append("model")
if m.get("reviewNotes") != ["N1","PN","Q1?","TN","TQ?"]: problems.append(f"reviewNotes {m.get('reviewNotes')}")
if m.get("status") != "completed": problems.append(f"status {m.get('status')}")
if m.get("threatModel") != {"format": "markdown", "content": "# Threat model", "scope": {"includePaths": ["app"], "excludePaths": []}, "origin": "generated"}: problems.append(f"threatModel {m.get('threatModel')}")
if not isinstance(m.get("revision"), str) or len(m["revision"]) < 40: problems.append("revision")
print("ok" if not problems else "bad " + "; ".join(problems))
PYEOF
expect_eq "ok" "$(cat "$RUN/m8.check")" "P8a 매니페스트 스키마·값(reviewNotes 는 상류 합집합 순서)"
if [ "$POLICY_020" = "true" ]; then
  expect_eq "$OUT8/threatmodel.md" "$(jget "$RUN/f8.json" 'd["threatModelPath"]')" "P8a threatModelPath = finalizer 가 투영한 threatmodel.md"
  contains "$(cat "$OUT8/threatmodel.md" 2>/dev/null)" "# Threat model" "P8a threatmodel.md 에 매니페스트 threatModel.content 투영"
else
  # 0.1.x finalizer 에는 투영 옵션이 없다 — 스킬은 경고와 null 로 계속한다(정본은 매니페스트에 남는다).
  expect_eq "None" "$(jget "$RUN/f8.json" 'repr(d["threatModelPath"])')" "P8a 0.1.x: threatModelPath=null(투영 불가)"
  contains "$(jget "$RUN/f8.json" 'd["threatModelWarning"] or ""')" "Could not save threatmodel.md" "P8a 0.1.x: 투영 실패 경고"
fi
F8="$(cat "$RUN/f8.json")"
contains "$F8" "--- a/app/SECURITY.md" "P8a diff a/ 라벨"
contains "$F8" "+++ b/app/SECURITY.md" "P8a diff b/ 라벨"
expect_eq "draft" "$(jget "$RUN/f8.json" 'd["status"]')" "P8a status=draft"
[ -e "$(jget "$RUN/p8.json" 'd["workDir"]')" ] && bad "P8a 작업 디렉터리가 남음" || ok "P8a 작업 디렉터리 정리"
# (b) 새 파일: 대상 정책이 없으면 /dev/null
R8N="$RUN/repos/finishnew"
mkrepo "$R8N"; mkdir -p "$R8N/app"; printf 'x\n' >"$R8N/app/main.py"; commit_all "$R8N"
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R8N" --repository "$R8N" --path app >"$RUN/p8n.json"
run_stages "$RUN/p8n.json"
RP finish --output-dir "$(jget "$RUN/p8n.json" 'd["outputDir"]')" --python "$PYTHON_B" >"$RUN/f8n.json"; expect_exit 0 $? "P8b finish(새 정책)"
contains "$(cat "$RUN/f8n.json")" "--- /dev/null" "P8b 새 파일 diff 는 /dev/null"
expect_eq "null" "$(jget "$(jget "$RUN/p8n.json" 'd["outputDir"]')/policy-draft.json" 'd["previousPolicySha256"]')" "P8b previousPolicySha256=null"
# (c) AE4: 생성 중 대상 SECURITY.md 변경 → 매니페스트 없음 + 한국어 보고, 세 문서는 남음
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R8" --repository "$R8" --path app >"$RUN/p8c.json"
run_stages "$RUN/p8c.json"
printf '# edited by owner\n' >"$R8/app/SECURITY.md"
OUT8C="$(jget "$RUN/p8c.json" 'd["outputDir"]')"
RP finish --output-dir "$OUT8C" --python "$PYTHON_B" >"$RUN/f8c.json"; expect_exit 2 $? "P8c 대상 변경 → finish 실패"
contains "$(cat "$RUN/f8c.json")" "생성 후 SECURITY.md가 바뀜 — 새 초안 필요" "P8c AE4 한국어 문구"
# 상류 0.2.0: threat_model 단계 직후 매니페스트를 쓰므로 남지만 completed 로 갱신되지 않는다
expect_eq "threat_model_ready" "$(jget "$OUT8C/policy-draft.json" 'd["status"]' 2>/dev/null)" "P8c 매니페스트는 threat_model_ready 그대로(completed 아님)"
P8C_FILES="project-spec.md SECURITY.md"; [ "$POLICY_020" = "true" ] && P8C_FILES="project-spec.md threatmodel.md SECURITY.md"
for f in $P8C_FILES; do [ -f "$OUT8C/$f" ] && ok "P8c $f 남음" || bad "P8c $f 없음"; done
"${GITC[@]}" -C "$R8" checkout -q -- app/SECURITY.md
# (d) 조상 정책 변경도 같은 규칙
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R8" --repository "$R8" --path app >"$RUN/p8d.json"
run_stages "$RUN/p8d.json"
printf '# root edited\n' >"$R8/SECURITY.md"
OUT8D="$(jget "$RUN/p8d.json" 'd["outputDir"]')"
RP finish --output-dir "$OUT8D" --python "$PYTHON_B" >"$RUN/f8d.json"; expect_exit 2 $? "P8d 조상 변경 → finish 실패"
contains "$(cat "$RUN/f8d.json")" "An inherited SECURITY.md changed" "P8d 상류 상속 변경 문구"
expect_eq "threat_model_ready" "$(jget "$OUT8D/policy-draft.json" 'd["status"]' 2>/dev/null)" "P8d 매니페스트는 threat_model_ready 그대로(completed 아님)"
"${GITC[@]}" -C "$R8" checkout -q -- SECURITY.md
# (e) 중간 매니페스트가 없거나 createdAt 이 없으면 finish 는 매니페스트를 새로 만들지 않고 멈춘다.
for variant in missing no-created-at; do
  RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R8" --repository "$R8" --path app >"$RUN/p8e.json"
  run_stages "$RUN/p8e.json"; expect_exit 0 $? "P8e($variant) 3단계 저장"
  OUT8E="$(jget "$RUN/p8e.json" 'd["outputDir"]')"
  if [ "$variant" = missing ]; then rm -f "$OUT8E/policy-draft.json"; else printf '{}\n' >"$OUT8E/policy-draft.json"; fi
  RP finish --output-dir "$OUT8E" --python "$PYTHON_B" >"$RUN/f8e.json"; expect_exit 2 $? "P8e($variant) finish 거부"
  contains "$(cat "$RUN/f8e.json")" "threat_model 단계에서 쓴 매니페스트가 없거나 createdAt 이 없다" "P8e($variant) 사유"
  RP cleanup --output-dir "$OUT8E" >/dev/null
done

# ---------------------------------------------------------------------------
# P9. 실행 형태 — env -i 가 NODE_OPTIONS 주입을 끊는다
# ---------------------------------------------------------------------------
step "P9. env -i / NODE_OPTIONS"
HOOK="$RUN/hook.cjs"; MARK="$RUN/hook.ran"
printf 'require("fs").writeFileSync(%s, "x");\n' "$(PY -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MARK")" >"$HOOK"
printf '{"value": 1}' >"$RUN/dv1.json"
# 대조군: env -i 없이 부르면 훅이 실행되고, 스크립트는 그 사실을 감지해 거부한다
NODE_OPTIONS="--require=$HOOK" "$NODE_B" "$DIGEST" digest --sdk-dist "$DIST" --json-file "$RUN/dv1.json" >"$RUN/p9a.json" 2>/dev/null; code=$?
[ -e "$MARK" ] && ok "P9 대조군: env -i 없이는 NODE_OPTIONS 훅이 실행됨(실측 재현)" || bad "P9 대조군 훅이 실행되지 않음 — 테스트가 무력"
expect_exit 2 "$code" "P9 NODE_OPTIONS 가 남아 있으면 스크립트가 거부"
contains "$(cat "$RUN/p9a.json")" "env -i" "P9 거부 안내"
rm -f "$MARK"
NODE_OPTIONS="--require=$HOOK" env -i "${ENVV[@]}" "$NODE_B" "$DIGEST" digest --sdk-dist "$DIST" --json-file "$RUN/dv1.json" >"$RUN/p9b.json"; code=$?
expect_exit 0 "$code" "P9 env -i 형태는 정상 실행"
[ -e "$MARK" ] && bad "P9 env -i 인데 훅이 실행됨" || ok "P9 env -i 형태에서는 훅이 실행되지 않음"
# 셰뱅 없음·실행 비트 없음(셰뱅 실행이면 PATH 의 node 가 선택된다)
for s in "$DIGEST" "$POLICY"; do
  head -c 2 "$s" | grep -q '#!' && bad "P9 셰뱅이 있음: $s" || ok "P9 셰뱅 없음: ${s##*/}"
done

# ---------------------------------------------------------------------------
# P10. 종단 결정론 흐름 (합성 저장소)
# ---------------------------------------------------------------------------
step "P10. 종단 결정론 흐름"
R10="$RUN/repos/e2e"
mkrepo "$R10"; mkdir -p "$R10/svc"; printf '# Root policy\nReport privately.\n' >"$R10/SECURITY.md"
printf 'def handler(req):\n    return req.args["q"]\n' >"$R10/svc/app.py"; commit_all "$R10"
boot "$R10" "$RUN/boot10.json" || bad "P10 bootstrap"
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$(jget "$RUN/boot10.json" 'd["repoRoot"]')" --repository "$R10" --path svc >"$RUN/p10.json"; expect_exit 0 $? "P10 prepare"
run_stages "$RUN/p10.json"; expect_exit 0 $? "P10 3단계 저장"
OUT10="$(jget "$RUN/p10.json" 'd["outputDir"]')"
RP finish --output-dir "$OUT10" --python "$PYTHON_B" >"$RUN/f10.json"; expect_exit 0 $? "P10 finish"
P10_WANT="SECURITY.md policy-draft.json previous-SECURITY.md project-spec.md"
[ "$POLICY_020" = "true" ] && P10_WANT="$P10_WANT threatmodel.md"
expect_eq "$P10_WANT" \
  "$(cd "$OUT10" && ls -A | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "P10 파일 목록(0.1.x 는 threatmodel.md 없이 4개)"
modes="$(cd "$OUT10" && for f in *; do fmode "$f"; done | sort -u | tr '\n' ' ' | sed 's/ $//')"
expect_eq "0o600" "$modes" "P10 5개 모두 0600"
case "$OUT10" in "$R10"/*) bad "P10 출력이 저장소 안" ;; *) ok "P10 출력은 저장소 밖" ;; esac
expect_eq "" "$("${GITC[@]}" -C "$R10" status --porcelain --ignored)" "P10 대상 저장소 git status 깨끗"

# ---------------------------------------------------------------------------
# P11. 상류 런타임 프롬프트 동등성 — 상류 runSecurityPolicyStages 에 가짜 run() 을 넣어 실제로
#      만들어진 세 단계 프롬프트를 받고, 우리 render-upstream(미신뢰 값을 상류처럼 제자리에 넣은 형태)과
#      문자 단위로 대조한다. 출력 디렉터리 경로만 치환한다(두 실행의 디렉터리가 다르다).
#      우리 `prompt` 는 이 텍스트에서 미신뢰 값 자리를 참조 문구로 바꾸고 신뢰/미신뢰 구획을 두른 것이다.
# ---------------------------------------------------------------------------
step "P11. 상류 런타임 프롬프트 동등성"
R11="$RUN/repos/parity"
mkrepo "$R11"; mkdir -p "$R11/svc/sub" "$R11/.github"
printf '# Root\nReport to sec@example.invalid\n' >"$R11/SECURITY.md"
printf '# Svc policy\n' >"$R11/svc/SECURITY.md"
printf '# Sub policy\n' >"$R11/svc/sub/SECURITY.md"
printf '# Reporting\n' >"$R11/.github/SECURITY.md"
printf 'x = 1\n' >"$R11/svc/app.py"; commit_all "$R11"
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R11" --repository "$R11" --path svc >"$RUN/p11.json"; expect_exit 0 $? "P11 prepare"
OUT11="$(jget "$RUN/p11.json" 'd["outputDir"]')"
PY - "$RUN/canned.json" <<'PYEOF'
import json, sys
json.dump({
  "architecture": {"markdown": "# Spec\n`svc/app.py:1`", "questions": ["Q1?", "Q2?", "Q3?", "Q4?"], "reviewNotes": ["A-note"], "blockedReason": None},
  "threat_model": {"markdown": "# TM", "questions": ["TQ?"], "reviewNotes": ["T-note"], "blockedReason": None},
  "policy": {"markdown": "# Policy", "questions": [], "reviewNotes": ["P-note"], "blockedReason": None},
  "answers": ["yes", "", "no", "maybe"],
}, open(sys.argv[1], "w"))
PYEOF
for st in architecture threat_model policy; do
  RP render-upstream --output-dir "$OUT11" --stage "$st" >"$RUN/ours-$st.txt" || bad "P11 render-upstream $st"
  PY -c 'import json,sys; c=json.load(open(sys.argv[1])); json.dump(c[sys.argv[2]], open(sys.argv[3],"w"))' "$RUN/canned.json" "$st" "$(jget "$RUN/p11.json" "d['stageResultFiles']['$st']")"
  RP save-stage --output-dir "$OUT11" --stage "$st" >/dev/null || bad "P11 save-stage $st"
  if [ "$st" = architecture ]; then
    PY -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["answers"], open(sys.argv[2],"w"))' "$RUN/canned.json" "$(jget "$RUN/p11.json" 'd["ownerAnswersFile"]')"
  fi
done
cat >"$RUN/upstream_prompts.mjs" <<'JSEOF'
import { mkdtemp, readFile } from "node:fs/promises";
import { join } from "node:path";
const [dist, pluginRoot, repo, scope, cannedPath, tmpRoot] = process.argv.slice(2);
const sp = await import(join(dist, "security-policy.js"));
const canned = JSON.parse(await readFile(cannedPath, "utf8"));
const target = await sp.resolveSecurityPolicyTarget(repo, scope);
const sources = await sp.inspectSecurityPolicySources(target);
const roots = await sp.securityPolicyProtectedRoots(target);
const gitMetadataPaths = [...new Set([...[...new Set([...roots, ...sources.gitMetadataPaths])].slice(1), ...sources.gitMetadataPaths])];
const snapshot = await sp.readSecurityPolicySnapshot(target, undefined, gitMetadataPaths);
const guidance = await sp.resolveSecurityPolicyGuidance(target, pluginRoot, process.env, undefined, sources.policyPaths, gitMetadataPaths);
const outputDir = await mkdtemp(join(tmpRoot, "upstream-"));
const prompts = {};
let asked = 0;
await sp.runSecurityPolicyStages({
  target, snapshot, policyPaths: sources.policyPaths, gitMetadataPaths, outputDir, pluginRoot, guidance,
  revision: null, model: "m", reasoningEffort: "e", pluginVersion: "v", signal: new AbortController().signal,
  // security-policy-cli.ts 의 대화형 answerQuestions 와 같은 조립
  answerQuestions: async (questions) => {
    const parts = [];
    for (const q of questions) { const a = canned.answers[asked++] ?? ""; if (a.trim()) parts.push(`${q}\n${a}`); }
    return parts.join("\n\n");
  },
  run: async (stage, prompt) => { prompts[stage] = prompt; return canned[stage]; },
  cost: () => null,
});
process.stdout.write(JSON.stringify({ outputDir, prompts }));
JSEOF
mkdir -p "$RUN/up"; chmod 700 "$RUN/up"
env -i "${ENVV[@]}" "$NODE_B" "$RUN/upstream_prompts.mjs" "$DIST" "$PLUGIN_ROOT" "$R11" svc "$RUN/canned.json" "$RUN/up" >"$RUN/up.json" 2>"$RUN/up.err"
expect_exit 0 $? "P11 상류 runSecurityPolicyStages(가짜 run) 실행"
PY - "$RUN/up.json" "$OUT11" "$RUN" <<'PYEOF' >"$RUN/p11.check"
import json, sys
up = json.load(open(sys.argv[1])); ours_dir = sys.argv[2]; run = sys.argv[3]
bad = []
for st in ("architecture", "threat_model", "policy"):
    theirs = up["prompts"][st].replace(json.dumps(up["outputDir"])[1:-1], json.dumps(ours_dir)[1:-1])
    ours = open(f"{run}/ours-{st}.txt", encoding="utf-8").read()
    if ours != theirs:
        i = next((k for k, (a, b) in enumerate(zip(ours, theirs)) if a != b), min(len(ours), len(theirs)))
        bad.append(f"{st}@{i}: ours={ours[i:i+80]!r} upstream={theirs[i:i+80]!r}")
print("ok" if not bad else "bad " + " | ".join(bad))
PYEOF
if [ "$POLICY_020" = "true" ]; then
  expect_eq "ok" "$(cat "$RUN/p11.check")" "P11 세 단계 프롬프트가 상류 런타임과 문자 단위로 같음(자리표시자 값 포함)"
else
  note020 "P11 상류 런타임 프롬프트 동등성"
fi
contains "$(cat "$RUN/ours-architecture.txt")" '"svc/sub/SECURITY.md"' "P11 하위 정책이 policyPaths 에 포함"
RP cleanup --output-dir "$OUT11" >/dev/null

# ===========================================================================
# SEVERITY BLOCK (U8) — skills/codex-security-classify-severity
#   상류 dist 함수(classifyScan…SeverityInternal + 가짜 Codex)로 분류·저장하고, 판정 자리만 고정 반환값
#   (canned)으로 바꾼다. 검증 기준은 상류 TS 읽기 경로(readScanSeverityClassification — publish 가 쓰는
#   함수)다. 워크벤치 read-severity-classification(0.2.0 Python / 0.4.0 Node 헬퍼)은 digest 를 거르지 않으므로
#   행 존재 확인에만 쓴다. 저장 행 직접 확인(db_col)은 두 버전 모두 쓰는 finding_severity_assessments 를 본다.
# ===========================================================================
CLASSIFY="$SKILLS/codex-security-classify-severity/scripts/classify_severity.mjs"
[ -f "$CLASSIFY" ] || bad "classify_severity.mjs 가 없다: $CLASSIFY"
if [ -z "$SDK_CLI" ] || [ -z "$PYTHON_B" ]; then
  # 심각도 블록은 scan import·CLI 위임에 npm CLI 가 필요하다. 없으면 이 블록 전체가 전제 부족이다.
  missing "상류 CLI(sdk.cli) 또는 부트스트랩 python 없음 — 심각도 블록을 건너뜀"
  [ "$FAILED" -ne 0 ] && { echo "FAILED: $FAILED assertion(s)"; exit 1; }
  echo "INCOMPLETE — 전제 부족: $MISSING"; exit 2
fi

# ---------------------------------------------------------------------------
# S0. 합성 봉인 스캔 — HOME·CODEX_HOME·STATE 를 격리한 scan import(상위 디렉터리 전부 0700)
# ---------------------------------------------------------------------------
step "S0. 합성 봉인 스캔(scan import)"
SEV="$RUN/sev"; mkdir -p "$SEV/home" "$SEV/codex" "$SEV/state" "$SEV/in" "$SEV/repo"; chmod 700 "$SEV" "$SEV"/*
SSTATE="$SEV/state"
mkrepo "$SEV/repo" >/dev/null
CODEX_SECURITY_STATE_DIR="$SSTATE" PY "$BOOTSTRAP" --target-repo "$SEV/repo" --no-scan-dir >"$SEV/boot.json" 2>"$SEV/boot.err" \
  || bad "S0 심각도용 부트스트랩 실패: $(head -c 300 "$SEV/boot.json")"
mapfile -d '' -t ENVS < <(PY -c 'import json,sys; [sys.stdout.write(e+"\0") for e in json.load(open(sys.argv[1]))["trustedChildEnv"]]' "$SEV/boot.json")
expect_eq "$(cd "$SSTATE" && pwd -P)" "$(jget "$SEV/boot.json" 'd["stateDir"]')" "S0 부트스트랩 stateDir = 격리 상태 디렉터리"
PY - "$PLUGIN_ROOT/examples/completed-scan/findings.json" "$SEV/in/findings.json" <<'PYEOF'
import copy, json, sys
doc = json.load(open(sys.argv[1]))
first = doc["findings"][0]
second = copy.deepcopy(first)
second.update(
    findingId="csf_000000000000000000000002",
    occurrenceId="occ_000000000000000000000002",
    ruleId="ssrf.preview-fetch",
    title="Server-side request forgery through preview fetch",
    summary="A user-supplied URL is fetched without host allow-listing. 한글 요약 포함.",
)
second["identity"] = {"anchor": "preview-fetch-without-allowlist"}
second["fingerprints"] = {"algorithm": "codex-security/v1", "primary": "codex-security/v1:sha256:" + "ab" * 32}
second["severity"] = {"level": "medium", "rationale": "Only an internal service is reachable.",
                      "changeConditions": "Internet exposure of the preview endpoint would raise it."}
doc["findings"].append(second)
json.dump(doc, open(sys.argv[2], "w"), indent=1)
PYEOF
IMPORT_ENV=(HOME="$SEV/home" CODEX_HOME="$SEV/codex" CODEX_SECURITY_STATE_DIR="$SSTATE" PATH=/usr/bin:/bin PYTHON="$PYTHON_B")
(cd "$SEV" && env -i "${IMPORT_ENV[@]}" "$NODE_B" "$SDK_CLI" scan import --json "$SEV/in/findings.json" --format json) >"$SEV/import.json" 2>"$SEV/import.err"
expect_exit 0 $? "S0 scan import --json"
SCAN_ID="$(jget "$SEV/import.json" 'd["manifest"]["scan"]["id"]')"
SCAN_DIR="$(jget "$SEV/import.json" 'd["scanDir"]')"
FID_A="$(jget "$SEV/import.json" 'd["findings"]["findings"][0]["findingId"]')"
FID_B="$(jget "$SEV/import.json" 'd["findings"]["findings"][1]["findingId"]')"
[ -n "$SCAN_ID" ] && [ -d "$SCAN_DIR" ] && ok "S0 봉인 스캔 $SCAN_ID (finding 2개: $FID_A, $FID_B)" || bad "S0 스캔 ID·디렉터리 없음"
SEAL_BEFORE="$(cd "$SCAN_DIR" && sha256sum scan-manifest.json findings.json coverage.json)"

# 버전 분기(파일 존재 프로브 — 스킬의 severityContract 와 같은 기준). 0.6.0 계약이면 finding 마다 리뷰 3회(기본).
if [ -f "$DIST/default-severity-rubric.js" ]; then SEV060=true; RUNS=3; else SEV060=false; RUNS=1; fi
ok "S0 심각도 계약: SEV060=$SEV060 (finding 당 기본 작업 항목 $RUNS 개)"
note060() { printf 'NOTE %s: 이 상류는 npm 0.6.0 이전이라 0.6.0 심각도 계약 단언 대상이 아닙니다\n' "$1"; }

# 스킬과 같은 호출 형태
RC() { env -i "${ENVS[@]}" "$NODE_B" "$CLASSIFY" "$@"; }
CS_ARGS=(--sdk-dist "$DIST" --state-dir "$SSTATE" --python "$PYTHON_B")

# 독립 대조 도구: 상류 dist 읽기 경로를 이 스크립트가 직접 부른다(스킬 코드를 거치지 않는다).
cat >"$SEV/dist_read.mjs" <<'JSEOF'
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const [dist, scanDir, stateDir, python] = process.argv.slice(2);
const load = (m) => import(pathToFileURL(join(dist, m)).href);
const { loadContractWithScanDirectory } = await load("contract.js");
const { bundledPluginRoot } = await load("runtime.js");
const { readScanSeverityClassification } = await load("classify-scan-severity.js");
const { contract, scanDirectory } = await loadContractWithScanDirectory(scanDir, { pluginRoot: await bundledPluginRoot() });
const environment = { ...process.env, CODEX_SECURITY_STATE_DIR: stateDir, PYTHON: python };
try {
  const result = await readScanSeverityClassification(scanDirectory, contract.manifest.scan.id, contract.findings.findings, undefined, environment);
  process.stdout.write(JSON.stringify({ ok: true, present: result !== undefined, result: result ?? null }));
} catch (error) {
  process.stdout.write(JSON.stringify({ ok: false, error: String(error?.message ?? error) }));
}
JSEOF
dist_read() { env -i "${ENVS[@]}" "$NODE_B" "$SEV/dist_read.mjs" "$DIST" "$SCAN_DIR" "$SSTATE" "$PYTHON_B" >"$1"; }
db_col() { # db_col <finding_id> <column> — 저장 행의 값(없으면 빈 문자열)
  PY -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); r=c.execute(f"SELECT {sys.argv[3]} FROM finding_severity_assessments WHERE finding_id=?",(sys.argv[2],)).fetchone(); print("" if r is None or r[0] is None else r[0])' "$SSTATE/workbench.sqlite3" "$1" "$2"
}
db_set() { # db_set <finding_id> <column> <value>
  # npm 0.4.0(bf9a5bce9)부터 상류 읽기 경로는 스캔별 행(scan_severity_assessments)을 읽는다. 그 표가 있으면 같이 바꾼다.
  PY -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); [c.execute(f"UPDATE {t} SET {sys.argv[3]}=? WHERE finding_id=?",(sys.argv[4],sys.argv[2])) for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type=\"table\" AND name IN (\"finding_severity_assessments\",\"scan_severity_assessments\")").fetchall()]; c.commit()' "$SSTATE/workbench.sqlite3" "$1" "$2" "$3"
}
# canned <prepare.json> <findingId> <answer-json> — 그 finding 의 모든 run 의 answerFile 에 같은 고정 반환값을 쓴다
canned() {
  local file
  while IFS= read -r file; do printf '%s' "$3" >"$file"; done < <(PY -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(p["answerFile"]) for p in d["pending"] if p["findingId"]==sys.argv[2]]' "$1" "$2")
}
# canned_run <prepare.json> <findingId> <run> <answer-json> — 그 finding 의 run 하나에만 쓴다
canned_run() {
  local file
  file="$(PY -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(p["answerFile"] for p in d["pending"] if p["findingId"]==sys.argv[2] and p.get("run",1)==int(sys.argv[3])))' "$1" "$2" "$3")"
  printf '%s' "$4" >"$file"
}
# ans <findingId> <decision> <level|null> <rubricLabel|null> <rationale> — 7키 반환 JSON
ans() {
  PY -c 'import json,sys; f,d,l,r,t=sys.argv[1:6]; n=lambda v: None if v=="null" else v; print(json.dumps({"findingId":f,"decision":d,"level":n(l),"rubricLabel":n(r),"rationale":t,"confidence":None,"reviewTrigger":None}))' "$@"
}
ANS_A_OK="{\"findingId\":\"$FID_A\",\"decision\":\"assessed\",\"level\":\"high\",\"rubricLabel\":\"High\",\"rationale\":\"Unauthenticated attacker writes outside the extraction root.\",\"confidence\":\"high\",\"reviewTrigger\":null}"
ANS_B_EXCL="{\"findingId\":\"$FID_B\",\"decision\":\"excluded\",\"level\":null,\"rubricLabel\":null,\"rationale\":\"The rubric excludes internal-only SSRF.\",\"confidence\":\"medium\",\"reviewTrigger\":\"Evidence that the preview endpoint is internet-facing.\"}"
printf '# Severity rubric\n\nHigh: remote unauthenticated file write.\nExcluded: SSRF that reaches only internal services.\n' >"$SEV/in/rubric.md"
printf 'The extraction service runs as an unprivileged user.\n' >"$SEV/in/kb.txt"

# ---------------------------------------------------------------------------
# S1. 첫 통합 단언 — 루브릭 경로 결과를 상류 dist 읽기 경로가 digest 재확인을 거쳐 읽는다 + 대조군
# ---------------------------------------------------------------------------
step "S1. 루브릭 분류 → 상류 dist 읽기 경로 + 대조군(inputSha256 변조)"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric.md" --knowledge-base "$SEV/in/kb.txt" >"$SEV/s1p.json"; code=$?
expect_exit 0 "$code" "S1 prepare"
expect_eq "$((2 * RUNS))" "$(jget "$SEV/s1p.json" 'len(d.get("pending",[]))')" "S1 작업 항목 = finding 2개 × 리뷰 $RUNS 회(저장 평가 없음)"
expect_eq "[\"$FID_A\", \"$FID_B\"]" "$(jget "$SEV/s1p.json" 'd.get("pendingFindings")')" "S1 판정할 finding 2개"
S1W="$(jget "$SEV/s1p.json" 'd.get("workDir","")')"
if [ "$SEV060" = true ]; then
  expect_eq "3" "$(jget "$SEV/s1p.json" 'd.get("classificationRuns")')" "S1 기본 리뷰 횟수 3(상류 classificationRunsSchema.default(3))"
  expect_eq "[1, 2, 3, 1, 2, 3]" "$(jget "$SEV/s1p.json" '[p.get("run") for p in d.get("pending",[])]')" "S1 작업 항목은 finding 마다 run 1·2·3(상류 호출 순서)"
  expect_eq "6" "$(jget "$SEV/s1p.json" 'd.get("subagentCalls")')" "S1 비용 고지값: 서브에이전트 호출 6회"
  expect_eq "True" "$(PY -c 'import sys; r=[open(f"{sys.argv[1]}/upstream/{i}.txt").read() for i in range(1,7)]; print(r[0]==r[1]==r[2] and r[3]==r[4]==r[5] and r[0]!=r[3])' "$S1W")" "S1 같은 finding 의 run 들은 상류 프롬프트가 같다(앞 답을 보여주지 않는 독립 리뷰)"
else
  expect_eq "null" "$(jget "$SEV/s1p.json" 'd.get("classificationRuns")')" "S1 0.5.1 이하: 리뷰 횟수 개념 없음(classificationRuns null)"
fi
canned "$SEV/s1p.json" "$FID_A" "$ANS_A_OK"
canned "$SEV/s1p.json" "$FID_B" "$ANS_B_EXCL"
RC apply --work-dir "$S1W" >"$SEV/s1a.json"; code=$?
expect_exit 0 "$code" "S1 apply(상류 classifyScanDirectorySeverityInternal + 가짜 Codex)"
dist_read "$SEV/s1r.json"
expect_eq "true" "$(jget "$SEV/s1r.json" 'd["ok"]')" "S1 상류 readScanSeverityClassification 이 오류 없이 읽는다"
expect_eq "[\"$FID_A\", \"$FID_B\"]" "$(jget "$SEV/s1r.json" '[a["findingId"] for a in (d.get("result") or {}).get("assessments",[])]')" "S1 선택 finding 전부의 평가를 반환"
expect_eq '["assessed:high:High", "excluded:None:None"]' "$(jget "$SEV/s1r.json" '[":".join(str(a[k]) for k in ("decision","level","rubricLabel")) for a in (d.get("result") or {}).get("assessments",[])]')" "S1 결정·레벨·루브릭 라벨이 고정 반환값 그대로"
expect_eq "$(RD digest --sdk-dist "$DIST" --json "{\"value\": [$(PY -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$SEV/in/rubric.md")]}" | PY -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" \
  "$(jget "$SEV/s1r.json" '(d.get("result") or {}).get("rubricSha256")')" "S1 rubricSha256 = workflowDigest([루브릭 텍스트])"
[ -f "$SCAN_DIR/severity-classification.json" ] && ok "S1 severity-classification.json 기록" || bad "S1 severity-classification.json 없음"
expect_eq "0o600" "$(fmode "$SCAN_DIR/severity-classification.json" 2>/dev/null)" "S1 결과 파일 0600"
expect_eq "2" "$(jget "$SCAN_DIR/severity-classification.json" 'len(d["assessments"])')" "S1 결과 파일 평가 수 = 선택 finding 수"
expect_eq "$SEAL_BEFORE" "$(cd "$SCAN_DIR" && sha256sum scan-manifest.json findings.json coverage.json)" "S1 봉인 정본 파일 불변"
# 대조군: 저장 행 inputSha256 첫 글자를 **다른** 글자로 바꾸면 같은 읽기 경로가 실패해야 한다.
ORIG_SHA="$(db_col "$FID_A" input_sha256)"
case "$ORIG_SHA" in 0*) NEW_SHA="1${ORIG_SHA:1}" ;; *) NEW_SHA="0${ORIG_SHA:1}" ;; esac
db_set "$FID_A" input_sha256 "$NEW_SHA"
TAMPERED="$(db_col "$FID_A" input_sha256)"
if [ -n "$ORIG_SHA" ] && [ "$TAMPERED" != "$ORIG_SHA" ] && [ "$TAMPERED" = "$NEW_SHA" ]; then ok "S1 대조군: 저장 행 값이 실제로 바뀜(${ORIG_SHA:0:4}… → ${TAMPERED:0:4}…)"; else bad "S1 대조군 변조가 값을 바꾸지 못함([$ORIG_SHA] → [$TAMPERED])"; fi
dist_read "$SEV/s1t.json"
expect_eq "false" "$(jget "$SEV/s1t.json" 'd["ok"]')" "S1 대조군: 변조 후 상류 읽기 경로가 실패"
contains "$(cat "$SEV/s1t.json")" "Severity assessment does not match the supplied findings" "S1 대조군 상류 오류 문구"
db_set "$FID_A" input_sha256 "$ORIG_SHA"
dist_read "$SEV/s1u.json"
expect_eq "true" "$(jget "$SEV/s1u.json" 'd["ok"]')" "S1 원복 후 다시 읽힌다"
expect_eq "true" "$(jget "$SEV/s1a.json" 'd.get("publishReadable")')" "S1 apply 자기 확인(publishReadable)"
if [ "$SEV060" = true ]; then
  expect_eq "3" "$(jget "$SCAN_DIR/severity-classification.json" 'd.get("classificationRuns")')" "S1 결과 파일 classificationRuns=3(상류 기록)"
  expect_eq "3" "$(db_col "$FID_A" classification_runs)" "S1 워크벤치 행 classification_runs=3(마이그레이션 52)"
  expect_eq "3" "$(jget "$SEV/s1a.json" 'd.get("classificationRuns")')" "S1 apply 보고 classificationRuns=3"
fi
expect_eq "[false, false]" "$(jget "$SEV/s1a.json" '[a["reused"] for a in d.get("assessments",[])]')" "S1 보고: 두 finding 모두 새로 분류(reused=false)"
[ -e "$S1W" ] && bad "S1 성공 후 작업 디렉터리가 남음" || ok "S1 성공 후 작업 디렉터리 삭제"
# 상류 publish 미리보기도 결과를 읽는다(Linear API 키 없이, 팀 ID 는 자리값)
(cd "$SEV" && env -i "${IMPORT_ENV[@]}" "$NODE_B" "$SDK_CLI" publish scan --scan-dir "$SCAN_DIR" --to linear --linear-team placeholder --dry-run --json) >"$SEV/s1pub.json" 2>"$SEV/s1pub.err"
expect_exit 0 $? "S1 상류 publish scan --dry-run 이 분류 결과를 받아들인다"
contains "$(cat "$SEV/s1pub.json")" "[Codex Security][HIGH]" "S1 publish 미리보기에 루브릭 레벨(HIGH) 반영"
not_contains "$(cat "$SEV/s1pub.json")" "Server-side request forgery through preview fetch" "S1 excluded finding 은 publish 이슈에서 빠진다"

# ---------------------------------------------------------------------------
# S2. AE5 — 같은 루브릭으로 다시 실행하면 서브에이전트 호출 0회(전부 재사용)
# ---------------------------------------------------------------------------
step "S2. AE5 같은 루브릭 재실행 → 전부 재사용"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric.md" --knowledge-base "$SEV/in/kb.txt" >"$SEV/s2p.json"; code=$?
expect_exit 0 "$code" "S2 prepare"
expect_eq "0" "$(jget "$SEV/s2p.json" 'len(d.get("pending",[]))')" "S2 판정할 작업 항목 0개(서브에이전트 호출 없음)"
expect_eq "[\"$FID_A\", \"$FID_B\"]" "$(jget "$SEV/s2p.json" 'd.get("reused")')" "S2 두 finding 모두 재사용"
RC apply --work-dir "$(jget "$SEV/s2p.json" 'd["workDir"]')" >"$SEV/s2a.json"; code=$?
expect_exit 0 "$code" "S2 apply(답 없이 상류가 전부 재사용)"
expect_eq "[true, true]" "$(jget "$SEV/s2a.json" '[a["reused"] for a in d.get("assessments",[])]')" "S2 보고: reused=true"
dist_read "$SEV/s2r.json"; expect_eq "2" "$(jget "$SEV/s2r.json" 'len((d.get("result") or {}).get("assessments",[]))')" "S2 상류 읽기 경로 2건"

# ---------------------------------------------------------------------------
# S3. AE5 — 루브릭 한 글자 변경 → 전부 다시 판정. prepare 는 워크벤치를 쓰지 않는다
# ---------------------------------------------------------------------------
step "S3. 루브릭 한 글자 변경 → 전부 재판정, prepare 는 읽기 전용"
sed 's/High:/Hig!:/' "$SEV/in/rubric.md" >"$SEV/in/rubric-1char.md"
[ "$(cmp -l "$SEV/in/rubric.md" "$SEV/in/rubric-1char.md" | wc -l)" = "1" ] && ok "S3 루브릭이 정확히 한 글자 다름" || bad "S3 루브릭 차이가 한 글자가 아님"
SEL_BEFORE="$(PY -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT finding_ids_json||assessed_at||rubric_sha256 FROM scan_severity_classifications").fetchall())' "$SSTATE/workbench.sqlite3")"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric-1char.md" --knowledge-base "$SEV/in/kb.txt" >"$SEV/s3p.json"; code=$?
expect_exit 0 "$code" "S3 prepare"
expect_eq "$((2 * RUNS))" "$(jget "$SEV/s3p.json" 'len(d.get("pending",[]))')" "S3 두 finding 모두 다시 판정 대상(작업 항목 2×$RUNS)"
expect_eq "$SEL_BEFORE" "$(PY -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT finding_ids_json||assessed_at||rubric_sha256 FROM scan_severity_classifications").fetchall())' "$SSTATE/workbench.sqlite3")" "S3 prepare 는 스캔 선택 행을 바꾸지 않음(begin 미호출)"
dist_read "$SEV/s3r.json"; expect_eq "true" "$(jget "$SEV/s3r.json" 'd["ok"]')" "S3 prepare 후에도 이전 분류가 그대로 읽힘"
RC cleanup --work-dir "$(jget "$SEV/s3p.json" 'd["workDir"]')" >/dev/null; expect_exit 0 $? "S3 cleanup"

# ---------------------------------------------------------------------------
# S4. --reprocess — digest 가 같아도 다시 판정
# ---------------------------------------------------------------------------
step "S4. --reprocess"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric.md" --knowledge-base "$SEV/in/kb.txt" --reprocess >"$SEV/s4p.json"; code=$?
expect_exit 0 "$code" "S4 prepare --reprocess"
expect_eq "$((2 * RUNS))" "$(jget "$SEV/s4p.json" 'len(d.get("pending",[]))')" "S4 두 finding 모두 다시 판정 대상(작업 항목 2×$RUNS)"
canned "$SEV/s4p.json" "$FID_A" "$ANS_A_OK"
canned "$SEV/s4p.json" "$FID_B" "$(printf '```json\n%s\n```' "$ANS_B_EXCL")"
RC apply --work-dir "$(jget "$SEV/s4p.json" 'd["workDir"]')" >"$SEV/s4a.json"; code=$?
expect_exit 0 "$code" "S4 apply(코드 펜스 하나로 감싼 반환도 받음)"
expect_eq "[false, false]" "$(jget "$SEV/s4a.json" '[a["reused"] for a in d.get("assessments",[])]')" "S4 보고: 재처리라 reused=false"

# ---------------------------------------------------------------------------
# S5. 잘못된 반환 — 거부, 1회 재판정 후 중단, 앞선 체크포인트 유지
# ---------------------------------------------------------------------------
step "S5. 잘못된 반환(level null / 여분 키 / findingId 불일치)"
printf '# Rubric v3\n\nHigh: remote file write.\n' >"$SEV/in/rubric3.md"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric3.md" >"$SEV/s5p.json"; code=$?
expect_exit 0 "$code" "S5 prepare"
S5W="$(jget "$SEV/s5p.json" 'd["workDir"]')"; R3SHA="$(jget "$SEV/s5p.json" 'd["rubricSha256"]')"
canned "$SEV/s5p.json" "$FID_A" "$ANS_A_OK"
canned "$SEV/s5p.json" "$FID_B" "{\"findingId\":\"$FID_B\",\"decision\":\"assessed\",\"level\":null,\"rubricLabel\":\"Medium\",\"rationale\":\"r\",\"confidence\":null,\"reviewTrigger\":null}"
RC apply --work-dir "$S5W" >"$SEV/s5a.json"; code=$?
expect_exit 2 "$code" "S5 assessed + level null → 거부"
expect_eq "invalid|$FID_B|true" "$(jget "$SEV/s5a.json" '"|".join([str(d.get("status")), str(d.get("findingId")), str(d.get("retryAllowed")).lower()])')" "S5 어느 finding 인지 보고 + 1회 재판정 허용"
contains "$(cat "$SEV/s5a.json")" "Severity classification returned an invalid assessment." "S5 상류 오류 문구"
expect_eq "$R3SHA" "$(db_col "$FID_A" rubric_sha256)" "S5 앞선 finding(A)의 체크포인트는 저장돼 남음"
[ "$(db_col "$FID_B" rubric_sha256)" != "$R3SHA" ] && ok "S5 거부된 finding(B)은 저장되지 않음" || bad "S5 거부된 반환이 저장됨"
dist_read "$SEV/s5r.json"
contains "$(cat "$SEV/s5r.json")" "Severity classification is incomplete or its inputs changed" "S5 미완료 실행 뒤 publish 읽기 경로는 incomplete(상류와 같은 상태)"
S5IDX="$(jget "$SEV/s5a.json" 'd.get("index")')"
expect_eq "1" "$(jget "$SEV/s5a.json" 'd.get("run")')" "S5 거부된 리뷰는 B 의 run 1(상류가 첫 무효 답에서 멈춤)"
RC prompt --work-dir "$S5W" --index "$S5IDX" >"$SEV/s5prompt.txt"; code=$?
expect_exit 0 "$code" "S5 재판정 프롬프트 생성"
contains "$(cat "$SEV/s5prompt.txt")" "Retry notice" "S5 재판정 프롬프트에 재시도 안내"
canned "$SEV/s5p.json" "$FID_B" "{\"findingId\":\"$FID_B\",\"decision\":\"excluded\",\"level\":null,\"rubricLabel\":null,\"rationale\":\"r\",\"confidence\":null,\"reviewTrigger\":null,\"extra\":1}"
RC apply --work-dir "$S5W" >"$SEV/s5b.json"; code=$?
expect_exit 2 "$code" "S5 여분 키 → 거부"
expect_eq "false" "$(jget "$SEV/s5b.json" 'str(d.get("retryAllowed")).lower()')" "S5 두 번째 거부면 재판정 불가"
expect_eq "[]" "$(jget "$SEV/s5b.json" 'd.get("checkpointsSavedThisAttempt")')" "S5 재시도 때 A 는 재사용(다시 저장하지 않음)"
RC apply --work-dir "$S5W" >"$SEV/s5c.json"; code=$?
expect_exit 2 "$code" "S5 한도 초과 후 apply 는 중단"
expect_eq "stopped" "$(jget "$SEV/s5c.json" 'd.get("status")')" "S5 status=stopped"
RC prompt --work-dir "$S5W" --index "$S5IDX" >/dev/null; expect_exit 2 $? "S5 한도 초과 후 prompt 도 거부"
RC cleanup --work-dir "$S5W" >/dev/null
# findingId 불일치
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric3.md" --finding-id "$FID_B" >"$SEV/s5d.json"; code=$?
expect_exit 0 "$code" "S5 prepare --finding-id B"
expect_eq "[\"$FID_B\"]" "$(jget "$SEV/s5d.json" 'd.get("pendingFindings")')" "S5 선택한 finding 만 판정 대상"
expect_eq "$RUNS" "$(jget "$SEV/s5d.json" 'len(d.get("pending",[]))')" "S5 선택한 finding 의 작업 항목 $RUNS 개"
canned "$SEV/s5d.json" "$FID_B" "$ANS_A_OK"
RC apply --work-dir "$(jget "$SEV/s5d.json" 'd["workDir"]')" >"$SEV/s5e.json"; code=$?
expect_exit 2 "$code" "S5 findingId 불일치 → 거부"
expect_eq "invalid" "$(jget "$SEV/s5e.json" 'd.get("status")')" "S5 findingId 불일치 status=invalid"
RC cleanup --work-dir "$(jget "$SEV/s5d.json" 'd["workDir"]')" >/dev/null

# ---------------------------------------------------------------------------
# S6. 입력 거부 — 없는 finding ID, 스캔 입력 개수, 반환 파일 누락, prepare 이후 입력 변경
# ---------------------------------------------------------------------------
step "S6. 시작 전 거부"
count_work() { find "$SSTATE/severity-work" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l; }
W0="$(count_work)"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric.md" --finding-id "$FID_A" --finding-id csf_does_not_exist >"$SEV/s6a.json"; code=$?
expect_exit 2 "$code" "S6 없는 finding ID → 거부"
contains "$(cat "$SEV/s6a.json")" "csf_does_not_exist" "S6 없는 ID 를 지목"
contains "$(cat "$SEV/s6a.json")" "Selected finding IDs must belong to the supplied scan." "S6 상류 문구"
expect_eq "$W0" "$(count_work)" "S6 거부 시 작업 디렉터리를 만들지 않음"
RC prepare "${CS_ARGS[@]}" --scan "$SCAN_ID" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric.md" >/dev/null; expect_exit 1 $? "S6 --scan 과 --scan-dir 동시 지정 거부"
RC prepare "${CS_ARGS[@]}" --rubric "$SEV/in/rubric.md" >/dev/null; expect_exit 1 $? "S6 스캔 입력 없음 거부"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric-1char.md" >"$SEV/s6b.json"
S6W="$(jget "$SEV/s6b.json" 'd["workDir"]')"
RC apply --work-dir "$S6W" >"$SEV/s6c.json"; code=$?
expect_exit 2 "$code" "S6 반환 파일 없으면 apply 거부"
contains "$(cat "$SEV/s6c.json")" "반환 파일이 없다" "S6 누락 안내"
canned "$SEV/s6b.json" "$FID_A" "$ANS_A_OK"; canned "$SEV/s6b.json" "$FID_B" "$ANS_B_EXCL"
cp "$SEV/in/rubric-1char.md" "$SEV/in/rubric-1char.bak"; printf 'changed\n' >>"$SEV/in/rubric-1char.md"
SEL_BEFORE="$(PY -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT finding_ids_json||assessed_at||coalesce(rubric_sha256,\"-\") FROM scan_severity_classifications").fetchall())' "$SSTATE/workbench.sqlite3")"
RC apply --work-dir "$S6W" >"$SEV/s6d.json"; code=$?
expect_exit 2 "$code" "S6 prepare 이후 루브릭이 바뀌면 apply 거부"
contains "$(cat "$SEV/s6d.json")" "prepare 이후 입력이 바뀌었다" "S6 입력 변경 안내"
expect_eq "$SEL_BEFORE" "$(PY -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT finding_ids_json||assessed_at||coalesce(rubric_sha256,\"-\") FROM scan_severity_classifications").fetchall())' "$SSTATE/workbench.sqlite3")" "S6 입력 변경 거부는 워크벤치 쓰기 전(begin 미호출)"
mv "$SEV/in/rubric-1char.bak" "$SEV/in/rubric-1char.md"
RC cleanup --work-dir "$S6W" >/dev/null

# ---------------------------------------------------------------------------
# S7. 루브릭 없는 경로 — 0.5.1 이하: 상류 CLI 위임, 결과가 스킬 stateDir 워크벤치에 저장
#     0.6.0 이상: 상속 경로가 없으므로 inherit 거부, 루브릭 생략 prepare = 상류 기본 루브릭으로 서브에이전트 판정
# ---------------------------------------------------------------------------
INH_ARGS=(--sdk-dist "$DIST" --sdk-cli "$SDK_CLI" --state-dir "$SSTATE" --python "$PYTHON_B")
if [ "$SEV060" = true ]; then
step "S7. 루브릭 없음(0.6.0) → inherit 거부, 상류 기본 루브릭으로 서브에이전트 판정"
rm -rf "$SSTATE/.codex"
SEL_BEFORE="$(PY -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT finding_ids_json||assessed_at||coalesce(rubric_sha256,\"-\") FROM scan_severity_classifications").fetchall())' "$SSTATE/workbench.sqlite3")"
RC inherit "${INH_ARGS[@]}" --scan-dir "$SCAN_DIR" >"$SEV/s7x.json"; code=$?
expect_exit 2 "$code" "S7 inherit 는 0.6.0 에서 거부(상속 경로 삭제)"
contains "$(cat "$SEV/s7x.json")" "0.5.1 이하 전용" "S7 거부 안내가 0.5.1 이하 전용임을 알린다"
contains "$(cat "$SEV/s7x.json")" "--rubric 없이 prepare" "S7 거부 안내가 기본 루브릭 경로를 가리킨다"
expect_eq "$SEL_BEFORE" "$(PY -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT finding_ids_json||assessed_at||coalesce(rubric_sha256,\"-\") FROM scan_severity_classifications").fetchall())' "$SSTATE/workbench.sqlite3")" "S7 거부 시 워크벤치 불변(상류 CLI 미실행)"
[ -e "$SSTATE/.codex" ] && bad "S7 거부인데 기본 상태 위치에 뭔가 생김" || ok "S7 거부 시 기본 상태 위치를 쓰지 않음"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" >"$SEV/s7p.json"; code=$?
expect_exit 0 "$code" "S7 prepare(루브릭 생략)"
expect_eq "upstream-default|6|3" "$(jget "$SEV/s7p.json" '"|".join([str(d.get("rubricSource")), str(len(d.get("pending",[]))), str(d.get("classificationRuns"))])')" "S7 상류 기본 루브릭, 작업 항목 2×3"
# 기대값: 설치된 dist 의 defaultSeverityRubric 을 이 스크립트가 직접 읽어 workflowDigest([원문]) 으로 계산
env -i "${ENVS[@]}" "$NODE_B" --input-type=module -e 'import { pathToFileURL } from "node:url"; const m = await import(pathToFileURL(process.argv[1] + "/default-severity-rubric.js").href); process.stdout.write(JSON.stringify({ value: [m.defaultSeverityRubric] }));' "$DIST" >"$SEV/s7rubric.json"
DEFAULT_SHA="$(RD digest --sdk-dist "$DIST" --json-file "$SEV/s7rubric.json" | PY -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"
expect_eq "$DEFAULT_SHA" "$(jget "$SEV/s7p.json" 'd.get("rubricSha256")')" "S7 rubricSha256 = workflowDigest([상류 기본 루브릭])"
expect_eq "false" "$(jget "$SEV/s7p.json" 'str(d.get("defaultRubricDrift")).lower()')" "S7 기본 루브릭이 검토한 원문(고정 SHA-256)과 같다"
S7W="$(jget "$SEV/s7p.json" 'd["workDir"]')"
expect_eq "True" "$(PY -c 'import json,sys; t=open(sys.argv[1]+"/upstream/1.txt").read(); r=json.load(open(sys.argv[2]))["value"]; print(json.loads(t[t.rindex(chr(10)*2)+2:])["rubric"]==r)' "$S7W" "$SEV/s7rubric.json")" "S7 상류 프롬프트 데이터의 rubric = [기본 루브릭 원문](상류가 넣음)"
canned "$SEV/s7p.json" "$FID_A" "$ANS_A_OK"
canned "$SEV/s7p.json" "$FID_B" "$ANS_B_EXCL"
RC apply --work-dir "$S7W" >"$SEV/s7a.json"; code=$?
expect_exit 0 "$code" "S7 apply(기본 루브릭)"
expect_eq '["rubric:high", "rubric:None"]' "$(jget "$SEV/s7a.json" '[a["source"]+":"+str(a["level"]) for a in d.get("assessments",[])]')" "S7 source 는 항상 rubric(existing-severity 없음)"
expect_eq "true" "$(jget "$SEV/s7a.json" 'd.get("publishReadable")')" "S7 자기 확인(publishReadable)"
dist_read "$SEV/s7r.json"
expect_eq "$DEFAULT_SHA" "$(jget "$SEV/s7r.json" '(d.get("result") or {}).get("rubricSha256")')" "S7 상류 읽기 경로의 rubricSha256 = 기본 루브릭 digest"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" >"$SEV/s7q.json"
expect_eq "0" "$(jget "$SEV/s7q.json" 'len(d.get("pending",[]))')" "S7 기본 루브릭 재실행 → 전부 재사용"
RC cleanup --work-dir "$(jget "$SEV/s7q.json" 'd["workDir"]')" >/dev/null
RC inherit --sdk-dist "$DIST" --state-dir "$SSTATE" --python "$PYTHON_B" --scan-dir "$SCAN_DIR" >"$SEV/s7c.json"; code=$?
expect_exit 2 "$code" "S7 --sdk-cli 없어도 inherit 거부"
else
step "S7. 루브릭 없음 → 상류 CLI 위임(inherit)"
# 대조군: STATE_DIR 없이 CLI 를 신뢰 환경으로 직접 부르면 HOME(=stateDir) 아래 빈 워크벤치를 쓴다
DEFAULT_STATE="$SSTATE/.codex/state/plugins/codex-security"
(env -i "${ENVS[@]}" PYTHON="$PYTHON_B" "$NODE_B" "$SDK_CLI" classify-severity --scan-dir "$SCAN_DIR" --json) >/dev/null 2>&1
[ -f "$DEFAULT_STATE/workbench.sqlite3" ] && ok "S7 대조군: STATE_DIR 를 빼면 다른 워크벤치($DEFAULT_STATE)에 쓴다(실측 재현)" || bad "S7 대조군이 기본 상태 위치에 쓰지 않음 — 대조군 무력"
rm -rf "$SSTATE/.codex"
RC inherit "${INH_ARGS[@]}" --scan-dir "$SCAN_DIR" >"$SEV/s7a.json"; code=$?
expect_exit 0 "$code" "S7 inherit --scan-dir"
expect_eq '["existing-severity:high", "existing-severity:medium"]' "$(jget "$SEV/s7a.json" '[a["source"]+":"+str(a["level"]) for a in d.get("assessments",[])]')" "S7 기존 severity 상속"
expect_eq "Internet exposure of the preview endpoint would raise it." "$(jget "$SEV/s7a.json" 'd["assessments"][1]["reviewTrigger"]')" "S7 changeConditions → reviewTrigger(상류 규칙)"
expect_eq "true" "$(jget "$SEV/s7a.json" 'd.get("publishReadable")')" "S7 자기 확인(publishReadable)"
dist_read "$SEV/s7r.json"
expect_eq '["existing-severity", "existing-severity"]' "$(jget "$SEV/s7r.json" '[a["source"] for a in (d.get("result") or {}).get("assessments",[])]')" "S7 스킬 stateDir 워크벤치에서 상류 읽기 경로가 읽는다"
[ -e "$SSTATE/.codex" ] && bad "S7 inherit 가 기본 상태 위치에 썼다" || ok "S7 inherit 는 기본 상태 위치를 쓰지 않음"
RC inherit "${INH_ARGS[@]}" --scan "$SCAN_ID" --finding-id "$FID_B" >"$SEV/s7b.json"; code=$?
expect_exit 0 "$code" "S7 inherit --scan <id> --finding-id"
expect_eq "[\"$FID_B\"]" "$(jget "$SEV/s7b.json" '[a["findingId"] for a in d.get("assessments",[])]')" "S7 선택 finding 만"
RC inherit --sdk-dist "$DIST" --state-dir "$SSTATE" --python "$PYTHON_B" --scan-dir "$SCAN_DIR" >"$SEV/s7c.json"; code=$?
expect_exit 2 "$code" "S7 CLI 없음(--sdk-cli 누락) → 중단"
contains "$(cat "$SEV/s7c.json")" "npm install -g @openai/codex-security" "S7 한국어 설치 안내"
RC inherit "${INH_ARGS[@]}" --scan-dir "$SCAN_DIR" --finding-id csf_does_not_exist >"$SEV/s7d.json"; code=$?
expect_exit 2 "$code" "S7 없는 finding ID → 시작 전 거부"

fi

# ---------------------------------------------------------------------------
# S8. 신뢰 Node — 대상 저장소 node_modules/.bin/node 가 PATH 맨 앞이어도 실행되지 않는다
# ---------------------------------------------------------------------------
step "S8. node_modules/.bin/node 가 PATH 앞에 있어도 실행 안 됨"
HOSTILE="$SEV/repo/node_modules/.bin"; SENT="$SEV/hostile-node.ran"
mkdir -p "$HOSTILE"
printf '#!/bin/sh\ntouch %s\nexec %s "$@"\n' "$SENT" "$NODE_B" >"$HOSTILE/node"; chmod +x "$HOSTILE/node"
ENVH=()
for e in "${ENVS[@]}"; do case "$e" in PATH=*) ENVH+=("PATH=$HOSTILE:${e#PATH=}") ;; *) ENVH+=("$e") ;; esac; done
env -i "${ENVH[@]}" sh -c 'node -e 0' >/dev/null 2>&1
[ -e "$SENT" ] && ok "S8 대조군: 이 PATH 에서 'node' 는 저장소 바이너리를 고른다" || bad "S8 대조군 무력(저장소 node 가 선택되지 않음)"
rm -f "$SENT"
PATH="$HOSTILE:$PATH" CODEX_SECURITY_STATE_DIR="$SSTATE" PY "$BOOTSTRAP" --target-repo "$SEV/repo" --no-scan-dir >"$SEV/s8boot.json" 2>/dev/null
case "$(jget "$SEV/s8boot.json" '(d.get("node") or {}).get("path") or ""')" in "$HOSTILE"*|"") bad "S8 부트스트랩이 저장소 node 를 골랐거나 못 찾음" ;; *) ok "S8 부트스트랩은 저장소 밖 node 를 해석" ;; esac
[ -e "$SENT" ] && bad "S8 부트스트랩이 저장소 node 를 실행함" || ok "S8 부트스트랩이 저장소 node 를 실행하지 않음"
RH() { env -i "${ENVH[@]}" "$NODE_B" "$CLASSIFY" "$@"; }
printf '# Rubric v4\n\nHigh: remote file write.\nMedium: internal SSRF.\n' >"$SEV/in/rubric4.md"
RH prepare "${CS_ARGS[@]}" --scan "$SCAN_ID" --repository "$SEV/repo" --rubric "$SEV/in/rubric4.md" >"$SEV/s8p.json"; code=$?
expect_exit 0 "$code" "S8 prepare --scan <id>(적대적 PATH)"
canned "$SEV/s8p.json" "$FID_A" "$ANS_A_OK"
canned "$SEV/s8p.json" "$FID_B" "{\"findingId\":\"$FID_B\",\"decision\":\"assessed\",\"level\":\"medium\",\"rubricLabel\":\"Medium\",\"rationale\":\"Internal SSRF.\",\"confidence\":\"low\",\"reviewTrigger\":null}"
(cd "$SEV/repo" && RH apply --work-dir "$(jget "$SEV/s8p.json" 'd["workDir"]')") >"$SEV/s8a.json"; code=$?
expect_exit 0 "$code" "S8 apply(classifyScanSeverityInternal 경로, 저장소 안 cwd)"
if [ "$SEV060" = true ]; then
  (cd "$SEV/repo" && RH inherit "${INH_ARGS[@]}" --scan "$SCAN_ID" --finding-id "$FID_A") >/dev/null; expect_exit 2 $? "S8 inherit(0.6.0 거부, 저장소 안 cwd)"
else
  (cd "$SEV/repo" && RH inherit "${INH_ARGS[@]}" --scan "$SCAN_ID" --finding-id "$FID_A") >/dev/null; expect_exit 0 $? "S8 inherit(CLI 위임, 저장소 안 cwd)"
fi
env -i "${ENVH[@]}" "$NODE_B" "$DIGEST" digest --sdk-dist "$DIST" --json '{"value": 1}' >/dev/null; expect_exit 0 $? "S8 digest 스크립트"
[ -e "$SENT" ] && bad "S8 어떤 호출이 저장소 node 를 실행함" || ok "S8 prepare·apply·inherit·digest 가 저장소 node 를 실행하지 않음"

# ---------------------------------------------------------------------------
# S9. NODE_OPTIONS 거부 · 셰뱅 없음
# ---------------------------------------------------------------------------
step "S9. NODE_OPTIONS / 셰뱅"
rm -f "$MARK"
NODE_OPTIONS="--require=$HOOK" "$NODE_B" "$CLASSIFY" prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric.md" >"$SEV/s9a.json" 2>/dev/null; code=$?
expect_exit 2 "$code" "S9 NODE_OPTIONS 가 남아 있으면 거부"
contains "$(cat "$SEV/s9a.json")" "env -i" "S9 거부 안내"
rm -f "$MARK"
NODE_OPTIONS="--require=$HOOK" env -i "${ENVS[@]}" "$NODE_B" "$CLASSIFY" upstream-literals >/dev/null; expect_exit 0 $? "S9 env -i 형태는 정상"
[ -e "$MARK" ] && bad "S9 env -i 인데 훅이 실행됨" || ok "S9 env -i 형태에서는 훅이 실행되지 않음"
head -c 2 "$CLASSIFY" | grep -q '#!' && bad "S9 셰뱅이 있음" || ok "S9 셰뱅 없음: ${CLASSIFY##*/}"

# ---------------------------------------------------------------------------
# S10. 크기 상한 · S11. 텍스트 전용 지식 베이스
# ---------------------------------------------------------------------------
step "S10. 프롬프트 크기 상한(80,000자)"
PY -c 'import sys; open(sys.argv[1],"w").write("# Big rubric\n" + ("x" * 90000) + "\n")' "$SEV/in/rubric-big.md"
W0="$(count_work)"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric-big.md" >"$SEV/s10.json"; code=$?
expect_exit 2 "$code" "S10 상한 초과 → 시작 전 거부"
contains "$(cat "$SEV/s10.json")" "80000" "S10 상한 보고"
contains "$(cat "$SEV/s10.json")" "$FID_A (" "S10 finding 별 문자 수 보고"
expect_eq "$W0" "$(count_work)" "S10 거부 시 작업 디렉터리 없음"
step "S11. 지식 베이스 PDF·DOCX 거부"
printf '%%PDF-1.4\n' >"$SEV/in/kb.pdf"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric.md" --knowledge-base "$SEV/in/kb.pdf" >"$SEV/s11a.json"; code=$?
expect_exit 2 "$code" "S11 PDF 지식 베이스 거부"
contains "$(cat "$SEV/s11a.json")" "텍스트 파일" "S11 한국어 안내"
mkdir -p "$SEV/in/kbdir/sub"; printf 'ok\n' >"$SEV/in/kbdir/a.md"; printf 'PK' >"$SEV/in/kbdir/sub/b.DOCX"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric.md" --knowledge-base "$SEV/in/kbdir" >"$SEV/s11b.json"; code=$?
expect_exit 2 "$code" "S11 디렉터리 안 DOCX 거부"
contains "$(cat "$SEV/s11b.json")" "b.DOCX" "S11 문제 파일 지목"

# ---------------------------------------------------------------------------
# S12. 프롬프트 — 상류 리터럴 드리프트, 난수 표식, 미신뢰 구획 = 상류 데이터 줄
# ---------------------------------------------------------------------------
step "S12. 프롬프트 구획과 상류 리터럴"
RC upstream-literals >"$SEV/s12lit.json"
PY - "$SEV/s12lit.json" "$DIST" <<'PYEOF' >"$SEV/s12lit.check"
import json, os, sys
lit = json.load(open(sys.argv[1])); dist = sys.argv[2]
read = lambda name: open(os.path.join(dist, name), encoding="utf-8").read()
# npm 0.5.0(#1662)은 지시 8문단을 severity-review.js 로 옮겼다. 그 모듈이 있으면 거기서 찾는다.
instr = "severity-review.js" if os.path.exists(os.path.join(dist, "severity-review.js")) else "classify-severity.js"
missing = [s for s in lit["instructions"] if s not in read(instr)]
for name, fragments in lit.items():
    if name.endswith(".js"):
        missing += [f"{name}: {s}" for s in fragments if s not in read(name)]
# npm 0.6.0(#1765) 기본 루브릭: 설치된 dist 의 원문 SHA-256 이 스킬이 고정한 값과 같은가(원문은 복사하지 않음)
if os.path.exists(os.path.join(dist, "default-severity-rubric.js")):
    import hashlib, re
    src = read("default-severity-rubric.js")
    body = re.search(r"defaultSeverityRubric = `(.*?)`;", src, re.S)
    if not body or hashlib.sha256(body.group(1).encode()).hexdigest() != lit.get("defaultRubricSha256"):
        missing.append("default-severity-rubric.js: SHA-256 differs from pinned defaultRubricSha256")
print("ok" if not missing and len(lit["instructions"]) == 8 else "missing " + json.dumps(missing))
PYEOF
expect_eq "ok" "$(cat "$SEV/s12lit.check")" "S12 고정 리터럴 8문단·상류 오류 문구가 설치된 dist 모듈에 그대로 있다"
RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric-1char.md" >"$SEV/s12p.json"
S12W="$(jget "$SEV/s12p.json" 'd["workDir"]')"
RC prompt --work-dir "$S12W" --index 1 >"$SEV/s12a.txt"; expect_exit 0 $? "S12 prompt 1"
RC prompt --work-dir "$S12W" --index 1 >"$SEV/s12b.txt"
PY - "$SEV/s12a.txt" "$SEV/s12b.txt" "$S12W/upstream/1.txt" "$SEV/s12lit.json" <<'PYEOF' >"$SEV/s12.check"
import json, re, sys
a, b, up = (open(p, encoding="utf-8").read() for p in sys.argv[1:4])
lit = json.load(open(sys.argv[4]))["instructions"]
bad = []
ma = re.search(r"\[TRUSTED_INSTRUCTIONS ([0-9a-f]{16})\]", a); mb = re.search(r"\[TRUSTED_INSTRUCTIONS ([0-9a-f]{16})\]", b)
if not ma or not mb: bad.append("marker")
elif ma.group(1) == mb.group(1): bad.append("marker not fresh")
else:
    m = ma.group(1)
    data = re.search(rf"\n\[UNTRUSTED_DATA {m}\]\n(.*)\n\[/UNTRUSTED_DATA {m}\]\n", a, re.S)
    trusted = re.search(rf"\[TRUSTED_INSTRUCTIONS {m}\]\n(.*)\n\[/TRUSTED_INSTRUCTIONS {m}\]", a, re.S)
    if not data or not trusted: bad.append("blocks")
    else:
        if up != "\n\n".join(lit) + "\n\n" + data.group(1): bad.append("upstream prompt != literal + untrusted data line")
        if "\n\n".join(lit) not in trusted.group(1): bad.append("instructions not in trusted block")
        if '"finding"' in trusted.group(1): bad.append("finding data leaked into trusted block")
        if a.count(f"<<< {m}") != 2: bad.append("guard lines")
print("ok" if not bad else "bad " + ",".join(bad))
PYEOF
expect_eq "ok" "$(cat "$SEV/s12.check")" "S12 호출마다 새 표식, 신뢰 구획=상류 지시, 미신뢰 구획=상류 데이터 줄(둘을 이으면 상류 프롬프트 원문)"
RC prompt --work-dir "$S12W" --index 9 >/dev/null; expect_exit 1 $? "S12 없는 --index 는 사용법 오류"
RC cleanup --work-dir "$S12W" >/dev/null
[ -e "$S12W" ] && bad "S12 cleanup 후 작업 디렉터리가 남음" || ok "S12 cleanup 이 작업 디렉터리를 지움"
expect_eq "$SEAL_BEFORE" "$(cd "$SCAN_DIR" && sha256sum scan-manifest.json findings.json coverage.json)" "S12 전 과정 동안 봉인 정본 파일 불변"

# ---------------------------------------------------------------------------
# S13. npm 0.6.0 리뷰 횟수 계약 — 다수결·동률·무효 리뷰·runs 불일치 재사용 안 함(0.5.1 이하는 --runs 거부)
#      다수결은 상류 reviewSeverity 가 한다. 이 블록은 답을 run 별로 다르게 넣고 상류 결과만 본다.
# ---------------------------------------------------------------------------
step "S13. 리뷰 횟수(--runs)와 상류 다수결"
printf '# Rubric v13\n\nHigh: remote file write.\nMedium: internal SSRF.\n' >"$SEV/in/rubric13.md"
if [ "$SEV060" = true ]; then
  # a) --runs 범위 검사(상류 classificationRunsSchema: 1–10 정수)
  for bad_runs in 0 11 2.5 abc; do
    RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric13.md" --runs "$bad_runs" >"$SEV/s13bad.json"; expect_exit 1 $? "S13 --runs $bad_runs → 사용법 오류"
  done
  # b) --runs 1: finding 당 작업 항목 1개, 상류가 classification_runs=1 로 저장
  RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric13.md" --runs 1 >"$SEV/s13a.json"; expect_exit 0 $? "S13 prepare --runs 1"
  expect_eq "2|1|[1, 1]" "$(jget "$SEV/s13a.json" '"|".join([str(len(d["pending"])), str(d["classificationRuns"]), json.dumps([p["run"] for p in d["pending"]])])')" "S13 --runs 1 → 작업 항목 2개(finding 당 1)"
  canned "$SEV/s13a.json" "$FID_A" "$ANS_A_OK"; canned "$SEV/s13a.json" "$FID_B" "$ANS_B_EXCL"
  RC apply --work-dir "$(jget "$SEV/s13a.json" 'd["workDir"]')" >"$SEV/s13a2.json"; expect_exit 0 $? "S13 apply --runs 1"
  expect_eq "1|1|1" "$(jget "$SEV/s13a2.json" 'str(d.get("classificationRuns"))')|$(jget "$SCAN_DIR/severity-classification.json" 'str(d.get("classificationRuns"))')|$(db_col "$FID_A" classification_runs)" "S13 runs=1 이 보고·결과 파일·워크벤치 행에 기록됨"
  # c) 같은 루브릭이라도 runs 가 다르면 재사용하지 않는다(severity-store matchingClassification). 같으면 재사용한다.
  RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric13.md" --runs 1 >"$SEV/s13b.json"
  expect_eq "0" "$(jget "$SEV/s13b.json" 'len(d["pending"])')" "S13 같은 루브릭·같은 runs(1) → 전부 재사용"
  RC cleanup --work-dir "$(jget "$SEV/s13b.json" 'd["workDir"]')" >/dev/null
  RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric13.md" >"$SEV/s13c.json"; expect_exit 0 $? "S13 prepare(기본 runs)"
  expect_eq "6|3" "$(jget "$SEV/s13c.json" '"|".join([str(len(d["pending"])), str(d["classificationRuns"])])')" "S13 같은 루브릭·runs 1 → 3 이면 재사용 안 함(작업 항목 6)"
  # d) 다수결: A = low / high / high → high(2:1), 승자 레벨의 첫 답(run 2)의 라벨·근거
  #    동률: B = excluded / low / medium (1:1:1) → medium(동률이면 높은 심각도, 제외보다 assessed 우선)
  canned_run "$SEV/s13c.json" "$FID_A" 1 "$(ans "$FID_A" assessed low Low r-a1-low)"
  canned_run "$SEV/s13c.json" "$FID_A" 2 "$(ans "$FID_A" assessed high High r-a2-high)"
  canned_run "$SEV/s13c.json" "$FID_A" 3 "$(ans "$FID_A" assessed high High-3 r-a3-high)"
  canned_run "$SEV/s13c.json" "$FID_B" 1 "$(ans "$FID_B" excluded null null r-b1-excluded)"
  canned_run "$SEV/s13c.json" "$FID_B" 2 "$(ans "$FID_B" assessed low Low r-b2-low)"
  canned_run "$SEV/s13c.json" "$FID_B" 3 "$(ans "$FID_B" assessed medium Medium r-b3-medium)"
  RC apply --work-dir "$(jget "$SEV/s13c.json" 'd["workDir"]')" >"$SEV/s13c2.json"; expect_exit 0 $? "S13 apply(run 별로 다른 답)"
  expect_eq '["high:High:r-a2-high", "medium:Medium:r-b3-medium"]' "$(jget "$SEV/s13c2.json" '[":".join(str(a[k]) for k in ("level","rubricLabel","rationale")) for a in d.get("assessments",[])]')" "S13 상류 다수결: A 2:1 → high(첫 high 답), B 1:1:1 동률 → medium"
  dist_read "$SEV/s13r.json"
  expect_eq '["high", "medium"]' "$(jget "$SEV/s13r.json" '[a["level"] for a in (d.get("result") or {}).get("assessments",[])]')" "S13 상류 읽기 경로도 다수결 결과"
  # e) 동률 규칙 하나 더: runs=2 로 excluded / high (1:1) → high(동률에서 assessed 가 이김)
  RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric13.md" --runs 2 --finding-id "$FID_B" >"$SEV/s13d.json"; expect_exit 0 $? "S13 prepare --runs 2 --finding-id B"
  expect_eq "2" "$(jget "$SEV/s13d.json" 'len(d["pending"])')" "S13 runs 3 → 2 도 재사용 안 함"
  canned_run "$SEV/s13d.json" "$FID_B" 1 "$(ans "$FID_B" excluded null null r-b1-excluded)"
  canned_run "$SEV/s13d.json" "$FID_B" 2 "$(ans "$FID_B" assessed high High r-b2-high)"
  RC apply --work-dir "$(jget "$SEV/s13d.json" 'd["workDir"]')" >"$SEV/s13d2.json"; expect_exit 0 $? "S13 apply --runs 2"
  expect_eq '["high:r-b2-high"]' "$(jget "$SEV/s13d2.json" '[":".join(str(a[k]) for k in ("level","rationale")) for a in d.get("assessments",[])]')" "S13 1:1 동률(excluded vs high) → assessed 가 이김"
  # f) 리뷰 하나라도 무효면 그 finding 은 저장되지 않는다(부분 표 없음). run 번호를 보고한다.
  printf '# Rubric v13b\n\nHigh: remote file write.\n' >"$SEV/in/rubric13b.md"
  RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric13b.md" --finding-id "$FID_A" >"$SEV/s13e.json"
  canned "$SEV/s13e.json" "$FID_A" "$ANS_A_OK"
  canned_run "$SEV/s13e.json" "$FID_A" 3 "$(ans "$FID_A" assessed null High r-bad)"
  RUNS_BEFORE="$(db_col "$FID_A" rubric_sha256)"
  RC apply --work-dir "$(jget "$SEV/s13e.json" 'd["workDir"]')" >"$SEV/s13e2.json"; expect_exit 2 $? "S13 run 3 무효 → 거부"
  expect_eq "invalid|3|true" "$(jget "$SEV/s13e2.json" '"|".join([str(d.get("status")), str(d.get("run")), str(d.get("retryAllowed")).lower()])')" "S13 무효 리뷰의 run 번호 보고 + 1회 재판정 허용"
  expect_eq "$RUNS_BEFORE" "$(db_col "$FID_A" rubric_sha256)" "S13 run 1·2 가 유효해도 A 는 저장되지 않음(부분 표 없음)"
  canned_run "$SEV/s13e.json" "$FID_A" 3 "$ANS_A_OK"
  RC apply --work-dir "$(jget "$SEV/s13e.json" 'd["workDir"]')" >"$SEV/s13e3.json"; expect_exit 0 $? "S13 run 3 만 다시 판정한 뒤 apply 성공"
else
  RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" --rubric "$SEV/in/rubric13.md" --runs 3 >"$SEV/s13x.json"; expect_exit 2 $? "S13 0.5.1 이하: --runs 거부(조용히 무시하지 않음)"
  contains "$(cat "$SEV/s13x.json")" "0.6.0 이상" "S13 0.5.1 이하: --runs 거부 안내"
  RC prepare "${CS_ARGS[@]}" --scan-dir "$SCAN_DIR" >/dev/null; expect_exit 1 $? "S13 0.5.1 이하: 루브릭 생략 prepare 는 사용법 오류(inherit 를 쓴다)"
  note060 "S13 다수결·runs 재사용"
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED assertion(s)"
  exit 1
fi
if [ -n "$MISSING" ]; then
  echo "INCOMPLETE — 전제 부족으로 일부 블록을 건너뛰었습니다: $MISSING"
  exit 2
fi
echo "ALL ASSERTIONS PASSED"
