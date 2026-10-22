---
title: codex-security npm 0.6.0 정합 — 심각도 다수결·정적 검증 모드 대응 기록
type: chore
date: 2026-10-22
status: done
---

# codex-security npm 0.6.0 정합

상류 `openai/codex-security` 태그 `npm-v0.6.0`(커밋 `13dcc6fec00aaf4c23a6fa7e375ccc1726b22836`, 2026-10-22)에
스킬을 맞춘 기록이다. 기준선은 npm 0.5.1이었다. 지난 기록은 `2026-10-21-1000-chore-codex-security-051-alignment.md`다.

## 1. 결론 요약

- 0.5.1 → 0.6.0은 19 커밋이다. breaking은 2건이다(#1765 심각도 재분류, #1837 policy diff). 매니페스트는 0.1.95 그대로다.
- 수정 전 스킬을 0.6.0에서 돌리면 `repro-u8` S 블록 45건이 실패했다. 나머지 자기채점과 `repro-u3` 관측은 0.5.1과 같았다.
- 새 기능 #1854(patch·verify-fix 정적 검증 모드)를 스킬에 들였다. 자기채점은 깨지지 않았지만 상류 문서가 바뀌었다.

## 2. 상류 변경과 반영

### 2.1 classify-severity (#1765, breaking)

| 상류 변경 | 반영 |
| --- | --- |
| 루브릭 생략 시 상류 기본 루브릭(`default-severity-rubric.ts`)으로 모델 판정. 기존 심각도 상속(무모델) 경로 삭제 | 0.6.0 이상에서 루브릭 생략 = 기본 루브릭으로 같은 서브에이전트 흐름. CLI·인증 불필요. `inherit`는 0.5.1 이하 전용, 0.6.0에서 거부 |
| finding마다 같은 프롬프트로 독립 리뷰 N회(기본 3, `--runs 1–10`), `reviewSeverity()` 다수결(동률이면 높은 심각도, 제외는 별도 표) | prepare가 가짜 Codex 호출 하나를 작업 항목 하나(finding × run)로 기록. run마다 새 격리 서브에이전트. apply가 run 순서대로 답을 공급하고 다수결은 상류가 한다(재구현 안 함) |
| 재사용 조건에 `classificationRuns` 일치 추가, 마이그레이션 52 | 상류 `SeverityStore`가 그대로 처리. runs를 바꾸면 재판정 |
| 지시 8문단 변경 없음 | 기본 루브릭은 원문 대신 SHA-256(`UPSTREAM_DEFAULT_RUBRIC_SHA256`)으로 고정. 다르면 중단하지 않고 `defaultRubricDrift: true`(루브릭은 미신뢰 구획 데이터) |

버전 판별은 파일과 export로 한다(`dist/default-severity-rubric.js` + `severity-review.js`의 `classificationRunsSchema`).
`--runs`는 0.5.1 이하에서 거부한다. 비용은 미캐시 finding당 서브에이전트 N회다.

### 2.2 patch·verify-fix 정적 검증 모드 (#1854)

상류 `fix-finding`·`verify-fix` 스킬에 `verificationMode: static`이 생겼다. 소스·diff 근거만 보고 빌드·테스트·재현을
실행하지 않는다. 런타임 도구 부재만으로는 blocked·inconclusive가 아니다.

- 사용자가 명시 요청할 때만 static이다. 승인 거부·도구 부재·"빨리"는 static 요청이 아니다. 모드는 처음에 정하고 유지한다.
- patch static: 1단 승인(저장소 변경)만 있고 2단 승인과 실행이 없다. 지금 1단 범위로 허용하던 구문 검사(`py_compile` 등)도
  실행하지 않는다. `git diff`는 `--no-ext-diff --no-textconv`. 통과 시 `fixed`이되 "정적 검증 — 런타임 검사 미실행"을 적는다.
- verify-fix static: 실행 승인 요청이 없고, 실행하지 않은 것만으로 `inconclusive`가 아니다.
- 상류 static 머리말과 `STATIC_VERIFICATION_INSTRUCTIONS`(`remediation.ts`)를 고정했다. 기존 dynamic 2줄은 같다.
- standard 모드의 2단 승인 흐름은 바뀌지 않았다. 안전 계약은 static에서 더 엄격해질 뿐이다.

### 2.3 policy (#1837, breaking)

diff 미리보기가 Python difflib에서 Node 구현(`security-policy-diff.ts`)으로 바뀌었다. `securityPolicyDiff`의 시그니처가 같아
스킬 영향이 없다(`repro-u8` P8 통과). 프롬프트 리터럴·진행 문구는 같다.

### 2.4 반영하지 않은 상류 변경

외부 스캐너 findings import(GitHub·Endor·Semgrep·Snyk·Wiz, 로컬 리포트), Cloud findings publisher, 스캔 후 소유자 제안,
hosted remediation 명령, 상류 `publish-findings` 스킬. 모두 이 스킬들이 감싸지 않는 경로다. 마이그레이션 53
(`external_source_reports`)이 추가됐다.

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록에 적었다.

## 4. 남은 문제

- 회귀 스크립트는 patch·verify-fix 문서의 고정 리터럴을 dist와 자동 대조하지 않는다. 수동 grep으로만 확인했다.
- standard에서 2단을 거부한 뒤 static으로 다시 실행할 때(패치가 이미 적용된 상태)의 결과는 실측하지 않았다.
- classify-severity prepare·apply는 실행마다 워크벤치 DB 전체를 복사한다(0.4.0부터 같음). runs가 늘어도 복사 횟수는 같다.
