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
   (`__pycache__` 제외). `bootstrap.py`나 공용 관문 `workflow_digest.mjs`가 빠지면 **빌드를 중단**한다.
2. 매뉴얼(`docs/install-and-usage.md`)과 재검증 도구 수집 — `repro-u3.sh`, `repro-u4.sh`,
   `repro-u1-search-command.sh`, `repro-u5-match-validator.sh`, `repro-u7-coverage-recovery.sh`,
   `repro-u8-policy-severity.sh`, 그리고 `fixtures/` 전체(하위 디렉터리 `scan-match/` 포함 —
   `repro-u5`가 이 픽스처가 없으면 exit 2다).
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
D=codex-security-claude-skills-*/docs/verification/scripts
bash $D/repro-u4.sh                  # 봉인 계약 + 인벤토리 정확성
bash $D/repro-u1-search-command.sh   # 검색 명령 확보와 신뢰 게이트
bash $D/repro-u7-coverage-recovery.sh  # 커버리지 정직성 + 복구 경로
bash $D/repro-u5-match-validator.sh  # 매칭 검증기
bash $D/repro-u8-policy-severity.sh  # SECURITY.md 초안·심각도 재분류 결정론 부분
```

기대: 체크섬 OK → 스킬 9종 설치 → 프로브가 플러그인 경로·버전(매니페스트·npm)·검색 명령·정규화·경로 바인딩·
diff 입력·Node·SECURITY.md 헬퍼·게이트 사본 보고, "사용 불가" 경고 줄 없음(`--check`도 **exit 0/2/1** 세 값을 낸다 — 2는 ripgrep
미확보이며 통과가 아니다) → 자기 채점 스크립트 다섯 개가 모두 `ALL ASSERTIONS PASSED`(exit 0).

**exit 2(`INCOMPLETE`)는 통과가 아니다.** 전제(ripgrep, 플러그인 사본)를 확보하지 못해 검증하지
못한 블록이 있다는 뜻이다. 릴리즈 검증에서는 exit 2를 실패로 취급하고, 전제를 갖춘 뒤 다시 돌린다
— 그러지 않으면 "핵심 주장이 미검증인 상태"와 "전부 통과"가 같은 신호가 된다.

플러그인이 없는 PC도 함께 확인하려면 npm 전역 경로를 빈 디렉터리로 가려 프로브가 exit 1 +
설치 안내를 내는지 본다.

## 3. 루트 README 갱신 (자동 아님)

`make-release.sh`는 배포본 **내부** README(`$PKG/README.md`)만 `${VERSION}`으로 채워서
생성한다. 저장소 루트의 `README.md`·`README.ko.md`는 별도 파일이라 스크립트가 건드리지
않는다 — 태그만 새로 따고 이 두 파일을 그대로 두면 "설치" 섹션의 복사/붙여넣기 문구가
이전 버전 태그(`.../releases/tag/<이전 버전>`)를 계속 가리키게 된다.

버전마다 다음을 수동으로 갱신하고 같은 커밋에 포함한다:

- `README.md`: "Install (users)" 아래 복사/붙여넣기 코드 블록의 태그 URL
- `README.ko.md`: "설치 (사용자)" 아래 복사/붙여넣기 코드 블록의 태그 URL

## 4. 업로드

```bash
gh release create v0.1.0 --repo kall/codex-security-claude-skills \
  dist/codex-security-claude-skills-v0.1.0.tar.gz dist/SHA256SUMS \
  --title 'codex-security-claude-skills-v0.1.0' --notes-file RELEASE_NOTES.md
```

빌드 스크립트가 종료 시 이 명령과 사용자용 설치 안내문을 실제 URL로 출력한다.

## 5. 릴리즈 노트에 반드시 넣을 것

**형식(v0.1.0부터 고정)**: 하나의 노트에 **영문 → 한국어** 두 벌을 담는다. 맨 위에
`*(한국어 버전은 아래로 스크롤 / Korean version below)*`, 한국어 섹션(`## 한국어`) 머리에
`*(English version above)*`를 두고 두 섹션 사이는 `---`로 나눈다. 두 벌은 같은 내용을 담되
번역투가 아니라 각 언어로 자연스럽게 쓴다. **한국어는 존댓말(~합니다체)로 작성한다.**

내용은 순서대로, **맨 위 항목이 가장 중요하다** — 끝까지 읽지 않는 독자가 많으므로 가장 먼저
전달해야 할 내용을 최상단에 둔다.

- **Claude에게 링크만 주고 설치를 맡겨도 된다**: 릴리즈 URL을 Claude Code 세션에 주고
  "설치해줘"라고 하면 아래 curl/sha256sum/tar/install.sh 과정을 그대로 수행한다.
  첫 문단에 **그대로 복사/붙여넣기할 수 있는 문구**를 코드 블록으로 넣는다. 반드시
  `.../releases/tag/<version>` 형태의 **태그가 박힌 URL**을 쓴다(`/releases` 인덱스
  페이지는 Claude가 최신 버전과 에셋 파일명을 다시 추론해야 해서 모호함). 예:

  ```
  https://github.com/kall/codex-security-claude-skills/releases/tag/v0.1.0 이거 설치해줘
  ```

  버전마다 이 URL을 갱신해야 한다(§3 루트 README 갱신, §6 버전 정책과 동일한 이유).
- **검증된 플러그인 조합**: `@openai/codex-security@<npm 버전>` / 플러그인 매니페스트
  `<manifest 버전>`. 스킬은 플러그인 문서를 런타임에 읽으므로 이 조합이 호환성의 기준이다.
- **게이트 사본 차이**: 같은 매니페스트 버전에서도 워킹트리 게이트가 하드 실패/경고로 갈린다.
  `--check`가 판별해준다는 안내([매뉴얼 3.4절](install-and-usage.md#34-플러그인-사본별-동작-차이-확인-권장)).
- 플러그인 자동 설치를 하지 않는다는 사실과 `npm install -g @openai/codex-security` 안내.
- 지원 범위: 비 Codex 경로이며 업스트림 OpenAI 지원 대상이 아님.

## 6. 버전 정책

**번호는 검증 대상 `@openai/codex-security`의 npm 버전과 같은 값을 쓴다**(v0.1.18부터).
스킬이 플러그인 문서를 런타임에 읽으므로 호환성을 결정하는 것은 플러그인 릴리즈이고, 번호가
곧 "어느 플러그인에 맞춰 검증했는가"를 가리킨다. 스킬만 고친 재배포가 필요하면 같은 플러그인
번호 뒤에 접미사를 붙인다(예: `v0.1.18-1`). 릴리즈 노트 첫머리에 이 규칙을 한 문단으로
설명해 0.1.0 → 0.1.18 같은 점프를 오해하지 않게 한다.

tarball 이름·최상위 디렉터리·`NOTICE`·문서 링크가 모두 `--version` 값을 쓴다. 링크가 태그에
고정되므로 **태그를 만든 뒤(또는 같은 이름으로 만들 예정으로) 빌드**한다. 이미 배포한 버전의
tarball을 교체하지 말고 새 버전을 올린다 — 사용자가 체크섬으로 무결성을 검증한다.

## 7. 플러그인 업데이트 대응

업스트림이 번들 플러그인을 갱신하면 스킬 동작이 바뀔 수 있다. 순서:

1. **고정한 상류 영문 리터럴을 새 상류 태그와 다시 대조한다.** 아래 네 곳은 상류 원문을 복사 시점 커밋
   (태그 `npm-v0.1.29` = `6620a380f86c26d6c6428a660b2a90c3b5a1fa45`)과 함께 고정했다. 마지막 재대조는
   태그 `npm-v0.4.0` = `559b492b22bb457aea8ff88c1bd41aacc2cec8bf`이다(직전은 `npm-v0.2.0` =
   `4949af70fcfadff154f6e8fdf100faa5bf2f8169`).
   - scan-match: `comparisonPrompt()`(0.4.0 약 973행) 원문이 같았다.
   - classify-severity: 지시 8문단이 같았다. 행 번호만 바뀌었다(`classify-severity.ts` 166–173행).
   - patch: 검증 지시 주입 문구(`cli.ts` 0.4.0 약 7688행)가 같았다.
   - policy: 단계 프롬프트는 같았다. 진행 문구 `[1/3]`·`[2/3]`이 0.3.0(#1416)에서 바뀌어 리터럴과 복사 시점
     커밋을 `npm-v0.4.0`(커밋 `559b492b2`)으로 갱신했다. 그래서 npm 0.2.0 설치본에서는 `repro-u8` P7이 실패한다
     (의도한 드리프트 검출).

   상류 저장소에서 `git diff npm-v<이전> npm-v<새 버전> -- <원본 파일>`로 원본을 보고, 바뀌었으면 리터럴과 복사
   시점 커밋을 함께 갱신한다. 회귀 스크립트만으로는 전부 잡히지 않는다.

   | 고정 위치 | 상류 원본 | 드리프트 자동 감지 |
   | --- | --- | --- |
   | `skills/codex-security-scan-match/SKILL.md` 「상류 판정 문장」 | `sdk/typescript/src/scan-comparison.ts` `comparisonPrompt()` | 없음 — 컴파일된 `dist/scan-comparison.js`에 같은 문자열이 있지만 회귀 스크립트가 대조하지 않는다(블록 S는 카탈로그·조정 결과만 대조) |
   | `skills/codex-security-policy/scripts/policy_draft.mjs` `UPSTREAM_*` | `sdk/typescript/src/security-policy.ts` `runSecurityPolicyStages()` | `repro-u8` P7·P11이 설치된 dist와 대조 |
   | `skills/codex-security-classify-severity/scripts/classify_severity.mjs` `UPSTREAM_CLASSIFY_INSTRUCTIONS` | `sdk/typescript/src/classify-severity.ts` `classifySeverityInternal()` | 있음 — 스킬 `prepare`가 다르면 중단하고, `repro-u8` S12가 대조 |
   | `skills/codex-security-patch/SKILL.md` 「검증 지시의 위치와 상류 주입 문구」 | `sdk/typescript/src/cli.ts` `runSkill()`의 검증 프롬프트 블록 | 없음 — 컴파일된 `dist/cli.js`에 같은 문자열이 있지만 회귀 스크립트가 대조하지 않는다 |
   | (고정 리터럴 없음) `skills/codex-security-validate/SKILL.md` 단독 모드 | 플러그인 `references/standalone-validation.md`·`references/static-finding-assessment.md`(상류 `validate`가 프롬프트에 싣는 두 문서, #1423) | 해당 없음 — 스킬이 런타임에 두 문서를 읽는다. 상류가 두 문서 말고 다른 지시를 프롬프트에 더하면 잡히지 않으므로 `sdk/typescript/src/standalone-validation-prompt.ts`의 diff를 본다 |

2. 새 플러그인으로 자기 채점 스크립트 다섯(`repro-u4.sh`, `repro-u1-search-command.sh`,
   `repro-u7-coverage-recovery.sh`, `repro-u5-match-validator.sh`, `repro-u8-policy-severity.sh`)과
   관측형 `repro-u3.sh` 실행 → 계약 변화 확인. exit 2는 미검증이므로 전제를 갖춰 다시 돌린다.
   npm 0.4.0 정합에서 늘어난 블록은 다음과 같다.
   - `repro-u4`: F 블록(coverage 스키마에 `completeness`가 있는지로 SARIF 형상 분기), I17~I20(diff 인벤토리가
     내용으로 바이너리를 빼고 삭제 파일을 넣음), L 블록(L0 부트스트랩 헬퍼 종류, L1 `bind-repo-scopes`, L2 `copy-deep-review-input`,
     L3 새 finding 검증 오류 문구).
   - `repro-u7`: I5x 블록(`completeness` 없는 coverage의 정산 요약과 사람용 신호).
   - `repro-u1`: H14a-5~7(`npmVersion`·`coverageCompleteness`·헬퍼 종류), H14b-8~9(헬퍼 불가·하위 명령별 판정).

   기준 버전 하나만 돌리지 않는다. 지원하는 버전마다 7.2절 방법으로 격리 설치본을 만들어 같은 스크립트를 돌린다.
   npm 0.4.0 정합(2026-10-17)에서는 다음을 확인했다.

   | 설치본 | 결과 |
   | --- | --- |
   | npm 0.4.0·0.3.0 | `repro-u4`(OK 80)·`repro-u1`(95)·`repro-u7`(70)·`repro-u5`(714)·`repro-u8`(284) 모두 exit 0. `repro-u3` S5 exit 0(경고 사본) |
   | npm 0.2.0 | `repro-u4`(OK 71, 0.4.0 전용 검사는 NOTE)·`repro-u1`·`repro-u7`·`repro-u5` 통과. `repro-u8`은 P7 리터럴 드리프트 1건만 실패(1번 policy). `repro-u3` 관측 결과는 0.3.0·0.4.0과 같다 |
   | npm 0.1.32 이하 | 다시 검증하지 않음 |
3. 변화가 있으면 해당 SKILL.md와 매뉴얼(특히 3.4절 표)을 갱신. 스캔 스킬의 버전 경고 기준
   (매니페스트 축)과 각 스킬의 "기준 실측 버전"(npm 축)을 함께 올린다.
4. 새 버전으로 재배포하고 릴리즈 노트에 검증된 조합을 갱신.

### 7.1 상류 태그가 npm에 아직 없을 때

> npm 0.2.0과 0.4.0(0.3.0 포함)은 레지스트리에 있었다. 그때는 아래 빌드 없이 `npm install -g --prefix /tmp/<dir>
> @openai/codex-security@<버전>`으로 격리 설치하고 7.2절 방법으로 검증했다.

상류가 `npm-v<버전>` 태그를 만든 뒤에도 npm 레지스트리 배포는 늦을 수 있다(0.1.32가 그랬다). 그때는 태그
소스로 패키지를 빌드해 격리 경로에 설치하고 검증한다. 전역 설치본은 건드리지 않는다.

```bash
B=$(mktemp -d) && git -C <상류 체크아웃> archive npm-v<버전> | tar -x -C "$B"
# 네이티브 바이너리(plugins/codex-security/native/prebuilt)는 git에 없다. 직전 npm 배포본에서 가져온다.
# 두 태그 사이의 native/ 변경이 대상 플랫폼과 무관한지 먼저 git diff --stat 으로 확인한다.
(cd "$B" && npm pack @openai/codex-security@<직전 버전> && tar xzf openai-codex-security-*.tgz &&
  mkdir -p plugins/codex-security/native/prebuilt &&
  cp -a package/_bundled_plugin/mcp/native/. plugins/codex-security/native/prebuilt/)
npx -y pnpm@<package.json의 packageManager 버전> --dir "$B/sdk/typescript" install --frozen-lockfile
npx -y pnpm@<같은 버전> --dir "$B/plugins/codex-security/mcp-app" install --frozen-lockfile
(cd "$B/sdk/typescript" && npx -y pnpm@<같은 버전> pack --pack-destination "$B/dist")
npm install -g --prefix /tmp/cs-prefix "$B"/dist/openai-codex-security-<버전>.tgz
P=/tmp/cs-prefix/lib/node_modules/@openai/codex-security/_bundled_plugin
# 자기채점 스크립트는 경로 변수로 이 사본을 가리킨다. 부트스트랩을 거치는 스크립트는 7.2절 npm 래퍼도 필요하다.
CODEX_SECURITY_PLUGIN_DIR=$P CODEX_SECURITY_PLUGIN_ROOT=$P \
  PATH=/tmp/cs-bin:/tmp/cs-prefix/bin:$PATH bash docs/verification/scripts/repro-u4.sh
```

빌드한 tarball의 파일 목록을 직전 npm 배포본과 비교해 빠진 파일이 없는지 본다. 릴리즈 노트와 README에는
"태그 소스 빌드로 검증했고 npm 배포 전에는 직전 버전을 설치한다"를 적고, 직전 npm 배포본으로도 자기채점
스크립트를 돌려 통과를 확인한다.

### 7.2 전역 설치본을 바꾸지 않고 다른 버전으로 검증

`bootstrap.py`는 `npm root -g`를 **정화된 환경**에서 실행한다. 그래서 `NPM_CONFIG_PREFIX` 환경변수만으로는
채택 사본이 바뀌지 않는다(2026-10-14 실측: 전역 0.1.29가 계속 선택됐다). PATH 맨 앞에 `--prefix`를 고정한
`npm` 래퍼를 둔다.

```bash
npm install -g --prefix /tmp/cs-prefix @openai/codex-security@<버전>
mkdir -p /tmp/cs-bin
printf '#!/bin/sh\nexec %s --prefix /tmp/cs-prefix "$@"\n' "$(command -v npm)" > /tmp/cs-bin/npm
chmod 755 /tmp/cs-bin/npm
P=/tmp/cs-prefix/lib/node_modules/@openai/codex-security/_bundled_plugin
PATH=/tmp/cs-bin:$PATH CODEX_SECURITY_PLUGIN_DIR=$P CODEX_SECURITY_PLUGIN_ROOT=$P \
  bash docs/verification/scripts/repro-u1-search-command.sh
```

먼저 `PATH=/tmp/cs-bin:$PATH python3 skills/codex-security-scan/scripts/bootstrap.py --no-scan-dir`의
`pluginRoot`가 격리 사본인지, `npmVersion`이 검증할 버전인지 확인한 뒤 자기채점 스크립트를 돌린다.

여러 버전을 비교할 때는 버전마다 prefix와 래퍼 디렉터리를 따로 둔다(예: `/tmp/cs040-g`·`/tmp/cs040-bin`,
`/tmp/cs030-g`·`/tmp/cs030-bin`, `/tmp/cs020-g`·`/tmp/cs020-bin`). 그리고 같은 스크립트를 버전마다 돌린다.

**`mise exec`를 쓰는 PC의 주의.** `mise exec -- <명령>`은 mise가 관리하는 Node의 `bin`을 PATH 앞에 넣는다. 그래서
`PATH=/tmp/cs-bin:$PATH mise exec -- python3 …`처럼 쓰면 전역 `npm`과 전역 `codex-security`가 다시 먼저 잡혀
격리 사본 대신 전역 설치본이 채택될 수 있다(2026-10-17 실측: 전역 0.3.0이 채택됐다). Python은
`PY=$(mise which python3)`로 절대 경로를 얻어 `mise exec` 없이 부른다. 상류 CLI를 손으로 확인할 때도 PATH에
기대지 말고 `node /tmp/<prefix>/bin/codex-security …`처럼 격리 설치본의 실행 파일을 직접 지정한다.

새 버전이 상태 DB 마이그레이션을 늘렸으면
기본 상태 디렉터리를 그 버전으로 열지 않는다 — 자기채점 스크립트는 임시 상태 디렉터리를 쓰지만, 실제 스캔을
돌려 볼 때는 `CODEX_SECURITY_STATE_DIR`를 임시 경로로 둔다.
