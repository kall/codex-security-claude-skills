#!/usr/bin/env bash
# U7 재현 스크립트: 커버리지 정직성 보정(coverage_reconcile.py)과 중단 스캔 복구
# 경로(workbench_glue.py recover)를 자기 채점한다.
#
# 무엇을 지키는가:
#   1. 빈 인벤토리는 전체 스캔에서 하드 실패(exit 3)다 — 커버리지 분모가 비면
#      어떤 완결성 주장도 근거가 없다. diff·deep 스캔은 --allow-empty-inventory
#      로만 통과한다.
#   2. 부분 커버리지인데 deferred 가 비면(SARIF 경고가 0건이라 불완전이 안 보인다)
#      사람용 출력과 JSON 요약 **둘 다** 그 사실을 말한다.
#      회귀 이력: 이 신호를 출력 루프 뒤에 append 해서 사람용 출력에 안 찍혔다.
#   3. --json 은 JSON 을 stdout, 사람용 요약을 stderr 로 보낸다 — 최종 보고가
#      JSON 키를 인용하기 때문이다.
#   4. recover 는 상류가 거부한 것(gate)과 상류를 실행조차 못한 것(infra)을
#      구분해 안내한다. 둘 다 exit 0 + ok:false 로 다른 선택지로 넘어갈 수 있다.
#   5. diff 스캔은 워크벤치에 등록·종결된다(I17). 글루는 diff 를 레시피 mode 가
#      아니라 target.kind 로 보내고, contract 의 snapshotDigest 는 상류 식과 같다.
#   6. 글루 자식 환경은 상속된 CODEX_SECURITY_GIT 을 넘기지 않는다(I18).
#
# 사용법: bash repro-u7-coverage-recovery.sh
#   PYTHON=<경로>                        Python 인터프리터 지정
#   CODEX_SECURITY_PLUGIN_ROOT=<경로>    _bundled_plugin 경로 지정
#   CODEX_SECURITY_RECONCILE=<경로>      검증 대상 coverage_reconcile.py 지정
#   CODEX_SECURITY_GLUE=<경로>           검증 대상 workbench_glue.py 지정
#   CODEX_SECURITY_FIXTURES=<경로>       픽스처 디렉터리 지정
# 뒤 세 변수는 스킬 본체가 아닌 파일을 검증하게 만들 수 있으므로, 스크립트는
# 시작 시 실제로 해석된 경로를 출력한다 — 통과 로그만으로 대상을 식별할 수 있게.
set -u -o pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# cd 실패로 WORK가 비면 아래 rm -rf 가 루트 수준 경로를 지운다. set -u 는
# set-but-empty 에 발동하지 않으므로 명시적으로 가드한다.
: "${WORK:?WORK 경로 해석 실패 — 중단}"
SKILL_SCRIPTS="$WORK/../../../skills/codex-security-scan/scripts"
RECONCILE="${CODEX_SECURITY_RECONCILE:-$SKILL_SCRIPTS/coverage_reconcile.py}"
GLUE="${CODEX_SECURITY_GLUE:-$SKILL_SCRIPTS/workbench_glue.py}"
for f in "$RECONCILE" "$GLUE"; do
  if [ ! -f "$f" ]; then
    echo "오류: 검증 대상 스크립트를 찾지 못했습니다: $f" >&2
    exit 1
  fi
done

# 플러그인 경로: 환경변수 → npm 전역 설치본. recover 블록에만 필요하다.
PLUGIN="${CODEX_SECURITY_PLUGIN_ROOT:-${CODEX_SECURITY_PLUGIN_DIR:-}}"
if [ -z "$PLUGIN" ]; then
  if NPM_ROOT="$(npm root -g 2>/dev/null)" && \
     [ -f "$NPM_ROOT/@openai/codex-security/_bundled_plugin/.codex-plugin/plugin.json" ]; then
    PLUGIN="$NPM_ROOT/@openai/codex-security/_bundled_plugin"
  fi
fi

FIXTURES="${CODEX_SECURITY_FIXTURES:-$WORK/../fixtures}"
RUN="$(mktemp -d)"
# rm -rf 대상은 RUN 이다. mktemp 실패로 비면 SRC="/source-root" 가 되고
# 산출물이 파일시스템 루트에 생성되며 트랩의 rm -rf "" 는 아무것도 지우지 않는다.
: "${RUN:?임시 디렉터리 생성 실패 — 중단}"
trap 'rm -rf "$RUN"' EXIT

# 스킬·플러그인 디렉터리에 __pycache__ 를 남기지 않는다.
export PYTHONDONTWRITEBYTECODE=1

# Python: PYTHON 환경변수 → python3 → python. 버전 매니저 환경이면
#   PYTHON="$(mise which python3)" bash repro-u7-coverage-recovery.sh
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

# 합성 소스 루트 — findings.locations 가 가리키는 실존 파일 1개.
SRC="$RUN/source-root"
mkdir -p "$SRC/src"
cat >"$SRC/src/extract.py" <<'EOF'
import tarfile


def extract(archive, destination):
    tarfile.open(archive).extractall(destination)
EOF

# make_scan <이름> <in_scope 내용> <review_log 내용> <completeness> <deferred-json>
# 정산 대상 스캔 디렉터리를 만들고 경로를 echo 한다. completeness 가 `-` 이면 키를
# 지운다(npm 0.3.0 이후 형상 — 상류가 coverage.completeness 를 지웠다).
make_scan() {
  local name="$1" in_scope="$2" review_log="$3" completeness="$4" deferred="$5"
  local scan="$RUN/scan-$name"
  mkdir -p "$scan/artifacts/02_discovery"
  cp "$FIXTURES"/scan-manifest.json "$FIXTURES"/findings.json "$FIXTURES"/coverage.json "$scan/"
  printf '%s' "$in_scope" >"$scan/artifacts/02_discovery/in_scope_files.txt"
  printf '%s' "$review_log" >"$scan/artifacts/02_discovery/review_log.jsonl"
  PY - "$scan/coverage.json" "$completeness" "$deferred" <<'EOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
coverage = json.loads(path.read_text())
if sys.argv[2] == "-":
    coverage.pop("completeness", None)
else:
    coverage["completeness"] = sys.argv[2]
coverage["deferred"] = json.loads(sys.argv[3])
path.write_text(json.dumps(coverage, indent=2))
EOF
  printf '%s' "$scan"
}

# 픽스처가 없으면 cp 가 조용히 실패하고, 그 결과 난 exit 3 이 "빈 인벤토리"로
# 오귀속된다(실측: I1a 가 잘못된 이유로 통과). 시작 시 끊는다.
for f in "$FIXTURES/scan-manifest.json" "$FIXTURES/findings.json" "$FIXTURES/coverage.json"; do
  if [ ! -f "$f" ]; then
    echo "오류: 픽스처를 찾지 못했습니다: $f" >&2
    exit 1
  fi
done
printf '검증 대상\n  reconcile: %s\n  glue     : %s\n  픽스처   : %s\n  플러그인 : %s\n' \
  "$RECONCILE" "$GLUE" "$FIXTURES" "${PLUGIN:-<미탐지>}"

REVIEWED='{"path": "src/extract.py", "reviewed_at": "2026-07-30T09:00:00Z", "outcome": "reviewed"}
'

# ---------------------------------------------------------------------------
# I1. 빈 인벤토리는 전체 스캔에서 하드 실패다 (exit 3 = 입력 오류).
#     0.1.18 기준에서는 경고였다 — 인벤토리를 상류에 위임한 뒤 승격했다.
# ---------------------------------------------------------------------------
step "I1. 빈 인벤토리 하드 실패 (전체 스캔)"
SCAN_EMPTY="$(make_scan empty "" "$REVIEWED" complete '[]')"
PY "$RECONCILE" --scan-dir "$SCAN_EMPTY" --source-root "$SRC" >"$RUN/i1.out" 2>"$RUN/i1.err"
expect_exit 3 "$?" "I1a 빈 인벤토리"
if grep -q "비어 있습니다" "$RUN/i1.out" "$RUN/i1.err" 2>/dev/null; then
  ok "I1b: 원인이 출력에 담김"
else
  bad "I1b: 빈 인벤토리 사유가 출력에 없습니다"
  sed 's/^/     /' "$RUN/i1.err"
fi
# 하드 실패는 coverage.json 을 고치지 않아야 한다(중단이지 보정이 아니다).
if [ "$(PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["completeness"])' "$SCAN_EMPTY/coverage.json")" = "complete" ]; then
  ok "I1c: coverage.json 이 수정되지 않음"
else
  bad "I1c: 하드 실패인데 coverage.json 이 수정됐습니다"
fi

# ---------------------------------------------------------------------------
# I1d. 정산 자신의 `git` 호출도 정화된 환경으로 돌아야 한다.
#
# coverage_reconcile 은 보고용 provenance 를 위해 `git rev-parse` / `git config` 를
# 돌린다. 대상 저장소는 신뢰할 수 없으므로, 원시 환경을 물려주면 부트스트랩이 상류
# 스크립트에 대해 막은 것과 같은 구멍이 이 스크립트에 남는다 — 저장소가 커밋한
# ./node_modules/.bin/git 이 사용자 권한으로 실행된다.
# ---------------------------------------------------------------------------
step "I1d. 정산의 git 호출 정화 (저장소가 커밋한 git 거부)"
# u7 에서 git 을 쓰는 유일한 곳이다. 전제가 없으면 SKIP 이어야 한다 — 없는 결함을
# 보고하면 릴리즈 검증이 엉뚱한 곳을 본다(실측: exit 127 git 스텁으로 exit 1 이었다).
# 본문은 들여쓰지 않는다 — 히어독 종료자가 컬럼 0 이어야 한다.
if ! git --version >/dev/null 2>&1; then
  skip "I1d: git 을 쓸 수 없어 정산의 git 호출 정화를 검증할 수 없습니다"
else
EVIL_BIN="$SRC/node_modules/.bin"
mkdir -p "$EVIL_BIN"
EVIL_MARK="$RUN/evil-git-ran"
cat >"$EVIL_BIN/git" <<EOF
#!/usr/bin/env bash
touch "$EVIL_MARK"
printf 'fake\n'
EOF
chmod 755 "$EVIL_BIN/git"
# 대상 저장소를 git 저장소로 만들어 provenance 경로가 실제로 타게 한다.
( cd "$SRC" && git -c core.excludesFile=/dev/null init -q . \
    && git add -A >/dev/null 2>&1 \
    && git -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1 ) || true
SCAN_GIT="$(make_scan gitprov 'src/extract.py
' "$REVIEWED" complete '[]')"
# `_git_origin` 은 --fp-recheck 경로에서만, 그리고 **피드백 파일이 있을 때만** 호출된다.
# 그 둘을 갖추지 않으면 이 단언이 문제의 코드에 도달조차 하지 않는다(실측: 갖추지
# 않았을 때 env= 를 걷어낸 변이가 통과했다).
mkdir -p "$SCAN_GIT/artifacts/01_context"
printf '{"entries": []}\n' >"$SCAN_GIT/artifacts/01_context/false_positive_feedback.json"
rm -f "$EVIL_MARK"
PATH="$EVIL_BIN:$PATH" PY "$RECONCILE" --scan-dir "$SCAN_GIT" --source-root "$SRC" --fp-recheck \
  >"$RUN/i1c.out" 2>"$RUN/i1c.err"
expect_exit 0 "$?" "I1d 정산 실행(--fp-recheck)"
# provenance 경로가 실제로 탔는지 확인한다 — 안 탔으면 아래 단언이 공허하다.
if grep -q "소스 저장소 origin" "$RUN/i1c.out" "$RUN/i1c.err" 2>/dev/null; then
  ok "I1d-0: git provenance 경로가 실행됨 (단언이 공허하지 않음)"
else
  bad "I1d-0: provenance 경로에 도달하지 못했습니다 — I1d-1 이 아무것도 검증하지 못합니다"
  sed 's/^/     /' "$RUN/i1c.out" | head -5
fi
if [ -e "$EVIL_MARK" ]; then
  bad "I1d-1: 대상 저장소가 커밋한 git 이 실행됐습니다 (정산이 원시 PATH 를 물려줍니다)"
else
  ok "I1d-1: 저장소가 커밋한 git 이 실행되지 않음"
fi
# I1d-2. 포기 사유가 **조용히 사라지지 않아야** 한다. origin 대조는 targetId 경로
# 해시 오연결을 잡는 안전장치이므로, 규칙을 못 불러 포기했다면 그 사실이 사람용
# 출력과 --json 양쪽에 남아야 한다(한때 sourceOrigin: null 만 남고 사유는
# except 가 삼켰다). bootstrap.py 를 못 찾는 사본을 만들어 그 경로를 행사한다.
BROKEN_SCRIPTS="$RUN/broken-rules/scripts"
mkdir -p "$BROKEN_SCRIPTS"
cp "$RECONCILE" "$BROKEN_SCRIPTS/coverage_reconcile.py"
# bootstrap.py 를 일부러 두지 않는다 → 규칙 로드 실패 경로.
PY "$BROKEN_SCRIPTS/coverage_reconcile.py" --scan-dir "$SCAN_GIT" --source-root "$SRC"   --fp-recheck --json >"$RUN/i1d2.json" 2>"$RUN/i1d2.err"
expect_exit 0 "$?" "I1d-2 규칙 로드 실패 사본으로 정산 실행"
PY - "$RUN/i1d2.json" <<'EOF'
import json, pathlib, sys
problems = []
try:
    doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception as error:
    print(f"FAIL I1d-2: --json 파싱 실패: {error}")
    raise SystemExit(1)
fp = None
for key in ("fpRecheck", "falsePositiveRecheck", "checks", "results"):
    if isinstance(doc.get(key), dict):
        fp = doc[key]
        break
if fp is None:
    # 최상위에 실리는 형상도 허용한다.
    fp = doc if "sourceOriginError" in doc or "sourceOrigin" in doc else None
if fp is None:
    problems.append(f"--json 에 FP 재검사 결과가 없습니다: {sorted(doc)}")
else:
    if fp.get("sourceOrigin") is not None:
        problems.append("규칙 로드가 실패했는데 sourceOrigin 이 실렸습니다 — 픽스처 미도달")
    err = fp.get("sourceOriginError")
    if not err:
        problems.append("sourceOriginError 가 비었습니다 — 포기 사유가 조용히 사라집니다")
    elif "bootstrap" not in err:
        problems.append(f"sourceOriginError 가 원인을 담지 않습니다: {err!r}")
for p in problems:
    print(f"FAIL I1d-2: {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "I1d-2 포기 사유가 --json 에 실림"
if grep -q "origin 대조를 건너뜀" "$RUN/i1d2.err" "$RUN/i1d2.json" 2>/dev/null; then
  ok "I1d-2: 포기 사유가 사람용 출력에도 남음"
else
  bad "I1d-2: 사람용 출력에 포기 사유가 없습니다 — 안전장치가 소리 없이 사라집니다"
fi
rm -rf "$SRC/node_modules"
fi

# ---------------------------------------------------------------------------
# I2. --allow-empty-inventory 는 diff·deep 스캔의 정당한 0건을 통과시킨다.
#     통과시키더라도 경고는 남긴다 — 조용히 넘어가면 안 된다.
# ---------------------------------------------------------------------------
step "I2. --allow-empty-inventory 로 통과 (diff·deep 전용)"
SCAN_ALLOW="$(make_scan allow "" "$REVIEWED" complete '[]')"
PY "$RECONCILE" --scan-dir "$SCAN_ALLOW" --source-root "$SRC" --allow-empty-inventory \
  >"$RUN/i2.out" 2>"$RUN/i2.err"
expect_exit 0 "$?" "I2a --allow-empty-inventory"
if grep -q "allow-empty-inventory" "$RUN/i2.out" "$RUN/i2.err" 2>/dev/null; then
  ok "I2b: 통과시켰다는 경고가 출력에 남음"
else
  bad "I2b: 빈 인벤토리를 조용히 통과시켰습니다"
  sed 's/^/     /' "$RUN/i2.out"
fi
# 마지막 "판정:" 줄만 읽는 소비자에게도 분모 0 이 전달돼야 한다.
# 파이프로 grep -q 에 넘기지 않는다 — 상류 grep 이 쓸 것이 남은 동안 하류가
# 조기 종료하면 pipefail 이 "일치했는데 실패"로 뒤집는다(u1 H3·H5 와 같은 함정).
I2C_VERDICT="$(grep -h '^판정:' "$RUN/i2.out" "$RUN/i2.err" 2>/dev/null || true)"
case "$I2C_VERDICT" in
  *"분모 0"*) ok "I2c: 최종 판정 줄에 분모 0 이 명시됨" ;;
  *)
    bad "I2c: 판정 줄이 '커버리지가 리뷰 로그와 일치'로만 끝납니다 (분모 0인데 완전 커버리지로 읽힌다)"
    printf '     %s\n' "$I2C_VERDICT" ;;
esac

# ---------------------------------------------------------------------------
# I3. 정상 경로 — 인벤토리 1건, 그 1건이 리뷰됨 → complete 유지, 경고 없음.
#     아래 부분 커버리지 블록의 대조군이다.
# ---------------------------------------------------------------------------
step "I3. 정상 경로 (완전 리뷰)"
SCAN_OK="$(make_scan ok 'src/extract.py
' "$REVIEWED" complete '[]')"
PY "$RECONCILE" --scan-dir "$SCAN_OK" --source-root "$SRC" --json \
  >"$RUN/i3.json" 2>"$RUN/i3.err"
expect_exit 0 "$?" "I3a 정상 정산"
PY - "$RUN/i3.json" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
summary = d.get("coverage") or {}
problems = []
if d.get("status") != "pass":
    problems.append(f"status={d.get('status')!r} (pass 기대)")
if summary.get("completenessAfter") != "complete":
    problems.append(f"completenessAfter={summary.get('completenessAfter')!r} (complete 기대)")
if summary.get("partialWithoutDeferred") is not False:
    problems.append(f"partialWithoutDeferred={summary.get('partialWithoutDeferred')!r} (False 기대)")
if summary.get("unreviewedCount") != 0:
    # None 을 허용하면 키가 사라져도 통과한다.
    problems.append(f"unreviewedCount={summary.get('unreviewedCount')!r} (0 기대)")
for p in problems:
    print(f"FAIL I3: {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "I3b 정상 경로 요약 값"
# I2c 의 대조군 — 분모가 있으면 그 문구가 붙지 않아야 한다(무조건 켜지지 않음).
I3C_VERDICT="$(grep -h '^판정:' "$RUN/i3.err" 2>/dev/null || true)"
case "$I3C_VERDICT" in
  *"분모 0"*) bad "I3c: 분모가 있는 스캔의 판정 줄에 '분모 0' 이 붙었습니다 (I2c 가 무조건 켜집니다)" ;;
  *)          ok "I3c: 대조군 — 분모가 있으면 '분모 0' 이 붙지 않음" ;;
esac

# ---------------------------------------------------------------------------
# I4. 부분 커버리지 + deferred 없음 — SARIF 경고가 0건이라 SARIF 만으로는
#     불완전을 알 수 없다. 그래서 정산이 사람용 출력과 JSON 둘 다에서 말해야 한다.
#     사람용 출력 검사가 핵심이다 — 회귀는 정확히 거기서 신호가 사라졌다.
# ---------------------------------------------------------------------------
step "I4. 부분 커버리지 + deferred 없음 (사람용 출력 + JSON)"
# 인벤토리 전부가 리뷰됐는데도 completeness 가 partial 인 형상. 미리뷰가 0이므로
# 정산은 deferred 를 추가하지 않는다 → partial + deferred 0건이 남는다.
# 이때 SARIF 에는 경고가 실리지 않아 SARIF 만 보면 완전한 스캔처럼 보인다.
SCAN_PWD="$(make_scan pwd 'src/extract.py
' "$REVIEWED" partial '[]')"
PY "$RECONCILE" --scan-dir "$SCAN_PWD" --source-root "$SRC" --json \
  >"$RUN/i4.json" 2>"$RUN/i4.err"
I4_RC=$?
expect_exit 0 "$I4_RC" "I4a 부분 커버리지 정산"
# 사람용 출력(stderr, --json 일 때)에 신호가 실제로 찍히는가.
# "SARIF" 는 경고 블록 서술문에도 나온다. 전용 정직성 라인의 문자열로 좁혀야
# 그 라인만 제거하는 회귀를 잡는다(느슨한 패턴으로는 통과했다 — 실측).
if grep -q "SARIF 경고 없음" "$RUN/i4.err"; then
  ok "I4b: 사람용 출력에 SARIF 경고 부재 신호가 찍힘"
else
  bad "I4b: 사람용 출력에 신호가 없습니다 (경고 계산이 출력보다 뒤에 있는 회귀)"
  sed 's/^/     /' "$RUN/i4.err"
fi
PY - "$RUN/i4.json" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
summary = d.get("coverage") or {}
problems = []
if summary.get("partialWithoutDeferred") is not True:
    problems.append(f"partialWithoutDeferred={summary.get('partialWithoutDeferred')!r} (True 기대)")
if summary.get("deferredCount") != 0:
    problems.append(f"deferredCount={summary.get('deferredCount')!r} (0 기대)")
if summary.get("completenessAfter") == "complete":
    problems.append("completenessAfter 가 complete — 미리뷰가 있는데 완전으로 주장했습니다")
for p in problems:
    print(f"FAIL I4: {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "I4c JSON 요약 값"
# 마지막 "판정:" 줄에도 신호가 실려야 한다 — 그 한 줄만 읽는 소비자가 있다.
I4D_VERDICT="$(grep -h '^판정:' "$RUN/i4.err" 2>/dev/null || true)"
case "$I4D_VERDICT" in
  *SARIF*) ok "I4d: 최종 판정 줄에도 완결성 신호가 실림" ;;
  *)
    bad "I4d: 최종 판정 줄이 '통과, 진행하세요'로만 끝납니다 (완전 커버리지로 요약된다)"
    printf '     %s\n' "$I4D_VERDICT" ;;
esac

# ---------------------------------------------------------------------------
# I5. 부분 커버리지 + deferred 있음 — 미리뷰가 있으면 정산이 스스로 deferred
#     항목을 추가하고, 그러면 SARIF 에 경고가 실리므로 이 신호는 꺼져야 한다.
#     I4 가 "partial 이면 항상 켜진다"가 아니라 deferred 건수를 실제로 보는지 가른다.
# ---------------------------------------------------------------------------
step "I5. 부분 커버리지 + deferred 있음 (신호 꺼짐)"
# 정산은 파일시스템을 순회하지 않으므로 in_scope 경로의 실존을 요구하지 않는다.
# 이 touch 는 무동작이지만, 픽스처를 읽는 사람이 "실존해야 카운트된다"고
# 오해하지 않도록 명시해 둔다.
touch "$SRC/src/unreviewed.py"
SCAN_DEF="$(make_scan deferred 'src/extract.py
src/unreviewed.py
' "$REVIEWED" partial '[]')"
PY "$RECONCILE" --scan-dir "$SCAN_DEF" --source-root "$SRC" --json \
  >"$RUN/i5.json" 2>"$RUN/i5.err"
expect_exit 0 "$?" "I5a 미리뷰가 있어 deferred 가 추가되는 부분 커버리지"
PY - "$RUN/i5.json" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
summary = d.get("coverage") or {}
problems = []
if summary.get("partialWithoutDeferred") is not False:
    problems.append(f"partialWithoutDeferred={summary.get('partialWithoutDeferred')!r} (False 기대)")
if not summary.get("deferredCount"):
    problems.append(f"deferredCount={summary.get('deferredCount')!r} (1 이상 기대)")
for p in problems:
    print(f"FAIL I5: {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "I5b 신호가 꺼짐"
# 음성 grep 단독은 fail-open 이다 — 출력이 아예 없으면 "신호 없음"으로 통과한다.
if [ ! -s "$RUN/i5.err" ]; then
  bad "I5c: 사람용 출력이 비었습니다 — 신호 부재를 판정할 수 없습니다"
elif grep -q "SARIF 경고 없음" "$RUN/i5.err"; then
  bad "I5c: deferred 가 있는데 'SARIF 경고 없음' 신호가 찍혔습니다"
else
  ok "I5c: 사람용 출력에 잘못된 신호가 없음"
fi
# 음성 대조군은 "판정 줄에 신호가 없다"와 "판정 줄이 아예 없다"를 갈라야 한다.
I5D_VERDICT="$(grep -h '^판정:' "$RUN/i5.err" 2>/dev/null || true)"
if [ -z "$I5D_VERDICT" ]; then
  bad "I5d: 판정 줄 자체가 없습니다 — 신호 부재를 판정할 수 없습니다"
else
  case "$I5D_VERDICT" in
    *SARIF*) bad "I5d: deferred 가 있는데 판정 줄에 완결성 신호가 붙었습니다 (I4d 가 무조건 켜진다)" ;;
    *)       ok "I5d: 대조군 — 판정 줄에 신호가 붙지 않음" ;;
  esac
fi

# ---------------------------------------------------------------------------
# I5x. completeness 필드가 없는 형상(npm 0.4.0, 상류 c380befb9 #1633).
#      0.4.0 coverage 스키마에는 completeness 가 없고 finalizer 가 unsealed draft 의
#      키를 버린다. 정산은 키를 새로 만들지 않고, 완결성은 coverageComplete 로 낸다.
#      SARIF 는 deferred 가 있을 때만 경고를 싣는다 — 판정 축은 0.2.0 과 같다.
# ---------------------------------------------------------------------------
step "I5x. completeness 필드 없음 (npm 0.3.0 이후 형상)"
# (1) 완전 리뷰 · deferred 없음 → 완전, 신호 꺼짐, 키를 만들지 않음.
SCAN_NC_OK="$(make_scan nc-ok 'src/extract.py
' "$REVIEWED" - '[]')"
PY "$RECONCILE" --scan-dir "$SCAN_NC_OK" --source-root "$SRC" --json \
  >"$RUN/i5x1.json" 2>"$RUN/i5x1.err"
expect_exit 0 "$?" "I5x-1a 완전 리뷰 정산"
# (2) 미리뷰 1건 → deferred 추가, 키는 여전히 없음, 신호 꺼짐(SARIF 가 경고를 싣는다).
SCAN_NC_DEF="$(make_scan nc-def 'src/extract.py
src/unreviewed.py
' "$REVIEWED" - '[]')"
PY "$RECONCILE" --scan-dir "$SCAN_NC_DEF" --source-root "$SRC" --json \
  >"$RUN/i5x2.json" 2>"$RUN/i5x2.err"
expect_exit 0 "$?" "I5x-2a 미리뷰가 있는 정산"
# (3) 완전 리뷰지만 needs_follow_up surface 가 있고 deferred 가 빔 → 신호 켜짐.
SCAN_NC_FU="$(make_scan nc-fu 'src/extract.py
' "$REVIEWED" - '[]')"
PY - "$SCAN_NC_FU/coverage.json" <<'EOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
coverage = json.loads(path.read_text())
coverage["surfaces"].append(
    {"id": "follow-up", "label": "Follow-up surface", "disposition": "needs_follow_up", "receiptRefs": []}
)
path.write_text(json.dumps(coverage, indent=2))
EOF
PY "$RECONCILE" --scan-dir "$SCAN_NC_FU" --source-root "$SRC" --json \
  >"$RUN/i5x3.json" 2>"$RUN/i5x3.err"
expect_exit 0 "$?" "I5x-3a needs_follow_up 만 남은 정산"
PY - "$RUN" "$SCAN_NC_OK" "$SCAN_NC_DEF" "$SCAN_NC_FU" <<'EOF'
import json, pathlib, sys
run = pathlib.Path(sys.argv[1])
scans = [pathlib.Path(p) for p in sys.argv[2:]]
expected = [
    # (라벨, coverageComplete, partialWithoutDeferred, deferredCount>0)
    ("I5x-1", True, False, False),
    ("I5x-2", False, False, True),
    ("I5x-3", False, True, False),
]
problems = []
for index, (label, complete, pwd, has_deferred) in enumerate(expected, start=1):
    d = json.loads((run / f"i5x{index}.json").read_text())
    summary = d.get("coverage") or {}
    if summary.get("completenessField") is not False:
        problems.append(f"{label}: completenessField={summary.get('completenessField')!r} (False 기대)")
    if summary.get("completenessAfter") is not None:
        problems.append(f"{label}: completenessAfter={summary.get('completenessAfter')!r} (None 기대)")
    if summary.get("coverageComplete") is not complete:
        problems.append(f"{label}: coverageComplete={summary.get('coverageComplete')!r} ({complete} 기대)")
    if summary.get("partialWithoutDeferred") is not pwd:
        problems.append(f"{label}: partialWithoutDeferred={summary.get('partialWithoutDeferred')!r} ({pwd} 기대)")
    if bool(summary.get("deferredCount")) is not has_deferred:
        problems.append(f"{label}: deferredCount={summary.get('deferredCount')!r}")
    coverage = json.loads((scans[index - 1] / "coverage.json").read_text())
    if "completeness" in coverage:
        problems.append(f"{label}: 정산이 completeness 키를 새로 만들었습니다 — 0.2.0 형상으로 되돌립니다")
for p in problems:
    print(f"FAIL {p}")
raise SystemExit(1 if problems else 0)
EOF
expect_exit 0 "$?" "I5x-b 요약 값과 coverage.json 형상"
# 대조군: 사람용 출력의 신호는 needs_follow_up + deferred 0건(I5x-3)에만 붙는다.
if grep -q "SARIF 경고 없음" "$RUN/i5x3.err" && ! grep -q "SARIF 경고 없음" "$RUN/i5x1.err"; then
  ok "I5x-c: 사람용 출력의 신호가 needs_follow_up + deferred 0건에만 붙음"
else
  bad "I5x-c: 사람용 출력 신호가 기대와 다릅니다"
  sed 's/^/     /' "$RUN/i5x3.err" | tail -5
fi

# ---------------------------------------------------------------------------
# I5y. 매니페스트와 coverage 의 includePaths 불일치 경고(npm 0.8.0, 상류 621bad47e #1762).
#      0.8.0 bind-repo-scopes 는 매니페스트만 바꾼다. coverage 를 맞추지 않으면 finalize 가
#      `coverage.includePaths: must match manifest scope` 로 거부하므로, 정산이 먼저 알린다.
# ---------------------------------------------------------------------------
step "I5y. includePaths 불일치 경고"
SCAN_IP_OK="$(make_scan ip-ok 'src/extract.py
' "$REVIEWED" - '[]')"
SCAN_IP_BAD="$(make_scan ip-bad 'src/extract.py
' "$REVIEWED" - '[]')"
PY - "$SCAN_IP_BAD/scan-manifest.json" <<'EOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest["scan"]["scope"]["includePaths"] = ["src/extract.py"]
path.write_text(json.dumps(manifest, indent=2))
EOF
PY "$RECONCILE" --scan-dir "$SCAN_IP_OK" --source-root "$SRC" --json >"$RUN/i5y1.json" 2>"$RUN/i5y1.err"
expect_exit 0 "$?" "I5y-1 includePaths 가 같은 정산"
PY "$RECONCILE" --scan-dir "$SCAN_IP_BAD" --source-root "$SRC" --json >"$RUN/i5y2.json" 2>"$RUN/i5y2.err"
expect_exit 0 "$?" "I5y-2 includePaths 가 다른 정산(경고만, 차단하지 않음)"
PY - "$RUN/i5y1.json" "$RUN/i5y2.json" <<'EOF'
import json, sys
def hits(path):
    return [w for w in json.load(open(path)).get("warnings", []) if "includePaths" in w]
same, differ = hits(sys.argv[1]), hits(sys.argv[2])
raise SystemExit(0 if not same and len(differ) == 1 and "src/extract.py" in differ[0] else 1)
EOF
if [ "$?" = 0 ]; then
  ok "I5y: 불일치일 때만 includePaths 경고 1건(대조군: 같으면 없음)"
else
  bad "I5y: includePaths 경고가 기대와 다릅니다"
  sed 's/^/     /' "$RUN/i5y2.json" | head -20
fi

# ---------------------------------------------------------------------------
# I6. --json 의 스트림 분리 — JSON 은 stdout, 사람용 요약은 stderr.
#     최종 보고가 JSON 키를 인용하므로 stdout 이 순수 JSON 이어야 한다.
# ---------------------------------------------------------------------------
step "I6. --json 스트림 분리"
if PY -c 'import json,sys; json.load(open(sys.argv[1]))' "$RUN/i4.json" 2>/dev/null; then
  ok "I6a: stdout 이 순수 JSON 으로 파싱됨"
else
  bad "I6a: stdout 이 JSON 으로 파싱되지 않습니다 (사람용 출력이 섞였습니다)"
  head -3 "$RUN/i4.json" | sed 's/^/     /'
fi
if [ -s "$RUN/i4.err" ]; then
  ok "I6b: 사람용 요약이 stderr 로 나감"
else
  bad "I6b: stderr 가 비었습니다 — 사람용 요약이 사라졌습니다"
fi

# ---------------------------------------------------------------------------
# I7~I8. recover 의 실패 구분 — 게이트 거부와 인프라 실패는 안내가 달라야 한다.
#     둘 다 exit 0 + ok:false 다(비가역 작업이 아니므로 다른 선택지로 넘어간다).
# ---------------------------------------------------------------------------
step "I7. recover 게이트 거부 (상류가 거부)"
if [ -z "$PLUGIN" ] || [ ! -f "$PLUGIN/scripts/workbench_db.py" ]; then
  skip "I7: 플러그인을 찾지 못해 recover 게이트 거부를 검증할 수 없습니다"
  skip "I8: 플러그인을 찾지 못해 recover 인프라 실패를 검증할 수 없습니다"
  skip "I9: 플러그인을 찾지 못해 상류 파손(infra) 분류를 검증할 수 없습니다"
  skip "I10: 플러그인을 찾지 못해 게이트 거부 대조군을 검증할 수 없습니다"
  skip "I11: 플러그인을 찾지 못해 서브커맨드 부재(infra) 분류를 검증할 수 없습니다"
  skip "I12: 플러그인을 찾지 못해 상류 파손 형상별 분류를 검증할 수 없습니다"
  skip "I13: 플러그인을 찾지 못해 errno 문구 정상 거부 분류를 검증할 수 없습니다"
  skip "I14: 플러그인을 찾지 못해 개행 경로 선차단을 검증할 수 없습니다"
  skip "I14b: 플러그인을 찾지 못해 개행 게이트 대조군을 검증할 수 없습니다"
  skip "I14c: 플러그인을 찾지 못해 분할문자 분류를 검증할 수 없습니다"
  skip "I14d: 플러그인을 찾지 못해 실제 개행 다중행 대조군을 검증할 수 없습니다"
  skip "I15: 플러그인을 찾지 못해 complete 실패 페이로드 분류를 검증할 수 없습니다"
  skip "I15b: 플러그인을 찾지 못해 분류별 힌트를 검증할 수 없습니다"
  skip "I16: 플러그인을 찾지 못해 저장소 local config 실행 차단을 검증할 수 없습니다"
else
  GLUE_STATE="$RUN/glue-state"
  mkdir -p "$GLUE_STATE"
  chmod 700 "$GLUE_STATE"
  PY - "$RUN/boot-ok.json" "$PLUGIN" "$GLUE_STATE" "$SRC" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True,
    "pluginRoot": plugin,
    "pluginVersion": "probe",
    "stateDir": state,
    "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  # UUID 형태여야 한다. UUID 가 아니면 상류가 스캔 조회 **전** 입력검증에서
  # 거부해("scan-id must be a UUID.") 재려던 축이 인자 형식 오류로 바뀐다(실측).
  PY "$GLUE" --bootstrap "$RUN/boot-ok.json" recover \
    --scan-id "00000000-0000-4000-8000-000000000000" \
    >"$RUN/i7.json" 2>"$RUN/i7.err"
  expect_exit 0 "$?" "I7a recover 거부는 exit 0"
  PY - "$RUN/i7.json" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
problems = []
if d.get("ok") is not False:
    problems.append(f"ok={d.get('ok')!r} (False 기대)")
if d.get("failureKind") != "gate":
    problems.append(f"failureKind={d.get('failureKind')!r} (gate 기대)")
# hint 는 kind 로만 분기하는 고정 문자열이라 kind 를 단언한 뒤 검사하면
# 동어반복이다. 상류가 **스캔을 조회한 뒤** 거부했다는 근거를 detail 에서 본다.
detail = (d.get("detail") or "").lower()
if "not found" not in detail:
    problems.append(
        f"상류 거부 사유가 '스캔 없음'이 아닙니다: {(d.get('detail') or '')[:120]!r} "
        "— 인자 형식 오류나 서브커맨드 부재를 게이트 거부로 재고 있을 수 있습니다"
    )
for p in problems:
    print(f"FAIL I7: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "I7b 게이트 거부 형상"

  step "I8. recover 인프라 실패 (상류를 실행조차 못함)"
  # python 경로를 존재하지 않는 값으로 두면 프로세스 기동 자체가 실패한다.
  PY - "$RUN/boot-broken.json" "$PLUGIN" "$GLUE_STATE" "$SRC" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo = sys.argv[1:5]
pathlib.Path(out).write_text(json.dumps({
    "ok": True,
    "pluginRoot": plugin,
    "pluginVersion": "probe",
    "stateDir": state,
    "repoRoot": repo,
    "python": {"path": "/nonexistent/python-does-not-exist", "version": "probe"},
}, indent=2))
EOF
  PY "$GLUE" --bootstrap "$RUN/boot-broken.json" recover --scan-id "scan_whatever_0001" \
    >"$RUN/i8.json" 2>"$RUN/i8.err"
  expect_exit 0 "$?" "I8a recover 인프라 실패도 exit 0"
  PY - "$RUN/i8.json" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
problems = []
if d.get("ok") is not False:
    problems.append(f"ok={d.get('ok')!r} (False 기대)")
if d.get("failureKind") != "infra":
    problems.append(f"failureKind={d.get('failureKind')!r} (infra 기대)")
# hint 는 kind 로만 분기하므로 kind 단언 뒤에는 동어반복이다. 대신 상류를
# 기동조차 못했다는 근거를 detail 에서 확인한다.
detail = (d.get("detail") or "")
if "No such file or directory" not in detail and "실행 실패" not in detail:
    problems.append(f"기동 실패 근거가 detail 에 없습니다: {detail[:120]!r}")
for p in problems:
    print(f"FAIL I8: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "I8b 인프라 실패 형상"

  # -------------------------------------------------------------------------
  # I9. 상류가 기동은 했으나 깨진 경우 — I8(기동 실패)이 덮지 못하는 축이다.
  #
  # bootstrap 은 매니페스트 존재만 보고 scripts/workbench_db.py 실존은 검사하지
  # 않는다. 그 스크립트가 없으면 인터프리터는 정상 기동한 뒤 rc=2 로 끝나므로,
  # 비-0 종료를 무조건 게이트 거부로 보면 "status=failed 스캔만 대상" 안내가
  # 붙어 사용자가 없는 문제를 쫓는다.
  # -------------------------------------------------------------------------
  step "I9. recover 인프라 실패 (상류가 기동은 했으나 깨짐)"
  BROKEN_PLUGIN="$RUN/broken-plugin"
  mkdir -p "$BROKEN_PLUGIN/scripts" "$BROKEN_PLUGIN/.codex-plugin"
  printf '{"version":"0.0.0-broken"}\n' >"$BROKEN_PLUGIN/.codex-plugin/plugin.json"
  # scripts/ 는 있지만 workbench_db.py 는 없다.
  PY - "$RUN/boot-noscript.json" "$BROKEN_PLUGIN" "$GLUE_STATE" "$SRC" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True,
    "pluginRoot": plugin,
    "pluginVersion": "0.0.0-broken",
    "stateDir": state,
    "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  PY "$GLUE" --bootstrap "$RUN/boot-noscript.json" recover --scan-id "scan_whatever_0002" \
    >"$RUN/i9.json" 2>"$RUN/i9.err"
  expect_exit 0 "$?" "I9a workbench_db.py 부재도 exit 0"
  PY - "$RUN/i9.json" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
problems = []
if d.get("ok") is not False:
    problems.append(f"ok={d.get('ok')!r} (False 기대)")
if d.get("failureKind") != "infra":
    problems.append(
        f"failureKind={d.get('failureKind')!r} (infra 기대) — 상류가 깨진 것을 "
        "게이트 거부로 오분류하면 전제 안내가 붙어 사용자가 없는 문제를 쫓는다"
    )
# kind 만 보면 stderr 마커 휴리스틱이 우연히 맞춰줘도 통과한다(실측: 가드를
# 지워도 `can't open file` 마커가 같은 결론을 낸다). 래퍼가 실행 **전에** 스스로
# 못 박았다는 근거를 detail 에서 확인해야 그 가드가 고정된다.
if "workbench_db.py 가 없습니다" not in (d.get("detail") or ""):
    problems.append(
        f"래퍼의 사전 가드 근거가 detail 에 없습니다: {(d.get('detail') or '')[:120]!r}"
    )
if "status=failed" in (d.get("hint") or ""):
    problems.append("상류가 깨졌는데 스캔 전제 안내가 붙었습니다")
for p in problems:
    print(f"FAIL I9: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "I9b 상류 파손이 infra 로 분류됨"

  # -------------------------------------------------------------------------
  # I10. 대조군 — 상류가 정상 실행되고 스스로 거부하면 gate 여야 한다.
  #      I9 가 "비-0 이면 전부 infra" 로 뒤집히지 않았음을 보장한다.
  # -------------------------------------------------------------------------
  # -------------------------------------------------------------------------
  # I11. recover-scan-results 서브커맨드가 없는 사본 — 우리 래퍼가 플러그인과
  #      어긋난 상태다. 이것을 게이트 거부로 분류하면, 상류가 복구 경로를
  #      제거·개명해도 I7 이 초록불로 남아 "검증 대상 기능이 없는데 통과"가 된다.
  # -------------------------------------------------------------------------
  step "I11. recover 서브커맨드 부재는 gate 가 아니다"
  NOSUB_PLUGIN="$RUN/nosub-plugin"
  mkdir -p "$NOSUB_PLUGIN/scripts" "$NOSUB_PLUGIN/.codex-plugin"
  printf '{"version":"0.0.0-nosub"}\n' >"$NOSUB_PLUGIN/.codex-plugin/plugin.json"
  cat >"$NOSUB_PLUGIN/scripts/workbench_db.py" <<'EOF'
import argparse, sys
parser = argparse.ArgumentParser()
sub = parser.add_subparsers(dest="command", required=True)
sub.add_parser("list-scans")
parser.parse_args()
EOF
  PY - "$RUN/boot-nosub.json" "$NOSUB_PLUGIN" "$GLUE_STATE" "$SRC" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": "0.0.0-nosub",
    "stateDir": state, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  PY "$GLUE" --bootstrap "$RUN/boot-nosub.json" recover \
    --scan-id "00000000-0000-4000-8000-000000000000" \
    >"$RUN/i11.json" 2>"$RUN/i11.err"
  expect_exit 0 "$?" "I11a 서브커맨드 부재도 exit 0"
  I11_KIND="$(PY -c 'import json,sys; print((json.load(open(sys.argv[1])) or {}).get("failureKind"))' "$RUN/i11.json")"
  if [ "$I11_KIND" = "infra" ]; then
    ok "I11b: 서브커맨드 부재가 infra 로 분류됨 (래퍼-플러그인 불일치)"
  else
    bad "I11b: failureKind=$I11_KIND — 서브커맨드가 없는데 게이트 거부로 안내하면 사용자가 스캔 상태를 쫓습니다"
    sed 's/^/     /' "$RUN/i11.json"
  fi

  # -------------------------------------------------------------------------
  # I12. 상류 파손의 여러 형상이 전부 infra 로 분류되는가.
  #
  # 초기 구현은 "stdout 이 있으면 상류가 판단해 거부한 것"으로 봤는데 실측은
  # 정반대였다 — 상류는 **성공에만** stdout 을 쓰고, 거부는 rc=1 + stdout 공백 +
  # stderr 한 줄이다. 그래서 아래 형상들이 전부 "게이트 거부"로 새어 사용자에게
  # "status=failed 스캔만 대상" 안내가 갔다. 어휘가 아니라 형상으로 판정한다.
  # -------------------------------------------------------------------------
  step "I12. 상류 파손 형상별 분류 (형상 규칙)"
  broken_case() { # broken_case <이름> <workbench_db.py 본문>
    local name="$1" body="$2"
    local root="$RUN/bp-$name"
    mkdir -p "$root/scripts" "$root/.codex-plugin"
    printf '{"version":"0.0.0-%s"}\n' "$name" >"$root/.codex-plugin/plugin.json"
    printf '%s' "$body" >"$root/scripts/workbench_db.py"
    PY - "$RUN/boot-$name.json" "$root" "$GLUE_STATE" "$SRC" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": "broken",
    "stateDir": state, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
    PY "$GLUE" --bootstrap "$RUN/boot-$name.json" recover \
      --scan-id "00000000-0000-4000-8000-000000000000" \
      >"$RUN/i12-$name.json" 2>"$RUN/i12-$name.err"
    local kind
    kind="$(PY -c 'import json,sys
try: print((json.load(open(sys.argv[1])) or {}).get("failureKind"))
except Exception: print("<파싱실패>")' "$RUN/i12-$name.json")"
    if [ "$kind" = "infra" ]; then
      ok "I12/$name: infra 로 분류됨"
    else
      bad "I12/$name: failureKind=$kind — 상류 파손이 게이트 거부로 안내됩니다"
      sed 's/^/     /' "$RUN/i12-$name.json"
    fi
  }
  # 최상위 문법 오류: CPython 이 Traceback 헤더를 찍지 않아 문자열 매칭이 놓쳤다.
  broken_case syntax 'def (
'
  # 무출력 비-0: 거부는 항상 사유를 남기므로, 말없이 죽으면 거부가 아니다.
  broken_case silent 'import os
os._exit(1)
'
  # 시그널 사망: returncode 가 음수다. stderr 를 한 줄 남겨야 "무출력 비-0" 규칙에
  # 흡수되지 않고 returncode 형상 규칙만이 이 케이스를 infra 로 만든다 — 그러지
  # 않으면 I12/silent 와 완전히 중복이고 returncode 규칙을 지워도 통과한다(실측).
  broken_case signal 'import os, signal, sys
sys.stderr.write("recover-scan-results: scan not eligible\n")
sys.stderr.flush()
os.kill(os.getpid(), signal.SIGKILL)
'
  # 성공 페이로드를 쓰다 죽음: stdout 이 있지만 거부가 아니다.
  # RuntimeError 를 올리면 Traceback 이 남아 기존 마커가 먼저 잡고 stdout 규칙이
  # 검증되지 않는다(실측: `if out` 을 지워도 통과). 마커 없는 1줄 stderr + rc=1 로
  # stdout 규칙만 남긴다.
  broken_case partial 'import sys
sys.stdout.write("{\"scan\": {\"id\":")
sys.stdout.flush()
sys.stderr.write("recover-scan-results: scan not eligible\n")
sys.exit(1)
'

  # rc=1 + 다중행 stderr: 인터프리터 래퍼(mise 심 등)가 낸 것이다. 상류 거부
  # 메시지는 개행을 담지 않는다(SystemExit 335건·ContractError 150건 중 0건 — 실측).
  # 마커가 없어서 이전 규칙에서는 게이트 거부로 샜다.
  broken_case multiline 'import sys
sys.stderr.write("wrapper install failed\n definition not found\n ERROR exit code 2\n")
sys.exit(1)
'
  # rc=120: stdout 플러시 실패. 상류 거부는 전부 rc=1 이므로 다른 코드는 거부가 아니다.
  # signal 과 같은 이유로 stderr 를 1줄 남겨야 한다 — 무출력이면 줄수 규칙이 흡수해
  # rc 축이 미검증이 된다(실측: rc 규칙을 구 거부목록으로 되돌려도 전 스위트 통과).
  broken_case flush120 'import os, sys
sys.stderr.write("recover-scan-results: scan not eligible\n")
sys.stderr.flush()
os._exit(120)
'

  # -------------------------------------------------------------------------
  # I13. errno 문자열을 담은 **정상 거부**는 gate 여야 한다.
  #
  # 상류 read_json_object 는 OSError 까지 잡아
  # `SystemExit(f"{name}: invalid JSON: {exc}")` 로 바꾼다. 그래서 산출물 권한
  # 문제가 정상 거부 형상(rc=1·stdout 공백·stderr 1줄)으로 나온다. `Permission
  # denied` 를 infra 마커에 넣으면 "파일 권한을 고치세요"가 "플러그인을
  # 확인하세요"로 오안내된다 — 마커를 뺀 근거를 여기서 고정한다.
  # -------------------------------------------------------------------------
  # -------------------------------------------------------------------------
  # I14. 개행이 든 경로는 진입 시점에 gate 로 차단한다.
  #
  # `_failure_kind` 의 "거부 stderr 는 정확히 1줄" 불변식은 상류 메시지가 리터럴일
  # 때만 성립한다. 상류에는 경로를 보간하는 사이트가 있어(workbench_db.py:270
  # `SystemExit(f"…: {target}")`), 경로에 개행이 있으면 정상 거부가 2줄이 되어
  # infra 로 뒤집힌다 — 사용자는 "경로를 고치세요" 대신 "플러그인을 확인하세요"를
  # 받는다. 불변식의 전제를 load_bootstrap 이 강제하는지 고정한다.
  # -------------------------------------------------------------------------
  # -------------------------------------------------------------------------
  # I15. complete 의 실패 페이로드도 failureKind 로 갈려야 한다.
  #
  # complete 는 게이트 실패를 예외가 아니라 구조화 결과로 돌려주므로 GlueError 를
  # 타지 않는다. failureKind 가 없으면 SKILL.md 의 R6 분기가 상류 파손을 "워킹트리
  # 게이트 실패"로 단정해, 되돌릴 변경도 없는데 "변경을 되돌리고 재시도" 3선택지를
  # 제시한다(그리고 트레이스백의 경로 줄이 changedFiles 로 수집된다).
  # -------------------------------------------------------------------------
  # -------------------------------------------------------------------------
  # I16. safe.directory 를 강제하면 저장소 자신의 `.git/config` 가 적용된다 —
  #      그 문을 함께 닫았는지.
  #
  # safe.directory 가 막는 것은 정확히 "git 이 저장소의 .git/config 를 신뢰하는가"다.
  # 우리는 소유자가 다른 저장소에서 add-back 이 조용히 사라지는 것을 막으려고 그것을
  # 강제한다 — 그러면 저장소가 커밋한 `core.fsmonitor`(ls-files 에서 임의 명령 실행)와
  # `diff.external`(diff 경로)이 살아난다(둘 다 재현). 환경 config 가 저장소 local 을
  # 덮으므로(실측) 실행 채널을 빈 값으로 함께 못 박아야 한다.
  #
  # 이 목록은 bootstrap.probe_child_env 와 coverage_reconcile._git_child_env **두 곳에
  # 복제**돼 있어 한쪽만 고치면 어긋난다. 두 소비자를 각각 검사한다.
  # -------------------------------------------------------------------------
  step "I16. 저장소 .git/config 의 실행 채널 차단 (safe.directory 강제의 대가)"
  # I1d 와 같은 이유로 git 전제를 검사한다 — 전제 부족은 SKIP 이어야 한다.
  if ! git --version >/dev/null 2>&1; then
    skip "I16: git 을 쓸 수 없어 저장소 local config 실행 차단을 검증할 수 없습니다"
  else
  EVIL_REPO="$RUN/evil-config-repo"
  mkdir -p "$EVIL_REPO"
  ( cd "$EVIL_REPO" && git -c core.excludesFile=/dev/null init -q . \
      && printf 'a\n' > a.py && git add a.py \
      && git -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 ) || true
  HOOK_MARK="$RUN/local-config-ran"
  cat >"$RUN/local-hook.sh" <<EOF
#!/usr/bin/env bash
touch "$HOOK_MARK"
EOF
  chmod 755 "$RUN/local-hook.sh"
  ( cd "$EVIL_REPO" \
      && git config core.fsmonitor "$RUN/local-hook.sh" \
      && git config diff.external "$RUN/local-hook.sh" ) || true
  printf 'b\n' >> "$EVIL_REPO/a.py"

  # (1) bootstrap 의 자식 환경
  I16_BOOTSTRAP="${CODEX_SECURITY_BOOTSTRAP:-$WORK/../../../skills/codex-security-scan/scripts/bootstrap.py}"
  if [ ! -f "$I16_BOOTSTRAP" ]; then
    skip "I16-1: bootstrap.py 를 찾지 못해 자식 환경을 검사할 수 없습니다"
  else
    rm -f "$HOOK_MARK"
    PY - "$I16_BOOTSTRAP" "$EVIL_REPO" "$GLUE_STATE" <<'EOF'
import importlib.util, pathlib, shutil, subprocess, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["bs"] = mod
spec.loader.exec_module(mod)
# 자식 PATH 를 "/usr/bin:/bin" 으로 하드코딩하면 안 된다 — Homebrew(macOS)·Nix·
# mise 로 관리하는 git 은 거기에 없고, 그러면 `git` 이 FileNotFoundError 로 죽어
# **중립화를 완전히 삭제한 상태에서도** 이 블록이 초록이 된다(실측). 셸 쪽
# `git --version` 가드는 ambient PATH 를 보므로 이것을 보장하지 못한다.
git_path = shutil.which("git")
if git_path is None:
    raise SystemExit("I16-1: git 실행 파일을 찾지 못했습니다")
env = mod.probe_child_env(
    {}, pathlib.Path(sys.argv[2]), str(pathlib.Path(git_path).parent), pathlib.Path(sys.argv[3])
)
for args in (["ls-files"], ["diff", "--raw"]):
    r = subprocess.run(["git", "-C", sys.argv[2], *args], capture_output=True, text=True, env=env)
    # git 이 실제로 돌았는지 확인한다. 안 돌면 픽스처가 축에 도달하지 못한 것이다.
    if r.returncode != 0:
        raise SystemExit(
            f"I16-1: git {' '.join(args)} 가 실행되지 않았습니다(rc={r.returncode}): "
            f"{r.stderr.strip()[:200]}"
        )
EOF
    expect_exit 0 "$?" "I16-1 자식 환경 검사가 실제로 git 을 실행"
    if [ -e "$HOOK_MARK" ]; then
      bad "I16-1: bootstrap 자식 환경에서 저장소 .git/config 의 실행 채널이 발동했습니다"
    else
      ok "I16-1: bootstrap 자식 환경이 저장소 local config 실행을 막음"
    fi
  fi

  # (2) coverage_reconcile 의 자식 환경 (별도 복제본)
  rm -f "$HOOK_MARK"
  PY - "$RECONCILE" "$EVIL_REPO" <<'EOF'
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("cr", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cr"] = mod
spec.loader.exec_module(mod)
env, reason = mod._git_child_env(sys.argv[2])
# 실패 센티넬은 빈 문자열 PATH 가 아니라 None 이다 — PATH="" 는
# os.get_exec_path 에서 [""] 가 되어 **cwd 상대 `git` 을 실행**한다(실측).
if env is None:
    raise SystemExit(f"I16-2: 정화 환경을 만들지 못했습니다: {reason}")
if not env.get("PATH"):
    raise SystemExit("I16-2: PATH 가 비었습니다 — 빈 PATH 는 cwd 상대 실행을 뜻합니다")
for args in (["ls-files"], ["diff", "--raw"]):
    r = subprocess.run(["git", "-C", sys.argv[2], *args], capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise SystemExit(
            f"I16-2: git {' '.join(args)} 가 실행되지 않았습니다(rc={r.returncode}): "
            f"{r.stderr.strip()[:200]}"
        )
EOF
  expect_exit 0 "$?" "I16-2 정산 자식 환경 검사가 실제로 git 을 실행"
  if [ -e "$HOOK_MARK" ]; then
    bad "I16-2: 정산의 자식 환경에서 저장소 .git/config 의 실행 채널이 발동했습니다 (두 복제본이 어긋남)"
  else
    ok "I16-2: 정산 자식 환경도 저장소 local config 실행을 막음"
  fi

  # (3) 대조군 — safe.directory 자체는 여전히 유효해야 한다(소유자가 달라도 동작).
  rm -f "$HOOK_MARK"
  I16_OUT="$(PY - "$RECONCILE" "$EVIL_REPO" <<'EOF'
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("cr", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["cr"] = mod
spec.loader.exec_module(mod)
env, reason = mod._git_child_env(sys.argv[2])
if env is None:
    raise SystemExit(f"정화 환경 생성 실패: {reason}")
env["GIT_TEST_ASSUME_DIFFERENT_OWNER"] = "1"
r = subprocess.run(["git", "-C", sys.argv[2], "ls-files"], capture_output=True, text=True, env=env)
print(r.stdout.strip())
EOF
)"
  if [ "$I16_OUT" = "a.py" ]; then
    ok "I16-3 대조군: 소유자가 달라도 git 이 동작함 (safe.directory 가 살아 있다)"
  else
    bad "I16-3 대조군: 소유자가 다른 저장소에서 git 이 실패했습니다 — safe.directory 복원이 깨졌습니다 (출력=$I16_OUT)"
  fi

  # (4) `.gitattributes` 가 이름을 고르는 filter/diff 드라이버.
  #
  # **고정 키 열거로는 닫을 수 없는 클래스다** — 드라이버 이름을 저장소가 커밋한
  # `.gitattributes` 가 정한다. 실측: `* filter=pwn diff=pwn` 을 커밋하고
  # `.git/config` 에 `filter.pwn.clean` 을 두면 (1)~(3)의 9개 키 목록이 다 얹힌
  # 환경에서도 `git diff --raw` 가 그것을 실행했다. `include.path` 로 끌어온 파일에
  # 정의된 드라이버까지 봐야 하므로 열거는 `--local --includes` 여야 한다.
  ATTR_REPO="$RUN/attr-driver-repo"
  mkdir -p "$ATTR_REPO"
  ( cd "$ATTR_REPO" && git -c core.excludesFile=/dev/null init -q .       && printf 'hello\n' > f.txt && printf '* filter=pwn diff=pwn\n' > .gitattributes       && git add -A && git -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 ) || true
  ATTR_MARK="$RUN/attr-driver-ran"
  cat >"$RUN/attr-hook.sh" <<EOF
#!/usr/bin/env bash
touch "$ATTR_MARK"
exec cat
EOF
  chmod 755 "$RUN/attr-hook.sh"
  # include 경유 정의까지 섞는다 — `--local` 만으로는 이 축이 목록에서 빠진다.
  cat >"$ATTR_REPO/.git/extra-config" <<EOF
[diff "pwn2"]
	textconv = $RUN/attr-hook.sh
EOF
  cat >>"$ATTR_REPO/.git/config" <<EOF
[filter "pwn"]
	clean = $RUN/attr-hook.sh
[diff "pwn"]
	textconv = $RUN/attr-hook.sh
	command = $RUN/attr-hook.sh
[include]
	path = extra-config
EOF
  printf 'hello2\n' > "$ATTR_REPO/f.txt"
  if [ ! -f "$I16_BOOTSTRAP" ]; then
    skip "I16-4: bootstrap.py 를 찾지 못해 드라이버 무력화를 검사할 수 없습니다"
  else
    rm -f "$ATTR_MARK"
    PY - "$I16_BOOTSTRAP" "$ATTR_REPO" "$GLUE_STATE" <<'EOF'
import importlib.util, pathlib, shutil, subprocess, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["bs"] = mod
spec.loader.exec_module(mod)
git_path = shutil.which("git")
if git_path is None:
    raise SystemExit("I16-4: git 실행 파일을 찾지 못했습니다")
env = mod.probe_child_env(
    {}, pathlib.Path(sys.argv[2]), str(pathlib.Path(git_path).parent), pathlib.Path(sys.argv[3])
)
# 열거가 실제로 네 축(clean / textconv / command / include 경유)을 잡았는가.
n = int(env.get("GIT_CONFIG_COUNT", "0"))
keys = {env.get(f"GIT_CONFIG_KEY_{i}") for i in range(n)}
want = {"filter.pwn.clean", "diff.pwn.textconv", "diff.pwn.command", "diff.pwn2.textconv"}
if want - keys:
    raise SystemExit(f"I16-4: 무력화 목록에 드라이버 키가 빠졌습니다: {sorted(want - keys)}")
for i in range(n):
    if env.get(f"GIT_CONFIG_KEY_{i}") in want and env.get(f"GIT_CONFIG_VALUE_{i}") != "":
        raise SystemExit(f"I16-4: {env.get(f'GIT_CONFIG_KEY_{i}')} 가 빈 값이 아닙니다")
# 상류가 실제로 쓰는 형태로 돌려 본다(둘 다 rc=0 이어야 한다 — 픽스처 도달 확인).
for args in (["diff", "--raw"], ["diff", "--name-status", "-z", "--diff-filter=ACMRD", "HEAD"]):
    r = subprocess.run(["git", "-C", sys.argv[2], *args], capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise SystemExit(
            f"I16-4: git {' '.join(args)} 가 실행되지 않았습니다(rc={r.returncode}): "
            f"{r.stderr.strip()[:200]}"
        )
EOF
    expect_exit 0 "$?" "I16-4 드라이버 키가 열거·무력화되고 상류 명령이 정상 동작"
    if [ -e "$ATTR_MARK" ]; then
      bad "I16-4: .gitattributes 가 고른 filter/diff 드라이버가 실행됐습니다"
    else
      ok "I16-4: .gitattributes 경유 드라이버가 실행되지 않음"
    fi
    # 대조군: 무력화를 빼면 실제로 실행된다(= 이 픽스처가 위험을 행사한다).
    rm -f "$ATTR_MARK"
    PY - "$I16_BOOTSTRAP" "$ATTR_REPO" "$GLUE_STATE" <<'EOF'
import importlib.util, pathlib, shutil, subprocess, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["bs"] = mod
spec.loader.exec_module(mod)
git_path = shutil.which("git")
if git_path is None:
    raise SystemExit(0)
# 드라이버 열거만 뺀 환경(정적 9키는 그대로) — 이것이 수정 전 상태다.
env = mod.probe_child_env(
    {}, pathlib.Path(sys.argv[2]), str(pathlib.Path(git_path).parent), pathlib.Path(sys.argv[3])
)
statics = mod.git_config_overrides(pathlib.Path(sys.argv[2]))
env["GIT_CONFIG_COUNT"] = str(len(statics))
for i, (k, v) in enumerate(statics):
    env[f"GIT_CONFIG_KEY_{i}"] = k
    env[f"GIT_CONFIG_VALUE_{i}"] = v
for i in range(len(statics), 64):
    env.pop(f"GIT_CONFIG_KEY_{i}", None)
    env.pop(f"GIT_CONFIG_VALUE_{i}", None)
subprocess.run(["git", "-C", sys.argv[2], "diff", "--raw"], capture_output=True, env=env)
EOF
    if [ -e "$ATTR_MARK" ]; then
      ok "I16-4 대조군: 드라이버 열거를 빼면 실제로 실행됨 (픽스처가 위험을 행사한다)"
    else
      bad "I16-4 대조군: 드라이버 열거 없이도 실행되지 않았습니다 — 이 픽스처가 축에 도달하지 못했습니다"
    fi
  fi
  fi

  step "I15. complete 실패 페이로드의 failureKind"
  PY "$GLUE" --bootstrap "$RUN/boot-nosub.json" complete \
    --scan-id "00000000-0000-4000-8000-000000000000" \
    >"$RUN/i15.json" 2>"$RUN/i15.err"
  I15_KIND="$(PY -c 'import json,sys
try: print((json.load(open(sys.argv[1])) or {}).get("failureKind"))
except Exception: print("<파싱실패>")' "$RUN/i15.json")"
  if [ "$I15_KIND" = "infra" ]; then
    ok "I15: complete 의 상류 파손이 infra 로 실려 R6 분기가 가를 수 있다"
  else
    bad "I15: failureKind=$I15_KIND — R6 분기가 상류 파손을 워킹트리 게이트 실패로 단정합니다"
    sed 's/^/     /' "$RUN/i15.json" | head -6
  fi

  # I15b. **분류마다 다른 힌트**여야 한다. 한때 양쪽에 같은 문장을 실었고 그것을
  # 잡는 단언이 하나도 없었다(실측: 필드를 통째로 삭제해도 이 스크립트가 초록).
  # 문안은 SKILL.md R6 과 정합해야 한다 — infra 는 3선택지를 제시하지 않고
  # changedFiles 를 신뢰하지 않으며, gate 는 3선택지를 적용한다.
  I15B_GATE_JSON="$RUN/i15b-gate.json"
  I15B_PLUGIN="$RUN/i15b-plugin"
  rm -rf "$I15B_PLUGIN"
  mkdir -p "$I15B_PLUGIN/scripts" "$I15B_PLUGIN/.codex-plugin"
  printf '{"version":"0.0.0-i15b"}\n' >"$I15B_PLUGIN/.codex-plugin/plugin.json"
  printf 'raise SystemExit("target working tree changed since scan start")\n' \
    >"$I15B_PLUGIN/scripts/workbench_db.py"
  PY - "$RUN/boot-i15b.json" "$I15B_PLUGIN" "$GLUE_STATE" "$SRC" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": "0.0.0-i15b",
    "stateDir": state, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  PY "$GLUE" --bootstrap "$RUN/boot-i15b.json" complete \
    --scan-id "00000000-0000-4000-8000-000000000000" \
    >"$I15B_GATE_JSON" 2>"$RUN/i15b.err"
  PY - "$RUN/i15.json" "$I15B_GATE_JSON" <<'EOF'
import json, pathlib, sys
problems = []
docs = []
for path in sys.argv[1:3]:
    try:
        docs.append(json.loads(pathlib.Path(path).read_text()) or {})
    except Exception as error:
        problems.append(f"{path} 파싱 실패: {error}")
        docs.append({})
infra, gate = docs
if infra.get("failureKind") != "infra":
    problems.append(f"첫 페이로드가 infra 가 아닙니다: {infra.get('failureKind')!r} — 픽스처 미도달")
if gate.get("failureKind") != "gate":
    problems.append(f"둘째 페이로드가 gate 가 아닙니다: {gate.get('failureKind')!r} — 픽스처 미도달")
hi, hg = infra.get("hint") or "", gate.get("hint") or ""
if not hi or not hg:
    problems.append("hint 필드가 없습니다 — R6 분기 안내가 사라졌습니다")
elif hi == hg:
    problems.append("두 분류의 hint 가 동일합니다 — 프로세스 기동 실패에 '변경을 되돌리세요'가 붙습니다")
else:
    # infra 안내: 3선택지를 제시하지 말고 changedFiles 를 믿지 말라고 해야 한다.
    if "3선택지를 제시하지" not in hi:
        problems.append(f"infra hint 가 3선택지 금지를 말하지 않습니다: {hi!r}")
    if "changedFiles" not in hi:
        problems.append(f"infra hint 가 changedFiles 불신을 말하지 않습니다: {hi!r}")
    # gate 안내: 3선택지를 적용하라고 해야 한다.
    if "3선택지" not in hg or "재시도" not in hg:
        problems.append(f"gate hint 가 3선택지를 안내하지 않습니다: {hg!r}")
for p in problems:
    print(f"FAIL I15b: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "I15b 분류별 힌트가 R6 과 정합"

  step "I14. 개행 담긴 repoRoot 는 gate 로 선차단"
  NL_DIR="$RUN/nl-repo"
  mkdir -p "$NL_DIR"
  PY - "$RUN/boot-newline.json" "$PLUGIN" "$GLUE_STATE" "$NL_DIR" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": "probe",
    "stateDir": state, "repoRoot": repo + "/nl\ndir",
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  PY "$GLUE" --bootstrap "$RUN/boot-newline.json" recover \
    --scan-id "00000000-0000-4000-8000-000000000000" \
    >"$RUN/i14.json" 2>"$RUN/i14.err"
  I14_RC=$?
  I14_KIND="$(PY -c 'import json,sys
try: print((json.load(open(sys.argv[1])) or {}).get("failureKind"))
except Exception: print("<파싱실패>")' "$RUN/i14.json")"
  # `gate` 만 보면 없는 scanId 의 정상 거부와 구분되지 않는다 — 픽스처에서 개행을
  # 지워도 초록이었다(실측). 게이트 고유 문구와 상류 미호출을 함께 본다.
  if [ "$I14_KIND" = "gate" ] \
     && grep -q "개행·NUL 이 있습니다" "$RUN/i14.json" 2>/dev/null \
     && ! grep -q "recover-scan-results" "$RUN/i14.json" 2>/dev/null; then
    ok "I14: 개행 경로가 상류 호출 전에 gate 로 차단됨"
  else
    bad "I14: 선차단되지 않았습니다 (kind=$I14_KIND) — 개행이 상류로 넘어가면 사유 추출이 절단됩니다"
    sed 's/^/     /' "$RUN/i14.json" | head -4
  fi
  # 대조군: 개행이 없으면 이 게이트가 발동하지 않아야 한다(무조건 켜지지 않음).
  PY - "$RUN/boot-clean.json" "$PLUGIN" "$GLUE_STATE" "$NL_DIR" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": "probe",
    "stateDir": state, "repoRoot": repo + "/nldir",
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  PY "$GLUE" --bootstrap "$RUN/boot-clean.json" recover \
    --scan-id "00000000-0000-4000-8000-000000000000" \
    >"$RUN/i14b.json" 2>"$RUN/i14b.err"
  if grep -q "개행·NUL 이 있습니다" "$RUN/i14b.json" 2>/dev/null; then
    bad "I14b 대조군: 개행이 없는데 게이트가 발동했습니다 (I14 가 무조건 켜집니다)"
  else
    ok "I14b 대조군: 개행이 없으면 게이트가 발동하지 않음"
  fi

  # I14c: 분류가 **메시지 문자**에 흔들리지 않는지.
  #
  # `splitlines()` 로 줄수를 세면 `\x0b \x0c \x1c \x1d \x1e \x85 U+2028 U+2029`
  # 에서도 쪼개진다. 상류는 거부 메시지에 경로를 보간하므로(workbench_db.py:270)
  # 그런 문자가 든 경로면 정상 거부가 여러 줄로 세어져 infra 로 뒤집힌다(8문자 확인).
  # 진입 시점에 문자를 막는 게이트로는 필연적으로 불완전하다 — 분류가 실제 개행만
  # 봐야 한다.
  #
  # 이 축은 `recover` 로 행사되지 않는다("scan not found" 에는 경로가 없다).
  # 합성 플러그인이 그 문자를 담은 **정상 거부 형상**을 직접 내게 해 분류만 겨냥한다.
  #
  # **`gate` 만 보면 안 된다** — 평범한 문자로 마커를 바꿔도, 심지어 합성 플러그인이
  # 한 번도 실행되지 않아도 gate 다(실측: 둘 다 초록이었다). 픽스처가 축에 실제로
  # 도달했음을 함께 단언한다: detail 에 그 문자가 실렸고, `splitlines()` 로는 여러
  # 줄로 세어지는가(= 수정 전 규칙이라면 infra 였는가).
  I14C_BAD=""
  for marker in '\x0b' '\x0c' '\x1c' '\x1d' '\x1e' '\x85' '\u2028' '\u2029'; do
    I14C_PLUGIN="$RUN/splitchar-plugin"
    rm -rf "$I14C_PLUGIN"
    mkdir -p "$I14C_PLUGIN/scripts" "$I14C_PLUGIN/.codex-plugin"
    printf '{"version":"0.0.0-splitchar"}\n' >"$I14C_PLUGIN/.codex-plugin/plugin.json"
    printf 'raise SystemExit("not a readable local directory: /tmp/a%sb")\n' "$marker" \
      >"$I14C_PLUGIN/scripts/workbench_db.py"
    PY - "$RUN/boot-splitchar.json" "$I14C_PLUGIN" "$GLUE_STATE" "$SRC" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": "0.0.0-splitchar",
    "stateDir": state, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
    PY "$GLUE" --bootstrap "$RUN/boot-splitchar.json" recover \
      --scan-id "00000000-0000-4000-8000-000000000000" \
      >"$RUN/i14c.json" 2>"$RUN/i14c.err"
    k="$(PY -c 'import json,sys
try: print((json.load(open(sys.argv[1])) or {}).get("failureKind"))
except Exception: print("<파싱실패>")' "$RUN/i14c.json")"
    [ "$k" = "gate" ] || I14C_BAD="$I14C_BAD ${marker}=$k"
    # 픽스처 도달 확인 — detail 이 그 문자를 담고 splitlines 로는 다중행인가.
    PY - "$RUN/i14c.json" <<'EOF' || I14C_BAD="$I14C_BAD ${marker}=축미도달"
import json, pathlib, sys
try:
    d = json.loads(pathlib.Path(sys.argv[1]).read_text()) or {}
except Exception:
    raise SystemExit(1)
detail = d.get("detail") or ""
reason = d.get("reason") or ""
# 상류 거부 메시지가 실려 있고(합성 플러그인이 실행됐다),
if "not a readable local directory" not in detail:
    raise SystemExit(1)
# splitlines 로는 다중행이며(= 이 문자가 실제로 분할문자다),
if len(detail.splitlines()) < 2:
    raise SystemExit(1)
# reason 이 절단되지 않았다(_split_lines 가 실제 개행만 본다).
if "not a readable local directory" not in reason:
    raise SystemExit(1)
raise SystemExit(0)
EOF
  done
  if [ -z "$I14C_BAD" ]; then
    ok "I14c: splitlines 가 쪼개는 문자가 든 정상 거부도 gate 로 유지됨"
  else
    bad "I14c: 메시지 문자로 정상 거부가 뒤집힙니다 (분류가 splitlines 를 씁니다):$I14C_BAD"
  fi

  # I14d 대조군: **실제 개행**이 든 다중행 stderr 는 여전히 infra 여야 한다.
  #              I14c 가 규칙을 통째로 무력화하지 않았음을 보장한다.
  I14D_PLUGIN="$RUN/realnl-plugin"
  mkdir -p "$I14D_PLUGIN/scripts" "$I14D_PLUGIN/.codex-plugin"
  printf '{"version":"0.0.0-realnl"}\n' >"$I14D_PLUGIN/.codex-plugin/plugin.json"
  printf 'import sys\nsys.stderr.write("line1\\nline2\\n")\nsys.exit(1)\n' \
    >"$I14D_PLUGIN/scripts/workbench_db.py"
  PY - "$RUN/boot-realnl.json" "$I14D_PLUGIN" "$GLUE_STATE" "$SRC" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": "0.0.0-realnl",
    "stateDir": state, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  PY "$GLUE" --bootstrap "$RUN/boot-realnl.json" recover \
    --scan-id "00000000-0000-4000-8000-000000000000" \
    >"$RUN/i14d.json" 2>"$RUN/i14d.err"
  I14D_KIND="$(PY -c 'import json,sys
try: print((json.load(open(sys.argv[1])) or {}).get("failureKind"))
except Exception: print("<파싱실패>")' "$RUN/i14d.json")"
  if [ "$I14D_KIND" = "infra" ]; then
    ok "I14d 대조군: 실제 개행 다중행은 여전히 infra"
  else
    bad "I14d 대조군: 다중행 stderr 가 $I14D_KIND — 다줄 인프라 형상을 놓칩니다"
  fi

  step "I13. errno 문구를 담은 정상 거부는 gate"
  ERRNO_PLUGIN="$RUN/errno-plugin"
  mkdir -p "$ERRNO_PLUGIN/scripts" "$ERRNO_PLUGIN/.codex-plugin"
  printf '{"version":"0.0.0-errno"}\n' >"$ERRNO_PLUGIN/.codex-plugin/plugin.json"
  cat >"$ERRNO_PLUGIN/scripts/workbench_db.py" <<'EOF'
raise SystemExit(
    "scan-manifest.json: invalid JSON: [Errno 13] Permission denied: '/x/scan-manifest.json'"
)
EOF
  PY - "$RUN/boot-errno.json" "$ERRNO_PLUGIN" "$GLUE_STATE" "$SRC" "$PYTHON_BIN" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python = sys.argv[1:6]
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": "0.0.0-errno",
    "stateDir": state, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  PY "$GLUE" --bootstrap "$RUN/boot-errno.json" recover \
    --scan-id "00000000-0000-4000-8000-000000000000" \
    >"$RUN/i13.json" 2>"$RUN/i13.err"
  expect_exit 0 "$?" "I13a errno 거부도 exit 0"
  I13_KIND="$(PY -c 'import json,sys
try: print((json.load(open(sys.argv[1])) or {}).get("failureKind"))
except Exception: print("<파싱실패>")' "$RUN/i13.json")"
  if [ "$I13_KIND" = "gate" ]; then
    ok "I13b: errno 문구를 담은 정상 거부가 gate 로 유지됨 (마커 과잉이 없음)"
  else
    bad "I13b: failureKind=$I13_KIND — 정상 거부를 infra 로 오분류하면 사용자를 플러그인 점검으로 보냅니다"
    sed 's/^/     /' "$RUN/i13.json"
  fi

  step "I10. 대조군 — 진짜 게이트 거부는 여전히 gate"
  # I7b 가 이미 failureKind=gate 를 단언했으므로 그것만 다시 읽으면 독립 신호가
  # 없다. kind 와 **안내 문구의 짝**을 본다 — "kind 는 gate 인데 안내는 infra 문구"
  # 라는 조합 회귀는 I7b 가 잡지 못한다.
  PY - "$RUN/i7.json" <<'EOF'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
hint = d.get("hint") or ""
problems = []
if d.get("failureKind") != "gate":
    problems.append(f"failureKind={d.get('failureKind')!r} (gate 기대)")
if "status=failed" not in hint:
    problems.append(f"게이트 분류인데 안내가 게이트 문구가 아닙니다: {hint[:100]!r}")
for p in problems:
    print(f"FAIL I10: {p}")
raise SystemExit(1 if problems else 0)
EOF
  expect_exit 0 "$?" "I10 게이트 분류와 안내 문구의 짝"
fi

# ---------------------------------------------------------------------------
# I17. diff 스캔의 워크벤치 등록·종결 (glue register --mode diff).
#
# 회귀 이력: 글루가 diff 를 레시피 mode 로 보냈는데 상류는 mode 로
# standard·deep 만 받는다(상류 최초 태그부터, "Scan launch recipe mode must be standard or deep.").
# 그래서 diff 스캔은 이력 등록이 항상 실패했다. diff 는 target.kind(refs/working_tree)로
# 보내야 한다. contract 의 diffTarget.snapshotDigest 는 상류 식과 같아야 한다 —
# npm 0.1.32(상류 8c78e655)부터 워크벤치가 커밋 diff digest 를 종결 시점에 직접 계산한다.
# ---------------------------------------------------------------------------
step "I17. diff 스캔 등록·종결 (refs·working_tree)"
if [ -z "$PLUGIN" ] || [ ! -f "$PLUGIN/scripts/workbench_db.py" ]; then
  skip "I17: 플러그인을 찾지 못해 diff 스캔 등록·종결을 검증할 수 없습니다"
elif ! command -v git >/dev/null 2>&1; then
  skip "I17: git 을 쓸 수 없어 diff 스캔 등록·종결을 검증할 수 없습니다"
else
  DREPO="$RUN/diff-repo"
  DGIT_HOME="$RUN/diff-git-home"
  mkdir -p "$DREPO" "$DGIT_HOME"
  # 사용자 전역·시스템 git 설정(commit.gpgsign, core.hooksPath 등)이 픽스처를 흔들지 않게 한다.
  dgit() { HOME="$DGIT_HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -C "$DREPO" -c user.email=u7@example.com -c user.name=u7 -c commit.gpgsign=false "$@"; }
  I17_FIXTURE=ok
  {
    dgit -c init.defaultBranch=main init -q . &&
      printf 'print(1)\n' >"$DREPO/a.py" && dgit add -A && dgit commit -qm one &&
      printf 'print(2)\n' >"$DREPO/b.py" && dgit add -A && dgit commit -qm two
  } >"$RUN/i17-fixture.log" 2>&1 || I17_FIXTURE=failed
  DBASE="$(dgit rev-parse HEAD~1 2>/dev/null)"
  if [ "$I17_FIXTURE" != ok ] || [ -z "$DBASE" ]; then
    bad "I17: 픽스처 git 저장소를 만들지 못했습니다(아래 로그)"
    sed 's/^/     /' "$RUN/i17-fixture.log"
  fi
  # contract 출력만으로 git_diff 미봉인 초안 3종을 쓴다. omit-digest 면 snapshotDigest 를 뺀다.
  cat >"$RUN/diff_draft.py" <<'EOF'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

scan_dir = Path(sys.argv[1])
c = json.loads(Path(sys.argv[2]).read_text())["contract"]
omit_digest = len(sys.argv) > 3 and sys.argv[3] == "omit-digest"
d = c["diffTarget"]
target = {
    "kind": c["target"]["allowedKinds"][0],
    "targetId": c["target"]["targetId"],
    "displayName": c["target"]["displayName"],
    "baseRevision": d["baseRevision"],
    "headRevision": d["headRevision"],
}
if not omit_digest:
    target["snapshotDigest"] = d["snapshotDigest"]
mode = {"commit": "commit", "range": "branch_diff", "working_tree": "working_tree"}[d["kind"]]
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
scope = {"includePaths": ["."], "excludePaths": c["scope"]["requiredExcludePaths"] or []}
documents = {
    "scan-manifest.json": {"documentType": "codex-security.scan-manifest", "schemaVersion": "1.0",
        "scan": {"id": c["scanId"], "status": "completed", "startedAt": now, "completedAt": now,
                 "producer": c["producer"], "target": target, "scope": scope,
                 "findingsRef": "findings.json", "coverageRef": "coverage.json"}},
    "findings.json": {"documentType": "codex-security.findings", "schemaVersion": "1.0",
                      "scanId": c["scanId"], "findings": []},
    "coverage.json": {"documentType": "codex-security.coverage", "schemaVersion": "1.0",
        "scanId": c["scanId"], "mode": mode, "completeness": "complete",
        "inventoryStrategy": "repository", **scope, "explicitExclusions": [], "deferred": [],
        "surfaces": [{"id": "surface_changed_files", "label": "Changed files",
                      "disposition": "no_issue_found", "receiptRefs": []}]},
}
for name, payload in documents.items():
    (scan_dir / name).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
EOF
  # diff_case <라벨> <seal|unsealed|unsealed-omit> <glue register 인자…>
  # 등록 → contract → 초안 → (seal 이면 finalize) → complete. 결과 JSON 은 $RUN/<라벨>.*.json.
  diff_case() {
    local label="$1" seal="$2"; shift 2
    local dir="$RUN/$label"
    local scan_dir="$dir/scan" state="$dir/state"
    mkdir -p "$scan_dir" "$state"
    chmod 700 "$dir" "$scan_dir" "$state"
    PY - "$dir/boot.json" "$PLUGIN" "$state" "$DREPO" "$PYTHON_BIN" "$scan_dir" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python, scan_dir = sys.argv[1:7]
manifest = json.loads((pathlib.Path(plugin) / ".codex-plugin" / "plugin.json").read_text())
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": manifest["version"],
    "stateDir": state, "scanDir": scan_dir, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
    PY "$GLUE" --bootstrap "$dir/boot.json" register "$@" >"$dir/register.json" 2>"$dir/register.err" || return 1
    local sid
    sid="$(PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["scanId"])' "$dir/register.json")" || return 1
    PY "$GLUE" --bootstrap "$dir/boot.json" contract --scan-id "$sid" >"$dir/contract.json" 2>"$dir/contract.err" || return 1
    case "$seal" in
      unsealed-omit) PY "$RUN/diff_draft.py" "$scan_dir" "$dir/contract.json" omit-digest || return 1 ;;
      *) PY "$RUN/diff_draft.py" "$scan_dir" "$dir/contract.json" || return 1 ;;
    esac
    if [ "$seal" = seal ]; then
      PY -I -B "$PLUGIN/scripts/finalize_scan_contract.py" --scan-dir "$scan_dir" --source-root "$DREPO" \
        >"$dir/finalize.out" 2>"$dir/finalize.err" || return 1
    fi
    PY "$GLUE" --bootstrap "$dir/boot.json" complete --scan-id "$sid" >"$dir/complete.json" 2>"$dir/complete.err" || return 1
  }
  # check_case <라벨> <기대 contract kind> <digest 기대: formula|content>
  check_case() {
    PY - "$RUN/$1" "$2" "$3" <<'EOF'
import hashlib, json, pathlib, sys
d, kind, expect = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
problems = []
contract = json.loads((d / "contract.json").read_text())["contract"]
diff = contract.get("diffTarget") or {}
if contract.get("mode") != "diff":
    problems.append(f"contract.mode={contract.get('mode')!r} (diff 기대)")
if diff.get("kind") != kind:
    problems.append(f"diffTarget.kind={diff.get('kind')!r} ({kind} 기대)")
if expect == "formula":
    digest = hashlib.sha256(
        f"codex-security-diff/v1\0{kind}\0{diff.get('baseRevision')}\0{diff.get('headRevision')}".encode()
    ).hexdigest()
    wanted = f"codex-security-snapshot/v1:sha256:{digest}"
else:
    raw = json.loads((d / "contract.json").read_text())["raw"]
    wanted = (raw.get("scan") or raw)["contract"]["diffTarget"].get("contentDigest")
if not wanted or diff.get("snapshotDigest") != wanted:
    problems.append(f"diffTarget.snapshotDigest={diff.get('snapshotDigest')!r} (기대 {wanted!r})")
complete = json.loads((d / "complete.json").read_text())
if complete.get("ok") is not True or complete.get("status") != "complete":
    problems.append(f"complete 결과가 성공이 아닙니다: {json.dumps(complete)[:300]}")
target = json.loads((d / "scan" / "scan-manifest.json").read_text())["scan"]["target"]
if target.get("kind") != "git_diff" or target.get("snapshotDigest") != wanted:
    problems.append(f"봉인 매니페스트 target 이 기대와 다릅니다: {target}")
for p in problems:
    print(f"FAIL {d.name}: {p}")
raise SystemExit(1 if problems else 0)
EOF
  }

  if diff_case i17-refs seal --mode diff --diff-target refs --base "$DBASE"; then
    check_case i17-refs range formula
    expect_exit 0 "$?" "I17a refs diff 등록·봉인·종결 + 손으로 쓴 식과 같은 digest(상류 대조는 I17c)"
  else
    bad "I17a: refs diff 수명주기가 중간에 실패했습니다"
    cat "$RUN/i17-refs"/*.err "$RUN/i17-refs"/*.json 2>/dev/null | sed 's/^/     /' | head -20; echo
  fi

  printf 'print(3)\n' >>"$DREPO/b.py"
  if diff_case i17-worktree seal --mode diff --diff-target working_tree --base HEAD; then
    check_case i17-worktree working_tree content
    expect_exit 0 "$?" "I17b working_tree diff 등록·봉인·종결 + contentDigest"
  else
    bad "I17b: working_tree diff 수명주기가 중간에 실패했습니다"
    cat "$RUN/i17-worktree"/*.err "$RUN/i17-worktree"/*.json 2>/dev/null | sed 's/^/     /' | head -20; echo
  fi
  dgit checkout -q -- b.py

  # 상류 식 대조: snapshotDigest 를 뺀 미봉인 초안을 넘기면 워크벤치가 종결 시점에 값을 채운다
  # (npm 0.1.32부터). 그 값이 glue 가 계산한 값과 같아야 한다. 그 전 사본은 채우지 않으므로 대상이 아니다.
  if grep -q "def committed_diff_snapshot_digest" "$PLUGIN/scripts/workbench_target.py" 2>/dev/null; then
    if diff_case i17-parity unsealed-omit --mode diff --diff-target refs --base "$DBASE"; then
      check_case i17-parity range formula
      expect_exit 0 "$?" "I17c 상류가 채운 커밋 diff digest == glue 계산값"
    else
      bad "I17c: 미봉인 refs diff 종결이 실패했습니다"
      cat "$RUN/i17-parity"/*.err "$RUN/i17-parity"/*.json 2>/dev/null | sed 's/^/     /' | head -20; echo
    fi
  else
    printf 'NOTE I17c: 이 플러그인 사본은 npm 0.1.32 이전이라 종결 시점 digest 계산이 없습니다(검사 대상 아님)\n'
  fi

  # 대조군: 예전 글루처럼 레시피 mode 에 diff 를 실으면 상류가 거부한다(상류 최초 태그부터).
  # 상류가 나중에 mode=diff 를 받기 시작하면 이 단언이 알려 준다.
  I17E_DIR="$RUN/i17-mode-diff"
  mkdir -p "$I17E_DIR"
  chmod 700 "$I17E_DIR"
  PY -c 'import json,sys; print(json.dumps({"repository": sys.argv[1], "mode": "diff", "config": {}, "target": {"kind": "repository", "paths": []}}))' "$DREPO" >"$RUN/i17e.recipe"
  CODEX_SECURITY_STATE_DIR="$RUN/i17-refs/state" PY -I -B "$PLUGIN/scripts/workbench_db.py" register-cli-scan \
    --scan-dir "$I17E_DIR" --repository "$DREPO" --recipe-json "$(cat "$RUN/i17e.recipe")" \
    >"$RUN/i17e.out" 2>&1
  I17E_CODE=$?
  if [ "$I17E_CODE" != 0 ] && grep -q "Scan launch recipe mode must be standard or deep" "$RUN/i17e.out"; then
    ok "I17e: 레시피 mode=diff 는 상류가 거부(글루가 target.kind 로 보내야 하는 이유)"
  else
    bad "I17e: 레시피 mode=diff 거부가 기대와 다릅니다(exit $I17E_CODE) — 상류 계약이 바뀌었을 수 있습니다"
    sed 's/^/     /' "$RUN/i17e.out" | head -10
  fi

  # 인자 오류는 상류를 부르기 전에 글루가 끊는다.
  PY "$GLUE" --bootstrap "$RUN/i17-refs/boot.json" register --mode diff >"$RUN/i17-usage.json" 2>&1
  I17D_CODE=$?
  if [ "$I17D_CODE" = 1 ] && grep -q -- "--diff-target" "$RUN/i17-usage.json"; then
    ok "I17d: --diff-target 없는 --mode diff 는 글루가 거부"
  else
    bad "I17d: --mode diff 인자 누락 거부가 기대와 다릅니다(exit $I17D_CODE)"
    sed 's/^/     /' "$RUN/i17-usage.json"
  fi
  PY "$GLUE" --bootstrap "$RUN/i17-refs/boot.json" register --mode standard --head HEAD >"$RUN/i17-usage2.json" 2>&1
  I17F_CODE=$?
  if [ "$I17F_CODE" = 1 ] && grep -q -- "--mode diff 에서만" "$RUN/i17-usage2.json"; then
    ok "I17f: diff 전용 인자(--head)를 다른 모드에 주면 글루가 거부"
  else
    bad "I17f: 비-diff 모드의 --head 거부가 기대와 다릅니다(exit $I17F_CODE)"
    sed 's/^/     /' "$RUN/i17-usage2.json"
  fi

  # I17g. deep-lite 는 표준 모드로 등록한다. 상류는 레시피 mode=deep 스캔을 종결하기 전에 공식 deep
  # 코디네이터가 만드는 deep_scan_runs 행(succeeded + manifest)을 요구한다(deep_scan_workbench.py,
  # npm 0.1.29~0.2.0). deep-lite 는 그 행을 만들지 않으므로 mode=deep 으로 등록하면 complete 가 항상
  # 거부되고 행은 running 으로 남는다(2026-10-14 스모크 테스트 실측). 글루는 그 등록을 상태 DB 에
  # 행을 만들기 전에 거부한다.
  I17G="$RUN/i17-deep"
  mkdir -p "$I17G/scan" "$I17G/state"
  chmod 700 "$I17G" "$I17G/scan" "$I17G/state"
  PY - "$I17G/boot.json" "$PLUGIN" "$I17G/state" "$DREPO" "$PYTHON_BIN" "$I17G/scan" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python, scan_dir = sys.argv[1:7]
manifest = json.loads((pathlib.Path(plugin) / ".codex-plugin" / "plugin.json").read_text())
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": manifest["version"],
    "stateDir": state, "scanDir": scan_dir, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  i17g_running() { PY "$GLUE" --bootstrap "$I17G/boot.json" check-running 2>/dev/null | PY -c 'import json,sys; print(json.load(sys.stdin).get("count"))'; }
  I17G_BEFORE="$(i17g_running)"
  PY "$GLUE" --bootstrap "$I17G/boot.json" register --mode deep >"$RUN/i17-deep.json" 2>&1
  I17G_CODE=$?
  I17G_AFTER="$(i17g_running)"
  if [ "$I17G_CODE" = 1 ] && grep -q "deep-lite" "$RUN/i17-deep.json" && [ "$I17G_BEFORE" = 0 ] && [ "$I17G_AFTER" = 0 ]; then
    ok "I17g: register --mode deep 은 글루가 상태 DB 에 행을 만들기 전에 거부(running 행 0 그대로)"
  else
    bad "I17g: --mode deep 거부가 기대와 다릅니다(exit $I17G_CODE, running $I17G_BEFORE -> $I17G_AFTER)"
    sed 's/^/     /' "$RUN/i17-deep.json"
  fi

  # I17h. scoped-path 스캔 등록·종결. 상류 parse_scan_recipe 는 target.kind 가 "paths" 가 아닌
  # 레시피의 경로를 거부한다("Only scoped scan launch recipes can include target paths.",
  # npm 0.2.0~0.4.0). 글루가 kind=repository 로 경로를 보내던 동안 `register --paths` 는 항상
  # exit 1 이었다(2026-10-17 0.4.0 스모크 테스트). 등록 → contract → bind-repo-scopes(사본의 경로)
  # → finalize → complete 를 끝까지 돌린다.
  mkdir -p "$DREPO/app"
  printf 'print(4)\n' >"$DREPO/app/c.py"
  { dgit add -A && dgit commit -qm scoped; } >"$RUN/i17h-fixture.log" 2>&1 \
    || { bad "I17h: 픽스처 커밋 실패"; sed 's/^/     /' "$RUN/i17h-fixture.log"; }
  I17H="$RUN/i17-scoped"
  mkdir -p "$I17H/scan" "$I17H/state"
  chmod 700 "$I17H" "$I17H/scan" "$I17H/state"
  PY - "$I17H/boot.json" "$PLUGIN" "$I17H/state" "$DREPO" "$PYTHON_BIN" "$I17H/scan" <<'EOF'
import json, pathlib, sys
out, plugin, state, repo, python, scan_dir = sys.argv[1:7]
manifest = json.loads((pathlib.Path(plugin) / ".codex-plugin" / "plugin.json").read_text())
pathlib.Path(out).write_text(json.dumps({
    "ok": True, "pluginRoot": plugin, "pluginVersion": manifest["version"],
    "stateDir": state, "scanDir": scan_dir, "repoRoot": repo,
    "python": {"path": python, "version": "probe"},
}, indent=2))
EOF
  # bind-repo-scopes 실행 경로: Python 하위 명령이 있으면 그것, 없으면 Node 헬퍼(npm 0.4.0).
  i17h_bind() {
    if grep -q '"bind-repo-scopes"' "$PLUGIN/scripts/generate_rank_input.py" 2>/dev/null; then
      PY -I -B "$PLUGIN/scripts/generate_rank_input.py" bind-repo-scopes "$@"
    else
      env -i PATH=/usr/bin:/bin HOME="$HOME" CODEX_MCP_NODE_PATH="$(command -v node)" \
        "$PLUGIN/scripts/launch_codex_security_mcp" --helper bind-repo-scopes "$@"
    fi
  }
  i17h_run() {
    PY "$GLUE" --bootstrap "$I17H/boot.json" register --paths app \
      >"$I17H/register.json" 2>"$I17H/register.err" || return 1
    local sid
    sid="$(PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["scanId"])' "$I17H/register.json")" || return 1
    PY "$GLUE" --bootstrap "$I17H/boot.json" contract --scan-id "$sid" \
      >"$I17H/contract.json" 2>"$I17H/contract.err" || return 1
    PY - "$I17H/scan" "$I17H/contract.json" <<'EOF' || return 1
import json, sys
from datetime import datetime, timezone
from pathlib import Path

scan_dir = Path(sys.argv[1])
c = json.loads(Path(sys.argv[2]).read_text())["contract"]
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
target = {"kind": c["target"]["allowedKinds"][0], "targetId": c["target"]["targetId"],
          "displayName": c["target"]["displayName"], "revision": c["target"]["revision"]}
# includePaths 는 bind-repo-scopes 가 채운다. 일부러 "." 로 두어 바인딩이 실제로 일어났는지 본다.
scope = {"includePaths": ["."], "excludePaths": c["scope"]["requiredExcludePaths"] or []}
documents = {
    "scan-manifest.json": {"documentType": "codex-security.scan-manifest", "schemaVersion": "1.0",
        "scan": {"id": c["scanId"], "status": "completed", "startedAt": now, "completedAt": now,
                 "producer": c["producer"], "target": target, "scope": scope,
                 "findingsRef": "findings.json", "coverageRef": "coverage.json"}},
    "findings.json": {"documentType": "codex-security.findings", "schemaVersion": "1.0",
                      "scanId": c["scanId"], "findings": []},
    "coverage.json": {"documentType": "codex-security.coverage", "schemaVersion": "1.0",
        "scanId": c["scanId"], "mode": "scoped_path", "completeness": "complete",
        "inventoryStrategy": "scoped_path", **scope, "explicitExclusions": [], "deferred": [],
        "surfaces": [{"id": "surface_app", "label": "App sources",
                      "disposition": "no_issue_found", "receiptRefs": []}]},
}
for name, payload in documents.items():
    (scan_dir / name).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
EOF
    printf '["app"]\n' >"$I17H/scopes.json"
    # npm 0.8.0 헬퍼는 --coverage 를 받지 않는다(상류 621bad47e #1762, 같은 커밋이
    # scripts/review_state.py 를 더함). 그때 스킬은 같은 배열을 coverage.json 에 직접 쓴다
    # (부트스트랩 bindRepoScopes.coverageArg=false 분기, 스캔 스킬 6단계 1번).
    if [ -f "$PLUGIN/scripts/review_state.py" ]; then
      i17h_bind --scopes-file "$I17H/scopes.json" --manifest "$I17H/scan/scan-manifest.json" \
        >"$I17H/bind.out" 2>"$I17H/bind.err" || return 1
      PY - "$I17H/scan/coverage.json" "$I17H/scopes.json" <<'EOF' || return 1
import json, sys
from pathlib import Path
coverage = Path(sys.argv[1])
payload = json.loads(coverage.read_text())
payload["includePaths"] = json.loads(Path(sys.argv[2]).read_text())
coverage.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
EOF
    else
      i17h_bind --scopes-file "$I17H/scopes.json" --manifest "$I17H/scan/scan-manifest.json" \
        --coverage "$I17H/scan/coverage.json" >"$I17H/bind.out" 2>"$I17H/bind.err" || return 1
    fi
    PY -I -B "$PLUGIN/scripts/finalize_scan_contract.py" --scan-dir "$I17H/scan" --source-root "$DREPO" \
      >"$I17H/finalize.out" 2>"$I17H/finalize.err" || return 1
    PY "$GLUE" --bootstrap "$I17H/boot.json" complete --scan-id "$sid" \
      >"$I17H/complete.json" 2>"$I17H/complete.err" || return 1
  }
  if i17h_run; then
    PY - "$I17H" <<'EOF'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
problems = []
contract = json.loads((d / "contract.json").read_text())["contract"]
if contract["scope"].get("requiredIncludePaths") != ["app"]:
    problems.append(f"contract.scope.requiredIncludePaths={contract['scope'].get('requiredIncludePaths')!r} (['app'] 기대)")
complete = json.loads((d / "complete.json").read_text())
if complete.get("ok") is not True or complete.get("status") != "complete":
    problems.append(f"complete 결과가 성공이 아닙니다: {json.dumps(complete)[:300]}")
scope = json.loads((d / "scan" / "scan-manifest.json").read_text())["scan"]["scope"]
if scope.get("includePaths") != ["app"]:
    problems.append(f"봉인 매니페스트 includePaths={scope.get('includePaths')!r} (['app'] 기대)")
for p in problems:
    print(f"FAIL I17h: {p}")
raise SystemExit(1 if problems else 0)
EOF
    expect_exit 0 "$?" "I17h scoped-path(--paths app) 등록·바인딩·봉인·종결"
  else
    bad "I17h: scoped-path 수명주기가 중간에 실패했습니다(--paths 가 kind=paths 레시피로 가지 않으면 register 가 거부됩니다)"
    cat "$I17H"/*.err "$I17H"/register.json 2>/dev/null | sed 's/^/     /' | head -10; echo
  fi
fi

# ---------------------------------------------------------------------------
# I18. 글루 자식 환경은 상속된 CODEX_SECURITY_GIT 을 넘기지 않는다.
#     npm 0.1.32부터 플러그인 스크립트는 이 값이 있으면 그 Git 을 쓴다. 상류 SDK 는
#     사용자 값을 자기가 고른 Git 으로 덮어쓰므로, 우리도 상속값을 쓰지 않는다.
# ---------------------------------------------------------------------------
step "I18. 글루 자식 환경의 CODEX_SECURITY_GIT 제거"
CODEX_SECURITY_GIT=/nonexistent/git PY - "$GLUE" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("workbench_glue", sys.argv[1])
glue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(glue)
env = glue.child_env("/tmp/state")
raise SystemExit(1 if any(k.upper() == "CODEX_SECURITY_GIT" for k in env) else 0)
EOF
expect_exit 0 "$?" "I18 상속된 CODEX_SECURITY_GIT 제거"

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
