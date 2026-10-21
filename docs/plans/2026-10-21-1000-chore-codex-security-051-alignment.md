---
title: codex-security npm 0.5.1 정합 — 상류 패치 릴리즈 대응 기록
type: chore
date: 2026-10-21
status: done
---

# codex-security npm 0.5.1 정합

상류 `openai/codex-security` 태그 `npm-v0.5.1`(커밋 `b2fa51576d81cda5e311e7eb89131ffb13daad8b`, 2026-10-20)에
스킬을 맞춘 기록이다. 기준선은 npm 0.5.0이었다. 지난 기록은 `2026-10-20-1700-chore-codex-security-050-alignment.md`다.

## 1. 결론 요약

- 0.5.0 → 0.5.1은 69 커밋인 상류 패치 릴리즈다. breaking 표기는 없다. 매니페스트는 0.1.95 그대로다.
- 수정 전 스킬을 0.5.1에서 돌리면 `repro-u8` P7·P11만 실패했다. policy 공통 지시 한 줄이 바뀌었기 때문이다.
  나머지 자기채점 스크립트와 `repro-u3` 관측은 0.5.0과 같았다.
- 정적 대조가 없는 리터럴 2개(patch 검증 2줄, verify-fix 머리말)가 `cli.ts`에서 `remediation.ts`로 옮겨졌다.
  문장은 같다.

## 2. 상류 변경과 반영

| 상류 변경 | 스킬 영향 | 반영 |
| --- | --- | --- |
| policy 공통 지시 8번째 줄 변경(`06201edfa` #1741): "directly; sibling source and Git metadata are unavailable" → "only the selected component; do not inspect sibling source or Git metadata" | `repro-u8` P7·P11 실패 | `policy_draft.mjs` 리터럴·복사 시점 커밋(`npm-v0.5.1`)·호스트 환경 절 인용 갱신. 사실 서술이 지시로 바뀌었고, 우리 환경에서는 여전히 샌드박스로 강제되지 않으므로 호스트 환경 절의 대체 조치를 유지 |
| patch·verify 프롬프트 조립을 `remediation.ts`로 이동(`a5753698f` #1684 hosted patch·verification) | 없음. 문장 같음 | patch·verify-fix 문서의 출처 표기 갱신 |
| 인벤토리가 `.svn`도 제외, 상위 디렉터리 `.git` 인식(#1552) | 커버리지 분모가 0.5.0과 다를 수 있음. 하위 디렉터리 스캔에서 추적 중인 gitignore 파일이 새로 들어감(실측 2 → 3). 로컬 패치 diff도 `.svn` 아래를 뺌 | scan·diff-scan 문서의 인벤토리 규칙에 기록 |
| unsealed draft 복구에서 `receiptRefs` 대소문자 무시 중복 검사(#1593) | 없음. 워크벤치 복구 경로 전용이다. 스킬 경로(finalizer)는 0.5.0부터 모든 surface에 걸친 대소문자 중복을 `manifest.scan.artifacts[N].path: duplicate artifact path`로 거부한다(스모크 실측) | 리페어 루프에 실측 문구로 추가 |
| 상태 DB 마이그레이션 51(`deep_scan_worker_threads`) | 없음 | 백업 경고 갱신 |
| `scan-comparison.ts`·`classify-scan-severity.ts`·`severity-store.ts` 내부 구현 변경 | 없음. 판정 문장 같음 | 기준 표기만 |

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록에 적었다. 0.5.0 설치본에서는 `repro-u8` P7·P11이
실패한다. 리터럴을 0.5.1 문구로 바꿨기 때문에 생기는 의도된 드리프트 검출이다.
