#!/usr/bin/env bash
# U7·U8 재현 스크립트: 신규 스킬 두 개(codex-security-policy, 심각도 재분류)의 **결정론 부분**을
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
#   P8  마무리 — 스냅샷 불변이면 매니페스트·diff, 바뀌면 매니페스트 없음(AE4)
#   P9  실행 형태 — env -i 로 NODE_OPTIONS 주입이 끊기고, 남아 있으면 스크립트가 거부
#   P10 종단 결정론 흐름 — 파일 5개 0600, 저장소 밖, 대상 저장소 git status 깨끗
#   ── 심각도 블록(U8) ── U8 이 이 아래 "SEVERITY BLOCK" 자리에 추가한다.
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
# 깨끗한 문서 수용 — 일반 시스템 경로·API 경로·URL 은 허용
stage_json "$ARCH_FILE" "# Project spec
Entry point \`app/main.py:1\`. Path traversal could reach /etc/passwd via /api/v1/files. See https://example.com/docs/a." \
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
if [ "${NFRAG:-0}" -ge 25 ] && [ "${NMISS:-1}" = "0" ]; then ok "P7 상류 리터럴 ${NFRAG}조각이 설치된 dist/security-policy.js 에 문자 그대로 있음"; else bad "P7 리터럴 드리프트: $(cat "$RUN/lit.check")"; fi
RP prompt --output-dir "$OUT3" --stage threat_model >"$RUN/pr1.txt"; expect_exit 0 $? "P7 threat_model 프롬프트(헤드리스)"
RP prompt --output-dir "$OUT3" --stage threat_model >"$RUN/pr2.txt"
PR1="$(cat "$RUN/pr1.txt")"
contains "$PR1" "No additional owner clarification was supplied." "P7 답 없음 → 상류 헤드리스 문구"
contains "$PR1" "sibling source and Git metadata are unavailable" "P7 상류 머리말 원문 유지"
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
  RP save-stage --output-dir "$od" --stage threat_model >/dev/null || return 1
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
RP finish --output-dir "$OUT8" --python "$PYTHON_B" >"$RUN/f8.json"; expect_exit 0 $? "P8a finish"
expect_eq "0o600" "$(fmode "$OUT8/policy-draft.json" 2>/dev/null)" "P8a policy-draft.json 0600"
PY - "$OUT8/policy-draft.json" "$R8" "$(jget "$RUN/p8.json" 'd["inheritedPolicySha256"]')" "$(sha "$R8/app/SECURITY.md")" "$PLUGIN_VERSION" <<'PYEOF' >"$RUN/m8.check"
import json, sys
m = json.load(open(sys.argv[1]))
keys = ["documentType","schemaVersion","repository","scope","createdAt","revision","previousPolicySha256","inheritedPolicySha256","model","reasoningEffort","pluginVersion","customPlugin","reviewNotes"]
problems = []
if list(m) != keys: problems.append(f"keys {list(m)}")
if m.get("documentType") != "codex-security.policy-draft" or m.get("schemaVersion") != "1.0": problems.append("type")
if m.get("repository") != sys.argv[2] or m.get("scope") != "app": problems.append("target")
if m.get("inheritedPolicySha256") != sys.argv[3]: problems.append("inherited")
if m.get("previousPolicySha256") != sys.argv[4]: problems.append("previous")
if m.get("pluginVersion") != sys.argv[5]: problems.append("pluginVersion")
if "claude" not in str(m.get("model","")).lower(): problems.append("model")
if m.get("reviewNotes") != ["N1","PN","Q1?","TN","TQ?"]: problems.append(f"reviewNotes {m.get('reviewNotes')}")
if not isinstance(m.get("revision"), str) or len(m["revision"]) < 40: problems.append("revision")
print("ok" if not problems else "bad " + "; ".join(problems))
PYEOF
expect_eq "ok" "$(cat "$RUN/m8.check")" "P8a 매니페스트 스키마·값(reviewNotes 는 상류 합집합 순서)"
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
[ -e "$OUT8C/policy-draft.json" ] && bad "P8c 매니페스트가 생김" || ok "P8c 매니페스트 없음"
for f in project-spec.md THREAT_MODEL.md SECURITY.md; do [ -f "$OUT8C/$f" ] && ok "P8c $f 남음" || bad "P8c $f 없음"; done
"${GITC[@]}" -C "$R8" checkout -q -- app/SECURITY.md
# (d) 조상 정책 변경도 같은 규칙
RP prepare "${PREP_ARGS[@]}" --bootstrap-repo-root "$R8" --repository "$R8" --path app >"$RUN/p8d.json"
run_stages "$RUN/p8d.json"
printf '# root edited\n' >"$R8/SECURITY.md"
OUT8D="$(jget "$RUN/p8d.json" 'd["outputDir"]')"
RP finish --output-dir "$OUT8D" --python "$PYTHON_B" >"$RUN/f8d.json"; expect_exit 2 $? "P8d 조상 변경 → finish 실패"
contains "$(cat "$RUN/f8d.json")" "An inherited SECURITY.md changed" "P8d 상류 상속 변경 문구"
[ -e "$OUT8D/policy-draft.json" ] && bad "P8d 매니페스트가 생김" || ok "P8d 매니페스트 없음"
"${GITC[@]}" -C "$R8" checkout -q -- SECURITY.md

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
expect_eq "SECURITY.md THREAT_MODEL.md policy-draft.json previous-SECURITY.md project-spec.md" \
  "$(cd "$OUT10" && ls -A | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "P10 파일 5개"
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
expect_eq "ok" "$(cat "$RUN/p11.check")" "P11 세 단계 프롬프트가 상류 런타임과 문자 단위로 같음(자리표시자 값 포함)"
contains "$(cat "$RUN/ours-architecture.txt")" '"svc/sub/SECURITY.md"' "P11 하위 정책이 policyPaths 에 포함"
RP cleanup --output-dir "$OUT11" >/dev/null

# ---------------------------------------------------------------------------
# SEVERITY BLOCK (U8) — U8 이 이 자리에 심각도 재분류 단언을 추가한다.
# ---------------------------------------------------------------------------

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
