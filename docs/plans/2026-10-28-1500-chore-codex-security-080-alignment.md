---
title: codex-security npm 0.8.0 정합 — coverage.json의 매니페스트 이전과 bind-repo-scopes 인자 삭제 대응 기록
type: chore
date: 2026-10-28
status: done
---

# codex-security npm 0.8.0 정합

상류 `openai/codex-security` 태그 `npm-v0.8.0`(커밋 `71bd7ae0e9bc859fb8fe9bc4b590b8f8998b19aa`, 2026-10-28)에
스킬을 맞춘 기록이다. 기준선은 npm 0.7.0이었다. 지난 기록은 `2026-10-26-1500-chore-codex-security-070-alignment.md`다.

## 1. 결론 요약

- 0.7.0 → 0.8.0은 49 커밋이다. 대부분 테스트·CI 변경이다. 매니페스트는 0.1.95 그대로다. 상태 DB 마이그레이션은 늘지 않았다
  (`scripts/workbench_schema.py`가 0.7.0과 같다).
- 수정 전 스킬을 0.8.0에서 돌리면 다음이 실패했다.
  - `repro-u4` L1: `bind-repo-scopes: error: Unknown option '--coverage'`(exit 2).
  - `repro-u7` I17h: 같은 원인으로 경로 지정 스캔 수명주기가 중간에 실패했다.
- 나머지 자기채점(`repro-u1`·`repro-u5`·`repro-u8`)과 관측형 `repro-u3`는 수정 전에도 통과했다.

## 2. 상류 변경과 반영

### 2.1 coverage.json을 매니페스트로 이전 (#1762, breaking)

- `621bad47e refactor!: simplify scan completion and recovery`가 coverage.json을 없앴다. 새 형상에서는 리뷰 기록이 미봉인
  매니페스트의 `scan.reviewState`에 들어가고, 봉인 때 `scan.review`(`excludedPaths`만)와 `scan.mode`로 줄어든다. 새 봉인
  번들은 `scan-manifest.json`·`findings.json`뿐이다. 상류 문서(`core-scan.md`·`final-report.md`·`scan-contract.md`·스킬 문서)도
  `coverage.*`를 `reviewState.*`로 바꿨다.
- 상류 finalizer는 레거시 형상을 계속 받는다. 미봉인 매니페스트에 `scan.review`·`scan.reviewState`가 없고 `<scan_dir>/coverage.json`이
  있으면 `coverageRef`를 스스로 넣고, coverage.json을 검사·봉인해 번들에 남긴다(`_prepare_scan_finalization`의 분기).
- **결정: 스킬은 모든 버전에서 coverage.json 형상을 유지한다.** 근거:
  1. 0.7.0 이하와 같은 산출물 경로를 쓰므로 버전 분기가 생기지 않는다.
  2. 스킬의 자체 정산(`coverage_reconcile.py` R9·R10)과 리페어 루프가 coverage.json을 전제로 한다.
  3. 상류 finalizer가 이 형상을 명시적으로 지원한다(실측: 0.8.0에서 fixture를 finalize하면 `coverageRef`가 들어가고
     `artifacts`에 `coverage.json`이 남는다).
- 위험: 상류가 레거시 분기를 지우면 다음 정합에서 새 형상으로 옮겨야 한다. 그때는 정산 입력을 `scan.reviewState`로 바꾸고,
  0.7.0 이하 분기를 함께 두어야 한다.
- 0.8.0 `report.md`는 형상과 관계없이 "Canonical artifacts: `scan-manifest.json` and `findings.json`"이라고 쓰고
  `Inventory strategy` 줄을 싣지 않는다(`report_projection.py`). 레거시 형상에서도 coverage.json은 봉인되므로 이 문장은
  사실과 다르지만, 상류 투영이라 스킬이 고치지 않는다.

### 2.2 bind-repo-scopes의 `--coverage` 삭제 (#1762)

- 같은 커밋이 `bind-repo-scopes` 헬퍼에서 `--coverage`를 지웠다. 헬퍼는 매니페스트 `scan.scope.includePaths`만 바꾼다.
- 헬퍼 번들(`mcp/helpers.mjs`)은 압축 조각이라 사용법 문자열을 읽을 수 없다. 그래서 같은 커밋이 더한
  `scripts/review_state.py`의 존재로 판별한다. 부트스트랩이 `bindRepoScopes.coverageArg`(`true`·`false`, 헬퍼 불가면 `null`)를 싣는다.
- 스캔 스킬 6단계 1번: `coverageArg`가 `false`이면 `--coverage`를 빼고, coverage.json의 `includePaths`를 `--scopes-file`과 같은 배열로
  직접 맞춘다. 빠뜨리면 finalize가 `coverage.includePaths: must match manifest scope`로 거부한다(변이 시험으로 확인). 리페어 루프
  항목에 이 문구를 넣었다.
- 자기채점: `repro-u4` L0b·L1·L1c, `repro-u7` I17h, `repro-u1` H14a-7·H14b-8·H14b-9를 `coverageArg`로 나눴다.
- 정산(`coverage_reconcile.py`)이 매니페스트와 coverage의 `includePaths`가 다르면 경고한다(차단하지 않음, `repro-u7` I5y).
  스모크 테스트에서 coverage 동기화를 빠뜨려도 정산이 `pass`로 통과하는 것을 찾았기 때문이다.

### 2.3 정책 탐색에서 Git 무시 파일 제외 (#1535)

- `716e74d72`가 `policy`의 정책 탐색(`securityPolicyPaths`)에서 Git이 무시하는 경로를 뺀다. 대상 컴포넌트의 `SECURITY.md` 자신은 남는다.
- `codex-security-policy`는 상류 `inspectSecurityPolicySources`를 import해 쓰므로 코드 변경 없이 따라간다. 프롬프트 리터럴은 같다(`repro-u8` P7·P11 통과).
- 스캔 0단계의 정책 해결 헬퍼(`resolve-security-md`)는 바뀌지 않았다.

### 2.4 고정 리터럴 재대조

`git diff npm-v0.7.0 npm-v0.8.0`이 `scan-comparison.ts`·`finding-catalogue.ts`·`severity-review.ts`·`classify-severity.ts`·
`classify-scan-severity.ts`·`severity-store.ts`·`default-severity-rubric.ts`·`remediation.ts`·`security-policy-cli.ts`·
`standalone-validation-prompt.ts`와 validate가 읽는 두 참조 문서, fix-finding·verify-fix·validation 스킬 문서에서 비어 있다.
설치본 dist도 `security-policy.js`를 빼면 0.7.0과 바이트 단위로 같다. 각 스킬의 기준 실측 버전을 0.8.0으로 올렸다.

### 2.5 반영하지 않은 상류 변경

OpenGrep 리포트 import(#1872), Linux amd64용 로컬 Wolfi 컨테이너 빌드(#2053), hosted dedupe 계속 진행(#2090), deep 스캔 재개 수정(#2049),
봉인 전 경고 보존(#1907), 체크아웃이 지워진 뒤 완료 스캔 읽기(#2050), GitHub issue 읽기 필드(#2048), patch 소스 발췌 끝 처리(#2015), CI·테스트 변경.

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록에 적었다.
