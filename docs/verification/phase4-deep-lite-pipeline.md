# Phase 4 U2 — deep-lite 랭킹 파이프라인 실측

**목적**: `generate_rank_input.py`의 랭킹·샤딩·병합·선택 서브커맨드 입출력 계약을 실측으로 고정해
U3(deep-lite 스킬)가 그대로 인용하게 한다. 합성 저장소(20파일)에서 전 구간 실행.

## 호출 순서와 실측 계약

| 단계 | 명령 | 산출물 | 실측 계약 |
|---|---|---|---|
| 1 | `make-repo-rank-input --repo <root> --out rank_input.jsonl` | `rank_input.jsonl` | 저장소 파일 1행/파일(20파일→20행). 각 행에 `path`·미리보기 등 |
| 2 | `make-rank-shards --rank-input rank_input.jsonl --out-dir <dir> --max-rows 150` | `rank-shard-NNNN.input.jsonl` | 기본 150행/샤드. `--max-rows 8`로 20행→3샤드 |
| 3 | `make-rank-pool-plan --shard-dir <rank_shards> --usable-worker-slots N --out rank_worker_assignments.json` | 배정 계획 | **샤드 디렉터리는 반드시 `rank_shards`로 명명되고 계획 파일의 형제여야 함**. round_robin 배정, `{workers:[{slot,input_shards,output_shards}], ranking_worker_count, shard_count}` |
| 4 | (랭킹 팬아웃) 각 input 샤드 → `.output.jsonl` | `rank-shard-NNNN.output.jsonl` | 출력 행 = `{path, area, score, include, reason}`. **`score`는 1~10 정수**(0-100 아님). 입력 path를 **1:1 빠짐없이** 덮어야 함 |
| 5 | `validate-rank-shard --input <in> --output <out>` / `validate-rank-worker --plan <plan> --shard-dir <rank_shards> --slot <n>` | 검증 | score 범위·path 커버리지 검증. 통과 시 `RANK_WORKER_RECEIPT {…outputs_sha256, rows, status:complete}` |
| 6 | `merge-rank-outputs --rank-input rank_input.jsonl --shard-dir <rank_shards> --out rank_output.jsonl` | `rank_output.jsonl` | 전량 성공 시 병합(20행). **부분 실패 불허**: 출력 샤드 하나라도 없으면 `"Rank shard outputs are incomplete: missing output shards [...]"` + **exit 1** |
| 7 | `select-deep-review-input --rank-output rank_output.jsonl --out deep_review_input.jsonl --top-percent 20` | `deep_review_input.jsonl` | score 상위 %만 선택(20행 중 top 20%=4행, 고score mod1/mod2 포함) |

## 랭킹 팬아웃 vs 리뷰 팬아웃 경계 (R7·KTD5)

- **랭킹 팬아웃(4단계)**: 출력은 **랭킹 행**(`{path,area,score,include,reason}`), 입력 path 1:1 덮기 필수,
  **전량 성공 필수**(6단계 merge가 부분 실패 거부, exit 1). 실패 샤드는 재시도(R8).
- **리뷰 팬아웃**: 랭킹 후 `select-deep-review-input`이 고른 파일에 대해 별도 수행. 출력은 **후보**
  (raw candidate 행), **부분 실패 허용**(커버리지 `partial`로 반영). `normalize_candidates.py`로 단일 원장 병합.
- 두 팬아웃의 출력 스키마·실패 정책이 다르므로 하나로 묶으면 안 된다.

## U3가 인용할 실패 조건
- 샤드 dir 이름이 `rank_shards`가 아니면 pool-plan 거부.
- score가 1~10 밖이면 validate-rank-shard 거부(`score must be from 1 through 10`).
- 출력 샤드 누락 시 merge exit 1(부분 병합 불가) → 랭킹 워커 재시도, 3회 실패 시 스캔 중단(R8).
