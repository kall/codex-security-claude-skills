# Claude Code 스킬 (security-scan-local)

이 디렉터리는 **Claude Code 스킬의 정본(canonical source)** 이다. `~/.claude/skills/` 아래의 것은
여기서 설치된 사본 또는 링크일 뿐이므로, 수정은 항상 이 저장소에서 한다.

- `security-scan-local/` — 메인 스캔 스킬 (`SKILL.md`, `scripts/`)
- `install.sh` — 전역 스킬 디렉터리로 설치하는 스크립트

## 설치

```bash
bash skills/install.sh            # 기본: 링크 모드
bash skills/install.sh --copy     # 복사 모드
bash skills/install.sh --link --force   # 기존 설치본 덮어쓰기
```

설치 위치는 `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/security-scan-local` 이다.
`CLAUDE_SKILLS_DIR` 를 지정하면 다른 경로로 설치할 수 있어 테스트에 유용하다.

### 링크 모드 vs 복사 모드

| 모드 | 동작 | 용도 |
|---|---|---|
| `--link` (기본) | 저장소 디렉터리로 심볼릭 링크 생성 | 개발. 저장소 수정이 즉시 반영된다. |
| `--copy` | 실제 복사본 생성 | 배포·검증. 저장소를 수정한 뒤에는 `--copy --force` 로 재설치해야 반영된다. |

대상 경로가 이미 있으면 설치를 **거부**한다. 의도적으로 덮어쓸 때만 `--force` 를 붙인다.

## 지원 범위

이 스킬은 **비 Codex 실행 경로**다. LLM 두뇌 역할을 Codex 네이티브 바이너리 대신 Claude Code
자신(구독 로그인)이 수행하며, OpenAI 인증(ChatGPT 로그인, `OPENAI_API_KEY`)을 사용하지 않는다.
따라서 **업스트림 OpenAI 지원 대상이 아니다.** 스킬 실행 중 발생하는 문제는 이 저장소에서 다룬다.

재사용하는 자산은 번들 플러그인의 결정적(deterministic) 부분 — 워크벤치 스크립트, 계약 검증,
리포트/SARIF 생성, JSON 스키마 — 이며, TypeScript SDK/CLI 코드는 수정하지 않는다.

## 이력 호환 범위

- **Phase 1 (현재)**: 워크벤치 없이 단독 스캔을 수행하고 산출물(`report.md`, SARIF)을 생성한다.
  이 단계의 스캔은 기존 CLI 이력(`codex-security scans list`)에 나타나지 않는다.
- **Phase 2**: 워크벤치 연동을 추가한다. `register-cli-scan` 으로 스캔을 등록하고
  `get-scan-feedback` 으로 과거 false-positive 피드백을 반영하므로, 기존 CLI 의
  `scans list` / `scans show <id>` 에서 Claude 스캔도 함께 보이게 된다.
