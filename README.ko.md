# Claude 로컬 보안 스킬 (codex-security-claude-skills)

[English](README.md) | 한국어

OpenAI/Codex 인증 없이 **Claude Code 구독 로그인만으로** [codex-security](https://github.com/openai/codex-security)
의 보안 스캔 워크플로를 실행하는 Claude Code 스킬 6종.

LLM 두뇌 역할은 Claude Code 세션 자신이 맡고, 검증·ID 파생·봉인·리포트 생성은 codex-security
번들 플러그인의 결정론(deterministic) Python 스크립트가 담당한다. 플러그인은 벤더링하지 않고
**설치된 것을 런타임에 찾아 쓴다.**

> 이 실행 경로는 비(非) Codex 경로이며 **업스트림 OpenAI 지원 대상이 아니다.**

## 설치 (사용자)

릴리즈 tarball을 받아 설치한다. 링크를 Claude Code 세션에 주고 "설치해줘"라고 해도 된다.

```bash
BASE=https://github.com/kall/codex-security-claude-skills/releases/latest/download
PKG=codex-security-claude-skills-<version>

curl -fsSLO "$BASE/$PKG.tar.gz"
curl -fsSL  "$BASE/SHA256SUMS" | sha256sum -c -
tar xzf "$PKG.tar.gz"
bash "$PKG/skills/install.sh" --copy --check
```

`--check`가 번들 플러그인·Python·게이트 사본을 프로브해 보고한다. 플러그인이 없으면 설치할
명령을 안내한다(자동 설치는 하지 않는다):

```bash
npm install -g @openai/codex-security     # Node 22+
```

Claude Code를 재시작한 뒤 호출한다:

```
/security-scan-local /path/to/repo
```

전체 사용법·환경변수·트러블슈팅: **[docs/install-and-usage.md](docs/install-and-usage.md)**

## 스킬

| 스킬 | 용도 | 저장소 변경 |
| --- | --- | --- |
| `security-scan-local` | 저장소 전체 1회 표준 스캔 → 봉인 계약 산출물 + `report.md` + SARIF | 없음 |
| `security-diff-scan-local` | 변경분(refs 또는 working-tree)만 스캔 | 없음 |
| `security-validate-local` | 후보 finding 진위 판정(disposition) | 없음 |
| `security-patch-local` | 보안 이슈 최소 수정 — 2단 승인 | 있음(승인 후) |
| `security-scan-match-local` | 완료된 스캔 2개 사이 동일 근본 원인 finding 매칭 | 없음 |
| `security-deep-scan-local` | 다중 패스 심층 스캔의 축소판(deep-lite — 공식 deep과 비동등) | 없음 |

## 요구사항

Claude Code(구독 로그인) · Python 3.10+ · git · codex-security 번들 플러그인.
Node 22+는 플러그인 npm 설치와 공식 CLI 이력 조회에만 필요하다. Linux·macOS(Windows는 WSL).

검증된 조합: `@openai/codex-security@0.1.3` (플러그인 매니페스트 `0.1.14`).

## 개발

```bash
git clone https://github.com/kall/codex-security-claude-skills
cd codex-security-claude-skills
bash skills/install.sh --link --check     # 링크 설치: 수정이 즉시 반영된다
```

이 저장소에는 업스트림 소스(`sdk/`)가 없으므로 개발자도 플러그인을 별도로 확보한다 —
`npm install -g @openai/codex-security`, 또는 업스트림을 clone해 두고
`CODEX_SECURITY_SDK_REPO=<clone 경로>`를 지정한다. **같은 플러그인 매니페스트 버전에서도 사본에
따라 워킹트리 게이트 처리가 다르므로**(하드 실패 vs 경고), 두 사본을 비교하려면 업스트림 clone이
필요하다. 자세한 내용은 매뉴얼 3.4절.

플러그인 업데이트 후 계약 회귀 확인:

```bash
bash docs/verification/scripts/repro-u4.sh    # 봉인 계약
bash docs/verification/scripts/repro-u3.sh    # 워크벤치 계약
```

- 배포본 빌드·릴리즈 절차: [docs/releasing.md](docs/releasing.md)
- 설계 배경과 필수 계약 8개: [docs/solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md](docs/solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md)
- 단계별 실측 검증: [docs/verification/](docs/verification/)

## 라이선스

Apache-2.0. 업스트림 출처와 파생 관계는 [NOTICE](NOTICE) 참조.
