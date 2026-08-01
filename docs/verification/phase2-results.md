# Phase 2 — 워크벤치 이력 통합 검증 결과

**계획**: [docs/plans/2026-07-30-003-feat-phase2-workbench-integration-plan.md](../plans/2026-07-30-003-feat-phase2-workbench-integration-plan.md)
**검증일**: 2026-07-30
**산출물**: `skills/security-scan-local/scripts/workbench_glue.py`(신규), `SKILL.md`(수명주기 통합), `coverage_reconcile.py`(`--fp-recheck` 추가)

## 종합 판정: **GO** (품질 대조 게이트는 인증 제약으로 부분 대체)

Claude 로컬 스캔을 워크벤치 SQLite 상태 DB에 등록·종결하고, 공식 CLI가 읽는 동일 백엔드에서
조회 가능함을 실측했다. OpenAI 인증이 필요한 U4의 **공식 스캔 파인딩 품질 대조(R12)** 만 계획의
폴백 조항(Assumptions·Risk R12 대조의 인증 의존)에 따라 보류한다.

## 유닛별 결과

### U1. workbench_glue.py — 수명주기 래퍼 (합성 저장소 왕복 실측)

`workbench_db.py`(공식 CLI의 실제 백엔드)를 `python -I -B`로 감싸고 `CODEX_SECURITY_STATE_DIR`
정확한 이름 주입 + `OPENAI_API_KEY`/`CODEX_API_KEY` 제거(runWorkbench 동일). `--claim-token`은 인터페이스에
아예 없음(R4). 서브커맨드 전부 실측:

| 서브커맨드 | 결과 |
| --- | --- |
| `register` | 빈 scan-dir에서만 등록, `scanId`/`targetId` 반환. **비어 있지 않은 scan-dir 거부** 확인 |
| `contract` | get-scan에서 draft 반영 필드 추출. `producer.version`은 bootstrap `pluginVersion`(0.1.14)에서 채움(Phase 0 U3 규칙), `target.allowedKinds`/`targetId`/`displayName`/`revision`/`scope.requiredIncludePaths` 반환 |
| `feedback` | 결과 있으면 `01_context/false_positive_feedback.json`에 O_EXCL·0600 기록; 없으면 `written:false` |
| `complete` | 무변경 저장소 → `{ok:true, status:complete}`. **저장소 수정 후 → `{ok:false, reason:"Working-tree contents changed…"}`, report.md 보존, 스캔 행 `running` 유지**(자동 실패 처리 안 함, KTD4/R6) |
| `fail` / `close-stale` | 명시된 scanId만 종결 |
| `check-running` / `list-stale` | running 행 나열만(상태 변경 없음). `list-stale`은 종결하지 않음(R7) |

**계약 반영 강제(R3) 실측**: contract 값을 반영하지 않은 draft(잘못된 targetId/revision)는 finalize는
통과(봉인은 계약 무관)하지만 **complete-scan이 거부** — `"scan.target.targetId: must match the workbench target"`.
이것이 R3(사전 계약 반영)의 실증이다.

**최종 DB 상태**(직접 조회로 확인 — 전체 수명주기 분기가 올바르게 영속됨):
```
complete | b0235fff | wbrepo | sealed=True  completed=True   ← 무변경 왕복 성공
failed   | 938f7a3d | wbrepo | sealed=False completed=True   ← close-stale 명시 종결
running  | 705ccbe3 | wbrepo | sealed=False completed=False  ← contract 불일치로 열림 유지
```

### U2. SKILL.md 수명주기 통합

워크벤치 이력 통합 섹션 추가: 순서 계약(register→contract→feedback→…→finalize→complete), contract
필드 → draft 반영 표, 피드백 미신뢰 취급(R11), commit/stash 권고, complete 실패 3선택지 분기(R6).

### U3. FP 재등장 경고 (`coverage_reconcile.py --fp-recheck`)

봉인된 `findings.json`의 `fingerprints.primary`를 `false_positive_feedback.json`의
`falsePositives[].fingerprint`와 대조. 실측:
- 피드백 파일 없음 → 대조 생략, 통과.
- 일치 fingerprint → **재등장 경고 + 과거 판정 사유 표시**(자동 억제 안 함, KTD3), 소스 저장소 origin/HEAD
  기록(targetId 경로 해시 오연결 확인용).
- `--json` 모드 → `{status:pass, reemergedCount:N, warnings:[…]}`.

### U4. 공식 CLI 호환성·품질 대조

- **호환성(R11) — 데이터 계층 확인**: 완료·실패·running 스캔 3종이 공식 CLI가 래핑하는 동일
  `workbench_db.py list-scans`/`get-scan`에서 정상 조회됨(JSON count=3). register/complete/fail/close-stale이
  모두 이 백엔드에 영속되므로 `npx codex-security scans list/show`의 데이터 소스와 완전 호환된다.
  - **TTY 렌더링 미확인**: 이 환경에 공식 CLI(`sdk/typescript/bin/codex-security.mjs`)의 node 빌드/의존성이
    없어 `npx` 실행은 확인하지 못했다. 데이터 계층 호환은 확인됐으므로 렌더링은 CLI 파서의 기존 동작에 의존한다.
- **품질 대조(R12) — 보류**: 공식 스캔 파인딩 대조는 OpenAI 인증이 필요하다. 이 환경에 인증이 없어
  계획의 폴백(Assumptions·Risk "R12 대조의 인증 의존")에 따라 **보류**한다. Phase 1 U6의 합성 취약점
  검출(스모크 신호)이 잠정 품질 근거이며, 인증 확보 시 이 게이트를 실행해 격차 대조표를 채워야 한다.
  → **게이트 신뢰도 저하를 명시**: "빈 배열 봉인"과 정상 스캔의 구별은 아직 합성 스모크에만 의존한다.

## 잔여 리스크(계획 Risks 반영)
- DB 스키마 다운그레이드 가드 부재 → bootstrap이 pluginVersion을 시작 고지에 표시(SKILL.md).
- 공유 상태 DB 쓰기 경합 → advisory 경고 + 구조화 실패 반환.
- 좀비 running 행 → `list-stale`/`close-stale` 수동 정리(자동화 없음).
- targetId 경로 해시 → U3의 origin 기록으로 오연결 감지.
- **R12 인증 의존(위 U4)** → 품질 게이트 미실행, 신뢰도 저하 명시.
