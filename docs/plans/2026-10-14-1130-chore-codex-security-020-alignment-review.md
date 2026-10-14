---
title: codex-security npm 0.2.0 대응 검토 — 전제 확인과 수정 범위
type: chore
date: 2026-10-14
status: review (실측 완료, 구현 전)
---

# codex-security npm 0.2.0 대응 검토

상류 `openai/codex-security` 태그 `npm-v0.2.0`(커밋 `4949af70f`, 2026-10-06)에 맞춰 이 저장소의 스킬 9종을
정합하기 전에, 개발환경 전제와 실제로 깨지는 지점을 먼저 확인한 기록이다. 기준선은 npm 0.1.32
(매니페스트 0.1.95)다. 이 문서는 검토 결과이며 코드는 아직 바꾸지 않았다.

## 1. 결론 요약

- **매니페스트 버전은 그대로 0.1.95다.** npm 0.1.26~0.2.0이 전부 같은 매니페스트라서 부트스트랩의
  버전 경고로는 0.2.0을 구분할 수 없다. 버전이 아니라 **파일 존재 프로브**로 경로를 골라야 한다.
- 실제로 깨지는 지점은 **셋**이다.
  1. `scripts/normalize_candidates.py` 삭제 → Node 헬퍼 `--helper normalize-candidates`로 이동(#837).
     전체·diff·deep 스캔 스킬의 후보 원장 병합 명령이 "파일 없음"으로 실패한다.
  2. 위협 모델 저장 방식 변경(#1133, breaking으로 표기). 우리 스캔 스킬은 `scan.threatModel`을 쓰지
     않고 `artifacts/01_context/threat_model.md`만 쓴다. 0.2.0에서는 그 레이아웃으로는 `threatmodel.md`도
     생기지 않고 `export --artifact threat-model`도 "No saved threat model"로 실패한다(실측).
  3. `codex-security-policy` 스킬의 상류 리터럴·파일 이름 드리프트. `THREAT_MODEL.md` → `threatmodel.md`,
     policy 단계 프롬프트 한 문장 변경, 매니페스트에 `status`·`threatModel` 필드 추가. `repro-u8` P7·P11이
     0.2.0에서 실패한다(실측).
- 나머지 자기채점 스크립트(`repro-u4`, `u1`, `u7`)와 관측형 `repro-u3`은 0.2.0에서 **그대로 통과**한다.
  봉인 계약·인벤토리·신뢰 게이트·커버리지 복구·워크벤치 종결 순서는 바뀌지 않았다.
- `repro-u5` Q2b 실패 1건은 **기준선 0.1.29에서도 똑같이 실패**한다. 0.2.0과 무관한 기존 문제다(§6).

## 2. 개발환경 전제 (2026-10-14 실측)

| 항목 | 상태 | 비고 |
| --- | --- | --- |
| 상류 clone | `/data/workspace/codex-security` (main `296abe731`, fetch 완료) | `npm-v0.2.0` 태그 존재. `npm-v0.1.32`의 직계 후손(128 커밋, 604 파일 변경) |
| npm 레지스트리 | **0.2.0 배포됨** | 0.1.32와 달리 태그 소스 빌드가 필요 없다(릴리즈 절차 7.1 불필요) |
| 사용자 전역 설치본 | `@openai/codex-security@0.1.29` | 기준선(0.1.32)보다도 낮다. 검증은 임시 prefix로 했다(아래) |
| 검증용 설치본 | `/tmp/cs020-g` (`npm install -g --prefix`) | 전역 설치본은 건드리지 않았다. 부트스트랩이 `npm root -g`를 정화된 환경에서 돌리므로 `NPM_CONFIG_PREFIX`만으로는 못 바꾼다. PATH 앞에 `npm` 래퍼(`--prefix` 고정)를 두어야 0.2.0을 채택한다 |
| Node | v22.23.2 | 0.2.0 engines `^22.13.0 \|\| ^24 \|\| ^26` 충족. 0.1.32와 같다 |
| Python | 3.14.8 (mise), 3.12.13도 있음 | 상류 하한 3.10(+tomli). 0.2.0 스크립트가 3.14에서 전부 동작했다 |
| ripgrep | Claude Code 내장 심링크(`search-shim/rg`) | 변화 없음 |
| 워크벤치 DB | `~/.codex/state/plugins/codex-security/workbench.sqlite3` (0.1.29로 만든 것) | 0.2.0은 마이그레이션이 늘었다(스키마 모듈 357줄 변경). 0.2.0으로 한 번 열면 **되돌리기 보장이 없다**. 전역을 0.2.0으로 올리기 전에 상태 디렉터리를 백업한다 |
| `install.sh --check` | 0.2.0에서 exit 0, "경고 사본"으로 판별 | `require_unchanged_target` 심볼은 0.2.0에도 없다. 게이트 판별 로직은 그대로 유효 |

## 3. 상류 0.2.0 변경 중 우리에게 닿는 것

### 3.1 깨지는 변경 (필수 대응)

**A. 후보 정규화가 Python에서 Node 헬퍼로 이동 (#837)**

- 삭제: `scripts/normalize_candidates.py`, `tests/test_normalize_candidates.py`, `plugin-files.json` 항목.
- 대체: `<plugin_dir>/scripts/launch_codex_security_mcp --helper normalize-candidates --input … --out … --repo-root … --in-scope-files … [--allow-missing-in-scope]`. 인자는 같다.
- 실측: 같은 입력에 대해 0.1.29 Python 출력과 0.2.0 Node 출력이 **바이트 단위로 같았다**(단일 행
  픽스처). 상류 커밋은 "JS 파싱·정렬, 네이티브 경로 해석, LF/CRLF 인벤토리, 콘솔 진단"의 차이를
  문서화된 호환 변화로 받아들였다고 적었다. 다중 행·CRLF·비ASCII 경로에서는 재실측이 필요하다.
- 영향: 헬퍼는 **신뢰 Node**가 필요하다. 상류 소스 체크아웃(`mcp/` 빌드 없음)에서는 후보 정규화 자체가
  불가능해진다. 이미 SECURITY.md 해결과 policy·classify-severity가 npm 설치본을 요구하므로, 요구사항
  표현을 "스캔도 npm 설치본 필요"로 올려야 한다.
- 런처도 바뀌었다. `--helper` 인자를 단일 argv 대신 **fd 3 heredoc**으로 넘긴다. `env -i` + 정화 PATH로
  돌리는 우리 호출은 `repro-u1`(resolve-security-md 블록)에서 그대로 통과했다.

**B. 위협 모델을 결과와 함께 저장 (#1133, 상류가 `!`로 표기)**

- 스키마: `scan.threatModel`이 `anyOf`가 됐다. 기존 구조형 `{summary, assets, …}` 또는 새
  `{format: "markdown", content, scope?, origin?}`. 둘 다 finalizer가 받는다(실측).
- finalizer: 봉인 뒤 `<scan_dir>/threatmodel.md`를 **호스트가 생성**한다(artifacts 목록에는 넣지 않음).
  `--describe-threat-model`, `--export-artifact threat-model`, `--write-threat-model` 옵션이 생겼다.
  CLI는 `codex-security export <결과 디렉터리> --artifact threat-model --output -`로 **인증 없이** 내보낸다(실측).
- 레거시: `artifacts/01_context/threat_model.md`는 봉인 스캔에서 **artifacts에 기록된 경우에만** 읽는다.
  우리 스캔 스킬은 그 파일을 artifacts에 기록하지 않으므로(finalizer가 `findings.json`·`coverage.json`만
  기록) 0.2.0에서는 모델이 "없는" 스캔이 된다.
- 상류 스킬 문서는 이제 모델을 만들자마자 `complete: false` 체크포인트에 `threatModel`을 싣고, 터미널
  경로에서는 "이른 부분 unsealed draft"에 넣으라고 쓴다. `references/final-report.md`는 마크다운 모델을
  `{ "format": "markdown", "content" }`로, 공급된 텍스트는 `origin: "provided"`, 생성 텍스트는
  `origin: "generated"`로 적으라고 쓴다.
- 워크벤치: `get-scan`에 `threatModelAvailable`, `scan_result`에 `threatModelPath`·`artifacts.threatModel`이
  추가됐다. 우리 글루는 이 키를 읽지 않으므로 깨지지 않는다.

**C. SECURITY.md 초안(security-policy.ts) 변경**

- 단계 파일 `THREAT_MODEL.md` → `threatmodel.md`. 이 파일은 이제 `writeThreatModel`(finalizer
  `--write-threat-model`)이 매니페스트의 `threatModel`에서 **투영**해 만든다. 투영이 실패하면
  경고만 내고 `threatModelPath: null`을 돌려준다.
- 매니페스트 `policy-draft.json`이 **threat_model 단계 직후에도** 저장된다. 새 필드 `status`
  (`threat_model_ready` / `blocked` / `completed`)와 `threatModel`
  (`{format: "markdown", content, scope: {includePaths: [scope], excludePaths: []}, origin: "generated"}`).
- policy 단계 프롬프트 첫 문장이 바뀌었다.
  `Read the completed specification at <spec> and threat model at <path>.` →
  `Read the completed specification at <spec> and the retained threatModel.content in <policy-draft.json>.`
- `SecurityPolicyPreflight`가 `ScanModelConfiguration`을 상속(`model`·`reasoningEffort` 필드 유지).
  `reasoningEffort`는 임의 문자열 허용(#1237).
- 실측: `repro-u8` P7(리터럴 46조각 중 1 누락: ` and threat model at `), P11(세 단계 프롬프트 문자 단위
  대조 실패)만 실패. S 블록(심각도 재분류)은 전부 통과.

### 3.2 깨지지 않지만 문서·검증을 손봐야 하는 변경

| 변경 | 상류 PR | 우리 쪽 영향 |
| --- | --- | --- |
| `coverage.resolvedDeferred` 추가(저장된 유예 작업 종결) | #1036 | 우리는 쓰지 않는다. `coverage_reconcile.py`는 모르는 키를 거부하지 않는다(u7 통과). 문서에 "쓰지 않음"을 적는다 |
| 인벤토리 글롭 `!.git/**` → `!**/.git`+`!**/.git/**`, 중복 제거, 임시 파일명 단축 | #1099 #1077 #1214 | u4 통과. 스캔 문서의 인벤토리 규칙 서술에 "중첩 Git 메타데이터 제외" 추가 |
| 인벤토리 확장자 추가(`.hh` `.hxx`, EJS/ERB/PHTML, Vyper) | #1079 #1197 #1306 | u4 I 블록은 통과하지만 새 확장자 대조군은 없다. I 블록에 한 커밋 추가 권장 |
| 소스 내 노출 자격증명 탐지 지시(`core-scan.md` "Secrets Exposed in Source") | #1134 | 우리 스캔 스킬은 상류 `core-scan.md`를 읽게 하므로 자동 반영. 다만 우리 validate 스킬의 "공격자 제어 입력 필요" 기준과 충돌할 수 있다 → validate 문서에 "소스 열람 경로" 예외를 명시 |
| finalizer: `--sarif-only`가 `write_export_output` 경로로 통합, SARIF 자체 검증 제거, CSV 선행 `'` 보존 | #1247 등 | 우리는 `--sarif-only`를 쓰지 않는다. u4 SARIF 단언 통과 |
| finalizer 스키마 오류 문구: `threatModel`이 `anyOf`라 `no schema alternative matched: …`로 바뀜 | #1133 | 스캔 스킬 리페어 루프 표(현재 `expected schema type object`) 갱신 |
| finalizer가 `threatmodel.md` 투영 실패 시 stderr에 `codex-security: warning: Automatic threat model save failed` 를 내고 exit 0 | #1133 | 리페어 루프는 exit≠0에만 반응하므로 영향 없음. 최종 보고에 경고 전달 |
| 워크벤치 `connect(deferred=…)`, 읽기 명령은 writer 승인 대기 안 함 | #1272 | u3·u7 통과. 글루 변경 불필요 |
| 워크벤치 `complete-scan`: 부모 초안 병합 시 `preserve_parent_head_on_error` | #1036 | 우리는 봉인 뒤 종결하므로 병합 경로를 타지 않는다(u3 S4~S9 통과) |
| `scan-comparison.ts` 리팩터(`Map.groupBy`, Cyber access 전달) | #1185 #1143 | `comparisonPrompt()` 판정 문장 **변화 없음**(0.2.0 dist 문자열 대조 완료). u5 R·S·U 블록 통과 |
| `cli.ts` 패치 검증 프롬프트 블록 | — | 0.2.0 `dist/cli.js`에 두 줄 모두 그대로 있다(대조 완료) |
| `classify-severity.ts` 지시문 | — | u8 S12 대조 통과 |
| CLI 도움말 재구성, `--model`/`--effort`를 patch·validate·verify-fix·match에 공통 적용 | #1143 #1238 #1274 | 매뉴얼의 "이 스킬이 감싸지 않는 CLI" 절에 반영 |
| Daybreak/Bedrock/Cyber access 문구 | #1185 #1188 | 우리 경로와 무관(인증 없음). 상류 스킬 문서를 읽는 에이전트가 "건너뛰라"는 지시를 그대로 따르면 된다 |
| 진단 문구의 자격증명 마스킹 제거(`safeErrorMessage` → `errorMessage`) | #1179 | 우리 최종 보고에 상류 stderr를 그대로 실을 때 민감값이 섞일 수 있다. 보고 지침에 주의 문구 추가 |

### 3.3 영향 없음

`generate_rank_input.py`(리팩터만), `workbench_target.py`(`git_submodule_paths` 제거 — 우리는 안 씀),
`validate_scan_contract.py`(변화 없음), `scan-manifest.schema.json`의 포매팅 변경, 상류 테스트의
TypeScript 이관, `triage-finding/evals` 삭제, 의존성 범프.

## 4. 스킬별 수정 목록 (우선순위 순)

### 4.1 `codex-security-scan` (필수)

1. **후보 정규화 명령을 프로브로 선택한다.** `bootstrap.py`가 `scripts/normalize_candidates.py` 존재와
   Node 헬퍼 가용성(`securityMdHelper`와 같은 게이트)을 보고 `candidateNormalizer: {"kind": "python"|"node-helper", …}`
   를 내보낸다. SKILL.md 2단계는 그 값으로 명령을 고른다. 0.1.32 이하와 0.2.0을 모두 지원한다.
   Node 헬퍼도 `env -i <trusted_child_env> CODEX_MCP_NODE_PATH=<node>`로 돌린다(SECURITY.md 헬퍼와 동일 계약).
2. **`scan.threatModel`을 정본에 싣는다.** 1단계에서 만든 마크다운을 draft `scan-manifest.json`에
   `{ "format": "markdown", "content": "<전문>", "origin": "generated" }`로 넣는다. 사용자가 모델을 공급했으면
   `origin: "provided"`, 구조형 객체를 공급했으면 그대로 보존. `artifacts/01_context/threat_model.md`는
   계속 쓰되 "사람이 읽는 복사본"으로 격하하고, 0.2.0에서는 finalizer가 만든 `<scan_dir>/threatmodel.md`를
   최종 보고에 함께 적는다.
3. 리페어 루프 표의 `threatModel` 오류 문구를 0.2.0 문구로 갱신하고, 두 형식 모두 설명한다.
4. 버전 서술: "npm 0.1.26~0.2.0은 모두 매니페스트 0.1.95"로 구간을 늘린다. 기준 실측 버전을 npm 0.2.0으로.
5. 인벤토리 규칙 서술에 중첩 `.git` 제외와 새 확장자를 추가한다.
6. 최종 보고에 `threatmodel.md` 경로와 `export --artifact threat-model` 안내를 추가한다.

### 4.2 `codex-security-diff-scan`, `codex-security-deep-scan`, `codex-security-validate` (필수)

- `normalize_candidates.py` 언급을 모두 프로브 기반 명령으로 바꾼다(diff: `--allow-missing-in-scope` 유지).
- diff 스캔도 저장소 범위 모델을 `scan.threatModel`(markdown 형식)에 싣는다. 상류 diff 스킬은
  "변경 파일 범위로 대체하지 말고 모델의 실제 범위를 `scope`에 적으라"고 쓴다 → `scope.includePaths: ["."]`.
- validate: 소스 노출 자격증명 finding은 "공격자 제어 입력 없음"만으로 `not_applicable` 처리하지 않도록
  상류 "Secrets Exposed in Source" 기준을 인용한다.

### 4.3 `codex-security-policy` (필수)

1. `STAGE_FILES.threat_model`을 `threatmodel.md`로, 매뉴얼·SKILL 표도 같이.
2. `UPSTREAM_POLICY_HEAD` 첫 문장을 0.2.0 원문으로 교체하고 자리표시자를 `manifestPath`로 바꾼다.
3. 매니페스트에 `status`와 `threatModel`을 추가하고, threat_model 단계 저장 시점에도 매니페스트를 쓴다
   (`status: "threat_model_ready"`, blocked면 `"blocked"`, 완료 시 `"completed"`). `reviewNotes`의
   중간 합집합 순서(architecture.reviewNotes → architecture.questions → tm.reviewNotes → tm.questions)도 상류와 맞춘다.
4. `threatmodel.md`는 직접 쓰지 않고 상류와 같이 finalizer `--write-threat-model`로 투영한다. 실패하면
   `threatModelPath: null`과 경고. 우리 결과 JSON의 `threatModelPath`도 nullable로.
5. 복사 시점 커밋을 `npm-v0.2.0` = `4949af70f…`로 갱신. `repro-u8` P7·P11이 통과해야 완료.

### 4.4 문서·검증·배포 (필수)

- README 두 개, `docs/install-and-usage.md`: 검증 조합을 npm 0.2.0으로. 요구사항에 "스캔의 후보 정규화도
  npm 설치본(Node 헬퍼) 필요"를 추가. 산출물 트리에 `threatmodel.md`. 무인증 CLI 표에
  `export <dir> --artifact threat-model`. 3.4절 사본 표에 0.2.0 행 추가.
- `docs/releasing.md` 7절: 리터럴 재대조 기록을 0.2.0으로. 7.1절은 "0.2.0은 레지스트리에 있다"로 각주.
- 검증 스크립트: `repro-u4`에 (a) `scan.threatModel` 두 형식의 봉인 + `threatmodel.md` 생성 + export 대조,
  (b) 레거시 레이아웃에서 "No saved threat model" 재현, (c) Node 헬퍼 정규화가 Python 결과와 같은지
  다중 행·CRLF 픽스처 대조. `repro-u8`은 4.3 반영 후 재실행.
- 아키텍처 러닝 문서 계약 10(artifact-storage 비적용)에 "threatModel은 정본 JSON 필드로 싣는다 — 이것은
  MCP 저장 정책이 아니라 스키마 계약이므로 따른다"를 추가.
- 배포 태그 `v0.2.0`(npm 축). 릴리즈 노트는 "0.1.32 이후 누적 변경"으로 서술.

### 4.5 권장 (선택)

- `bootstrap.py`가 npm 패키지 `package.json`의 `version`을 `npmVersion`으로 함께 보고한다. 매니페스트
  축으로 구분이 안 되는 구간이 다섯 릴리즈째라, 시작 고지에 npm 축을 같이 보여 주는 편이 정직하다.
- `codex-security-scan-match` 문서의 "출처 고정" 커밋을 0.2.0으로 재대조 표기(문장은 같다).

## 5. 범위 밖

- Cyber access 프로그램, Bedrock 인증, Daybreak 고지 — 모델 호출 경로이므로 우리 경로에 없다.
- 상류 `evals/`·테스트 이관, 의존성 범프.
- Deep 스캔 재개·재실행, GitLab MR 생성(0.1.29 계획과 같은 제외).

## 6. 기존 문제 (0.2.0과 무관, 별도 처리)

`repro-u5-match-validator.sh` Q2b가 Python 3.14와 3.12, 플러그인 0.1.29와 0.2.0 네 조합 모두에서 실패한다.
픽스처(깊게 중첩된 행)가 `repr` 재귀 오류에 도달하지 못하고 그 전에 "문자열 occurrenceId 없음"으로
거부된다. Python 3.12부터 C 재귀 한도가 바뀌어 픽스처 깊이가 모자란 것으로 보인다. 단언이 공허해진
상태이므로 픽스처 깊이를 올리거나 단언 방식을 바꿔야 한다. `v0.1.32` 검증 기록에는 통과로 적혀 있으니
당시 Python 버전을 확인한다.

## 7. 실측 로그

- 설치: `/tmp/cs020-g`(전역 prefix), `/tmp/cs020-npm`(로컬). npm 래퍼 `/tmp/cs020-bin/npm`.
- 결과: u4 exit 0, u1 exit 0, u7 exit 0, u5 exit 1(Q2b만), u8 exit 1(P7·P11만), u3 S5 exit 0(경고 사본).
- 위협 모델 3형식 finalize 실측: `/tmp/cs020-run/tm/{structured,markdown,legacy}`.
- Node 정규화 대조: `/tmp/cs020-run/norm/ledger.jsonl` == `ledger29.jsonl`.
