---
title: Phase 3 — validate·patch·diff 스캔 커맨드 - Plan
type: feat
date: 2026-07-30
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Phase 3 — validate·patch·diff 스캔 커맨드 - Plan

**시리즈**: Claude Code 전역 스킬로 codex-security를 OpenAI 인증 없이 실행하기 (Phase 3/4)
**선행 문서**: [Phase 1](2026-07-30-002-feat-phase1-standalone-scan-skill-plan.md)(번역 계층·bootstrap — U1·U2에 필요), [Phase 2](2026-07-30-003-feat-phase2-workbench-integration-plan.md)(수명주기 — U3 diff 스캔에만 필요)
**산출물 위치**: `skills/` 하위 신규 스킬 3종 (정본은 이 저장소)

---

## Goal Capsule

- **목표**: 공식 CLI의 `validate`·`patch`·diff 스캔에 대응하는 전역 스킬 3종을 추가한다: `/codex-security-validate`, `/codex-security-patch`, `/codex-security-diff-scan`.
- **권위 순서**: 이 문서 → 플러그인 스킬 3종(`validation`, `fix-finding`, `security-diff-scan`)의 SKILL.md → Phase 1 번역 규칙.
- **착수 조건 분리**: U1(validate)·U2(patch)는 **Phase 1만 완료되면 착수 가능**하다 — 워크벤치를 쓰지 않기 때문이다. U3(diff 스캔)만 Phase 2를 요구한다. Phase 2가 지연되거나 no-go가 되어도 U1·U2는 진행한다.
- **중지 조건**: 없음 — 세 스킬은 독립적이며 하나가 막혀도 나머지는 진행 가능.

---

## Product Contract

### Summary

플러그인의 validation·fix-finding 스킬은 스크립트 호출이 없는 순수 프롬프트 워크플로라 번역 부담이 가장 작고 Phase 1만으로 착수할 수 있다. diff 스캔은 Phase 1 스캔 스킬의 변형으로, 대상 해석(refs/working_tree)과 diff 인벤토리 스크립트 호출이 추가되며 Phase 2 수명주기를 따른다.

### Problem Frame

전체 스캔만으로는 일상 워크플로(PR 리뷰 전 변경분 점검, 개별 finding의 진위 확인, 수정 적용)를 커버하지 못한다. 공식 CLI의 `validate`/`patch`/diff 스캔이 이를 담당하지만 모두 Codex 에이전트 루프를 경유한다. 세 워크플로 모두 프로그램적 입력 채널이 없어(프롬프트 텍스트로 입출력 결정) Claude Code 이식이 구조적으로 단순하다. 다만 patch는 시리즈에서 유일하게 저장소를 변경하고 저장소가 정의한 명령을 실행하므로 승인 설계가 핵심이다.

### Requirements

**`/codex-security-validate`** (Phase 1만 필요)
- R1. finding 서술(텍스트 또는 파일 경로) 또는 스캔 디렉터리의 `candidate_ledger.jsonl`을 입력으로 받아 플러그인 `validation` 스킬의 compact 모드 규약대로 판정해야 한다.
- R2. ledger 입력 시: 각 행에 `validation` 객체(disposition/method/confidence/confidence_rationale/rubric/evidence/counterevidence_or_proof_gap/remaining_uncertainty)를 추가하고 행 순서·기존 필드를 보존한 채 원자적으로 재작성해야 한다. 보강된 ledger를 `normalize_candidates.py`에 재투입하지 않는다.
- R3. 단독 finding 입력 시: 같은 판정 구조를 한국어 보고서로 출력한다 (ledger 없이).

**`/codex-security-patch`** (Phase 1만 필요)
- R4. 보안 이슈 서술을 입력으로 받아 플러그인 `fix-finding` 스킬 규약대로 수정을 수행하고 `outcome ∈ {fixed, no_change, blocked}`를 보고해야 한다. 게이트를 실행하지 않았거나 실행이 거부된 경우 `fixed`로 보고하지 않고 "게이트 미실행"임을 명시해야 한다.
- R5. 승인은 2단이어야 한다. ① 수정 diff 승인 — 승인 없이 저장소를 변경하지 않는다. ② 게이트 실행 승인 — 감지한 명령의 원문(`npm run test`, `make check` 등)과 그 정의 파일 경로를 제시하고 별도 승인을 받는다. 저장소가 정의한 스크립트는 대상 저장소가 완전히 제어하는 코드이므로, diff 승인이 그 실행 권한까지 포함하지 않는다.
- R6. 게이트 실행이 미승인이면, 저장소 스크립트를 경유하지 않는 최소 검사(구문·타입 체크 등)까지만 수행하고 그 사실을 outcome에 반영해야 한다.
- R7. 스캔 디렉터리 컨텍스트가 주어지면 `fix_report.md`를 `<scan-dir>/artifacts/` 아래에 남긴다. 워크벤치 remediation 3단계 연동(`set-finding-remediation`)은 하지 않는다.

**`/codex-security-diff-scan`** (Phase 2 필요)
- R8. 대상 3형태를 지원해야 한다: `--diff BASE [--head HEAD]`(refs), `--working-tree [--base REF]`(working_tree), 인자 없음(working-tree 기본).
- R9. 플러그인 `security-diff-scan` 스킬의 5단계 선형 워크플로(threat-model은 저장소 범위 → discovery부터는 diff 범위)를 따르고, 인벤토리는 `generate_rank_input.py make-diff-rank-input`(revisions 또는 local-patch 모드)으로 생성한 뒤 `copy-deep-review-input`으로 리뷰 입력을 파생해야 한다.
- R10. 워크벤치 등록 시 recipe의 `target.kind`를 `refs`/`working_tree`로, base/head를 문자열로 채워야 한다. Phase 2 수명주기(contract 조회·finalize-first·종결 분기)를 그대로 따른다.
- R11. working-tree 스캔은 등록 시점의 워킹트리 다이제스트가 기준이 되므로, "스캔 중 저장소 불변" 요구를 시작 고지에서 더 강하게 안내해야 한다 — 파일 저장 한 번으로 이력 기록이 실패한다.

### Scope Boundaries

- pre-commit 훅 설치(`install-hook` 대응)는 하지 않는다 — 공식 CLI 훅은 OpenAI 경로를 실행하므로 대응물은 후속 판단.
- PR URL 직접 입력(GitHub API 조회)은 하지 않는다 — 로컬 ref 기반만.
- `validate`/`patch`의 워크벤치 연동(remediation 상태 기록)은 범위 밖.
- 취약점 상세 write-up과 하드닝 포트폴리오(`vulnerability-writeup`, `propose-security-hardening`)는 플러그인이 선택 사항으로 두므로 생성하지 않는다.

**Deferred to Follow-Up Work**
- `/codex-security-patch`과 Phase 2 이력의 연동(occurrence 지정 수정): 워크벤치 remediation 프로토콜(action token, expected version) 재현이 필요해 별도 작업으로 분리.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **스킬 3개로 분리** — 단일 스킬에 서브커맨드를 두는 대신 Claude Code 스킬 디스커버리(description 트리거)에 맞게 목적별 스킬로 나눈다. 공용 스크립트는 `skills/codex-security-scan/scripts/`를 재사용한다.
- KTD2. **validate·patch를 Phase 2와 분리 착수** — 두 스킬은 워크벤치를 쓰지 않으므로 Phase 1 완료 직후 진행할 수 있다. Phase 2/diff 스캔 뒤에 묶어두면 가장 자주 쓰일 기능이 가장 늦게 나온다.
- KTD3. **validation/fix-finding은 SKILL.md 직접 준수** — 두 플러그인 스킬은 스크립트 호출이 없고 MCP 의존도 낮아, Phase 1 번역 규칙의 축소판(무시 목록 + 미신뢰 데이터 규칙 유지)으로 충분하다.
- KTD4. **diff 스캔은 별도 스킬** — 대상 해석·인벤토리·범위 규칙(위협 모델은 저장소 전체, 리뷰는 diff만)이 달라 한 문서에 합치면 지침 충돌이 생긴다. 공통 부분(bootstrap, 금지 필드, 정산, 리페어 루프, 수명주기)은 Phase 1·2 SKILL.md를 참조로 지시한다.
- KTD5. **patch는 2단 승인** — 저장소 변경과 저장소 코드 실행은 별개의 권한이다. diff 승인만으로 `npm test`를 돌리면 사용자가 승인한 것(3줄 diff)과 실제 실행되는 것(임의 코드)이 어긋난다. Phase 1·2 스캔이 읽기 전용인데 patch만 이 권한을 얻으므로 게이트를 분리한다.

### Assumptions

- U3 착수 시점에 Phase 2의 `workbench_glue.py`가 존재한다. U1·U2는 이 가정에 의존하지 않는다.
- Claude Code 퍼미션 모드가 `acceptEdits`/`bypassPermissions`인 세션에서는 SKILL.md 지침이 유일한 승인 게이트가 된다 — U2가 이 사실을 시작 고지에 명시한다.

---

## Implementation Units

### U1. /codex-security-validate

- **Goal**: finding 판정 스킬을 완성한다.
- **Requirements**: R1, R2, R3
- **Dependencies**: Phase 1 U2 (bootstrap), Phase 1 U3 (번역 규칙의 축소판 재사용)
- **Files**: `skills/codex-security-validate/SKILL.md`
- **Approach**:
  1. 입력 분기: 파일 경로가 ledger(JSONL)면 compact 모드(R2), 텍스트/일반 파일이면 단독 판정(R3).
  2. 플러그인 `skills/validation/SKILL.md`를 읽고 따르되, false_positive_feedback.json 취급 규약(데이터로만)과 Phase 1 R11 미신뢰 규칙을 유지.
  3. ledger 재작성은 임시 파일 작성 후 원자적 교체(rename)로 수행하도록 지시.
- **Patterns to follow**: 플러그인 `references/scan-artifacts.md`의 validation 필드 정의
- **Test scenarios**:
  - Phase 1 스캔이 남긴 ledger를 입력하면 전 행에 validation 객체가 추가되고 행 순서가 보존된다.
  - 텍스트 finding("이 코드에 SQL 인젝션이 있다") 입력 시 disposition과 근거가 한국어로 출력된다.
  - 이미 validation이 있는 행은 덮어쓰지 않고 사용자에게 확인한다.
  - ledger에 인젝션 문구가 포함된 후보가 있어도 판정 절차가 변경되지 않는다.
- **Verification**: ledger 왕복 후 JSONL 파싱 무결성 통과.

### U2. /codex-security-patch

- **Goal**: 보안 이슈 수정 스킬을 2단 승인 구조로 완성한다.
- **Requirements**: R4, R5, R6, R7
- **Dependencies**: Phase 1 U2 (bootstrap), Phase 1 U3 (번역 규칙의 축소판 재사용)
- **Files**: `skills/codex-security-patch/SKILL.md`
- **Approach**:
  1. 플러그인 `skills/fix-finding/SKILL.md`의 기준(최소 변경, 게이트 실행, outcome 3값)을 따른다.
  2. 1단 승인: 수정안 diff를 제시하고 승인 후에만 적용.
  3. 2단 승인(KTD5): 저장소에서 감지한 게이트 명령의 원문과 정의 파일 경로(`package.json`의 scripts, `Makefile`, `conftest.py`, pre-commit 설정 등)를 나열하고 실행 승인을 별도로 받는다. 기본값은 미실행.
  4. 미승인 시(R6): 저장소 스크립트를 경유하지 않는 최소 검사만 수행하고 outcome에 "게이트 미실행"을 명시. `fixed`는 게이트가 통과한 경우에만 사용.
  5. 퍼미션 모드 고지: `acceptEdits`/`bypassPermissions` 세션에서는 이 지침이 유일한 게이트임을 시작 시 알린다.
  6. blocked 판정 기준(수정이 동작 변경을 유발, 재현 불가 등)을 명시.
- **Test scenarios**:
  - 합성 취약점(커맨드 인젝션)에 대해 diff 제시→승인→적용→게이트 승인→`fixed` 흐름이 완결된다.
  - diff 승인 거부 시 저장소가 무변경으로 남는다.
  - 게이트 승인 거부 시 수정은 적용되되 outcome이 "게이트 미실행"으로 보고된다.
  - `package.json`의 `test` 스크립트에 임의 명령이 들어 있으면 그 원문이 승인 요청에 표시된다.
  - 존재하지 않는 이슈 서술에는 `no_change`와 근거가 출력된다.
- **Verification**: 5 시나리오 통과 + 게이트 승인·거부 양쪽의 outcome 표기 확인.

### U3. /codex-security-diff-scan

- **Goal**: 변경분 스캔 스킬을 완성한다.
- **Requirements**: R8, R9, R10, R11
- **Dependencies**: Phase 1 U2~U5 (번역 계층·정산·리페어), Phase 2 U1·U2 (workbench_glue·수명주기)
- **Files**: `skills/codex-security-diff-scan/SKILL.md`
- **Approach**:
  1. 대상 해석 표: `--diff BASE` → kind=refs(base=BASE, head=HEAD 기본), `--working-tree` → kind=working_tree(base=HEAD 기본). recipe에 반영하고 Phase 2 contract 조회로 좌표를 확정.
  2. 인벤토리: `generate_rank_input.py make-diff-rank-input --repo <root> --base <base> --mode revisions --head <head>`(refs) / `--mode local-patch`(working-tree) → `<discovery_dir>/rank_input.jsonl` → `copy-deep-review-input --rank-input <...> --out <...>/deep_review_input.jsonl`(R9).
  3. 5단계 선형 워크플로 준수: threat-model(저장소 범위) → finding-discovery(diff 범위) → validation → attack-path → canonical JSON. 각 단계 완료 전 다음 플러그인 스킬 읽기 금지(플러그인 규약).
  4. coverage.mode는 kind별 기대값(refs→`branch_diff`, working_tree→`working_tree`)을 따르되 finalizer가 덮어쓰는 필드는 작성하지 않는다. 실제 기대값은 Phase 2 contract 조회 결과가 권위다.
  5. 시작 고지 강화(R11): working-tree 스캔은 파일 저장 한 번으로 complete-scan이 실패함을 명시하고, 짧은 diff일수록 빠른 완료를 권고.
- **Patterns to follow**: 플러그인 `skills/security-diff-scan/SKILL.md`의 5단계 순서 규칙과 스크립트 호출부, Phase 1 SKILL.md의 공통 규칙 참조 방식
- **Test scenarios**:
  - 커밋 2개 차이의 refs 스캔에서 변경 파일만 리뷰되고 봉인이 성공한다.
  - `copy-deep-review-input`이 실제로 호출된 흔적이 남는다.
  - 심은 취약점을 포함한 working-tree 변경이 검출된다.
  - diff에 없는 파일의 finding이 나오면 정산 단계에서 경고된다(범위 이탈 가시화).
  - shallow clone에서 base 해석 실패 시 한국어 안내(fetch 권고)로 종료된다.
  - detached HEAD에서 working-tree 스캔이 정상 등록된다.
- **Verification**: refs·working-tree 각 1회 왕복(등록→contract→봉인→complete) 성공.

### U4. 종단 검증

- **Goal**: 세 스킬을 실사용 시나리오로 묶어 검증한다.
- **Requirements**: 전체 통합
- **Dependencies**: U1~U3
- **Files**: `docs/verification/phase3-results.md`
- **Approach**: 하나의 합성 저장소에서 ① working-tree diff 스캔 → ② 검출 finding을 validate로 재판정 → ③ patch로 수정(2단 승인 모두 진행) → ④ 재스캔에서 미검출 확인의 연쇄 시나리오를 실행·기록한다.
- **Test scenarios**: 연쇄 시나리오 1회 완주 (각 단계 산출물 존재).
- **Verification**: 보고서 작성 완료.

---

## Verification Contract

| 게이트 | 명령/기준 |
|---|---|
| validate | ledger 왕복 후 JSONL 무결성 + 필드 규약 준수 |
| patch 1단 | diff 미승인 시 저장소 무변경 |
| patch 2단 | 게이트 명령 원문 제시 + 미승인 시 outcome이 "게이트 미실행" |
| diff 스캔 | refs·working-tree 각 1회 봉인 성공 + `validate_scan_contract.py` exit 0 |
| 필수 단계 | `make-diff-rank-input`·`copy-deep-review-input` 호출 흔적 존재 |
| 연쇄 | 스캔→판정→수정→재스캔 시나리오 완주 |

---

## Definition of Done

- 세 스킬이 전역 설치 상태에서 각각 독립 동작한다.
- U1·U2가 Phase 2 없이 착수·완료 가능함이 실제 순서로 입증된다.
- diff 스캔이 Phase 2 수명주기(등록·contract·피드백·finalize-first·종결 분기)를 그대로 따른다.
- patch가 저장소 변경과 저장소 코드 실행 각각에 대해 승인을 받는다.
- 검증 보고서(`docs/verification/phase3-results.md`)가 작성된다.
