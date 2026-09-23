#!/usr/bin/env bash
# U1 재현 스크립트: bootstrap.py 의 검색 명령(ripgrep) 확보와 신뢰 게이트를 자기 채점한다.
#
# 무엇을 지키는가:
#   1. 검색 명령 해석은 --require-search / --probe-search 를 준 호출에서만 일어난다
#      (부작용 게이팅 — 다른 스킬이 shim 을 만들지 않는다).
#   2. 채택된 실행 파일과 PATH 항목은 리터럴 경로·realpath 둘 다 대상 저장소 밖이다
#      (계약 1: 대상 저장소는 신뢰할 수 없다).
#   3. `pathEnv` 는 그 자체로 완결된 PATH 다 — 앞에 덧붙이지 않고 교체해서 쓴다.
#   4. 확보 실패 시 --require-search 는 exit 1 + stage=searchCommand 로 멈춘다.
#   5. 같은 상태 디렉터리로 반복 호출해도 성공하고 shim 디렉터리가 누적되지 않는다.
#   6. SECURITY.md 헬퍼를 돌릴 Node 도 같은 게이트로 해석하고, 헬퍼·Node 가 없어도
#      부트스트랩은 성공한다(H14, P6-KTD6·P6-KTD7).
#
# 사용법: bash repro-u1-search-command.sh
#   PYTHON=<경로>                          Python 인터프리터 지정
#   CODEX_SECURITY_BOOTSTRAP=<경로>        검증 대상 bootstrap.py 지정
#   CODEX_SECURITY_NODE=<경로>             H14 가 신뢰 Node 로 쓸 실행 파일 (기본: PATH 의 node)
set -u -o pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# cd 실패로 WORK가 비면 아래 BOOTSTRAP 기본값이 엉뚱한 경로가 된다.
: "${WORK:?WORK 경로 해석 실패 — 중단}"
BOOTSTRAP="${CODEX_SECURITY_BOOTSTRAP:-$WORK/../../../skills/codex-security-scan/scripts/bootstrap.py}"
if [ ! -f "$BOOTSTRAP" ]; then
  echo "오류: bootstrap.py 를 찾지 못했습니다: $BOOTSTRAP" >&2
  echo "      CODEX_SECURITY_BOOTSTRAP=<경로> 로 지정하세요." >&2
  exit 1
fi
# H13e(문서 계약)가 읽을 스킬 트리의 루트. bootstrap.py 의 위치에서 되짚는다 —
# 릴리즈 타르볼 사본에서도 같은 상대 구조(skills/<스킬>/scripts/)를 갖는다.
REPO_ROOT="$(cd "$(dirname "$BOOTSTRAP")/../../.." && pwd -P)"

# 플러그인 경로: 환경변수 → 이 저장소 체크아웃 → npm 전역 설치본.
# 아래 격리 호출(env -i)은 npm 을 해석할 PATH 가 없으므로 미리 정해 명시적으로 물려준다.
PLUGIN="${CODEX_SECURITY_PLUGIN_ROOT:-${CODEX_SECURITY_PLUGIN_DIR:-}}"
if [ -z "$PLUGIN" ]; then
  if NPM_ROOT="$(npm root -g 2>/dev/null)" && \
     [ -f "$NPM_ROOT/@openai/codex-security/_bundled_plugin/.codex-plugin/plugin.json" ]; then
    PLUGIN="$NPM_ROOT/@openai/codex-security/_bundled_plugin"
  else
    echo "오류: 플러그인을 찾지 못했습니다. CODEX_SECURITY_PLUGIN_ROOT=<_bundled_plugin 경로> 를 지정하세요." >&2
    exit 1
  fi
fi
if [ ! -f "$PLUGIN/.codex-plugin/plugin.json" ]; then
  echo "오류: 플러그인 매니페스트가 없습니다: $PLUGIN/.codex-plugin/plugin.json" >&2
  exit 1
fi

# realpath 로 정규화한다. bootstrap 은 경로를 realpath 로 emit 하므로, mktemp 결과에
# 심링크 성분이 있으면(macOS 의 /var/folders -> /private/var 가 기본값이다) 아래
# 리터럴 대조가 영원히 어긋나 H9b 블록이 공허하게 통과한다 — 즉 이 스크립트가
# 지키려는 계약 1 우회가 되살아나도 초록불이 된다(심링크 TMPDIR 로 재현 확인).
RUN="$(cd "$(mktemp -d)" && pwd -P)"
# rm -rf 대상은 RUN 이다. mktemp 실패로 비면 TARGET="/target-repo" 가 되고
# 아래에서 루트 수준 경로에 실행 가능한 가짜 rg 를 쓴다. set -u 는
# set-but-empty 에 발동하지 않으므로 명시적으로 가드한다.
: "${RUN:?임시 디렉터리 생성 실패 — 중단}"
trap 'rm -rf "$RUN"' EXIT

# 스킬 디렉터리에 __pycache__ 를 남기지 않는다 (레포는 읽기 전용으로 유지).
export PYTHONDONTWRITEBYTECODE=1

# Python: PYTHON 환경변수 → python3 → python. 버전 매니저 환경이면
#   PYTHON="$(mise which python3)" bash repro-u1-search-command.sh
PYTHON_BIN="${PYTHON:-$(command -v python3 || command -v python)}"
: "${PYTHON_BIN:?Python 3.10+ 인터프리터를 찾지 못했습니다. PYTHON=<경로> 로 지정하세요.}"
PY() { "$PYTHON_BIN" "$@"; }

FAILED=0
SKIPPED=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf 'OK   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf 'SKIP %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
expect_exit() { # expect_exit <expected> <actual> <label>
  if [ "$2" = "$1" ]; then
    ok "$3: exit $2 (expected $1)"
  else
    bad "$3: exit $2 (expected $1)"
  fi
}

# 대상 저장소(신뢰 경계의 안쪽)와 상태 디렉터리(밖)를 분리한다.
TARGET="$RUN/target-repo"
STATE="$RUN/state"
mkdir -p "$TARGET" "$STATE"

# boot <출력파일> [추가 인자...] — 격리된 상태 디렉터리로 bootstrap 을 돌린다.
# 반환값은 bootstrap 의 종료코드다.
boot() {
  local out="$1"; shift
  CODEX_SECURITY_STATE_DIR="$STATE" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" \
    PYTHONDONTWRITEBYTECODE=1 \
    "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir "$@" \
    >"$out" 2>"$out.err"
}

# jget <파일> <python 표현식> — 파싱 실패도 값 부재와 구분되게 문자열로 돌려준다.
jget() {
  PY - "$1" "$2" <<'EOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("<산출물 없음>")
    raise SystemExit(0)
raw = path.read_text()
if not raw.strip():
    # bootstrap 이 emit 전에 죽었다는 뜻이다. "{}" 로 승격시키면 크래시가
    # 값 부재와 같은 모습이 되어 부정형 단언이 공허하게 통과한다.
    print("<빈 stdout — bootstrap 이 emit 전에 종료>")
    raise SystemExit(0)
try:
    d = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"<JSON 파싱 실패: {exc}>")
    raise SystemExit(0)
try:
    print(eval(sys.argv[2], {"d": d}))  # noqa: S307 — 검증 스크립트 내부 표현식
except Exception as exc:  # noqa: BLE001
    print(f"<평가 실패: {exc}>")
EOF
}

# ---------------------------------------------------------------------------
# 사전 조건: 이 환경에서 ripgrep 을 확보할 수 있는가.
# 확보할 수 없으면 성공 경로 블록(H1~H3, H6)은 검증 자체가 불가능하다 —
# 통과가 아니라 SKIP 으로 세고, 말미에서 종료코드로 구분한다.
# ---------------------------------------------------------------------------
step "H0. 사전 조건 — 검색 명령 확보 가능 여부"
boot "$RUN/h0.json" --probe-search
H0_RC=$?
H0_OK="$(jget "$RUN/h0.json" 'd.get("ok") is True and bool(d.get("searchCommand"))')"
H0_STAGE="$(jget "$RUN/h0.json" 'd.get("stage")')"
if [ "$H0_RC" = "0" ] && [ "$H0_OK" = "True" ]; then
  SEARCH_AVAILABLE=yes
  SKIP_REASON=""
  ok "H0: 검색 명령 확보 가능 ($(jget "$RUN/h0.json" 'd["searchCommand"]["source"]') / $(jget "$RUN/h0.json" 'd["searchCommand"]["version"]'))"
elif [ "$H0_RC" = "0" ]; then
  # --probe-search 는 확보 실패에도 exit 0 이다 = 진짜 전제 부족.
  SEARCH_AVAILABLE=no
  skip "H0: 이 환경에서 ripgrep 을 확보할 수 없습니다 (전제 부족)"
  SKIP_REASON="ripgrep 을 확보할 수 없습니다(설치 필요)"
  printf '     %s\n' "$(jget "$RUN/h0.json" '(d.get("diagnostics") or {}).get("searchError")')"
else
  # 검색 단계 전에 멈춘 것은 환경 부재가 아니라 회귀다. SKIP 으로 접으면
  # 코드 회귀가 "ripgrep 설치 후 재시도"로 오진되고 exit 2 로 통과한다.
  SEARCH_AVAILABLE=no
  # 단계 순서는 pluginRoot -> python -> searchCommand -> trustedPathEnv 다.
  # 앞의 둘은 환경 전제 부족이고 bootstrap 이 스스로 설치 안내를 낸다 — 그것을
  # "회귀"로 단정하면 한 화면에 상충하는 진단 셋이 나온다.
  case "$H0_STAGE" in
    searchCommand|trustedPathEnv)
      bad "H0: bootstrap 이 stage=$H0_STAGE 로 하드 실패했습니다 (전제 부족이 아닌 회귀)"
      SKIP_REASON="bootstrap 이 검색 단계에서 실패했습니다" ;;
    *)
      skip "H0: bootstrap 이 검색 단계 이전(stage=$H0_STAGE)에서 멈췄습니다 — 환경 전제를 먼저 갖추세요"
      SKIP_REASON="bootstrap 이 stage=$H0_STAGE 에서 멈춰 검색 축에 도달하지 못했습니다" ;;
  esac
  printf '     %s\n' "$(jget "$RUN/h0.json" 'd.get("error")')"
fi

# ---------------------------------------------------------------------------
# H0b. npm 탐색 경로로도 성공하는가.
#
# 이 스크립트의 다른 블록은 전부 CODEX_SECURITY_PLUGIN_ROOT 를 명시해 npm 탐색을
# 건너뛴다. 그래서 자식 환경 정화가 `npm root -g` 를 깨뜨린 회귀가 잡히지 않았다
# (실측: npm 은 user/global config 가 같은 경로면 "double-loading config" 로 exit 1
# 이 되는데, 정화가 둘을 같은 /dev/null 로 주었다). 실제 사용자의 기본 경로다.
# ---------------------------------------------------------------------------
step "H0b. npm 전역 탐색 경로 (플러그인 루트 미지정)"
NPM_STATE="$RUN/state-npm"
mkdir -p "$NPM_STATE"
env -u CODEX_SECURITY_PLUGIN_ROOT -u CODEX_SECURITY_PLUGIN_DIR \
  CODEX_SECURITY_STATE_DIR="$NPM_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search \
  >"$RUN/h0b.json" 2>"$RUN/h0b.err"
h0b_rc=$?
H0B_SRC="$(jget "$RUN/h0b.json" 'd.get("pluginSource")')"
if [ "$h0b_rc" = "0" ] && [ "$H0B_SRC" = "npm-global" ]; then
  ok "H0b: npm 전역 탐색으로 플러그인을 찾음 (자식 환경 정화가 npm 을 깨지 않음)"
elif [ "$h0b_rc" = "0" ]; then
  skip "H0b: 플러그인이 npm 전역이 아닌 경로($H0B_SRC)에서 왔습니다 — 이 축은 검증되지 않았습니다"
else
  bad "H0b: npm 탐색 경로가 실패했습니다 (stage=$(jget "$RUN/h0b.json" 'd.get("stage")'))"
  jget "$RUN/h0b.json" '[n for n in ((d.get("notes") or []) + ((d.get("diagnostics") or {}).get("pluginNotes") or [])) if "npm" in str(n)]' | sed 's/^/     /'
fi

# ---------------------------------------------------------------------------
# H1. 성공 형상 — searchCommand 의 필수 키와 ripgrep 버전 문자열.
# ---------------------------------------------------------------------------
step "H1. 성공 형상 (searchCommand 키·버전)"
if [ "$SEARCH_AVAILABLE" != "yes" ]; then
  skip "H1: 성공 형상을 검증할 수 없습니다 — $SKIP_REASON"
else
  PY - "$RUN/h0.json" "$TARGET" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
search = d["searchCommand"]
problems = []
for key in ("path", "source", "pathPrefix", "pathEnv", "version"):
    if key not in search:
        problems.append(f"키 누락: {key}")
if search.get("source") not in {"trusted-executable", "claude-shim"}:
    problems.append(f"source 가 알려진 값이 아님: {search.get('source')!r}")
if "ripgrep" not in (search.get("version") or "").lower():
    problems.append(f"version 이 ripgrep 을 표기하지 않음: {search.get('version')!r}")
if not search.get("pathEnv"):
    problems.append("pathEnv 가 비어 있음")
# pathPrefix 는 trusted-executable 분기에서 None 이다(shim 이 필요 없다).
# 그때도 pathEnv 는 완결돼야 한다 — 소비자는 pathEnv 만 쓴다.
if search.get("source") == "trusted-executable" and search.get("pathPrefix") is not None:
    problems.append("trusted-executable 인데 pathPrefix 가 설정됨")
if search.get("source") == "claude-shim" and not search.get("pathPrefix"):
    problems.append("claude-shim 인데 pathPrefix 가 없음")
if not d.get("trustedPathEnv"):
    problems.append("trustedPathEnv 가 비어 있음")
for p in problems:
    print(f"FAIL H1: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "H1 성공 형상"
fi

# ---------------------------------------------------------------------------
# H2. 신뢰 게이트 — 채택 실행 파일과 PATH 항목 전부가 대상 저장소 밖이다.
#     리터럴 경로와 realpath 를 모두 본다(심링크로 경계를 넘는 것을 막는다).
# ---------------------------------------------------------------------------
step "H2. 신뢰 게이트 (리터럴·realpath 둘 다 저장소 밖)"
if [ "$SEARCH_AVAILABLE" != "yes" ]; then
  skip "H2: 경계 검사를 검증할 수 없습니다 — $SKIP_REASON"
else
  PY - "$RUN/h0.json" "$TARGET" <<'EOF'
import json, os, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
target = pathlib.Path(sys.argv[2])
targets = {target, pathlib.Path(os.path.realpath(target))}


def inside(raw: str) -> bool:
    literal = pathlib.Path(raw)
    resolved = pathlib.Path(os.path.realpath(raw))
    for root in targets:
        for candidate in (literal, resolved):
            if candidate == root or root in candidate.parents:
                return True
    return False


problems = []
search = d["searchCommand"]
if inside(search["path"]):
    problems.append(f"채택 실행 파일이 대상 저장소 안: {search['path']}")
for label, value in (("pathEnv", search["pathEnv"]), ("trustedPathEnv", d["trustedPathEnv"])):
    for entry in value.split(os.pathsep):
        if not entry:
            problems.append(f"{label} 에 빈 항목이 있음")
            continue
        if not os.path.isabs(entry):
            problems.append(f"{label} 에 상대경로 항목: {entry}")
            continue
        if inside(entry):
            problems.append(f"{label} 항목이 대상 저장소 안: {entry}")
for p in problems:
    print(f"FAIL H2: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "H2 신뢰 게이트"
fi

# ---------------------------------------------------------------------------
# H3. pathEnv 자기 완결성 — 이 값을 PATH 로 교체하면 rg 와 git 이 모두 해석된다.
#     상류 generate_in_scope_files.py 가 둘 다 PATH 에서 찾기 때문이다.
# ---------------------------------------------------------------------------
step "H3. pathEnv 자기 완결성 (rg·git 둘 다 해석)"
if [ "$SEARCH_AVAILABLE" != "yes" ]; then
  skip "H3: pathEnv 를 검증할 수 없습니다 — $SKIP_REASON"
else
  PATH_ENV="$(jget "$RUN/h0.json" 'd["searchCommand"]["pathEnv"]')"
  # 파이프로 grep -q 에 넘기지 않는다. grep 이 일치하자마자 종료하면 rg 가 SIGPIPE 로
  # 141 을 내고, `set -o pipefail` 이 그것을 파이프라인 실패로 만들어 단언이 간헐
  # 실패한다(실측). 출력을 먼저 받아 두고 문자열만 검사한다.
  RG_OUT="$(env -i PATH="$PATH_ENV" rg --version 2>&1)" || RG_OUT="<실행 실패: $RG_OUT>"
  case "$RG_OUT" in
    *ripgrep*) ok "H3a: pathEnv 로 rg 가 ripgrep 으로 해석됨 (${RG_OUT%%$'\n'*})" ;;
    *) bad "H3a: pathEnv 로 rg 를 해석하지 못했거나 ripgrep 이 아님: ${RG_OUT%%$'\n'*}" ;;
  esac
  if env -i PATH="$PATH_ENV" git --version >/dev/null 2>&1; then
    ok "H3b: pathEnv 로 git 이 해석됨"
  else
    bad "H3b: pathEnv 로 git 을 해석하지 못했습니다 (인벤토리 위임이 실패한다)"
  fi
fi

# ---------------------------------------------------------------------------
# H4. 부작용 게이팅 — 플래그를 주지 않으면 검색 해석을 아예 하지 않는다.
#     validate/patch/verify-fix/scan-match 는 rg 가 필요 없으므로 shim 도
#     만들지 않아야 한다.
# ---------------------------------------------------------------------------
step "H4. 부작용 게이팅 (플래그 없으면 해석·shim 없음)"
GATE_STATE="$RUN/state-gate"
mkdir -p "$GATE_STATE"
CODEX_SECURITY_STATE_DIR="$GATE_STATE" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" \
  PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir \
  >"$RUN/h4.json" 2>"$RUN/h4.json.err"
expect_exit 0 "$?" "H4 플래그 없는 호출"
H4_SEARCH="$(jget "$RUN/h4.json" 'd.get("searchCommand")')"
if [ "$H4_SEARCH" = "None" ]; then
  ok "H4a: searchCommand 가 None (해석하지 않음)"
else
  bad "H4a: 플래그 없이도 searchCommand 가 채워졌습니다: $H4_SEARCH"
fi
if [ -e "$GATE_STATE/search-shim" ]; then
  bad "H4b: 플래그 없이도 shim 디렉터리가 생성됐습니다: $GATE_STATE/search-shim"
else
  ok "H4b: shim 디렉터리가 생성되지 않음"
fi

# ---------------------------------------------------------------------------
# H5. 반복 호출 — 같은 상태 디렉터리로 3회 연속 성공하고 shim 이 누적되지 않는다.
#     회귀 이력: shim 디렉터리를 고정 이름으로 바꾼 뒤 심링크를 원자 교체하지
#     않아 2회차부터 FileExistsError 로 완전히 멈췄다.
# ---------------------------------------------------------------------------
step "H5. 반복 호출 멱등성 (심링크 원자 교체 회귀)"
if [ "$SEARCH_AVAILABLE" != "yes" ]; then
  skip "H5: 반복 호출을 검증할 수 없습니다 — $SKIP_REASON"
else
  REPEAT_STATE="$RUN/state-repeat"
  mkdir -p "$REPEAT_STATE"
  repeat_fail=0
  for i in 1 2 3; do
    CODEX_SECURITY_STATE_DIR="$REPEAT_STATE" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" \
  PYTHONDONTWRITEBYTECODE=1 \
      "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search \
      >"$RUN/h5-$i.json" 2>"$RUN/h5-$i.err"
    rc=$?
    got="$(jget "$RUN/h5-$i.json" 'd.get("ok") is True and bool(d.get("searchCommand"))')"
    if [ "$rc" != "0" ] || [ "$got" != "True" ]; then
      bad "H5 ${i}회차: exit $rc, ok+searchCommand=$got (stage=$(jget "$RUN/h5-$i.json" 'd.get("stage")'))"
      repeat_fail=1
    fi
  done
  [ "$repeat_fail" = "0" ] && ok "H5a: 3회 연속 성공"
  shim_count="$(find "$REPEAT_STATE" -maxdepth 1 -name 'search-shim*' | wc -l | tr -d ' ')"
  # source 에 따라 기대 개수가 다르다. trusted-executable 분기(PATH 에 실제 rg
  # 바이너리가 있는 표준 환경)는 shim 을 아예 만들지 않으므로 0개가 정상이다.
  # 무조건 1개를 요구하면 그 환경에서 "누적되고 있습니다"라는 정반대 메시지로
  # 릴리즈 검증을 막는다.
  H5_SOURCE="$(jget "$RUN/h5-3.json" '(d.get("searchCommand") or {}).get("source")')"
  case "$H5_SOURCE" in
    claude-shim)        expect_shim=1 ;;
    trusted-executable) expect_shim=0 ;;
    *)                  expect_shim=unknown ;;
  esac
  if [ "$expect_shim" = "unknown" ]; then
    bad "H5b: searchCommand.source 가 알려진 값이 아닙니다: $H5_SOURCE"
  elif [ "$shim_count" = "$expect_shim" ]; then
    ok "H5b: shim 항목 ${shim_count}개 (source=$H5_SOURCE — 기대 ${expect_shim}개, 누적 없음)"
  else
    bad "H5b: shim 항목이 ${shim_count}개 (source=$H5_SOURCE — ${expect_shim}개 기대) — 누적 의심"
    find "$REPEAT_STATE" -maxdepth 1 -name 'search-shim*' | sed 's/^/     /'
  fi
  # 잔여 스테이징 파일(.rg.<pid>.new)이 남아 있으면 정리 경로가 깨진 것이다.
  # 파이프로 grep -q 에 넘기지 않는다 — grep 이 일치 즉시 종료하면 find 가
  # SIGPIPE 로 141 을 내고 pipefail 이 조건을 거짓으로 뒤집는다(H3 와 같은 함정).
  if [ -n "$(find "$REPEAT_STATE" -name '.rg.*.new' -print -quit)" ]; then
    bad "H5c: 스테이징 파일이 남아 있습니다"
    find "$REPEAT_STATE" -name '.rg.*.new' | sed 's/^/     /'
  else
    ok "H5c: 스테이징 잔여물 없음"
  fi
fi

# ---------------------------------------------------------------------------
# H6. 저장소 내부 rg 거부 — 대상 저장소가 커밋한 rg 가 PATH 앞에 있어도 쓰지 않는다.
#     저장소 내부 rg 만 있는 환경에서는 --require-search 가 실패해야 한다.
# ---------------------------------------------------------------------------
step "H6. 저장소 내부 rg 거부 (계약 1)"
mkdir -p "$TARGET/node_modules/.bin"
EVIL_MARK="$RUN/evil-ran"
cat >"$TARGET/node_modules/.bin/rg" <<EOF
#!/usr/bin/env bash
printf 'ripgrep 99.0.0\n'
touch "$EVIL_MARK"
EOF
chmod 755 "$TARGET/node_modules/.bin/rg"

POISON_STATE="$RUN/state-poison"
mkdir -p "$POISON_STATE"
# 저장소 내부 rg 만 있는 PATH. CLAUDE_CODE_EXECPATH 도 비워 shim 경로를 막는다.
# --skip-python: PATH 에 인터프리터가 없어 python 단계가 먼저 실패하면 검사 축이
# 흐려진다. 여기서 보려는 것은 검색 명령 게이트다.
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$TARGET/node_modules/.bin" \
  CODEX_SECURITY_STATE_DIR="$POISON_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --require-search --skip-python \
  >"$RUN/h6.json" 2>"$RUN/h6.err"
H6_RC=$?
if [ -e "$EVIL_MARK" ]; then
  bad "H6a: 대상 저장소의 rg 가 실행됐습니다 (신뢰 게이트 우회)"
else
  ok "H6a: 대상 저장소의 rg 가 실행되지 않음"
fi
# 저장소 내부 rg 만 있으면 채택할 것이 없다. 정화 PATH 도 비므로
# stage 는 trustedPathEnv 이거나 searchCommand 다 — 둘 다 "멈췄다"는 뜻이다.
if [ "$H6_RC" = "1" ]; then
  ok "H6b: exit 1 (expected 1)"
else
  bad "H6b: exit $H6_RC (expected 1) — 저장소 내부 rg 로 진행했습니다"
fi
H6_STAGE="$(jget "$RUN/h6.json" 'd.get("stage")')"
case "$H6_STAGE" in
  searchCommand|trustedPathEnv)
    ok "H6c: stage=$H6_STAGE, ok=$(jget "$RUN/h6.json" 'd.get("ok")')" ;;
  *)
    bad "H6c: stage=$H6_STAGE (searchCommand 또는 trustedPathEnv 기대)" ;;
esac

# ---------------------------------------------------------------------------
# H7. CLAUDE_CODE_EXECPATH 가 저장소 내부를 가리키면 거부한다.
#     리터럴 경로와 realpath 둘 다 본다(심링크로 경계를 넘는 것을 막는다).
#
#     부정형 단언("마커가 안 생겼다")만으로는 부족하다. PATH 에 신뢰 가능한 rg 가
#     있으면 EXECPATH 분기는 조회조차 되지 않으므로, 게이트를 완전히 제거해도
#     세 줄 다 OK 가 된다. 그래서 (a) FAKE_BIN 으로 앞 분기를 확실히 탈락시키고
#     (b) diagnostics.searchAttempts 에 '거부됨' 근거가 실제로 남았는지를
#     양성으로 단언한다.
# ---------------------------------------------------------------------------
step "H7. CLAUDE_CODE_EXECPATH 저장소 내부 거부"

# ripgrep 이 아닌 rg — 앞 분기(신뢰 PATH)가 반드시 탈락하게 만든다.
FAKE_BIN="$RUN/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/rg" <<'EOF'
#!/usr/bin/env bash
printf 'GNU grep 3.11\n'
EOF
chmod 755 "$FAKE_BIN/rg"

# execpath_rejected <json> — EXECPATH 분기가 평가되고 거부됐는지 근거로 확인한다.
# 사람이 읽는 reason 문구가 아니라 구조적 필드로 판정한다. 문구에 단언을 걸면
# 동작이 정상인데 문구만 바뀌어도 거짓 실패하고, 반대로 경계와 무관한 다른
# 사유("대상 저장소 확인 실패" 등)로 거부돼도 통과한다.
execpath_rejected() { # execpath_rejected <json> <대상저장소 realpath>
  jget "$1" "any(
      a.get('source') == 'CLAUDE_CODE_EXECPATH'
      and a.get('result') == 'rejected'
      and (a.get('path') or '').startswith('$2')
      for a in ((d.get('diagnostics') or {}).get('searchAttempts') or [])
  )"
}
TARGET_REAL="$(cd "$TARGET" && pwd -P)"

EXEC_MARK="$RUN/execpath-ran"
cat >"$TARGET/fake-claude" <<EOF
#!/usr/bin/env bash
printf 'ripgrep 98.0.0\n'
touch "$EXEC_MARK"
EOF
chmod 755 "$TARGET/fake-claude"
EXEC_STATE="$RUN/state-execpath"
mkdir -p "$EXEC_STATE"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$FAKE_BIN:/usr/bin:/bin" \
  CLAUDE_CODE_EXECPATH="$TARGET/fake-claude" \
  CODEX_SECURITY_STATE_DIR="$EXEC_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search --skip-python \
  >"$RUN/h7.json" 2>"$RUN/h7.err"
expect_exit 0 "$?" "H7a --probe-search (리터럴 저장소 내부)"
if [ -e "$EXEC_MARK" ]; then
  bad "H7b: 저장소 내부 CLAUDE_CODE_EXECPATH 가 실행됐습니다"
else
  ok "H7b: 저장소 내부 CLAUDE_CODE_EXECPATH 가 실행되지 않음"
fi
if [ "$(execpath_rejected "$RUN/h7.json" "$TARGET_REAL")" = "True" ]; then
  ok "H7c: EXECPATH 게이트가 실제로 평가되고 '저장소 내부'로 거부됨"
else
  bad "H7c: 거부 근거가 searchAttempts 에 없습니다 — 게이트가 평가되지 않았을 수 있습니다"
  jget "$RUN/h7.json" '(d.get("diagnostics") or {}).get("searchAttempts")' | sed 's/^/     /'
fi
H7_PATH="$(jget "$RUN/h7.json" '(d.get("searchCommand") or {}).get("path")')"
case "$H7_PATH" in
  "$TARGET"*) bad "H7d: 채택 경로가 대상 저장소 안입니다: $H7_PATH" ;;
  *)          ok "H7d: 채택 경로가 저장소 밖이거나 확보 실패 (path=$H7_PATH)" ;;
esac

# 심링크로 경계를 넘기는 변형 — 링크는 저장소 밖, 대상은 저장소 안.
LINK_DIR="$RUN/link-out"
mkdir -p "$LINK_DIR"
SYM_MARK="$RUN/symlink-ran"
cat >"$TARGET/fake-claude" <<EOF
#!/usr/bin/env bash
printf 'ripgrep 97.0.0\n'
touch "$SYM_MARK"
EOF
chmod 755 "$TARGET/fake-claude"
ln -sfn "$TARGET/fake-claude" "$LINK_DIR/claude"
SYM_STATE="$RUN/state-symlink"
mkdir -p "$SYM_STATE"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$FAKE_BIN:/usr/bin:/bin" \
  CLAUDE_CODE_EXECPATH="$LINK_DIR/claude" \
  CODEX_SECURITY_STATE_DIR="$SYM_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search --skip-python \
  >"$RUN/h7b.json" 2>"$RUN/h7b.err"
expect_exit 0 "$?" "H7e --probe-search (심링크 경유)"
if [ -e "$SYM_MARK" ]; then
  bad "H7f: 심링크를 통해 저장소 내부 실행 파일이 실행됐습니다 (realpath 검사 누락)"
else
  ok "H7f: 심링크 경유 저장소 내부 실행 파일이 실행되지 않음"
fi
if [ "$(execpath_rejected "$RUN/h7b.json" "$TARGET_REAL")" = "True" ]; then
  ok "H7g: 심링크 변형도 realpath 로 '저장소 내부' 거부 근거가 남음"
else
  bad "H7g: 심링크 변형의 거부 근거가 없습니다 — realpath 검사가 평가되지 않았을 수 있습니다"
  jget "$RUN/h7b.json" '(d.get("diagnostics") or {}).get("searchAttempts")' | sed 's/^/     /'
fi

# H7i: 링크는 저장소 **안**, 대상은 저장소 밖 — 계약 1 의 리터럴 검사 축이다.
# H7·H7g 는 (리터럴=realpath) 와 (리터럴 밖·realpath 안) 두 경우뿐이라, 게이트가
# 리터럴 검사를 잃고 realpath 만 보게 되는 회귀를 아무것도 잡지 못했다(실측: 게이트
# 인자를 realpath 로 낮춘 사본에서 스크립트 전체가 통과). H11 이 PATH 항목에 대해
# 하는 검사를 EXECPATH 축에도 둔다. 여기서는 기록된 path 가 realpath(저장소 밖)라
# 접두 판정을 쓸 수 없으므로 "거부됐다 + 채택되지 않았다"로 단언한다.
INSIDE_LINK_MARK="$RUN/inside-link-ran"
cat >"$RUN/real-claude" <<EOF
#!/usr/bin/env bash
printf 'ripgrep 96.0.0\n'
touch "$INSIDE_LINK_MARK"
EOF
chmod 755 "$RUN/real-claude"
ln -sfn "$RUN/real-claude" "$TARGET/inside-link"
LIT_STATE="$RUN/state-literal"
mkdir -p "$LIT_STATE"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$FAKE_BIN:/usr/bin:/bin" \
  CLAUDE_CODE_EXECPATH="$TARGET/inside-link" \
  CODEX_SECURITY_STATE_DIR="$LIT_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search --skip-python \
  >"$RUN/h7i.json" 2>"$RUN/h7i.err"
expect_exit 0 "$?" "H7i --probe-search (링크는 저장소 안, 대상은 밖)"
if [ -e "$INSIDE_LINK_MARK" ]; then
  bad "H7i-1: 저장소 안 링크를 통해 실행됐습니다 (리터럴 경로 검사 상실)"
else
  ok "H7i-1: 저장소 안 링크 경유 실행 파일이 실행되지 않음"
fi
H7I_REJ="$(jget "$RUN/h7i.json" 'any(
    a.get("source") == "CLAUDE_CODE_EXECPATH" and a.get("result") == "rejected"
    for a in ((d.get("diagnostics") or {}).get("searchAttempts") or [])
)')"
H7I_SRC="$(jget "$RUN/h7i.json" '(d.get("searchCommand") or {}).get("source")')"
if [ "$H7I_REJ" = "True" ] && [ "$H7I_SRC" != "claude-shim" ]; then
  ok "H7i-2: 리터럴이 저장소 안이면 거부됨 (계약 1 의 리터럴 축)"
else
  bad "H7i-2: 거부 근거가 없거나 채택됐습니다 (rejected=$H7I_REJ source=$H7I_SRC)"
  jget "$RUN/h7i.json" '(d.get("diagnostics") or {}).get("searchAttempts")' | sed 's/^/     /'
fi
rm -f "$TARGET/inside-link"

# 대조군: 저장소 **밖** EXECPATH 는 채택돼야 한다. 이것이 없으면 게이트가
# 과잉 거부(모두 거부)로 회귀해도 H7c/H7g 는 오히려 더 잘 통과한다 — 변이로 확인된
# 공백이었다. 거부 사유가 "저장소 내부"임을 귀속시키는 근거이기도 하다.
cp "$TARGET/fake-claude" "$RUN/outside-claude"
chmod 755 "$RUN/outside-claude"
CTRL_EXEC_STATE="$RUN/state-execpath-ctrl"
mkdir -p "$CTRL_EXEC_STATE"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$FAKE_BIN:/usr/bin:/bin" \
  CLAUDE_CODE_EXECPATH="$RUN/outside-claude" \
  CODEX_SECURITY_STATE_DIR="$CTRL_EXEC_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search --skip-python \
  >"$RUN/h7ctrl.json" 2>"$RUN/h7ctrl.err"
if [ "$(jget "$RUN/h7ctrl.json" '(d.get("searchCommand") or {}).get("source")')" = "claude-shim" ]; then
  ok "H7h 대조군: 저장소 밖 EXECPATH 는 채택됨 (게이트가 과잉 거부로 회귀하지 않음)"
else
  bad "H7h 대조군: 저장소 밖 EXECPATH 도 채택되지 않았습니다 — H7c/H7g 의 근거가 약해집니다"
  jget "$RUN/h7ctrl.json" '(d.get("diagnostics") or {}).get("searchAttempts")' | sed 's/^/     /'
fi

# ---------------------------------------------------------------------------
# H8. 신뢰 경로의 rg 가 ripgrep 이 아니면 거부한다 (--version 프로브).
# ---------------------------------------------------------------------------
step "H8. ripgrep 아닌 rg 거부"
# FAKE_BIN 은 H7 에서 만든 것을 재사용한다(ripgrep 이 아닌 rg).
FAKE_STATE="$RUN/state-fake"
mkdir -p "$FAKE_STATE"
# CLAUDE_CODE_EXECPATH 를 비워 shim 폴백을 막고, 가짜 rg 만 남긴다.
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$FAKE_BIN:/usr/bin:/bin" \
  CODEX_SECURITY_STATE_DIR="$FAKE_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --require-search --skip-python \
  >"$RUN/h8.json" 2>"$RUN/h8.err"
expect_exit 1 "$?" "H8a 가짜 rg 만 있으면 --require-search 실패"
H8_STAGE="$(jget "$RUN/h8.json" 'd.get("stage")')"
if [ "$H8_STAGE" = "searchCommand" ]; then
  ok "H8b: stage=searchCommand"
else
  bad "H8b: stage=$H8_STAGE (searchCommand 기대)"
fi
H8_ERR="$(jget "$RUN/h8.json" 'd.get("error")')"
printf '     %s\n' "${H8_ERR%%$'\n'*}"

# ---------------------------------------------------------------------------
# H9. --probe-search 는 확보 실패를 하드 실패로 만들지 않는다.
#     설치 점검(install.sh --check)이 "확보 실패"를 보고할 수 있어야 한다.
# ---------------------------------------------------------------------------
step "H9. --probe-search 는 확보 실패에도 진행"
PROBE_STATE="$RUN/state-probe"
mkdir -p "$PROBE_STATE"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$FAKE_BIN:/usr/bin:/bin" \
  CODEX_SECURITY_STATE_DIR="$PROBE_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search --skip-python \
  >"$RUN/h9.json" 2>"$RUN/h9.err"
expect_exit 0 "$?" "H9a --probe-search 는 exit 0"
H9_OK="$(jget "$RUN/h9.json" 'd.get("ok")')"
H9_SEARCH="$(jget "$RUN/h9.json" 'd.get("searchCommand")')"
if [ "$H9_OK" = "True" ] && [ "$H9_SEARCH" = "None" ]; then
  ok "H9b: ok=true, searchCommand=None (보고 가능한 실패)"
else
  bad "H9b: ok=$H9_OK, searchCommand=$H9_SEARCH (ok=true + None 기대)"
fi
H9_DIAG="$(jget "$RUN/h9.json" '(d.get("diagnostics") or {}).get("searchError")')"
if [ "$H9_DIAG" = "None" ] || [ -z "$H9_DIAG" ]; then
  bad "H9c: diagnostics.searchError 가 비어 있어 실패 원인을 알 수 없습니다"
else
  ok "H9c: diagnostics.searchError 에 원인이 담김"
  printf '     %s\n' "${H9_DIAG%%$'\n'*}"
fi

# ---------------------------------------------------------------------------
# H11. PATH 항목의 리터럴 경로 검사 — 저장소가 커밋한 심링크 디렉터리 거부.
#
# 회귀 이력: trusted_path_entries 가 realpath 만 검사해서, 저장소가
# `repo/evilbin -> /outside/bin` 심링크를 커밋하면 그 항목이 정화 PATH 에
# 살아남았다. 소비자는 이 값을 PATH 로 **교체**하므로 상류 스크립트의 rg·git 이
# 저장소를 통해서만 도달되는 디렉터리에서 해석됐다(합성 저장소로 재현).
# ---------------------------------------------------------------------------
step "H11. PATH 항목 리터럴 검사 (저장소 심링크 디렉터리 거부)"
OUTSIDE="$RUN/outside/bin"
mkdir -p "$OUTSIDE"
cat >"$OUTSIDE/rg" <<'EOF'
#!/usr/bin/env bash
printf 'ripgrep 99.9.9
'
EOF
chmod 755 "$OUTSIDE/rg"
# 링크는 저장소 안, 대상은 저장소 밖 — realpath 만 보면 통과한다.
ln -sfn "$OUTSIDE" "$TARGET/evilbin"
SYMPATH_STATE="$RUN/state-sympath"
mkdir -p "$SYMPATH_STATE"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$TARGET/evilbin:/usr/bin:/bin"   CODEX_SECURITY_STATE_DIR="$SYMPATH_STATE" PYTHONDONTWRITEBYTECODE=1   "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search --skip-python   >"$RUN/h9b.json" 2>"$RUN/h9b.err"
expect_exit 0 "$?" "H11-1 --probe-search (저장소 심링크 PATH 항목)"
H11_TRUSTED="$(jget "$RUN/h9b.json" 'd.get("trustedPathEnv") or ""')"
case "$H11_TRUSTED" in
  *"$RUN/outside/bin"*)
    bad "H11-2: 저장소 심링크를 통해서만 도달되는 디렉터리가 정화 PATH 에 실렸습니다: $H11_TRUSTED" ;;
  *)
    ok "H11-2: 저장소 심링크 경유 디렉터리가 정화 PATH 에서 제거됨" ;;
esac
H11_PATH="$(jget "$RUN/h9b.json" '(d.get("searchCommand") or {}).get("path")')"
case "$H11_PATH" in
  *"$RUN/outside/bin"*)
    bad "H11-3: 저장소 심링크 경유 rg 가 채택됐습니다: $H11_PATH" ;;
  *)
    ok "H11-3: 저장소 심링크 경유 rg 가 채택되지 않음 (path=$H11_PATH)" ;;
esac
# 대조군: 같은 디렉터리를 저장소 밖 경로로 직접 PATH 에 넣으면 채택돼야 한다.
# 이것이 없으면 H9b-2/3 이 "심링크라서"가 아니라 다른 이유로 통과할 수 있다.
CTRL_STATE="$RUN/state-ctrl"
mkdir -p "$CTRL_STATE"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$OUTSIDE:/usr/bin:/bin"   CODEX_SECURITY_STATE_DIR="$CTRL_STATE" PYTHONDONTWRITEBYTECODE=1   "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search --skip-python   >"$RUN/h9c.json" 2>"$RUN/h9c.err"
CTRL_VER="$(jget "$RUN/h9c.json" '(d.get("searchCommand") or {}).get("version")')"
case "$CTRL_VER" in
  *99.9.9*) ok "H11-4 대조군: 저장소 밖 직접 경로의 같은 rg 는 채택됨 (거부 사유가 '심링크 경유'임을 확인)" ;;
  *)        bad "H11-4 대조군: 저장소 밖 rg 도 채택되지 않았습니다(version=$CTRL_VER) — H9b-2/3 의 근거가 약해집니다" ;;
esac
rm -f "$TARGET/evilbin"

# ---------------------------------------------------------------------------
# H12. 소비자 계약(`trustedChildEnv`) — 위험 변수가 다시 들어오지 않는지.
#
# 이 계약이 닫는 채널은 전부 재현으로 확인된 것이다:
#   GIT_CONFIG_KEY_*  → core.fsmonitor 로 임의 명령 실행(`git ls-files`, cwd=저장소)
#   GIT_DIR/WORK_TREE → 신뢰 경계 자체를 옮긴다
#   NODE_OPTIONS      → `npm root -g` 자식에서 저장소 JS 실행
#   LD_PRELOAD        → 저장소 안 .so 가 자식 전부에서 실행
#   RIPGREP_CONFIG_PATH → 커버리지 분모 축소
# 그런데 이 배열을 단언하는 곳이 저장소에 하나도 없었다 — 허용 목록에 위험 변수가
# 실수로 다시 들어가도 아무 회귀도 울리지 않았다. 여기서 고정한다.
# ---------------------------------------------------------------------------
step "H12. trustedChildEnv 계약 (위험 변수 부재·셸 인용)"
if [ "$SEARCH_AVAILABLE" != "yes" ]; then
  skip "H12: 검색 명령을 확보할 수 없어 소비자 계약을 검증할 수 없습니다 — $SKIP_REASON"
else
  POISON_CE="$RUN/state-poison-ce"
  mkdir -p "$POISON_CE"
  # 위험 변수를 **넓게** 얹는다. 심지 않은 변수는 계약에 나타나지 않으므로
  # "기대 집합과 정확히 일치" 단언이 그 이름의 허용목록 추가를 잡지 못한다
  # (실측: GIT_EXTERNAL_DIFF·PYTHONPATH 를 허용목록에 넣어도 초록이었다).
  # 값에는 셸 메타문자·공백도 넣어 인용 계약을 함께 시험한다.
  # `PYTHONHOME` 은 넣지 않는다 — 그것은 **부모** 인터프리터를 먼저 깨뜨려
  # 부트스트랩이 실행조차 되지 않는다(하네스 파손이지 계약 위반이 아니다).
  env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$PATH" \
    CODEX_SECURITY_STATE_DIR="$POISON_CE" PYTHONDONTWRITEBYTECODE=1 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=/tmp/evil \
    GIT_DIR=/tmp/other/.git GIT_WORK_TREE=/tmp/other \
    NODE_OPTIONS="--require /tmp/evil.js" LD_PRELOAD=/tmp/evil.so \
    RIPGREP_CONFIG_PATH=/tmp/evil.rgcfg BASH_ENV=/tmp/evil.sh \
    TERM='$(touch '"$RUN"'/H12_PWNED)x' TZ='a b' \
    GIT_EXTERNAL_DIFF=/tmp/evil.sh GIT_ASKPASS=/tmp/evil.sh \
    GIT_SSH_COMMAND=/tmp/evil.sh GIT_PROXY_COMMAND=/tmp/evil.sh \
    GIT_ALTERNATE_OBJECT_DIRECTORIES=/tmp/evil GIT_OBJECT_DIRECTORY=/tmp/evil \
    GIT_INDEX_FILE=/tmp/evil.idx GIT_TEMPLATE_DIR=/tmp/evil \
    GIT_CONFIG_SYSTEM=/tmp/evil.cfg GIT_CONFIG_PARAMETERS="'core.pager=/tmp/evil.sh'" \
    PYTHONPATH=/tmp/evil PYTHONSTARTUP=/tmp/evil.py \
    LD_AUDIT=/tmp/evil.so GCONV_PATH=/tmp/evil \
    npm_config_prefix=/tmp/evil XDG_CONFIG_HOME=/tmp/evil \
    LOCPATH=/tmp/evil GIT_CEILING_DIRECTORIES=/tmp \
    CLAUDE_CODE_EXECPATH="${CLAUDE_CODE_EXECPATH:-}" \
    "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --probe-search \
    >"$RUN/h12.json" 2>"$RUN/h12.err"
  expect_exit 0 "$?" "H12a --probe-search (오염 환경)"
  PY - "$RUN/h12.json" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
env = d.get("trustedChildEnv")
problems = []
if not isinstance(env, list) or not env:
    problems.append(f"trustedChildEnv 가 배열이 아니거나 비었습니다: {env!r}")
else:
    keys = {e.partition("=")[0] for e in env}
    got = {e.partition("=")[0]: e.partition("=")[2] for e in env}
    # 구현이 **허용 목록**이므로 이름 몇 개를 금지하는 denylist 단언으로는 부족하다 —
    # 목록에 추가되는 **모든** 이름이 위험 표면이다(실측: GIT_EXTERNAL_DIFF·
    # PYTHONPATH·GIT_ASKPASS 를 넣어도 denylist 판은 초록이었다). 기대 집합과
    # **정확히 일치**를 요구해 어떤 추가도 근거를 강제한다.
    try:
        n_cfg = int(got.get("GIT_CONFIG_COUNT", "0"))
    except ValueError:
        n_cfg = 0
    expected = {
        "PATH", "HOME", "LC_ALL", "PYTHONDONTWRITEBYTECODE",
        "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_COUNT",
        "RIPGREP_CONFIG_PATH",
        "npm_config_userconfig", "npm_config_globalconfig",
        # 허용 목록·검사 통과 경로형
        "LANG", "TERM", "SYSTEMROOT", "TMPDIR",
        "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
    } | {f"GIT_CONFIG_KEY_{i}" for i in range(n_cfg)} \
      | {f"GIT_CONFIG_VALUE_{i}" for i in range(n_cfg)}
    unexpected = keys - expected
    if unexpected:
        problems.append(
            f"기대 집합에 없는 변수가 계약에 실렸습니다: {sorted(unexpected)} — "
            "허용 목록에 넣은 근거를 이 단언에도 반영하세요"
        )
    # **반대 방향도 본다.** keys-expected 한 방향만 보면 필수 정화 변수가
    # **사라져도** 초록이다(실측: GIT_CONFIG_NOSYSTEM·LC_ALL·npm_config_* 를
    # 전부 삭제해도 통과했다 — GIT_CONFIG_NOSYSTEM 소실은 미신뢰 자식에게
    # /etc/gitconfig 를 되돌려 주는 회귀다).
    mandatory = {
        "PATH", "HOME", "LC_ALL", "PYTHONDONTWRITEBYTECODE",
        "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_COUNT",
        "RIPGREP_CONFIG_PATH",
        "npm_config_userconfig", "npm_config_globalconfig",
    }
    if mandatory - keys:
        problems.append(
            f"필수 정화 변수가 계약에서 사라졌습니다: {sorted(mandatory - keys)}"
        )
    if got.get("npm_config_userconfig") == got.get("npm_config_globalconfig"):
        problems.append(
            "npm_config_userconfig 와 globalconfig 가 같은 경로입니다 — npm 이 "
            "'double-loading config' 로 죽습니다(실측: npm root -g 가 exit 1)"
        )
    # GIT_CONFIG_* 는 **우리 값으로 덮어써야** 한다. 부모가 얹은
    # core.fsmonitor(임의 명령 실행)가 살아남으면 안 되고, 동시에 우리가
    # safe.directory 를 되돌려 줘야 다른 소유자 저장소에서 add-back 이 유지된다.
    # 개수를 고정하지 않는다 — 목록이 늘면 단언이 깨질 뿐 위험은 늘지 않는다.
    # 확인할 것은 (a) 부모 값이 살아남지 않았는가, (b) 우리가 의도한 키가 실렸는가다.
    count = got.get("GIT_CONFIG_COUNT")
    try:
        n = int(count)
    except (TypeError, ValueError):
        problems.append(f"GIT_CONFIG_COUNT={count!r} 가 정수가 아닙니다")
        n = 0
    ours = {got.get(f"GIT_CONFIG_KEY_{i}"): got.get(f"GIT_CONFIG_VALUE_{i}") for i in range(n)}
    if ours.get("safe.directory") is None:
        problems.append("safe.directory 를 되돌리지 않았습니다(다른 소유자 저장소에서 add-back 소실)")
    # safe.directory 를 강제하면 저장소 자신의 .git/config 가 적용된다 — 실행 채널을
    # 함께 빈 값으로 못 박아야 한다.
    for key in ("core.fsmonitor", "diff.external"):
        if ours.get(key) != "":
            problems.append(
                f"{key} 를 빈 값으로 덮지 않았습니다({ours.get(key)!r}) — 저장소 "
                ".git/config 의 실행 채널이 열립니다"
            )
    if ours.get("core.fsmonitor") == "/tmp/evil":
        problems.append("부모가 얹은 core.fsmonitor 가 살아남았습니다")
    # 부모가 얹은 값이 인덱스 범위 안에 남아 있지 않은지도 본다.
    if "/tmp/evil" in set(ours.values()):
        problems.append(f"부모 값이 계약에 살아남았습니다: {ours!r}")
    if got.get("GIT_CONFIG_GLOBAL") != "/dev/null":
        problems.append(f"GIT_CONFIG_GLOBAL={got.get('GIT_CONFIG_GLOBAL')!r} (/dev/null 기대)")
    if got.get("RIPGREP_CONFIG_PATH") != "":
        problems.append(
            f"RIPGREP_CONFIG_PATH 가 비워지지 않았습니다: {got.get('RIPGREP_CONFIG_PATH')!r}"
        )
for p in problems:
    print(f"FAIL H12: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "H12b 위험 변수가 계약에 없음"

  # H12b-2. **구현 상수를 직접 고정한다.** 위 검사는 오염 환경에 심은 이름만
  # 볼 수 있어, 목록 밖 이름을 허용 목록에 넣으면 초록이다(실측:
  # PERL5LIB·GIT_PAGER·SSH_ASKPASS·NODE_PATH 를 추가해도 통과했다 — GIT_PAGER 는
  # core.pager="" 오버라이드를 이기는 임의 명령 실행 채널이다). 심은 것과
  # 무관하게 어떤 추가·삭제도 잡히도록 상수 자체를 대조한다.
  PY - "$BOOTSTRAP" <<'EOF'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("_bs", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["_bs"] = mod
spec.loader.exec_module(mod)
expected = {
    "PROBE_CHILD_ENV_ALLOW": {"LANG", "TERM", "SYSTEMROOT"},
    "CHECKED_PATH_ENV": {"TMPDIR"},
    "FILTERED_PATHLIST_ENV": {"LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"},
}
problems = []
for name, want in expected.items():
    got = set(getattr(mod, name, ()))
    if got != want:
        problems.append(
            f"{name} 이 바뀌었습니다: 추가={sorted(got - want)} 삭제={sorted(want - got)} — "
            "이 목록의 모든 이름이 위험 표면입니다. 근거를 이 단언에도 반영하세요"
        )
for p in problems:
    print(f"FAIL H12b-2: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "H12b-2 자식 환경 허용 목록 상수가 그대로임"

  # 셸 인용 형태가 실제로 안전한가 — 배열을 그대로 이으면 명령 치환이 일어난다.
  rm -f "$RUN/H12_PWNED"
  H12_SHELL="$(jget "$RUN/h12.json" 'd.get("trustedChildEnvShell") or ""')"
  if [ -z "$H12_SHELL" ]; then
    bad "H12c: trustedChildEnvShell 이 비었습니다 (소비자가 쓸 인용 형태가 없다)"
  else
    bash -c "env -i $H12_SHELL /bin/true" >/dev/null 2>&1
    if [ -e "$RUN/H12_PWNED" ]; then
      bad "H12c: 인용 형태를 셸에 보간했는데 명령 치환이 실행됐습니다"
    else
      ok "H12c: 인용 형태를 셸에 보간해도 명령 치환이 없음"
    fi
  fi
  # 대조군: 인용하지 않은 배열을 이으면 실제로 위험하다는 것을 고정한다.
  rm -f "$RUN/H12_PWNED"
  H12_RAW="$(jget "$RUN/h12.json" '" ".join(d.get("trustedChildEnv") or [])')"
  # 두 분기가 모두 ok 이면 이 대조군은 실패할 수 없고, 그러면 H12c 의 비공허성을
  # 지켜 줄 장치가 없다(실측: 허용 목록에서 TERM 을 빼 페이로드 운반 채널을 없애도
  # H12c 가 조용히 초록이었다). 운반 전제부터 못 박는다.
  case "$H12_RAW" in
    *H12_PWNED*) ;;
    *)
      bad "H12d: 오염 페이로드가 trustedChildEnv 에 실리지 않았습니다 — H12c 가 공허합니다"
      H12_RAW="" ;;
  esac
  if [ -n "$H12_RAW" ]; then
    bash -c "env -i $H12_RAW /bin/true" >/dev/null 2>&1
    if [ -e "$RUN/H12_PWNED" ]; then
      ok "H12d 대조군: 인용 없이 이으면 명령 치환이 일어남 (그래서 Shell 형태를 쓴다)"
    else
      bad "H12d 대조군: 인용 없는 결합이 위험하지 않게 됐습니다 — H12c 의 근거를 재확인하세요"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# H13. 셸 보간 계약이 **모든 축**에 적용됐는지.
#
# trustedChildEnv 를 인용한 뒤에도 같은 명령줄의 `PATH="<pathEnv>"` 와
# `mkdir -p "<scanDir>/…"` 로 명령 치환이 실행됐다(실측) — 이중인용은 $() 를 막지
# 못하고, 그 값들의 출처는 미신뢰 환경이다(CODEX_SECURITY_STATE_DIR, PATH 항목의
# 디렉터리 이름). 한 축만 인용하면 계약이 반쪽이다.
# ---------------------------------------------------------------------------
step "H13. shellQuoted 계약 (모든 보간 축)"
INJ_STATE="$RUN/st\$(touch $RUN/H13_PWNED)x"
mkdir -p "$INJ_STATE"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$PATH" \
  CODEX_SECURITY_STATE_DIR="$INJ_STATE" PYTHONDONTWRITEBYTECODE=1 \
  CLAUDE_CODE_EXECPATH="${CLAUDE_CODE_EXECPATH:-}" \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --skip-python --probe-search \
  >"$RUN/h13.json" 2>"$RUN/h13.err"
expect_exit 0 "$?" "H13a 주입 문자 담긴 stateDir 로 부트스트랩"
H13_SD_RAW="$(jget "$RUN/h13.json" 'd.get("scanDir") or ""')"
H13_SD_Q="$(jget "$RUN/h13.json" '(d.get("shellQuoted") or {}).get("scanDir") or ""')"
# **운반 전제를 먼저 선언한다.** 페이로드가 실제로 scanDir 에 실렸는지 확인하지
# 않으면, 픽스처에서 `$(touch …)` 를 지우는 것만으로 H13 네 건이 전부 초록이 된다
# (실측). 그러면 shlex.quote 가 전부 사라져도 드러나지 않는다.
case "$H13_SD_RAW" in
  *'$(touch '*) ;;
  *) bad "H13a: 주입 페이로드가 scanDir 에 실리지 않았습니다 — H13b/H13c 가 공허합니다 ($H13_SD_RAW)"
     H13_SD_Q="" ;;
esac
if [ -z "$H13_SD_Q" ]; then
  bad "H13b: shellQuoted.scanDir 가 없습니다 (소비자가 쓸 인용 형태가 없다)"
else
  # 인용본을 셸에 보간해도 실행되지 않아야 한다.
  rm -f "$RUN/H13_PWNED"
  bash -c "mkdir -p $H13_SD_Q/artifacts/02_discovery" >/dev/null 2>&1
  if [ -e "$RUN/H13_PWNED" ]; then
    bad "H13b: 인용본을 보간했는데 명령 치환이 실행됐습니다"
  else
    ok "H13b: 인용본 보간에서 명령 치환 없음"
  fi
  # 대조군: 원본을 이중인용으로 보간하면 실제로 실행된다(그래서 인용본을 쓴다).
  # **두 분기가 모두 ok 이면 안 된다** — 실패할 수 없는 대조군은 H13b 의 비공허성을
  # 지키지 못한다(H12d 에서 같은 결함을 고쳤는데 여기서 재도입했었다).
  rm -f "$RUN/H13_PWNED"
  bash -c "mkdir -p \"$H13_SD_RAW/artifacts/02_discovery\"" >/dev/null 2>&1
  if [ -e "$RUN/H13_PWNED" ]; then
    ok "H13c 대조군: 이중인용 원본은 명령 치환이 일어남"
  else
    bad "H13c 대조군: 이중인용 원본이 위험하지 않게 됐습니다 — H13b 의 근거를 재확인하세요"
  fi
  # 대조군 2: **인용본을 다시 이중인용으로 감싸면** 인용이 무효가 된다. 소비자
  # 명령형이 `PATH="<search_path_env>"` 처럼 감싸고 있으면 인용본을 써도 $() 가
  # 실행되고 정상 경로에는 리터럴 따옴표가 섞인다(실측). 그래서 SKILL.md 의
  # 명령형은 자리표시자를 맨몸으로 쓴다 — H13e 가 그것을 고정한다.
  rm -f "$RUN/H13_PWNED"
  bash -c "mkdir -p \"$H13_SD_Q/artifacts/02_discovery\"" >/dev/null 2>&1
  if [ -e "$RUN/H13_PWNED" ]; then
    ok "H13c-2 대조군: 인용본을 이중인용으로 감싸면 인용이 무효가 됨 (맨몸 보간이 계약)"
  else
    bad "H13c-2 대조군: 이중인용 감싸기가 위험하지 않게 됐습니다 — H13e 의 근거를 재확인하세요"
  fi
fi
# 모든 보간 축에 인용본이 있고 **값이 실제로 인용돼 있어야** 한다 — 키 존재만
# 보면 shlex.quote 를 벗겨 raw 를 실어도 초록이다(실측).
PY - "$RUN/h13.json" <<'EOF'
import json, pathlib, shlex, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
q = d.get("shellQuoted") or {}
problems = []
# 셸에 보간되는 축 전부. searchPathEnv·scansRoot 가 빠져 있었다 — 근거 주석이
# 지목한 바로 그 축(PATH="<pathEnv>")이 검사에서 누락된 상태였다.
required = ("repoRoot", "pluginRoot", "trustedPathEnv", "stateDir",
            "scanDir", "scansRoot", "pythonPath", "searchPathEnv")
missing = [k for k in required if k not in q]
if missing:
    problems.append(f"shellQuoted 에 축이 빠졌습니다: {missing}")
# 인용본이 대응 원본의 shlex.quote 결과와 같아야 한다.
raw_of = {
    "repoRoot": d.get("repoRoot"),
    "pluginRoot": d.get("pluginRoot"),
    "trustedPathEnv": d.get("trustedPathEnv"),
    "stateDir": d.get("stateDir"),
    "scanDir": d.get("scanDir"),
    "scansRoot": d.get("scansRoot"),
    "pythonPath": (d.get("python") or {}).get("path"),
    "searchPathEnv": (d.get("searchCommand") or {}).get("pathEnv"),
}
checked = 0
for key, raw in raw_of.items():
    if raw is None:
        continue
    checked += 1
    want = shlex.quote(str(raw))
    if q.get(key) != want:
        problems.append(f"{key} 인용본이 shlex.quote 결과와 다릅니다: {q.get(key)!r} != {want!r}")
# 인용이 실제로 무언가를 했는지(= 이 실행이 검사 가치가 있는지) 고정한다.
if q.get("scanDir") == d.get("scanDir"):
    problems.append("scanDir 인용본이 원본과 동일합니다 — 인용이 적용되지 않았습니다")
if checked < 5:
    problems.append(f"인용을 대조한 축이 {checked}개뿐입니다 — 이 실행은 검사 가치가 낮습니다")
for p in problems:
    print(f"FAIL H13: {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "H13d 모든 보간 축에 인용본 존재·값이 인용됨"

# H13f. 인용이 **코드에** 남아 있는지. H13d 의 축별 대조는 원본이 인용을 필요로
# 하지 않으면(공백·$ 가 없는 평범한 경로) `shlex.quote(raw) == raw` 라서 정의상
# 만족된다 — 즉 그 축에서 `shlex.quote()` 를 벗겨도 드러나지 않는다(실측).
# 공백이 든 대상 저장소·상태 디렉터리 경로로 한 번 더 돌려 repoRoot·stateDir
# 축을 실제로 행사한다. **남는 한계**: pluginRoot·trustedPathEnv·pythonPath 는 이
# 환경의 실제 경로에 공백이 없어 `shlex.quote(raw) == raw` 이고, 그 축에서 인용을
# 벗겨도 이 스크립트는 잡지 못한다(실측). 값의 출처가 운영자(npm 전역 경로·PATH)
# 라서 위험도가 낮아 픽스처를 만들지 않았다 — 검출 공백으로 남겨 둔다.
H13F_TARGET="$RUN/sp ace/repo"
mkdir -p "$H13F_TARGET"
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$PATH"   CODEX_SECURITY_STATE_DIR="$RUN/h13f-state" PYTHONDONTWRITEBYTECODE=1   "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$H13F_TARGET" --skip-python --no-scan-dir   >"$RUN/h13f.json" 2>"$RUN/h13f.err"
expect_exit 0 "$?" "H13f 공백 담긴 저장소 경로로 부트스트랩"
PY - "$RUN/h13f.json" <<'EOF'
import json, pathlib, shlex, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
q = d.get("shellQuoted") or {}
problems = []
raw = d.get("repoRoot") or ""
# stateDir·scanDir 축은 H13a 픽스처가 주입 문자를 실어 H13d 가 이미 행사한다
# (실측: 그 축에서 인용을 벗기면 H13d 가 빨강). 여기서는 repoRoot 만 본다.
if " " not in raw:
    problems.append(f"픽스처가 공백 담긴 경로를 만들지 못했습니다: {raw!r} — 이 단언이 공허합니다")
elif q.get("repoRoot") == raw:
    problems.append("repoRoot 인용본이 원본과 동일합니다 — shlex.quote 가 적용되지 않았습니다")
elif q.get("repoRoot") != shlex.quote(raw):
    problems.append(f"repoRoot 인용본이 shlex.quote 결과와 다릅니다: {q.get('repoRoot')!r}")
# 인용본을 맨몸으로 보간했을 때 경로가 하나의 단어로 남는가.
for key in ("repoRoot", "pluginRoot", "trustedPathEnv", "stateDir"):
    val = (d.get(key) if key != "stateDir" else d.get("stateDir")) or ""
    if not val:
        continue
    if q.get(key) != shlex.quote(str(val)):
        problems.append(f"{key} 인용본이 shlex.quote 결과와 다릅니다: {q.get(key)!r}")
for p in problems:
    print(f"FAIL H13f: {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "H13f 공백 경로에서 인용이 실제로 적용됨"
H13F_Q="$(jget "$RUN/h13f.json" '(d.get("shellQuoted") or {}).get("repoRoot") or ""')"
if [ -n "$H13F_Q" ] && [ "$(bash -c "printf '%s' $H13F_Q")" = "$H13F_TARGET" ]; then
  ok "H13f-2: 인용본 맨몸 보간이 공백 경로를 한 단어로 복원함"
else
  bad "H13f-2: 인용본 맨몸 보간이 공백 경로를 복원하지 못했습니다 ($H13F_Q)"
fi

# H13e. **문서 계약**: 인용본을 내보내는 것만으로는 계약을 못 지킨다. 소비자
# 명령형이 자리표시자를 이중인용 안에 두면(`PATH="<search_path_env>"`) 인용본의
# 단일인용은 리터럴이 되고 $() 는 그대로 확장된다 — 실측으로 두 축 모두 실행됐다.
# 인용본을 명령형에 넣는 SKILL.md 다섯 개(스캔 3종 + policy·classify-severity)의
# 명령형에 그 형태가 남아 있지 않은지 고정한다.
if [ ! -f "$REPO_ROOT/skills/codex-security-scan/SKILL.md" ]; then
  skip "H13e: 스킬 트리를 찾지 못했습니다($REPO_ROOT) — 문서 계약은 검증되지 않았습니다"
else
PY - "$REPO_ROOT" <<'EOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
# shellQuoted.* 로 매핑되는 자리표시자만 본다(운영자·사용자 입력 자리표시자 제외).
quoted_axes = (
    "repo_root", "plugin_dir", "scan_dir", "python_command", "python",
    "search_path_env", "trusted_path_env", "trusted_child_env", "pathEnv", "root",
    "node", "security_md_launcher",
    # codex-security-policy·codex-security-classify-severity 가 쓰는 shellQuoted.* 축.
    "sdk_dist", "sdk_cli", "state_dir",
)
# 여는 큰따옴표 **바로 뒤**만 보면 자리표시자가 더 긴 이중인용 문자열 중간에
# 오는 형태(`"… <scan_dir>/x"`)를 놓친다. 자리표시자 앞의 큰따옴표 개수가
# 홀수면 그 자리표시자는 이중인용 구간 **안**에 있다.
placeholder = re.compile(r'<(' + "|".join(map(re.escape, quoted_axes)) + r')>')


def double_quoted_axes(line: str) -> list[str]:
    return [
        m.group(1)
        for m in placeholder.finditer(line)
        if line.count('"', 0, m.start()) % 2 == 1
    ]
problems = []
for name in (
    "codex-security-scan", "codex-security-diff-scan", "codex-security-deep-scan",
    "codex-security-policy", "codex-security-classify-severity",
):
    path = root / "skills" / name / "SKILL.md"
    if not path.is_file():
        problems.append(f"{name}/SKILL.md 가 없습니다")
        continue
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        # 인용문(> 로 시작하는 설명·근거 서술)은 잘못된 형태를 **일부러** 인용한다.
        if line.lstrip().startswith((">", "#")):
            continue
        found = double_quoted_axes(line)
        if found:
            problems.append(
                f"{name}/SKILL.md:{lineno} 명령형이 인용본 자리표시자를 이중인용으로 "
                f"감쌌습니다({found}) — 인용이 무효가 됩니다: {line.strip()[:100]}"
            )
for p in problems:
    print(f"FAIL H13e: {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "H13e SKILL.md 명령형이 인용본을 이중인용하지 않음"
fi
rm -f "$RUN/H13_PWNED"

# ---------------------------------------------------------------------------
# H14. SECURITY.md 헬퍼와 Node 신뢰 해석 (P6-KTD6·P6-KTD7).
#
# 0.1.29(매니페스트 0.1.95)에서 상류가 Python 리졸버를 지우고 Node 헬퍼
# (`scripts/launch_codex_security_mcp --helper resolve-security-md`)로 바꿨다.
# 런처는 CODEX_MCP_NODE_PATH → CODEX_BROWSER_USE_NODE_PATH → … → PATH 의 `node`
# 순으로 Node 를 고른다. 대상 저장소가 PATH 에 `node_modules/.bin` 을 얹으면
# 저장소가 커밋한 `node` 가 실행될 수 있다. 그래서 부트스트랩이 `rg` 와 같은
# 게이트로 Node 를 해석하고, 스킬은 그 경로를 CODEX_MCP_NODE_PATH 로 준다.
# 헬퍼나 Node 가 없어도 부트스트랩은 성공해야 한다(스캔은 정책 없이 계속한다).
# ---------------------------------------------------------------------------
step "H14. SECURITY.md 헬퍼·Node 신뢰 해석"
NODE_BIN="${CODEX_SECURITY_NODE:-$(command -v node || true)}"
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  skip "H14: 신뢰할 수 있는 Node 를 찾지 못했습니다(CODEX_SECURITY_NODE=<경로> 로 지정) — 헬퍼 축은 검증되지 않았습니다"
elif [ ! -f "$PLUGIN/mcp/helpers.mjs" ] || [ ! -f "$PLUGIN/scripts/launch_codex_security_mcp" ]; then
  skip "H14: 이 플러그인 사본에 헬퍼가 없습니다($PLUGIN) — npm 0.1.29 이상 설치본으로 다시 실행하세요"
else
NODE_REAL="$(cd "$(dirname "$NODE_BIN")" && pwd -P)/$(basename "$NODE_BIN")"
NODE_REAL="$(PY -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$NODE_REAL")"
NT="$RUN/node-target"
NT_STATE="$RUN/node-state"
mkdir -p "$NT" "$NT_STATE"
# 신뢰 PATH 항목: node 심링크만 둔다(리터럴·realpath 둘 다 저장소 밖).
NODE_DIR="$RUN/trusted-node-bin"
mkdir -p "$NODE_DIR"
ln -s "$NODE_REAL" "$NODE_DIR/node"
# Node 가 없는 PATH 항목. trustedPathEnv 가 비지 않게 존재하는 디렉터리를 둔다.
EMPTY_BIN="$RUN/empty-bin"
mkdir -p "$EMPTY_BIN"

# nboot <출력파일> <PATH> [추가 env KEY=VAL ...] -- [추가 인자] — 격리 환경의 부트스트랩.
nboot() {
  local out="$1" path_value="$2"; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="${NBOOT_PLUGIN:-$PLUGIN}" PATH="$path_value" \
    CODEX_SECURITY_STATE_DIR="$NT_STATE" PYTHONDONTWRITEBYTECODE=1 ${envs[@]+"${envs[@]}"} \
    "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "${NBOOT_TARGET:-$NT}" --no-scan-dir --skip-python "$@" \
    >"$out" 2>"$out.err"
}

# H14a. 헬퍼 파일과 신뢰 Node 가 있으면 가용성이 참이고 경로가 실린다.
nboot "$RUN/h14a.json" "$NODE_DIR:$EMPTY_BIN"
expect_exit 0 "$?" "H14a 신뢰 Node 로 부트스트랩"
PY - "$RUN/h14a.json" "$PLUGIN" "$NODE_REAL" <<'EOF'
import json, os, pathlib, shlex, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
plugin, node_real = os.path.realpath(sys.argv[2]), sys.argv[3]
h = d.get("securityMdHelper") or {}
n = d.get("node") or {}
q = d.get("shellQuoted") or {}
problems = []
if h.get("available") is not True:
    problems.append(f"securityMdHelper.available 가 참이 아닙니다: {h}")
want_launcher = os.path.join(plugin, "scripts", "launch_codex_security_mcp")
if h.get("launcher") != want_launcher:
    problems.append(f"launcher 경로가 다릅니다: {h.get('launcher')!r} != {want_launcher!r}")
if h.get("node") != node_real or n.get("path") != node_real:
    problems.append(f"Node 경로가 다릅니다: helper={h.get('node')!r} node={n.get('path')!r} 기대={node_real!r}")
if n.get("source") != "trusted-path":
    problems.append(f"node.source 가 trusted-path 가 아닙니다: {n.get('source')!r}")
if h.get("reason") is not None:
    problems.append(f"가용인데 reason 이 있습니다: {h.get('reason')!r}")
for key, raw in (("nodePath", n.get("path")), ("securityMdLauncher", h.get("launcher"))):
    if key not in q:
        problems.append(f"shellQuoted.{key} 가 없습니다")
    elif q[key] != shlex.quote(str(raw)):
        problems.append(f"shellQuoted.{key} 가 shlex.quote 결과와 다릅니다: {q[key]!r}")
for p in problems:
    print(f"FAIL H14a: {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "H14a 가용성 필드·Node·런처 경로·인용본"

# H14a-2. SDK dist·CLI 필드. npm 설치본이면 둘 다 실린다.
PKG_ROOT="$(cd "$PLUGIN/.." && pwd -P)"
if [ -f "$PKG_ROOT/dist/finding-workflow.js" ] && [ -f "$PKG_ROOT/bin/codex-security.mjs" ]; then
  PY - "$RUN/h14a.json" "$PKG_ROOT" <<'EOF'
import json, os, pathlib, shlex, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = sys.argv[2]
s = d.get("sdk") or {}
q = d.get("shellQuoted") or {}
problems = []
if s.get("dist") != os.path.join(root, "dist"):
    problems.append(f"sdk.dist 가 다릅니다: {s.get('dist')!r}")
if s.get("cli") != os.path.join(root, "bin", "codex-security.mjs"):
    problems.append(f"sdk.cli 가 다릅니다: {s.get('cli')!r}")
if s.get("reason") is not None:
    problems.append(f"가용인데 sdk.reason 이 있습니다: {s.get('reason')!r}")
for key, raw in (("sdkDist", s.get("dist")), ("sdkCli", s.get("cli"))):
    if q.get(key) != (None if raw is None else shlex.quote(raw)):
        problems.append(f"shellQuoted.{key} 가 인용본이 아닙니다: {q.get(key)!r}")
for p in problems:
    print(f"FAIL H14a-2: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "H14a-2 sdk.dist·sdk.cli 가 npm 패키지 경로로 실림"
else
  skip "H14a-2: 이 플러그인은 npm 패키지 레이아웃이 아닙니다($PKG_ROOT) — sdk 축은 검증되지 않았습니다"
fi

# H14b. 헬퍼 파일이 없는 플러그인 사본(상류 소스 체크아웃 형상)이면 불가 + "헬퍼 파일 없음".
#       sdk 도 null 이어야 한다(형제 dist/ 가 없다).
NOHELPER="$RUN/src-checkout/plugins/codex-security"
mkdir -p "$NOHELPER/.codex-plugin" "$NOHELPER/scripts"
cp "$PLUGIN/.codex-plugin/plugin.json" "$NOHELPER/.codex-plugin/plugin.json"
cp "$PLUGIN/scripts/launch_codex_security_mcp" "$NOHELPER/scripts/"
NBOOT_PLUGIN="$NOHELPER" nboot "$RUN/h14b.json" "$NODE_DIR:$EMPTY_BIN"
expect_exit 0 "$?" "H14b 헬퍼 없는 사본으로도 부트스트랩 성공"
H14B="$(jget "$RUN/h14b.json" '(d.get("securityMdHelper") or {}).get("available") is False and str((d.get("securityMdHelper") or {}).get("reason") or "").startswith("헬퍼 파일 없음") and (d.get("sdk") or {}).get("dist") is None and bool((d.get("sdk") or {}).get("reason"))')"
if [ "$H14B" = "True" ]; then
  ok "H14b: 불가·사유 '헬퍼 파일 없음'·sdk.dist=null"
else
  bad "H14b: $(jget "$RUN/h14b.json" '[d.get("securityMdHelper"), d.get("sdk")]')"
fi

# H14c. PATH 의 `node` 가 대상 저장소 안이면 거부하고 다음 후보를 쓴다.
mkdir -p "$NT/node_modules/.bin"
NODE_EVIL_MARK="$RUN/node-evil-ran"
cat >"$NT/node_modules/.bin/node" <<EOF
#!/bin/sh
touch "$NODE_EVIL_MARK"
echo v99.0.0
EOF
chmod 755 "$NT/node_modules/.bin/node"
nboot "$RUN/h14c.json" "$NT/node_modules/.bin:$NODE_DIR:$EMPTY_BIN"
expect_exit 0 "$?" "H14c 저장소 node 가 PATH 앞에 있어도 부트스트랩"
if [ -e "$NODE_EVIL_MARK" ]; then
  bad "H14c: 대상 저장소의 node 가 실행됐습니다 (신뢰 게이트 우회)"
else
  ok "H14c: 대상 저장소의 node 가 실행되지 않음"
fi
H14C_PATH="$(jget "$RUN/h14c.json" '(d.get("node") or {}).get("path")')"
H14C_REJ="$(jget "$RUN/h14c.json" 'any(a.get("result") == "rejected" and "node_modules/.bin/node" in str(a.get("path")) for a in (d.get("diagnostics") or {}).get("nodeAttempts") or [])')"
if [ "$H14C_PATH" = "$NODE_REAL" ] && [ "$H14C_REJ" = "True" ]; then
  ok "H14c: 저장소 node 는 거부 기록, 다음 후보($NODE_REAL) 채택"
else
  bad "H14c: node.path=$H14C_PATH 거부기록=$H14C_REJ (기대: $NODE_REAL / True)"
fi

# H14d. 환경변수가 가리키는 Node 의 realpath 가 저장소 안이면 거부한다.
#       링크는 저장소 **밖**, 대상은 저장소 **안** — realpath 축이다.
ln -s "$NT/node_modules/.bin/node" "$RUN/outside-node-link"
nboot "$RUN/h14d.json" "$NODE_DIR:$EMPTY_BIN" CODEX_MCP_NODE_PATH="$RUN/outside-node-link"
expect_exit 0 "$?" "H14d 저장소를 가리키는 CODEX_MCP_NODE_PATH 로 부트스트랩"
H14D="$(jget "$RUN/h14d.json" '(d.get("node") or {}).get("source") == "trusted-path" and any(a.get("source") == "CODEX_MCP_NODE_PATH" and a.get("result") == "rejected" for a in (d.get("diagnostics") or {}).get("nodeAttempts") or [])')"
if [ "$H14D" = "True" ] && [ ! -e "$NODE_EVIL_MARK" ]; then
  ok "H14d: CODEX_MCP_NODE_PATH(realpath 저장소 내부) 거부, PATH 후보 채택, 미실행"
else
  bad "H14d: $(jget "$RUN/h14d.json" '[d.get("node"), (d.get("diagnostics") or {}).get("nodeAttempts")]')"
fi
# 그 후보뿐이면 가용성은 거짓이고 사유는 "신뢰 게이트 거부"다.
nboot "$RUN/h14d2.json" "$EMPTY_BIN" CODEX_MCP_NODE_PATH="$RUN/outside-node-link"
expect_exit 0 "$?" "H14d-2 거부된 후보뿐이어도 부트스트랩 성공"
H14D2="$(jget "$RUN/h14d2.json" 'd.get("node") is None and (d.get("securityMdHelper") or {}).get("available") is False and str((d.get("securityMdHelper") or {}).get("reason") or "").startswith("신뢰 게이트 거부")')"
if [ "$H14D2" = "True" ]; then
  ok "H14d-2: 불가·사유 '신뢰 게이트 거부'"
else
  bad "H14d-2: $(jget "$RUN/h14d2.json" 'd.get("securityMdHelper")')"
fi

# H14e. 신뢰 Node 가 하나도 없으면 가용성 거짓·"Node 없음", 부트스트랩은 ok:true.
nboot "$RUN/h14e.json" "$EMPTY_BIN"
expect_exit 0 "$?" "H14e Node 없는 환경에서 부트스트랩 성공"
H14E="$(jget "$RUN/h14e.json" 'd.get("ok") is True and d.get("node") is None and (d.get("securityMdHelper") or {}).get("available") is False and str((d.get("securityMdHelper") or {}).get("reason") or "").startswith("Node 없음") and (d.get("shellQuoted") or {}).get("nodePath", "<키 없음>") is None')"
if [ "$H14E" = "True" ]; then
  ok "H14e: ok:true·불가·사유 'Node 없음'·shellQuoted.nodePath=null"
else
  bad "H14e: $(jget "$RUN/h14e.json" '[d.get("ok"), d.get("node"), d.get("securityMdHelper")]')"
fi

# H14f. 문서화한 호출 형태(env -i <trusted_child_env> CODEX_MCP_NODE_PATH=<node> <launcher>)
#       는 호출 환경의 NODE_OPTIONS 를 헬퍼에 넘기지 않는다. 없는 파일을 --require 로
#       주면 Node 가 기동 단계에서 죽으므로, 성공 = 전달되지 않음이다.
printf '# Security\n\nReport issues privately.\n' >"$NT/SECURITY.md"
NODE_OPTS_EVIL="--require $RUN/nonexistent-preload.js"
NODE_OPTIONS="$NODE_OPTS_EVIL" nboot "$RUN/h14f.json" "$NODE_DIR:$EMPTY_BIN" NODE_OPTIONS="$NODE_OPTS_EVIL"
expect_exit 0 "$?" "H14f NODE_OPTIONS 가 있는 환경에서 부트스트랩"
H14F_TCE="$(jget "$RUN/h14f.json" 'd.get("trustedChildEnvShell") or ""')"
H14F_NODE="$(jget "$RUN/h14f.json" '(d.get("shellQuoted") or {}).get("nodePath") or ""')"
H14F_LAUNCHER="$(jget "$RUN/h14f.json" '(d.get("shellQuoted") or {}).get("securityMdLauncher") or ""')"
H14F_REPO="$(jget "$RUN/h14f.json" '(d.get("shellQuoted") or {}).get("repoRoot") or ""')"
if [ -z "$H14F_NODE" ] || [ -z "$H14F_LAUNCHER" ] || [ -z "$H14F_TCE" ]; then
  bad "H14f: 인용본(nodePath/securityMdLauncher/trustedChildEnvShell)이 없어 문서 형태를 재현할 수 없습니다"
else
  NODE_OPTIONS="$NODE_OPTS_EVIL" bash -c "env -i $H14F_TCE CODEX_MCP_NODE_PATH=$H14F_NODE $H14F_LAUNCHER --helper resolve-security-md --repo $H14F_REPO --scope $H14F_REPO --out -" \
    >"$RUN/h14f.out" 2>"$RUN/h14f.helper.err"
  H14F_RC=$?
  if [ "$H14F_RC" = "0" ] && grep -q 'Report issues privately' "$RUN/h14f.out"; then
    ok "H14f: 문서 형태 호출이 exit 0·정책 본문 출력 (NODE_OPTIONS 미전달)"
  else
    bad "H14f: 문서 형태 호출 exit $H14F_RC — $(head -c 300 "$RUN/h14f.helper.err")"
  fi
  # 대조군: env -i 없이 부르면 NODE_OPTIONS 가 전달되어 실패한다. 실패할 수 없는
  # 대조군은 H14f 의 비공허성을 지키지 못한다.
  NODE_OPTIONS="$NODE_OPTS_EVIL" bash -c "CODEX_MCP_NODE_PATH=$H14F_NODE $H14F_LAUNCHER --helper resolve-security-md --repo $H14F_REPO --scope $H14F_REPO --out -" \
    >/dev/null 2>&1
  H14F_CTRL=$?
  if [ "$H14F_CTRL" != "0" ]; then
    ok "H14f 대조군: env -i 없이 부르면 NODE_OPTIONS 가 발동함 (exit $H14F_CTRL)"
  else
    bad "H14f 대조군: env -i 없이도 성공했습니다 — H14f 의 근거를 재확인하세요"
  fi
fi

# H14g. 1 MiB 를 넘는 SECURITY.md 는 헬퍼가 exit 2 로 끝난다. 스킬은 이 종료코드로
#       건너뛰기 분기를 탄다(중단하면 저장소가 자기 스캔을 막을 수 있다).
BIG="$RUN/big-target"
mkdir -p "$BIG"
PY -c 'import sys; open(sys.argv[1], "w").write("# Security\n" + "a" * (1024 * 1024 + 16))' "$BIG/SECURITY.md"
NBOOT_TARGET="$BIG" nboot "$RUN/h14g.json" "$NODE_DIR:$EMPTY_BIN"
expect_exit 0 "$?" "H14g 거대 SECURITY.md 저장소로 부트스트랩"
H14G_TCE="$(jget "$RUN/h14g.json" 'd.get("trustedChildEnvShell") or ""')"
H14G_NODE="$(jget "$RUN/h14g.json" '(d.get("shellQuoted") or {}).get("nodePath") or ""')"
H14G_LAUNCHER="$(jget "$RUN/h14g.json" '(d.get("shellQuoted") or {}).get("securityMdLauncher") or ""')"
H14G_REPO="$(jget "$RUN/h14g.json" '(d.get("shellQuoted") or {}).get("repoRoot") or ""')"
if [ -z "$H14G_NODE" ] || [ -z "$H14G_LAUNCHER" ]; then
  bad "H14g: 인용본이 없어 헬퍼를 실행할 수 없습니다"
else
  bash -c "env -i $H14G_TCE CODEX_MCP_NODE_PATH=$H14G_NODE $H14G_LAUNCHER --helper resolve-security-md --repo $H14G_REPO --scope $H14G_REPO --out -" \
    >"$RUN/h14g.out" 2>"$RUN/h14g.helper.err"
  H14G_RC=$?
  if [ "$H14G_RC" = "2" ] && grep -q '1 MiB' "$RUN/h14g.helper.err"; then
    ok "H14g: 1 MiB 초과 SECURITY.md → 헬퍼 exit 2 + 크기 한도 오류 (스킬이 건너뛰기 분기로 감지 가능)"
  else
    bad "H14g: 헬퍼 exit $H14G_RC (기대 2) — $(head -c 300 "$RUN/h14g.helper.err")"
  fi
fi

# H14h. 헬퍼 경로에 셸 메타문자가 들어도 인용본이 명령 치환을 막는다.
#       플러그인 루트는 운영자가 정하지만(CODEX_SECURITY_PLUGIN_ROOT), 경로 축은
#       전부 인용 계약 대상이다(H13 과 같은 근거).
META_PLUGIN="$RUN/pl\$(touch $RUN/H14_PWNED)x/_bundled_plugin"
mkdir -p "$META_PLUGIN/.codex-plugin" "$META_PLUGIN/scripts" "$META_PLUGIN/mcp"
cp "$PLUGIN/.codex-plugin/plugin.json" "$META_PLUGIN/.codex-plugin/plugin.json"
cp "$PLUGIN/scripts/launch_codex_security_mcp" "$META_PLUGIN/scripts/"
cp "$PLUGIN"/mcp/helpers.mjs* "$META_PLUGIN/mcp/"
NBOOT_PLUGIN="$META_PLUGIN" nboot "$RUN/h14h.json" "$NODE_DIR:$EMPTY_BIN"
expect_exit 0 "$?" "H14h 메타문자 담긴 플러그인 경로로 부트스트랩"
H14H_RAW="$(jget "$RUN/h14h.json" '(d.get("securityMdHelper") or {}).get("launcher") or ""')"
H14H_TCE="$(jget "$RUN/h14h.json" 'd.get("trustedChildEnvShell") or ""')"
H14H_NODE="$(jget "$RUN/h14h.json" '(d.get("shellQuoted") or {}).get("nodePath") or ""')"
H14H_LAUNCHER="$(jget "$RUN/h14h.json" '(d.get("shellQuoted") or {}).get("securityMdLauncher") or ""')"
H14H_REPO="$(jget "$RUN/h14h.json" '(d.get("shellQuoted") or {}).get("repoRoot") or ""')"
case "$H14H_RAW" in
  *'$(touch '*)
    rm -f "$RUN/H14_PWNED"
    bash -c "env -i $H14H_TCE CODEX_MCP_NODE_PATH=$H14H_NODE $H14H_LAUNCHER --helper resolve-security-md --repo $H14H_REPO --scope $H14H_REPO --out -" \
      >"$RUN/h14h.out" 2>"$RUN/h14h.helper.err"
    H14H_RC=$?
    if [ -e "$RUN/H14_PWNED" ]; then
      bad "H14h: 인용본 런처 경로를 보간했는데 명령 치환이 실행됐습니다"
    elif [ "$H14H_RC" = "0" ] && grep -q 'Report issues privately' "$RUN/h14h.out"; then
      ok "H14h: 인용본 보간에서 명령 치환 없음·헬퍼 정상 실행"
    else
      bad "H14h: 명령 치환은 없지만 헬퍼가 exit $H14H_RC — $(head -c 300 "$RUN/h14h.helper.err")"
    fi
    # 대조군: 원본을 이중인용으로 보간하면 실제로 실행된다.
    rm -f "$RUN/H14_PWNED"
    bash -c "ls \"$H14H_RAW\"" >/dev/null 2>&1
    if [ -e "$RUN/H14_PWNED" ]; then
      ok "H14h 대조군: 이중인용 원본은 명령 치환이 일어남"
    else
      bad "H14h 대조군: 이중인용 원본이 위험하지 않게 됐습니다 — H14h 의 근거를 재확인하세요"
    fi
    rm -f "$RUN/H14_PWNED" ;;
  *)
    bad "H14h: 주입 페이로드가 launcher 경로에 실리지 않았습니다 — 이 블록이 공허합니다 ($H14H_RAW)" ;;
esac
fi

# ---------------------------------------------------------------------------
# H10. 정화 PATH 가 비면 멈춘다 — PATH="" 로 자식을 띄우면 git 조차 못 찾는다.
# ---------------------------------------------------------------------------
step "H10. 정화 PATH 가 비면 하드 실패"
EMPTY_STATE="$RUN/state-empty"
mkdir -p "$EMPTY_STATE"
# PATH 에 대상 저장소 내부 항목만 둔다 → 정화하면 아무것도 남지 않는다.
# --skip-python: 위와 같은 이유로 python 단계를 건너뛰어 정화 PATH 축만 본다.
env -i HOME="$HOME" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" PATH="$TARGET/node_modules/.bin" \
  CODEX_SECURITY_STATE_DIR="$EMPTY_STATE" PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$TARGET" --no-scan-dir --skip-python \
  >"$RUN/h10.json" 2>"$RUN/h10.err"
expect_exit 1 "$?" "H10a 정화 PATH 가 비면 exit 1"
H10_STAGE="$(jget "$RUN/h10.json" 'd.get("stage")')"
if [ "$H10_STAGE" = "trustedPathEnv" ]; then
  ok "H10b: stage=trustedPathEnv"
else
  bad "H10b: stage=$H10_STAGE (trustedPathEnv 기대)"
fi

printf '\n=== 결과 ===\n'
if [ "$SKIPPED" -gt 0 ]; then
  printf 'SKIPPED ASSERTIONS: %s (검증되지 않은 항목이 있습니다)\n' "$SKIPPED"
fi
if [ "$FAILED" -gt 0 ]; then
  printf 'FAILED ASSERTIONS: %s\n' "$FAILED"
  exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "INCOMPLETE — 실패는 없으나 위 SKIP 항목은 검증되지 않았습니다."
  exit 2
fi
echo "ALL ASSERTIONS PASSED"
exit 0
