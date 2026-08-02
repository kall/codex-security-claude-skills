#!/usr/bin/env bash
#
# 이 저장소의 보안 스캔 스킬들(SKILL.md 를 가진 skills/ 하위 디렉터리 전부)을
# Claude Code 전역 스킬 디렉터리에 설치한다.
#   - security-scan-local, security-validate-local, security-patch-local,
#     security-diff-scan-local 등 앞으로 추가되는 스킬도 자동 포함된다.
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
  --check   설치 후 실행 환경을 프로브한다(번들 플러그인·Python·게이트 사본).
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
#   3. 플러그인 사본의 워킹트리 게이트 처리(하드 실패 / 경고) — 같은 버전에서도 다르다
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
  # shellcheck disable=SC2064
  trap "rm -rf -- '$probe_target' '$boot_json'" RETURN

  PYTHONDONTWRITEBYTECODE=1 "$python_bin" "$bootstrap" \
    --target-repo "$probe_target" --no-scan-dir > "$boot_json" 2>/dev/null
  rc=$?

  PYTHONDONTWRITEBYTECODE=1 "$python_bin" - "$boot_json" "$rc" <<'PYEOF'
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
print("\n[프로브] 실행 환경 정상")
print(f"  플러그인 : {plugin_root}")
print(f"  버전     : {data.get('pluginVersion')} (출처: {data.get('pluginSource')})")
print(f"  Python   : {python_info.get('path')} ({python_info.get('version')})")

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
PYEOF
}

BOOTSTRAP_PATH="${SCRIPT_DIR}/security-scan-local/scripts/bootstrap.py"

if [ "$CHECK_ONLY" = "true" ]; then
  if [ ! -f "$BOOTSTRAP_PATH" ]; then
    echo "오류: 프로브에 필요한 bootstrap.py 가 없습니다: ${BOOTSTRAP_PATH}" >&2
    exit 1
  fi
  run_check "$BOOTSTRAP_PATH"
  exit "$?"
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
  probe_bootstrap="${SKILLS_ROOT}/security-scan-local/scripts/bootstrap.py"
  [ -f "$probe_bootstrap" ] || probe_bootstrap="$BOOTSTRAP_PATH"
  if [ -f "$probe_bootstrap" ]; then
    run_check "$probe_bootstrap" || failed=1
  else
    echo "경고: 프로브를 건너뜁니다(bootstrap.py 없음): ${probe_bootstrap}" >&2
  fi
fi
exit "$failed"
