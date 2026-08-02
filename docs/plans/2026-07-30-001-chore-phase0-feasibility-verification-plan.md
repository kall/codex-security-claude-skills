---
title: Phase 0 — Claude 로컬 스캔 실행 기반 검증 - Plan
type: chore
date: 2026-07-30
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Phase 0 — Claude 로컬 스캔 실행 기반 검증 - Plan

**시리즈**: Claude Code 전역 스킬로 codex-security를 OpenAI 인증 없이 실행하기 (Phase 0/4)
**후속 문서**: [Phase 1](2026-07-30-002-feat-phase1-standalone-scan-skill-plan.md) · [Phase 2](2026-07-30-003-feat-phase2-workbench-integration-plan.md) · [Phase 3](2026-07-30-004-feat-phase3-validate-patch-diff-plan.md) · [Phase 4](2026-07-30-005-feat-phase4-matching-deep-scan-plan.md)

---

## Goal Capsule

- **목표**: Phase 1~4 구현에 앞서 계획의 전제 7가지를 재현 가능한 실측으로 고정하고, 항목별 통과 기준에 따라 go/no-go를 판정한다.
- **권위 순서**: 이 문서 → 번들 플러그인 실제 동작(실측) → 시리즈 공통 결정(KTD).
- **중지 조건과 항목별 판정** (R7의 통과 기준표가 권위):
  - **U1 탐색 체인** 실패(어떤 설치 형태에서도 플러그인을 못 찾음) → 시리즈 전체 no-go, 플러그인 경로를 사용자 설정으로 받는 설계로 전환.
  - **U6 프롬프트 준수** 실패(Claude가 5단계 워크플로를 완주하지 못함) → Phase 1을 "단계별 별도 스킬 호출" 구조로 재설계하고 Phase 3·4의 스킬 구성도 재작성. 시리즈 최대 하중 항목.
  - **U3 워킹트리 게이트** 무변경 상태에서도 실패 → Phase 2 no-go, Phase 1(순수 로컬)만 진행.
  - **U4 픽스처** 봉인 실패 → Phase 1 no-go, 산출물 계약 재조사.
  - 단순 환경 문제(Python 미설치, npm 미설치)는 중지 사유가 아니며 요구사항으로 문서화한다.
- **산출물**: `docs/verification/phase0-results.md` (한국어 검증 보고서) + 탐색 체인 프로토타입 스크립트.

---

## Product Contract

### Summary

번들 플러그인(`sdk/typescript/_bundled_plugin/`)의 결정론 계층이 OpenAI 인증 없이 Claude Code 환경에서 동작한다는 사전 조사 결과와, Claude가 플러그인 워크플로를 프롬프트만으로 완주할 수 있다는 미검증 가정을 **반복 실행 가능한 검증 절차**로 고정한다.

### Problem Frame

사전 조사에서 finalizer 독립 동작, preflight 프로필 구성, complete-scan 워킹트리 게이트가 확인되었으나 이는 일회 관찰이다. 더 중요한 것은 시리즈의 최대 하중 가정 — "SKILL.md 지침만으로 Claude가 5단계 스캔 워크플로를 통제할 수 있다" — 이 아직 아무 근거도 없다는 점이다. 이 가정이 틀리면 Phase 1의 스킬 1개가 아니라 Phase 3의 3개·Phase 4의 2개 스킬 구조까지 재작성된다. 결정론 계층 검증만 하고 넘어가면 가장 비싼 오류를 가장 늦게 발견한다. 또한 전역 스킬의 플러그인 루트 탐색은 임의 저장소에서 실행되므로 신뢰 경계 결정이 선행되어야 한다.

### Requirements

**실행 환경**
- R1. 플러그인 루트 탐색이 3가지 신뢰 가능한 설치 형태(저장소 체크아웃, `npm install -g`, npx 캐시)에서 각각 성공/실패 여부와 실제 경로가 기록되어야 하고, 대상 저장소 하위 사본은 거부됨이 확인되어야 한다.
- R2. Python 인터프리터 검증 로직이 SDK의 `usablePython()`(`sdk/typescript/src/runtime.ts`)과 동일한 판정(≥3.10, 3.10이면 `tomli` 필요)을 내려야 한다.

**계약 재현**
- R3. `register-cli-scan` → 저장소 파일 1줄 수정 → `complete-scan` 시퀀스에서 워킹트리 불변 게이트 실패가 재현되고, finalize-first 순서로 `report.md`가 보존됨이 확인되어야 한다. 또한 `get-scan`이 반환하는 contract 필드(producer, target 좌표, revision, snapshotDigest, scope)가 실측되어야 한다 — Phase 2가 draft에 반영해야 하는 값이다.
- R4. 골든 샘플(`sdk/typescript/_bundled_plugin/examples/completed-scan/`) 수준의 최소 unsealed draft가 `finalize_scan_contract.py`로 exit 0 봉인됨이 픽스처로 고정되어야 한다.
- R5. `config_preflight.py --profile security_scan`을 Claude Code 조건에서 실행해 상태(`ready`/`incomplete`)와 미충족 능력 목록이 기록되어야 한다 — Phase 1의 degraded path 서술 근거.

**워크플로 이식성**
- R6. `skills/security-scan/SKILL.md`와 그것이 읽도록 지시하는 참조 문서들의 지시를 "Codex/MCP 전용"과 "이식 가능"으로 분해한 매핑 표가 작성되어야 한다.
- R7. Claude가 소형 저장소에서 플러그인 5단계 워크플로를 프롬프트 지침만으로 완주할 수 있는지 실측되어야 하고, 결과가 항목별 통과 기준표와 함께 go/no-go 판정으로 기록되어야 한다.

### Scope Boundaries

- 스킬 파일 본체(`skills/codex-security-scan/SKILL.md`) 작성은 하지 않는다 — Phase 1의 몫. U6은 임시 프롬프트로 워크플로 완주 가능성만 본다.
- 워크벤치 DB 스키마의 마이그레이션·다운그레이드 검증은 하지 않는다 — Phase 2의 Risks 항목으로 넘긴다.
- TS SDK/CLI 및 번들 플러그인 소스는 수정하지 않는다.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **무수정 래퍼 방식** — TS SDK·번들 플러그인을 수정하지 않고 검증도 외부 스크립트로만 수행한다. (session-settled: user-approved — TS SDK에 별도 엔진 모드를 추가하는 방식 대신 선택: 업스트림 추적 용이성)
- KTD2. **검증은 실행 가능한 스크립트로 고정** — 보고서에 명령·exit code·출력 원문을 남겨 이후 플러그인 버전 업데이트 시 회귀 검증에 재사용한다.
- KTD3. **플러그인 탐색 체인 프로토타입은 Python으로 작성** — Phase 1의 `bootstrap.py`로 승격될 예정이므로 처음부터 Python으로 작성한다.
- KTD4. **스캔 대상 저장소는 플러그인 공급자가 될 수 없다** — 탐색 후보에서 대상 저장소 하위 경로(프로젝트 `node_modules` 포함)를 제외하고, 확정된 pluginRoot가 대상 저장소 하위이면 실패시킨다. 스캔 대상은 정의상 미신뢰 코드이고, 선택된 사본이 실행되는 Python 스크립트·스캔 워크플로 프롬프트·상태 DB 쓰기 권한을 모두 소유하기 때문이다. SDK의 `bundledPluginCandidates()`는 자기 모듈 경로 기준 2개 후보만 보므로 이 공격면은 전역 스킬이 새로 만드는 것이다.
- KTD5. **프롬프트 준수 검증을 결정론 검증과 동급으로 취급** — 시리즈의 최대 하중 가정이 프롬프트 계층에 있으므로, Python 계층 검증만으로 go 판정을 내리지 않는다.

### Assumptions

- 검증용 소형 저장소는 임시 디렉터리에 생성한 합성 Git 저장소로 충분하다.
- 사전 조사에서 확인된 결정론 계층 사실은 이 Phase에서 재확인 성격이며 뒤집힐 가능성이 낮다 — U6과 달리 no-go 확률이 낮은 항목이다.

---

## Implementation Units

### U1. 플러그인 루트 탐색 체인 프로토타입

- **Goal**: 임의 cwd에서 신뢰 가능한 번들 플러그인 루트를 찾는 탐색 체인을 구현하고, 대상 저장소 사본을 거부함을 실증한다.
- **Requirements**: R1
- **Dependencies**: 없음
- **Files**: 프로토타입 스크립트(임시 위치, Phase 1에서 `skills/codex-security-scan/scripts/bootstrap.py`로 승격), 결과는 `docs/verification/phase0-results.md`
- **Approach**:
  1. 탐색 순서: `CODEX_SECURITY_PLUGIN_ROOT` 환경변수(스킬 자체 규약) → `npm root -g` 하위 → npx 캐시(`~/.npm/_npx/*/node_modules/...`) → 스킬 개발용 저장소 체크아웃(`sdk/typescript/_bundled_plugin`). **프로젝트 `node_modules`는 후보에서 제외한다**(KTD4).
  2. 신뢰 게이트: 확정된 pluginRoot의 realpath가 대상 저장소 realpath 하위이면 무조건 실패. `CODEX_SECURITY_PLUGIN_ROOT`도 같은 게이트를 통과해야만 채택한다.
  3. 판정은 `.codex-plugin/plugin.json` 존재에 더해 `name`/`version` 필드를 확인하고, 선택된 사본의 절대 경로와 버전을 반환값에 담아 스캔 시작 고지에서 사용자에게 보인다.
  4. 3가지 설치 형태를 실제로 구성해 탐색 성공 여부·소요 시간·복수 사본 존재 시 우선순위를 기록한다.
- **Patterns to follow**: `sdk/typescript/src/runtime.ts`의 `bundledPluginRoot()`/`hasPluginManifest` 판정 로직 (후보 목록은 의도적으로 다르게 구성)
- **Test scenarios**:
  - 전역 설치(`npm install -g @openai/codex-security`) 환경에서 전역 경로가 반환된다.
  - 대상 저장소에 `node_modules/@openai/codex-security/_bundled_plugin/.codex-plugin/plugin.json`을 심어도 후보로 선택되지 않는다.
  - `CODEX_SECURITY_PLUGIN_ROOT`가 대상 저장소 내부를 가리키면 거부되고 사유가 출력된다.
  - 어떤 신뢰 가능한 사본도 없으면 설치 안내 문구를 포함한 실패 JSON이 반환된다.
  - `plugin.json`의 `name`이 예상값과 다르면 거부된다.
- **Verification**: 3가지 형태별 결과 표와 거부 시나리오 3종 로그가 보고서에 존재하고, 성공 시 `{pluginRoot, version}` JSON이 출력된다.

### U2. Python 인터프리터 판정 재현

- **Goal**: SDK `usablePython()`과 동일한 검사(≥3.10, 3.10+`tomli`)를 탐색 체인에 통합한다.
- **Requirements**: R2
- **Dependencies**: U1
- **Files**: U1 스크립트에 통합
- **Approach**: SDK와 동일한 인라인 검사 코드를 서브프로세스로 실행하고, 후보 순서(`$PYTHON` → `python3` → `python`)도 동일하게 따른다. `python -I -B` 실행 규약을 확정한다.
- **Test scenarios**:
  - 3.11+ 환경에서 통과한다.
  - `$PYTHON`이 잘못된 경로면 다음 후보로 넘어간다.
  - (가능하면) 3.10 + tomli 부재 환경에서 명확한 실패 메시지가 나온다.
- **Verification**: 판정 결과가 U1의 JSON 출력에 `python` 필드로 포함된다.

### U3. 워크벤치 계약 실측 — 게이트·contract·finalize 순서

- **Goal**: Phase 2가 의존하는 세 계약(워킹트리 불변 게이트, `get-scan` contract 필드, finalize-first 순서)을 한 번의 시퀀스로 실측한다.
- **Requirements**: R3
- **Dependencies**: U1, U2
- **Files**: 검증 절차 스크립트(임시), 결과는 보고서
- **Approach**:
  1. 합성 Git 저장소 생성 → 저장소 밖 빈 scan-dir 생성 → `workbench_db.py register-cli-scan`(최소 recipe: `{repository, mode:"standard", config:{}, target:{kind:"repository", paths:[]}}`, claim token 없음) → 반환된 `{scanDir, scanId, targetId}` 기록.
  2. `workbench_db.py get-scan --scan-id <id>` 실행 → 반환 contract에서 draft가 사전 일치시켜야 하는 필드 전체(producer name/version, target kind·targetId·displayName, revision, snapshotDigest, scope includePaths/excludePaths, coverage.mode 기대값)를 표로 정리.
  3. 그 값을 반영한 draft 작성 → `finalize_scan_contract.py` 실행(봉인 성공 확인) → 저장소 파일 1줄 수정 → `complete-scan` 실행 → "Working-tree contents changed" 실패 확인 → scan-dir 산출물 온전함 확인.
  4. 동일 절차를 저장소 무변경으로 반복해 `complete-scan` 성공과 `scans show` 조회 가능을 확인한다.
- **Patterns to follow**: `sdk/typescript/_bundled_plugin/scripts/workbench_db.py`의 `require_unchanged_target`(1375행), `register_cli_scan`(1574행), `finalize_scan_contract.py`의 sealed 매니페스트 검증 경로(912-950행 부근)
- **Test scenarios**:
  - `get-scan` contract 필드 표가 완성되고, 그 값을 반영하지 않은 draft는 complete-scan에서 거부됨이 확인된다.
  - 저장소 수정 후 complete-scan이 실패하되 scan-dir의 `report.md`·SARIF는 온전하다.
  - 무변경 시 complete-scan이 성공하고 상태 DB에 `complete` 행이 생긴다.
  - `--claim-token`을 전달하면 실패한다(전달 금지 규약 확인).
- **Verification**: contract 필드 표 + 두 시나리오의 명령·exit code·핵심 stderr가 보고서에 기록된다.

### U4. 최소 unsealed draft 픽스처 고정

- **Goal**: 모델이 작성해야 하는 최소 필드 집합을 픽스처로 고정하고 finalizer 통과를 보장한다.
- **Requirements**: R4
- **Dependencies**: U2
- **Files**: 픽스처 JSON 3종(`docs/verification/fixtures/`), 결과는 보고서
- **Approach**: 골든 샘플에서 finalizer가 덮어쓰는 필드(`findingId`, `occurrenceId`, `fingerprints`, `sealedAt`, `artifacts`, `documentType`, `schemaVersion` 등)를 제거한 draft를 만들고, `CODEX_SECURITY_STARTED_AT` 주입 → finalize exit 0 → `validate_scan_contract.py` exit 0을 확인한다. 오류 유도 케이스(대문자 ruleId, coverage includePaths 불일치)도 1건씩 실행해 stderr 메시지 형태를 기록한다 — Phase 1 리페어 루프의 입력.
- **Test scenarios**:
  - 최소 draft가 봉인되고 `report.md`·`exports/results.sarif`가 생성된다.
  - 잘못된 `ruleId` slug는 "expected a stable lowercase rule slug" 계열 오류로 거부된다.
  - findings의 `locations` 경로가 실존하지 않아도 통과함(경로 미검증)이 확인된다 — Phase 1에서 자체 검사 필요성의 근거.
- **Verification**: 픽스처와 실행 로그가 보고서에 포함된다.

### U5. SKILL.md 번역 매핑 표

- **Goal**: 플러그인 워크플로 문서군의 지시를 Claude Code 관점에서 3분류한 매핑 표를 만든다.
- **Requirements**: R6
- **Dependencies**: 없음 (U1~U4와 병렬 가능)
- **Files**: `docs/verification/phase0-results.md` 내 섹션
- **Approach**: 각 지시를 ① 그대로 따름(워크플로 5단계, 산출물 규약) ② 대체 실행(`$threat-model` 등 스킬 참조 → 플러그인 스킬 파일 직접 읽기, MCP 완료 도구 → 워크벤치 CLI) ③ 무시(데스크톱 앱 지시, MCP 앱 도구 호출)로 분류한다. 대상 문서: `skills/security-scan/SKILL.md`, `skills/security-scan/references/repository-wide-scan.md`(표준 워크플로 2단계가 읽도록 지시하는 문서 — `in_scope_files.txt` 생성, 후보 원장 원시 행 스키마, `normalize_candidates.py` 호출 규약을 소유), `references/scan-artifacts.md`, `references/final-report.md`, `references/config-preflight.md`, `references/shared-hard-rules.md`.
- **Test scenarios**: Test expectation: none — 분석 산출물(문서)이며 행위 변경이 없음.
- **Verification**: Phase 1 계획의 U2(SKILL.md 본체)가 이 표만 보고 번역 지침을 쓸 수 있는 수준의 구체성. 특히 `normalize_candidates.py`·`bind-repo-scopes` 같은 필수 스크립트 호출이 표에 빠짐없이 등장한다.

### U6. 프롬프트 워크플로 완주 실측

- **Goal**: 시리즈 최대 하중 가정 — SKILL.md 지침만으로 Claude가 5단계 워크플로를 통제할 수 있는지 — 를 실측한다.
- **Requirements**: R5, R7
- **Dependencies**: U1, U2, U5
- **Files**: 임시 프롬프트(스킬 파일이 아닌 일회성 지침), 결과는 `docs/verification/phase0-results.md`
- **Approach**:
  1. `config_preflight.py --profile security_scan --cwd <repo> --runtime-check delegation_available=true --runtime-check goal_tools_available=false`를 실행해 상태와 미충족 능력을 기록(R5).
  2. 50~150 파일 규모의 합성 저장소에 취약점 1건을 심고, U5 매핑 표 기반 임시 프롬프트로 5단계(위협 모델 → 인벤토리·전 파일 리뷰 → validation → attack-path → canonical JSON)를 수행시킨다. 스킬 파일화 없이 세션 내 지침으로만 진행한다.
  3. 측정 항목: 각 단계 완주 여부, 단계 건너뛰기·순서 위반 발생, 컨텍스트 소진 시점, 산출물 규약 준수율(금지 필드 작성 여부), 심은 취약점 검출.
  4. 완주하지 못한 경우 실패 지점과 원인을 기록하고 Goal Capsule의 대응(단계별 별도 스킬 구조)이 필요한지 판정한다.
- **Test scenarios**: Test expectation: none — 실측 결과 자체가 산출물이며, 통과 기준은 아래 Verification이 정의한다.
- **Verification**: 5단계 중 최소 4단계가 지침대로 수행되고 canonical JSON 3종이 생성되면 go. 3단계 이하이거나 순서 위반이 반복되면 no-go로 판정하고 Phase 1 재설계 항목을 명시한다.

---

## Verification Contract

| 게이트 | 명령/기준 | 미달 시 |
|---|---|---|
| 탐색 체인 | 3가지 설치 형태 표 + 거부 시나리오 3종 통과 | 시리즈 no-go (경로 사용자 설정 설계로 전환) |
| Python 판정 | `mise exec -- python3` 기준 통과, 실패 경로 메시지 확인 | 요구사항으로 문서화 (중지 아님) |
| 워크벤치 계약 | contract 필드 표 완성 + complete-scan 실패/성공 두 시나리오 | 무변경 실패 시 Phase 2 no-go |
| 픽스처 | `finalize_scan_contract.py` exit 0 + `validate_scan_contract.py` exit 0 | Phase 1 no-go |
| 프롬프트 완주 | 5단계 중 4단계 이상 수행 + canonical JSON 3종 생성 | Phase 1~4 스킬 구조 재설계 |
| 보고서 | `docs/verification/phase0-results.md`에 항목별 판정과 종합 go/no-go 명시 | — |

---

## Definition of Done

- R1~R7 전부에 대해 실측 근거(명령·exit code·출력)가 보고서에 존재한다.
- 항목별 통과 기준표에 따른 판정이 기록되고, no-go 항목마다 어느 Phase를 어떻게 축소·재설계할지 명시된다.
- U3의 `get-scan` contract 필드 표와 U5의 매핑 표가 Phase 1·2가 그대로 인용할 수 있는 형태로 완성된다.
- 검증 중 만든 임시 저장소·scan-dir이 정리되고, 유지할 픽스처(`docs/verification/fixtures/`)만 남는다.
