#!/usr/bin/env bash
#
# 이 저장소의 보안 스캔 스킬들(SKILL.md 를 가진 skills/ 하위 디렉터리 전부)을
# Claude Code 전역 스킬 디렉터리에 설치한다.
#   - codex-security-scan, codex-security-validate, codex-security-patch,
#     codex-security-diff-scan 등 앞으로 추가되는 스킬도 자동 포함된다.
#
# 사용법:
#   bash skills/install.sh [--link|--copy] [--force] [스킬이름 …]
#
#   --link    (기본) 심볼릭 링크로 설치. 저장소 수정이 즉시 반영되므로 개발용.
#   --copy    실제 복사본으로 설치. 저장소와 분리되므로 배포/배포본 검증용.
#   --force   대상 경로가 이미 있으면 덮어쓴다. 없으면 설치를 거부한다.
#   스킬이름   지정하면 그 스킬만 설치한다(기본: SKILL.md 를 가진 모든 스킬).
#
# 환경변수:
#   CLAUDE_SKILLS_DIR   설치 위치의 상위 디렉터리 (기본: $HOME/.claude/skills)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

MODE="link"
FORCE="false"
CHECK="false"
CHECK_ONLY="false"
REQUESTED=()

usage() {
  cat <<'EOF'
사용법: bash skills/install.sh [--link|--copy] [--force] [--check|--check-only] [스킬이름 …]

  --link    (기본) 심볼릭 링크로 설치한다. 저장소 수정이 즉시 반영된다 (개발용).
  --copy    실제 복사본으로 설치한다 (배포용).
  --force   대상 경로가 이미 있을 때 덮어쓴다.
  --check   설치 후 실행 환경을 프로브한다(번들 플러그인·Python·검색 명령·Node·
            SECURITY.md 헬퍼·게이트 사본).
            종료코드 0=정상 / 2=부분 정상(ripgrep 미확보, 전체 스캔 불가) / 1=실패.
            플러그인이 없으면 설치 명령을 안내한다. 자동 설치는 하지 않는다.
  --check-only  설치하지 않고 프로브만 수행한다.
  -h, --help  이 도움말을 출력한다.

환경변수:
  CLAUDE_SKILLS_DIR   설치 위치의 상위 디렉터리 (기본: $HOME/.claude/skills)
  PYTHON              프로브에 쓸 Python 인터프리터 (기본: python3 → python)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --link) MODE="link" ;;
    --copy) MODE="copy" ;;
    --force) FORCE="true" ;;
    --check) CHECK="true" ;;
    --check-only) CHECK="true"; CHECK_ONLY="true" ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "오류: 알 수 없는 인자 '$1'" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
    *)
      REQUESTED+=("$1")
      ;;
  esac
  shift
done

SKILLS_ROOT="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
if [ -z "$SKILLS_ROOT" ]; then
  echo "오류: CLAUDE_SKILLS_DIR 이 비어 있습니다." >&2
  exit 1
fi

# 설치 대상 스킬 목록: 인자로 지정되면 그것만, 아니면 SKILL.md 를 가진 모든 하위 디렉터리.
SKILL_NAMES=()
if [ "${#REQUESTED[@]}" -gt 0 ]; then
  SKILL_NAMES=("${REQUESTED[@]}")
else
  for skill_md in "${SCRIPT_DIR}"/*/SKILL.md; do
    [ -f "$skill_md" ] || continue
    SKILL_NAMES+=("$(basename "$(dirname "$skill_md")")")
  done
fi

if [ "${#SKILL_NAMES[@]}" -eq 0 ]; then
  echo "오류: 설치할 스킬(SKILL.md 를 가진 디렉터리)을 찾지 못했습니다: ${SCRIPT_DIR}" >&2
  exit 1
fi

mkdir -p -- "$SKILLS_ROOT"

install_one() {
  local name="$1"
  local source_dir="${SCRIPT_DIR}/${name}"
  local target_dir="${SKILLS_ROOT}/${name}"

  if [ ! -f "${source_dir}/SKILL.md" ]; then
    echo "오류: 스킬 '${name}' 에 SKILL.md 가 없습니다: ${source_dir}" >&2
    return 1
  fi
  # rm -rf 대상이 반드시 우리가 만든 스킬 경로인지 확인한다.
  if [ "$(basename "$target_dir")" != "$name" ]; then
    echo "오류: 설치 대상 경로가 올바르지 않습니다: ${target_dir}" >&2
    return 1
  fi

  if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
    if [ "$FORCE" != "true" ]; then
      echo "경고: 설치 대상이 이미 존재합니다(건너뜀): ${target_dir}" >&2
      if [ -L "$target_dir" ]; then
        echo "      현재 상태: 심볼릭 링크 -> $(readlink "$target_dir")" >&2
      else
        echo "      현재 상태: 일반 디렉터리/파일" >&2
      fi
      echo "      덮어쓰려면 --force 를 함께 지정하세요." >&2
      return 1
    fi
    echo "기존 설치본을 제거합니다: ${target_dir}"
    rm -rf -- "$target_dir"
  fi

  case "$MODE" in
    link) ln -s -- "$source_dir" "$target_dir" ;;
    copy) cp -R -- "$source_dir" "$target_dir" ;;
  esac
  echo "  설치: ${name} -> ${target_dir} (${MODE})"
}

# ---------------------------------------------------------------------------
# 실행 환경 프로브 (--check / --check-only)
#
# 무엇을 확인하는가:
#   1. Python 3.10+ (bootstrap.py 가 스스로 판정한다)
#   2. 신뢰 가능한 codex-security 번들 플러그인 (없으면 설치 명령 안내 — 자동 설치는 하지 않음)
#   3. 검색 명령(ripgrep) — 저장소 전체 스캔·deep-lite 의 전제. 미확보는 exit 2(부분 정상)
#   4. 플러그인 사본의 워킹트리 게이트 처리(하드 실패 / 경고) — 같은 버전에서도 다르다
#   5. 신뢰 Node 와 SECURITY.md 헬퍼 가용성(P6-KTD6). 불가여도 종료코드는 바꾸지 않는다 —
#      전체 스캔은 정책 해결을 건너뛰고 계속하기 때문이다(P6-KTD7). 사유만 보고한다.
#   6. 후보 정규화 경로(Python 스크립트 또는 npm 0.2.0 의 Node 헬퍼). 불가이면 "부분 정상"으로
#      표시한다 — 전체·diff·deep 스캔이 0단계에서 멈추기 때문이다.
#   7. 상류 `codex-security skills add`(npm 0.2.0)가 같은 이름의 설치본을 덮어썼는지. 덮어쓰였으면
#      "부분 정상"으로 표시한다(check_upstream_overwrite).
# 자동 설치를 하지 않는 이유: 전역 npm 환경 변경은 사용자 결정이다.
# ---------------------------------------------------------------------------
run_check() {
  local bootstrap="$1"   # 프로브에 쓸 bootstrap.py 경로
  local python_bin probe_target boot_json rc

  python_bin="${PYTHON:-$(command -v python3 || command -v python || true)}"
  if [ -z "$python_bin" ]; then
    echo "프로브 실패: Python 을 찾지 못했습니다(python3/python). PYTHON=<경로> 로 지정하세요." >&2
    return 1
  fi

  # 대상 저장소는 신뢰 경계 계산에만 쓰이므로 빈 임시 디렉터리로 프로브한다.
  probe_target="$(mktemp -d)" || return 1
  boot_json="$(mktemp)" || { rm -rf -- "$probe_target"; return 1; }
  # 홑따옴표 트랩이어야 한다. 큰따옴표로 두면 설정 시점에 경로가 트랩 문자열로
  # 확장돼, TMPDIR 에 `'` 가 들어가면 정리 명령이 깨지고 임의 명령이 주입된다
  # (합성 TMPDIR 로 재현 확인). bash RETURN 트랩은 함수 local 을 그대로 본다.
  # shellcheck disable=SC2016
  # `|| true` 가 필요하다. rm 이 실패하면 set -e 가 트랩 안에서 발동해 셸이 1 로
  # 끝나고 함수의 반환값(0/2)이 사라진다 — 정리 실패가 판정을 삼키면 안 된다.
  # 다만 stderr 는 지우지 않는다. 반환값 보호에 필요한 것은 `|| true` 뿐이고,
  # 2>/dev/null 까지 붙이면 임시 디렉터리가 조용히 누출된다.
  trap 'rm -rf -- "$probe_target" "$boot_json" || true' RETURN

  # `|| rc=$?` 로 감싸야 한다. set -e 아래에서 맨몸 호출이 실패하면 rc 대입 다음
  # 진단 블록에 도달하지 못하고, RETURN 트랩도 실행되지 않아 프로브용 임시
  # 디렉터리가 매 실패마다 누출된다(--check-only 경로에서 재현 확인).
  rc=0
  PYTHONDONTWRITEBYTECODE=1 "$python_bin" "$bootstrap" \
    --target-repo "$probe_target" --no-scan-dir --probe-search > "$boot_json" 2>/dev/null \
    || rc=$?

  # 이 호출도 `|| return` 으로 감싼다. set -e 아래 맨몸 호출이 실패하면 RETURN
  # 트랩이 실행되지 않아 프로브용 임시 파일이 누출된다(실측: 실패마다 2건).
  local report_rc=0
  PYTHONDONTWRITEBYTECODE=1 "$python_bin" - "$boot_json" "$rc" <<'PYEOF' || report_rc=$?
import json, pathlib, sys

boot_path, rc = pathlib.Path(sys.argv[1]), int(sys.argv[2])
try:
    data = json.loads(boot_path.read_text() or "{}")
except json.JSONDecodeError:
    data = {}

if rc != 0 or not data.get("ok"):
    stage = data.get("stage", "unknown")
    print(f"\n[프로브] 실패 (stage={stage})")
    error = data.get("error")
    if error:
        print(f"  {error}")
    if stage == "pluginRoot":
        print("\n  번들 플러그인을 설치한 뒤 다시 확인하세요(자동 설치는 하지 않습니다):")
        print("    npm install -g @openai/codex-security          # Node 22+ 필요")
        print("    # 또는 이미 사본이 있으면")
        print("    export CODEX_SECURITY_PLUGIN_ROOT=<_bundled_plugin 경로>")
    raise SystemExit(1)

python_info = data.get("python") or {}
plugin_root = pathlib.Path(data["pluginRoot"])
search = data.get("searchCommand")
normalizer = data.get("candidateNormalizer") or {}
inventory = data.get("inScopeInventory") or {}
# 저장소 전체 스캔과 deep-lite 는 검색 명령 없이는 시작조차 못 한다. 후보 정규화가
# 불가하면(npm 0.2.0 소스 체크아웃) 전체·diff·deep 스캔이 0단계에서 멈춘다. 인벤토리
# 도우미가 불가해도(npm 0.7.0 소스 체크아웃) 마찬가지다. 그 상태를 "실행 환경 정상"으로
# 표시하면 주력 스킬 불가와 전부 정상이 같은 신호가 된다.
full_ok = bool(search) and bool(normalizer.get("available")) and bool(inventory.get("available"))
print("\n[프로브] 실행 환경 정상" if full_ok else "\n[프로브] 부분 정상 — 저장소 전체 스캔 불가")
print(f"  플러그인 : {plugin_root}")
print(f"  버전     : 매니페스트 {data.get('pluginVersion')} · npm {data.get('npmVersion') or '알 수 없음'}"
      f" (출처: {data.get('pluginSource')})")
print(f"  Python   : {python_info.get('path')} ({python_info.get('version')})")

# 검색 명령(ripgrep). 저장소 전체 스캔·deep-lite 는 인벤토리를 상류 도우미에 위임하므로
# 필수다. diff 스캔과 나머지 스킬(validate/patch/verify-fix/scan-match)은 없어도 동작한다.
if search:
    origin = {
        "trusted-executable": "PATH의 ripgrep",
        "claude-shim": "Claude Code 내장 ripgrep(심링크)",
    }.get(search.get("source"), search.get("source"))
    print(f"  검색     : {search.get('version')} — {origin}")
else:
    detail = (data.get("diagnostics") or {}).get("searchError") or ""
    print("  검색     : 확보 실패 — 저장소 전체 스캔을 시작할 수 없습니다")
    print("             ripgrep 을 설치하세요(apt/brew/cargo install ripgrep).")
    if detail:
        print(f"             {detail.splitlines()[0]}")

# 후보 정규화(npm 0.2.0 부터 Node 헬퍼). 불가이면 스캔 스킬 3종이 시작하지 않는다.
if normalizer.get("available"):
    kind = {"python": "Python 스크립트", "node-helper": "Node 헬퍼"}.get(
        normalizer.get("kind"), normalizer.get("kind"))
    print(f"  정규화   : {kind}")
else:
    print("  정규화   : 사용 불가 — 전체·diff·deep 스캔을 시작할 수 없습니다")
    print(f"             {normalizer.get('reason') or 'candidateNormalizer 없음'}")

# 인벤토리 도우미(npm 0.7.0 부터 Node 헬퍼, 상류 #1432). 불가이면 전체·diff·deep 스캔이 시작하지 않는다.
if inventory.get("available"):
    kind = {"python": "Python 스크립트", "node-helper": "Node 헬퍼"}.get(
        inventory.get("kind"), inventory.get("kind"))
    print(f"  인벤토리 : {kind}")
else:
    print("  인벤토리 : 사용 불가 — 전체·diff·deep 스캔을 시작할 수 없습니다")
    print(f"             {inventory.get('reason') or 'inScopeInventory 없음'}")

# 작업 목록 도우미(npm 0.3.0 부터 Node 헬퍼). scoped-path 바인딩과 diff 리뷰 입력 복사에 쓴다.
# 불가여도 저장소 전체 스캔은 영향이 없으므로 종료코드를 바꾸지 않는다. 못 쓰는 경로만 알린다.
for key, label, consumer in (
    ("bindRepoScopes", "경로 바인딩", "scoped-path 스캔을"),
    ("copyDeepReviewInput", "diff 입력 ", "diff 스캔을"),
    ("diffRankInput", "diff 목록 ", "diff 스캔을"),
):
    helper_info = data.get(key) or {}
    if helper_info.get("available"):
        kind = {"python": "Python 하위 명령", "node-helper": "Node 헬퍼"}.get(
            helper_info.get("kind"), helper_info.get("kind"))
        print(f"  {label}: {kind}")
    else:
        print(f"  {label}: 사용 불가 — {consumer} 시작할 수 없습니다")
        print(f"             {helper_info.get('reason') or key + ' 없음'}")

# Node 와 SECURITY.md 헬퍼(P6-KTD6). 불가여도 전체 스캔은 정책 없이 진행하므로
# 종료코드를 바꾸지 않는다(P6-KTD7). 원인만 알린다.
node = data.get("node") or {}
helper = data.get("securityMdHelper") or {}
if node:
    print(f"  Node     : {node.get('path')} ({node.get('version')}, 출처: {node.get('source')})")
else:
    print("  Node     : 신뢰할 수 있는 node 없음")
if helper.get("available"):
    print("  정책 헬퍼: 사용 가능 — 전체 스캔이 SECURITY.md 정책을 해결합니다")
else:
    print("  정책 헬퍼: 사용 불가 — 전체 스캔은 SECURITY.md 정책 해결을 건너뛰고 계속합니다")
    reason = helper.get("reason")
    if reason:
        print(f"             {reason}")

# 신규 스킬 2종의 전제(P6-KTD6). 종료코드는 바꾸지 않는다 — 주력 스캔 스킬과 무관하게
# 두 스킬만 쓸 수 없는 상태이므로, 어느 스킬을 못 쓰는지와 그 이유만 알린다.
#   codex-security-policy            : Node + SECURITY.md 헬퍼 + npm dist/ 가 모두 필요
#   codex-security-classify-severity : Node + npm dist/ 가 필요
sdk = data.get("sdk") or {}
sdk_reason = sdk.get("reason") or "npm 번들 dist/ 없음"
if not node:
    no_node = "신뢰할 수 있는 node 없음"
    print(f"  경고     : codex-security-policy 사용 불가 — {no_node}")
    print(f"  경고     : codex-security-classify-severity 사용 불가 — {no_node}")
else:
    if not helper.get("available"):
        print("  경고     : codex-security-policy 사용 불가 — "
              f"{helper.get('reason') or 'SECURITY.md 헬퍼 없음'}")
    elif not sdk.get("dist"):
        print(f"  경고     : codex-security-policy 사용 불가 — {sdk_reason}")
    if not sdk.get("dist"):
        print(f"  경고     : codex-security-classify-severity 사용 불가 — {sdk_reason}")

# 같은 pluginVersion 에서도 워킹트리 게이트 처리가 다르다 — 심볼 존재로 판별한다.
db = plugin_root / "scripts" / "workbench_db.py"
try:
    hard_gate = "def require_unchanged_target" in db.read_text(errors="replace")
except OSError:
    print("  게이트    : 판별 불가(workbench_db.py 를 읽을 수 없음)")
else:
    if hard_gate:
        print("  게이트    : 하드 실패 사본 — 스캔 중 저장소가 변경되면 이력 종결이 실패합니다")
    else:
        print("  게이트    : 경고 사본 — 변경돼도 종결은 성공하고 경고만 남습니다"
              "(결과는 등록 시점 스냅샷 기준)")
print("\n  스캔 정확도를 위해 스캔 전 commit/stash 를 권장합니다.")

# 부분 정상은 0 이 아니라 2 로 알린다(회귀 스크립트의 3값 규약과 같은 뜻) —
# CI 나 릴리즈 검증이 종료코드만 보고 rg 부재·정규화 불가를 놓치지 않게 한다.
if not full_ok:
    raise SystemExit(2)
PYEOF
  return "$report_rc"
}

BOOTSTRAP_PATH="${SCRIPT_DIR}/codex-security-scan/scripts/bootstrap.py"

# 상류 `codex-security skills add`(npm 0.2.0)는 <SKILLS_ROOT>/codex-security-<명령> 을 지우고
# ~/.agents/skills 의 CLI 안내 스킬(frontmatter `requires_bin: codex-security`)로 바꾼다. 이름이
# 우리 스킬 6개와 겹치고, 바뀐 스킬은 로그인이 필요한 CLI 를 부를 뿐이다. 덮어쓰인 스킬을 이름으로
# 알리고 1을 돌려준다(호출자가 "부분 정상"으로 반영). 설치본을 읽기만 하고 고치지 않는다.
check_upstream_overwrite() {
  local name target found=0
  for name in "${SKILL_NAMES[@]}"; do
    target="${SKILLS_ROOT}/${name}"
    if [ -f "${target}/SKILL.md" ] && grep -q '^requires_bin: codex-security' "${target}/SKILL.md"; then
      if [ "$found" -eq 0 ]; then
        echo ""
        echo "[경고] 상류 'codex-security skills add' 가 이 스킬을 덮어썼습니다(로그인이 필요한 CLI 안내로 바뀜):"
      fi
      found=1
      echo "  덮어쓰였습니다: ${name} -> $(readlink -f -- "$target" 2>/dev/null || echo "$target")"
    fi
  done
  if [ "$found" -eq 1 ]; then
    echo "  다시 설치하세요: bash skills/install.sh --force (복사본이면 --copy --force)"
    echo "  상류 'codex-security skills add' 를 다시 실행하면 또 덮어씁니다."
    return 1
  fi
  return 0
}

if [ "$CHECK_ONLY" = "true" ]; then
  if [ ! -f "$BOOTSTRAP_PATH" ]; then
    echo "오류: 프로브에 필요한 bootstrap.py 가 없습니다: ${BOOTSTRAP_PATH}" >&2
    exit 1
  fi
  check_rc=0
  run_check "$BOOTSTRAP_PATH" || check_rc=$?
  if ! check_upstream_overwrite && [ "$check_rc" -eq 0 ]; then
    check_rc=2
  fi
  exit "$check_rc"
fi

echo "설치 위치: ${SKILLS_ROOT} (모드: ${MODE})"
failed=0
for name in "${SKILL_NAMES[@]}"; do
  install_one "$name" || failed=1
done
if [ "$MODE" = "link" ]; then
  echo "참고: 링크 모드이므로 저장소의 수정이 즉시 반영됩니다."
else
  echo "참고: 복사 모드이므로 저장소를 수정한 뒤에는 --copy --force 로 재설치해야 합니다."
fi

if [ "$CHECK" = "true" ]; then
  # 설치본(있으면)의 bootstrap 으로 프로브해 실제 실행 경로를 확인한다.
  probe_bootstrap="${SKILLS_ROOT}/codex-security-scan/scripts/bootstrap.py"
  [ -f "$probe_bootstrap" ] || probe_bootstrap="$BOOTSTRAP_PATH"
  if [ -f "$probe_bootstrap" ]; then
    # 프로브의 3값(0 정상 / 2 부분 정상 / 1 실패)을 그대로 노출한다. `|| failed=1`
    # 로만 두면 2가 1로 눌려, 문서가 릴리즈 검증에 지정한 `--copy --check` 경로
    # (docs/releasing.md)에서 "rg 부재"와 "설치 실패"가 같은 신호가 된다.
    probe_rc=0
    run_check "$probe_bootstrap" || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      if [ "$failed" -eq 0 ]; then
        failed="$probe_rc"
      else
        failed=1   # 설치 자체가 실패했으면 그쪽이 더 강한 신호다.
      fi
    fi
  else
    echo "경고: 프로브를 건너뜁니다(bootstrap.py 없음): ${probe_bootstrap}" >&2
  fi
  if ! check_upstream_overwrite && [ "$failed" -eq 0 ]; then
    failed=2
  fi
fi
exit "$failed"
