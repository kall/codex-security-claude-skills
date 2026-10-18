---
title: codex-security npm 0.4.0 정합 — 상류 변경과 스킬 수정 기록
type: chore
date: 2026-10-17
status: done (자기채점 0.2.0·0.3.0·0.4.0 실측 완료)
---

# codex-security npm 0.4.0 정합

상류 `openai/codex-security` 태그 `npm-v0.4.0`(커밋 `559b492b22bb457aea8ff88c1bd41aacc2cec8bf`, 2026-10-16)에
스킬 9종을 맞춘 기록이다. 기준선은 npm 0.2.0이었다. 지난 검토는
`2026-10-14-1130-chore-codex-security-020-alignment-review.md`다.

## 1. 결론 요약

- 변경 대부분은 0.3.0(`5c5239dd8`)에서 들어갔다. 0.4.0에서 새로 깨진 것은 랭킹 헬퍼 은퇴(#1607)다.
- 상류는 0.2.0 → 0.4.0 사이에 351 커밋이 있었다. 그중 8건이 breaking(`!`)이다. 중간 릴리즈 0.3.0(`5c5239dd8`)이 있다.
- **플러그인 매니페스트 버전은 여전히 0.1.95다.** npm 0.1.26~0.4.0이 모두 같다. 부트스트랩은 계속 파일 존재
  프로브로 경로를 고른다. 이번에 npm 패키지 버전(`npmVersion`)도 보고하게 했다.
- 수정 전 스킬을 0.4.0에서 돌리면 다음이 깨졌다.
  1. classify-severity: `workbench_severity.py` 삭제(#1543) → `saved_assessments.py` import 실패. `repro-u8` S 블록 다수 실패.
  2. 전체·diff 스캔: coverage `completeness` 제거(#1633). `repro-u4` F 블록 실패.
  3. diff 스캔: 인벤토리 확장자 필터 제거(0.3.0 #1347). `repro-u4` I 블록 6건 실패.
  4. 경로 지정 스캔·diff 스캔: `bind-repo-scopes`·`copy-deep-review-input`이 Python에서 Node 헬퍼로 이동(0.3.0).
     자기채점에는 잡히지 않았다. deep-scan 점검 중 찾았다.
  5. deep-lite: 랭킹 헬퍼 8종 은퇴(#1607). 대체 경로가 없다.
  6. policy: 진행 문구 2개 변경(0.3.0 #1416). `repro-u8` P7 실패.
- 0.2.0부터 있던 `repro-u5` Q2b 실패도 원인을 찾아 고쳤다(§4).

## 2. 상류 변경과 스킬 반영

### 2.1 scan·diff-scan

| 상류 변경 | 반영 |
| --- | --- |
| `coverage.completeness` 제거. finalizer가 draft의 키를 버린다. SARIF `codexSecurityCoverageCompleteness` 제거. `invocations`·경고는 status가 completed가 아니거나 `deferred`가 있을 때만 생긴다(#1633) | `coverage_reconcile.py`는 키가 있을 때만 `partial`로 내린다. 미리뷰 파일은 두 버전 모두 `deferred`에 기록한다. 요약에 `coverageComplete`·`completenessField`·`needsFollowUpCount` 추가. SKILL.md 5단계에 버전별 정본 규칙 표 |
| 새 finding 검증 강화. 구 별칭(`root_cause`, `code_evidence`, `dataFlow`, `data_flow`, `evidence_refs`) 거부. `confidence.rationale`·`taxonomy.category`/`cwe`·`provenance.source` 필수 | SKILL.md 작성 규칙과 리페어 루프에 오류 문구 `Scan result contains invalid findings; …` 추가 |
| `bind-repo-scopes`·`copy-deep-review-input`이 Node 헬퍼로만 존재(0.3.0). Python에는 `make-repo-scope-input`·`make-diff-rank-input`만 남음 | `bootstrap.py`가 `bindRepoScopes`·`copyDeepReviewInput`(`kind: python \| node-helper`)을 보고. 스킬이 `kind`로 명령 선택 |
| diff 인벤토리·랭킹 입력이 확장자·`.github` 규칙 없이 바이너리가 아닌 변경 파일 전부를 포함. 삭제 파일은 base 내용으로 판정 | diff-scan 인벤토리 규칙 재작성. 0.2.0 규칙은 이전 규칙으로 남김 |
| 상류 문서에서 터미널 finalizer 경로 삭제, `reviewed_surfaces.md` 작성 지시 삭제 | 스크립트는 우리 경로를 계속 받는다(u3·u4·u7 실측). 명시 지시 우선 원칙으로 경로 유지. `reviewed_surfaces.md` 작성 제거 |
| 바뀌지 않음: `normalize-candidates` 헬퍼, 워크벤치 명령(`register-cli-scan`, `get-scan`, `complete-scan`, `fail-scan`, `list-scans`, `get-scan-feedback`, `recover-scan-results`), 신뢰 게이트 판별 | — |

`install.sh --check`가 매니페스트·npm 버전과 두 헬퍼 경로를 표시한다. 종료코드는 그대로다.

### 2.2 deep-scan (deep-lite 재설계)

- 0.4.0에는 랭킹 서브커맨드 8종(`make-repo-rank-input`, `make-rank-shards`, `make-rank-pool-plan`,
  `validate-rank-shard`, `validate-rank-worker`, `validate-rank-pool`, `merge-rank-outputs`,
  `select-deep-review-input`)이 없다. Node 헬퍼에도 없다. 0.3.0에서 잠시 Node로 옮겨졌다가 0.4.0에서 지워졌다.
- 공식 deep도 0.4.0에서는 랭킹을 하지 않는다. 코디네이터가 독립 표준 스캔을 반복하고 결과를 집계한다.
- 그래서 deep-lite는 랭킹을 재구현하지 않고 구조를 바꿨다. 인벤토리 전체를 서로 다른 샤드 구성으로 **독립
  2패스** 리뷰하고, 두 패스의 raw 후보를 상류 정규화기에 한 번에 넘겨 병합한다. 나머지는 전체 스캔 tail과 같다.
- 비용은 표준 스캔의 약 2배다. 상위 N% 선택으로 비용을 줄이던 수단은 없다.
- 실측 기록: `docs/verification/phase4-deep-lite-pipeline.md`.

### 2.3 classify-severity

- 상류 bf9a5bce9(#1543)가 심각도 저장을 Node(`mcp/helpers.mjs`)로 옮겼다. 스캔별 표
  `scan_severity_assessments`가 생겼고, `begin`이 캐시 행을 이 표로 복사한다. publish 읽기 경로
  (`read-severity-classification`)는 스캔별 표를 읽는다.
- 0.4.0에는 finding별 저장 평가를 **읽기 전용으로** 조회하는 상류 명령이 없다.
- 스킬은 상류 `scripts/snapshot_sqlite.py`로 워크벤치 DB 사본을 만들고(상태 디렉터리 안 0700 임시 디렉터리),
  그 사본에 상류 `SeverityStore.checkpoint(...).load()`를 그대로 부른다. 버전 프로브 없이 0.2.0·0.4.0 모두 동작한다.
  `saved_assessments.py`는 지웠다. `workflow_digest.mjs` 허용 목록에 `severity-store.js`를 더했다.
- `classify-severity.ts` 지시 8문단과 오류 문구 5개는 문자 단위로 같다(166–173행).
- 남은 비용: 실행할 때마다 DB 전체를 복사한다. 프로세스가 강제 종료되면 `.severity-readonly-*` 사본이 남을 수 있다.

### 2.4 policy

- 0.3.0(#1416)에서 진행 문구가 `[1/3] Reading the source`, `[2/3] Writing the threat model`로 바뀌었다.
  CLI 끝 안내는 "copy only SECURITY.md to the Policy target shown"이다.
- 프롬프트 리터럴·오류 문구·매니페스트 필드는 0.2.0과 같다. 리터럴 복사 시점 커밋을 `559b492b2`로 올렸다.
- 이 때문에 0.2.0 설치본에서는 `repro-u8` P7이 진행 문구 2조각 드리프트로 실패한다. 의도된 검출이다.

### 2.5 validate

- 상류 `validate`가 소스 증거만으로 판정한다(#1423). `standalone-validation.md`와
  `static-finding-assessment.md`를 프롬프트에 싣고, 읽기 전용·네트워크 차단으로 돌며, 보고서·PoC를 쓰지 않는다.
  새 옵션은 `--context`, `--context-file`, `--knowledge-base`, `--output-schema`(Ajv 2020)다.
- 스킬 단독 모드가 이 계약을 따른다. 상류 두 문서를 런타임에 읽는다. `--output-schema` 검사는 npm 패키지에 든
  Ajv2020으로 한다. ledger 모드(스캔 후보 검증)는 기존 규칙 그대로다.
- 한계: 상류 샌드박스가 없으므로 실행 금지는 지시 수준이다. DOCX 지식 베이스는 텍스트 변환을 안내한다.

### 2.6 patch·verify-fix·scan-match

- patch 검증 리터럴(0.4.0 `cli.ts` 약 7688행), `fix-finding/SKILL.md`, `verify-fix/SKILL.md`,
  `comparisonPrompt()`(약 973행)는 문자 단위로 같다. verify-fix CLI 머리말 한 줄만 바뀌었다(뜻 같음).
- 상류 #1364가 `validateComparison`의 `enforceConfirmedIdentities` 분기를 지웠다. 조정 단계가 그룹을 먼저
  병합하므로 도달할 수 없던 분기다. 우리 `validate_matches.py`도 같이 지웠다. 단계 표식은 `[최종 단계]`다.

### 2.7 반영하지 않은 상류 변경

`findings serve` 제거(#1340), 로컬 `dedupe`, Cloud findings·publish to Cloud, publish issue receipt 공유(#1426,
오프라인 미검증), CODEOWNERS 우선 소유자 제안(#1519), hosted Standard scan(#1559), Windows 네이티브 프로세스,
의존성 범프, 상류 테스트 이관. 모두 이 스킬들이 감싸지 않는 경로다. `codex-security skills add`는 0.4.0에도
있으므로 기존 충돌 경고를 유지한다.

## 3. 검증 결과 (2026-10-17)

격리 prefix 설치본 세 개(`/tmp/cs020-g`, `/tmp/cs030-g`, `/tmp/cs040-g`)에 npm 래퍼를 두고 돌렸다
(`docs/releasing.md` 7.2절). Python 3.14.8, Node v22.23.2.

| 스크립트 | npm 0.4.0 | npm 0.3.0 | npm 0.2.0 |
| --- | --- | --- | --- |
| `repro-u4.sh` | exit 0, OK 80 | exit 0, OK 80 | exit 0, OK 71 (0.4.0 전용 검사 NOTE) |
| `repro-u1-search-command.sh` | exit 0, OK 95 | exit 0, OK 95 | exit 0, OK 95 |
| `repro-u7-coverage-recovery.sh` | exit 0, OK 70 | exit 0, OK 70 | exit 0, OK 70 |
| `repro-u5-match-validator.sh` | exit 0, OK 714 | exit 0, OK 714 | exit 0, OK 714 |
| `repro-u8-policy-severity.sh` | exit 0, OK 284 | exit 0, OK 284 | exit 1, OK 283, FAIL 1 (P7 진행 문구 드리프트, 의도됨) |
| `repro-u3.sh` (관측형) | S5 0, S6 0, S9 1, S9b 0 | 0.4.0과 같음 | 0.4.0과 같음 |

npm 0.1.32 이하는 다시 검증하지 않았다.

새 단언: `repro-u4` F 블록 스키마 프로브 분기·I17~I20(바이너리 제외, 삭제 파일 포함)·L 블록(헬퍼 `kind` 대조,
`bind-repo-scopes`·`copy-deep-review-input` 실행, 구 별칭 거부 문구), `repro-u7` I5x(completeness 없는 coverage),
`repro-u1` H14a-5~7·H14b-8~9(새 부트스트랩 필드), `repro-u7` I17h(경로 지정 스캔 register → complete). `repro-u7` I5x·I17h는
가드·수정을 되돌린 변이에서 실패함을 확인했다.

종단간 스모크 테스트(npm 0.4.0)는 `docs/verification/phase0-results.md` 마지막 부록에 기록했다. 경로 지정 스캔의
워크벤치 등록이 0.2.0부터 항상 실패하던 결함(글루의 `target.kind`)과 coverage surface 필수 필드 누락 등 6건을 찾아 고쳤다.

## 4. 기존 결함 해소: `repro-u5` Q2b

원인: Python 3.12와 3.14 모두 `json.loads`가 `repr`보다 먼저 재귀 한도에 걸린다. 그래서 JSON 픽스처로는
`_safe_repr`의 재귀 방어 분기에 닿을 수 없었다. Q2를 셋으로 나눴다. Q2a는 900단 중첩 입력의 거부 경로,
Q2b는 100만 단 중첩 입력의 "중첩 한도" JSON 봉투, Q2c는 `repr`이 RecursionError를 내는 객체를 직접 넣어
방어 표식을 확인한다. Q2c는 방어를 지운 변이에서 실패한다.

## 5. 남은 문제

- deep-lite는 전체 인벤토리를 2회 리뷰하므로 큰 저장소에서 비용이 크다. 표현만 다른 같은 근본 원인은
  정규화기가 합치지 않는다(validation 단계에서 정리).
- 0.3.0 이후 경로 지정 스캔과 diff 스캔도 Node가 필요하다(헬퍼 경로).
- 0.3.0·0.4.0은 상태 DB 마이그레이션이 늘었다(스캔별 심각도 표, issue receipt 표). 전역 설치본을 올리기 전에
  상태 디렉터리를 백업한다.
- publish 경로 변경(#1426)은 GitHub가 필요해 오프라인으로 검증하지 못했다.
- 수동으로 CLI를 확인할 때 `mise exec`의 PATH가 전역 CLI를 먼저 잡는다. 격리 설치본은
  `node /tmp/<prefix>/bin/codex-security`로 직접 지정한다.
