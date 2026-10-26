---
title: codex-security npm 0.7.0 정합 — 인벤토리 헬퍼 Node 이전·정책 크기 한도 제거·상류 문서 단순화 대응 기록
type: chore
date: 2026-10-26
status: done
---

# codex-security npm 0.7.0 정합

상류 `openai/codex-security` 태그 `npm-v0.7.0`(커밋 `f05a0b096cc881242ddf34a4d6b3ce0f322f3cf9`, 2026-10-26)에
스킬을 맞춘 기록이다. 기준선은 npm 0.6.0이었다. 지난 기록은 `2026-10-22-1500-chore-codex-security-060-alignment.md`다.

## 1. 결론 요약

- 0.6.0 → 0.7.0은 173 커밋이다. 대부분 CI 변경이다. 매니페스트는 0.1.95 그대로다.
- 수정 전 스킬을 0.7.0에서 돌리면 다음이 실패했다.
  - `repro-u4` FAIL 21·SKIP 3: 인벤토리 스크립트 삭제(#1432). 전체·diff·deep 스캔의 인벤토리 단계가 모두 깨졌다.
  - `repro-u1` H14g: SECURITY.md 1 MiB 한도 제거(#1883).
  - `repro-u8` P7: 같은 변경으로 policy 오류 문구 하나가 사라졌다.
- 상류 스킬 문서가 크게 단순화됐다(#1676, 32개 파일 약 2,000줄 감소). 실행 오류는 없지만 인용 드리프트를 정리했다.

## 2. 상류 변경과 반영

### 2.1 인벤토리 헬퍼 Node 이전 (#1432, breaking)

- `scripts/generate_in_scope_files.py`, `generate_rank_input.py`, `rank_preview.py`가 삭제됐다. 대신
  `launch_codex_security_mcp --helper generate-in-scope-files | make-diff-rank-input | make-repo-scope-input`을 쓴다. 인자 이름은 같다.
- 부트스트랩에 `inScopeInventory`·`diffRankInput`(`kind: python | node-helper`)을 더하고, scan·diff-scan·deep-scan 명령형을
  kind로 나눴다. 0.6.0 이하(Python)도 계속 지원한다.
- 실측: 출력 집합(add-back, `.rgignore`·`RIPGREP_CONFIG_PATH` 축소와 완화, diff 확장자·바이너리·삭제 파일 규칙), 빈 스코프,
  줄바꿈 경로 exit 2가 0.6.0 Python과 같다. 줄바꿈 오류 문구의 `generate_in_scope_files: ` 접두사만 없어졌다.
- Node 헬퍼도 rg를 PATH에서 찾는다(폴백 없음). 그래서 `searchCommand`는 계속 필요하다. 0.7.0부터는 전체 스캔 인벤토리에도 Node가 필요하다.

### 2.2 SECURITY.md 1 MiB 한도 제거 (#1883)

- `resolve-security-md` 헬퍼와 `security-policy.ts`에서 한도와 오류 문구, 초안 크기 검사가 모두 지워졌다.
- policy 스킬은 설치본 dist에 한도 문구가 있으면 기존처럼 1 MiB를 검사하고, 없으면 큰 정책을 받아들인다(`policySizeLimit`).
- scan 0단계는 버전별로 서술을 나누고, 큰 정책은 나눠 읽으라고 지시했다. `repro-u1` H14g·`repro-u8` P4·P4c·P7을 버전 분기했다.

### 2.3 상류 문서 단순화 (#1676) 등

- scan 쪽 깨진 인용 8건을 정리했다. 예: `final-report.md`의 shell-authored fallback 문구, surface ID 서술, validation·attack-path의
  `Compact Workbench Diff` 절 이름, `scan-artifacts-and-ledger.md`가 "Standalone Diff Worklists and Artifacts"로 개편된 것.
  인용이 사라진 곳은 이 저장소 문서가 권위를 가진다고 적었다.
- patch: 상류 fix-finding의 사전 조사 절이 없어지고 리뷰 절이 `Review the fix`로 바뀌었다. 스킬은 사전 조사·후보 리뷰 두 패스를
  유지한다(상류가 허용하는 범위에서 더 엄격한 선택). 승인 게이트·정적 모드는 그대로다.
- verify-fix: 상류 대화형 응답은 Markdown이 됐다(#1836). 스킬은 CLI 대체이므로 JSON 결과를 고정한다. hosted checks 확장은 제거됐다(#1951).
- validate: 단독 모드가 읽는 상류 문서는 같다. ledger 모드 서술을 버전 중립으로 바꿨다.
- classify-severity·scan-match: 상류 원문 변경 없음. 기본 루브릭 SHA-256도 같다.

### 2.4 반영하지 않은 상류 변경

외부 import·게시 워크플로 opt-in(`CODEX_SECURITY_ENABLE_EXTERNAL_IMPORTS=1`, #1863), `scan --validate`(#1007, 스캔 뒤
단독 검증 — validate 스킬 단독 모드로 같은 목적을 이룬다), deep 스캔 수정과 마이그레이션 54~57, CI 변경.

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록에 적었다.
