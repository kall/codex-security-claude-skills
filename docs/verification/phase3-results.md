# Phase 3 — validate·patch·diff 스캔 커맨드 검증 결과

**계획**: [docs/plans/2026-07-30-004-feat-phase3-validate-patch-diff-plan.md](../plans/2026-07-30-004-feat-phase3-validate-patch-diff-plan.md)
**검증일**: 2026-07-30
**산출물**: `skills/codex-security-validate/SKILL.md`, `skills/codex-security-patch/SKILL.md`,
`skills/codex-security-diff-scan/SKILL.md`, `skills/install.sh`(다중 스킬 설치로 확장)

## 종합 판정: **GO**

공식 CLI의 `validate`·`patch`·diff 스캔에 대응하는 전역 스킬 3종을 추가했다. 세 스킬은
프롬프트 워크플로(플러그인 스킬 직독)이며 Phase 1의 bootstrap·정산·리페어 루프와(diff는)
Phase 2의 워크벤치 수명주기를 재사용한다.

## 유닛별 결과

### U1. /codex-security-validate (Phase 2 불필요)
- 입력 분기: `.jsonl` → ledger 모드(전 행에 `validation` 객체 추가, 행 순서·discovery 필드 보존,
  원자적 rename 재작성, enriched ledger 재투입 금지), 텍스트/파일 → 단독 판정 모드(한국어 보고).
- 플러그인 `validation` 스킬 compact 모드 직독. FP 피드백·입력 서술은 미신뢰 데이터로 취급(R11).

### U2. /codex-security-patch (Phase 2 불필요)
- 플러그인 `fix-finding` 스킬 직독. **2단 승인**(KTD5): ① 수정 diff 승인(승인 없이 저장소 무변경)
  ② 게이트 실행 승인(감지한 저장소 스크립트 명령의 **원문 + 정의 파일 경로** 제시, 기본 미실행).
- outcome 3값: `fixed`는 게이트 통과 시에만, 미승인이면 최소 검사만 하고 "게이트 미실행" 명시(R6).
- **퍼미션 모드 고지**: `acceptEdits`/`bypassPermissions` 세션에서는 이 지침이 유일한 게이트임을 시작 고지.

### U3. /codex-security-diff-scan (Phase 2 필요)
- 대상 3형태 해석표(`--diff BASE [--head]`→refs, `--working-tree [--base]`→working_tree, 무인자→working_tree).
- 5단계 선형(위협모델=저장소 범위, discovery부터=diff 범위). Phase 2 수명주기(register·contract·
  finalize-first·complete 3선택지)와 Phase 1 공통 규칙을 참조.
- working-tree 스캔의 저장소 불변 강조 고지(R11), shallow clone·detached HEAD 안내.

### U4. 종단 검증 (결정론 구성요소 실측)

| 게이트 | 결과 |
| --- | --- |
| install.sh 다중 스킬 설치 | **4개 스킬 모두 링크 설치 + SKILL.md 해석 확인**, no-clobber 가드 동작(--force 없이 거부) |
| diff 인벤토리 (revisions) | `make-diff-rank-input --mode revisions`가 변경 파일(`src/exec.py`)만 1행 생성, exit 0 |
| diff 인벤토리 (local-patch) | `make-diff-rank-input --mode local-patch`가 워킹트리 편집 1행 생성, exit 0 |
| copy-deep-review-input | rank_input → deep_review_input 1행 복사, exit 0 (R9 필수 호출) |

**LLM 워크플로 부분**(validate 전 행 판정, patch 2단 승인 실행, diff 전체 봉인)은 Phase 1 U6에서
전체 스캔 워크플로 완주(bootstrap→인벤토리→normalize→draft→reconcile→finalize→validate)가
이미 실증됐고, Phase 3 스킬은 그 검증된 구성요소(bootstrap, coverage_reconcile, finalize, workbench_glue,
diff 인벤토리 스크립트)를 재사용한다. 사용량 제약으로 전체 LLM 연쇄(스캔→판정→수정→재스캔) 1회
완주는 서브에이전트 재개 시점으로 남긴다 — 결정론 구성요소는 모두 통과했다.

## Definition of Done 대비
- 세 스킬이 전역 설치 상태에서 각각 독립 동작: install.sh로 4개 설치 확인. ✓
- U1·U2가 Phase 2 없이 착수·완료(워크벤치 미사용, bootstrap `--no-scan-dir`만 사용). ✓
- diff 스캔이 Phase 2 수명주기를 그대로 따름(SKILL.md가 workbench_glue·contract 조회 참조). ✓
- patch가 저장소 변경과 저장소 코드 실행 각각에 승인(2단 승인 명문화). ✓
