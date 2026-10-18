# Phase 4 U2 — deep-lite 파이프라인 실측

**목적**: deep-lite 스킬(`skills/codex-security-deep-scan/SKILL.md`)이 부르는 상류 스크립트·헬퍼의
입출력 계약을 실측으로 고정한다. 합성 저장소(Git, 20파일)에서 결정론 구간을 실행한다.

## npm 0.4.0 재실측 (2026-10-17)

**설치본**: npm 0.4.0 격리 설치(`/tmp/cs040-g`, 매니페스트 0.1.95), 비교용 npm 0.2.0 격리 설치(`/tmp/cs020-g`).
`CODEX_SECURITY_STATE_DIR`는 임시 경로. 부트스트랩은 `bootstrap.py --target-repo <repo> --require-search
--no-scan-dir`(둘 다 exit 0, `candidateNormalizer.kind=node-helper`). Python 스크립트는
`env -i <trustedChildEnv> PATH=<searchCommand.pathEnv> <python>`, Node 헬퍼는
`env -i <trustedChildEnv> CODEX_MCP_NODE_PATH=<node> <launcher> --helper <name>`로 불렀다.

합성 저장소: `app/*.py` 6, `web/*.js` 5, `lib/*.go` 3, `lib/x.tf`, `docs/a.txt`·`docs/b.toml`,
`README.md`, `.gitignore`(`build/` 무시), `bin/blob.bin`(NUL 포함), 무시된 `build/out.js`.

### 바뀐 상류 계약

| 항목 | npm 0.2.0 | npm 0.4.0 | 근거 |
|---|---|---|---|
| 랭킹 Python 서브커맨드 8종(`make-repo-rank-input`·`make-rank-shards`·`make-rank-pool-plan`·`validate-rank-shard`·`validate-rank-worker`·`validate-rank-pool`·`merge-rank-outputs`·`select-deep-review-input`) | 있음 | **없음** — `invalid choice`, exit 2 | `f894583a3`(#1607). 0.3.0에서는 `make-repo-rank-input`만 Python에 남고 나머지는 Node 헬퍼로 옮겨졌다(#839·#841·#842) |
| 같은 이름의 Node 헬퍼 | 없음 | **없음** — 헬퍼 사용법 출력, exit 2 | `rank-pool.ts`·`rank-shards.ts` 삭제 |
| `bind-repo-scopes` | Python 서브커맨드 | **Node 헬퍼만**(인자 같음: `--scopes-file --manifest --coverage`). Python은 exit 2 | #843(0.3.0) |
| `copy-deep-review-input` | Python 서브커맨드 | **Node 헬퍼만**. 입력 행이 정확히 `{path, area, preview}`여야 함 | #839(0.3.0) |
| `make-repo-scope-input` | 있음 | 있음. 출력 행 `{path}`만 | — |
| `rank_preview.TEXT_CODE_EXTENSIONS` | 있음 | **없음**(0.3.0부터). 공개 상수는 `DEFAULT_PREVIEW_BYTES`·`DEFAULT_PREVIEW_READ_BYTES`·`PREVIEW_HEAD_LINES`·`PREVIEW_SAMPLE_LINES`뿐 | #1347 |
| 공식 deep 방식 | 코디네이터 랭킹 → 후보 발굴 | **독립 표준 스캔 반복 + 집계** | `skills/deep-security-scan/SKILL.md` |
| `coverage.completeness` | 있음 | 봉인 전 coverage에서 finalizer가 지움 | `c380befb9`(#1633), `finalize_scan_contract.py` |
| `mode=deep` 종결 가드(`deep_scan_runs` 요구) | 있음 | 있음 | `deep_scan_workbench.py:207` |

상류 `security-scan/references/scan-artifacts-and-ledger.md`(0.4.0)는 랭킹 헬퍼를 "legacy ranking
helpers have been removed"로 적고, 명시 스코프에는 `make-repo-scope-input`, diff에는
`make-diff-rank-input`·`copy-deep-review-input`만 남긴다.

### 결론 — deep-lite 파이프라인 교체

랭킹·샤딩·병합·선택을 대신할 상류 경로는 없다. 상류도 공식 deep에서 랭킹을 버리고 전 범위 표준 스캔을
반복한다. 그래서 deep-lite는 랭킹을 빼고 **인벤토리 전체를 독립적으로 2회 리뷰**한 뒤, 상류 정규화기로
두 패스 후보를 합친다. 랭킹·상위 % 선택을 이 저장소에서 다시 구현하지 않는다.

| 단계 | 명령 | 0.4.0 실측 | 0.2.0 실측 |
|---|---|---|---|
| 1. 인벤토리 | `generate_in_scope_files.py --repo <root> --scope <root> --out <disc>/in_scope_files.txt` | exit 0, `Recorded 20 in-scope files.` 20행(`./` 접두사, `bin/blob.bin` 포함, 무시된 `build/out.js` 제외) | 같음 |
| (참고) | `generate_rank_input.py make-repo-scope-input --repo <root> --scopes-file ["."] --out …` | exit 0, 20행 `{path}`. 1번과 같은 경로 집합(`./` 차이만) | 같음 |
| (참고) | `--helper copy-deep-review-input --rank-input <scope 출력> --out …` | **exit 1**, `missing fields ["area","preview"]` | Node 헬퍼 없음, exit 2 |
| 2. 패스 1·2 리뷰 | (LLM — 가짜 raw 후보로 대체) `raw/pass1-agent-1.jsonl` 2행, `raw/pass2-agent-1.jsonl` 2행. 그중 1행은 `cwe_ids`·`locations`가 패스 1과 같음 | — | — |
| 3. 단일 원장 | `--helper normalize-candidates --input raw/pass1-agent-1.jsonl raw/pass2-agent-1.jsonl --out <disc>/candidate_ledger.jsonl --repo-root <root> --in-scope-files <disc>/in_scope_files.txt` | exit 0, `Combined 4 candidate rows into 3 rows`. 겹친 행은 `summary`·`evidence`가 줄바꿈으로 합쳐짐(`candidate-8a2116c965facfbf`) | 같음(같은 `candidate_id` 3개) |
| 4. 스코프 결합(하위 경로 스캔만) | `--helper bind-repo-scopes --scopes-file ["app"] --manifest … --coverage …` | exit 0, `Bound 1 requested scopes`, manifest·coverage `includePaths=["app"]` | Node 헬퍼 없음(exit 2) → Python `generate_rank_input.py bind-repo-scopes` 사용 |

정규화기의 병합 키는 `cwe_ids`·`locations`·`instance`의 정확 일치다(`normalize-candidates.ts`
`createCandidateNormalizer`). 표현만 다른 같은 근본 원인은 합쳐지지 않는다.

5단계 이후(validation → attack-path → canonical JSON → `coverage_reconcile.py` → finalize → complete)는
Phase 1·2 계약이며 이 문서의 범위 밖이다.

## npm 0.1.x~0.2.0 기록 (역사 — 0.4.0에서 무효)

아래는 2026-07-30 실측한 옛 랭킹 파이프라인 계약이다. npm 0.4.0에는 이 서브커맨드가 없다.

| 단계 | 명령 | 실측 계약 |
|---|---|---|
| 1 | `make-repo-rank-input --repo <root> --out rank_input.jsonl` | 저장소 파일 1행/파일(20파일→20행) |
| 2 | `make-rank-shards --rank-input rank_input.jsonl --out-dir <dir> --max-rows 150` | 기본 150행/샤드. `--max-rows 8`로 20행→3샤드 |
| 3 | `make-rank-pool-plan --shard-dir <rank_shards> --usable-worker-slots N --out rank_worker_assignments.json` | 샤드 디렉터리는 `rank_shards`로 명명하고 계획 파일의 형제여야 함 |
| 4 | (랭킹 팬아웃) | 출력 행 `{path, area, score, include, reason}`, `score`는 1~10 정수, 입력 path 1:1 |
| 5 | `validate-rank-shard` / `validate-rank-worker` | 통과 시 `RANK_WORKER_RECEIPT {…status:complete}` |
| 6 | `merge-rank-outputs` | 출력 샤드 누락 시 exit 1(부분 병합 불가) |
| 7 | `select-deep-review-input --top-percent 20` | score 상위 %만 선택(20행→4행) |
