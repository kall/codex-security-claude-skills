---
title: "녹색 기준선은 스크립트가 도는 경로만 증명한다 — 상류 정합 때 글루→상류 호출 경로를 전부 실측하기"
date: 2026-10-01
last_updated: 2026-10-27
category: workflow-issues
module: codex-security-claude-skills
problem_type: workflow_issue
component: tooling
related_components:
  - testing_framework
severity: high
applies_when:
  - "상류 codex-security를 새 태그(npm-vX.Y.Z)로 올리고 회귀 스크립트가 수정 전부터 모두 통과할 때"
  - "글루 스크립트가 상류 워크벤치 서브커맨드를 모드·옵션별로 다르게 호출할 때"
  - "상류 diff를 읽고 우리 스킬에 영향이 있는지 판단해야 할 때"
  - "새 상류 릴리즈에만 있는 동작을 단언하는데 플러그인 매니페스트 버전으로 사본을 구분할 수 없을 때"
  - "자기채점 스크립트와 코드 리뷰가 모두 통과해서 정합을 끝내려 할 때"
  - "이미 있는 동작을 고정하는 특성화 단언을 새로 쓸 때"
  - "상류 diff를 읽고 스킬 문서에 상류 동작에 관한 새 문장(오류 문구, 한도, 어느 버전부터)을 쓸 때"
  - "상류가 한도나 검사를 지웠을 때"
symptoms:
  - "0.1.29·0.1.32 정합에서 수정 전 기준선이 모두 exit 0이라 '회귀 없음'으로 결론냈다"
  - "workbench_glue.py register --mode diff 가 글루를 처음 만든 때부터 항상 exit 1이었는데 어떤 스크립트도 잡지 못했다"
  - "deep-lite의 register --mode deep → complete가 처음부터 항상 거부됐는데 자기채점 스크립트와 코드 리뷰가 모두 통과했다"
  - "새 특성화 단언이 지키려는 검사를 지워도 통과했다(다른 검사가 먼저 거부해서 대상 검사에 닿지 않음)"
  - "npm 0.4.0~0.7.0 정합 다섯 번 모두 자기채점은 녹색이었는데 종단간 스모크가 매번 결함을 찾았다"
  - "상류 diff를 읽고 이번 정합에서 새로 쓴 리페어 항목이 실측과 달랐다(0.5.1 receiptRefs)"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
tags: [codex-security, upstream-alignment, regression-test, coverage-gap, control-assertion, version-gate, diff-scan, deep-scan, smoke-test, mutation-check, doc-claim, execution-canary]
---

# 녹색 기준선은 스크립트가 도는 경로만 증명한다

> **경로 기준**: `plugins/codex-security/...`·`sdk/typescript/...` 경로는 업스트림
> [openai/codex-security](https://github.com/openai/codex-security) 저장소 기준이다(이 저장소에는 없다).
> 그 밖의 경로는 이 저장소 기준이다. 행 번호는 각 절의 작성 시점(2026-10-01, 「두 번째 사례」는 2026-10-14, 「0.4.0~0.7.0 정합」은 2026-10-27) 기준이다.

## Context

상류 기준을 npm 0.1.29에서 태그 `npm-v0.1.32`로 올렸다. 수정 전 스킬로 회귀 스크립트 6종(자기채점 5종과 `repro-u3.sh`)을 새 상류에서 돌렸다. 모두 exit 0이었다(`docs/verification/phase0-results.md:1282-1284`). 0.1.25·0.1.29 정합도 같은 방법으로 "회귀 없음"을 결론냈다(`docs/verification/phase0-results.md` 0.1.25 부록 `:1135`, 0.1.29 부록 `:1201`).

그런데 diff 스캔 등록은 글루를 처음 만든 때(2026-08, 당시 기준선 npm 0.1.18)부터 한 번도 성공한 적이 없다.

- 예전 글루 `cmd_register`는 레시피 `mode`에 `"diff"`를 그대로 넣었다.
- 상류 `parse_scan_recipe`는 `mode`로 `standard`·`deep`만 받는다. 다른 값이면 `Scan launch recipe mode must be standard or deep.`로 끝난다(태그 `npm-v0.1.32`의 `plugins/codex-security/scripts/workbench_db.py:1815`, 검사는 `:1828-1829`). 이 검사는 상류 최초 태그 `npm-v0.1.0`부터 모든 태그에 있다. npm 0.1.21 이전에는 플러그인 경로가 `sdk/typescript/_bundled_plugin/`이라, 새 경로(`plugins/codex-security/`)로 옛 태그를 조회하면 파일이 없다고 나온다. 이 작업에서도 처음에 그 결과를 "검사 없음"으로 잘못 읽었다.
- 상류는 diff를 `target.kind`(`refs`/`working_tree`)와 `base`/`head`로 받는다. 그 값에서 `mode=diff`를 유도한다(같은 파일 `:1833-1838`의 target kind 목록, `:1675-1688`의 diff 대상 처리와 `mode` 유도).

`skills/codex-security-diff-scan/SKILL.md`는 이 명령을 Phase 2 절차로 문서화했다. 그러나 어떤 스크립트도 diff 등록을 실제 상류 사본에 대고 돌리지 않았다. 그래서 기준선이 녹색이어도 결함이 남았다.

발견 경로는 테스트가 아니었다. 상류 변경 하나를 읽었다. "커밋 diff digest를 종결 시점에 계산한다"(`fix(plugin): calculate diff digests at completion (#1040)`, `npm-v0.1.32`에 포함)이다. 이 변경은 `workbench_completion_binding`과 `workbench_target.diff_snapshot_digest`를 바꾼다(`workbench_target.py:23-27`의 `committed_diff_snapshot_digest`, `:30`의 `diff_snapshot_digest`). 그다음 "우리 글루의 어떤 경로가 이 코드에 닿는가"를 물었다. 답은 `register --mode diff` → `complete`였다. 이 경로를 실제로 돌리자 등록 단계에서 바로 실패했다.

수정과 고정:

- 글루는 diff를 `target.kind`로 보낸다. 레시피 `mode`는 `standard`로 둔다(`skills/codex-security-scan/scripts/workbench_glue.py:221-245`의 `cmd_register`).
- `contract`는 `diffTarget`과 `snapshotDigest`를 돌려준다(`workbench_glue.py:277-311`의 `cmd_contract`, `:327-343`의 `diff_snapshot_fields`). 커밋·range digest 식은 상류 `committed_diff_snapshot_digest`와 같다(`workbench_glue.py:314-323`).
- `docs/verification/scripts/repro-u7-coverage-recovery.sh`에 I17a~f와 I18을 넣었다(I17 블록은 `:1224`부터). I17e는 대조군이다. 상류가 레시피 `mode=diff`를 여전히 거부하는지 잰다(`:1391-1405`).
- 예전 글루에 대고 돌리면 새 단언 중 6건이 FAIL이다. 상류 거부를 재는 I17e만 통과한다(`docs/verification/phase0-results.md:1308`).

부수 결정도 하나 있다. 새 상류에만 있는 동작을 단언하는 방법이다.

- 대상은 `repro-u4.sh` I9~I12(`.m`·`.sol`·`.svelte` 인벤토리 확장자, `docs/verification/scripts/repro-u4.sh:646-672`)와 `repro-u7` I17c(상류가 채운 digest와 글루 계산값 대조, `repro-u7-coverage-recovery.sh:1377-1389`)다.
- 플러그인 매니페스트 버전은 npm 0.1.26~0.1.32에서 모두 `0.1.95`다(`README.md:73-77`). 버전으로 사본을 가를 수 없다.
- 그래서 같은 릴리즈에 들어온 다른 상류 심볼로 사본을 알아본다. `workbench_target.py`에 `def committed_diff_snapshot_digest`가 있으면 0.1.32 사본이다.
- 해당 사본이 아니면 SKIP이 아니라 NOTE를 찍는다. NOTE는 집계하지 않는다. SKIP은 exit 2(`INCOMPLETE`)이고 `docs/releasing.md:52-53`은 이를 실패로 취급한다. 0.1.32가 npm에 아직 없어서 직전 배포본 0.1.31에서도 스크립트가 통과해야 했다.
- 대가: 0.1.31에서는 `.m`(0.1.31에 추가, `fix(plugin): include Objective-C sources in scan inventories (#989)`)을 검사하지 않는다. `README.md:76-77`(0.1.32 전용 검사는 NOTE)과 `docs/verification/phase0-results.md:1309-1310`(`.m` 미검사)에 적었다.
- 리뷰어가 NOTE와 SKIP의 차이를 지적했다. 위 이유로 NOTE를 유지했다.

### 두 번째 사례 — deep-lite 등록 (npm 0.2.0 정합, 2026-10-14)

같은 일이 다시 일어났다. 이번에는 호출 경로 표의 deep 행이다.

- 이 문서의 지침 2는 `register`(standard/**deep**/…)를 표에 적으라고 했다. 그러나 deep 행에 연결한 단언은 없었다. 2026-07 deep-lite 검증 기록도 전체 LLM 연쇄 실행을 "서브에이전트 재개 시점으로 남긴다"고 적었다(`docs/verification/phase4-results.md:41-43`).
- 0.2.0 정합에서 자기채점 6종, 상류 diff 읽기, 전체 코드 리뷰, 후속분 코드 리뷰가 모두 통과했다(이 세션의 판단).
- 그다음 **종단간 스모크 테스트**를 돌렸다. 합성 저장소에 스킬 문서의 명령을 그대로 따라 등록부터 워크벤치 `complete`까지 실행했다. deep-lite만 `complete`에서 실패했다: `Deep Scan discovery orchestration must finish and persist its manifest before the parent scan can be completed.` 행은 `running`으로 남았다.
- 원인: 상류는 레시피 `mode=deep` 스캔을 종결하기 전에 공식 deep 코디네이터가 만드는 `deep_scan_runs` 행(`succeeded` + manifest)을 요구한다(태그 `npm-v0.2.0`의 `plugins/codex-security/scripts/deep_scan_workbench.py:199-207`, `npm-v0.1.29`에도 `:283`에 같은 문구). deep-lite는 그 행을 만들지 않는다. 그래서 deep-lite의 워크벤치 종결은 처음부터 성공한 적이 없다.
- 수정: deep-lite를 표준 모드로 등록한다(`skills/codex-security-deep-scan/SKILL.md:41-53`). 글루는 `register --mode deep`을 상태 DB에 행을 만들기 전에 거부한다(`skills/codex-security-scan/scripts/workbench_glue.py:222-229`). 고정 단언은 `repro-u7` I17g다(`docs/verification/scripts/repro-u7-coverage-recovery.sh:1426-1454`). 수정 전 글루에서는 등록이 성공해 running 행이 생기므로 FAIL이다.
- 같은 스모크 테스트에서 문서 차이도 하나 나왔다. diff 스캔 문서가 인용한 정규화 실패 문구가 0.2.0 Node 헬퍼와 달랐다(지금은 두 버전 문구를 함께 적는다, `skills/codex-security-diff-scan/SKILL.md:137-139`). 자기채점 스크립트는 문구를 재지 않으므로 잡을 수 없었다.

이번에 드러난 두 번째 구멍은 **특성화 단언**이다. 이미 있는 동작을 고정하는 단언은 지침 5("예전 코드에서 실패하는가")로 확인할 수 없다. 예전 코드도 같은 동작을 하기 때문이다.

- `repro-u1` H14b-5는 "플러그인 사본의 정규화 스크립트·스키마가 대상 저장소 안을 가리키면 채택하지 않는다"를 고정하려 했다. 처음 버전은 **파일** 심링크를 대상 저장소 안으로 걸었다.
- 그 단언은 통과했다. 그러나 지키려던 `within_target` 검사를 지워도 그대로 통과했다. 파일 심링크는 그 전에 `is_regular_file`(lstat로 심링크를 거부, `skills/codex-security-scan/scripts/bootstrap.py:559-565`)이 거부하기 때문이다. 단언이 대상 검사에 닿지 않았다.
- **디렉터리** 심링크(`scripts/`·`schemas/` 자체가 대상 저장소 안을 가리킴)로 바꾸자, 같은 코드 변경에서 FAIL이 났다(`docs/verification/scripts/repro-u1-search-command.sh:1242-1260`).
- 같은 방법으로 policy의 투영 실패 처리·`createdAt` 가드를 지웠을 때 P6e·P8e 6건이 FAIL하는 것을 확인했다(`docs/verification/phase0-results.md:1351`). `install.sh`의 종료코드 배선을 끊었을 때 H15c가 FAIL하는 것도 이 세션에서 확인했다(H15c는 대조군 exit 0일 때만 판정한다, `docs/verification/scripts/repro-u1-search-command.sh`의 H15 블록).

### 0.4.0~0.7.0 정합 — 다섯 번 연속 스모크만 잡은 결함 (2026-10-17~2026-10-26)

지침 7을 정합마다 지켰다. 상류 npm 0.4.0, 0.5.0, 0.5.1, 0.6.0, 0.7.0 다섯 번 모두, 자기채점 스크립트를 녹색으로
만든 **뒤에** 돌린 종단간 스모크가 결함을 하나 이상 찾았다(`docs/verification/phase0-results.md`의 0.4.0~0.7.0 부록,
`:1399`·`:1449`·`:1494`·`:1538`·`:1584`). 이번에는 결함이 두 종류였다.

**① 글루→상류 경로 결함 — 세 번째 사례(0.4.0).** 경로 지정 스캔의 워크벤치 등록 `register --paths`가 글루를 만든
때부터 항상 실패했다. 글루가 `target.kind: "repository"`에 `paths`를 실어 보냈고, 상류 `parse_scan_recipe`는 kind가
`"paths"`가 아닌 레시피의 경로를 `Only scoped scan launch recipes can include target paths.`로 거부했다. 지침 2의 표에
"scoped" 행은 있었지만 `complete`까지 도는 단언이 없었다 — diff·deep 행과 같은 구멍이다. 수정은 한 줄이다
(`skills/codex-security-scan/scripts/workbench_glue.py:237`). 고정 단언은 `repro-u7` I17h다
(`docs/verification/scripts/repro-u7-coverage-recovery.sh:1535`). 수정을 되돌린 글루 사본으로 돌리면 I17h가 FAIL하는 것을 이 세션에서 변이로 확인했다.

**② 문서 주장 결함 — 새 종류.** 스모크는 코드뿐 아니라 **이번 정합에서 상류 diff를 읽고 새로 쓴 문장**도 틀렸다고 잡았다.

- 0.5.1: 상류 diff에서 `receiptRefs` 대소문자 무시 중복 검사(#1593)를 보고 "0.5.1 finalizer가 한 surface 안의 중복을
  거부한다"를 리페어 루프에 썼다. 실측해 보니 그 검사는 워크벤치 unsealed draft 복구 경로 전용이고 경고만 낸다. 스킬이
  타는 finalizer는 0.5.0에서도 이미 surface를 가리지 않고 `manifest.scan.artifacts[N].path: duplicate artifact path`로
  거부했다(검사 자체는 npm 0.1.22부터 있다). 실측 문구로 바꿨다(`skills/codex-security-scan/SKILL.md:609`).
- 0.5.0: diff 스캔 문서에 `coverage.inventoryStrategy` 값이 없었다. 문서만 따르면 `git_diff`를 짐작하게 되고, finalize가
  거부한다. 값은 `diff`다(`skills/codex-security-diff-scan/SKILL.md:64`).
- 0.6.0: 정적 검증 모드 문서가 "`git diff --no-ext-diff --no-textconv`로 저장소 코드 실행을 막는다"는 전제에 섰다.
  스모크가 저장소 로컬 `.git/config`에 실행 카나리를 심자 `core.fsmonitor`가 그 명령에서도 실행됐다. git 명령을
  부트스트랩 신뢰 환경으로 감쌌다(`skills/codex-security-patch/SKILL.md:160`).
- 0.7.0: 상류가 SECURITY.md 1 MiB 한도를 지웠다(#1883). 문서에 "0.7.0에서는 큰 정책도 받는다"고 썼다. 실측하니 스킬
  자체의 80,000자 프롬프트 상한(`MAX_PROMPT_CHARACTERS`)이 실제 한도가 되어, `prepare`는 통과하고 다음 단계에서 멈춘
  뒤 출력 디렉터리가 남았다. `prepare`에서 미리 검사하게 했다
  (`skills/codex-security-policy/scripts/policy_draft.mjs:892`, 단언 `repro-u8` P4g
  `docs/verification/scripts/repro-u8-policy-severity.sh:345`).
- 0.4.0: "0.4.0에서 바뀜"으로 적은 상류 변경 4건(#1633 completeness 제거, #1543 심각도 저장 이동, #1423 소스 전용 validate,
  #839·#843 헬퍼 이동)이 실제로는 0.3.0 태그에 들어 있었다. 정합 기준(0.2.0→0.4.0)과 변경이
  처음 들어간 버전을 혼동했다. 공용 문서 작업 에이전트가 `git tag --contains`로 확인해 바로잡았다
  (예: `skills/codex-security-scan/SKILL.md:134`의 "npm 0.3.0부터").

이 결함들은 자기채점 스크립트로는 잡을 수 없었다. 스크립트는 우리가 이미 아는 계약을 잰다. 이번 정합에서 새로 쓴 문장은
아직 어떤 단언과도 연결되지 않은 가설이다.

**③ 검증 도구 자체의 거짓 녹색.** 0.6.0 설치 점검을 `install.sh --check 2>&1 | tail -25; echo exit=$?`로 돌려 "exit 0"이라고
보고했다. 그 값은 `tail`의 종료코드였다. 기존 링크가 있으면 `--check`는 설치 단계의 "건너뜀"을 실패로 세어 exit 1이다.
점검만 하려면 `--check-only`를 쓴다(이 세션의 2026-10-27 확인).

## Guidance

1. **녹색 기준선을 "회귀 없음"의 증거로 쓰지 않는다.** 녹색은 스크립트가 실제로 도는 경로만 증명한다. 결론 문장은 "스크립트가 도는 경로에서 회귀 없음"으로 쓴다.

2. **정합마다 호출 경로 표를 만든다.** 스킬 문서가 안내하는 글루 서브커맨드 × 모드·옵션 조합을 모두 적는다. 예: `register`(standard/scoped/diff refs/diff working_tree), `contract`, `complete`, `fail`, `close-stale`(`workbench_glue.py:578-630`의 서브파서). 각 행에 "실제 상류 사본에 대고 이 조합을 **`complete`까지** 돌리는 단언"을 하나 이상 연결한다. 연결할 단언이 없는 행이 커버리지 구멍이다. 표에 적기만 하고 단언을 연결하지 않으면 구멍은 그대로다(deep 행이 그랬다 — 「두 번째 사례」). deep-lite는 이제 표준 모드로 등록하므로 `register --mode deep`은 거부되는 경로로 적는다.

3. **상류 diff는 "우리 경로 중 어디가 이 코드에 닿는가"로 읽는다.** 변경된 함수마다 그 함수를 부르는 상류 서브커맨드를 찾는다. 그 서브커맨드를 부르는 글루 경로를 찾는다. 찾은 경로를 실제로 한 번 돌린다. 코드를 읽고 "영향 없음"으로 끝내지 않는다.

4. **상류 거부를 고정하는 대조군을 둔다.** 글루가 상류 제약을 우회하도록 고쳤으면, 그 제약이 아직 있는지 재는 단언을 따로 둔다(I17e). 상류가 나중에 제약을 풀면 이 단언이 FAIL로 알려 준다. 그때 우회를 걷어낼지 판단한다.

5. **새 단언은 실패할 수 있는지 확인한다.** 수정을 고정하는 단언은 수정 전 코드에 대고 돌려 FAIL 건수를 기록한다. 예전 코드에서도 통과하는 단언은 회귀를 잡지 못한다. **이미 있는 동작을 고정하는 특성화 단언**은 그 방법이 통하지 않는다. 대신 단언이 지키려는 코드를 잠깐 지우거나 끊고(mutation) 돌려 FAIL을 관찰한 뒤 원복한다. 통과하면 단언이 다른 검사에 먼저 걸려 대상에 닿지 않는 것이다(H14b-5 — 「두 번째 사례」).

6. **새 상류에만 있는 동작은 형제 심볼로 게이트한다.** 매니페스트 버전이 릴리즈를 가르지 못하면, 같은 릴리즈에 들어온 상류 심볼의 존재로 가른다. 게이트 밖이면 NOTE를 찍고 집계하지 않는다. SKIP은 "전제가 없어 검증하지 못함"에만 쓴다. 게이트 때문에 검사하지 않는 항목은 README와 검증 기록에 사본별로 적는다. 게이트가 기대는 조건(직전 배포본 지원)이 사라지면 게이트를 걷고 강한 단언으로 바꾼다. 예: npm에 0.1.32가 배포되고 0.1.31 지원을 끊을 때.

7. **정합을 끝내기 전에 스킬별 종단간 스모크 테스트를 한 번 돌린다.** 합성 저장소(취약점 몇 개, `SECURITY.md`, 삭제 경로가 있는 커밋)를 만든다. 스킬 문서의 셸 명령을 문서에 적힌 그대로(자리표시자에는 부트스트랩 `shellQuoted` 값을 맨몸으로) 실행해 등록 → 봉인 → 워크벤치 `complete`까지 간다. 모델이 판단할 부분(위협 모델, 후보, 랭킹 행)은 직접 작성해도 된다 — 확인하려는 것은 결정론 경로다. 자기채점 스크립트와 코드 리뷰가 녹색이어도 이 단계를 건너뛰지 않는다. 결과는 검증 기록에 스킬·버전별 표로 남긴다(`docs/verification/phase0-results.md`의 0.2.0 부록 「종단간 스모크 테스트」).

8. **이번 정합에서 새로 쓴 상류 동작 문장은 가설로 다루고 스모크로 실행한다.** 상류 diff를 읽고 쓴 오류 문구, 한도,
   "어느 버전부터", 보안 전제(예: "이 플래그가 실행을 막는다")는 실행 경로에 닿기 전까지 확인되지 않은 주장이다.
   스모크 에이전트에게 "이번 diff에서 새로 쓴 문장 목록"을 넘기고, 각 문장을 일부러 위반하는 입력(대소문자만 다른 경로,
   한도를 넘는 정책, 저장소 로컬 `.git/config` 카나리)으로 확인하게 한다. 실측과 다르면 실측 문구로 바꾼다.

9. **상류가 한도나 검사를 지우면, 그 뒤에 숨어 있던 우리 쪽 한도를 찾는다.** 상류 검사가 먼저 걸리던 동안에는 우리
   한도가 드러나지 않는다. 지워진 한도 근처의 우리 상수(프롬프트 상한, 크기 검사, 타임아웃)를 찾아, 어느 단계에서 먼저
   걸리는지와 실패 뒤 남는 산출물을 실측한다.

10. **"npm X부터"는 `git tag --contains <커밋>`으로 확인하고 쓴다.** 정합 구간(예: 0.2.0→0.4.0)에 중간 릴리즈가 있으면,
    변경이 처음 들어간 태그와 정합 대상 태그가 다를 수 있다. 버전 표기는 하위 호환 판정과 사용자 안내의 근거다.

11. **검증 명령의 종료코드는 파이프 앞에서 잰다.** `cmd | tail; echo $?`는 `tail`을 잰다. `cmd > log 2>&1; echo $?`처럼
    출력을 파일로 돌린 뒤 재거나 `PIPESTATUS`를 쓴다.

## Why This Matters

- diff 스캔은 문서화된 기능이었다. 그런데 기준선 npm 0.1.18부터 0.1.29까지 등록 단계에서 항상 실패했다. 세 번의 정합(0.1.25·0.1.29·0.1.32)이 모두 수정 전 기준선을 "회귀 없음"으로 봤다.
- 원인은 테스트 품질이 아니라 테스트 범위였다. 스크립트 6종은 모두 정확했다. diff 등록을 돌리는 스크립트가 없었을 뿐이다.
- 상류 diff를 코드 경로 기준으로 읽지 않았으면 이번에도 놓쳤다. #1040은 digest 계산만 바꿨고 레시피 검사는 바꾸지 않았다. 결함은 그 변경이 아니라 그 변경에 닿는 경로를 돌렸을 때 드러났다.
- 대조군이 없으면 상류가 제약을 풀어도 모른다. 그러면 글루의 우회가 근거 없이 남는다.
- deep-lite도 같았다. 문서에 deep 행을 적으라고 해 두었는데 단언이 없었다. 자기채점 스크립트와 코드 리뷰가 모두 통과했고, 결정론 경로를 끝까지 돌린 스모크 테스트만 잡았다. 리뷰는 코드가 문서와 맞는지를 보고, 상류가 그 경로를 받아들이는지는 실행해야만 보인다.
- 특성화 단언은 예전 코드에서도 통과하므로, 단언이 공허해도 아무 신호가 없다. mutation으로 확인하지 않으면 "단언이 있다"가 "검사가 지켜진다"로 잘못 읽힌다.
- 버전 게이트를 SKIP으로 처리하면 직전 배포본에서 릴리즈 검증이 항상 실패한다. 그러면 사람들이 exit 2를 무시하는 습관이 생긴다. 그 습관은 진짜 전제 부족을 가린다.

- 0.4.0~0.7.0 다섯 번의 정합에서 스모크는 매번 결함을 찾았다. 자기채점이 녹색이 된 뒤였다. 스모크를 "시간이 남으면
  하는 확인"으로 다루면, 다섯 번 중 다섯 번 결함이 배포됐다.
- 문서 주장 결함은 코드 리뷰도 잘 잡지 못한다. 리뷰어는 문서가 상류 diff와 맞는지를 보고, 그 diff를 쓴 사람과 같은
  해석을 할 수 있다. 0.5.1 receiptRefs 문장이 그랬다 — 상류 diff에는 그 검사가 실제로 있었다. 어느 경로에서 도는지는
  실행해야 보였다.
- 보안 전제(실행 차단)가 틀리면 결과가 가장 나쁘다. 정적 검증 모드는 "저장소 코드를 실행하지 않는다"를 약속하는데,
  그 약속을 지키는 플래그가 실제로는 막지 못했다.

## When to Apply

- 상류 태그를 올리고, 수정 전 기준선이 모두 통과할 때. 이때가 가장 위험하다.
- 스킬 문서에 새 모드·옵션을 추가하거나, 글루가 상류 서브커맨드를 새 방식으로 부를 때.
- 상류 변경 로그에 워크벤치·레시피·계약 필드 변경이 있을 때.
- 새 상류에만 있는 동작을 단언해야 하는데, 직전 배포본에서도 스크립트가 통과해야 할 때.
- 상류 diff를 근거로 스킬 문서에 상류 동작 문장을 새로 쓰거나, 상류가 한도·검사를 지웠을 때.

## Examples

**호출 경로 표의 한 행(수정 전 상태):**

| 글루 경로 | 스킬 문서 | 실제 상류에 대고 도는 단언 |
| --- | --- | --- |
| `register --mode standard` | codex-security-scan | repro-u7 여러 블록 |
| `register --mode diff --diff-target refs` | codex-security-diff-scan `SKILL.md:37` | 없음 → 구멍 |
| `register --mode diff --diff-target working_tree` | codex-security-diff-scan `SKILL.md:39` | 없음 → 구멍 |

**같은 표의 deep 행(0.2.0 정합 전 상태):**

| 글루 경로 | 스킬 문서 | 실제 상류에 대고 `complete`까지 도는 단언 |
| --- | --- | --- |
| `register --mode deep` | codex-security-deep-scan(당시 5단계) | 없음 → 구멍. 스모크 테스트에서 `complete` 거부 |

**공허했던 특성화 단언과 고친 형태(H14b-5):**

```bash
# 처음 버전 — 파일 심링크. is_regular_file(lstat)이 먼저 거부하므로 within_target 을 지워도 통과했다.
ln -s "$NT/evil_normalize.py" "$NOHELPER/scripts/normalize_candidates.py"
# 고친 버전 — 디렉터리 심링크. 그 안의 파일은 정규 파일이라 within_target 만이 거부한다.
ln -s "$NT/evil-scripts" "$LINKED/scripts"
```

**예전 글루가 보낸 레시피와 상류 응답:**

```text
{"repository": "...", "mode": "diff", "config": {}, "target": {"kind": "repository", "paths": []}}
→ Scan launch recipe mode must be standard or deep.   (exit 1)
```

**고친 글루가 보내는 레시피(`workbench_glue.py:237-243`):**

```python
recipe["mode"] = "standard"
recipe["target"] = {"kind": args.diff_target, "paths": [], "base": args.base, "head": args.head or "HEAD"}
```

**대조군 I17e(`repro-u7-coverage-recovery.sh:1401-1404`의 판정):** 상류 `workbench_db.py register-cli-scan`에 `mode=diff` 레시피를 직접 넣는다. exit가 0이 아니고 거부 메시지가 나와야 `ok`다. 상류가 이를 받기 시작하면 `bad`로 "상류 계약이 바뀌었을 수 있습니다"를 찍는다.

**형제 심볼 게이트(`repro-u4.sh:658`, `repro-u7-coverage-recovery.sh:1379`):**

```bash
if grep -q "def committed_diff_snapshot_digest" "$PLUGIN/scripts/workbench_target.py" 2>/dev/null; then
  # 0.1.32 전용 단언
else
  printf 'NOTE I17c: 이 플러그인 사본은 npm 0.1.32 이전이라 ... (검사 대상 아님)\n'
fi
```

**결과 기록(`docs/verification/phase0-results.md:1299-1309`):** 0.1.32 빌드에서 `repro-u4` OK 53, `repro-u7` OK 63이다. npm 0.1.31 배포본에서 `repro-u4` OK 49(I9~I12 NOTE), `repro-u7` OK 62(I17c NOTE)다. FAIL·SKIP은 0건이다. 0.1.31에서 `.m`을 검사하지 않는다는 점도 함께 적었다.

**호출 경로 표의 scoped 행(0.4.0 정합 전 상태):**

| 글루 경로 | 스킬 문서 | 실제 상류에 대고 `complete`까지 도는 단언 |
| --- | --- | --- |
| `register --paths <경로>` | codex-security-scan(경로 지정 스캔) | 없음 → 구멍. 스모크에서 등록 거부. 지금은 `repro-u7` I17h |

**스모크 에이전트에 넘기는 "새로 쓴 문장" 목록의 예(0.6.0 정적 모드):**

```text
- 주장: static 모드의 git 읽기 명령은 저장소 코드를 실행하지 않는다.
  확인: 저장소 로컬 .git/config 에 core.fsmonitor·core.pager·diff.external·filter.<x>.clean 카나리를 심고
        문서의 명령형 그대로 실행한다. 대조군으로 같은 저장소에서 일반 git diff·git status 를 돌려 카나리가 발동하는지 본다.
```

## Related

- [codex-security 번들 플러그인을 OpenAI 인증 없이 Claude Code 스킬로 실행하기](../architecture-patterns/codex-security-plugin-without-openai-auth.md) — 워크벤치 수명주기 계약(계약 2·3·6). 계약 1-b의 심볼 프로브는 이 문서의 형제 심볼 게이트와 같은 원리다.
- [릴리즈 절차](../../releasing.md) 7절(플러그인 업데이트 대응)과 7.1절(npm 미배포 태그 검증), 2절의 exit 2 규칙.
- [phase0-results.md](../../verification/phase0-results.md) — npm 0.1.25·0.1.29 부록의 "회귀 없음"(당시에도 diff 등록은 깨져 있었다), npm 0.1.32 부록, npm 0.2.0 부록(종단간 스모크 테스트와 deep 등록 결함), npm 0.4.0~0.7.0 부록(정합마다 스모크가 찾은 결함).
- 정합 기록: `docs/plans/2026-10-17-1430-chore-codex-security-040-alignment.md`부터 `docs/plans/2026-10-26-1500-chore-codex-security-070-alignment.md`까지.
- [phase4-results.md](../../verification/phase4-results.md) — deep-lite를 처음 만들 때 전체 연쇄 실행을 미룬 기록.
- 상류 경로 이동 주의: npm 0.1.21 이전 태그의 플러그인은 `sdk/typescript/_bundled_plugin/`에 있다. 옛 태그를 조회할 때 경로 오류를 "없음"으로 읽지 않는다.
