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
터미널 정본 경로를 계속한다. npm 0.4.0 `skills/security-diff-scan/SKILL.md`는 터미널 절차를 지우고
MCP가 없으면 "report the blocker; do not author canonical files through a shell"이라고 썼다. npm 0.7.0은
같은 취지를 "report the blocker without creating a replacement scan or shell-authored canonical files"로
고쳐 쓴다. 이 문장도 같은 근거로 적용하지 않는다. 0.7.0에서도 diff 인벤토리 도우미(Node 헬퍼)·
finalizer·`complete-scan`은 이 경로를 받아들인다(`repro-u4.sh` I 블록, `repro-u7` I17).

## 대상 해석 (R8)

| 인자 | target.kind | base / head |
| --- | --- | --- |
| `--diff BASE [--head HEAD]` | `refs` | base=BASE, head=HEAD(기본 현재 HEAD) |
| `--working-tree [--base REF]` | `working_tree` | base=REF(기본 HEAD), head=워킹트리 |
| (인자 없음) | `working_tree` | base=HEAD |

## 0단계 — 부트스트랩·등록·contract (Phase 1·2 준수)

1. `bootstrap.py --target-repo <저장소 루트>`로 pluginRoot·python·scanDir을 얻는다(Phase 1 0단계).
   Phase 1 0단계의 **후보 정규화 확인**을 그대로 적용한다 — `candidateNormalizer.available`이 `false`면
   중단한다(npm 0.2.0 이후 소스 체크아웃 등). `copyDeepReviewInput`·`diffRankInput`·`inScopeInventory` 중
   하나라도 `available`이 `false`여도 중단한다(2단계의 필수 호출을 할 수 없다). 사유는 각 객체의 `reason`에 있다.
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
   항상 실패했다(글루를 처음 만든 때부터, `repro-u7` I17·I17e). 이어서 `contract`로 좌표를 확정하고 `feedback`를
   주입한다. 순서·finalize-first·complete 실패 3선택지 분기는 Phase 2 SKILL.md와 동일하다.

   **contract → draft `scan.target` 매핑(diff).** `contract.diffTarget`은 글루가 get-scan에서 옮긴 값이다.

   | contract 필드 | draft 반영 위치 |
   | --- | --- |
   | `target.allowedKinds[0]`(=`git_diff`) | `scan.target.kind` |
   | `target.targetId`·`target.displayName` | 같은 이름으로 그대로 복사 |
   | `diffTarget.baseRevision`·`diffTarget.headRevision` | `scan.target.baseRevision`·`headRevision`(해석된 커밋 SHA) |
   | `diffTarget.snapshotDigest` | `scan.target.snapshotDigest` |
   | `scope.requiredIncludePaths`(배열이면 그대로) / `null`이면 `[requestedPath]`(diff는 `requestedPath: "."` → `["."]`) | `scan.scope.includePaths`, `coverage.includePaths`(두 곳에 같은 값) |
   | `diffTarget.kind` | `coverage.mode` — `range` → `branch_diff`, `commit` → `commit`, `working_tree` → `working_tree` |
   | (diff 종류와 무관) | `coverage.inventoryStrategy` = `diff`. 상류 스키마 enum은 `repository \| scoped_path \| diff \| directory \| custom`이다. `git_diff`를 쓰면 finalize가 `coverage.schema.inventoryStrategy: unsupported value 'git_diff'`로 거부한다(2026-10-20 0.5.0 스모크) |

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
   저장소 수준 위협 모델을 만든다(무관한 diff에도 유효하도록). 5단계에서 이 모델을 정본
   `scan.threatModel`에 싣는다(Phase 1 5단계 "정본 위협 모델" 표). `scope.includePaths`는 **모델의
   범위**인 `["."]`이며 변경 파일 목록으로 바꾸지 않는다(상류 `skills/security-diff-scan/SKILL.md` 1항).
2. **Discovery — diff 범위**: 인벤토리를 diff-rank-input으로 생성한다. 0단계 `diffRankInput.kind`로
   명령을 고른다. 인자는 두 경로가 같다(npm 0.7.0이 Python 스크립트를 지우고 Node 헬퍼로 옮겼다,
   상류 05cceee24 #1432).
   ```bash
   # kind = python (npm 0.6.0 이하) — refs (커밋/브랜치)
   env -i <trusted_child_env> <python_command> <plugin_dir>/scripts/generate_rank_input.py make-diff-rank-input --repo <repo_root> --base <base> --mode revisions --head <head> --out <scan_dir>/artifacts/02_discovery/rank_input.jsonl
   # kind = python — working-tree (로컬 패치)
   env -i <trusted_child_env> <python_command> <plugin_dir>/scripts/generate_rank_input.py make-diff-rank-input --repo <repo_root> --base <base> --mode local-patch --out <scan_dir>/artifacts/02_discovery/rank_input.jsonl
   # kind = node-helper (npm 0.7.0) — refs
   env -i <trusted_child_env> CODEX_MCP_NODE_PATH=<node> <security_md_launcher> --helper make-diff-rank-input --repo <repo_root> --base <base> --mode revisions --head <head> --out <scan_dir>/artifacts/02_discovery/rank_input.jsonl
   # kind = node-helper — working-tree
   env -i <trusted_child_env> CODEX_MCP_NODE_PATH=<node> <security_md_launcher> --helper make-diff-rank-input --repo <repo_root> --base <base> --mode local-patch --out <scan_dir>/artifacts/02_discovery/rank_input.jsonl
   ```
   이어서 리뷰 입력을 파생한다(필수 호출). 0단계 `copyDeepReviewInput.kind`로 명령을 고른다. 인자는 같다.
   ```bash
   # kind = python (npm 0.2.0 이하)
   env -i <trusted_child_env> <python_command> <plugin_dir>/scripts/generate_rank_input.py copy-deep-review-input --rank-input <scan_dir>/artifacts/02_discovery/rank_input.jsonl --out <scan_dir>/artifacts/02_discovery/deep_review_input.jsonl
   # kind = node-helper (npm 0.3.0 이후 — Python 하위 명령은 지워졌다, 상류 #839)
   env -i <trusted_child_env> CODEX_MCP_NODE_PATH=<node> <security_md_launcher> --helper copy-deep-review-input --rank-input <scan_dir>/artifacts/02_discovery/rank_input.jsonl --out <scan_dir>/artifacts/02_discovery/deep_review_input.jsonl
   ```
   Node 헬퍼는 `make-diff-rank-input`이 만든 행(`path`·`area`·`preview`)을 그대로 받는다. 행을 손으로
   만들거나 고치지 않는다. 두 경로 모두 랭킹 입력의 모든 행을 같은 순서로 옮긴다(`repro-u4.sh` L2).
   이 두 단계(`make-diff-rank-input` → `copy-deep-review-input`)의 상류 서술은 npm 0.7.0
   `skills/security-scan/references/scan-artifacts-and-ledger.md`의 "Changed-file Worklist" 절이다("Standalone Diff
   Worklists and Artifacts" — 레거시 diff 경로 전용으로 다시 쓰였다). 그 절의 MCP 저장 도구 지시는 P6-KTD8에 따라
   적용하지 않는다.
   diff 범위 인벤토리(`in_scope_files.txt`)도 **상류 인벤토리 도우미로** 만든다. 0단계 `inScopeInventory.kind`로
   명령을 고른다. Phase 1의 `rg --files` 전체 목록을 쓰면 안 된다(범위가 저장소 전체가 된다):
   ```bash
   # kind = python (npm 0.6.0 이하) — refs
   env -i <trusted_child_env> <python_command> <plugin_dir>/scripts/generate_in_scope_files.py --repo <repo_root> --scope . --diff-base <base> --diff-head <head> --diff-mode revisions --out <scan_dir>/artifacts/02_discovery/in_scope_files.txt
   # kind = python — working-tree
   env -i <trusted_child_env> <python_command> <plugin_dir>/scripts/generate_in_scope_files.py --repo <repo_root> --scope . --diff-base <base> --diff-mode local-patch --out <scan_dir>/artifacts/02_discovery/in_scope_files.txt
   # kind = node-helper (npm 0.7.0) — refs
   env -i <trusted_child_env> CODEX_MCP_NODE_PATH=<node> <security_md_launcher> --helper generate-in-scope-files --repo <repo_root> --scope . --diff-base <base> --diff-head <head> --diff-mode revisions --out <scan_dir>/artifacts/02_discovery/in_scope_files.txt
   # kind = node-helper — working-tree
   env -i <trusted_child_env> CODEX_MCP_NODE_PATH=<node> <security_md_launcher> --helper generate-in-scope-files --repo <repo_root> --scope . --diff-base <base> --diff-mode local-patch --out <scan_dir>/artifacts/02_discovery/in_scope_files.txt
   ```
   Node 헬퍼의 런처·`env -i`·`CODEX_MCP_NODE_PATH`는 Phase 1 SKILL.md 0단계 3번과 같다(P6-KTD6). 두 경로의
   출력 집합은 같다(`repro-u4.sh` I 블록, 0.6.0·0.7.0 실측). 성공 출력은 인벤토리가 `Recorded N in-scope files.`,
   랭킹 입력이 `Wrote N rows to <경로>`다.

   > **셸에 보간하는 모든 값은 인용본을 쓴다** — `<trusted_child_env>` =
   > `trustedChildEnvShell`, 나머지 경로는 `shellQuoted.*`(`repoRoot`·`scanDir`·
   > `pluginRoot`·`pythonPath`·`trustedPathEnv`). 이중인용은 `$()`를 막지 못하고 이
   > 값들의 출처는 미신뢰 환경이다(실측으로 `mkdir -p "<scan_dir>/…"`와
   > `PATH="<pathEnv>"` 둘 다 명령 치환이 실행됐다). 그리고 **인용본을 다시 `"…"`로
   > 감싸지 말 것** — 그러면 단일인용이 리터럴이 되고 `$()`는 그대로 확장돼 인용이
   > 무효가 된다(실측). 위 명령형처럼 자리표시자는 맨몸으로 쓴다. 정본 근거는
   > Phase 1 SKILL.md 2단계.
   `RIPGREP_CONFIG_PATH=`는 **diff 경로에서는 실효가 없다** — diff 모드는 `git`만 쓰고 `rg`를
   타지 않는다(실측: 오염된 설정에서도, PATH에 `rg`가 아예 없어도 결과가 같다. npm 0.7.0 Node 헬퍼도
   diff 경로에서는 `git diff`·`git ls-files`만 부른다). 전체 스캔
   인벤토리 호출과 형태를 맞춰 두는 방어 조치이며, 근거는 Phase 1 SKILL.md 2단계가 정본이다.

   **PATH는 `<trusted_child_env>` 안에 이미 있다.** `trustedChildEnvShell`의 `PATH`는 bootstrap의
   **`trustedPathEnv`**(대상 저장소 내부 항목을 제거한 PATH)이고 `PYTHONDONTWRITEBYTECODE=1`도 들어 있다.
   그래서 위 diff 명령형에는 `PATH=`를 따로 붙이지 않는다. `$PATH`를 이어 붙이거나 `env -i` 밖에서 호출하지
   않는다. diff 모드는 ripgrep을 쓰지 않으므로 `--require-search`는 붙이지 않지만, diff 인벤토리와 랭킹
   입력이 **`git`을 PATH에서 해석해 `cwd=대상 저장소`로 실행**하므로 정화된 PATH가 필요하다. 원시 `$PATH`를 물려주면 대상
   저장소가 커밋한 `./node_modules/.bin/git`이 실행된다(실측). 전체 스캔과 같은 이유이며 정본
   서술은 Phase 1 SKILL.md 2단계에 있다(P5-KTD2).

   **diff 인벤토리에 들어가는 파일(npm 0.4.0~0.7.0).** diff 인벤토리와 diff 랭킹 입력은 같은 규칙을
   쓴다(`repro-u4.sh` I 블록).
   - **바이너리가 아닌 변경 파일 전부**다. 파일 이름·확장자·디렉터리로 거르지 않는다(상류
     `skills/security-diff-scan/SKILL.md`: "changed text files regardless of filename, extension, or
     directory"). 그래서 `.github/dependabot.yml`·`notes.txt`도 들어간다. 바이너리 판정은 내용(NUL 바이트)
     으로 하므로 `.py` 확장자라도 바이너리면 빠진다(`repro-u4.sh` I17~I20). 삭제된 파일은 base 쪽 내용으로
     판정해 들어간다. 커밋 diff는 head 커밋의 blob으로, 로컬 패치는 워킹트리 파일로 판정하고 심링크는
     뺀다. npm 0.5.1부터는 `.git`·`.svn` 아래 경로도 뺀다(#1552). 로컬 패치의 변경이 `.svn` 아래뿐이면
     인벤토리가 비고 "빈 인벤토리" 분기로 간다.
   - 이전 규칙(npm 0.2.0 이하): 확장자를 `rank_preview.TEXT_CODE_EXTENSIONS`로 거르고(0.2.0에서
     `.hh`·`.hxx`·`.ejs`·`.erb`·`.phtml`·`.vy`까지), `.github`는 `workflows/*`만 남겼다. 이 집합과 제외
     규칙은 npm 0.3.0(#1347)에서 지워졌다. 같은 diff라도 0.2.0과 0.4.0의 커버리지 분모가 다르다.
   - 상류는 경로가 아니라 동작과 도달성으로 보안 관련성을 판단하라고 쓴다(빌드·배포·CI 사용 포함).
     목록에 든 문서·설정 파일도 리뷰 대상이며, 보안과 무관하면 리뷰 로그에 `reviewed`로 남긴다.
   - diff에 이름에 `\n`·`\r`이 든 경로가 있으면 인벤토리가
     `Git changes contain a path that cannot fit in the file inventory`로 실패한다. 이 동작은
     0.1.25에도 있었다. 그 경로는 Phase 1 SKILL.md 2단계의 탐색 명령(`<스코프>`는 `.`)으로 찾아
     사용자에게 보여 준다. 이름을 바꾸기 전에는 이 diff를 스캔할 수 없다.

   인벤토리의 변경 파일만 리뷰한다. 후보는 Phase 1 2단계 5번의 정규화 명령(`candidateNormalizer.kind`로
   고름)으로 단일 원장에 병합하되, **diff 스캔은 `--allow-missing-in-scope`를 반드시 붙인다**. 두 경로 모두
   이 인자를 받는다:
   ```bash
   # kind = python (npm 0.1.32 이하)
   PYTHONDONTWRITEBYTECODE=1 <python_command> <plugin_dir>/scripts/normalize_candidates.py --input <raw1.jsonl> [...] --out <scan_dir>/artifacts/02_discovery/candidate_ledger.jsonl --repo-root <repo_root> --in-scope-files <scan_dir>/artifacts/02_discovery/in_scope_files.txt --allow-missing-in-scope
   # kind = node-helper (npm 0.2.0부터)
   env -i <trusted_child_env> CODEX_MCP_NODE_PATH=<node> <security_md_launcher> --helper normalize-candidates --input <raw1.jsonl> [...] --out <scan_dir>/artifacts/02_discovery/candidate_ledger.jsonl --repo-root <repo_root> --in-scope-files <scan_dir>/artifacts/02_discovery/in_scope_files.txt --allow-missing-in-scope
   ```
   diff 인벤토리에는 **삭제된 경로**가 포함되며(예: `git rm` 된 파일), 이 플래그가 없으면
   정규화가 exit 2로 실패한다(실측). 문구는 npm 0.1.32 이하 Python이 `in-scope file row N: [Errno 2] No such file or directory: '<경로>'`, npm 0.2.0 Node 헬퍼가 `in-scope file row N: ENOENT: no such file or directory, realpath '<경로>'`다(npm 0.4.0·0.7.0도 같다). 플래그를 붙여도
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
   조회 결과가 권위**다. finalizer가 덮어쓰는 R6 금지 필드는 작성하지 않는다. `scan.threatModel`은
   1단계 모델로 Phase 1 5단계 "정본 위협 모델" 표대로 싣는다(`threatModelMarkdown`이 `false`면 생략).

## 완료 (Phase 1·2 준수)

`bind-repo-scopes`(필요 시) → `coverage_reconcile.py`(정산 R9 + 경로 검사 R10) → `finalize_scan_contract.py`
(리페어 루프 R12) → `workbench_glue.py complete`(게이트 실패 3선택지 분기). Phase 1·2 SKILL.md의
해당 절차를 그대로 따른다.

- **`bind-repo-scopes`가 필요하면** Phase 1 6단계의 `bindRepoScopes.kind`·`coverageArg` 분기를 따른다. npm 0.3.0부터
  `generate_rank_input.py bind-repo-scopes`가 없다(Node 헬퍼로 이동). npm 0.8.0 헬퍼는 `--coverage`를 받지 않는다(상류 #1762).
- **커버리지 완결성**: `coverage.completeness`는 Phase 1 5단계 규칙(`coverageCompleteness`)을 따른다.
  npm 0.3.0부터는 쓰지 않고, 남은 작업은 `deferred`와 `needs_follow_up` surface로만 표현한다.
- **정산은 `--json`과 함께 호출한다** — 최종 보고가 `coverage.coverageComplete`·`deferredCount`·
  `needsFollowUpCount`·`partialWithoutDeferred` 키를 인용한다. `--json`이면 JSON은 stdout, 사람용 요약은
  stderr로 나간다.
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
- **루트 커밋(부모 없는 커밋)을 diff 대상으로 지정**: 워크벤치에 등록할 수 없다. 글루 `register`는
  `refs|working_tree`만 받고, 상류 CLI 레시피도 base를 로컬 커밋으로만 받는다(빈 트리나 `<루트>^`를 주면
  `Base revision does not resolve to a local Git commit`). 상류 #1716(npm 0.5.0)의 빈 트리 처리는 MCP
  `commit` 경로에만 적용된다. 저장소 전체 스캔(Phase 1)을 쓰라고 안내하고 종료한다.

## 하드 규칙

Phase 1 SKILL.md의 하드 규칙(R6 금지 필드, R7 저장소 불변, R11 미신뢰 데이터, 단일 원장,
파괴적 명령 금지)을 그대로 적용한다.
