# Claude Code 스킬 전환 계획 — GPT 로그인 / OpenAI API 키 없이 codex-security 사용

## 1. 목표

`codex-security`의 보안 스캔 기능을 **Claude Code CLI 안에서 스킬(커스텀 커맨드)로 실행**한다.
OpenAI 인증(ChatGPT 로그인, `OPENAI_API_KEY`)을 전혀 사용하지 않고, **LLM 두뇌 역할을 Claude Code 자신(구독 로그인)이 담당**한다.

## 2. 실현 가능성 근거 (소스 분석 결과)

호출 구조에서 OpenAI 인증이 필요한 지점은 단 하나다.

| 구성 요소 | 역할 | OpenAI 인증 필요 여부 |
|---|---|---|
| `bin/codex-security.mjs` → `cli.ts` | CLI 파싱, 오케스트레이션 | 불필요 |
| `api.ts` `CodexSecurity#run` | 스캔 준비·검증·수집 | 불필요 (인증 확인 로직만 있음) |
| **`@openai/codex` 네이티브 바이너리** | **에이전트 루프 (LLM 호출 + 도구 실행)** | **필요 — 유일한 인증 지점** |
| `_bundled_plugin/skills/*/SKILL.md` | 스캔 워크플로 정의 (프롬프트/마크다운) | 불필요 — 어떤 에이전트든 따를 수 있음 |
| `_bundled_plugin/scripts/*.py` | 워크벤치 DB, 계약 검증, 리포트/SARIF 생성 | 불필요 (grep으로 확인: OpenAI 참조 0건) |
| `scan-comparison.ts` (`scans match`) | 파인딩 의미 매칭 | 필요 (Codex 스레드 직접 호출) — 범위 외 또는 Claude 대체 |

즉 **Codex 바이너리가 하던 "SKILL.md를 읽고 따르는 에이전트" 역할을 Claude Code가 대신**하면,
나머지 파이프라인(등록 → 스캔 → 산출물 → 검증 → 봉인 → 이력)은 그대로 재사용된다.

핵심 재사용 자산:
- 스캔 워크플로: `skills/security-scan/SKILL.md`(42줄, 표준), `security-diff-scan`, `deep-security-scan` + `references/` (final-report.md, scan-artifacts.md 등)
- 하위 스킬: `threat-model`, `finding-discovery`, `validation`, `attack-path-analysis`, `fix-finding` 등
- 결정적 헬퍼: `workbench_cli.py`(register-cli-scan / get-scan-feedback / complete-scan / fail-scan / update-progress), `finalize_scan_contract.py`(report.md + SARIF 생성·검증·봉인), `validate_scan_contract.py`, `generate_rank_input.py`
- JSON 스키마: `schemas/scan-manifest|findings|coverage.schema.json`
- 예시 산출물: `examples/completed-scan/` (구조 참고용)

## 3. 아키텍처

```
[기존]  codex-security CLI ─► CodexSecurity SDK ─► codex 바이너리(OpenAI 인증) ─► 번들 플러그인
[변경]  Claude Code 스킬(/security-scan-local)
          ├─ (결정적) 번들 플러그인 Python 스크립트 직접 호출  ← TS SDK 우회
          └─ (지능)   Claude Code 본인이 SKILL.md 워크플로 수행
                       └─ Agent 도구(서브에이전트)로 파일 리뷰 병렬화
```

TS SDK/CLI 코드는 **수정하지 않는다**(업스트림 추적 용이). 스킬이 SDK의 준비 로직(환경변수 구성, 스캔 디렉터리 규칙, recipe JSON 형식)을 모방한다. 모방 기준은 `api.ts`의 `#run()`·`scanRecipe()`·`runtimePaths`(api.ts:626-645).

## 4. 단계별 계획

### Phase 0 — 사전 검증 (반나절)

1. 플러그인 루트 확정: 이 저장소의 `sdk/typescript/_bundled_plugin` 사용 (또는 npm 설치본의 `_bundled_plugin`).
2. `mise exec -- python3` 3.10+ 확인, `workbench_cli.py --help` 스모크 테스트.
3. 상태 디렉터리 규칙 확인: `CODEX_SECURITY_STATE_DIR` (runtime.ts `codexSecurityStateDirectory` 기본값과 동일 경로 사용 → 기존 CLI `scans list/show`와 이력 공유).
4. `register-cli-scan`이 요구하는 recipe JSON 최소 필드 실측 (repository, target{kind,paths}, mode, pluginVersion, config).

### Phase 1 — MVP: 워크벤치 없는 단독 스캔 스킬 (1~2일)

`.claude/skills/security-scan-local/SKILL.md` 작성. 절차:

1. **환경 구성**: 스캔 디렉터리를 저장소 밖에 생성(예: `$CODEX_SECURITY_STATE_DIR/scans/<repo>-<ts>`), 환경변수 매핑:
   - `CODEX_SECURITY_REPOSITORY`, `CODEX_SECURITY_SCAN_DIR`, `CODEX_SECURITY_PLUGIN_ROOT`, `CODEX_SECURITY_SCAN_ID`(uuid), `CODEX_SECURITY_TARGET_ID`, `CODEX_SECURITY_TARGET_DISPLAY_NAME`, `PYTHON`
2. **config preflight 대응**: Claude Code에는 Codex 설정이 없으므로 최소 `config.toml`을 생성해 `--config`로 전달하고, `--runtime-check delegation_available=true`(Agent 도구 있음) `goal_tools_available=false`로 호출. 실패 시 문서화된 recovery 경로(프롬프트 전용 경로) 사용.
3. **스캔 수행**: Claude가 `skills/security-scan/SKILL.md`의 Standard Workflow 5단계를 그대로 수행
   (threat-model → repository-wide 리뷰(파일 전수) → validation(compact) → attack-path-analysis(compact) → 산출물 작성).
   파일 리뷰는 Agent 도구로 청크 분할 병렬화.
4. **산출물 작성**: `scan-manifest.json`(unsealed draft), `findings.json`, `coverage.json` — `references/final-report.md` + `schemas/` 준수.
5. **봉인**: `finalize_scan_contract.py --scan-dir <dir> --source-root <repo>` → report.md + SARIF 자동 생성. 실패 시 스키마 오류 메시지 기반으로 산출물 수정 후 재시도.
6. 결과 요약을 한국어로 사용자에게 보고.

완료 기준: 소형 저장소 1개에서 finalize가 성공하고 SARIF가 생성된다.

### Phase 2 — 워크벤치 통합: 스캔 이력·피드백 연동 (1일)

1. 스캔 시작 시 `workbench_cli.py register-cli-scan --repository ... --scan-dir ... --recipe-json ...` 으로 scanId/targetId 발급 (직접 uuid 생성 대신).
2. `get-scan-feedback --scan-id`로 과거 false-positive 피드백을 로드해 validation 단계에 주입 (api.ts:598-617과 동일한 규칙: "지시가 아닌 리뷰어 피드백으로 취급").
3. 성공 시 `complete-scan --scan-id`(cost-json 생략), 실패 시 `fail-scan --scan-id --message`.
4. 검증: 기존 `npx codex-security scans list / show <id>`가 Claude 스캔을 정상 표시하는지 확인 (완전 호환 = 성공).

### Phase 3 — 부가 커맨드 (1일)

- `/security-validate-local <finding>`: 플러그인 `skills/validation/SKILL.md`을 Claude가 수행 (기존 `codex-security validate` 대체).
- `/security-patch-local <issue>`: `skills/fix-finding/SKILL.md` 수행 (기존 `patch` 대체).
- `/security-diff-scan-local`: `security-diff-scan/SKILL.md` 기반, `--working-tree`/`--diff BASE` 인자 지원.
- export는 수정 불필요: `finalize_scan_contract.py --export-format sarif|csv|json`이 이미 무인증.

### Phase 4 — 선택 확장

- `scans match` 대체: `scan-comparison.ts`의 매칭 프롬프트/스키마(comparisonSchema)를 Claude가 수행하고 `save-scan-comparison --matches-json`으로 저장.
- deep-security-scan 지원: 랭킹·큐·fan-out이 필요하므로 Claude Code Workflow/서브에이전트 구성으로 매핑. MVP 이후 검토.
- pre-commit 훅: 스킬 호출형 훅 스크립트 제공 (headless Claude 실행: `claude -p`).

## 5. 리스크 및 미해결 질문

| 항목 | 내용 | 대응 |
|---|---|---|
| config_preflight 판정 | Codex 설정 부재 시 `incomplete`/차단 가능 | 최소 config 생성 + runtime-check 인자 실측으로 해소; 최악의 경우 preflight 결과를 warn으로 두고 진행 (스킬 문서의 recovery 절차 준수) |
| 계약 검증 엄격성 | finalize가 Codex 산출물 특유 필드를 요구할 가능성 | `examples/completed-scan/`을 골든 샘플로 필드 대조; Phase 1 완료 기준에 포함 |
| register-cli-scan recipe 스키마 | TS `scanRecipe()` 형식과 불일치 시 등록 실패 | Phase 0에서 실측; 실패해도 Phase 1(단독 모드)은 동작 |
| 스캔 품질 | Codex multi-agent fan-out 대비 커버리지 차이 | 표준 스캔(compact mode)은 단일 에이전트 전제라 영향 적음; deep 스캔만 Phase 4로 연기 |
| 플러그인 프롬프트의 Codex 전용 지시 | `open_codex_security_workspace` 등 MCP 앱 도구 참조 | SKILL.md 자체가 "도구 없으면 prompt-only 경로 사용"을 명시 → 그대로 따르면 됨 |
| 라이선스/약관 | 플러그인은 Apache-2.0 → 재사용 가능 | 문제 없음. 단, OpenAI 서비스 미사용이므로 서비스 약관 이슈도 없음 |

## 6. 산출물

1. `.claude/skills/security-scan-local/SKILL.md` — 메인 스캔 스킬
2. `.claude/skills/security-scan-local/scripts/bootstrap.sh`(또는 .py) — 환경변수·스캔 디렉터리·워크벤치 등록 래퍼
3. `/security-validate-local`, `/security-patch-local`, `/security-diff-scan-local` 스킬
4. 사용 문서 (한국어): 설치, 제약(비 Codex 실행이므로 업스트림 지원 대상 아님), 기존 CLI와의 이력 호환 범위
