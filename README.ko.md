# Claude 보안 스킬 (codex-security-claude-skills)

[English](README.md) | 한국어

OpenAI/Codex 인증 없이 **Claude Code 구독 로그인만으로** [codex-security](https://github.com/openai/codex-security)
의 보안 스캔 워크플로를 실행하는 Claude Code 스킬 9종. SECURITY.md 초안 작성과 심각도 재분류도
포함한다.

LLM 두뇌 역할은 Claude Code 세션 자신이 맡고, 검증·ID 파생·봉인·리포트 생성은 codex-security
번들 플러그인의 결정론(deterministic) Python 스크립트가 담당한다. 플러그인은 벤더링하지 않고
**설치된 것을 런타임에 찾아 쓴다.**

> 이 실행 경로는 비(非) Codex 경로이며 **업스트림 OpenAI 지원 대상이 아니다.**

## 설치 (사용자)

릴리즈 tarball을 받아 설치한다. 아니면 Claude Code 세션에 이 문구를 그대로 복사/붙여넣기해도 된다:

```
https://github.com/kall/codex-security-claude-skills/releases/tag/v0.6.0 이거 설치해줘
```

```bash
BASE=https://github.com/kall/codex-security-claude-skills/releases/latest/download
PKG=codex-security-claude-skills-<version>

curl -fsSLO "$BASE/$PKG.tar.gz"
curl -fsSL  "$BASE/SHA256SUMS" | sha256sum -c -
tar xzf "$PKG.tar.gz"
bash "$PKG/skills/install.sh" --copy --check
```

`--check`가 번들 플러그인·Python·검색 명령(ripgrep)·게이트 사본을 프로브해 보고한다.
종료코드는 **0=정상 / 2=부분 정상(ripgrep 미확보 — 저장소 전체 스캔 불가) / 1=실패** 세 값이다. 플러그인이 없으면 설치할
명령을 안내한다(자동 설치는 하지 않는다):

```bash
npm install -g @openai/codex-security     # Node 22+
```

Claude Code를 재시작한 뒤 호출한다:

```
/codex-security-scan /path/to/repo
```

전체 사용법·환경변수·트러블슈팅: **[docs/install-and-usage.md](docs/install-and-usage.md)**

## 스킬

| 스킬 | 용도 | 저장소 변경 |
| --- | --- | --- |
| `codex-security-scan` | 저장소 전체 1회 표준 스캔 → 봉인 계약 산출물 + `report.md` + SARIF | 없음 |
| `codex-security-diff-scan` | 변경분(refs 또는 working-tree)만 스캔 | 없음 |
| `codex-security-validate` | 후보 finding 진위 판정(disposition) | 없음 |
| `codex-security-patch` | 보안 이슈 최소 수정 — 2단 승인 | 있음(승인 후) |
| `codex-security-verify-fix` | 적용된 수정이 원래 취약점을 실제로 닫았는지 검증(읽기 전용) | 없음 |
| `codex-security-scan-match` | 완료된 스캔 2개 사이 동일 근본 원인 finding 매칭 | 없음 |
| `codex-security-deep-scan` | 다중 패스 심층 스캔의 축소판(deep-lite — 공식 deep과 비동등) | 없음 |
| `codex-security-policy` | 저장소·컴포넌트의 SECURITY.md 초안 작성 — 초안은 저장소 밖에만 저장 | 없음 |
| `codex-security-classify-severity` | 완료된 스캔의 finding을 루브릭으로 심각도 재분류 — 결과는 스캔 디렉터리와 워크벤치에 저장 | 없음 |

## 요구사항

Claude Code(구독 로그인) · Python 3.10+ · git · codex-security 번들 플러그인.
Node 22+는 플러그인 npm 설치, 스캔의 후보 정규화(npm 0.2.0부터 상류 Node 헬퍼), 경로 지정 스캔과 diff 스캔
(npm 0.3.0부터 `bind-repo-scopes`·`copy-deep-review-input`이 Node 헬퍼), 스캔의 SECURITY.md 정책 해결(상류 Node 헬퍼),
`codex-security-policy`·`codex-security-classify-severity`, 공식 CLI 이력 조회에 필요하다.
Linux·macOS(Windows는 WSL).

검증된 조합: `@openai/codex-security@0.6.0` (플러그인 매니페스트 `0.1.95`). npm 0.1.26~0.6.0은 모두
매니페스트 `0.1.95`라서 매니페스트 버전 경고로 구분되지 않는다. 스킬은 버전 대신 플러그인 파일로 버전별 동작을
판별하고, `--check`는 npm 버전도 함께 보여 준다. npm 0.6.0을 설치한다. `repro-u8`은 npm 0.6.0·0.5.1 격리
설치본에서 모두 exit 0이다(0.5.1에서는 0.6.0 전용 검사 S13이 NOTE 1건을 낸다). 나머지 스크립트 네 개(`repro-u4`·`repro-u1`·`repro-u7`·`repro-u5`)도
두 설치본에서 모두 exit 0이다. 아래 0.5.0 결과는 v0.5.1 때 기록이고, 이번에는 다시 돌리지 않았다. npm 0.5.0에서는 `repro-u8`의
P7·P11만 실패했다. policy 공통 지시 한 줄이 0.5.1에서 바뀌어 고정 리터럴을 0.5.1 원문으로 갱신했기 때문이다
(의도한 드리프트 검출). 아래 0.4.0 이하 결과는
v0.5.0 때 기록이고, 이번에는 다시 돌리지 않았다. 다섯 개는 npm 0.4.0·0.3.0 격리 설치본에서 모두 exit 0이었다.
npm 0.2.0에서는 `repro-u4`·`repro-u1`·`repro-u7`·`repro-u5`가 통과한다(0.4.0 전용 동작 검사는 NOTE를 내고 돌지
않는다). `repro-u8`은 P7 한 건만 실패한다. policy 진행 문구가 0.3.0에서 바뀌어 고정 리터럴을 0.3.0 이후 원문으로 갱신했기 때문이다(의도한 드리프트 검출). npm 0.1.32 이하는 이번에 다시
검증하지 않았다.

npm 0.2.0부터 스캔 스킬은 npm 설치본이 필요하다. 상류 소스 체크아웃에는 빌드된 Node 헬퍼가 없어 후보
정규화를 할 수 없고, 스캔이 0단계에서 멈춘다. npm 0.3.0·0.4.0·0.5.0·0.5.1·0.6.0은 상태 DB 마이그레이션이 더 늘었다(0.3.0 스캔별 심각도 표,
0.4.0 issue receipt 표, 0.5.0 스캔 소스 범위 열, 0.5.1 deep 스캔 워커 스레드 표, 0.6.0 심각도 리뷰 횟수 열과 외부 소스 리포트 표). 전역 설치본을 올리기 전에 `~/.codex/state/plugins/codex-security`를 백업한다.

deep-lite 스킬은 npm 0.4.0에 맞춰 바뀌었다. 상류가 랭킹 헬퍼를 지웠으므로, 파일을 랭킹해 상위만 고르지 않고
인벤토리 전체를 서로 독립인 2패스로 리뷰한다. 비용은 표준 스캔의 약 2배다.

classify-severity 스킬은 npm 0.6.0에 맞춰 바뀌었다(상류 breaking 변경 #1765). 루브릭이 없으면 이제 기존 심각도를
상속하지 않는다. 상류 기본 루브릭으로 같은 서브에이전트 흐름을 타고 모델이 판정한다(CLI·인증 불필요). finding마다
독립 리뷰를 여러 번(기본 3회, `--runs 1–10`) 하고, 다수결은 상류 코드가 한다. 비용은 재사용되지 않는 finding마다
서브에이전트 N회(기본 3회)다. npm 0.5.1 이하는 이전 계약 그대로다. 루브릭이 없으면 모델을 부르지 않고, `--runs`는 거부한다.

npm 0.6.0부터 `codex-security-patch`·`codex-security-verify-fix`는 정적 검증 모드(`verificationMode: static`, #1854)도
지원한다. 사용자가 명시 요청할 때만 쓴다(예: "정적 검증", `--static`). 저장소 정의 스크립트를 실행하지 않으므로 patch는
1단 승인(저장소 변경)만 받고, verify-fix는 실행 승인을 요청하지 않는다. static에서 `fixed`이면 "정적 검증 — 런타임 검사
미실행"을 적는다. standard 모드는 기존 2단 승인 그대로다.

**`codex-security skills add`(npm 0.6.0에도 있음)를 실행하지 않는다.** 이 명령은 `~/.claude/skills/codex-security-<명령>`을
지우고, 로그인이 필요한 CLI를 부르기만 하는 상류 스킬 링크로 바꾼다. 이 저장소의 스킬 6개(scan, policy, patch,
validate, verify-fix, classify-severity)와 이름이 겹친다. `install.sh --check`가 덮어쓰인 스킬을 알려 준다.
`bash skills/install.sh --force`(복사본이면 `--copy --force`)로 다시 설치한다.

## 개발

```bash
git clone https://github.com/kall/codex-security-claude-skills
cd codex-security-claude-skills
bash skills/install.sh --link --check     # 링크 설치: 수정이 즉시 반영된다
```

이 저장소에는 업스트림 소스(`sdk/`)가 없으므로 개발자도 플러그인을 별도로 확보한다 —
`npm install -g @openai/codex-security`, 또는 업스트림을 clone해 두고
`CODEX_SECURITY_SDK_REPO=<clone 경로>`를 지정한다. 플러그인 매니페스트 `0.1.95`에서는 두 사본의
워킹트리 게이트 처리가 **같다**(종결 성공 + 경고). 과거 `0.1.14`에서는 사본에 따라 하드 실패와
경고로 갈렸으므로 `--check`는 여전히 이를 프로브한다. 자세한 내용은 매뉴얼 3.4절. 업스트림 체크아웃에는
빌드된 `mcp/`와 `dist/`가 없다. 그래서 SECURITY.md 정책 해결, `codex-security-policy`,
`codex-security-classify-severity`에는 npm 설치본이 필요하다.

플러그인 업데이트 후 계약 회귀 확인:

```bash
bash docs/verification/scripts/repro-u4.sh                 # 봉인 계약 + 인벤토리 정확성
bash docs/verification/scripts/repro-u1-search-command.sh  # 검색 명령 확보와 신뢰 게이트
bash docs/verification/scripts/repro-u7-coverage-recovery.sh  # 커버리지 정직성 + 복구 경로
bash docs/verification/scripts/repro-u5-match-validator.sh # 매칭 검증기
bash docs/verification/scripts/repro-u8-policy-severity.sh # SECURITY.md 초안·심각도 재분류 결정론 부분
bash docs/verification/scripts/repro-u3.sh                 # 워크벤치 계약(관측형)
```

앞의 다섯은 자기 채점형이다 — **exit 0** = 전부 통과, **exit 2**(`INCOMPLETE`) = 전제 부족으로
검증하지 못한 블록이 있음(통과 아님), **exit 1** = 단언 실패. 저장소 전체 스캔은 ripgrep을
요구하므로(상류 인벤토리 스크립트가 `rg`를 PATH에서만 해석한다) PATH에 `rg`가 없으면 Claude Code
내장 ripgrep을 심링크로 노출해 쓴다 — 둘 다 없으면 스캔이 시작되지 않고 `repro-u4.sh`·
`repro-u1-search-command.sh`는 exit 2다.

- 배포본 빌드·릴리즈 절차: [docs/releasing.md](docs/releasing.md)
- 설계 배경과 필수 계약 13개: [docs/solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md](docs/solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md)
- 단계별 실측 검증: [docs/verification/](docs/verification/)

## 라이선스

Apache-2.0. 업스트림 출처와 파생 관계는 [NOTICE](NOTICE) 참조.
