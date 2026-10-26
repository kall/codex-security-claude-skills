---
title: "codex-security 번들 플러그인을 OpenAI 인증 없이 Claude Code 스킬로 실행하기"
date: 2026-07-30
last_updated: 2026-10-27
category: architecture-patterns
module: codex-security-claude-skills
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - "codex-security(또는 유사한 Codex 플러그인)의 스캔 기능을 OpenAI/Codex 인증 없이 쓰고 싶을 때"
  - "번들 플러그인의 결정론 스크립트·헬퍼(finalizer, 워크벤치, 인벤토리·후보 정규화)를 재사용하되 LLM 두뇌만 다른 에이전트로 바꾸고 싶을 때"
  - "임의 저장소에서 실행되는 전역 스킬이 신뢰할 수 있는 플러그인 사본을 선택해야 할 때"
  - "스킬 문서(SKILL.md)의 명령형이 부트스트랩 출력을 셸 명령에 보간할 때 — 계약 9의 문서 절반"
  - "스킬이 미신뢰 입력을 도구 없는/읽기 전용 서브에이전트에 넘기거나, 조립한 큰 프롬프트를 Agent 호출 하나로 보낼 때 — 계약 7"
tags: [codex-security, claude-code-skill, no-auth, security-scan, plugin-architecture, shell-quoting, documentation-contract, regression-test]
---

# codex-security 번들 플러그인을 OpenAI 인증 없이 Claude Code 스킬로 실행하기

> **경로 기준**: 이 문서의 `sdk/typescript/...` 경로는 업스트림
> [openai/codex-security](https://github.com/openai/codex-security) 기준이다(이 저장소에는 업스트림
> 소스를 포함하지 않는다). `skills/...` 경로는 이 저장소 기준이다.

## Context

codex-security의 스캔 기능은 공식적으로 Codex 바이너리(OpenAI 인증)를 통해서만 실행된다. 그러나
저장소를 분석한 결과, **OpenAI 인증이 필요한 지점은 단 하나 — Codex 에이전트 루프(LLM 호출)뿐**이었다.
번들 플러그인(npm 배포본에서는 `_bundled_plugin/`, 상류 소스 트리에서는 `plugins/codex-security/`)의
결정론 계층(워크벤치 SQLite, `finalize_scan_contract.py`,
인벤토리·후보 정규화 헬퍼)은 인증을 전혀 요구하지 않는다. 오히려 `runtime.ts`의 `runWorkbench`는 자식 환경에서
`OPENAI_API_KEY`/`CODEX_API_KEY`를 **제거**한다(`sdk/typescript/src/runtime.ts:132` 부근).

따라서 "SKILL.md를 읽고 따르는 에이전트" 역할을 Claude Code가 대신하면, 나머지 파이프라인(등록 →
스캔 → 산출물 → 검증 → 봉인 → 이력)을 그대로 재사용할 수 있다. 이 러닝은 그 대체를 실제로 구현하며
(Phase 0~4를 구현했고 작성 시점에는 아직 푸시되지 않은 로컬 브랜치에 있다 — 이후 커밋이 재구성돼
초판에 적었던 SHA는 더 이상 해소되지 않으므로 SHA 대신 아래 파일·계약 번호로 되짚는다)
확인한 재사용 가치가 있는 계약들을 고정한다.

## Guidance

**전체 구조**: 전역 Claude Code 스킬(`skills/codex-security-scan/` 등)이 TS SDK/CLI를 **수정하지 않고**
번들 플러그인의 결정론 스크립트를 직접 호출하고, 지능 계층(SKILL.md 워크플로 수행)은 Claude가 담당한다.
결정론 스크립트는 상류 릴리즈마다 Python에서 Node 헬퍼(`scripts/launch_codex_security_mcp --helper …`)로
옮겨 왔다(후보 정규화 npm 0.2.0, 범위 바인딩·diff 입력 0.3.0, 인벤토리 0.7.0). 그래서 스킬은 버전 문자열이
아니라 부트스트랩의 파일 존재 프로브(계약 1-b)로 Python·Node 경로를 고른다. 플러그인 버전은 벤더링하지 않고
런타임에 읽는다.

구현하면서 반드시 지켜야 할 계약(각각은 실패로 학습한 것):

1. **플러그인 루트 신뢰 게이트 — 리터럴 경로와 realpath를 둘 다 검사한다.** 스캔 대상 저장소는
   미신뢰 코드이므로 그 하위(node_modules 포함)의 플러그인 사본을 절대 채택하면 안 된다(KTD4).
   realpath만 검사하면 대상 저장소가 저장소 밖을 가리키는 **심볼릭 링크**를 커밋해 게이트를 우회한다.
   `npm`도 `shutil.which` 대신 신뢰 PATH 머신러리로 해석하고 정화된 env로 실행해야 대상 저장소의
   `./node_modules/.bin/npm`으로 임의 코드가 실행되지 않는다.
   → `skills/codex-security-scan/scripts/bootstrap.py`의 `within_target`, `untrusted_provenance`,
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
   플러그인 매니페스트(`<플러그인 루트>/.codex-plugin/plugin.json`의 `version`)에서 온다.

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
   - **격리는 요청만으로 성립하지 않는다.** Claude Code의 Agent 도구에는 도구 허용 목록 인자가 없다
     (`isolation`은 git worktree 격리다). 내장 유형 Explore·Plan은 Edit·Write만 빼고 Bash·WebFetch를
     남기며, general-purpose는 모든 도구를 가진다. 다만 내장 유형의 도구 구성은 환경에 따라 다르다 — 0.7.0
     스모크 환경의 Explore는 Read만 받아 Glob·Grep으로 파일을 나열하지 못했고, policy 커버리지가 줄었다. 유형
     이름이 아니라 실제 도구 목록을 확인한다. 도구를 실제로 줄이는 방법은 사용자가 설치한 에이전트
     정의(`~/.claude/agents/<name>.md`)의 frontmatter `tools`뿐이다. `tools`를 빼면 모든 도구를 상속한다.
     `tools: []`가 "도구 0개"를 뜻하는지는 검증하지 않았다 — 설치 뒤 `/agents`에서 확인하게 한다.
   - **유형 선택 절차.** (1) Glob으로 정의가 있는지 확인해 있으면 그 유형을 쓴다(스킬은 그 파일을 만들지
     않는다). (2) 없으면 쓰기 도구가 없는 가장 좁은 유형을 쓰고, 도구 금지는 프롬프트 지시로만 성립함을
     최종 보고에 적는다. (3) 실제로 실행한 유형을 최종 보고에 적는다.
   - **부모 대체 경로는 격리의 목적으로 정한다.** 목적이 "Bash·Write를 가진 부모가 미신뢰 텍스트에 따라
     행동하지 않게 하는 것"이면(scan-match 판정, classify-severity 판정, policy 초안) 서브에이전트를 쓸 수
     없을 때 부모가 대신하지 않고 **중단한다**. patch의 사전 조사·후보 리뷰처럼 이미 승인받은 저장소를
     다시 읽는 읽기 전용 검토라면 부모가 별도 패스로 수행해도 된다. 한 스킬의 대체 문장을 다른 스킬에
     복사하기 전에 목적부터 확인한다.
   - **프롬프트 한도는 둘로 나눈다.** 부모는 조립한 프롬프트 전문을 Agent 인자로 **한 응답 안에서 출력**해야
     한다. 그래서 병목은 서브에이전트의 입력 컨텍스트가 아니라 부모 한 응답의 출력 토큰 상한이다. 상류
     동등성 한도(`scan-comparison.ts`의 1,048,576 코드포인트)와 별도로 **실행 한도 80,000자**(기본 출력
     32,000토큰 × 토큰당 2.5자, **실측 전 추정값**)를 두고, min(두 값)을 넘으면 호출 전에 중단한다.
     80,000 초과 1,048,576 이하 구간이 가장 위험하다 — 상류 기준으로는 통과하지만 호출이 도중에 잘려,
     설계한 "중단과 보고" 경로를 타지 않는다. 상류가 입력 한도를 없애면 실행 한도가 유일한 한도가 된다. npm 0.7.0이
     SECURITY.md 1 MiB 한도를 지우자(#1883) policy는 큰 가이던스로 `prepare`를 통과한 뒤 다음 단계에서 멈추고
     출력 디렉터리를 남겼다(스모크 실측). 그래서 실행 한도 검사는 사용자가 산출물을 받기 전 단계(`prepare`)로
     당긴다. 초안은 한도를 524,288자(상류 ÷ 2)로 두었다. 이 값이 부모 한
     응답의 출력 한도를 넘어 호출이 잘릴 수 있어 80,000으로 내렸다.
   → `skills/codex-security-scan-match/SKILL.md`(「프롬프트 한도」·「3단계」·「하드 규칙」),
   `skills/codex-security-scan-match/scripts/validate_matches.py`(`EQUIVALENCE_LIMIT`·`DEFAULT_EXECUTION_LIMIT`),
   `skills/codex-security-scan/scripts/workflow_digest.mjs`(`MAX_PROMPT_CHARACTERS`, policy·classify-severity
   공용), `skills/codex-security-policy/SKILL.md`·`skills/codex-security-classify-severity/SKILL.md`·
   `skills/codex-security-deep-scan/SKILL.md`(유형 선택), `skills/codex-security-patch/SKILL.md`(부모 패스 대조군).

   입력에 워크벤치 DB 파생 사실(대표 ID, 이미 적용된 신원 그룹 등)이 섞이면 신뢰 구획을
   **두 블록으로 분해**하고 경계를 **호출별 난수 표식**으로 구분한다 — 방어 문구를 단일 블록 앞에만
   두면 신뢰 사실까지 데이터로 취급되어 무시되고, 경계가 고정 문자열이면 악성 저장소가 파인딩
   서술 안에 위조된 신뢰 블록을 심을 수 있다. 상류는 npm 0.1.26부터 기확정 그룹(`knownFindingGroups`)을
   판정 제약으로 넘기지 않는다(이 저장소는 0.1.29 정합에서 반영). 호스트가 먼저 카드로 접고, 서브에이전트는 그 그룹이 틀렸다고 보면
   `priorGroupConcerns`로 보고만 한다(저장은 진행).

8. **deep-lite는 상류 랭킹을 흉내 내지 않고, 상류에 남은 결정론 헬퍼만 조합한다.** 초판의 계약은 상류 랭킹
   헬퍼(`make-rank-shards` → pool-plan → `merge-rank-outputs` → `select-deep-review-input`) 위에 섰다: 샤드 디렉터리
   `rank_shards`, 1~10 정수 점수, 부분 실패를 거부하는 병합, 랭킹 팬아웃과 리뷰 팬아웃의 분리. npm 0.4.0이 이 헬퍼를
   모두 지웠고(#1607) 대체 경로도 없다. 공식 deep도 랭킹 대신 독립 표준 스캔을 반복한다. 그래서 deep-lite는 랭킹을
   재구현하지 않고, 인벤토리 전체를 서로 다른 샤드 구성으로 **독립 2패스** 리뷰한 뒤 두 패스의 원시 후보를 상류
   후보 정규화기에 한 번에 넘겨 병합한다. 정규화기는 위치·CWE·인스턴스가 정확히 같은 행만 합치므로, 표현만 다른
   중복은 validation 단계가 정리한다. 비용은 표준 스캔의 약 2배다. 일반화하면: 상류 헬퍼가 사라졌을 때 그 로직을
   이 저장소로 옮기지 말고, 남은 헬퍼로 같은 목적을 이루는 구조를 다시 짠다 — 옮긴 사본은 다음 정합부터 상류와
   어긋난다.
   → `skills/codex-security-deep-scan/SKILL.md`(「인벤토리」·「리뷰 팬아웃 — 고정 2패스」),
   `docs/verification/phase4-deep-lite-pipeline.md`(0.4.0 재실측, 옛 랭킹 계약은 역사 절).

9. **인벤토리는 상류 스크립트에 위임하고 검색 명령에도 신뢰 게이트를 적용한다.** 커버리지 분모
   (`in_scope_files.txt`)를 직접 만들면 상류와 다른 집합이 된다 — `rg`만 부르면 추적 중인 무시 파일이
   빠지고, `git ls-files`로 폴백하면 미추적 파일이 빠진다. 상류 인벤토리 도우미에 위임한다(npm 0.6.0 이하
   `generate_in_scope_files.py`, npm 0.7.0부터 Node 헬퍼 `--helper generate-in-scope-files`, #1432).
   두 도우미 모두 `rg`를 PATH에서만 해석하므로 **PATH에서 찾은 `rg`도 계약 1의 신뢰 게이트를 통과해야
   한다**(대상 저장소가 `./node_modules/.bin`을 얹으면 저장소가 커밋한 `rg`가 채택된다). 해석된 명령은
   **실행해서 ripgrep인지 확인한다** — 상류는 종료코드 0과 1을 모두 정상으로 받으므로 엉뚱한 목록이
   조용히 분모가 될 수 있고, 빈 목록 하드 실패로는 잡히지 않는다. 확보 실패는 격하가 아니라 중단이다.

   플러그인 스크립트는 **정화된 PATH로 교체해** 실행한다(앞에 덧붙이지 않는다). 상류
   인벤토리 도우미는 `rg`뿐 아니라 `git`도 PATH에서 해석하고 `cwd=대상 저장소`로
   실행하므로, 원시 `$PATH`를 물려주면 저장소가 커밋한 `./node_modules/.bin/git`이 사용자 권한으로
   실행된다(합성 저장소로 재현). 정화 후 남는 항목이 없으면 빈 문자열을 내보내지 말고 **중단한다** —
   `PATH=""`로 자식을 띄우면 `git`조차 해석되지 않아 실패 원인이 지시 위반처럼 보인다.

   **정화 대상은 PATH 하나가 아니다.** 상류 인벤토리 도우미는 부모 환경을 전부 상속한다(Python 스크립트는
   `env=`를 넘기지 않고, Node 헬퍼는 `process.env`를 물려준다). `rg`는 `RIPGREP_CONFIG_PATH`가 가리키는 파일의 플래그를 무조건
   적용하므로, PATH만 교체하고 이 변수를 남기면 정화가 반쪽이 된다 — `--glob=!src/**` 한 줄로
   커버리지 분모가 줄어든다. `--glob=!*`면 rg 열거는 0이 되지만 분모에는 add-back 집합
   (추적 AND gitignore된 파일)이 남아 **1개**다 — "통째로 붕괴"가 아니라 "정산이 잡지 못하는
   축소"가 정확한 서술이다(실측). 분모가 진짜 0이 되는 것은 그 집합이 빈 저장소에서뿐이고,
   그때는 정산이 exit 3으로 잡는다. 부트스트랩은 자기 프로브의 자식
   환경에서 이 변수를 비우고, **소비자도 인벤토리 호출에서 함께 비워야 한다**(계약에 포함).

   **환경 교체는 셸 인용까지가 계약이다.** 정화한 환경을 소비자에게 넘기는 순간
   자리표시자 보간이 새 주입 축이 된다. 값의 출처가 미신뢰 환경이기 때문이다
   (`scanDir`·`stateDir`는 `CODEX_SECURITY_STATE_DIR`, `pathEnv`는 PATH 항목의 디렉터리 이름).
   그래서 부트스트랩은 보간되는 **모든** 축의 `shlex.quote` 사본(`shellQuoted.*`,
   `trustedChildEnvShell`)을 함께 낸다. **그리고 소비자 명령형은 그 인용본을 맨몸으로 써야
   한다** — 인용본을 다시 `"…"`로 감싸면 단일인용이 리터럴 문자가 되고 `$()`는 그대로 확장돼
   인용이 무효가 된다(실측: `PATH="<pathEnv>"`·`mkdir -p "<scanDir>/…"` 두 축 모두 실행됐다).
   인용본을 내보내는 것만으로는 계약이 지켜지지 않는다. 이 결함은 **적대적 리뷰 다섯 라운드를
   통과했다**(작업 세션 집계 — 저장소에는 이 횟수의 근거가 남아 있지 않다). 매 라운드가 코드를
   읽었고 어느 라운드도 산문을 읽지 않았다.

   문서 쪽 회귀는 `repro-u1-search-command.sh`의 `H13e`가 SKILL.md를 직접 읽어 고정한다.
   `shellQuoted.*`로 매핑되는 자리표시자가 **이중인용 구간 안에** 놓인 채 명령줄에 나타나면
   실패시키고(자리표시자 앞의 큰따옴표 개수가 홀수인지로 판정한다 — 여는 따옴표 바로 뒤만 보면
   `"… <scan_dir>/x"`처럼 문자열 중간에 오는 형태를 놓친다),
   `>`·`#`로 시작하는 줄은 건너뛴다 — 설명 블록쿼트가 반례로 그 형태를 **일부러** 인용하기
   때문이다. 위험이 실재함은 대조군 `H13c-2`가 따로 단언한다(인용본을 이중인용 안에 넣으면
   명령 치환이 **실제로** 일어나는지를 본다). 그리고 축별 인용 대조(`H13d`)는 원본이 인용을
   필요로 하지 않으면 `shlex.quote(raw) == raw`라 정의상 만족되므로, `H13f`가 공백 담긴 저장소
   경로로 부트스트랩을 다시 돌려 `repoRoot` 축을 실제로 행사한다.

   **남는 검출 공백**: `H13e`가 읽는 것은 이 축을 보간하는 다섯 파일
   (`codex-security-scan`·`-diff-scan`·`-deep-scan`·`-policy`·`-classify-severity`)뿐이고 저장소의
   SKILL.md는 9개다.
   `skills/codex-security-scan-match/SKILL.md`는 같은 축(`<python>`·`<plugin_dir>`)을 명령형에
   보간하는데 회귀망 밖이다(현재는 맨몸이라 무해). 또 `H13e`는 **보간 형태**만 고정할 뿐
   "어느 필드를 가리키는가"라는 산문 지시는 잡지 못한다 —
   `skills/codex-security-diff-scan/SKILL.md`의 `<trusted_path_env>` 설명이 아직 원시
   `trustedPathEnv`를 가리키는데, 그 파일의 명령 블록에 그 자리표시자가 등장하지 않아 지금은
   무해하다. 두 공백 모두 사람 눈에 의존한다.

   **이 실패는 codex-security 고유가 아니다.** 완화가 프로그램과 "그 출력을 쓰는 법을 알려주는
   문서"로 쪼개져 있으면 그 문서는 완화의 일부이고 곧 공격 표면이다. 안전한 값을 내보내는 것은
   완화가 아니다 — 완화는 소비자의 **보간 형태**가 맞을 때 완성되고, 그 형태는 보안 코드와
   똑같이 회귀 테스트 아래에 있어야 한다. 스킬·시스템 프롬프트·툴 설명은 전부 산문으로 쓴
   실행 계약이므로 이 계층은 계속 커진다.

   **`safe.directory` 강제는 저장소의 `.git/config`를 여는 대가를 치른다.** 소유자가 다른
   저장소(컨테이너 바인드 마운트·CI)에서 add-back 집합이 경고 없이 사라지므로 강제가 필요한데,
   `safe.directory`가 막던 것이 정확히 "git이 저장소 자신의 `.git/config`를 신뢰하는가"다.
   환경 config가 저장소 local을 덮으므로 실행 채널을 빈 값으로 함께 못 박는다. 다만
   **고정 키 열거로 닫을 수 없는 클래스가 하나 있다**: `filter.<n>.clean/smudge/process`와
   `diff.<n>.command/textconv`는 **드라이버 이름을 저장소가 커밋한 `.gitattributes`가 정한다**
   (실측: `* filter=pwn diff=pwn`을 커밋하고 `filter.pwn.clean`을 두면 9개 키가 다 얹힌 환경에서도
   `git diff --raw`가 그것을 실행했다). 그래서 `git config --local --includes --list`로 정의된
   드라이버 키를 열거해 함께 무력화한다 — 열거 자체는 어떤 드라이버도 호출하지 않고,
   `--includes`가 없으면 `include.path`로 끌어온 파일의 드라이버가 목록에서 빠진다(실측).
   이 신뢰 환경은 인벤토리만의 것이 아니다. patch·verify-fix의 정적 검증 모드(npm 0.6.0, #1854)는 "저장소 코드를
   실행하지 않는다"를 약속하는데, `git diff --no-ext-diff --no-textconv`만으로는 저장소 로컬 `core.fsmonitor`가
   실행됐다(0.6.0 스모크 실측). 그래서 두 스킬의 git 읽기 명령도 `env -i <trusted_child_env> git -c
   core.fsmonitor=false …` 형태로 고정한다(`skills/codex-security-patch/SKILL.md`의 static 허용 명령).

   **같은 보안 규칙의 두 사본은 반드시 어긋난다.** PATH 정화(`sanitize_pathlist`)와 config
   무력화 목록(`git_config_overrides`)은 `bootstrap.py`에만 두고 `coverage_reconcile.py`는
   import해서 쓴다. 한때 PATH 규칙을 문자열 접두사 비교로 재구현했는데, 그것은 `within_target`이
   세 번의 우회를 겪으며 얻은 성분 접두사 순회와 inode 비교가 없는 더 약한 사본이었다(실측:
   저장소가 `escape -> /tmp`를 커밋하면 정화 PATH의 첫 항목이 `/tmp`가 되어 `/tmp/git`이 실행됐다).
   그리고 **실패 센티넬로 빈 문자열 PATH를 쓰면 안 된다** — `subprocess`는 `os.get_exec_path(env)`를
   쓰고 `"".split(":") == [""]`이므로 `PATH=""`는 "못 찾는다"가 아니라 **"cwd 상대 `git`을 실행한다"**가
   된다(실측: cwd의 `git` 스텁이 rc=0으로 실행됐다). `None`을 돌려 가드를 놓치면 즉시 깨지게 하고,
   포기 사유는 결과에 실어 사람용 출력과 `--json` 양쪽에 남긴다.

   **남는 위험(실측으로 고정)**: 상류는 `rg`에 `--no-config`를 주지 않으므로 대상 저장소가
   `.rgignore`를 커밋하면 그 경로가 rg 열거에서 빠진다. 되살아나는 것은 상류가 add-back 하는
   파일뿐이고, 그 add-back은 `git ls-files --cached --ignored --exclude-standard` — 즉 **추적 AND
   gitignore된** 파일만이다. 따라서 **저장소 대부분을 이루는 추적+비무시 파일은 add-back 대상이
   아니라 그대로 분모에서 빠진다**(실측). 커버리지 분모가 작아지면 "전부 리뷰했다"가 더 쉽게
   성립하므로, 스캔 대상이 자기 채점 기준을 줄이는 통로다. 게다가 상류는 `rg`의 종료코드 0과 1을
   모두 정상으로 받으므로 분모가 통째로 비어도 스캔은 경고 없이 진행된다. 정산이 잡는 것은
   **완전히 빈 분모뿐이고**(`coverage_reconcile.py` exit 3), **비지 않은 축소는 어떤 게이트도
   잡지 못한다** — 정산은 인벤토리를 재생성하지 않고 리뷰 로그와만 대조하므로, 실제 파일 4개
   중 1개로 줄어든 분모에도 `completeness=complete` 로 통과한다(실측). 막을 수단이 없으므로 회귀(`repro-u4.sh` 블록 G3·G4)로 범위를 고정하고,
   상류가 `--no-config`를 주기 시작하면 그 블록이 실패로 알린다.

10. **상류 `artifact-storage.md` 저장 정책은 적용하지 않는다(P6-KTD8).** npm 0.1.28부터 상류 스킬
   문서(`skills/threat-model/SKILL.md`, `skills/validation/SKILL.md`, `skills/fix-finding/SKILL.md`,
   `references/scan-artifacts.md` 등)가 `references/artifact-storage.md`를 읽고 따르라고 지시한다.
   그 정책은 scanId를 MCP로 먼저 받고, 산출물을 `save_codex_security_artifact`로만 저장하고, 셸로 쓴
   정본 파일로 폴백하지 말라고 한다. 따르면 이 저장소의 터미널 정본 경로(셸로 쓴 draft →
   `finalize_scan_contract.py` → 선택적 `complete-scan`)가 막힌다. 근거는 두 가지다. `artifact-storage.md`
   스스로 "Explicit user instructions still take precedence"라고 쓰고, 사용자가 설치해 호출한 스킬의
   지시가 그 명시 지시다. 또 터미널 정본 경로는 npm 0.1.29에서도 finalizer와 `complete-scan`이
   받아들인다(`repro-u3.sh`·`repro-u4.sh` 실측). "MCP 지시는 무시한다"는 한 줄로는 부족하다. 그 정책이
   자기가 "older terminal file-authoring fallbacks"보다 우선한다고 쓰기 때문이다. 그래서 상류 문서를
   읽는 스킬마다 비적용을 명시한다.
   → 정본 서술은 `skills/codex-security-scan/SKILL.md`의 prompt-only 절이다. 같은 문단을
   `codex-security-diff-scan`·`-deep-scan`·`-validate`·`-patch`·`-policy`의 SKILL.md가 참조하거나
   반복한다. 정책 초안 스킬은 서브에이전트 프롬프트에도 이 저장·편집 지시를 따르지 말라고 넣는다.
   **저장 정책 비적용과 스키마 계약은 다르다.** npm 0.2.0은 위협 모델의 정본을 `scan.threatModel` 필드로
   옮겼다(#1133). 이것은 MCP 저장 정책이 아니라 finalizer가 읽는 정본 JSON의 스키마 계약이므로 따른다.
   따르지 않고 `artifacts/01_context/threat_model.md`만 쓰면 봉인은 성공하지만 0.2.0은 그 스캔을 "모델
   없음"으로 본다(`threatmodel.md` 미생성, `export --artifact threat-model` 실패 — `repro-u4.sh` K3).
   자기채점이 녹색이어도 이 결함은 보이지 않았다. 상류 정합 때는 "무시할 저장 지시"와 "정본 JSON에 생긴
   새 필드"를 나눠서 본다. 매니페스트 버전이 같은 구간(npm 0.1.26~0.7.0)이라 형식 선택은 버전이 아니라
   스키마 파일로 판별한다(`bootstrap.py`의 `threatModelMarkdown`).

11. **Node는 `rg`와 같은 신뢰 게이트로 해석하고, 모든 Node 호출은 `env -i`로 환경을 교체한다(P6-KTD6).**
   npm 0.1.27부터 SECURITY.md 리졸버가 Python에서 Node 헬퍼(`scripts/launch_codex_security_mcp --helper
   resolve-security-md`)로 옮겨졌다. 런처는 `CODEX_MCP_NODE_PATH` → `CODEX_BROWSER_USE_NODE_PATH` → PATH의
   `node` 순으로 Node를 고르므로, 대상 저장소가 PATH에 `node_modules/.bin`을 얹으면 저장소가 커밋한 `node`가
   실행된다. 그래서 부트스트랩이 같은 순서의 후보를 계약 1·9의 게이트(리터럴·realpath 둘 다 저장소 밖,
   실행해서 Node인지 확인)로 해석하고, 소비자는 그 경로를 `CODEX_MCP_NODE_PATH`로 넘긴다. 게이트만으로는
   부족하다. `env -i` 없이 부르면 호출 환경의 `NODE_OPTIONS=--require <저장소 JS>`가 신뢰한 Node에 그대로
   적용된다(실측). 그래서 실행 형태를 `env -i <trusted_child_env> <node> <스크립트>` 하나로 고정한다. 이
   저장소의 `.mjs` 스크립트는 셰뱅을 두지 않고(셰뱅 `#!/usr/bin/env node`는 PATH의 첫 `node`를 고른다),
   `NODE_OPTIONS`나 node 실행 옵션이 남아 있으면 실행을 거부한다. 이 거부는 심층 방어다. `--require`는
   이미 실행된 뒤이므로 1차 방어선은 `env -i`다. 헬퍼나 Node가 없어도 부트스트랩은 실패하지 않는다.
   전체 스캔은 정책 해결을 고지와 함께 건너뛰고, 정책 해결이 입력 자체인 `codex-security-policy`는 중단한다.
   → `skills/codex-security-scan/scripts/bootstrap.py`의 `resolve_node`, `probe_node`,
   `resolve_security_md_helper`, `resolve_sdk`, 그리고 `skills/codex-security-scan/scripts/workflow_digest.mjs`
   머리말. 회귀는 `repro-u1-search-command.sh` H14(저장소 안 Node 거부, 문서화한 호출 형태, 거대 SECURITY.md —
   H14g는 npm 0.6.0 이하에서 1 MiB 초과 exit 2, 0.7.0부터 한도 없이 해결로 버전 분기)와
   `repro-u8-policy-severity.sh` P9·S8·S9(`NODE_OPTIONS` 주입 차단, 저장소 `node_modules/.bin/node` 미실행,
   셰뱅 없음)가 고정한다.

12. **상류 dist가 export하는 결정론 함수는 재구현하지 않고 직접 부른다.** npm 번들의 `dist/`는
   `finding-workflow.js`의 `workflowDigest`, `security-policy.js`의 스냅샷·인벤토리 함수,
   `classify-severity.js`·`classify-scan-severity.js`·`severity-store.js`의 분류·저장·읽기 함수를 export한다(phase0-results.md
   0.1.29 부록 4번). 상류는 이 함수들을 모듈 사이로 옮긴다 — 저장 계층은 0.3.0에 Node로, 분류 지시문은 0.5.0에
   `severity-review.js`로 옮겨졌고 0.6.0에 기본 루브릭(`default-severity-rubric.js`)과 독립 리뷰 다수결이 생겼다.
   허용 목록과 드리프트 대조 위치를 정합마다 함께 옮긴다. 재구현하면 JS 키 정렬·`JSON.stringify` 숫자 표기·링크 체인·Git 메타데이터 규칙이
   Python 사본과 조용히 어긋난다. 그래서 부트스트랩이 채택한 패키지의 `dist/`를 허용 목록
   (`UPSTREAM_MODULES`)으로만 import한다. 모델 호출 자리는 상류의 내부 주입점으로 바꾼다. 예를 들어
   `classifySeverityInternal`은 `options.codex`(읽기 전용 Codex 클라이언트)가 있으면 인증·설정·Codex 실행
   파일 해석을 건너뛴다. 스킬은 여기에 **가짜 Codex**를 넣어 상류가 조립한 프롬프트를 받고, 격리
   서브에이전트의 반환을 돌려준다. 그러면 저장·재사용·검증·결과 파일 기록이 상류 코드 그대로 돈다. export되지
   않는 함수(`reconcileComparison`·`validateComparison`·`comparisonPrompt`)는 여전히 이식이 필요하다. 이식본은
   `matchScanFindingsInternal`에 가짜 Codex를 넣어 얻은 상류 결과와 대조한다. 상류 영문 프롬프트를 리터럴로
   고정한 곳은 복사 시점 커밋을 적고, 설치된 dist 문자열과 대조해 드리프트를 잡는다. 상류 소스 체크아웃에는
   `dist/`가 없으므로 이 방식을 쓰는 스킬(`codex-security-policy`·`codex-security-classify-severity`)은 npm
   설치본에서만 동작한다.
   → `skills/codex-security-scan/scripts/workflow_digest.mjs`(공용 관문), `skills/codex-security-policy/scripts/policy_draft.mjs`,
   `skills/codex-security-classify-severity/scripts/classify_severity.mjs`(가짜 Codex 주입과 `UPSTREAM_CLASSIFY_INSTRUCTIONS`
   드리프트 검사), `skills/codex-security-scan-match/scripts/validate_matches.py`(이식본). 회귀는
   `repro-u5-match-validator.sh` 블록 S(가짜 Codex로 돌린 상류 dist 결과 대조)와 `repro-u8-policy-severity.sh`
   P1·P2·P7·P11·S1·S12가 고정한다.

## Why This Matters

이 패턴이 없으면 codex-security는 OpenAI 구독이 있어야만 쓸 수 있다. 결정론 계층이 무인증임을 활용하면
Claude Code 구독만으로 개발자 로컬에서 동일한 봉인 계약 산출물(scan-manifest/findings/coverage +
report.md + SARIF)을 만들고 공식 CLI(`scans list/show`, `findings false-positive`)와 이력 호환된다.

위 13개 계약(1, 1-b, 2~12 — `1-b`가 별 항목이므로 번호 최댓값보다 하나 많다)을 어기면 게이트가 조용히
통과하거나(신뢰 게이트 우회, 빈 커버리지 봉인), complete가 반드시 실패하거나(contract 미반영),
되돌릴 수 없는 이력 손상(자동 fail-scan)이 발생한다.

이 중 **실측 실패를 겪고 나서야 알게 된 것**은 일부다:

- **계약 1(신뢰 게이트)** — realpath만 검사하면 리터럴 경로로 경계를 넘을 수 있다. 합성 저장소로
  재현해 확인했다. 이후 인벤토리를 상류에 위임하면서 **정화되지 않은 `$PATH`로 저장소가 커밋한
  `git`이 실행되는** 경로도 실측 재현으로 발견했다(계약 9).
- **계약 9(셸 인용의 문서 절반)** — 인용본(`shellQuoted.*`)을 정직하게 내보내고 코드에 단언까지
  붙였는데, 소비자 명령형이 그것을 이중인용으로 감싸고 있어 **두 축 모두 그대로 실행됐다**(실측).
  완화가 명목상 존재하는 상태였고, 코드만 읽은 리뷰 라운드가 이것을 거듭 놓쳤다. 사전 독해로
  막을 수 있는 종류가 아니었다 — 코드와 문서를 **함께** 읽어야 보인다.
- **계약 1-b(사본별 능력 프로브)** — 같은 매니페스트 버전을 보고하는 두 사본이 워킹트리 게이트를
  다르게 처리한다는 것은 실측으로만 드러났다(버전 문자열로는 알 수 없다).
- **계약 2(finalize-first)** — `complete-scan`이 binding을 주입하지 않고 검증만 한다는 사실은
  complete가 반복 실패한 뒤에 드러났다.
- **계약 5(집합 기반 정산)** — 건수 비교로는 "다른 파일을 같은 수만큼 리뷰한" 경우를 못 잡는다.
- **계약 11(Node `env -i`)** — 신뢰 게이트를 통과한 Node라도 호출 환경의 `NODE_OPTIONS=--require …`가
  그대로 적용된다는 것은 실측으로 확인했다. 경로 게이트만 보면 놓친다.

나머지(계약 3·4·6·7·8·10·12)는 상류 코드·스키마를 읽어 사전에 도출한 것이고, 실패를 겪은 적은 없다.
구분해 두는 이유: "전부 사고로 배웠다"고 쓰면 사전 독해로 막을 수 있는 부분까지 불가피했던 것처럼
읽히고, 다음 사람이 코드를 먼저 읽지 않게 된다.

## When to Apply

- 임의 저장소에서 실행되는 전역 스킬이 플러그인 사본을 선택할 때(신뢰 게이트 계약 1).
- 워크벤치 이력에 스캔을 등록·종결할 때(계약 2·3·6).
- 모델이 canonical JSON draft를 작성할 때(계약 4·5).
- deep 스캔 대체물을 만들 때(계약 8).
- 스캔 간 매칭이나 finding 판정처럼 대상 저장소 파생 텍스트를 LLM에 넣을 때(계약 7).
- 커버리지 분모가 되는 파일 목록을 만들 때, 또는 대상 저장소에서 외부 실행 파일을 해석할 때(계약 9).
- 상류 스킬 문서가 MCP 저장 도구나 별도 저장 정책을 지시할 때(계약 10).
- 상류 Node 헬퍼나 npm `dist/` 함수를 호출할 때(계약 11·12).
- **스킬 문서의 명령형이 부트스트랩 출력을 셸에 보간할 때(계약 9의 문서 절반).** 더 넓게는,
  프로그램이 정화한 값을 내보내고 **사람이나 에이전트가 문서를 읽어** 그것을 셸·SQL·URL·템플릿에
  보간하는 모든 구조. 이스케이프 함수의 출력은 소비자 쪽 문맥에 따라 유효성이 달라진다
  (`shlex.quote`와 이중인용, `html.escape`와 속성/스크립트 문맥, 파라미터 바인딩과 문자열 접합).
  반대로 값이 오직 `subprocess(env=…)`처럼 프로그램적으로만 소비된다면 원시 값을 쓰는 것이 맞다.

## Examples

**인용본을 이중인용으로 감싸면 인용이 무효가 된다(계약 9의 문서 절반)** — 가장 반직관적인 실패다.
소비자 명령형은 산문이므로 코드 리뷰에 잡히지 않는다:

```bash
# 위험 — 인용본을 넣어도 명령 치환이 실행된다(실측)
mkdir -p "<scan_dir>/artifacts/02_discovery"
env -i <trusted_child_env> PATH="<search_path_env>" <python_command> …

# 계약 — 맨몸 보간. 인용본은 이미 완결된 셸 토큰이다
mkdir -p <scan_dir>/artifacts/02_discovery
env -i <trusted_child_env> PATH=<search_path_env> <python_command> …
```

이어붙이기도 맨몸이 옳다 — `'…'/artifacts/02_discovery`를 셸이 하나의 단어로 잇는다(실측).
보안만의 문제도 아니다: 이중인용으로 감싸면 공백이 든 정상 경로에 리터럴 `'`가 섞여
**선의의 사용자가 깨진다**(실측).

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
`docs/verification/phase4-deep-lite-pipeline.md`(deep-lite 계약 — 0.4.0 이전 랭킹 계약은 역사 절),
각 상류 정합 기록(`docs/plans/*-alignment*.md`).
