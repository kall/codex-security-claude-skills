---
title: codex-security npm 0.8.2 정합 — policy 출력 디렉터리 검사 함수 이름 변경 대응 기록
type: chore
date: 2026-10-30
status: done
---

# codex-security npm 0.8.2 정합

상류 `openai/codex-security` 태그 `npm-v0.8.2`(커밋 `79ff4bde8a4685b9c31ad8f449bdb40df8f468f7`)에 스킬을 맞춘 기록이다.
기준선은 npm 0.8.1이었다. 지난 기록은 `2026-10-29-1000-chore-codex-security-081-alignment.md`다.

## 1. 결론 요약

- 0.8.1 → 0.8.2는 26 커밋이다(릴리즈 커밋 포함). 매니페스트는 0.1.95, 상태 DB 스키마(`scripts/workbench_schema.py`)도 같다.
- 수정 전 스킬을 0.8.2에서 돌리면 `repro-u8`만 실패했다. policy `prepare`가
  `TypeError: runtime.requirePrivatePolicyOutputDirectory is not a function`으로 멈춰 P3~P11 113건이 FAIL이었다.
  `repro-u4`·`repro-u1`·`repro-u7`·`repro-u5`와 관측형 `repro-u3`는 통과했다.

## 2. 상류 변경과 반영

### 2.1 출력 디렉터리 권한 검사 완화 (#2120)

- `11a45947c fix: allow existing scan output directory permissions`가 `runtime.ts`의 `requirePrivatePolicyOutputDirectory`를
  `preparePolicyOutputDirectory`로 바꿨다. POSIX에서는 0700 검사 대신 소유자만 검사한다. 스캔 출력 디렉터리(`validateOutputDir`,
  `validatePreparedOutputDir`)와 워크벤치 `require_canonical_scan_directory`의 0700 요구도 소유자 검사로 바뀌었다.
- policy 스킬 `prepare`는 상류 함수를 import해 부르므로 깨졌다. 상류 policy(`api.ts`)도 같은 자리에서 새 함수를 부른다.
- 반영: `policy_draft.mjs`가 `preparePolicyOutputDirectory ?? requirePrivatePolicyOutputDirectory`를 고르고, 둘 다 없으면
  명확한 오류로 멈춘다. 출력 디렉터리는 `prepareOutputDir`가 새로 만든 것이라 0700이 성립하므로, 비공개 검사
  (`requirePrivateDirectory`)는 버전과 무관하게 스킬이 계속 한다.
- 같은 종류의 깨짐을 찾으려고, 스킬 `.mjs`가 `loadUpstream`으로 불러 쓰는 상류 dist 멤버 98개를 0.8.2·0.8.1 dist와
  대조했다. 두 버전 사이에 없는 것은 이 함수 쌍뿐이었다.

### 2.2 고정 리터럴과 나머지

`scan-comparison.ts`·`finding-catalogue.ts`·`severity-review.ts`·`classify-severity.ts`·`classify-scan-severity.ts`·
`severity-store.ts`·`default-severity-rubric.ts`·`remediation.ts`·`security-policy.ts`·`security-policy-cli.ts`·
`standalone-validation-prompt.ts`, 플러그인 `references/`·`schemas/`·헬퍼·`finalize_scan_contract.py`·`review_state.py`, 스킬이
읽는 상류 스킬 문서는 `git diff npm-v0.8.1 npm-v0.8.2`가 비어 있다. 설치본 dist는 `runtime.js`만 다르다.
`workbench_target.py`·`workbench_coverage_receipts.py`·`workbench_saved_results.py`의 삭제는 쓰이지 않던 함수 정리다.

### 2.3 반영하지 않은 상류 변경

위협 모델 탐색기 `threat-model-visualize`(#2112), 의존성 경보 해결 `resolve-dependency-alert`(#2084), Amazon Inspector import(#2097),
Debian·Wolfi 컨테이너(#2116), 스캔 제목의 디렉터리 이름 해석(#2121), 대화형 finding 정렬(#2135), dedupe 수정(#2139), deep 스캔 정리(#2137).

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록에 적었다.
