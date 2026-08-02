# 릴리즈 절차 (Claude 보안 스킬)

배포 형식은 **GitHub 공개 릴리즈 + tarball**이다. 사용자는 링크 하나만 받아 설치한다
([매뉴얼 0절](install-and-usage.md#0-빠른-설치-릴리즈-tarball--링크-하나로)).

## 1. 배포본 빌드

```bash
bash tools/make-release.sh --version v0.1.0 --repo kall/codex-security-claude-skills
```

산출물은 `dist/`에 생성된다(git 추적 제외).

- `dist/codex-security-claude-skills-<version>.tar.gz`
- `dist/SHA256SUMS`

스크립트가 하는 일:

1. `SKILL.md`를 가진 스킬 디렉터리 **전부** + `install.sh` + `skills/README.md` 수집
   (`__pycache__` 제외). `bootstrap.py`가 빠지면 **빌드를 중단**한다.
2. 매뉴얼(`docs/install-and-usage.md`)과 재검증 도구(`repro-u3.sh`, `repro-u4.sh`,
   `fixtures/*.json`) 수집.
3. `LICENSE` 복사 + `NOTICE` 생성(업스트림 Apache-2.0 파생 관계·비지원 경로 명시).
4. 배포본 진입점 `README.md` 생성(설치 3줄 + 검증된 플러그인 조합).
5. **배포본에 없는 문서로의 상대 링크를 절대 GitHub URL로 치환**한다(개발 기록 문서는 담지
   않으므로 링크가 깨지지 않게). 배포본 안에 존재하는 링크는 상대 경로를 유지한다.
6. 결정론적 tarball(`--sort=name`, owner/group 제거) + `SHA256SUMS` 생성.

## 2. 배포본 검증 (업로드 전 필수)

실제 사용자 경로를 그대로 재현한다. 저장소 밖 임시 디렉터리에서:

```bash
T=$(mktemp -d) && cp dist/*.tar.gz dist/SHA256SUMS "$T"/ && cd "$T"
sha256sum -c SHA256SUMS
tar xzf codex-security-claude-skills-*.tar.gz
CLAUDE_SKILLS_DIR="$T/skills" bash codex-security-claude-skills-*/skills/install.sh --copy --check
bash codex-security-claude-skills-*/docs/verification/scripts/repro-u4.sh
```

기대: 체크섬 OK → 스킬 6종 설치 → 프로브가 플러그인 경로·버전·게이트 사본 보고 →
`ALL ASSERTIONS PASSED`.

플러그인이 없는 PC도 함께 확인하려면 npm 전역 경로를 빈 디렉터리로 가려 프로브가 exit 1 +
설치 안내를 내는지 본다.

## 3. 업로드

```bash
gh release create v0.1.0 --repo kall/codex-security-claude-skills \
  dist/codex-security-claude-skills-v0.1.0.tar.gz dist/SHA256SUMS \
  --title 'codex-security-claude-skills-v0.1.0' --notes-file RELEASE_NOTES.md
```

빌드 스크립트가 종료 시 이 명령과 사용자용 설치 안내문을 실제 URL로 출력한다.

## 4. 릴리즈 노트에 반드시 넣을 것

- **검증된 플러그인 조합**: `@openai/codex-security@<npm 버전>` / 플러그인 매니페스트
  `<manifest 버전>`. 스킬은 플러그인 문서를 런타임에 읽으므로 이 조합이 호환성의 기준이다.
- **게이트 사본 차이**: 같은 매니페스트 버전에서도 워킹트리 게이트가 하드 실패/경고로 갈린다.
  `--check`가 판별해준다는 안내([매뉴얼 3.4절](install-and-usage.md#34-플러그인-사본별-동작-차이-확인-권장)).
- 플러그인 자동 설치를 하지 않는다는 사실과 `npm install -g @openai/codex-security` 안내.
- 지원 범위: 비 Codex 경로이며 업스트림 OpenAI 지원 대상이 아님.

## 5. 버전 정책

tarball 이름·최상위 디렉터리·`NOTICE`·문서 링크가 모두 `--version` 값을 쓴다. 링크가 태그에
고정되므로 **태그를 만든 뒤(또는 같은 이름으로 만들 예정으로) 빌드**한다. 이미 배포한 버전의
tarball을 교체하지 말고 새 버전을 올린다 — 사용자가 체크섬으로 무결성을 검증한다.

## 6. 플러그인 업데이트 대응

업스트림이 번들 플러그인을 갱신하면 스킬 동작이 바뀔 수 있다. 순서:

1. 새 플러그인으로 `repro-u4.sh`·`repro-u3.sh` 실행 → 계약 변화 확인.
2. 변화가 있으면 해당 SKILL.md와 매뉴얼(특히 3.4절 표)을 갱신.
3. 새 버전으로 재배포하고 릴리즈 노트에 검증된 조합을 갱신.
