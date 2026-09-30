#!/usr/bin/env bash
# U4 재현 스크립트: 최소 unsealed draft 픽스처가 finalize + validate를 통과하는지 검증한다.
# 사용법: bash repro-u4.sh
set -u -o pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# cd 실패로 WORK가 비면 아래 rm -rf 가 루트 수준 경로를 지운다. set -u 는
# set-but-empty 에 발동하지 않으므로 명시적으로 가드한다.
: "${WORK:?WORK 경로 해석 실패 — 중단}"
# 플러그인 경로: 환경변수 → 이 저장소 체크아웃(스크립트 위치 기준) → npm 전역 설치본.
PLUGIN="${CODEX_SECURITY_PLUGIN_DIR:-}"
if [ -z "$PLUGIN" ]; then
  # 상류 체크아웃 레이아웃: 현재는 plugins/codex-security, 과거는 sdk/typescript/_bundled_plugin.
  if [ -f "$WORK/../../../plugins/codex-security/.codex-plugin/plugin.json" ]; then
    PLUGIN="$(cd "$WORK/../../../plugins/codex-security" && pwd -P)"
  elif [ -f "$WORK/../../../sdk/typescript/_bundled_plugin/.codex-plugin/plugin.json" ]; then
    PLUGIN="$(cd "$WORK/../../../sdk/typescript/_bundled_plugin" && pwd -P)"
  elif NPM_ROOT="$(npm root -g 2>/dev/null)" && \
       [ -f "$NPM_ROOT/@openai/codex-security/_bundled_plugin/.codex-plugin/plugin.json" ]; then
    PLUGIN="$NPM_ROOT/@openai/codex-security/_bundled_plugin"
  else
    echo "오류: 플러그인을 찾지 못했습니다. CODEX_SECURITY_PLUGIN_DIR=<_bundled_plugin 경로> 를 지정하세요." >&2
    exit 1
  fi
fi
FINALIZE="$PLUGIN/scripts/finalize_scan_contract.py"
VALIDATE="$PLUGIN/scripts/validate_scan_contract.py"
# 픽스처는 스크립트의 상위 디렉터리(docs/verification/fixtures)에 있다.
FIXTURES="${CODEX_SECURITY_FIXTURES:-$WORK/../fixtures}"
# 산출물은 저장소 밖 임시 디렉터리에 쓴다(레포 오염 방지).
RUN="$(mktemp -d)"
SRC="$RUN/source-root"
trap 'rm -rf "$RUN"' EXIT

# 플러그인 디렉터리에 __pycache__ 를 남기지 않는다 (레포는 읽기 전용으로 유지).
export PYTHONDONTWRITEBYTECODE=1

# Python: PYTHON 환경변수 → python3 → python. 버전 매니저 환경이면
#   PYTHON="$(mise which python3)" bash repro-u4.sh
PYTHON_BIN="${PYTHON:-$(command -v python3 || command -v python)}"
: "${PYTHON_BIN:?Python 3.10+ 인터프리터를 찾지 못했습니다. PYTHON=<경로> 로 지정하세요.}"
PY() { "$PYTHON_BIN" "$@"; }

FAILED=0
SKIPPED=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf 'OK   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }
# 검증하지 못한 항목은 통과로 세지 않는다. 전제(ripgrep 등)가 없어 실행조차 못한
# 블록을 조용히 넘기면 "핵심 주장이 미검증인 상태"와 "전부 통과"가 같은 신호가 된다.
skip() { printf 'SKIP %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
expect_exit() { # expect_exit <expected> <actual> <label>
  if [ "$2" = "$1" ]; then
    printf 'OK   %s: exit %s (expected %s)\n' "$3" "$2" "$1"
  else
    printf 'FAIL %s: exit %s (expected %s)\n' "$3" "$2" "$1"
    FAILED=$((FAILED + 1))
  fi
}

rm -rf "$RUN"
mkdir -p "$SRC/src"

# 합성 소스 루트: findings.locations 가 가리키는 실존 파일 1개.
cat >"$SRC/src/extract.py" <<'EOF'
import tarfile


def extract(archive, destination):
    tarfile.open(archive).extractall(destination)
EOF

# ---------------------------------------------------------------------------
# A. 정상 경로 — 최소 draft 3종 -> finalize(exit 0) -> validate(exit 0)
# ---------------------------------------------------------------------------
step "A. finalize_scan_contract.py (최소 unsealed draft)"
SCAN="$RUN/scan-a"
mkdir -p "$SCAN"
cp "$FIXTURES"/scan-manifest.json "$FIXTURES"/findings.json "$FIXTURES"/coverage.json "$SCAN/"

echo "\$ CODEX_SECURITY_STARTED_AT=2026-07-30T09:00:00Z python3 finalize_scan_contract.py --scan-dir $SCAN --source-root $SRC"
CODEX_SECURITY_STARTED_AT=2026-07-30T09:00:00Z PY "$FINALIZE" --scan-dir "$SCAN" --source-root "$SRC"
expect_exit 0 "$?" "A finalize"

step "A. validate_scan_contract.py"
echo "\$ python3 validate_scan_contract.py --scan-dir $SCAN"
PY "$VALIDATE" --scan-dir "$SCAN"
expect_exit 0 "$?" "A validate"

step "A. 생성 산출물"
for artifact in report.md exports/results.sarif; do
  if [ -f "$SCAN/$artifact" ]; then
    printf 'OK   %s 생성됨 (%s bytes)\n' "$artifact" "$(wc -c <"$SCAN/$artifact")"
  else
    printf 'FAIL %s 없음\n' "$artifact"
    FAILED=$((FAILED + 1))
  fi
done
echo "--- sealed manifest scan.sealedAt / artifacts / findingId ---"
PY - "$SCAN" <<'EOF'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
scan = json.loads((d / "scan-manifest.json").read_text())["scan"]
print("documentType:", json.loads((d / "scan-manifest.json").read_text())["documentType"])
print("status:", scan["status"], "| startedAt:", scan["startedAt"])
print("completedAt == sealedAt:", scan["completedAt"] == scan["sealedAt"], scan["sealedAt"])
print("artifacts:", [a["path"] for a in scan["artifacts"]])
f = json.loads((d / "findings.json").read_text())["findings"][0]
print("findingId:", f["findingId"])
print("occurrenceId:", f["occurrenceId"])
print("fingerprints.primary:", f["fingerprints"]["primary"])
sarif = json.loads((d / "exports" / "results.sarif").read_text())
print("sarif partialFingerprints:", sarif["runs"][0]["results"][0]["partialFingerprints"])
EOF

# ---------------------------------------------------------------------------
# B. 오류 형상 프로브 1 — 대문자 ruleId 슬러그
# ---------------------------------------------------------------------------
step "B. 오류 프로브 1: 잘못된 ruleId 슬러그 (대문자)"
SCAN="$RUN/scan-b"
mkdir -p "$SCAN"
cp "$FIXTURES"/scan-manifest.json "$FIXTURES"/coverage.json "$SCAN/"
PY - "$FIXTURES/findings.json" "$SCAN/findings.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1]).read())
data["findings"][0]["ruleId"] = "Path-Traversal.ArchiveExtraction"
open(sys.argv[2], "w").write(json.dumps(data, indent=2) + "\n")
EOF
echo "\$ python3 finalize_scan_contract.py --scan-dir $SCAN --source-root $SRC   # stderr:"
CODEX_SECURITY_STARTED_AT=2026-07-30T09:00:00Z PY "$FINALIZE" --scan-dir "$SCAN" --source-root "$SRC"
expect_exit 2 "$?" "B finalize (실패 기대)"

# ---------------------------------------------------------------------------
# C. 오류 형상 프로브 2 — coverage.includePaths 가 manifest scope 와 불일치
# ---------------------------------------------------------------------------
step "C. 오류 프로브 2: coverage.includePaths != manifest.scan.scope.includePaths"
SCAN="$RUN/scan-c"
mkdir -p "$SCAN"
cp "$FIXTURES"/scan-manifest.json "$FIXTURES"/findings.json "$SCAN/"
PY - "$FIXTURES/coverage.json" "$SCAN/coverage.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1]).read())
data["includePaths"] = ["lib/"]
open(sys.argv[2], "w").write(json.dumps(data, indent=2) + "\n")
EOF
echo "\$ python3 finalize_scan_contract.py --scan-dir $SCAN --source-root $SRC   # stderr:"
CODEX_SECURITY_STARTED_AT=2026-07-30T09:00:00Z PY "$FINALIZE" --scan-dir "$SCAN" --source-root "$SRC"
expect_exit 2 "$?" "C finalize (실패 기대)"

# ---------------------------------------------------------------------------
# D. 경로 미검증 증명 — 소스 루트에 없는 locations.path 도 seal 통과
# ---------------------------------------------------------------------------
step "D. 경로 미검증 증명: 존재하지 않는 locations[].path"
SCAN="$RUN/scan-d"
mkdir -p "$SCAN"
cp "$FIXTURES"/scan-manifest.json "$FIXTURES"/coverage.json "$SCAN/"
PY - "$FIXTURES/findings.json" "$SCAN/findings.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1]).read())
data["findings"][0]["locations"] = [
    {"path": "src/this/file/does/not/exist.py", "startLine": 999999, "endLine": 1000000}
]
open(sys.argv[2], "w").write(json.dumps(data, indent=2) + "\n")
EOF
echo "존재 확인: $SRC/src/this/file/does/not/exist.py -> $([ -e "$SRC/src/this/file/does/not/exist.py" ] && echo EXISTS || echo MISSING)"
echo "\$ python3 finalize_scan_contract.py --scan-dir $SCAN --source-root $SRC"
CODEX_SECURITY_STARTED_AT=2026-07-30T09:00:00Z PY "$FINALIZE" --scan-dir "$SCAN" --source-root "$SRC"
expect_exit 0 "$?" "D finalize (없는 경로도 통과)"
PY "$VALIDATE" --scan-dir "$SCAN" >/dev/null
expect_exit 0 "$?" "D validate (없는 경로도 통과)"
PY - "$SCAN" <<'EOF'
import json, sys, pathlib
sarif = json.loads((pathlib.Path(sys.argv[1]) / "exports" / "results.sarif").read_text())
result = sarif["runs"][0]["results"][0]
print("SARIF uri:", result["locations"][0]["physicalLocation"]["artifactLocation"]["uri"])
print("SARIF partialFingerprints keys:", sorted(result["partialFingerprints"]))
EOF

# ---------------------------------------------------------------------------
# E. 보너스 — CODEX_SECURITY_STARTED_AT 미주입 시 실패 형상
# ---------------------------------------------------------------------------
step "E. 보너스: CODEX_SECURITY_STARTED_AT 미주입"
SCAN="$RUN/scan-e"
mkdir -p "$SCAN"
cp "$FIXTURES"/scan-manifest.json "$FIXTURES"/findings.json "$FIXTURES"/coverage.json "$SCAN/"
echo "\$ python3 finalize_scan_contract.py --scan-dir $SCAN --source-root $SRC   # env 없음, stderr:"
env -u CODEX_SECURITY_STARTED_AT "$PYTHON_BIN" "$FINALIZE" --scan-dir "$SCAN" --source-root "$SRC"
expect_exit 2 "$?" "E finalize (실패 기대)"

# ---------------------------------------------------------------------------
# F. SARIF 성공 판정 형상 (0.1.25 에서 의미가 바뀜)
#
#   completeness=complete  -> invocations 키가 아예 생성되지 않는다
#   completeness=partial   -> executionSuccessful=true (종결 상태만 반영) +
#                             properties.codexSecurityCoverageCompleteness=partial
#   partial + deferred=[]  -> 경고가 0건이라 SARIF 만으로는 불완전을 알 수 없다
# ---------------------------------------------------------------------------
step "F. SARIF 성공 판정 형상 (complete / partial / partial+deferred 없음)"
# sarif_shape <label> <completeness> <deferred-json> <invocations 유무> <기대 completeness> <기대 경고건수>
# 세 케이스가 서로 다른 값을 단언해야 한다 — 같은 것만 검사하면 케이스가 늘어도
# 판별력이 늘지 않는다. 특히 경고 건수는 partial 두 케이스를 가르는 유일한 축이다.
sarif_shape() {
  local label="$1" completeness="$2" deferred="$3" expect_inv="$4"
  local expect_completeness="$5" expect_warnings="$6"
  local scan="$RUN/scan-f-$label"
  mkdir -p "$scan"
  cp "$FIXTURES"/scan-manifest.json "$FIXTURES"/findings.json "$FIXTURES"/coverage.json "$scan/"
  PY - "$scan/coverage.json" "$completeness" "$deferred" <<'EOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
coverage = json.loads(path.read_text())
coverage["completeness"] = sys.argv[2]
coverage["deferred"] = json.loads(sys.argv[3])
path.write_text(json.dumps(coverage, indent=2))
# 픽스처 변형이 실제로 적용됐는지 되읽어 확인한다 — 적용 실패를 통과로 세면
# 세 케이스가 모두 같은 입력을 검사하게 된다.
back = json.loads(path.read_text())
if back["completeness"] != sys.argv[2] or back["deferred"] != json.loads(sys.argv[3]):
    print(f"FAIL: 픽스처 변형이 적용되지 않았습니다: {path}")
    raise SystemExit(1)
EOF
  expect_exit 0 "$?" "F/$label 픽스처 변형 적용"
  CODEX_SECURITY_STARTED_AT=2026-07-30T09:00:00Z PY "$FINALIZE" \
    --scan-dir "$scan" --source-root "$SRC" >/dev/null 2>&1
  expect_exit 0 "$?" "F/$label finalize"
  PY - "$scan" "$expect_inv" "$label" "$expect_completeness" "$expect_warnings" <<'EOF'
import json, pathlib, sys
run = json.loads((pathlib.Path(sys.argv[1]) / "exports" / "results.sarif").read_text())["runs"][0]
expect_inv = sys.argv[2] == "yes"
label, expect_completeness, expect_warnings = sys.argv[3], sys.argv[4], int(sys.argv[5])
invocations = run.get("invocations")
completeness = run.get("properties", {}).get("codexSecurityCoverageCompleteness")
problems = []
if (invocations is not None) != expect_inv:
    problems.append(f"invocations 유무 기대={expect_inv} 실제={invocations is not None}")
want = None if expect_completeness == "none" else expect_completeness
if completeness != want:
    problems.append(f"completeness 기대={want!r} 실제={completeness!r}")
if invocations is not None:
    if invocations[0].get("executionSuccessful") is not True:
        problems.append("executionSuccessful 이 true 가 아님")
    warnings = invocations[0].get("toolExecutionNotifications", [])
    if len(warnings) != expect_warnings:
        problems.append(f"경고 건수 기대={expect_warnings} 실제={len(warnings)}")
    detail = f"executionSuccessful=true, completeness={completeness!r}, 경고 {len(warnings)}건"
else:
    detail = f"invocations 키 없음, completeness={completeness!r}"
for p in problems:
    print(f"FAIL F/{label}: {p}")
if problems:
    raise SystemExit(1)
print(f"     {detail}")
EOF
  expect_exit 0 "$?" "F/$label SARIF 형상"
}
# complete: invocations 키가 아예 없다 → completeness 프로퍼티도 없다.
sarif_shape complete complete '[]' no none 0
# partial + deferred 1건: executionSuccessful=true 인데 경고 1건이 실린다.
sarif_shape partial partial '[{"id":"unreviewed-in-scope-files","reason":"미리뷰 12개"}]' yes partial 1
# partial + deferred 없음: 경고가 0건이라 SARIF 만으로는 불완전을 알 수 없다.
# 이 0 이 위 1 과 다르다는 것이 이 케이스의 존재 이유다.
sarif_shape partial-nodeferred partial '[]' yes partial 0

# ---------------------------------------------------------------------------
# G. 인벤토리 정확성 — 상류 출력이 아니라 손으로 열거한 기대 집합과 대조한다.
#    상류 출력과의 비교는 위임 후 자기참조가 되어 규칙 변경을 잡지 못한다.
#
#    검색 명령(rg)은 스킬이 실제로 쓰는 기계, 즉 bootstrap.py 가 해석한
#    `searchCommand.pathEnv` 를 그대로 쓴다. 여기서 shim 을 셸로 재구현하면
#    상류 호출은 통과하지만 정작 스킬이 쓰는 경로는 검증되지 않는다.
# ---------------------------------------------------------------------------
step "G. 인벤토리 정확성 (추적된 무시 파일 포함 / 미추적 포함 / 무시된 미추적 제외)"
INV_SCRIPT="$PLUGIN/scripts/generate_in_scope_files.py"
BOOTSTRAP="${CODEX_SECURITY_BOOTSTRAP:-$WORK/../../../skills/codex-security-scan/scripts/bootstrap.py}"
SEARCH_PATH_ENV=""
if [ ! -f "$INV_SCRIPT" ]; then
  bad "G: $INV_SCRIPT 가 없습니다"
elif [ ! -f "$BOOTSTRAP" ]; then
  skip "G: bootstrap.py 를 찾지 못해 검색 명령을 확보할 수 없습니다: $BOOTSTRAP"
else
  # bootstrap 의 신뢰 경계 계산에만 쓰이는 빈 대상 저장소로 프로브한다.
  BOOT_TARGET="$RUN/boot-target"
  BOOT_STATE="$RUN/boot-state"
  mkdir -p "$BOOT_TARGET" "$BOOT_STATE"
  boot_rc=0
  CODEX_SECURITY_STATE_DIR="$BOOT_STATE" CODEX_SECURITY_PLUGIN_ROOT="$PLUGIN" \
    PYTHONDONTWRITEBYTECODE=1 \
    "$PYTHON_BIN" "$BOOTSTRAP" --target-repo "$BOOT_TARGET" --no-scan-dir --probe-search \
    >"$RUN/boot.json" 2>"$RUN/boot.err" || boot_rc=$?
  # bootstrap.py 는 상류가 아니라 이 저장소의 코드다. --probe-search 계약이 깨진
  # 사건을 "이 기계에 ripgrep 이 없다"로 오진하면 실패가 SKIP(exit 2)으로 강등돼
  # exit 1 만 보는 게이트를 통과한다.
  if [ "$boot_rc" != "0" ]; then
    bad "G: bootstrap --probe-search 가 exit $boot_rc 로 실패했습니다 (환경 부재가 아니라 회귀)"
    sed 's/^/     /' "$RUN/boot.err"
    # 아래 SEARCH_PATH_ENV 공백 분기는 "이 기계에 ripgrep 이 없다"를 안내한다.
    # 이미 회귀로 FAIL 을 냈으면 그 안내는 오진이고, SKIPPED 도 한 사건을 이중
    # 계상하게 된다 — 중복 보고를 막는다.
    boot_diagnosed=1
  fi
  SEARCH_PATH_ENV="$(PY - "$RUN/boot.json" <<'PYEOF2'
import json, pathlib, sys
try:
    d = json.loads(pathlib.Path(sys.argv[1]).read_text() or "{}")
except json.JSONDecodeError:
    raise SystemExit(0)
print(((d.get("searchCommand") or {}).get("pathEnv")) or "")
PYEOF2
)"
  if [ -z "$SEARCH_PATH_ENV" ] && [ "${boot_diagnosed:-0}" = "0" ]; then
    skip "G: bootstrap 이 ripgrep 을 확보하지 못했습니다 — 인벤토리 정확성을 검증할 수 없습니다"
    printf '        ripgrep 을 설치하고 다시 실행하세요(apt/brew/cargo install ripgrep).\n'
  fi
fi

if [ -n "$SEARCH_PATH_ENV" ]; then
  INV="$RUN/inv-repo"
  mkdir -p "$INV/src" "$INV/dist"
  # `-c core.excludesFile` 은 이 init 프로세스에만 적용돼 새 저장소 config 에 남지
  # 않는다(무효과). 실제로 막아야 하는 것은 전역 init.templateDir / GIT_TEMPLATE_DIR
  # 이 심는 .git/info/exclude 다 — rg 와 git ls-files --exclude-standard 가 둘 다
  # 이를 존중하므로 run_inventory 의 env -i / HOME 격리로는 우회되지 않는다(실측:
  # 전역 templateDir 하나로 G2 가 거짓 실패).
  ( cd "$INV" && git init -q --template= . )
  # --template= 는 info/ 자체를 만들지 않는다. 빈 exclude 를 명시적으로 둬서
  # 이후 어떤 경로로도 규칙이 끼어들지 않게 못 박는다.
  mkdir -p "$INV/.git/info"
  : > "$INV/.git/info/exclude"
  printf 'a\n' > "$INV/src/tracked.py"       # 추적 + 무시 안 됨  -> 포함
  printf 'b\n' > "$INV/src/untracked.py"     # 미추적 + 무시 안 됨 -> 포함
  printf 'c\n' > "$INV/dist/generated.py"    # 추적 + 무시됨       -> 포함(add-back)
  printf 'd\n' > "$INV/dist/loose.py"        # 미추적 + 무시됨     -> 제외
  printf 'dist/\n' > "$INV/.gitignore"
  ( cd "$INV" && git add -f .gitignore src/tracked.py dist/generated.py >/dev/null 2>&1 \
      && git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1 )

  # 상류 스크립트는 rg 와 git 을 모두 PATH 에서 해석하고 cwd=대상 저장소로 실행한다.
  # 그래서 PATH 를 pathEnv 로 **교체**한다(앞에 덧붙이지 않는다) — 원시 $PATH 를
  # 물려주면 저장소가 커밋한 ./node_modules/.bin/git 이 실행된다(실측).
  # HOME 을 실사용자 홈으로 물려주면 전역 gitignore(~/.config/git/ignore,
  # core.excludesFile)를 rg 와 git ls-files --exclude-standard 가 읽어, 손으로
  # 열거한 기대 집합이 기계마다 달라진다(실측: untracked.py 패턴 하나로 G2 오탐).
  INV_HOME="$RUN/scratch-home"
  mkdir -p "$INV_HOME"
  run_inventory() { # run_inventory <출력파일> [환경 KEY=VAL ...]
    local out="$1"; shift
    # 오류 로그도 호출별로 남긴다 — 고정 파일이면 뒤 호출이 앞 원인을 덮는다.
    env -i PATH="$SEARCH_PATH_ENV" HOME="$INV_HOME" GIT_CONFIG_NOSYSTEM=1 \
      PYTHONDONTWRITEBYTECODE=1 "$@" \
      "$PYTHON_BIN" "$INV_SCRIPT" --repo "$INV" --scope . --out "$out" \
      > "$out.err" 2>&1
  }

  run_inventory "$RUN/inv.txt"
  expect_exit 0 "$?" "G1 인벤토리 생성"
  [ -s "$RUN/inv.txt.err" ] && sed 's/^/     /' "$RUN/inv.txt.err"
  LC_ALL=C sort -u "$RUN/inv.txt" > "$RUN/inv.actual"
  printf './.gitignore\n./dist/generated.py\n./src/tracked.py\n./src/untracked.py\n' \
    | LC_ALL=C sort -u > "$RUN/inv.expected"
  if diff -u "$RUN/inv.expected" "$RUN/inv.actual" > "$RUN/inv.diff" 2>&1; then
    ok "G2: 인벤토리가 기대 집합과 일치 (4개)"
  else
    bad "G2: 인벤토리가 기대 집합과 다름"
    cat "$RUN/inv.diff"
  fi

  # -------------------------------------------------------------------------
  # G3. `.rgignore` 로 분모가 줄어드는 범위 (잔여 위험의 실측).
  #
  # 상류는 rg 에 --no-config 를 주지 않는다. 대상 저장소가 `.rgignore` 를
  # 커밋하면 그 경로가 rg 열거에서 빠진다. 되살아나는 것은 상류가 별도로
  # add-back 하는 파일뿐이고, 그 add-back 은
  #   git ls-files --cached --ignored --exclude-standard
  # 즉 **추적 AND gitignore된** 파일만 대상이다. 따라서 저장소 대부분을 이루는
  # 추적+비무시 파일은 add-back 대상이 아니라 그대로 분모에서 빠진다(실측).
  # 이 범위를 정확히 고정한다 — 좁게 적으면 위험을 과소 보고한다.
  # -------------------------------------------------------------------------

  # G3a·G3b: 추적 + gitignore됨 → add-back 으로 살아남아야 한다.
  #          이것이 add-back 경로를 단독으로 통과하는 유일한 클래스다.
  # 추적+무시 파일은 `.gitignore` 만으로 이미 rg 열거에서 빠져 있으므로, `.rgignore`
  # 항목은 이 클래스에 **무해**해야 한다. 단일 경로 grep 은 G2 의 add-back 확인과
  # 같은 사실 하나만 봐서 한계 판별력이 0이다(실측: `.rgignore` 쓰기를 지워도 결과
  # 동일). 집합 동치로 바꿔 "무해함" 자체를 고정한다.
  printf 'generated.py\n' > "$INV/.rgignore"
  run_inventory "$RUN/inv-addback.txt"
  expect_exit 0 "$?" "G3a add-back 대상(.rgignore=추적+무시) 인벤토리 생성"
  LC_ALL=C sort -u "$RUN/inv-addback.txt" > "$RUN/inv-addback.actual"
  { cat "$RUN/inv.expected"; printf './.rgignore\n'; } \
    | LC_ALL=C sort -u > "$RUN/inv-addback.expected"
  if diff -u "$RUN/inv-addback.expected" "$RUN/inv-addback.actual" \
       > "$RUN/inv-addback.diff" 2>&1; then
    ok "G3b: .rgignore 항목이 추적+무시 파일에 무해함 (add-back 이 분모를 그대로 유지)"
  else
    bad "G3b: .rgignore 가 추적+무시 파일의 분모를 바꿨습니다 — add-back 이 깨졌거나 범위가 바뀌었습니다"
    cat "$RUN/inv-addback.diff"
  fi

  # G3c·G3d: 추적 + 비무시 → add-back 대상이 아니므로 빠진다.
  #          이 클래스가 저장소 대부분이라 위험의 실제 크기를 정한다.
  printf 'src/tracked.py\n' > "$INV/.rgignore"
  run_inventory "$RUN/inv-tracked.txt"
  expect_exit 0 "$?" "G3c 추적+비무시(.rgignore) 인벤토리 생성"
  if grep -qx './src/tracked.py' "$RUN/inv-tracked.txt"; then
    # 상류가 --no-config 를 주거나 add-back 범위를 넓혔다는 뜻이다.
    bad "G3d: 추적+비무시 파일이 .rgignore 에도 남았습니다 — 상류 동작이 바뀌었으니 문서(계약 9)를 갱신하세요"
  else
    ok "G3d: 추적+비무시 파일이 .rgignore 로 분모에서 빠짐 — 알려진 잔여 위험(계약 9와 일치)"
    printf '     add-back 은 추적 AND gitignore된 파일만 되살린다. 저장소 대부분인\n'
    printf '     추적+비무시 파일은 커밋된 .rgignore 로 커버리지 분모에서 빠질 수 있다.\n'
  fi
  # 대조군: 분모가 전면 붕괴한 것이 아니라 지정한 경로만 빠졌는지 확인한다.
  # 이것이 없으면 "인벤토리가 통째로 비었다"도 위 OK 와 같은 신호가 된다.
  if grep -qx './src/untracked.py' "$RUN/inv-tracked.txt" \
     && grep -qx './.gitignore' "$RUN/inv-tracked.txt"; then
    ok "G3e: 지정 경로만 빠지고 나머지 분모는 유지됨 (G3d 판정을 신뢰할 수 있음)"
  else
    bad "G3e: 인벤토리가 지정 범위를 넘어 축소됐습니다 — G3d 판정을 신뢰할 수 없습니다"
    sed 's/^/     /' "$RUN/inv-tracked.txt"
  fi
  rm -f "$INV/.rgignore"

  # -------------------------------------------------------------------------
  # G4. RIPGREP_CONFIG_PATH 로도 같은 축소가 가능한가.
  #     실행 환경이 정하는 값이지만, 상류 generate_in_scope_files.py 는 env= 를
  #     넘기지 않아 부모 환경을 전부 상속한다. 소비자가 PATH 만 교체해도 이
  #     변수는 자식 rg 에 그대로 들어간다.
  # -------------------------------------------------------------------------
  # G4b 는 .rgignore 가 없어야 RIPGREP_CONFIG_PATH 를 단독으로 검증한다. 남아
  # 있으면 같은 경로가 두 이유로 빠져 단언이 조용히 무력화된다(실측으로 거짓 통과 재현).
  if [ -e "$INV/.rgignore" ]; then
    bad "G4 전제 위반: $INV/.rgignore 가 남아 있어 G4b 가 RIPGREP_CONFIG_PATH 를 단독 검증하지 못합니다"
  fi
  printf -- '--glob=!src/tracked.py\n' > "$RUN/rgconfig"
  run_inventory "$RUN/inv-rgconfig.txt" RIPGREP_CONFIG_PATH="$RUN/rgconfig"
  expect_exit 0 "$?" "G4a RIPGREP_CONFIG_PATH 인벤토리 생성"
  if grep -qx './src/tracked.py' "$RUN/inv-rgconfig.txt"; then
    bad "G4b: RIPGREP_CONFIG_PATH 가 분모에 영향을 주지 않았습니다 — 순서대로 확인: (1) $INV/.rgignore 잔존, (2) rg 가 이 변수를 지원하는 버전인지, (3) 상류가 --no-config 를 주기 시작했는지, (4) add-back 범위가 넓어졌는지. (3)(4)면 문서(계약 9)를 갱신하세요"
  else
    ok "G4b: RIPGREP_CONFIG_PATH 로 추적+비무시 파일이 분모에서 빠짐 — 알려진 잔여 위험"
  fi
  # 대조군: rg 는 매치 0건에 exit 1 을 내고 상류는 0/1 을 모두 정상으로 받는다.
  # 그래서 `--glob=!*` 같은 값으로 분모가 통째로 붕괴해도 exit 0 이 된다.
  # 좁은 제외와 전면 붕괴를 반드시 갈라야 한다.
  if grep -qx './src/untracked.py' "$RUN/inv-rgconfig.txt" \
     && grep -qx './.gitignore' "$RUN/inv-rgconfig.txt"; then
    ok "G4c: 지정 경로만 빠지고 분모 전체가 붕괴하지 않음"
  else
    bad "G4c: 분모가 지정 범위를 넘어 축소됐습니다 — G4b 판정을 신뢰할 수 없습니다"
    sed 's/^/     /' "$RUN/inv-rgconfig.txt"
  fi
  # 전면 붕괴가 실제로 exit 0 으로 통과함을 고정한다 — 상류가 rg 의 exit 1 을
  # 정상으로 받는다는 사실 자체가 위험의 일부다.
  printf -- '--glob=!*\n' > "$RUN/rgconfig-all"
  run_inventory "$RUN/inv-collapse.txt" RIPGREP_CONFIG_PATH="$RUN/rgconfig-all"
  expect_exit 0 "$?" "G4d 분모 전면 붕괴도 상류는 exit 0"
  collapse_n="$(wc -l < "$RUN/inv-collapse.txt" | tr -d ' ')"
  # 잔존해야 하는 것은 add-back 대상(추적 AND 무시) 1개뿐이다. `-lt 4` 같은 느슨한
  # 임계값은 부분 붕괴(3/4 잔존)도 "전면 붕괴"로 통과시켜 잘못된 이유로 성공한다(실측).
  if [ "$collapse_n" -le 1 ] && ! grep -qx './src/tracked.py' "$RUN/inv-collapse.txt"; then
    ok "G4e: 전면 붕괴 시 인벤토리가 ${collapse_n}개로 줄어들지만 상류는 성공으로 끝남 — 정산은 빈 분모만 잡고 비지 않은 축소는 잡지 못한다"
  else
    bad "G4e: 전면 붕괴를 재현하지 못했습니다(${collapse_n}개) — 이 케이스의 전제를 다시 확인하세요"
  fi

  # G4f. 스킬이 강제하는 완화(RIPGREP_CONFIG_PATH= 빈 값)가 실제로 듣는가.
  # 위험만 고정하고 완화는 아무도 검증하지 않으면, SKILL.md 의 그 줄을 지워도
  # 이 스크립트는 침묵한다.
  # `env -i` 아래에서는 RIPGREP_CONFIG_PATH 가 애초에 자식 환경에 없다. 빈 값만
  # 넘기면 덮을 대상이 없어 이 단언이 G2 의 사실을 재확인할 뿐이다(실측: 인자를
  # 지워도 통과). 오염값을 먼저 주고 빈 값으로 **덮어야** 완화가 갈린다.
  run_inventory "$RUN/inv-mitigated.txt" \
    RIPGREP_CONFIG_PATH="$RUN/rgconfig-all" RIPGREP_CONFIG_PATH=
  expect_exit 0 "$?" "G4f 완화 적용 인벤토리 생성"
  if grep -qx './src/tracked.py' "$RUN/inv-mitigated.txt"; then
    ok "G4g: RIPGREP_CONFIG_PATH= (스킬이 강제하는 완화)로 분모가 복원됨"
  else
    bad "G4g: 문서화된 완화(RIPGREP_CONFIG_PATH=)가 듣지 않습니다 — SKILL.md 의 계약이 무효입니다"
  fi
fi

# ---------------------------------------------------------------------------
# H. 리포트·finalizer 완화 (npm 0.1.29, 상류 1518e933·936d850a)
#
#   H1  report.md 에 "Runtime or test status" 행이 없다. 값(scan.scope.runtimeStatus)
#       은 매니페스트에 남지만 리포트는 표시하지 않는다.
#   H2  unsealed draft 의 scan.artifacts: [] 를 finalizer 가 지우고 봉인한다.
#       이것은 호환성 완화의 관측이다. 스킬 규약(R6 금지 필드)은 여전히
#       scan.artifacts 를 쓰지 않는다.
#   둘 다 0.1.25 에서는 실패해야 변화를 잡는 단언이다.
# ---------------------------------------------------------------------------
step "H. 리포트 runtime status 행 삭제 / unsealed artifacts: [] 봉인"
if [ -f "$RUN/scan-a/report.md" ]; then
  if grep -q "Runtime or test status" "$RUN/scan-a/report.md"; then
    bad "H1: report.md 에 'Runtime or test status' 행이 있습니다 — 리포트가 실행·테스트 상태를 표시하지 않는다는 스킬 서술이 틀립니다"
    grep -n "Runtime or test status" "$RUN/scan-a/report.md" | sed 's/^/     /'
  else
    ok "H1: report.md 에 'Runtime or test status' 행이 없음"
  fi
else
  bad "H1: A 블록의 report.md 가 없어 검사할 수 없습니다"
fi

SCAN="$RUN/scan-h"
mkdir -p "$SCAN"
cp "$FIXTURES"/findings.json "$FIXTURES"/coverage.json "$SCAN/"
PY - "$FIXTURES/scan-manifest.json" "$SCAN/scan-manifest.json" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1]).read())
data["scan"]["artifacts"] = []
open(sys.argv[2], "w").write(json.dumps(data, indent=2) + "\n")
back = json.loads(open(sys.argv[2]).read())
if back["scan"].get("artifacts") != [] or "sealedAt" in back["scan"]:
    print("FAIL: 픽스처 변형(scan.artifacts: [])이 적용되지 않았습니다")
    raise SystemExit(1)
EOF
expect_exit 0 "$?" "H2 픽스처 변형 적용"
CODEX_SECURITY_STARTED_AT=2026-07-30T09:00:00Z PY "$FINALIZE" --scan-dir "$SCAN" --source-root "$SRC" \
  > "$RUN/scan-h.out" 2>&1
h_rc=$?
expect_exit 0 "$h_rc" "H2 finalize (unsealed scan.artifacts: [] 봉인 성공 기대)"
[ "$h_rc" != "0" ] && sed 's/^/     /' "$RUN/scan-h.out"
if [ "$h_rc" = "0" ]; then
  PY - "$SCAN/scan-manifest.json" <<'EOF'
import json, sys
scan = json.loads(open(sys.argv[1]).read())["scan"]
paths = sorted(a.get("path") for a in scan.get("artifacts") or [])
# 기대 집합은 손으로 열거한다. 빈 배열을 쓰지 않은 A 블록의 봉인 결과와 같다.
expected = ["coverage.json", "findings.json"]
if scan.get("sealedAt") and paths == expected:
    print(f"OK   H3: 봉인 후 finalizer 가 artifacts 를 다시 채움 {paths}")
else:
    print(f"FAIL H3: 봉인 매니페스트의 artifacts 가 기대 {expected} 와 다르거나 sealedAt 이 없습니다: {paths}")
    raise SystemExit(1)
EOF
  [ "$?" = "0" ] || FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------------------
# I. diff 인벤토리·diff 랭킹 입력 (npm 0.1.27~0.1.32, 상류 be7807de·fa5fe21c·46dce4a2·
#    cce82310·ce7f75c1·6f8b3545)
#
#   새 확장자(.cjs .cts .mts .tf, 0.1.31 의 .m, 0.1.32 의 .sol .svelte)는
#   rank_preview.TEXT_CODE_EXTENSIONS 에 들어갔다.
#   이 집합은 diff 인벤토리와 랭킹 입력만 쓴다. 전체 인벤토리는 확장자 필터가
#   없는 `rg --files` 라 0.1.25 에서도 이 파일들을 포함했다.
#   diff 인벤토리는 .github/workflows/* 를 제외 규칙에서 빼서 유지한다.
#   .github 의 다른 파일(dependabot.yml)은 계속 제외된다 — 음성 대조군이다.
#   기대 집합은 손으로 열거한다(P5-KTD3). 상류 출력끼리 비교하지 않는다.
# ---------------------------------------------------------------------------
step "I. diff 인벤토리·랭킹 입력: 새 확장자와 .github/workflows"
RANK_SCRIPT="$PLUGIN/scripts/generate_rank_input.py"
GIT_BIN="$(command -v git || true)"
if [ -z "$GIT_BIN" ]; then
  skip "I: git 이 없어 diff 인벤토리를 검증할 수 없습니다"
else
  # diff 모드는 rg 를 타지 않는다. git 만 PATH 에서 해석하므로 git 이 있는
  # 디렉터리만 PATH 로 준다(원시 $PATH 를 물려주지 않는다).
  DIFF_PATH_ENV="${SEARCH_PATH_ENV:-$(dirname "$GIT_BIN"):/usr/bin:/bin}"
  DIFF_HOME="$RUN/diff-home"
  mkdir -p "$DIFF_HOME"
  DREPO="$RUN/diff-repo"
  mkdir -p "$DREPO/src"
  ( cd "$DREPO" && git init -q --template= . )
  mkdir -p "$DREPO/.git/info"
  : > "$DREPO/.git/info/exclude"
  printf 'print(1)\n' > "$DREPO/src/base.py"
  dgit() { env -i PATH="$DIFF_PATH_ENV" HOME="$DIFF_HOME" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$DREPO" -c user.email=t@t -c user.name=t "$@"; }
  dgit add -A >/dev/null && dgit commit -qm base >/dev/null
  DBASE="$(dgit rev-parse HEAD)"

  # 커밋 1: 새 확장자 4종 + workflow + 음성 대조군 + 기존 확장자 대조군.
  mkdir -p "$DREPO/.github/workflows"
  printf 'module.exports = 1;\n' > "$DREPO/src/a.cjs"
  printf 'export const b = 1;\n' > "$DREPO/src/b.cts"
  printf 'export const c = 1;\n' > "$DREPO/src/c.mts"
  printf 'resource "null_resource" "x" {}\n' > "$DREPO/main.tf"
  printf 'on: push\njobs: {}\n' > "$DREPO/.github/workflows/ci.yml"
  printf 'version: 2\n' > "$DREPO/.github/dependabot.yml"
  printf 'print(2)\n' > "$DREPO/src/control.py"
  dgit add -A >/dev/null && dgit commit -qm exts >/dev/null
  DMID="$(dgit rev-parse HEAD)"

  # 커밋 2: workflow 파일만 바꾼다.
  printf 'on: [push, pull_request]\njobs: {}\n' > "$DREPO/.github/workflows/ci.yml"
  dgit add -A >/dev/null && dgit commit -qm workflow >/dev/null
  DHEAD="$(dgit rev-parse HEAD)"

  diff_inventory() { # diff_inventory <base> <head> <out>
    env -i PATH="$DIFF_PATH_ENV" HOME="$DIFF_HOME" GIT_CONFIG_NOSYSTEM=1 \
      PYTHONDONTWRITEBYTECODE=1 \
      "$PYTHON_BIN" "$INV_SCRIPT" --repo "$DREPO" --scope . \
      --diff-base "$1" --diff-head "$2" --diff-mode revisions --out "$3" > "$3.err" 2>&1
  }
  diff_rank_input() { # diff_rank_input <base> <head> <out> — 경로 목록만 뽑아 <out>.paths 에 쓴다
    env -i PATH="$DIFF_PATH_ENV" HOME="$DIFF_HOME" GIT_CONFIG_NOSYSTEM=1 \
      PYTHONDONTWRITEBYTECODE=1 \
      "$PYTHON_BIN" "$RANK_SCRIPT" make-diff-rank-input --repo "$DREPO" \
      --base "$1" --head "$2" --mode revisions --out "$3" > "$3.err" 2>&1 || return $?
    PY - "$3" > "$3.paths" <<'EOF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        print(json.loads(line)["path"])
EOF
  }
  compare_set() { # compare_set <label> <expected-file> <actual-file> <설명>
    if diff -u "$2" "$3" > "$3.diff" 2>&1; then
      ok "$1: $4"
    else
      bad "$1: 기대 집합과 다름 — $4"
      sed 's/^/     /' "$3.diff"
    fi
  }

  printf '%s\n' .github/workflows/ci.yml main.tf src/a.cjs src/b.cts src/c.mts src/control.py \
    | LC_ALL=C sort > "$RUN/diff1.expected"
  printf '%s\n' .github/workflows/ci.yml > "$RUN/diff2.expected"

  diff_inventory "$DBASE" "$DMID" "$RUN/diff1.inv"
  i_rc=$?
  expect_exit 0 "$i_rc" "I1 diff 인벤토리 생성 (새 확장자 커밋)"
  [ "$i_rc" != "0" ] && sed 's/^/     /' "$RUN/diff1.inv.err"
  LC_ALL=C sort "$RUN/diff1.inv" 2>/dev/null > "$RUN/diff1.inv.actual"
  compare_set "I2" "$RUN/diff1.expected" "$RUN/diff1.inv.actual" \
    "diff 인벤토리에 .cjs·.cts·.mts·.tf 와 .github/workflows/ci.yml 이 들어가고 .github/dependabot.yml 은 빠짐"

  diff_rank_input "$DBASE" "$DMID" "$RUN/diff1.rank.jsonl"
  expect_exit 0 "$?" "I3 diff 랭킹 입력 생성 (새 확장자 커밋)"
  LC_ALL=C sort "$RUN/diff1.rank.jsonl.paths" 2>/dev/null > "$RUN/diff1.rank.actual"
  compare_set "I4" "$RUN/diff1.expected" "$RUN/diff1.rank.actual" \
    "diff 랭킹 입력이 diff 인벤토리와 같은 기대 집합"

  diff_inventory "$DMID" "$DHEAD" "$RUN/diff2.inv"
  expect_exit 0 "$?" "I5 diff 인벤토리 생성 (workflow 만 바꾼 커밋)"
  LC_ALL=C sort "$RUN/diff2.inv" 2>/dev/null > "$RUN/diff2.inv.actual"
  compare_set "I6" "$RUN/diff2.expected" "$RUN/diff2.inv.actual" \
    ".github/workflows/ci.yml 만 바꾼 diff 의 인벤토리에 그 파일이 들어감"

  diff_rank_input "$DMID" "$DHEAD" "$RUN/diff2.rank.jsonl"
  expect_exit 0 "$?" "I7 diff 랭킹 입력 생성 (workflow 만 바꾼 커밋)"
  LC_ALL=C sort "$RUN/diff2.rank.jsonl.paths" 2>/dev/null > "$RUN/diff2.rank.actual"
  compare_set "I8" "$RUN/diff2.expected" "$RUN/diff2.rank.actual" \
    ".github/workflows/ci.yml 만 바꾼 diff 의 랭킹 입력에 그 파일이 들어감"

  # 커밋 3: npm 0.1.31~0.1.32 에서 추가된 확장자 .m(상류 cce82310)·.sol(ce7f75c1)·
  # .svelte(6f8b3545). .txt 는 목록에 없는 음성 대조군이다.
  # 이 세 확장자는 npm 0.1.32 사본에서만 단언한다. 매니페스트가 0.1.95 로 같아 버전으로
  # 가를 수 없으므로, 같은 릴리즈에 들어온 상류 함수 committed_diff_snapshot_digest
  # (8c78e655)의 존재로 0.1.32 사본을 알아본다.
  printf '@implementation A\n@end\n' > "$DREPO/src/d.m"
  printf 'contract C {}\n' > "$DREPO/src/e.sol"
  printf '<script>let f = 1;</script>\n' > "$DREPO/src/f.svelte"
  printf 'notes\n' > "$DREPO/notes.txt"
  dgit add -A >/dev/null && dgit commit -qm exts2 >/dev/null
  DHEAD3="$(dgit rev-parse HEAD)"
  if grep -q "def committed_diff_snapshot_digest" "$PLUGIN/scripts/workbench_target.py" 2>/dev/null; then
    printf '%s\n' src/d.m src/e.sol src/f.svelte | LC_ALL=C sort > "$RUN/diff3.expected"
    diff_inventory "$DHEAD" "$DHEAD3" "$RUN/diff3.inv"
    expect_exit 0 "$?" "I9 diff 인벤토리 생성 (0.1.31~0.1.32 확장자 커밋)"
    LC_ALL=C sort "$RUN/diff3.inv" 2>/dev/null > "$RUN/diff3.inv.actual"
    compare_set "I10" "$RUN/diff3.expected" "$RUN/diff3.inv.actual" \
      "diff 인벤토리에 .m·.sol·.svelte 가 들어가고 .txt 는 빠짐"
    diff_rank_input "$DHEAD" "$DHEAD3" "$RUN/diff3.rank.jsonl"
    expect_exit 0 "$?" "I11 diff 랭킹 입력 생성 (0.1.31~0.1.32 확장자 커밋)"
    LC_ALL=C sort "$RUN/diff3.rank.jsonl.paths" 2>/dev/null > "$RUN/diff3.rank.actual"
    compare_set "I12" "$RUN/diff3.expected" "$RUN/diff3.rank.actual" \
      "diff 랭킹 입력이 diff 인벤토리와 같은 기대 집합"
  else
    printf 'NOTE I9~I12: 이 플러그인 사본은 npm 0.1.32 이전이라 .m·.sol·.svelte 단언 대상이 아닙니다\n'
  fi
fi

# ---------------------------------------------------------------------------
# J. 줄바꿈이 든 경로 — 전체 인벤토리 하드 실패 (npm 0.1.29)
#
#   상류는 rg --null 로 받은 경로에 \n·\r 이 있으면 경로 이름 없이
#   "Repository contains a path that cannot fit in the file inventory" 로 끝낸다.
#   출력은 원자적으로 쓰므로 실패하면 in_scope_files.txt 가 생기지 않는다.
#   0.1.25 는 그 경로를 두 줄로 쪼개 exit 0 으로 끝났다(분모 오염).
#
#   J4 는 스킬 문서의 탐색 명령을 **SKILL.md 에서 그대로 꺼내** 실행한다.
#   여기서 명령을 다시 쓰면 문서가 바뀌어도 이 단언은 침묵한다.
#   J4·J5 는 우리 문서·정산기의 단언이라 상류 버전과 무관하게 통과해야 한다.
# ---------------------------------------------------------------------------
step "J. 줄바꿈이 든 경로: 전체 인벤토리 하드 실패와 탐색 명령"
SCAN_SKILL_MD="${CODEX_SECURITY_SCAN_SKILL_MD:-$WORK/../../../skills/codex-security-scan/SKILL.md}"
RECONCILE="${CODEX_SECURITY_RECONCILE:-$WORK/../../../skills/codex-security-scan/scripts/coverage_reconcile.py}"
if [ -z "$SEARCH_PATH_ENV" ]; then
  skip "J: 검색 명령(rg)을 확보하지 못해 전체 인벤토리 실패를 검증할 수 없습니다(G 블록 참조)"
else
  NREPO="$RUN/newline-repo"
  mkdir -p "$NREPO/src"
  ( cd "$NREPO" && git init -q --template= . )
  mkdir -p "$NREPO/.git/info"
  : > "$NREPO/.git/info/exclude"
  printf 'ok\n' > "$NREPO/src/ok.py"
  NL_NAME="$NREPO/src/bad"$'\n'"name.py"
  printf 'x\n' > "$NL_NAME"
  NOUT="$RUN/newline-scan/artifacts/02_discovery/in_scope_files.txt"
  mkdir -p "$(dirname "$NOUT")"
  env -i PATH="$SEARCH_PATH_ENV" HOME="$INV_HOME" GIT_CONFIG_NOSYSTEM=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    "$PYTHON_BIN" "$INV_SCRIPT" --repo "$NREPO" --scope . --out "$NOUT" \
    > "$RUN/newline.err" 2>&1
  n_rc=$?
  if [ "$n_rc" != "0" ]; then
    ok "J1: 줄바꿈 경로가 있으면 전체 인벤토리가 exit $n_rc 로 실패"
  else
    bad "J1: 줄바꿈 경로가 있는데 전체 인벤토리가 exit 0 으로 끝났습니다(분모가 쪼개진 경로로 오염됨)"
  fi
  if grep -q "Repository contains a path that cannot fit in the file inventory" "$RUN/newline.err"; then
    ok "J2: 상류 오류 문구가 스킬 문서의 인용과 일치 (경로 이름 없음)"
  else
    bad "J2: 상류 오류 문구가 다릅니다 — 스킬 문서의 인용을 갱신하세요"
    sed 's/^/     /' "$RUN/newline.err"
  fi
  if [ -e "$NOUT" ]; then
    bad "J3: 실패했는데 in_scope_files.txt 가 생겼습니다 — 정산기 안내(파일 없음 분기)의 전제가 틀립니다"
  else
    ok "J3: 실패 시 in_scope_files.txt 가 생기지 않음 (정산기는 '찾을 수 없습니다' 분기로 간다)"
  fi

  # J4. SKILL.md 의 탐색 명령. 마커 줄부터 닫는 ``` 까지 꺼내, 마커 줄의 들여쓰기만
  #     걷어 낸다(python 코드의 상대 들여쓰기를 보존). 자리표시자는 인용본으로 바꾼다.
  if [ ! -f "$SCAN_SKILL_MD" ]; then
    bad "J4: 스캔 SKILL.md 를 찾지 못했습니다: $SCAN_SKILL_MD"
  else
    PY - "$SCAN_SKILL_MD" "$NREPO" "$PYTHON_BIN" > "$RUN/finder.sh" <<'EOF'
import pathlib, re, shlex, sys
lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
start = next((i for i, l in enumerate(lines) if "newline-path-finder" in l), None)
if start is None:
    raise SystemExit(1)
indent = len(lines[start]) - len(lines[start].lstrip(" "))
body = []
for line in lines[start:]:
    if line.strip().startswith("```"):
        break
    body.append(line[indent:] if line[:indent].strip() == "" else line)
text = "\n".join(body)
text = text.replace("<repo_root>", shlex.quote(sys.argv[2]))
text = text.replace("<스코프>", ".")
text = text.replace("<python_command>", shlex.quote(sys.argv[3]))
if re.search(r"<[a-z_]+>|<스코프>", text):
    raise SystemExit(2)
print(text)
EOF
    x_rc=$?
    if [ "$x_rc" != "0" ]; then
      bad "J4: SKILL.md 에서 탐색 명령(newline-path-finder 마커)을 꺼내지 못했습니다 (exit $x_rc)"
    else
      bash "$RUN/finder.sh" > "$RUN/finder.out" 2> "$RUN/finder.err"
      f_rc=$?
      if [ "$f_rc" = "0" ] && [ "$(wc -l < "$RUN/finder.out" | tr -d ' ')" = "1" ] \
         && grep -qF 'src/bad\nname.py' "$RUN/finder.out"; then
        ok "J4: 스킬 문서의 탐색 명령이 줄바꿈 경로 1개만 출력: $(cat "$RUN/finder.out")"
      else
        bad "J4: 스킬 문서의 탐색 명령이 줄바꿈 경로를 정확히 1개 출력하지 않았습니다 (exit $f_rc)"
        sed 's/^/     /' "$RUN/finder.out" "$RUN/finder.err"
      fi
    fi
  fi

  # J5. 정산기 안내. 인벤토리가 없을 때 줄바꿈 경로를 원인 후보로 말하는가.
  #     J3 결과와 섞이지 않게 인벤토리가 확실히 없는 별도 scan-dir 을 쓴다.
  if [ ! -f "$RECONCILE" ]; then
    bad "J5: coverage_reconcile.py 를 찾지 못했습니다: $RECONCILE"
  else
    mkdir -p "$RUN/newline-scan-missing/artifacts/02_discovery"
    PY "$RECONCILE" --scan-dir "$RUN/newline-scan-missing" --source-root "$NREPO" \
      > "$RUN/reconcile-nl.out" 2> "$RUN/reconcile-nl.err"
    r_rc=$?
    if [ "$r_rc" = "3" ] && grep -q "줄바꿈" "$RUN/reconcile-nl.err"; then
      ok "J5: 인벤토리가 없으면 정산기가 exit 3 과 함께 줄바꿈 경로를 원인 후보로 안내"
    else
      bad "J5: 정산기 안내에 줄바꿈 경로 원인이 없거나 종료코드가 3 이 아닙니다 (exit $r_rc)"
      sed 's/^/     /' "$RUN/reconcile-nl.err"
    fi
  fi
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
