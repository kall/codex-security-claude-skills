#!/usr/bin/env bash
#
# Claude 로컬 보안 스킬 배포본(tarball)을 만든다.
#
# 산출물:
#   dist/codex-security-local-skills-<version>.tar.gz
#   dist/SHA256SUMS
#
# 사용법:
#   bash tools/make-release.sh --version v0.1.0 --repo <owner>/<repo>
#
#   --version   릴리즈 버전 태그(필수). tarball 이름·최상위 디렉터리·문서 링크에 쓰인다.
#   --repo      GitHub owner/repo(필수). 배포본에 포함되지 않는 문서로의 링크를
#               절대 URL 로 치환하고 설치 안내문을 생성하는 데 쓰인다.
#   --out       산출물 디렉터리 (기본: dist)
#
# 왜 파일을 골라 담는가: 배포본은 "스킬 + 매뉴얼 + 재검증 도구"만 담는다. 원본 TS SDK/CLI
# (sdk/)는 수정하지 않으므로 넣지 않고, 개발 기록(docs/plans, phase 결과, learning)은
# 링크로 남긴다. 번들 플러그인은 대상 PC에서 npm 등으로 확보한다(벤더링하지 않음).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${REPO_ROOT:?저장소 루트 해석 실패}"

VERSION=""
GH_REPO=""
OUT_DIR="dist"

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift ;;
    --repo)    GH_REPO="${2:-}"; shift ;;
    --out)     OUT_DIR="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "오류: 알 수 없는 인자 '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$VERSION" ] || { echo "오류: --version 이 필요합니다 (예: --version v0.1.0)" >&2; exit 2; }
[ -n "$GH_REPO" ] || { echo "오류: --repo 가 필요합니다 (예: --repo myorg/codex-security-local-skills)" >&2; exit 2; }
case "$GH_REPO" in
  */*) : ;;
  *) echo "오류: --repo 는 owner/repo 형식이어야 합니다: $GH_REPO" >&2; exit 2 ;;
esac

PKG_NAME="codex-security-local-skills-${VERSION}"
STAGE="$(mktemp -d)"
trap 'rm -rf -- "$STAGE"' EXIT
PKG="$STAGE/$PKG_NAME"
mkdir -p "$PKG"

# --------------------------------------------------------------------------
# 1. 스킬 (SKILL.md 를 가진 디렉터리 전부 + install.sh + README)
# --------------------------------------------------------------------------
mkdir -p "$PKG/skills"
skill_count=0
for skill_md in "$REPO_ROOT"/skills/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  name="$(basename "$(dirname "$skill_md")")"
  cp -R -- "$REPO_ROOT/skills/$name" "$PKG/skills/$name"
  rm -rf -- "$PKG/skills/$name/scripts/__pycache__"
  skill_count=$((skill_count + 1))
done
[ "$skill_count" -gt 0 ] || { echo "오류: 담을 스킬을 찾지 못했습니다." >&2; exit 1; }
cp -- "$REPO_ROOT/skills/install.sh" "$PKG/skills/install.sh"
cp -- "$REPO_ROOT/skills/README.md" "$PKG/skills/README.md"

# bootstrap.py 는 모든 스킬이 참조하는 공통 진입점이므로 반드시 있어야 한다.
[ -f "$PKG/skills/security-scan-local/scripts/bootstrap.py" ] \
  || { echo "오류: bootstrap.py 가 배포본에 없습니다(부분 패키징 금지)." >&2; exit 1; }

# --------------------------------------------------------------------------
# 2. 매뉴얼 + 재검증 도구
# --------------------------------------------------------------------------
mkdir -p "$PKG/docs/verification/scripts" "$PKG/docs/verification/fixtures"
cp -- "$REPO_ROOT/docs/install-and-usage.md" "$PKG/docs/install-and-usage.md"
cp -- "$REPO_ROOT/docs/verification/scripts/repro-u3.sh" "$PKG/docs/verification/scripts/"
cp -- "$REPO_ROOT/docs/verification/scripts/repro-u4.sh" "$PKG/docs/verification/scripts/"
cp -- "$REPO_ROOT"/docs/verification/fixtures/*.json "$PKG/docs/verification/fixtures/"

# --------------------------------------------------------------------------
# 3. 라이선스·출처 표기 (업스트림 Apache-2.0 파생물)
# --------------------------------------------------------------------------
cp -- "$REPO_ROOT/LICENSE" "$PKG/LICENSE"
cat > "$PKG/NOTICE" <<EOF
Claude 로컬 보안 스킬 (codex-security-local-skills) ${VERSION}

이 배포본은 OpenAI 의 codex-security (https://github.com/openai/codex-security,
Apache License 2.0) 파생물입니다. 포함된 스킬 문서와 스크립트는 별도로 작성되었으나,
skills/security-scan-local/scripts/bootstrap.py 는 업스트림 sdk/typescript/src/runtime.ts
및 trusted-executable.ts 의 플러그인 루트·인터프리터 판정 로직을 의도적으로 재현합니다
(해당 파일 docstring에 참조 구현이 명시되어 있습니다).

이 실행 경로는 비(非) Codex 경로이며 OpenAI 의 지원 대상이 아닙니다.
전체 라이선스 전문은 LICENSE 파일을 참조하세요.

배포본 소스: https://github.com/${GH_REPO} (${VERSION})
EOF

# --------------------------------------------------------------------------
# 4. 배포본 README (설치 진입점)
# --------------------------------------------------------------------------
cat > "$PKG/README.md" <<EOF
# Claude 로컬 보안 스킬 ${VERSION}

OpenAI/Codex 인증 없이 **Claude Code 구독 로그인만으로** codex-security 보안 스캔
워크플로를 실행하는 Claude Code 스킬 ${skill_count}종.

## 설치

\`\`\`bash
bash skills/install.sh --copy --check
\`\`\`

\`--copy\` 로 \`~/.claude/skills/\` 에 설치하고, \`--check\` 로 실행 환경(번들 플러그인·Python·
게이트 사본)을 프로브한다. 플러그인이 없으면 설치할 명령을 안내한다(자동 설치는 하지 않는다).

플러그인이 없다는 안내가 나오면:

\`\`\`bash
npm install -g @openai/codex-security     # Node 22+
bash skills/install.sh --copy --force --check
\`\`\`

설치 후 Claude Code 를 재시작하고 호출한다:

\`\`\`
/security-scan-local /path/to/repo
\`\`\`

## 검증된 조합

- 번들 플러그인: \`@openai/codex-security@0.1.3\` (플러그인 매니페스트 \`0.1.14\`)
- Python 3.10+ / git / Node 22+(플러그인 npm 설치 시)
- Linux · macOS (Windows 는 WSL)

> 같은 플러그인 매니페스트 버전에서도 사본에 따라 워킹트리 게이트 처리가 다르다.
> \`--check\` 가 어느 쪽인지 알려준다. 자세한 내용은 매뉴얼 3.4절.

## 문서

- **설치·사용 매뉴얼**: [docs/install-and-usage.md](docs/install-and-usage.md)
- 스킬 목록·수정 방법: [skills/README.md](skills/README.md)
- 재검증(플러그인 업데이트 후): \`bash docs/verification/scripts/repro-u4.sh\`, \`repro-u3.sh\`

## 라이선스

Apache-2.0. 업스트림 출처와 파생 관계는 [NOTICE](NOTICE) 참조.
EOF

# --------------------------------------------------------------------------
# 5. 배포본 밖으로 나가는 상대 링크를 절대 URL 로 치환
#    (개발 기록 문서는 배포본에 넣지 않으므로 링크가 깨지는 것을 막는다)
# --------------------------------------------------------------------------
PYTHON_BIN="${PYTHON:-$(command -v python3 || command -v python || true)}"
[ -n "$PYTHON_BIN" ] || { echo "오류: python3/python 을 찾지 못했습니다." >&2; exit 1; }

PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" - "$PKG" "$GH_REPO" "$VERSION" <<'PYEOF'
import pathlib, re, sys

pkg, gh_repo, version = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
link_re = re.compile(r"\[([^\]]+)\]\((?!https?://|#)([^)]+)\)")
rewritten = 0

for md in sorted(pkg.rglob("*.md")):
    text = md.read_text()
    # 배포본 안에서 이 문서가 놓인 위치 = 원본 저장소에서의 위치와 동일하다.
    doc_dir_in_repo = md.parent.relative_to(pkg)

    def replace(match):
        global rewritten
        label, target = match.group(1), match.group(2)
        anchor = ""
        if "#" in target:
            target, anchor = target.split("#", 1)
            anchor = "#" + anchor
        if not target:
            return match.group(0)
        # 배포본 안에 실제로 존재하면 상대 링크를 유지한다.
        if (md.parent / target).exists():
            return match.group(0)
        repo_path = (doc_dir_in_repo / target).as_posix()
        # 상위 참조(..) 정규화
        parts = []
        for part in repo_path.split("/"):
            if part == "..":
                if parts:
                    parts.pop()
            elif part not in ("", "."):
                parts.append(part)
        url = f"https://github.com/{gh_repo}/blob/{version}/" + "/".join(parts)
        rewritten += 1
        return f"[{label}]({url}{anchor})"

    new_text = link_re.sub(replace, text)
    if new_text != text:
        md.write_text(new_text)

print(f"  배포본 밖 링크 {rewritten}건을 절대 URL 로 치환")
PYEOF

# --------------------------------------------------------------------------
# 6. tarball + 체크섬
# --------------------------------------------------------------------------
mkdir -p "$REPO_ROOT/$OUT_DIR"
TARBALL="$REPO_ROOT/$OUT_DIR/${PKG_NAME}.tar.gz"
# 결정론적 tarball: 정렬된 파일 목록, 소유자/그룹 제거.
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -czf "$TARBALL" -C "$STAGE" "$PKG_NAME"

( cd "$REPO_ROOT/$OUT_DIR" && sha256sum "${PKG_NAME}.tar.gz" > SHA256SUMS )

echo
echo "생성 완료:"
echo "  $TARBALL"
echo "  $REPO_ROOT/$OUT_DIR/SHA256SUMS"
echo "  스킬 ${skill_count}종, 파일 $(tar tzf "$TARBALL" | grep -vc '/$')개"
echo
echo "GitHub 릴리즈 업로드:"
echo "  gh release create ${VERSION} --repo ${GH_REPO} \\"
echo "    ${TARBALL} ${REPO_ROOT}/${OUT_DIR}/SHA256SUMS \\"
echo "    --title '${PKG_NAME}' --notes-file <릴리즈 노트>"
echo
echo "설치 안내문(사용자에게 전달할 링크 기준):"
BASE="https://github.com/${GH_REPO}/releases/download/${VERSION}"
cat <<EOF
  curl -fsSLO ${BASE}/${PKG_NAME}.tar.gz
  curl -fsSL  ${BASE}/SHA256SUMS | sha256sum -c -
  tar xzf ${PKG_NAME}.tar.gz
  bash ${PKG_NAME}/skills/install.sh --copy --check
EOF
