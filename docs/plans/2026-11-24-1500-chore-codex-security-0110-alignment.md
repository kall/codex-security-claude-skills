---
title: codex-security npm 0.11.0 정합 — 분류 지시 9문단과 호스트 Continuum 평가 부재 규칙 대응 기록
type: chore
date: 2026-11-24
status: done
---

# codex-security npm 0.11.0 정합

상류 `openai/codex-security` 태그 `npm-v0.11.0`(커밋 `353fbf8f5c`)에 스킬을 맞춘 기록이다. 기준선은 npm 0.10.0이었다. 지난 기록은
`2026-11-12-1500-chore-codex-security-0100-alignment.md`다.

## 1. 결론 요약

- 0.10.0 → 0.11.0은 85 커밋이다(0.10.1 30, 0.11.0 55). 매니페스트는 0.1.95 그대로다. 상태 DB 마이그레이션은 72개 그대로다.
- **0.11.0은 작업 시점(2026-11-24)에 npm에 없었다**(레지스트리 최신은 0.10.1). `docs/releasing.md` 7.1절대로 태그 소스로 패키지를
  빌드해 격리 설치하고 검증했다. native 바이너리는 0.10.1 배포본에서 가져왔다(두 태그 사이 native 변경은 napi 패치 버전 올림뿐).
  빌드한 tarball에는 0.10.1 배포본보다 빠진 파일이 없다. 직전 npm 배포본 0.10.1에서도 자기채점을 돌렸다.
- 수정 전 스킬은 0.11.0에서 `repro-u8`이 실패했다. 상류 분류 지시가 바뀌어 classify-severity prepare가 `upstreamPromptDrift`로 멈춘다.
  0.10.1부터의 변경이므로 이전 릴리즈(v0.10.0)의 classify-severity는 npm 0.10.1에서도 동작하지 않는다. 스캔 계열(`repro-u4`·`repro-u1`·
  `repro-u7`·`repro-u5`)은 통과했다.
- 스킬이 인용한 상류 영문 문장·파일·식별자 중 사라진 것은 없다(자동 대조). `loadUpstream` dist 멤버 33개도 모두 있다.

## 2. 상류 변경과 반영

### 2.1 분류 지시 9문단 (0.10.1, `2911786f24` #2619)

- `severity-review.ts`의 `severityReviewInstructions` 4문단 뒤에 한 문단이 생겼다. "Use supplied deployment observations or execution
  results to establish or rule out reachability for the reported target and attacker. A scanner verdict or source analysis alone does
  not establish deployed access."
- 검토: 판정 기준만 더한다. 도구·파일 접근·출력 형식을 바꾸지 않으므로 신뢰 구획에 넣어도 된다. 판정 서브에이전트는 도구가 없다.
- 반영: 고정 리터럴을 검토한 변형 목록 `UPSTREAM_CLASSIFY_INSTRUCTION_VARIANTS`(0.1.29~0.10.0 8문단, 0.10.1~0.11.0 9문단)로 바꿨다.
  받은 지시부가 그중 하나와 문자 단위로 같아야 한다. 새 변형은 상류 소스 배열과 문자 단위로 같음을 확인했다.
- `repro-u8` S12는 설치된 dist에 문장이 모두 있는 변형을 고르고(가장 긴 것), 실제 상류 프롬프트가 그 변형 + 데이터 줄과 정확히 같은지
  본다. 그래서 dist에 새 문장이 더해져도 실제 프롬프트 검사에서 실패한다.
- 대안: 리터럴을 9문단으로 바꾸기만 하면 0.10.0 이하가 깨진다. 지원 구간을 유지하려고 변형을 더했다.

### 2.2 호스트 Continuum 평가 부재 (0.11.0, `73eb1520f6` #2794)

- 상류 patch·verify-fix가 워크벤치에 저장한 AWS Continuum 평가(`continuumAssessment`)를 다시 쓴다. 평가가 없으면 `remediation.ts`가
  프롬프트 맨 앞에 "No host Continuum assessment was supplied. Do not attribute a provider verdict or proof to claims in the finding
  text."를 넣고, 사용자가 준 JSON finding의 `continuumAssessment` 키를 지운다(`standaloneRemediationText`).
- fix-finding·verify-fix 문서에는 `continuumAssessment`를 미신뢰 보조 맥락으로 다루라는 문단이 생겼다.
- 반영: 두 스킬은 워크벤치 remediation을 쓰지 않으므로 호스트 평가가 항상 없다. 위 문장을 그대로 적용하고, 이슈 서술 속 공급자 판정을
  증거로 쓰지 않으며, 상류의 `continuumAssessment` 보고 규칙은 적용하지 않는다고 적었다.

### 2.3 확인만 한 변경

- finalizer: 오류에 `reason`·`location`이 붙고 `--json-errors` 영수증이 생겼다(#2730). 워크벤치 완료 바인딩의 `excludePaths`(#2699)는
  워크벤치 경로 전용이다. 봉인 결과는 같다(`repro-u4`·`repro-u3`).
- 위협 모델 문서 한 줄, attack-path·severity-policy의 Continuum 검증 증거 문단, final-report·scan-artifacts의 보조 validation(MCP 전용),
  security-scan·diff-scan의 `projectConfigPath`(MCP 전용): 스킬이 런타임에 읽거나 적용하지 않는 경로다.
- scan-match: `comparisonPrompt()`와 `finding-catalogue.ts`가 같다. 워크벤치 매칭 계획 형식만 바뀌었다(#149).
- policy·validate: 상류 문서와 프롬프트가 바뀌지 않았다. 기본 심각도 루브릭 dist도 바이트 단위로 같다.
- `skills add`는 0.11.0에도 있고 `~/.claude/skills`를 같은 방식으로 덮어쓴다(임시 HOME에서 확인).

### 2.4 반영하지 않은 상류 변경

의존성 취약점 조사 `exploitability`(#2712~#2745), 배포 인지 validation 공급자와 Continuum 제출 재개(#2742·#2781 등), CrowdStrike FCS IaC
import(#2589), 스캔 경로 제외 옵션(#2699), deep 스캔 Windows 수정.

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록과 `docs/releasing.md` 7절 표에 적었다.
