---
title: codex-security npm 0.9.1 정합 — 기본 심각도 루브릭·digest 계약 변경과 헬퍼 번들 배치 변경 대응 기록
type: chore
date: 2026-11-10
status: done
---

# codex-security npm 0.9.1 정합

상류 `openai/codex-security` 태그 `npm-v0.9.1`(커밋 `fe1089ab51`, npm 게시 2026-11-10)에 스킬을 맞춘 기록이다.
기준선은 npm 0.8.2였다. 지난 기록은 `2026-10-30-1000-chore-codex-security-082-alignment.md`다.

## 1. 결론 요약

- 0.8.2 → 0.9.1은 366 커밋이다(0.8.3 125, 0.9.0 220, 0.9.1 21). 0.9.0은 태그만 있고 npm에 게시되지 않았다. 매니페스트는 0.1.95 그대로다.
- 상태 DB 마이그레이션이 57개에서 64개로 늘었다(0.8.3: 58~60, 0.9.0: 61~63, 0.9.1: 64).
- 수정 전 스킬을 0.9.1에서 돌리면 다음이 실패했다.
  - `repro-u8` S1·S5·S7·S12(6건): 기본 심각도 루브릭 원문과 digest 계약 변경(0.8.3부터).
  - `repro-u1` H14g(1건): 헬퍼 번들 배치 변경(스크립트만의 문제).
- 스캔 계열(`repro-u4`·`repro-u7`·`repro-u5`, 관측형 `repro-u3`)은 수정 전에도 통과했다. 스킬이 `loadUpstream`으로 쓰는 dist 멤버 98개도
  모두 남아 있다(이미 대응한 옛 이름 하나만 없음).

## 2. 상류 변경과 반영

### 2.1 기본 심각도 루브릭과 digest 계약 (0.8.3, #2257·#2258·#2260·#2262)

- 기본 루브릭이 플러그인 `references/default-severity-rubric.md`에서 생성된다. 스캔 채점(`core-scan.md`, attack-path
  `severity-policy.md`)과 classify-severity가 같은 루브릭을 쓴다.
- 원문 검토: Critical·High를 세 조건(Access·Impact·Evidence) 목록으로 정리했고 Medium 이하는 문장이 같다. 머리말의
  "Use the supplied report and evidence; do not perform new validation." 한 문장이 빠졌다. 이 스킬의 판정 서브에이전트는 도구가 없어
  새 검증을 할 수 없으므로 판정 기준에 주는 영향은 없다고 판단했다.
- 반영: `classify_severity.mjs`의 고정 SHA를 검토 목록 `UPSTREAM_DEFAULT_RUBRIC_SHA256S`(0.9.1, 0.6.0~0.8.2)로 바꿨다. 0.8.3의
  중간 원문은 검토하지 않아 `defaultRubricDrift: true`로 알린다.
- 보고용 `rubricSha256`은 루브릭 원문(단일 문서)의 일반 SHA-256으로 바뀌었다. 체크포인트 바인딩은 `rubricCheckpointSha256`
  (= `workflowDigest`)이 따로 맡는다. 기본 루브릭이면 `rubricRevision`도 붙는다. 스킬은 두 값을 상류 결과에서 옮기므로 계산을 바꾸지
  않았다. `repro-u8` S1·S5·S7은 `dist/severity-rubric.js` 유무로 계약을 고르고, S12는 Node로 import한 원문으로 대조한다(0.9.1 dist는
  템플릿 리터럴이 아니라 일반 문자열로 내보낸다).
- `CODEX_SECURITY_ENABLE_REMOTE_SEVERITY_RUBRIC=1`이면 상류가 원격 루브릭을 받아 온다. 스킬은 `env -i` 신뢰 환경으로 상류를 부르므로
  이 값이 넘어가지 않고 항상 번들 루브릭을 쓴다.

### 2.2 헬퍼 번들 배치

- `mcp/helpers.mjs.br.part-*` 조각이 단일 `mcp/helpers.mjs.br`로 바뀌었다. 스킬 코드는 번들을 직접 읽지 않는다. `repro-u1` H14g만
  1 MiB 한도 문구를 찾으려고 번들을 풀었으므로 두 배치를 모두 받게 고쳤다.

### 2.3 scan-match 조건부 문장

- `comparisonPrompt`가 `crossModeSite` 카드용 조건부 문장을 더했다. 상류는 standard↔deep 모드가 다른 두 스캔을 비교하고
  다회차 판정일 때만 쓴다(`!runtimeOptions.singleTurn`). 이 스킬은 한 번짜리 판정이라 상류 single-turn 경로와 같으므로 반영하지 않았다.
  입력의 `crossModeOccurrenceIds`는 검증기가 무시한다.

### 2.4 스캔 산출물과 문서

- finalizer는 coverage.json 형식(이 스킬의 형식)을 계속 봉인한다. 미봉인 초안에 coverage.json이 있으면 `coverageRef`를 자동으로 넣는
  분기도 그대로다.
- `report.md`가 informational finding의 개수만 적고 세부를 싣지 않는다(#155). 스캔 스킬 최종 보고에 그 안내를 넣었다.
- 스킬이 인용한 상류 문장과 제목 중 0.9.1에서 사라진 것은 없다(자동 대조).

### 2.5 반영하지 않은 상류 변경

deep 스캔 개편(#2118), 로컬 dedupe의 Node 이전(#1840), 봉인 스캔 읽기 공유(#1846, 스킬이 쓰는 `contract.js` 멤버는 남음), 규칙 통합(#2452),
릴리즈 tarball 검사(#2456), GitHub Action(#1580), Checkmarx import, 원격 심각도 루브릭(#2257, opt-in), fix-finding의 워크벤치 Git 격리 절차
확대(이 스킬은 워크벤치 remediation을 쓰지 않는다).

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록에 적었다.
