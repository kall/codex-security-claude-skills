---
title: codex-security npm 0.5.0 정합 — 상류 변경과 스킬 수정 기록
type: chore
date: 2026-10-20
status: done (자기채점 0.2.0~0.5.0, 0.5.0 종단간 스모크 완료)
---

# codex-security npm 0.5.0 정합

상류 `openai/codex-security` 태그 `npm-v0.5.0`(커밋 `03414ad84e91a8638bde85af08c47fe957dc9323`, 2026-10-19)에
스킬 9종을 맞춘 기록이다. 기준선은 npm 0.4.0이었다. 지난 기록은
`2026-10-17-1430-chore-codex-security-040-alignment.md`다.

## 1. 결론 요약

- 0.4.0 → 0.5.0은 85 커밋이다. breaking(`!`)은 #1609(advisory capability preflight 은퇴) 1건이다.
- 플러그인 매니페스트는 여전히 0.1.95다. 부트스트랩은 `npmVersion: 0.5.0`을 보고한다.
- 수정 전 스킬을 0.5.0에서 돌리면 `repro-u8` S12 1건만 실패했다. classify-severity 지시 8문단이 새 모듈로
  옮겨졌기 때문이다. 문장은 같다. 실행 경로(prepare의 프롬프트 대조, S1~S11)는 통과했다.
- 종단간 스모크에서 0.5.0 회귀는 없었다. 0.4.0부터 있던 문서 결함 2건을 찾아 고쳤다.

## 2. 상류 변경과 반영

| 상류 변경 | 스킬 영향 | 반영 |
| --- | --- | --- |
| classify-severity 지시 8문단을 `severity-review.ts`의 `severityReviewInstructions`로 이동(#1662, 호스트 리뷰와 공유) | 문장·순서·조립 같음. 정적 대조 위치만 바뀜 | `repro-u8` S12가 `severity-review.js`가 있으면 거기서 대조. 리터럴 출처 주석 갱신 |
| `config_preflight.py`·`capability-profiles.toml`·`config-preflight.md` 삭제, `scan-runtime.md`로 대체(#1609) | 없음. 스킬은 Phase 0부터 이 preflight를 쓰지 않고 3줄 경량 확인을 한다 | scan·deep-scan 문서에 상류 은퇴 사실 기록 |
| finalizer 경로 검증: `codeEvidence` 경로(#1567), `deferred` 경로(#1573) | 없음. 0.4.0 finalizer도 같은 문구로 거부했다(스모크 실측) | 리페어 루프에 오류 문구 추가 |
| diff 리비전과 경로를 `--`로 분리(#1694) | 경로와 같은 이름의 브랜치가 있으면 0.4.0은 `ambiguous argument`로 실패, 0.5.0은 성공 | 없음(상류 수정의 이득) |
| 루트 커밋 diff에 SHA-256 빈 트리 사용(#1716) | MCP `commit` 경로에만 적용. 글루 `register`와 CLI 레시피는 base를 로컬 커밋으로만 받는다 | diff-scan 실패 안내에 루트 커밋 제약 추가 |
| 스캔한 소스에서 excerpt 읽기(#488), 마이그레이션 50(`scans.source_scopes_json`) | 없음. 모든 스모크 스캔의 finding에 `sourceExcerpt`가 있다 | 상태 DB 백업 경고 갱신 |
| `--max-time` 조사 시간 예산(#1674, `investigation-time-budget.md`) | 명시 요청이 있을 때만 쓰는 선택 기능 | 지원하지 않음(감싸지 않는 CLI로 기록) |
| 바뀌지 않음 | `security-policy.ts`·`security-policy-cli.ts`, `scan-comparison.ts`, `standalone-validation.md`·`static-finding-assessment.md`, patch 검증 2줄(`cli.ts` 약 7747행), 워크벤치 명령, 헬퍼 경로 | 기준 표기만 갱신 |

## 3. 스모크에서 찾은 문서 결함 (0.4.0부터)

1. diff 스캔의 `coverage.inventoryStrategy` 값이 문서에 없었다. `git_diff`로 짐작하면 finalize가
   `coverage.schema.inventoryStrategy: unsupported value 'git_diff'`로 거부한다. 값은 `diff`다.
   diff-scan 0단계 표와 리페어 루프에 넣었다.
2. 루트 커밋을 diff 대상으로 지정하면 워크벤치 등록이 실패한다(`Base revision does not resolve to a local
   Git commit`). 실패 안내에 넣고 전체 스캔을 안내하게 했다.

## 4. 검증 결과 (2026-10-20)

0.5.0·0.4.0·0.3.0은 자기채점 5종 모두 exit 0이다. 0.2.0은 `repro-u8` P7 1건만 실패한다(0.3.0 policy 진행 문구 변경, 의도된 검출). `repro-u3` 요약은 네 버전이 같다.

`/tmp`가 정리되어 0.2.0~0.4.0 격리 설치본을 다시 설치했다. Python 3.14.8, Node v22.23.2.
결과는 `docs/verification/phase0-results.md` 마지막 부록에 적었다.

## 5. 남은 문제

- 루트 커밋 diff는 워크벤치 경로로 지원하지 않는다. 워크벤치 없이 로컬로 봉인하는 경로는 실행해 보지 않았다.
- `coverage_reconcile.py`는 모델이 직접 쓴 `deferred` 경로를 검사하지 않는다. finalizer가 거부하므로
  리페어 루프로 처리한다.
