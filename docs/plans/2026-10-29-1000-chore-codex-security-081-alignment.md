---
title: codex-security npm 0.8.1 정합 — 스킬 경로 영향 없음 확인과 기준 버전 갱신 기록
type: chore
date: 2026-10-29
status: done
---

# codex-security npm 0.8.1 정합

상류 `openai/codex-security` 태그 `npm-v0.8.1`(커밋 `1f2f96d562b98216257e7f7cdacd40c446b97f70`)에 스킬을 맞춘 기록이다.
기준선은 npm 0.8.0이었다. 지난 기록은 `2026-10-28-1500-chore-codex-security-080-alignment.md`다.

## 1. 결론 요약

- 0.8.0 → 0.8.1은 11 커밋이다(릴리즈 커밋 포함). 매니페스트는 0.1.95 그대로다. 상태 DB 스키마(`scripts/workbench_schema.py`)도 같다.
- **수정 전 스킬이 0.8.1에서 그대로 통과했다.** 자기채점 다섯 개와 관측형 `repro-u3`의 결과가 0.8.0과 같다.
- 그래서 코드 변경은 없다. 기준 실측 버전, 시작 고지 기준, 문서의 버전 구간을 0.8.1로 올렸다.

## 2. 상류 변경과 판단

| 변경 | 스킬 영향 |
| --- | --- |
| 인벤토리 헬퍼 정리와 hosted 전용 `make-hosted-repo-scope-input`(#2110). 상류 `security-scan/SKILL.md` 1단계와 `scan-artifacts.md`의 `target_paths_file` 서술이 이 명령을 반영해 바뀌었다 | 없음. 스킬이 쓰는 `generate-in-scope-files`·`make-diff-rank-input`·`make-repo-scope-input`의 인자와 출력은 같다(`repro-u4` G·I·J). 바뀐 문장은 SDK 소유 스캔 경로라 스킬이 인용하지 않는다 |
| ServiceNow AVIT CSV 내보내기(#2103, `finalize_scan_contract.py --export-format servicenow-avit --avit-template`) | 없음. 새 선택 옵션이고 봉인 경로는 같다 |
| 스캔 디렉터리 이름의 하이픈 보존(#2102, `workbench_scan_start.py`) | 없음. 스킬의 스캔 디렉터리는 부트스트랩이 정한다. 글루 수명주기(`repro-u7` I17)는 통과했다 |
| 변경된 봉인 파일의 hosted 영수증 거부(#2105), Dependabot 경보 import(#2096), Wolfi 스캐너 컨테이너(#2091), Codex CLI·SDK 0.165.0(#2107) | 없음(감싸지 않는 기능) |

고정 리터럴의 원본(`scan-comparison.ts`·`finding-catalogue.ts`·`severity-review.ts`·`classify-severity.ts`·`classify-scan-severity.ts`·
`severity-store.ts`·`default-severity-rubric.ts`·`remediation.ts`·`security-policy.ts`·`security-policy-cli.ts`·
`standalone-validation-prompt.ts`)과 validate 참조 문서, fix-finding·verify-fix·validation 스킬 문서, `bind-repo-scopes.ts`·
`review_state.py`는 `git diff npm-v0.8.0 npm-v0.8.1`이 비어 있다. 설치본 dist의 해당 파일 7개도 0.8.0과 바이트 단위로 같다.
부트스트랩은 0.8.1에서 `bindRepoScopes.coverageArg: false`를 낸다(`review_state.py`가 있다).

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록에 적었다. 릴리즈 때는 종단간 스모크 테스트를 건너뛰었다
("바뀐 상류 코드가 스킬 경로에 닿지 않는다"는 판단은 추론이었다). 기존 러닝과 어긋나 릴리즈 뒤에 돌렸고, 0.8.0과 결과가
같았다. 0.8.1 회귀는 없었고, 기존 문서 공백 하나(finding `identity` 필수 필드 누락)를 찾아 고쳤다.
