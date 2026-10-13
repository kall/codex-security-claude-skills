---
title: "녹색 기준선은 스크립트가 도는 경로만 증명한다 — 상류 정합 때 글루→상류 호출 경로를 전부 실측하기"
date: 2026-10-01
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
symptoms:
  - "0.1.29·0.1.32 정합에서 수정 전 기준선이 모두 exit 0이라 '회귀 없음'으로 결론냈다"
  - "workbench_glue.py register --mode diff 가 글루를 처음 만든 때부터 항상 exit 1이었는데 어떤 스크립트도 잡지 못했다"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
tags: [codex-security, upstream-alignment, regression-test, coverage-gap, control-assertion, version-gate, diff-scan]
---

# 녹색 기준선은 스크립트가 도는 경로만 증명한다

> **경로 기준**: `plugins/codex-security/...`·`sdk/typescript/...` 경로는 업스트림
> [openai/codex-security](https://github.com/openai/codex-security) 저장소 기준이다(이 저장소에는 없다).
> 그 밖의 경로는 이 저장소 기준이다. 행 번호는 작성 시점(2026-10-01) 기준이다.

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

## Guidance

1. **녹색 기준선을 "회귀 없음"의 증거로 쓰지 않는다.** 녹색은 스크립트가 실제로 도는 경로만 증명한다. 결론 문장은 "스크립트가 도는 경로에서 회귀 없음"으로 쓴다.

2. **정합마다 호출 경로 표를 만든다.** 스킬 문서가 안내하는 글루 서브커맨드 × 모드·옵션 조합을 모두 적는다. 예: `register`(standard/deep/scoped/diff refs/diff working_tree), `contract`, `complete`, `fail`, `close-stale`(`workbench_glue.py:572-616`의 서브파서). 각 행에 "실제 상류 사본에 대고 이 조합을 돌리는 단언"을 하나 이상 연결한다. 연결할 단언이 없는 행이 커버리지 구멍이다.

3. **상류 diff는 "우리 경로 중 어디가 이 코드에 닿는가"로 읽는다.** 변경된 함수마다 그 함수를 부르는 상류 서브커맨드를 찾는다. 그 서브커맨드를 부르는 글루 경로를 찾는다. 찾은 경로를 실제로 한 번 돌린다. 코드를 읽고 "영향 없음"으로 끝내지 않는다.

4. **상류 거부를 고정하는 대조군을 둔다.** 글루가 상류 제약을 우회하도록 고쳤으면, 그 제약이 아직 있는지 재는 단언을 따로 둔다(I17e). 상류가 나중에 제약을 풀면 이 단언이 FAIL로 알려 준다. 그때 우회를 걷어낼지 판단한다.

5. **새 단언은 예전 코드에서 실패하는지 확인한다.** 수정 전 글루에 대고 돌려 FAIL 건수를 기록한다. 예전 코드에서도 통과하는 단언은 회귀를 잡지 못한다.

6. **새 상류에만 있는 동작은 형제 심볼로 게이트한다.** 매니페스트 버전이 릴리즈를 가르지 못하면, 같은 릴리즈에 들어온 상류 심볼의 존재로 가른다. 게이트 밖이면 NOTE를 찍고 집계하지 않는다. SKIP은 "전제가 없어 검증하지 못함"에만 쓴다. 게이트 때문에 검사하지 않는 항목은 README와 검증 기록에 사본별로 적는다. 게이트가 기대는 조건(직전 배포본 지원)이 사라지면 게이트를 걷고 강한 단언으로 바꾼다. 예: npm에 0.1.32가 배포되고 0.1.31 지원을 끊을 때.

## Why This Matters

- diff 스캔은 문서화된 기능이었다. 그런데 기준선 npm 0.1.18부터 0.1.29까지 등록 단계에서 항상 실패했다. 세 번의 정합(0.1.25·0.1.29·0.1.32)이 모두 수정 전 기준선을 "회귀 없음"으로 봤다.
- 원인은 테스트 품질이 아니라 테스트 범위였다. 스크립트 6종은 모두 정확했다. diff 등록을 돌리는 스크립트가 없었을 뿐이다.
- 상류 diff를 코드 경로 기준으로 읽지 않았으면 이번에도 놓쳤다. #1040은 digest 계산만 바꿨고 레시피 검사는 바꾸지 않았다. 결함은 그 변경이 아니라 그 변경에 닿는 경로를 돌렸을 때 드러났다.
- 대조군이 없으면 상류가 제약을 풀어도 모른다. 그러면 글루의 우회가 근거 없이 남는다.
- 버전 게이트를 SKIP으로 처리하면 직전 배포본에서 릴리즈 검증이 항상 실패한다. 그러면 사람들이 exit 2를 무시하는 습관이 생긴다. 그 습관은 진짜 전제 부족을 가린다.

## When to Apply

- 상류 태그를 올리고, 수정 전 기준선이 모두 통과할 때. 이때가 가장 위험하다.
- 스킬 문서에 새 모드·옵션을 추가하거나, 글루가 상류 서브커맨드를 새 방식으로 부를 때.
- 상류 변경 로그에 워크벤치·레시피·계약 필드 변경이 있을 때.
- 새 상류에만 있는 동작을 단언해야 하는데, 직전 배포본에서도 스크립트가 통과해야 할 때.

## Examples

**호출 경로 표의 한 행(수정 전 상태):**

| 글루 경로 | 스킬 문서 | 실제 상류에 대고 도는 단언 |
| --- | --- | --- |
| `register --mode standard` | codex-security-scan | repro-u7 여러 블록 |
| `register --mode diff --diff-target refs` | codex-security-diff-scan `SKILL.md:37` | 없음 → 구멍 |
| `register --mode diff --diff-target working_tree` | codex-security-diff-scan `SKILL.md:39` | 없음 → 구멍 |

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

## Related

- [codex-security 번들 플러그인을 OpenAI 인증 없이 Claude Code 스킬로 실행하기](../architecture-patterns/codex-security-plugin-without-openai-auth.md) — 워크벤치 수명주기 계약(계약 2·3·6). 계약 1-b의 심볼 프로브는 이 문서의 형제 심볼 게이트와 같은 원리다.
- [릴리즈 절차](../../releasing.md) 7절(플러그인 업데이트 대응)과 7.1절(npm 미배포 태그 검증), 2절의 exit 2 규칙.
- [phase0-results.md](../../verification/phase0-results.md) — npm 0.1.25·0.1.29 부록의 "회귀 없음"(당시에도 diff 등록은 깨져 있었다)과 npm 0.1.32 부록.
- 상류 경로 이동 주의: npm 0.1.21 이전 태그의 플러그인은 `sdk/typescript/_bundled_plugin/`에 있다. 옛 태그를 조회할 때 경로 오류를 "없음"으로 읽지 않는다.
