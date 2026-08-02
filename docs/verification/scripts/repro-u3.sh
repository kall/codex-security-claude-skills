#!/usr/bin/env bash
# U3 — 워크벤치 계약 실측 재현 스크립트
#
# 목적: Phase 2가 의존하는 세 가지 계약을 경험적으로 고정한다.
#   (a) working-tree-unchanged 게이트
#   (b) get-scan 계약 필드
#   (c) finalize-first 순서 (complete-scan 실패 시에도 report.md / SARIF 보존)
#
# 사용법: bash repro-u3.sh
#   플러그인 경로 재지정: CODEX_SECURITY_PLUGIN_DIR=/path/to/_bundled_plugin bash repro-u3.sh
#
# 모든 생성물은 저장소 밖 임시 디렉터리(OUT)에 쓰고 종료 시 정리한다.
# 상태 DB는 CODEX_SECURITY_STATE_DIR로 격리한다 (~/.codex 는 건드리지 않음).
# 플러그인 업데이트 후 그대로 재실행하면 계약 변화가 종료코드/stderr로 드러난다.

set -u -o pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# cd 실패 시 WORK가 빈 문자열이 되면 아래 rm -rf 가 루트 수준 경로를 지운다.
# set -u 는 set-but-empty 에 발동하지 않으므로 명시적으로 가드한다.
: "${WORK:?WORK 경로 해석 실패 — 중단}"
# 모든 생성물(임시 저장소·scan-dir·상태 DB·로그·probe 산출물)은 저장소 밖
# 임시 디렉터리에 둔다. 스크립트 위치(WORK)는 오염시키지 않는다.
OUT="$(mktemp -d)"
: "${OUT:?OUT 임시 디렉터리 생성 실패 — 중단}"
trap 'rm -rf "$OUT"' EXIT
# 플러그인 경로: 환경변수 → 이 저장소 체크아웃(스크립트 위치 기준) → npm 전역 설치본.
PLUGIN="${CODEX_SECURITY_PLUGIN_DIR:-}"
if [ -z "$PLUGIN" ]; then
  if [ -f "$WORK/../../../sdk/typescript/_bundled_plugin/.codex-plugin/plugin.json" ]; then
    PLUGIN="$(cd "$WORK/../../../sdk/typescript/_bundled_plugin" && pwd -P)"
  elif NPM_ROOT="$(npm root -g 2>/dev/null)" && \
       [ -f "$NPM_ROOT/@openai/codex-security/_bundled_plugin/.codex-plugin/plugin.json" ]; then
    PLUGIN="$NPM_ROOT/@openai/codex-security/_bundled_plugin"
  else
    echo "오류: 플러그인을 찾지 못했습니다. CODEX_SECURITY_PLUGIN_DIR=<_bundled_plugin 경로> 를 지정하세요." >&2
    exit 1
  fi
fi
SCRIPTS="$PLUGIN/scripts"
# Python: PYTHON 환경변수 → python3 → python. 버전 매니저 환경이면
#   PYTHON="$(mise which python3)" bash repro-u3.sh
PY=("${PYTHON:-$(command -v python3 || command -v python)}")
: "${PY[0]:?Python 3.10+ 인터프리터를 찾지 못했습니다. PYTHON=<경로> 로 지정하세요.}"

export CODEX_SECURITY_STATE_DIR="$OUT/state"
# 플러그인 디렉터리에 __pycache__ 를 남기지 않는다 (레포는 읽기 전용으로 유지).
export PYTHONDONTWRITEBYTECODE=1
LOG="$OUT/evidence.log"

REPO="$OUT/repo"
SCAN="$OUT/scan"       # 정상 경로 시나리오용 scan-dir
SCAN2="$OUT/scan2"     # 계약 불일치 거부 시나리오용 scan-dir
DRAFT_PY="$OUT/make-draft.py"

: > "$LOG"

say() { printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }

# 명령 실행 + 종료코드/stderr 기록. $1 = 시나리오 라벨, 나머지 = 명령
run() {
  local label="$1"; shift
  printf '\n--- [%s]\n$ %s\n' "$label" "$*" >> "$LOG"
  "$@" > "$OUT/.stdout" 2> "$OUT/.stderr"
  LAST_CODE=$?
  printf 'exit=%d\n' "$LAST_CODE" >> "$LOG"
  printf 'stdout: %s\n' "$(head -c 2000 "$OUT/.stdout")" >> "$LOG"
  printf 'stderr: %s\n' "$(head -c 2000 "$OUT/.stderr")" >> "$LOG"
  printf '[%s] exit=%d\n' "$label" "$LAST_CODE"
  if [ -s "$OUT/.stderr" ]; then printf '  stderr: '; head -c 400 "$OUT/.stderr"; echo; fi
  return 0
}

wb() { "${PY[@]}" "$SCRIPTS/workbench_db.py" "$@"; }
sha() { "${PY[@]}" -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }
recipe() {
  "${PY[@]}" -c 'import json,sys; print(json.dumps({"repository": sys.argv[1], "mode": "standard", "config": {}, "target": {"kind": "repository", "paths": []}}))' "$1"
}

# ---------------------------------------------------------------------------
# 초안(draft) 생성기를 독립 파일로 내보낸다.
# 사용법: python3 make-draft.py <scan-dir> <get-scan.json> <plugin-dir> [mismatch-field]
# get-scan 이 돌려준 contract 값만으로 초안 3종(manifest/findings/coverage)을 만든다.
# ---------------------------------------------------------------------------
cat > "$DRAFT_PY" <<'DRAFT_EOF'
"""get-scan 계약에서 관측된 값만으로 미봉인(unsealed) 초안 3종을 작성한다."""

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

scan_dir = Path(sys.argv[1])
doc = json.load(open(sys.argv[2]))
plugin_dir = Path(sys.argv[3])
mismatch = sys.argv[4] if len(sys.argv) > 4 else ""

scan = doc["scan"]
contract = scan["contract"]
target_contract = contract["target"]
scope_contract = contract["scope"]
plugin_version = json.loads((plugin_dir / ".codex-plugin" / "plugin.json").read_text())["version"]

# target.kind 는 contract.target.allowedKinds 안에서만 골라야 한다.
target_kind = target_contract["allowedKinds"][0]
target = {
    "kind": target_kind,
    "targetId": target_contract["targetId"],
    "displayName": target_contract["displayName"],
}
if target_kind in ("git_revision", "git_worktree"):
    target["revision"] = scan["targetRevision"]
if "requiredSnapshotDigest" in target_contract:
    target["snapshotDigest"] = target_contract["requiredSnapshotDigest"]

include_paths = scope_contract.get("requiredIncludePaths", [scope_contract["requestedPath"]])
exclude_paths = scope_contract["requiredExcludePaths"]

# coverage.mode 는 get-scan 이 직접 노출하지 않으므로 workbench_db.expected_coverage_mode()
# 규칙을 그대로 재현한다.
recipe = doc.get("recipe") or {}
recipe_kind = (recipe.get("target") or {}).get("kind")
if scan["mode"] == "diff":
    coverage_mode = {
        "commit": "commit",
        "range": "branch_diff",
        "working_tree": "working_tree",
    }[scan["diffTarget"]["kind"]]
elif scan["scope"] != "." or recipe_kind == "paths":
    coverage_mode = "scoped_path"
elif scan["mode"] == "deep":
    coverage_mode = "deep_repository"
else:
    coverage_mode = "repository"

now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

# 계약 위반 초안을 만들기 위한 의도적 변조 지점
if mismatch == "targetId":
    target["targetId"] = "target_sha256_" + "0" * 64
elif mismatch == "displayName":
    target["displayName"] = "not-the-repo"
elif mismatch == "revision":
    target["revision"] = "0" * 40
elif mismatch == "kind":
    target = {
        "kind": "directory_snapshot",
        "targetId": target_contract["targetId"],
        "displayName": target_contract["displayName"],
        "snapshotDigest": "codex-security-directory/v1:sha256:" + "0" * 64,
    }
elif mismatch == "includePaths":
    include_paths = ["src"]
elif mismatch == "producer":
    plugin_version = "0.0.0-not-the-plugin"
elif mismatch == "coverageMode":
    coverage_mode = "scoped_path"
elif mismatch == "scanId":
    scan = dict(scan, scanId="00000000-0000-4000-8000-000000000000")

manifest = {
    "documentType": "codex-security.scan-manifest",
    "schemaVersion": "1.0",
    "scan": {
        "id": scan["scanId"],
        "status": "completed",
        "startedAt": now,
        "completedAt": now,
        "producer": {"name": "codex-security-plugin", "version": plugin_version},
        "target": target,
        "scope": {"includePaths": include_paths, "excludePaths": exclude_paths},
        "findingsRef": "findings.json",
        "coverageRef": "coverage.json",
    },
}

# findingId / occurrenceId / fingerprints 는 finalize 가 파생시키므로 초안에서 생략한다.
findings = {
    "documentType": "codex-security.findings",
    "schemaVersion": "1.0",
    "scanId": scan["scanId"],
    "findings": [
        {
            "ruleId": "path-traversal.unvalidated-read",
            "title": "Unvalidated path reaches a filesystem read",
            "summary": "An attacker-controlled path reaches a filesystem read without containment validation.",
            "remediation": "Normalize the destination and reject paths escaping the root.",
            "severity": {"level": "high"},
            "confidence": {"level": "high", "rationale": "Direct source-to-sink trace."},
            "identity": {"anchor": "unvalidated-path-read"},
            "taxonomy": {"category": "path-traversal", "cwe": ["CWE-22"]},
            "locations": [
                {"path": "src/extract.py", "role": "sink", "startLine": 1, "endLine": 2}
            ],
            "provenance": {"source": "local_plugin"},
            "extensions": {},
            "attackPath": None,
            "validation": None,
        }
    ],
}

coverage = {
    "documentType": "codex-security.coverage",
    "schemaVersion": "1.0",
    "scanId": scan["scanId"],
    "mode": coverage_mode,
    "completeness": "complete",
    "inventoryStrategy": "repository",
    "includePaths": include_paths,
    "excludePaths": exclude_paths,
    "explicitExclusions": [],
    "deferred": [],
    "surfaces": [
        {
            "id": "surface_filesystem_read",
            "label": "Filesystem read",
            "disposition": "reported",
            "receiptRefs": [],
        }
    ],
}


def write(name, payload):
    (scan_dir / name).write_text(
        json.dumps(payload, allow_nan=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


write("scan-manifest.json", manifest)
write("findings.json", findings)
write("coverage.json", coverage)
print(f"draft -> {scan_dir} (coverage.mode={coverage_mode}, mismatch={mismatch or 'none'})")
DRAFT_EOF

make_draft() { "${PY[@]}" "$DRAFT_PY" "$@"; }

# ---------------------------------------------------------------------------
say "0. 작업 영역 초기화 + 합성 git 저장소 생성"
rm -rf "$REPO" "$SCAN" "$SCAN2" "$OUT/state" "$OUT"/scan3 "$OUT"/probe-*
mkdir -p "$REPO" "$SCAN" "$SCAN2" "$OUT/state"
(
  cd "$REPO"
  # -b 플래그 대신 init.defaultBranch 설정으로 결정론적 브랜치명을 준다.
  git -c init.defaultBranch=main init -q .
  git config user.email u3@example.com
  git config user.name u3
  mkdir -p src
  printf 'def extract(path):\n    return open(path).read()\n' > src/extract.py
  printf '# u3 synthetic repo\n' > README.md
  git add -A
  git commit -qm "initial"
)
echo "repo HEAD = $(git -C "$REPO" rev-parse HEAD)" | tee -a "$LOG"

# ---------------------------------------------------------------------------
say "S1. register-cli-scan (claim token 없이) — 정상 등록"
run "S1 register-cli-scan" wb register-cli-scan \
  --scan-dir "$SCAN" --repository "$REPO" --recipe-json "$(recipe "$REPO")"
cp "$OUT/.stdout" "$OUT/register.json"
SCAN_ID="$("${PY[@]}" -c "import json;print(json.load(open('$OUT/register.json'))['scanId'])")"
echo "register-cli-scan stdout = $(cat "$OUT/register.json")" | tee -a "$LOG"

say "S2. register-cli-scan --claim-token — do-not-pass 규약 (argparse 거부 기대: exit 2)"
run "S2 register-cli-scan --claim-token" wb register-cli-scan \
  --scan-dir "$SCAN2" --repository "$REPO" --recipe-json "$(recipe "$REPO")" \
  --claim-token deadbeef

say "S3. get-scan — 계약 필드 채집"
run "S3 get-scan" wb get-scan --scan-id "$SCAN_ID"
cp "$OUT/.stdout" "$OUT/get-scan.json"
"${PY[@]}" - "$OUT/get-scan.json" <<'PYEOF' | tee -a "$LOG"
import json, sys
doc = json.load(open(sys.argv[1]))
scan = doc["scan"]
print(json.dumps({
    "scanId": scan["scanId"],
    "scanDir": scan["scanDir"],
    "mode": scan["mode"],
    "scope": scan["scope"],
    "targetPath": scan["targetPath"],
    "targetRevision": scan["targetRevision"],
    "handoffStatus": scan["handoffStatus"],
    "contract": scan["contract"],
    "recipe": doc.get("recipe"),
}, indent=2, sort_keys=True))
PYEOF

say "S4. 초안 작성 → finalize_scan_contract.py (seal 성공 기대) → validate_scan_contract.py"
make_draft "$SCAN" "$OUT/get-scan.json" "$PLUGIN" | tee -a "$LOG"
run "S4 finalize (seal)" "${PY[@]}" "$SCRIPTS/finalize_scan_contract.py" --scan-dir "$SCAN"
run "S4 validate_scan_contract" "${PY[@]}" "$SCRIPTS/validate_scan_contract.py" --scan-dir "$SCAN"
echo "scan-dir 내용:" | tee -a "$LOG"
(cd "$SCAN" && find . -type f | sort) | tee -a "$LOG"
# finalize-first 산출물이 실제로 존재해야 보존 검증이 의미 있다. 없으면 S4가
# 실패한 것이므로 여기서 즉시 중단한다 — 그러지 않으면 아래 sha 비교가
# "" = "" 로 통과해 계약 위반이 보이지 않는다.
for f in "$SCAN/report.md" "$SCAN/exports/results.sarif"; do
  [ -s "$f" ] || { echo "FAIL S4 산출물 없음: $f" | tee -a "$LOG"; exit 1; }
done
REPORT_SHA_BEFORE="$(sha "$SCAN/report.md")"
SARIF_SHA_BEFORE="$(sha "$SCAN/exports/results.sarif")"
echo "report.md sha256     = $REPORT_SHA_BEFORE" | tee -a "$LOG"
echo "results.sarif sha256 = $SARIF_SHA_BEFORE" | tee -a "$LOG"

# ---------------------------------------------------------------------------
say "S5. 저장소 1줄 수정 후 complete-scan — working-tree 게이트 실패 기대 (exit 1)"
printf 'def extract(path):\n    return open(path).read()  # u3 modification\n' > "$REPO/src/extract.py"
git -C "$REPO" status --porcelain | tee -a "$LOG"
run "S5 complete-scan (modified repo)" wb complete-scan --scan-id "$SCAN_ID"
S5_CODE=$LAST_CODE

echo "-- finalize-first 아티팩트 보존 검증 --" | tee -a "$LOG"
if [ -n "$REPORT_SHA_BEFORE" ] && [ "$REPORT_SHA_BEFORE" = "$(sha "$SCAN/report.md")" ]; then
  echo "report.md     : 무변경 OK" | tee -a "$LOG"; else echo "report.md     : 변경됨/소실 FAIL" | tee -a "$LOG"; fi
if [ -n "$SARIF_SHA_BEFORE" ] && [ "$SARIF_SHA_BEFORE" = "$(sha "$SCAN/exports/results.sarif")" ]; then
  echo "results.sarif : 무변경 OK" | tee -a "$LOG"; else echo "results.sarif : 변경됨/소실 FAIL" | tee -a "$LOG"; fi
run "S5 validate_scan_contract (게이트 실패 후)" "${PY[@]}" "$SCRIPTS/validate_scan_contract.py" --scan-dir "$SCAN"

say "S6. 수정 되돌리고 complete-scan 재시도 — 성공 기대 (exit 0)"
git -C "$REPO" checkout -- src/extract.py
run "S6 complete-scan (unmodified repo)" wb complete-scan --scan-id "$SCAN_ID"
S6_CODE=$LAST_CODE
"${PY[@]}" -c "
import json
s=json.load(open('$OUT/.stdout'))['scan']
print(json.dumps({'scanId':s['scanId'],'status':s['progress']['status'],'phase':s['progress']['phase'],
                  'findingCount':s['findingCount'],'reportAvailable':s['reportAvailable'],
                  'artifacts':sorted(s['artifacts'])},indent=2))
" 2>/dev/null | tee -a "$LOG"
echo "-- 완료 후 초안 자기 타임스탬프 보존 여부 (finalize-first 특권) --" | tee -a "$LOG"
"${PY[@]}" -c "
import json,sqlite3
s=json.load(open('$SCAN/scan-manifest.json'))['scan']
row=sqlite3.connect('$OUT/state/workbench.sqlite3').execute(
    'SELECT started_at, completed_at FROM scans WHERE id=?', ('$SCAN_ID',)).fetchone()
print('manifest startedAt/completedAt/sealedAt =', s['startedAt'], s['completedAt'], s['sealedAt'])
print('DB       started_at/completed_at        =', row[0], row[1])
print('=> 봉인 초안의 타임스탬프가 DB 값으로 덮이지 않음:', s['startedAt'] != row[0])
" | tee -a "$LOG"

say "S6b. 상태 DB 확인 (list-scans + 직접 SQLite 조회)"
run "S6b list-scans --status complete" wb list-scans --status complete
"${PY[@]}" -c "
import sqlite3
c=sqlite3.connect('$OUT/state/workbench.sqlite3'); c.row_factory=sqlite3.Row
for r in c.execute('SELECT id, status, phase, seal_manifest_digest, recipe_json IS NOT NULL AS cli_scan FROM scans ORDER BY created_at'):
    print(dict(r))
print('scan_artifacts kinds:', sorted(r[0] for r in c.execute('SELECT DISTINCT kind FROM scan_artifacts')))
print('finding_occurrences:', c.execute('SELECT COUNT(*) FROM finding_occurrences').fetchone()[0])
" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# 계약 위반 초안 거부 프로브: 필드별로 새 scan 을 등록해 독립적으로 검증한다.
# probe <label> <mismatch-field> <seal:yes|no>
probe() {
  local label="$1" mismatch="$2" seal="$3"
  local dir="$OUT/probe-$label"
  rm -rf "$dir"; mkdir -p "$dir"
  local out sid
  out="$(wb register-cli-scan --scan-dir "$dir" --repository "$REPO" --recipe-json "$(recipe "$REPO")")"
  sid="$("${PY[@]}" -c "import json,sys;print(json.loads(sys.argv[1])['scanId'])" "$out")"
  wb get-scan --scan-id "$sid" > "$dir.get.json"
  make_draft "$dir" "$dir.get.json" "$PLUGIN" "$mismatch" > /dev/null
  if [ "$seal" = yes ]; then
    "${PY[@]}" "$SCRIPTS/finalize_scan_contract.py" --scan-dir "$dir" > /dev/null 2> "$dir.seal.err"
    printf '  [%s] finalize(seal) exit=%d %s\n' "$label" "$?" "$(head -c 200 "$dir.seal.err")" | tee -a "$LOG"
  fi
  wb complete-scan --scan-id "$sid" > /dev/null 2> "$dir.err"
  printf '[probe %-22s mismatch=%-12s seal=%-3s] complete-scan exit=%d stderr=%s\n' \
    "$label" "${mismatch:-none}" "$seal" "$?" "$(head -c 300 "$dir.err")" | tee -a "$LOG"
  if [ -f "$dir/scan-manifest.json" ]; then
    "${PY[@]}" -c "
import json,sys
s=json.load(open(sys.argv[1]))['scan']
print('   -> 최종 manifest: targetId=%s... producer=%s includePaths=%s' % (
    s['target']['targetId'][:24], s['producer']['version'], s['scope']['includePaths']))
" "$dir/scan-manifest.json" | tee -a "$LOG"
  fi
}

say "S7. 봉인 초안의 계약 위반 → complete-scan 거부 기대 (exit 1)"
probe sealed-targetId    targetId     yes
probe sealed-producer    producer     yes
probe sealed-includePath includePaths yes
probe sealed-coverageMode coverageMode yes
probe sealed-targetKind  kind         yes
probe sealed-revision    revision     yes

say "S8. 미봉인 초안 (finalize-first 생략) → 워크벤치가 값을 덮어써 통과함 (대조군)"
probe unsealed-targetId  targetId     no
probe unsealed-covMode   coverageMode no

say "S9. complete-scan --claim-token — do-not-pass 규약 (exit 1 기대)"
rm -rf "$OUT/scan3"; mkdir -p "$OUT/scan3"
run "S9 register-cli-scan (3rd)" wb register-cli-scan \
  --scan-dir "$OUT/scan3" --repository "$REPO" --recipe-json "$(recipe "$REPO")"
SCAN_ID3="$("${PY[@]}" -c "import json;print(json.load(open('$OUT/.stdout'))['scanId'])")"
run "S9 get-scan (3rd)" wb get-scan --scan-id "$SCAN_ID3"
cp "$OUT/.stdout" "$OUT/get-scan3.json"
make_draft "$OUT/scan3" "$OUT/get-scan3.json" "$PLUGIN" | tee -a "$LOG"
run "S9 finalize (seal, 3rd)" "${PY[@]}" "$SCRIPTS/finalize_scan_contract.py" --scan-dir "$OUT/scan3"
run "S9 complete-scan --claim-token" wb complete-scan --scan-id "$SCAN_ID3" \
  --claim-token 00000000-0000-4000-8000-000000000000
S9_CODE=$LAST_CODE
run "S9b complete-scan (토큰 없이 재시도)" wb complete-scan --scan-id "$SCAN_ID3"
S9B_CODE=$LAST_CODE

# ---------------------------------------------------------------------------
say "요약 (관측 종료코드 / 기대값)"
printf 'S5  complete-scan (repo 수정됨)     exit=%s  기대 1 (working-tree 게이트)\n' "$S5_CODE" | tee -a "$LOG"
printf 'S6  complete-scan (repo 무수정)     exit=%s  기대 0\n' "$S6_CODE" | tee -a "$LOG"
printf 'S9  complete-scan --claim-token     exit=%s  기대 1\n' "$S9_CODE" | tee -a "$LOG"
printf 'S9b complete-scan (토큰 없이)       exit=%s  기대 0\n' "$S9B_CODE" | tee -a "$LOG"
echo "전체 증거 로그: $LOG"
