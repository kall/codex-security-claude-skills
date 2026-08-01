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
REQUESTED=()

usage() {
  cat <<'EOF'
사용법: bash skills/install.sh [--link|--copy] [--force]

  --link    (기본) 심볼릭 링크로 설치한다. 저장소 수정이 즉시 반영된다 (개발용).
  --copy    실제 복사본으로 설치한다 (배포용).
  --force   대상 경로가 이미 있을 때 덮어쓴다.
  -h, --help  이 도움말을 출력한다.

환경변수:
  CLAUDE_SKILLS_DIR   설치 위치의 상위 디렉터리 (기본: $HOME/.claude/skills)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --link) MODE="link" ;;
    --copy) MODE="copy" ;;
    --force) FORCE="true" ;;
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
exit "$failed"
