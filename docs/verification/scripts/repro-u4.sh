#!/usr/bin/env bash
# U4 재현 스크립트: 최소 unsealed draft 픽스처가 finalize + validate를 통과하는지 검증한다.
# 사용법: bash repro-u4.sh
set -u -o pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# cd 실패로 WORK가 비면 아래 rm -rf 가 루트 수준 경로를 지운다. set -u 는
# set-but-empty 에 발동하지 않으므로 명시적으로 가드한다.
: "${WORK:?WORK 경로 해석 실패 — 중단}"
PLUGIN="${CODEX_SECURITY_PLUGIN_DIR:-/data/workspace/codex-security/sdk/typescript/_bundled_plugin}"
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

PY() { mise exec -- python3 "$@"; }

FAILED=0
step() { printf '\n=== %s ===\n' "$1"; }
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
env -u CODEX_SECURITY_STARTED_AT mise exec -- python3 "$FINALIZE" --scan-dir "$SCAN" --source-root "$SRC"
expect_exit 2 "$?" "E finalize (실패 기대)"

printf '\n=== 결과 ===\n'
if [ "$FAILED" -eq 0 ]; then
  echo "ALL ASSERTIONS PASSED"
  exit 0
fi
echo "FAILED ASSERTIONS: $FAILED"
exit 1
