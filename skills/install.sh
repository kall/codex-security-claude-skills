#!/usr/bin/env bash
#
# security-scan-local 스킬을 Claude Code 전역 스킬 디렉터리에 설치한다.
#
# 사용법:
#   bash skills/install.sh [--link|--copy] [--force]
#
#   --link    (기본) 심볼릭 링크로 설치. 저장소 수정이 즉시 반영되므로 개발용.
#   --copy    실제 복사본으로 설치. 저장소와 분리되므로 배포/배포본 검증용.
#   --force   대상 경로가 이미 있으면 덮어쓴다. 없으면 설치를 거부한다.
#
# 환경변수:
#   CLAUDE_SKILLS_DIR   설치 위치의 상위 디렉터리 (기본: $HOME/.claude/skills)
#
set -euo pipefail

SKILL_NAME="security-scan-local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="${SCRIPT_DIR}/${SKILL_NAME}"

MODE="link"
FORCE="false"

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
    *)
      echo "오류: 알 수 없는 인자 '$1'" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -d "$SOURCE_DIR" ]; then
  echo "오류: 스킬 원본 디렉터리를 찾을 수 없습니다: ${SOURCE_DIR}" >&2
  echo "      이 스크립트는 codex-security 저장소의 skills/ 안에서 실행해야 합니다." >&2
  exit 1
fi

SKILLS_ROOT="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
TARGET_DIR="${SKILLS_ROOT}/${SKILL_NAME}"

# rm -rf 대상이 반드시 우리가 만든 스킬 경로인지 확인한다.
if [ "$(basename "$TARGET_DIR")" != "$SKILL_NAME" ] || [ -z "$SKILLS_ROOT" ]; then
  echo "오류: 설치 대상 경로가 올바르지 않습니다: ${TARGET_DIR}" >&2
  exit 1
fi

if [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; then
  if [ "$FORCE" != "true" ]; then
    echo "경고: 설치 대상이 이미 존재합니다: ${TARGET_DIR}" >&2
    if [ -L "$TARGET_DIR" ]; then
      echo "      현재 상태: 심볼릭 링크 -> $(readlink "$TARGET_DIR")" >&2
    else
      echo "      현재 상태: 일반 디렉터리/파일" >&2
    fi
    echo "      덮어쓰려면 --force 를 함께 지정하세요:" >&2
    echo "        bash skills/install.sh --${MODE} --force" >&2
    exit 1
  fi
  echo "기존 설치본을 제거합니다: ${TARGET_DIR}"
  rm -rf -- "$TARGET_DIR"
fi

mkdir -p -- "$SKILLS_ROOT"

case "$MODE" in
  link)
    ln -s -- "$SOURCE_DIR" "$TARGET_DIR"
    ;;
  copy)
    cp -R -- "$SOURCE_DIR" "$TARGET_DIR"
    ;;
esac

echo "설치 완료"
echo "  모드    : ${MODE}"
echo "  원본    : ${SOURCE_DIR}"
echo "  설치 위치: ${TARGET_DIR}"
if [ "$MODE" = "link" ]; then
  echo "  참고    : 링크 모드이므로 저장소의 수정이 즉시 반영됩니다."
else
  echo "  참고    : 복사 모드이므로 저장소를 수정한 뒤에는 --copy --force 로 재설치해야 합니다."
fi
