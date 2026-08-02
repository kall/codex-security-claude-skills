---
name: codex-security-diff-scan
description: >-
  변경분(diff)만 보안 스캔한다. --diff BASE [--head HEAD](커밋/브랜치 refs) 또는
  --working-tree [--base REF](스테이지+미스테이지 로컬 패치)를 대상으로, 위협 모델은
  저장소 전체 범위에서, 리뷰는 diff 범위에서 수행하고 봉인된 계약 산출물을 만든다.
  OpenAI/Codex 인증 없이 Claude Code 구독만으로 동작. 전체 저장소 스캔은
  codex-security-scan을 쓴다.
---

# codex-security-diff-scan — 변경분 스캔

codex-security 플러그인의 `security-diff-scan` 스킬을 Claude가 직접 수행한다. Phase 1의
전체 스캔 스킬(codex-security-scan/SKILL.md)의 공통 규칙(bootstrap, R6 금지 필드, 정산,
리페어 루프)과 Phase 2의 워크벤치 수명주기를 **그대로 참조**하며, 차이점(대상 해석·diff 인벤토리·
범위 규칙)만 아래에 정의한다.

## 대상 해석 (R8)

| 인자 | target.kind | base / head |
| --- | --- | --- |
| `--diff BASE [--head HEAD]` | `refs` | base=BASE, head=HEAD(기본 현재 HEAD) |
| `--working-tree [--base REF]` | `working_tree` | base=REF(기본 HEAD), head=워킹트리 |
| (인자 없음) | `working_tree` | base=HEAD |

## 0단계 — 부트스트랩·등록·contract (Phase 1·2 준수)

1. `bootstrap.py --target-repo <저장소 루트>`로 pluginRoot·python·scanDir을 얻는다(Phase 1 0단계).
2. **워크벤치 등록(Phase 2)**: `workbench_glue.py register`의 recipe에 `mode`는 diff에 맞게,
   `target.kind`를 `refs`/`working_tree`로, base/head를 **문자열로** 채운다(R10). 이어서
   `contract`로 좌표(targetId/revision/coverage.mode 기대값)를 확정하고 `feedback`를 주입한다.
   순서·finalize-first·complete 실패 3선택지 분기는 Phase 2 SKILL.md와 동일하다.
3. **시작 고지 강화(R11)**: working-tree 스캔은 **등록 시점의 워킹트리 다이제스트가 기준**이므로
   스캔 중 파일 저장 한 번으로 complete-scan이 실패한다. "스캔이 끝날 때까지 저장소를 건드리지
   마세요(짧은 diff일수록 빨리 끝납니다)"를 refs 스캔보다 강하게 안내한다.

## 5단계 선형 워크플로 (R9 — 각 단계 완료 전 다음 플러그인 스킬 읽기 금지)

`<plugin_dir>/skills/security-diff-scan/SKILL.md`를 **읽고** 순서를 따른다.

1. **위협 모델 — 저장소 전체 범위**: `skills/threat-model/SKILL.md` 절차. diff 범위가 아니라
   저장소 수준 위협 모델을 만든다(무관한 diff에도 유효하도록).
2. **Discovery — diff 범위**: 인벤토리를 diff-rank-input으로 생성한다.
   ```bash
   # refs (커밋/브랜치)
   <python> <plugin_dir>/scripts/generate_rank_input.py make-diff-rank-input --repo <repo_root> --base <base> --mode revisions --head <head> --out <scan_dir>/artifacts/02_discovery/rank_input.jsonl
   # working-tree (로컬 패치)
   <python> <plugin_dir>/scripts/generate_rank_input.py make-diff-rank-input --repo <repo_root> --base <base> --mode local-patch --out <scan_dir>/artifacts/02_discovery/rank_input.jsonl
   ```
   이어서 리뷰 입력을 파생한다(필수 호출):
   ```bash
   <python> <plugin_dir>/scripts/generate_rank_input.py copy-deep-review-input --rank-input <scan_dir>/artifacts/02_discovery/rank_input.jsonl --out <scan_dir>/artifacts/02_discovery/deep_review_input.jsonl
   ```
   변경된 source-like 파일만 리뷰한다. 후보는 `normalize_candidates.py`로 단일 원장에 병합한다
   (Phase 1과 동일).
3. **Validation (compact)** — Phase 1과 동일.
4. **Attack Path (compact)** — Phase 1과 동일.
5. **Canonical JSON** — Phase 1의 순서 있는 결과 매핑 적용. `coverage.mode`는 kind별 기대값
   (refs → `branch_diff`, working_tree → `working_tree`)을 따르되, 실제 기대값은 **Phase 2 contract
   조회 결과가 권위**다. finalizer가 덮어쓰는 R6 금지 필드는 작성하지 않는다.

## 완료 (Phase 1·2 준수)

`bind-repo-scopes`(필요 시) → `coverage_reconcile.py`(정산 R9 + 경로 검사 R10) → `finalize_scan_contract.py`
(리페어 루프 R12) → `workbench_glue.py complete`(게이트 실패 3선택지 분기). Phase 1·2 SKILL.md의
해당 절차를 그대로 따른다.

## 범위 이탈 가시화

정산 단계에서 diff에 없는 파일의 finding이 나오면 경고한다(리뷰는 diff 범위인데 finding이 범위를
벗어나면 조사 대상). coverage_reconcile.py의 경로 검사가 존재/이탈을 잡고, diff 범위 이탈은 요약에 남긴다.

## 실패 안내

- **shallow clone에서 base 해석 실패**: `git fetch --unshallow` 또는 필요한 base를 fetch하라는 한국어
  안내로 종료한다.
- **detached HEAD**: working-tree 스캔은 정상 등록된다(HEAD를 base로 사용).

## 하드 규칙

Phase 1 SKILL.md의 하드 규칙(R6 금지 필드, R7 저장소 불변, R11 미신뢰 데이터, 단일 원장,
파괴적 명령 금지)을 그대로 적용한다.
