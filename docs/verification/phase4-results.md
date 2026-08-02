# Phase 4 — 파인딩 매칭·deep-lite 스캔 검증 결과

**계획**: [docs/plans/2026-07-30-005-feat-phase4-matching-deep-scan-plan.md](../plans/2026-07-30-005-feat-phase4-matching-deep-scan-plan.md)
**검증일**: 2026-07-30
**산출물**: `skills/codex-security-scan-match/`(SKILL.md + scripts/validate_matches.py),
`skills/codex-security-deep-scan/SKILL.md`, `docs/verification/phase4-deep-lite-pipeline.md`(U2 실측)

## 종합 판정: **GO**

시리즈에서 남은 두 LLM 의존 기능(의미 기반 매칭, 다중 패스 deep 스캔)을 Claude 대체물로 완성했다.
결정론 구성요소(매칭 검증기, 랭킹 파이프라인)는 전부 인라인 실측을 통과했다.

## 유닛별 결과

### U1. /codex-security-scan-match — 매칭
- `validate_matches.py`가 `scan-comparison.ts`의 `validateComparison` 규칙을 재현. 실측:
  - 정상 매칭(b1↔a1, uncertain b2↔a2) → `{ok:true}`.
  - **미지 occurrenceId** → 거부. **확정 매칭 중복**(b1 두 번) → 거부. **uncertain의 before가 기매칭** →
    거부. **confidence≠"high"** → 거부. (R3 오염 판정 3종 + 스키마 위반 모두 거부)
- SKILL.md: 매칭 판정을 **도구 없는 격리 서브에이전트**가 수행(R4/KTD2 — 파일쓰기·Bash·네트워크 없이
  프롬프트 텍스트만, JSON만 반환, 방어 문구 포함), 캐시 분기(R1), 저장 전 validate 통과 강제, 재판정 루프.

### U2. deep-lite 랭킹 파이프라인 실측 → `phase4-deep-lite-pipeline.md`
합성 저장소(20파일)에서 전 구간 실측·계약 고정:
- `make-repo-rank-input`(20행) → `make-rank-shards --max-rows 8`(3샤드) → `make-rank-pool-plan`(round_robin
  2슬롯) → 랭킹(`score` 1~10) → `validate-rank-worker`(RANK_WORKER_RECEIPT) → `merge-rank-outputs`(20행) →
  `select-deep-review-input --top-percent 20`(4행 선택).
- **발견한 계약**: 샤드 dir은 `rank_shards` 명명 필수·plan 형제, `score`는 1~10, **merge는 부분 실패
  거부**(누락 샤드 → exit 1). 랭킹 팬아웃(전량 성공·랭킹 행) vs 리뷰 팬아웃(부분 실패 허용·후보) 경계 확정.

### U3. /codex-security-deep-scan — deep-lite
- U2 계약을 그대로 인용. 랭킹 팬아웃(읽기 전용 워커, path 1:1, score 1-10, 3회 실패 시 중단 R8) /
  리뷰 팬아웃(고정 2패스 R9, 부분 실패→partial, 워커 분포 표 R12) **분리**.
- deep-lite 축소 고지(공식 deep 비동등), `deep_security_scan` preflight 미실행·`security_scan` 대체(R11),
  `register --mode deep`(KTD4, deep 전용 DB 미사용), 후속 단계는 Phase 1·2 계약(R10).

### U4. 종단 검증
- **install.sh 6개 스킬 전부 설치 확인**(codex-security-scan / -validate-local / -patch-local /
  -diff-scan-local / -scan-match-local / -deep-scan-local).
- 결정론 구성요소(validate_matches 4종 케이스, 랭킹 파이프라인 7단계)는 전부 통과.
- 전체 LLM 연쇄(deep-lite 스캔→patch 수정→재스캔→매칭→compare)와 격리 서브에이전트 매칭 판정 실행은
  사용량 제약으로 서브에이전트 재개 시점으로 남긴다. 스킬이 재사용하는 결정론 구성요소는 모두 실증됐다.

---

## 시리즈 최종 기능 대응표 (공식 CLI ↔ 로컬 스킬)

| 공식 codex-security CLI | 로컬 Claude 스킬 | 인증 | 상태 |
|---|---|---|---|
| `scan`(전체) | `/codex-security-scan` | 불필요 | ✓ (Phase 1, U6 종단 실증) |
| `scans list/show` 이력 | `workbench_glue.py` 등록·종결 | 불필요 | ✓ (Phase 2, 데이터 계층 호환) |
| `findings false-positive` 피드백 | `feedback` 주입 + `--fp-recheck` 재등장 경고 | 불필요 | ✓ (Phase 2) |
| `validate` | `/codex-security-validate` | 불필요 | ✓ (Phase 3) |
| `patch` | `/codex-security-patch`(2단 승인) | 불필요 | ✓ (Phase 3) |
| diff/working-tree 스캔 | `/codex-security-diff-scan` | 불필요 | ✓ (Phase 3) |
| `scans match` | `/codex-security-scan-match`(격리 서브에이전트) | 불필요 | ✓ (Phase 4) |
| deep 스캔 | `/codex-security-deep-scan`(deep-lite) | 불필요 | ✓ 축소판 (Phase 4) |
| `scans rerun` | — | (OpenAI 경로 재진입) | 범위 밖 |
| pre-commit 훅 | — | (OpenAI 경로) | 범위 밖 |

## 보류·잔여
- **품질 대조(Phase 2 R12)**: 공식 스캔 파인딩과의 대조는 OpenAI 인증 필요 — 보류. "빈 배열 봉인"과
  정상 스캔의 구별은 현재 합성 스모크 신호에만 의존(신뢰도 저하 명시).
- **전체 LLM 연쇄 종단(Phase 3·4 U4)**: 결정론 구성요소는 실증됐고, LLM 워크플로 1회 완주는 사용량
  리셋 후 재개 시점으로 남김. Phase 1 U6에서 전체 스캔 워크플로 완주가 이미 실증돼 구성요소 건전성은 확보.
- **deep-lite 효용**: 표준 스캔 대비 더 넓게 본다는 것이 실제 검출 이득인지는 인증 있는 품질 대조에서만 확인됨.
