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

**상류 저장 정책(`references/artifact-storage.md`)은 적용하지 않는다(P6-KTD8).** 근거와 범위는 Phase 1
SKILL.md의 prompt-only 절이 정본이다. 이 스킬이 읽는 `skills/threat-model/SKILL.md`·
`skills/validation/SKILL.md`·`skills/attack-path-analysis/SKILL.md`가 그 정책을 가리켜도 멈추지 않고
터미널 정본 경로를 계속한다.

## 대상 해석 (R8)

| 인자 | target.kind | base / head |
| --- | --- | --- |
| `--diff BASE [--head HEAD]` | `refs` | base=BASE, head=HEAD(기본 현재 HEAD) |
| `--working-tree [--base REF]` | `working_tree` | base=REF(기본 HEAD), head=워킹트리 |
| (인자 없음) | `working_tree` | base=HEAD |

## 0단계 — 부트스트랩·등록·contract (Phase 1·2 준수)

1. `bootstrap.py --target-repo <저장소 루트>`로 pluginRoot·python·scanDir을 얻는다(Phase 1 0단계).
2. **워크벤치 등록(Phase 2)**: `workbench_glue.py register`에 diff 대상을 인자로 준다(R10).
   ```bash
   # refs (커밋/브랜치)
   python3 <codex-security-scan 스킬 dir>/scripts/workbench_glue.py --bootstrap <bootstrap JSON 파일> register --mode diff --diff-target refs --base <base> --head <head>
   # working-tree (head 는 현재 HEAD 여야 한다 — 생략하면 HEAD)
   python3 <codex-security-scan 스킬 dir>/scripts/workbench_glue.py --bootstrap <bootstrap JSON 파일> register --mode diff --diff-target working_tree --base <base>
   ```
   글루는 레시피 `mode`를 `standard`로 두고 `target.kind`(`refs`/`working_tree`)와 base/head를 **문자열로**
   싣는다. 상류가 레시피 `mode`로 `standard`·`deep`만 받고, target 종류에서 diff 모드를 유도하기
   때문이다. 이 글루 수정 전에는 diff 등록이 `Scan launch recipe mode must be standard or deep.`로
   항상 실패했다(npm 0.1.22부터, `repro-u7` I17·I17e). 이어서 `contract`로 좌표를 확정하고 `feedback`를
   주입한다. 순서·finalize-first·complete 실패 3선택지 분기는 Phase 2 SKILL.md와 동일하다.

   **contract → draft `scan.target` 매핑(diff).** `contract.diffTarget`은 글루가 get-scan에서 옮긴 값이다.

   | contract 필드 | draft 반영 위치 |
   | --- | --- |
   | `target.allowedKinds[0]`(=`git_diff`) | `scan.target.kind` |
   | `target.targetId`·`target.displayName` | 같은 이름으로 그대로 복사 |
   | `diffTarget.baseRevision`·`diffTarget.headRevision` | `scan.target.baseRevision`·`headRevision`(해석된 커밋 SHA) |
   | `diffTarget.snapshotDigest` | `scan.target.snapshotDigest` |
   | `diffTarget.kind` | `coverage.mode` — `range` → `branch_diff`, `commit` → `commit`, `working_tree` → `working_tree` |

   `snapshotDigest`는 글루가 상류 규칙으로 계산한다. working_tree는 등록 시점 `contentDigest`다. 커밋 diff는
   `sha256("codex-security-diff/v1\0<kind>\0<base>\0<head>")`이고, 상류 `workbench_target.committed_diff_snapshot_digest()`와
   같다. npm 0.1.32부터 워크벤치가 커밋 diff digest를 종결 시점에 직접 계산한다(상류 `8c78e655`). 이미
   봉인한 매니페스트는 기록된 값을 유지하므로 우리 경로(봉인 뒤 `complete`)는 두 버전에서 모두 통과한다.
   같은 값을 쓰면 공식 CLI가 만든 같은 diff 스캔과 digest가 일치한다(`repro-u7` I17c).
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
   diff 범위 인벤토리(`in_scope_files.txt`)도 **플러그인 스크립트로** 만든다. Phase 1의 `rg --files`
   전체 목록을 쓰면 안 된다(범위가 저장소 전체가 된다):
   ```bash
   # refs
   env -i <trusted_child_env> <python> <plugin_dir>/scripts/generate_in_scope_files.py --repo <repo_root> --scope . --diff-base <base> --diff-head <head> --diff-mode revisions --out <scan_dir>/artifacts/02_discovery/in_scope_files.txt
   # working-tree
   env -i <trusted_child_env> <python> <plugin_dir>/scripts/generate_in_scope_files.py --repo <repo_root> --scope . --diff-base <base> --diff-mode local-patch --out <scan_dir>/artifacts/02_discovery/in_scope_files.txt
   ```

   > **셸에 보간하는 모든 값은 인용본을 쓴다** — `<trusted_child_env>` =
   > `trustedChildEnvShell`, 나머지 경로는 `shellQuoted.*`(`repoRoot`·`scanDir`·
   > `pluginRoot`·`pythonPath`·`trustedPathEnv`). 이중인용은 `$()`를 막지 못하고 이
   > 값들의 출처는 미신뢰 환경이다(실측으로 `mkdir -p "<scan_dir>/…"`와
   > `PATH="<pathEnv>"` 둘 다 명령 치환이 실행됐다). 그리고 **인용본을 다시 `"…"`로
   > 감싸지 말 것** — 그러면 단일인용이 리터럴이 되고 `$()`는 그대로 확장돼 인용이
   > 무효가 된다(실측). 위 명령형처럼 자리표시자는 맨몸으로 쓴다. 정본 근거는
   > Phase 1 SKILL.md 2단계.
   `RIPGREP_CONFIG_PATH=`는 **diff 경로에서는 실효가 없다** — diff 모드는 `git`만 쓰고 `rg`를
   타지 않는다(실측: 오염된 설정에서도, PATH에 `rg`가 아예 없어도 결과가 같다). 전체 스캔
   인벤토리 호출과 형태를 맞춰 두는 방어 조치이며, 근거는 Phase 1 SKILL.md 2단계가 정본이다.

   `<trusted_path_env>` = bootstrap이 반환한 **`trustedPathEnv`**(대상 저장소 내부 항목을 제거한
   PATH). **PATH를 이 값으로 교체한다 — `$PATH`를 이어 붙이지 않는다.** diff 모드는 ripgrep을
   쓰지 않으므로 `--require-search`는 붙이지 않지만, `committed_changed_paths`가 **`git`을 PATH에서
   해석해 `cwd=대상 저장소`로 실행**하므로 정화된 PATH가 필요하다. 원시 `$PATH`를 물려주면 대상
   저장소가 커밋한 `./node_modules/.bin/git`이 실행된다(실측). 전체 스캔과 같은 이유이며 정본
   서술은 Phase 1 SKILL.md 2단계에 있다(P5-KTD2).

   **diff 인벤토리에 들어가는 파일(npm 0.1.32 기준).** diff 인벤토리와 diff 랭킹 입력은 같은 규칙을
   쓴다(`repro-u4.sh` I 블록).
   - 확장자는 `rank_preview.TEXT_CODE_EXTENSIONS`로 거른다. npm 0.1.27~0.1.29에서 `.cjs`·`.cts`·
     `.mts`·`.tf`가, npm 0.1.31에서 `.m`이, npm 0.1.32에서 `.sol`·`.svelte`가 추가됐다. 이 확장자 목록은 diff 인벤토리와 랭킹 입력(diff·저장소 모두)에만 쓰인다. 전체 스캔
     인벤토리는 확장자 필터가 없는 `rg --files`라 0.1.25에서도 이 파일들을 포함했다.
   - `.github/workflows/*` 변경은 제외 규칙(`path_is_diff_excluded`)에서 빠져 인벤토리에 남는다.
     `.github`의 다른 파일(예: `dependabot.yml`)은 여전히 제외된다.
   - diff에 이름에 `\n`·`\r`이 든 경로가 있으면 인벤토리가
     `Git changes contain a path that cannot fit in the file inventory`로 실패한다. 이 동작은
     0.1.25에도 있었다. 그 경로는 Phase 1 SKILL.md 2단계의 탐색 명령(`<스코프>`는 `.`)으로 찾아
     사용자에게 보여 준다. 이름을 바꾸기 전에는 이 diff를 스캔할 수 없다.

   변경된 source-like 파일만 리뷰한다. 후보는 `normalize_candidates.py`로 단일 원장에 병합하되
   (Phase 1과 동일), **diff 스캔은 `--allow-missing-in-scope`를 반드시 붙인다**:
   ```bash
   <python> <plugin_dir>/scripts/normalize_candidates.py --input <raw1.jsonl> [...] --out <scan_dir>/artifacts/02_discovery/candidate_ledger.jsonl --repo-root <repo_root> --in-scope-files <scan_dir>/artifacts/02_discovery/in_scope_files.txt --allow-missing-in-scope
   ```
   diff 인벤토리에는 **삭제된 경로**가 포함되며(예: `git rm` 된 파일), 이 플래그가 없으면
   `in-scope file row N: No such file or directory`로 정규화가 실패한다(실측). 플래그를 붙여도
   후보 location 파일의 실존 검사는 그대로 수행된다.

   **삭제된 파일에 대한 finding 처리**: head 시점에 존재하지 않는 경로만 `locations`에 갖는
   finding은 `coverage_reconcile.py`가 거부한다("소스 루트 하위에 존재하지 않습니다" — 플러그인
   finalizer 자체는 통과시키지만 우리 정산 게이트가 더 엄격하다, 실측). 그런 후보는 finding 대신
   `coverage.deferred`(또는 `not_applicable` 서피스)로 기록하고 삭제 사실을 사유에 적는다.
   review_log에는 base 시점에서 읽었음을 남긴다.
3. **Validation (compact)** — Phase 1과 동일.
4. **Attack Path (compact)** — Phase 1과 동일.
5. **Canonical JSON** — Phase 1의 순서 있는 결과 매핑 적용. `coverage.mode`는 kind별 기대값
   (refs → `branch_diff`, working_tree → `working_tree`)을 따르되, 실제 기대값은 **Phase 2 contract
   조회 결과가 권위**다. finalizer가 덮어쓰는 R6 금지 필드는 작성하지 않는다.

## 완료 (Phase 1·2 준수)

`bind-repo-scopes`(필요 시) → `coverage_reconcile.py`(정산 R9 + 경로 검사 R10) → `finalize_scan_contract.py`
(리페어 루프 R12) → `workbench_glue.py complete`(게이트 실패 3선택지 분기). Phase 1·2 SKILL.md의
해당 절차를 그대로 따른다.

- **정산은 `--json`과 함께 호출한다** — 최종 보고가 `coverage.completenessAfter`·`deferredCount`·
  `partialWithoutDeferred` 키를 인용한다. `--json`이면 JSON은 stdout, 사람용 요약은 stderr로 나간다.
- **빈 인벤토리**: diff 범위에 리뷰 대상 파일이 없는 것(문서만 바뀐 커밋 등)은 diff 스캔에서
  정직한 상태다. 그 경우에만 `--allow-empty-inventory`를 붙인다 — 통과시켜도 경고는 남는다.
  인벤토리 생성 자체가 실패해서 비었을 가능성이 있으면 붙이지 말고 상류 스크립트의 종료 상태를
  먼저 확인한다.
- **중단된 스캔의 복구**: 계약 오류로 상류가 스캔을 자동 `failed` 종결시킨 경우
  `workbench_glue.py recover --scan-id <id>`를 시도할 수 있다. 판정 규칙은 Phase 1 SKILL.md
  6단계가 정본이다 — exit 0 + `ok:false`면 이 명령의 대상이 아니고, `failureKind`가 `infra`면
  전제 문제가 아니라 실행 환경 문제다.

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
