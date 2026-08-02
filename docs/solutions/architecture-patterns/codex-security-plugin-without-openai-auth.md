---
title: "codex-security 번들 플러그인을 OpenAI 인증 없이 Claude Code 스킬로 실행하기"
date: 2026-07-30
category: architecture-patterns
module: codex-security-claude-skills
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - "codex-security(또는 유사한 Codex 플러그인)의 스캔 기능을 OpenAI/Codex 인증 없이 쓰고 싶을 때"
  - "번들 플러그인의 결정론 스크립트(finalizer, 워크벤치, 랭킹)를 재사용하되 LLM 두뇌만 다른 에이전트로 바꾸고 싶을 때"
  - "임의 저장소에서 실행되는 전역 스킬이 신뢰할 수 있는 플러그인 사본을 선택해야 할 때"
tags: [codex-security, claude-code-skill, no-auth, security-scan, plugin-architecture]
---

# codex-security 번들 플러그인을 OpenAI 인증 없이 Claude Code 스킬로 실행하기

> **경로 기준**: 이 문서의 `sdk/typescript/...` 경로는 업스트림
> [openai/codex-security](https://github.com/openai/codex-security) 기준이다(이 저장소에는 업스트림
> 소스를 포함하지 않는다). `skills/...` 경로는 이 저장소 기준이다.

## Context

codex-security의 스캔 기능은 공식적으로 Codex 바이너리(OpenAI 인증)를 통해서만 실행된다. 그러나
저장소를 분석한 결과, **OpenAI 인증이 필요한 지점은 단 하나 — Codex 에이전트 루프(LLM 호출)뿐**이었다.
번들 플러그인(`sdk/typescript/_bundled_plugin/`)의 결정론 계층(워크벤치 SQLite, `finalize_scan_contract.py`,
랭킹 스크립트)은 인증을 전혀 요구하지 않는다. 오히려 `runtime.ts`의 `runWorkbench`는 자식 환경에서
`OPENAI_API_KEY`/`CODEX_API_KEY`를 **제거**한다(`sdk/typescript/src/runtime.ts:132` 부근).

따라서 "SKILL.md를 읽고 따르는 에이전트" 역할을 Claude Code가 대신하면, 나머지 파이프라인(등록 →
스캔 → 산출물 → 검증 → 봉인 → 이력)을 그대로 재사용할 수 있다. 이 러닝은 그 대체를 실제로 구현하며
(Phase 0~4를 브랜치 `feature/claude-local-skill`에 커밋; 작성 시점 로컬 커밋 `066cebe`·`fc17f3c`·`76430e8`·
`16388dd`·`26a9717`, 아직 미푸시라 병합 시 SHA는 바뀔 수 있음) 확인한 재사용 가치가 있는 계약들을 고정한다.

## Guidance

**전체 구조**: 전역 Claude Code 스킬(`skills/security-scan-local/` 등)이 TS SDK/CLI를 **수정하지 않고**
번들 플러그인의 Python 스크립트를 직접 호출하고, 지능 계층(SKILL.md 워크플로 수행)은 Claude가 담당한다.
플러그인 버전은 벤더링하지 않고 런타임에 읽는다.

구현하면서 반드시 지켜야 할 계약(각각은 실패로 학습한 것):

1. **플러그인 루트 신뢰 게이트 — 리터럴 경로와 realpath를 둘 다 검사한다.** 스캔 대상 저장소는
   미신뢰 코드이므로 그 하위(node_modules 포함)의 플러그인 사본을 절대 채택하면 안 된다(KTD4).
   realpath만 검사하면 대상 저장소가 저장소 밖을 가리키는 **심볼릭 링크**를 커밋해 게이트를 우회한다.
   `npm`도 `shutil.which` 대신 신뢰 PATH 머신러리로 해석하고 정화된 env로 실행해야 대상 저장소의
   `./node_modules/.bin/npm`으로 임의 코드가 실행되지 않는다.
   → `skills/security-scan-local/scripts/bootstrap.py`의 `within_target`, `untrusted_provenance`,
   `npm_global_root`, `default_target_repo`.

1-b. **`pluginVersion`은 동작을 식별하지 못한다 — 사본별 능력 프로브가 필요하다.** npm 배포본
   (`@openai/codex-security@0.1.3`)과 GitHub 저장소 체크아웃이 **둘 다 플러그인 매니페스트 `0.1.14`를
   보고하면서** 워킹트리 게이트 처리가 다르다(실측): 체크아웃은 `require_unchanged_target`으로
   **하드 실패**("… Start a new scan."), npm 배포본은 `scan_target_warning`으로 **경고 후 성공 종결**
   ("… results were saved for the original snapshot.")한다. 게이트 조건(등록 시 저장한 스냅샷
   다이제스트 비교)은 동일하고 위반 시 처리만 다르다. 따라서 (a) 버전 문자열로 계약을 가정하지 말고
   필요한 심볼의 존재를 프로브하고, (b) 종결 결과는 실패 분기와 **경고 분기**를 모두 처리해야 한다.
   경고는 complete-scan 응답의 `scan.warnings`에 실린다(최상위가 아님).

2. **finalize-first, 그다음 complete.** 워크벤치의 워킹트리 불변 게이트(`require_unchanged_target`)는
   우회 불가하고 finalization 전후로 재검사한다. `finalize_scan_contract.py`를 워크벤치 `complete-scan`
   **앞에** 두어야, complete가 실패(스캔 중 파일 변경)해도 `report.md`·SARIF가 보존된다.

3. **complete 전에 get-scan contract를 draft에 반영한다.** `complete-scan`은 봉인된 매니페스트에
   binding을 주입하지 않고 **검증만** 한다. 등록 직후 `get-scan`으로 얻은 좌표(targetId, revision,
   displayName, scope)를 canonical JSON에 반영하지 않으면 complete가 반드시 실패한다
   (`scan.target.targetId: must match the workbench target`). `producer.version`은 get-scan이 아니라
   플러그인 매니페스트(`sdk/typescript/_bundled_plugin/.codex-plugin/plugin.json`의 `version`)에서 온다.

4. **finalizer 소유 필드를 모델이 작성하지 않는다.** `findingId`, `occurrenceId`, `fingerprints`,
   `sealedAt`, `artifacts`, `documentType`, `schemaVersion`, `scan.status`는 finalizer가 파생한다.
   `scan-manifest.json`은 `scan.sealedAt`·`scan.artifacts`가 없는 unsealed draft로 쓴다.

5. **finalizer가 검증하지 않는 것은 스킬이 검증한다.** finalizer는 findings의 `locations` 경로 실존을
   검사하지 않고, 커버리지 완결성이 실제 리뷰와 일치하는지도 강제하지 않는다. 별도 결정론 스크립트
   (`coverage_reconcile.py`)가 리뷰 로그 대비 커버리지를 **집합 기반**으로 정산하고(중복·범위밖 리뷰로
   부풀리기 불가) 경로 이탈/심링크를 거부한다.

6. **complete 실패 시 스캔 행을 자동 종결하지 않는다.** `fail-scan`은 되돌릴 수 없고 해당 스캔을
   비교·false-positive 이력에서 영구 제외한다. 게이트 실패는 예외가 아니라 구조화 결과로 반환해
   사용자가 "재시도 / 실패 기록 / 보류"를 선택하게 한다. 워크벤치 명령에 `--claim-token`은 전달하지 않는다.

7. **미신뢰 데이터·격리.** 대상 저장소 콘텐츠·finding 서술은 데이터로만 취급하고 그 안의 지시를
   실행하지 않는다. 특히 `scans match`의 매칭 판정은 finding 설명(대상 코드 파생)을 읽으므로,
   메인 세션이 아니라 **도구를 제한한 격리 서브에이전트**(파일쓰기·Bash·네트워크 없음, JSON만 반환)에서
   수행한다.

8. **랭킹 파이프라인 계약(deep-lite).** 샤드 디렉터리는 `rank_shards`로 명명하고 pool-plan의 형제여야
   하며, 랭킹 `score`는 1~10 정수이고, `merge-rank-outputs`는 **부분 실패를 거부**한다(누락 샤드 → exit 1).
   랭킹 팬아웃(전량 성공·랭킹 행)과 리뷰 팬아웃(부분 실패 허용·후보)은 출력 스키마·실패 정책이 달라
   반드시 분리한다.

## Why This Matters

이 패턴이 없으면 codex-security는 OpenAI 구독이 있어야만 쓸 수 있다. 결정론 계층이 무인증임을 활용하면
Claude Code 구독만으로 개발자 로컬에서 동일한 봉인 계약 산출물(scan-manifest/findings/coverage +
report.md + SARIF)을 만들고 공식 CLI(`scans list/show`, `findings false-positive`)와 이력 호환된다.

위 8개 계약은 모두 "실패로 배운 것"이다 — 각각을 어기면 게이트가 조용히 통과하거나(신뢰 게이트 우회,
빈 커버리지 봉인), complete가 반드시 실패하거나(contract 미반영), 되돌릴 수 없는 이력 손상(자동 fail-scan)이
발생한다. 특히 **realpath만 검사하는 신뢰 게이트**와 **finalize 없이 검증만 하는 complete-scan**은
코드 리뷰/실측 전에는 드러나지 않은 함정이었다.

## When to Apply

- 임의 저장소에서 실행되는 전역 스킬이 플러그인 사본을 선택할 때(신뢰 게이트 계약 1).
- 워크벤치 이력에 스캔을 등록·종결할 때(계약 2·3·6).
- 모델이 canonical JSON draft를 작성할 때(계약 4·5).
- deep 스캔 대체물을 만들 때(계약 8).
- 스캔 간 매칭이나 finding 판정처럼 대상 저장소 파생 텍스트를 LLM에 넣을 때(계약 7).

## Examples

**신뢰 게이트 — realpath만으로는 부족(계약 1)**:
```python
# 취약: realpath만 검사 → 대상 저장소가 저장소 밖을 가리키는 심링크를 커밋하면 통과
if is_within(target_repo, real(candidate)): reject()
# 안전: 리터럴 경로와 realpath 둘 다 검사
def within_target(target_repo, candidate):
    return is_within(target_repo, literal(candidate)) or is_within(target_repo, real(candidate))
```

**contract 반영 없이는 complete 실패(계약 3)** — 실측:
```
$ workbench_glue.py complete --scan-id <id>   # draft가 잘못된 targetId를 씀
{"ok": false, "reason": "scan.target.targetId: must match the workbench target"}
```

**커버리지 정산은 집합 기반이어야 부풀리기 불가(계약 5)**:
```python
# reviewed_count >= in_scope_count 같은 카운트 비교는 중복 리뷰로 우회됨
unreviewed = [k for k in in_scope if k not in (log.reviewed & set(in_scope))]  # 집합 멤버십
```

검증 근거: `docs/verification/phase0-results.md` ~ `phase4-results.md`(각 Phase 실측 보고서),
`docs/verification/phase4-deep-lite-pipeline.md`(랭킹 계약).
