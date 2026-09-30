# Claude 보안 스킬 — 설치 및 사용 가이드

**Claude Code만 설치된 PC**에서 이 스킬 9종을 설치해 쓰는 방법을 다룬다. OpenAI/Codex 인증
(ChatGPT 로그인, `OPENAI_API_KEY`)은 **필요하지 않다** — Claude Code 구독 로그인만 있으면 된다.

LLM 두뇌 역할은 Claude Code 세션 자신이 맡고, 검증·ID 파생·봉인·리포트 생성은 `codex-security`
번들 플러그인의 결정론(deterministic) Python 스크립트가 담당한다. 플러그인은 벤더링하지 않고
**설치된 것을 런타임에 찾아 쓴다.**

> **지원 범위**: 이 실행 경로는 비(非) Codex 경로이며 **업스트림 OpenAI 지원 대상이 아니다.**

- 설계 배경과 필수 계약 13개: [solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md](solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md)
- 단계별 실측 검증: [verification/phase0-results.md](verification/phase0-results.md) ~ [phase4-results.md](verification/phase4-results.md)

---

## 0. 빠른 설치 (릴리즈 tarball — 링크 하나로)

릴리즈 링크를 Claude에게 주고 *"이거 설치해줘"* 라고 하면 아래를 수행한다. 직접 실행해도 된다.

```bash
BASE=https://github.com/kall/codex-security-claude-skills/releases/download/<version>
PKG=codex-security-claude-skills-<version>

curl -fsSLO "$BASE/$PKG.tar.gz"
curl -fsSL  "$BASE/SHA256SUMS" | sha256sum -c -     # 무결성 검증
tar xzf "$PKG.tar.gz"
bash "$PKG/skills/install.sh" --copy --check
```

`--check`가 실행 환경을 프로브해 번들 플러그인 경로·버전·검색 명령(ripgrep)·Node·SECURITY.md
헬퍼·게이트 사본과 Python을 보고한다. 종료코드는 **0=정상 / 2=부분 정상(ripgrep 미확보 — 저장소 전체 스캔 불가) /
1=실패** 세 값이다 — exit 2를 통과로 보지 않는다.
플러그인이 없으면 설치할 명령을 안내한다(**자동 설치는 하지 않는다** — 전역 npm 환경 변경은
사용자 결정이다):

```bash
npm install -g @openai/codex-security                 # Node 22+
bash "$PKG/skills/install.sh" --copy --force --check   # 다시 확인
```

Claude Code를 재시작한 뒤 `/codex-security-scan <저장소>` 로 호출한다. 언제든 프로브만 다시
돌릴 수 있다:

```bash
bash "$PKG/skills/install.sh" --check-only
```

수동 설치(저장소 clone)나 세부 옵션은 3절을 본다.

---

## 1. 스킬 목록

| 스킬 | 용도 | 저장소 변경 |
| --- | --- | --- |
| `codex-security-scan` | 저장소 전체 1회 표준 스캔 → 봉인 계약 산출물 + `report.md` + SARIF | 없음 |
| `codex-security-diff-scan` | 변경분(커밋/브랜치 refs 또는 working-tree)만 스캔 | 없음 |
| `codex-security-validate` | 후보 finding 진위 판정(disposition) | 없음 |
| `codex-security-patch` | 보안 이슈 최소 수정 — **2단 승인** | **있음(승인 후)** |
| `codex-security-verify-fix` | 적용된 수정이 원래 취약점을 실제로 닫았는지 검증(**읽기 전용**) | 없음 |
| `codex-security-scan-match` | 완료된 스캔 2개 사이 동일 근본 원인 finding 매칭 | 없음 |
| `codex-security-deep-scan` | 다중 패스 심층 스캔의 축소판(**deep-lite** — 공식 deep과 비동등) | 없음 |
| `codex-security-policy` | 저장소·컴포넌트의 SECURITY.md **초안** 작성(공식 `policy` 대체) — 초안은 저장소 밖 상태 디렉터리에만 저장 | 없음 |
| `codex-security-classify-severity` | 완료된 스캔의 finding을 루브릭으로 심각도 재분류(공식 `classify-severity` 대체) — 결과는 스캔 디렉터리의 `severity-classification.json`과 워크벤치에 저장 | 없음 |

`codex-security-scan`이 공통 규칙의 정본이다(bootstrap, 금지 필드, 커버리지 정산, 리페어 루프,
워크벤치 수명주기). 나머지는 차이점만 정의하고 이를 참조한다.

---

## 2. 사전 요구사항

새 PC에서 아래 4개만 확인하면 된다.

```bash
claude --version     # Claude Code (구독 로그인 완료 상태)
python3 --version    # 3.10 이상 (3.10 이면 tomli 도 필요: pip install tomli)
git --version        # 필수
node --version       # 22 이상 — 플러그인 npm 설치, SECURITY.md 정책 해결, 5.9·5.10절 스킬에 필요
```

| 항목 | 요구 | 없을 때 |
| --- | --- | --- |
| Claude Code | 구독 로그인 세션 | OpenAI 키는 불필요하며 설정해도 쓰이지 않는다 |
| Python | 3.10+ (3.10은 `tomli`) | 설치 후 `PYTHON=<경로>`로 지정 가능 |
| git | 필수 | 대상 해석·diff·인벤토리 폴백에 사용 |
| Node.js | 22+ | 플러그인을 3.1절 (c)·(d) 방법으로 확보하면 설치에는 불필요하다. 다만 Node가 없으면 전체 스캔이 SECURITY.md 정책 해결을 고지와 함께 건너뛰고, `codex-security-policy`·`codex-security-classify-severity`는 쓸 수 없다 |
| ripgrep (`rg`) | 저장소 전체 스캔·deep-lite 는 **필수** | 인벤토리를 상류 스크립트에 위임하므로 확보하지 못하면 스캔이 시작되지 않는다. Claude Code 세션이면 내장 ripgrep을 `rg` 심링크로 노출해 자동 충족된다(3.3절 프로브가 확인). validate·patch·verify-fix·scan-match·policy·classify-severity는 불필요 |

**OS**: Linux / macOS 기준(bash). Windows는 WSL 사용을 권한다.

> **버전 매니저(mise/asdf/pyenv)를 쓰는 PC라면**: `python3`가 PATH에 없을 수 있다. 이 문서의
> `python3 …` 명령을 `mise exec -- python3 …` 처럼 감싸거나, `PYTHON="$(mise which python3)"`를
> 앞에 붙여 실행하면 된다. 스킬은 부트스트랩이 반환한 인터프리터 절대 경로를 이후 단계에
> 그대로 쓰므로, 첫 호출만 성공하면 나머지는 알아서 따라간다.

---

## 3. 설치 (새 PC, 3단계)

### 3.1 번들 플러그인 확보

스킬은 아래 순서로 플러그인을 탐색한다: **npm 전역 → npx 캐시 → (스킬 근처의) 저장소 체크아웃**.
새 PC에서는 (a)를 권한다.

```bash
# (a) 권장 — npm 전역 설치
npm install -g @openai/codex-security

# (b) npx 캐시에 내려받기만 하기
npx -y @openai/codex-security --version

# (c) 저장소 체크아웃 사용 (Node 불필요 — 단 아래 주의)
git clone https://github.com/openai/codex-security
#   → <clone>/plugins/codex-security (구 레이아웃: <clone>/sdk/typescript/_bundled_plugin)

# (d) 이미 어딘가에 사본이 있으면 경로를 직접 지정 (셸 프로필에 넣어두면 편하다)
export CODEX_SECURITY_PLUGIN_ROOT=/path/to/_bundled_plugin
```

**중요 — (c)를 쓸 때의 함정**: 저장소 체크아웃 후보는 **스킬 스크립트 위치의 상위 디렉터리**에서만
탐색한다. 즉 3.2절에서 스킬을 `~/.claude/skills/`로 **복사**하면 그 사본은 저장소 밖에 있으므로
체크아웃 자동 탐색이 되지 않는다. (c)를 쓰려면 `--link` 모드로 설치하거나 `CODEX_SECURITY_PLUGIN_ROOT`
(또는 `CODEX_SECURITY_SDK_REPO=<clone 경로>`)를 지정하라.

**(c)의 또 다른 한계**: 상류 소스 체크아웃에는 빌드된 `mcp/`(SECURITY.md Node 헬퍼)와 `dist/`(상류
결정론 함수)가 없다. 그래서 전체 스캔은 SECURITY.md 정책 해결을 건너뛰고, `codex-security-policy`와
`codex-security-classify-severity`는 동작하지 않는다. 이 둘을 쓰려면 (a) npm 설치본을 쓴다.

**신뢰 게이트**: 스캔 대상 저장소는 미신뢰 코드로 취급되므로, 그 하위(`node_modules` 포함)의
플러그인 사본은 리터럴 경로·realpath 양쪽 검사로 **거부**된다. 다른 사용자 소유이거나
world-writable인 사본도 거부된다. 공유 그룹 환경이라면 플러그인을 사용자 전용 권한(0755, 사용자
소유)으로 설치하라.

### 3.2 스킬 설치

스킬 파일은 이 저장소에 있다. 대상 PC에서 저장소를 받은 뒤 설치 스크립트를 실행한다.

```bash
git clone <이 저장소 URL> codex-security-skills
cd codex-security-skills

bash skills/install.sh --copy --check   # 새 PC 권장: 복사 설치 + 환경 프로브
bash skills/install.sh                  # 기본(--link): 저장소로 심볼릭 링크 — 스킬 개발용
bash skills/install.sh --copy --force   # 기존 설치본 덮어쓰기
bash skills/install.sh --check-only     # 설치 없이 프로브만
```

| 옵션 | 동작 |
| --- | --- |
| `--check` | 설치 후 플러그인·Python·검색 명령·게이트 사본을 프로브해 보고(자동 설치 없음) |
| `--check-only` | 설치를 건너뛰고 프로브만 수행 |
| `--force` | 대상 경로가 이미 있을 때 덮어쓰기 |

`--check`·`--check-only`의 **종료코드는 세 값**이며, 회귀 스크립트와 같은 규약이다:

| 종료코드 | 의미 | 어떻게 다룰까 |
| --- | --- | --- |
| 0 | 실행 환경 정상 | 정상 |
| **2** | **부분 정상** — 플러그인·Python은 정상인데 **ripgrep을 확보하지 못했다** | 저장소 전체 스캔과 deep-lite는 **시작할 수 없다**. diff·validate·patch·verify-fix·scan-match·policy·classify-severity는 동작한다. ripgrep을 설치하고 다시 확인한다 |
| 1 | 실패 | 플러그인 부재 등. 출력의 `stage=`와 설치 안내를 따른다 |

**exit 2를 통과로 보지 않는다.** CI나 릴리즈 검증이 종료코드만 확인하면 "주력 스킬이 시작조차
불가한 환경"과 "전부 정상"이 같은 신호가 된다.

Node·SECURITY.md 헬퍼·npm `dist/` 중 하나가 없으면 프로브가 `경고     : codex-security-policy 사용 불가 —
<사유>`, `경고     : codex-security-classify-severity 사용 불가 — <사유>` 줄을 낸다. 이 경고는 **종료코드를
바꾸지 않는다** — 주력 스캔 스킬과 무관하게 두 스킬만 쓸 수 없는 상태이기 때문이다. 두 스킬을 쓸
계획이면 이 줄이 없는지 확인한다.

스킬 이름을 인자로 주면 일부만 설치할 수 있지만, `bootstrap.py`는 `codex-security-scan`에만
있고 모든 스킬이 이를 참조하므로 **9종 전체 설치를 기본으로 두라**. `codex-security-policy`와
`codex-security-classify-severity`는 `codex-security-scan/scripts/workflow_digest.mjs`를 형제 경로로
import하므로, 같은 스킬 루트에 같은 버전으로 설치돼 있어야 한다.

설치 위치는 `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/<스킬이름>`이다. 대상 경로가 이미 있으면
설치를 **거부**하며 `--force`로만 덮어쓴다.

| 모드 | 동작 | 용도 |
| --- | --- | --- |
| `--copy` | 실제 복사본 | 다른 PC 배포. 저장소를 지워도 동작한다. 갱신은 `--copy --force` 재설치 |
| `--link` (기본) | 저장소 디렉터리로 심볼릭 링크 | 스킬 개발. 저장소 수정이 즉시 반영된다 |

복사 모드로 설치했다면 저장소 clone은 지워도 되지만, 3.1절 (c) 자동 탐색과 8절 재검증
스크립트는 저장소가 있어야 쓸 수 있다.

### 3.3 설치 확인

Claude Code를 재시작하고 스킬 목록에 9종이 보이는지, 그리고 부트스트랩이 플러그인을 찾는지
확인한다.

```bash
ls "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" | grep security-

python3 "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/codex-security-scan/scripts/bootstrap.py \
  --target-repo /path/to/target-repo --no-scan-dir
```

npm 전역 설치 환경에서의 성공 출력(npm 0.1.29 = 매니페스트 0.1.95 기준, 2026-09-23 실측. npm 0.1.32 빌드에서도
필드 구성이 같다(2026-09-30). 경로·Python·Node 값은 환경마다 다르다. 스킬 내부용 필드 `trustedPathEnv`·`trustedChildEnv`·`trustedChildEnvShell`·
`searchCommand`·`shellQuoted`와 `diagnostics`의 나머지 항목은 생략했다):

```json
{
  "ok": true,
  "pluginRoot": "<npm root -g>/@openai/codex-security/_bundled_plugin",
  "pluginVersion": "0.1.95",
  "pluginSource": "npm-global",
  "python": { "path": "/usr/bin/python3.14", "version": "3.14.7", "source": "python3" },
  "node": { "path": "/usr/bin/node", "source": "trusted-path", "version": "v22.23.2" },
  "securityMdHelper": {
    "available": true,
    "launcher": "<npm root -g>/@openai/codex-security/_bundled_plugin/scripts/launch_codex_security_mcp",
    "node": "/usr/bin/node",
    "reason": null
  },
  "sdk": {
    "dist": "<npm root -g>/@openai/codex-security/dist",
    "cli": "<npm root -g>/@openai/codex-security/bin/codex-security.mjs",
    "reason": null
  },
  "scanDir": null,
  "scansRoot": null,
  "stateDir": "/home/<user>/.codex/state/plugins/codex-security",
  "repoRoot": "/path/to/target-repo",
  "diagnostics": { "pluginAttempts": [ { "source": "npm-global", "result": "accepted", "pluginVersion": "0.1.95" } ] }
}
```

새 필드 세 개는 실패해도 `ok`를 바꾸지 않는다. 가용성과 사유만 싣고, 건너뛸지는 각 스킬이 정한다.

| 필드 | 뜻 | 없을 때 |
| --- | --- | --- |
| `node` | 대상 저장소 밖에서 신뢰 게이트를 통과한 Node(`CODEX_MCP_NODE_PATH` → `CODEX_BROWSER_USE_NODE_PATH` → 신뢰 PATH 순) | `null`. 전체 스캔은 정책 해결을 건너뛰고, policy·classify-severity는 중단한다 |
| `securityMdHelper` | 상류 SECURITY.md Node 헬퍼(npm 0.1.27부터) | `available: false`와 `reason`(헬퍼 파일 없음 / Node 없음 / 신뢰 게이트 거부). 전체 스캔은 건너뛰고, policy는 중단한다 |
| `sdk` | npm 패키지의 `dist/`와 CLI 스크립트 | `dist: null`과 `reason`(상류 소스 체크아웃 등). policy·classify-severity가 중단한다 |

`ok: false`면 `stage`(`pluginRoot` / `python` / `scanDir` / `arguments`)와 `error`의 한국어 안내를
그대로 따른다. `diagnostics.pluginAttempts`에 후보별 채택/거부 사유가 남으므로 왜 못 찾았는지
바로 알 수 있다.

### 3.4 플러그인 사본별 동작 차이 확인 (권장)

**매니페스트 0.1.95(npm 0.1.32) 기준으로는 두 사본이 같게 동작한다** — npm 배포본과 GitHub 저장소
체크아웃 모두 워킹트리가 변경돼도 **종결은 성공하고 경고만** 남긴다. 태그 `npm-v0.1.32`로 빌드한 패키지에서
`repro-u3.sh` S5가 `exit=0`이었고 경고 문구도 같았다(2026-09-30 재실측). npm 0.1.32의
`scripts/workbench_target.py`는 Git 실행 파일 선택과 커밋 diff digest 함수가 늘었지만 게이트 판정은 그대로다.
태그 체크아웃의 `scripts/`는 빌드 사본과 파일 단위로 같다. 체크아웃 사본에
`--check`를 돌려도 "경고 사본"으로 판별된다. 하드 실패 사본을 만드는 심볼(`require_unchanged_target`)은
현재 배포본에 존재하지 않는다.

과거(플러그인 0.1.14)에는 **같은 매니페스트 버전에서도 사본에 따라 처리가 달랐으므로**(하드 실패
vs 경고), 오래된 사본을 쓰거나 상류가 다시 바꿀 수 있다는 전제로 아래 프로브를 유지한다.

```bash
PLUGIN=$(python3 "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/codex-security-scan/scripts/bootstrap.py \
  --target-repo /path/to/target-repo --no-scan-dir | python3 -c 'import json,sys;print(json.load(sys.stdin)["pluginRoot"])')

grep -q "def require_unchanged_target" "$PLUGIN/scripts/workbench_db.py" \
  && echo "하드 게이트 사본: 스캔 중 저장소가 변경되면 이력 종결(complete)이 실패한다" \
  || echo "경고 사본: 변경돼도 종결은 성공하고 경고만 남는다(결과는 등록 시점 스냅샷 기준)"
```

| 사본 / 시점 | 스캔 중 워킹트리 변경 후 종결 시 | 실측 메시지 |
| --- | --- | --- |
| 태그 `npm-v0.1.32` 빌드 패키지 (매니페스트 0.1.95) | **성공 종결 + 경고** | `Working-tree contents changed while the scan was running; results were saved for the original snapshot.` |
| GitHub 저장소 체크아웃 0.1.32 (매니페스트 0.1.95) | **성공 종결 + 경고**(게이트 파일이 빌드 사본과 같다. `--check` 판별도 경고 사본) | 위와 동일 |
| npm 배포본 0.1.29 (매니페스트 0.1.95, 과거 실측) | **성공 종결 + 경고** | 위와 동일 |
| npm 배포본 0.1.25 (매니페스트 0.1.94, 과거 실측) | **성공 종결 + 경고** | 위와 동일 |
| GitHub 저장소 체크아웃 0.1.25 (매니페스트 0.1.94, 과거 실측) | **성공 종결 + 경고**(과거의 하드 실패 동작 없음) | 위와 동일 |
| npm 배포본 0.1.3 (매니페스트 0.1.14, 과거 실측) | **성공 종결 + 경고** | 위와 동일 |
| GitHub 저장소 체크아웃 0.1.14 (과거 실측) | `complete-scan` **실패**(스캔 행은 `running` 유지) → 스킬이 3선택지를 묻는다 | `Working-tree contents changed while the scan was running. Start a new scan.` |

게이트 조건(등록 시 저장한 스냅샷 다이제스트 비교)은 어느 사본이든 같고 **위반 시 처리만** 달랐다.
스킬은 양쪽 모두 정직하게 보고한다 — 실패면 3선택지를 묻고, 경고면 그 문구를 최종 보고에 그대로
싣는다. 현재 배포본에서는 경고 경로만 관측되지만, 하드 실패 분기는 오래된 사본 대비로 남겨 둔다.

다만 **결과의 기준 시점은 등록 시점 스냅샷**이므로, 정확한 스캔을 원하면 사본과 무관하게 스캔 전
commit/stash를 권한다.

### 3.5 제거

```bash
rm -rf "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/codex-security-{scan,diff-scan,validate,patch,verify-fix,scan-match,deep-scan,policy,classify-severity}
npm uninstall -g @openai/codex-security   # 플러그인까지 지울 때
```

스캔 이력·산출물은 `~/.codex/state/plugins/codex-security/`에 남으므로 필요하면 별도로 지운다.
SECURITY.md 초안은 그 아래 `policies/`, 심각도 재분류 작업 파일은 `severity-work/`에 있다.

---

## 4. 환경변수

전부 선택이다. 기본값으로 동작한다.

| 변수 | 역할 |
| --- | --- |
| `CODEX_SECURITY_PLUGIN_ROOT` | 플러그인 루트 직접 지정(탐색 생략) |
| `CODEX_SECURITY_SDK_REPO` | 상류 저장소 체크아웃 경로 지정. `<경로>/plugins/codex-security` 를 먼저 보고, 없으면 구 레이아웃 `<경로>/sdk/typescript/_bundled_plugin` 을 본다 |
| `CODEX_SECURITY_STATE_DIR` | 워크벤치 상태 DB·스캔 산출물 루트. 기본 `$CODEX_HOME/state/plugins/codex-security` → `~/.codex/state/plugins/codex-security` |
| `CODEX_HOME` | 위 폴백 기준(기본 `~/.codex`) |
| `PYTHON` | 부트스트랩이 쓸 Python 인터프리터 지정 |
| `CLAUDE_SKILLS_DIR` | 스킬 설치 위치의 상위 디렉터리(기본 `$HOME/.claude/skills`) |
| `CODEX_SECURITY_STARTED_AT` | 스캔 시작 시각(ISO8601 Z). finalize에 필수 — **스킬이 관리**한다 |
| `PYTHONDONTWRITEBYTECODE=1` | 플러그인 디렉터리에 `__pycache__`를 남기지 않는다 — **스킬이 항상 전달**한다 |

상태 디렉터리를 기본 위치로 두면 공식 CLI(`codex-security scans list`)와 **이력이 공유**된다.
`~/.codex`에 쓸 수 없는 환경이면 `CODEX_SECURITY_STATE_DIR`을 대상 저장소 밖의 쓰기 가능한
전용 디렉터리로 지정한다.

---

## 5. 사용법

### 5.1 호출

Claude Code 세션에서 슬래시로 호출하거나, 자연어로 요청하면 Claude가 설명(description)을 보고
적절한 스킬을 고른다.

```
/codex-security-scan /path/to/target-repo
/codex-security-diff-scan --diff origin/main
/codex-security-patch docs/finding.md
```

```
"이 저장소 전체를 보안 스캔해줘"          → codex-security-scan
"이번 브랜치 변경분만 보안 검토해줘"       → codex-security-diff-scan
"이 finding이 진짜 취약점인지 판정해줘"    → codex-security-validate
"이 저장소의 SECURITY.md 초안을 만들어줘"   → codex-security-policy
"이 스캔 finding을 우리 루브릭으로 심각도 다시 매겨줘" → codex-security-classify-severity
```

**대상 저장소 루트를 명시하라.** 생략하면 cwd의 git 최상위로 추정하는데, 모노레포 하위
패키지에서 호출하면 신뢰 경계가 좁아진다.

첫 실행 때 Claude가 사용자에게 알리는 것: 선택된 플러그인의 절대 경로와 `pluginVersion`,
그리고 스캔 중 저장소를 건드리지 말라는 권고. 부트스트랩이 실패하면 원인과 조치를 한국어로
안내하고 중단한다.

### 5.2 표준 전체 스캔 — `/codex-security-scan`

```
/codex-security-scan /path/to/target-repo
```

진행 순서: bootstrap → (선택) 워크벤치 등록 → 위협 모델 → 인벤토리 + **스코프 내 전 파일 리뷰** →
validation(compact) → attack-path(compact) → canonical JSON 3종 draft → 커버리지 정산 → 봉인
(`finalize_scan_contract.py`) → (선택) 워크벤치 종결.

산출물은 대상 저장소 **밖**에 생성된다(디렉터리 0700, 파일 0600):

```
~/.codex/state/plugins/codex-security/scans/<저장소이름>-<타임스탬프>/
├── scan-manifest.json          # 봉인 계약 매니페스트
├── findings.json
├── coverage.json
├── report.md                   # 주 가독 산출물 (finalizer 생성 — 손으로 수정 금지)
├── *.sarif
├── threat_model.md
└── artifacts/
    ├── 01_context/             # threat_model 복사본, security_guidance.md, false_positive_feedback.json
    ├── 02_discovery/           # in_scope_files.txt, review_log.jsonl, raw/agent-*.jsonl, candidate_ledger.jsonl
    └── 03_coverage/            # reviewed_surfaces.md
```

완료 시 Claude가 한국어로 보고하는 항목: 파인딩 수와 심각도 분포, `report.md`·SARIF **절대 경로**,
커버리지 상태(`complete`/`partial`)와 미리뷰 파일 수, 능력 확인에서 격하됐는지 여부, 워크벤치
경고(있으면). 완전 커버리지를 거짓 주장하지 않으며, 후속 작업(내보내기·패치·트래킹)은
**제안만** 하고 요청 없이는 실행하지 않는다.

대형 저장소는 컨텍스트가 소진될 수 있다. 그때는 남은 파일을 미완으로 남기고 커버리지를
`partial`로 정산해 정직하게 보고한다. 스코프를 좁혀(경로 지정) 나눠 돌리는 것도 방법이다.

### 5.3 변경분 스캔 — `/codex-security-diff-scan`

| 인자 | 대상 | base / head |
| --- | --- | --- |
| `--diff BASE [--head HEAD]` | 커밋/브랜치 refs | base=BASE, head=HEAD(기본 현재 HEAD) |
| `--working-tree [--base REF]` | 스테이지+미스테이지 로컬 패치 | base=REF(기본 HEAD) |
| (인자 없음) | working-tree | base=HEAD |

```
/codex-security-diff-scan --diff origin/main
/codex-security-diff-scan --diff v1.2.0 --head HEAD
/codex-security-diff-scan --working-tree
```

위협 모델은 **저장소 전체 범위**에서, 리뷰는 **diff 범위**에서 수행한다. working-tree 스캔은
등록 시점의 워킹트리 다이제스트가 기준이므로 **스캔이 끝날 때까지 파일을 저장하지 마라**
(플러그인 사본에 따라 이력 종결이 실패하거나 경고가 남는다 — 3.4절).

### 5.4 finding 판정 — `/codex-security-validate`

```
/codex-security-validate <scanDir>/artifacts/02_discovery/candidate_ledger.jsonl   # ledger 모드
/codex-security-validate "src/db.py:42 의 f-string SQL 조립이 SQLi 인지 판정"        # 단독 모드
```

- **ledger 모드**: 원장의 모든 행에 `validation` 객체를 하나씩 추가하고, discovery 필드와 행
  순서를 보존하며 원자적으로 재작성한다. 이미 판정된 행은 재판정 여부를 먼저 묻는다.
- **단독 모드**: 같은 판정 구조를 한국어 보고서로 출력한다.

disposition은 `reportable` / `suppressed` / `not_applicable` / `deferred` 4값이다. 데모·테스트·로컬
전용이라는 이유로 실제 버그를 기각하지 않는다.

### 5.5 이슈 수정 — `/codex-security-patch` (2단 승인)

```
/codex-security-patch <finding 서술 파일 또는 텍스트>
```

이 시리즈에서 **유일하게 저장소를 변경하고 저장소가 정의한 코드를 실행**할 수 있는 스킬이다.

1. **1단 승인 — 수정 diff**: 최소 수정안을 diff로 제시하고, 승인 후에만 적용한다. 거부하면
   저장소는 무변경으로 남는다.
2. **2단 승인 — 게이트 실행**: 명령 원문과 정의 파일 경로를 보여주고 **별도 승인**을 받으며,
   기본값은 미실행이다.

**무엇이 2단 승인 대상인가** — 판정 기준은 "명령 문자열의 출처"가 아니라 **"저장소가 코드 실행을
통제하는가"**다(정본: `codex-security-patch/SKILL.md`의 「2단 승인 대상 판정 규칙 (P5-KTD7)」).
`package.json`의 `scripts.test`나 `Makefile` 타깃처럼 저장소가 정의한 명령은 물론이고, 툴체인
바이너리를 **직접 호출**하더라도 그것이 저장소 설정 파일을 읽어 코드를 실행하면 대상이다 —
`pytest`→`conftest.py`, `eslint`→`.eslintrc` 플러그인, `mypy`→플러그인. **불확실하면 기본값은 2단
승인**이고, 1단 범위는 설정 파일을 읽지 않음이 확인된 명령(`python -m py_compile <file>`, 설정
로드 없는 `tsc --noEmit`)으로만 한정한다. 이 규칙은 패치 적용 **전**의 재현 명령에도 적용된다.

outcome은 `fixed` / `no_change` / `blocked` 3값이다. **`fixed`는 수정이 적용되고 게이트가 통과한
경우에만** 쓴다 — 게이트를 실행하지 않았거나 거부됐으면 `blocked`이고, 그때는 **적용 여부 / 게이트
실행 여부 / 되돌리는 방법**을 세 줄로 명시한다(되돌리기는 제안만 하고 실행은 별도 승인).
**1단 승인 거부**도 `no_change`가 아니라 `blocked`다 — 저장소는 무변경이지만 "이미 안전함이 증거로
확인된" 경우가 아니기 때문이다. `no_change`에도 검증 근거(원래 이슈가 재현되지 않는 증거와 정상 동작
확인)가 필요하다. 근거가 없으면 `blocked`다. npm 0.1.32 상류 CLI도 근거 없는 `no_change`를 실패로 처리한다.

> 세션 퍼미션이 `acceptEdits`/`bypassPermissions`면 편집·실행이 프롬프트 없이 진행되므로, 그때는
> **SKILL.md의 2단 승인 지침이 유일한 게이트**다. 스킬은 이 사실을 먼저 고지한다. 보안 수정을
> 검토하며 진행하려면 기본 퍼미션 모드에서 쓰는 편이 안전하다.

### 5.6 수정 검증 — `/codex-security-verify-fix` (읽기 전용)

```
/codex-security-verify-fix <findings.json 또는 finding 서술 파일/텍스트>
```

이미 적용된 수정이 **원래 취약점을 실제로 닫았는지**만 판정한다. 저장소를 변경하지 않는다
(파일 생성·수정·패치 적용·커밋·아티팩트 쓰기 없음). `findings.json`을 주면 파일 순서 그대로
finding별로 1건씩 판정한다.

판정값은 `fixed`(경계가 닫혔고 정상 동작도 유지됨이 입증) / `still_vulnerable`(원래 경로가 여전히
도달 가능함이 입증) / `inconclusive`(저장소 불일치·컨텍스트 부족·관련 검사 실행 불가 등 증명 공백)
3값이며, JSON 결과 뒤에 한국어 요약이 붙는다.

**파일이 사라졌거나 함수명이 바뀐 것은 수정의 증거가 아니다** — 스킬은 이동·리팩터링된 코드를
따라가 재추적한다. 티켓 종료·무관한 테스트 통과·"새 스캔에 안 나옴"도 증거로 인정하지 않는다.

> 재현기·테스트 등 **저장소가 코드 실행을 통제하는 명령**을 돌리려면 명령 원문과 정의 파일을
> 제시하고 **별도 승인**을 받는다(기본 미실행). 승인 대상 판정은 5.5절과 같은 규칙(P5-KTD7)을
> 쓴다 — 정본은 `codex-security-patch/SKILL.md`다. 미승인이면 정적 근거로만 판정하고 못 돌린
> 검사를 증명 공백으로 남긴다 — 대개 `inconclusive`가 된다.

### 5.7 스캔 간 매칭 — `/codex-security-scan-match`

```
/codex-security-scan-match <before-scan-id> <after-scan-id>
```

완료(sealed) 스캔 2개 사이에서 제목·CWE·fingerprint·위치가 달라도 **동일 근본 원인·동일 수정으로
해결되는** finding을 그룹화해 이력을 연결한다(공식 `scans match` 대체 — 그 명령은 SDK가 Codex
스레드를 직접 여는 유일한 지점이라 OpenAI 인증 없이는 막혀 있다).

매칭은 상류 0.1.29~0.1.32 `scans match`와 같은 순서로 진행한다(이 구간에 조정 규칙 변경 없음).

1. **호스트 신원 병합** — 같은 `findingId`와 **`knownFindingGroups`**(이전 비교들에서 이미 같은
   finding으로 확정된 `findingId` 묶음, union-find로 이행 병합)를 판정 **전에** 카드 한 장으로 접는다.
   이것만으로 모든 그룹이 끝나면(예: 두 스캔의 모든 finding이 같은 `findingId`) **서브에이전트를
   부르지 않고** 바로 저장한다.
2. **판정** — 끝나지 않으면 전체 카탈로그(before 대표 카드 전부 + after 카드 전부)를 **도구를 제한한
   격리 서브에이전트**(파일 쓰기·Bash·네트워크 없음, JSON만 반환)에 보낸다. 매칭 입력에는 대상 저장소
   코드에서 파생된 텍스트가 그대로 들어가기 때문이다. 서브에이전트는 대표 카드 ID로 답한다.
3. **조정·검증** — `validate_matches.py`가 대표 ID를 과거 occurrence 전부로 펼치고, 신원 그룹과
   합친 뒤 강제 검증한다. 거부되면 사유를 전달해 재판정한다. 통과한 결과만 저장한다.

판정 결과는 세 갈래다 — **`matches`**(동일 근본 원인, 확정), **`uncertain`**(그럴듯하나 확신 없음),
**`related`**(의미 있게 관련되지만 근본 원인이 달라 각각 따로 수정해야 함). `related` 쌍의 before와
after는 **같은 확정 매칭 그룹에 있으면 안 되고**, `uncertain`과 겹치거나 서로 중복될 수 없다. 세 갈래
모두 각 항목에 **비어 있지 않은 `reason`**이 필요하다. 같은 신원 그룹 안의 `uncertain`·`related` 쌍은
호스트가 오류 없이 버린다.

**프롬프트 한도**: 조립한 프롬프트가 실효 한도(상류 동등성 한도 1,048,576자와 실행 한도 중 작은 값,
스킬 문서 「프롬프트 한도」)를 넘으면 **나눠서 판정하지 않고 저장 없이 중단**한다. 서브에이전트가
카드만으로 판정할 수 없어 증거가 필요하다고 답한 경우(`evidenceNeeded`)도 같다. 두 경우 모두 사유와
대상 건수를 보고한다. 상류의 페이지·증거 요청 루프는 지원하지 않는다.

저장 후:

```bash
codex-security scans compare <before-scan-id> <after-scan-id>
```

두 스캔 모두 5.11절 워크벤치 등록을 거쳐야 하며, 일괄 매칭(`--all`)은 지원하지 않는다(쌍 단위만).

**기확정 그룹이 틀렸다고 판단될 때** — 호스트가 기확정 그룹을 먼저 병합하므로 서브에이전트는 그
그룹을 깰 수 없다. 대신 우려를 `priorGroupConcerns`(그룹의 `findingId` + 근거)로 보고할 수 있다.
**우려가 있어도 저장은 진행된다**(상류와 같은 동작). 우려는 최종 보고의 별도 절에 나온다. 잘못된
그룹을 고치는 정상 경로는 다음과 같다:

1. 어느 비교에서 그 그룹이 생겼는지 확인한다(`codex-security scans compare` 이력).
2. 그 비교를 다시 판정해 저장한다 — 근원을 고치면 `knownFindingGroups`가 갱신된다.

> 동작 변경(P5 → 0.1.29 정합): 이전에는 기확정 그룹과 모순되는 판정을 거부하고
> `blockedByPriorGroup`으로 저장을 막았다. 지금은 그 필드를 받지 않고, 과거 오판은 우려 보고만 남긴 채
> 저장된다.

### 5.8 deep-lite 스캔 — `/codex-security-deep-scan`

```
/codex-security-deep-scan /path/to/target-repo
```

> **공식 deep 스캔과 동등하지 않다.** 공식 deep은 Codex Subagents v2 런타임과 24시간 MCP
> 오케스트레이터에 결박되어 있어 동등 재현이 불가능하다. 이 스킬은 정직한 축소판으로,
> 랭킹·샤딩은 플러그인 스크립트, 후보 발굴 팬아웃은 Claude 서브에이전트, 수렴은 **고정 2패스**로
> 대체한다. 스킬은 이 고지를 시작과 최종 요약에 모두 넣는다.

파이프라인: 랭킹 입력 생성 → 샤딩 → 워커 배정 → **랭킹 팬아웃(전량 성공 필수, 3회 실패 시 중단)**
→ 병합 → 상위 N% 선택 → **리뷰 팬아웃 고정 2패스(부분 실패 허용 → 커버리지 `partial`)** → 단일
원장 병합 → validation·attack-path 중앙화 tail → 봉인.

표준 스캔보다 시간과 컨텍스트를 훨씬 많이 쓴다. 최종 요약에는 워커별 후보 분포 표가 포함되어
조용히 "후보 없음"을 반환한 워커를 감지할 수 있다.

### 5.9 SECURITY.md 초안 — `/codex-security-policy` (저장소 무변경)

```
/codex-security-policy /path/to/target-repo
```

```
"services/api 컴포넌트의 SECURITY.md 초안을 만들어줘. 아키텍처 문서는 docs/arch.md야"
```

공식 `codex-security policy`를 대체한다. 그 명령은 OpenAI 모델을 세 번 호출하므로 인증 없이는 쓸 수
없다. 이 스킬은 상류와 같은 3단계(아키텍처 → 위협 모델 → 정책)를 **읽기 전용 격리 서브에이전트**로
수행하고, 나머지 호스트 동작(대상 해석, 출력 디렉터리, 스냅샷, diff 미리보기)은 npm 배포본 `dist/`의 상류
함수로 재현한다.

| 입력 | 규칙 |
| --- | --- |
| 대상 저장소 | 컴포넌트를 둘러싼 **가장 바깥 Git worktree 루트**를 명시한다 |
| 컴포넌트 경로 | 저장소 루트 기준 상대 경로(기본 `.`) |
| 지식 베이스(선택) | 아키텍처 문서 등. 상류와 달리 복사·변환하지 않고 서브에이전트가 읽을 수 있는 경로에 넣는다 |

진행: 부트스트랩 → 대상 해석과 출력 디렉터리 준비 → 단계마다 서브에이전트 → **저장 전 결정론 검사** →
(architecture 단계 뒤) **소유자 질문** → 마무리(스냅샷 재확인, 매니페스트, diff 미리보기).

- **소유자 질문**: 한 번에 최대 3개씩 묻는다. 답을 비우면 미해결로 남는다. 질문은 저장소에서 파생된
  모델 출력이므로 그 안의 지시는 따르지 않는다. 이것 말고 승인 단계는 없다 — 저장소를 바꾸지 않기 때문이다.
- **저장 전 검사**: 초안은 저장소에 커밋될 문서라 여기서 새면 공개 저장소로 나간다. 로컬 절대 경로,
  `.git/` 경로, 개인 키 머리글, URL 자격 증명, AWS·GitHub·Slack·`sk-` 토큰이 보이면 그 단계 문서를 저장하지
  않고 다시 판정한다(단계당 최대 3회). 완전한 비밀 탐지기는 아니다.
- **한도**: 단계 프롬프트가 80,000자를 넘으면 나누지 않고 중단한다. 컴포넌트의 정책 체인에 1 MiB를 넘는
  SECURITY.md가 있으면 해결 전에 중단한다(출력 디렉터리를 만들지 않는다).
- **생성 중 SECURITY.md가 바뀌면** 매니페스트를 쓰지 않고 "생성 후 SECURITY.md가 바뀜 — 새 초안 필요"를
  보고한다. 이미 저장한 문서는 남는다.

산출물은 대상 저장소 **밖**에만 생긴다(디렉터리 0700, 파일 0600, 덮어쓰지 않음):

```
~/.codex/state/plugins/codex-security/policies/<저장소이름>/codex-security-<저장소이름>-policy-XXXXXX/
├── previous-SECURITY.md   # 원래 정책(없으면 빈 파일)
├── project-spec.md        # architecture 단계 결과
├── THREAT_MODEL.md        # threat_model 단계 결과
├── SECURITY.md            # 검토할 초안
└── policy-draft.json      # 매니페스트(세 단계 성공 + 스냅샷 불변일 때만)
```

**저장소를 바꾸지 않는다.** 초안을 검토한 뒤 사용자가 직접 대상 경로(`targetPath`)로 복사한다. 승인 후
저장소에 적용하는 상류 plugin 단계는 이 스킬 범위 밖이다. 매니페스트의 `model`은
`"claude-subagent (Claude Code)"`로 적는다.

**전제**: npm 설치본(npm 0.1.27 이상, 권장 0.1.32) — Node 헬퍼와 `dist/`가 필요하다. 신뢰 Node도 필요하다.
하나라도 없으면 초안을 만들지 않고 중단한다(3.2절 프로브 경고 줄로 미리 알 수 있다).

> **비동등성 고지**: 상류 `policy`는 모델을 OS 수준 권한 프로필(읽기 경로 한정, Git 메타데이터 차단,
> 네트워크 차단, 쓰기 불가)로 실행한다. 이 스킬은 서브에이전트 도구 제한, 프롬프트 수준 읽기 범위 지시,
> 저장 전 검사로 대체한다. **OS 샌드박스와 동등하지 않고, 경로 제한은 강제되지 않는다.** Read·Grep·Glob만
> 가진 에이전트 유형을 `~/.claude/agents/`에 정의해 두면 그것을 쓴다(정의 예시는
> `codex-security-policy/SKILL.md` 2단계). 없으면 쓰기 도구가 없는 가장 좁은 유형을 쓰고, 어떤 유형을
> 썼는지 최종 보고에 적는다.

### 5.10 심각도 재분류 — `/codex-security-classify-severity`

```
/codex-security-classify-severity <scanDir> --rubric rubric.md
/codex-security-classify-severity <scanDir>                      # 루브릭 없음: 기존 severity 상속
```

공식 `codex-security classify-severity --rubric`을 대체한다. 그 명령은 finding마다 OpenAI 모델을 한 번
호출한다. 이 스킬은 **판정 자리만** 도구 없는 격리 서브에이전트로 바꾸고, finding 선택·digest·저장 평가
재사용·검증·저장·결과 파일 기록은 npm 배포본 `dist/`의 상류 함수를 그대로 실행한다.

| 입력 | 규칙 |
| --- | --- |
| 스캔 | 스캔 ID(접두어·`latest`) **또는** 완료 스캔 디렉터리 중 정확히 하나 |
| 루브릭 | 있으면 루브릭 판정, 없으면 기존 severity 상속 |
| 지식 베이스(선택, 반복) | **텍스트 파일만.** PDF·DOCX는 거부한다 — 텍스트로 변환해서 준다 |
| finding 선택(선택) | 생략하면 스캔의 모든 finding. 스캔에 없는 ID가 하나라도 있으면 시작 전에 거부한다 |
| 재처리(선택) | digest가 같은 저장 평가가 있어도 다시 판정한다 |

- **루브릭 없음**: 상류 CLI의 루브릭 없는 경로에 위임한다(모델 호출·인증 없음, 5.12절). 기존 severity가
  없는 finding이 있으면 상류가 멈추므로 루브릭을 준다.
- **루브릭 있음**: 준비(워크벤치에 쓰지 않음) → finding마다 새 서브에이전트 판정(병렬 가능) → 저장(쓰기
  전에 입력이 그대로인지 다시 확인). 루브릭·지식 베이스·finding digest가 모두 같은 저장 평가는 다시 판정하지
  않는다. 루브릭이 한 글자라도 바뀌면 전부 다시 판정한다. 반환이 상류 검증을 통과하지 못하면 그 finding만
  **한 번** 다시 판정하고, 또 실패하면 중단한다.
- **한도**: 조립한 프롬프트가 80,000자를 넘으면 나누지 않고 시작 전에 거부한다. 루브릭·지식 베이스를 줄이거나
  finding을 나눠 고른다.
- 상류 분류 지시가 이 스킬이 고정한 영문 원문과 다르면 진행하지 않는다(상류 계약이 바뀐 것이다).

저장 위치(대상 저장소와 봉인 파일은 바뀌지 않는다):

| 위치 | 내용 |
| --- | --- |
| 워크벤치 `~/.codex/state/plugins/codex-security/workbench.sqlite3` | finding별 평가 행 — **정본**. 공식 `publish`가 읽는다 |
| `<scanDir>/severity-classification.json` | 결과 파일(원자적 기록). 재사용·게시에는 읽히지 않는다 |
| `~/.codex/state/plugins/codex-security/severity-work/` | 작업 파일(0700). 성공하면 지운다 |

최종 보고는 finding마다 결정(`decision`)·레벨(`level`)·루브릭 라벨·재사용 여부를 표로 보여 준다.

- **제외(`excluded`)는 낮은 심각도가 아니다.** 루브릭이 범위에서 뺀 finding이며, 공식 `publish`는 이슈로
  만들지 않는다.
- 평가는 finding ID마다 하나씩 **전역으로** 저장된다. 같은 finding이 다른 스캔에 있으면 그 평가도 바뀐다
  (상류와 같은 동작).
- 중간에 멈추면 일부 finding만 저장된 상태가 남는다. 그때 `publish`는 `Severity classification is incomplete
  or its inputs changed.`로 멈추므로 끝까지 다시 분류한다.
- **확인**: `publish scan --dry-run`으로 Linear API 키 없이 게시 미리보기를 볼 수 있다(5.12절).

**전제**: npm 설치본의 `dist/`(npm 0.1.26 이상, 권장 0.1.32), 신뢰 Node, 플러그인 Python 3.10+.

> **비동등성 고지**: 상류는 finding마다 OS 샌드박스(읽기 전용, 네트워크 차단, 셸·MCP 비활성)의 Codex 모델을
> 쓴다. 이 스킬은 Claude 서브에이전트가 판정하고, 도구 금지는 서브에이전트 유형이나 프롬프트 지시로
> 대체한다. **OS 샌드박스와 동등하지 않다.** 모델이 달라 같은 루브릭이라도 판정이 다를 수 있다. 모델·effort는
> digest에 들어가지 않으므로, 상류 CLI로 다시 분류하려면 `--reprocess`가 필요하다.

### 5.11 워크벤치 이력 통합 (선택)

스캔을 공식 CLI 이력과 호환시키려면 워크벤치 상태 DB에 등록·종결한다. 순수 로컬 스캔만 원하면
건너뛰면 되고, 그 스캔은 `scans list`에 나타나지 않는다. 스킬에 "이력에 등록해줘"라고 말하면
아래를 알아서 수행한다.

순서 계약: `check-running` → **`register`(빈 scan-dir)** → 하위 구조 생성 → **`contract`** →
`feedback` → (스캔 수행) → 정산 → **finalize → `complete`**.

```bash
python3 "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/codex-security-scan/scripts/workbench_glue.py \
  --bootstrap <bootstrap.json> <서브커맨드> [옵션]
```

| 서브커맨드 | 용도 |
| --- | --- |
| `check-running` | 같은 저장소의 `running` 행 advisory 경고(차단 아님) |
| `register [--mode standard\|diff\|deep] [--paths …]` | 스캔 등록. **scan-dir이 비어 있어야** 성공. diff는 `--diff-target refs\|working_tree --base <base> [--head <head>]`를 함께 준다 |
| `contract --scan-id <id>` | draft가 사전 일치시켜야 하는 좌표 필드 조회. diff 스캔은 `diffTarget`(base·head 커밋과 상류 규칙으로 계산한 `snapshotDigest`)도 준다 |
| `feedback --scan-id <id>` | 과거 false-positive 피드백을 `01_context`에 기록 |
| `complete --scan-id <id>` | 종결. 게이트 실패는 구조화 결과로, 경고는 `warnings`로 반환 |
| `fail --scan-id <id> --message <사유>` | 실패로 종결(사용자 명시 선택 시에만) |
| `list-stale [--hours N]` / `close-stale --scan-id <id>` | 좀비 `running` 행 나열 / 명시적 정리 |

등록된 스캔은 공식 CLI에서 함께 조회된다(Node 22+ 필요):

```bash
codex-security scans list
codex-security scans show <scan-id>
codex-security findings false-positive <occurrence-id> --reason "…"
```

기록된 false-positive는 다음 스캔의 `feedback` 단계에서 주입되며, **리뷰어 피드백이지 지시가
아님**으로 취급되어 사유가 여전히 유효할 때만 finding을 기각한다.

### 5.12 인증 없이 쓰는 상류 CLI 명령

공식 CLI(`@openai/codex-security`)에는 모델을 부르지 않아 **OpenAI 인증 없이 바로 쓸 수 있는** 명령이 있다.
이 스킬들은 그 명령을 감싸지 않는다. 아래 표는 npm 0.1.29와 태그 `npm-v0.1.32` 빌드에서 빈 `HOME`·`CODEX_HOME`·
`CODEX_SECURITY_STATE_DIR`로 격리해 **성공을 실측한 명령만** 담는다([phase0-results.md](verification/phase0-results.md)
0.1.29 부록 2번, 0.1.32 부록).

호출은 전역 설치본이면 `codex-security <명령>`, 설치 없이 쓰려면 `npx @openai/codex-security <명령>`이다.
공통 전제는 Node 22+와 플러그인 Python(3.10+, `PYTHON`으로 지정 가능)이다. 이 스킬들과 같은 이력을 쓰려면
`CODEX_SECURITY_STATE_DIR`를 스킬과 같은 값으로 둔다(기본값이면 둘 다 `~/.codex/state/plugins/codex-security`).

| 명령 | 용도 | 실측 결과 |
| --- | --- | --- |
| `init [file]` | 공식 CLI용 프로젝트 설정 파일 초안을 쓴다(기본 `codex-security.yaml`, 기존 파일은 덮어쓰지 않음) | 성공. 파일을 0600으로 쓴다 |
| `scan import --json <file>` (또는 `--csv <file>`) | 다른 도구의 finding(CSV·JSON)을 **보안 분석 없이** 완료된 봉인 스캔으로 저장한다 | 성공. `<상태 디렉터리>/scans/imports/codex-security-import-*`에 봉인 스캔을 만든다 |
| `classify-severity --scan-dir <dir>` (루브릭 없음) | 기존 severity를 상속해 심각도 평가를 저장한다 | 성공. `severity-classification.json`과 워크벤치 행을 쓴다 |
| `policy <repo> --dry-run --headless` | SECURITY.md 초안 생성 입력(대상 해석 등)만 검증한다 | 성공. 모델을 시작하지 않는다(`authentication.verified: false`) |
| `publish scan --scan-dir <dir> --to linear --linear-team <아무 값> --dry-run` | Linear 게시 미리보기 | 성공. Linear API 키 없이 미리보기를 낸다 |

**명령별 주의와 이 스킬들과의 관계**

- **`init`**: 공식 CLI의 설정 파일이다. 이 저장소의 스킬은 이 파일을 읽지 않는다.
- **`scan import`**: 출력 경로의 **모든 상위 디렉터리가 group/world 쓰기 불가**여야 한다(sticky 비트가 있는
  디렉터리는 예외). 아니면 `Scan output parent must not be group- or world-writable without the sticky
  bit`로 exit 2다. 상태 디렉터리를 옮길 때 그 상위를 0700으로 둔다. 만든 스캔의 저장소는 원래 저장소가
  아니라 `<상태 디렉터리>/imports/json-<digest>` 디렉터리로 기록되고, 커버리지는 `unknown`이다(2026-09-23
  실측). 이 스킬들의 입력으로 쓸 때:
  - `codex-security-classify-severity`: 쓸 수 있다. 회귀 스크립트 `repro-u8-policy-severity.sh`가 import
    스캔을 입력으로 분류·저장·`publish --dry-run`까지 확인한다.
  - `codex-security-scan-match`: import 스캔 두 개로 워크벤치 `compare-scans`가 매칭 입력을 내는 것까지
    확인했다(`comparable: false`). 매칭 판정과 저장까지 이어지는지는 확인하지 않았다.
  - `codex-security-patch`·`codex-security-verify-fix`: **확인하지 않음.** finding 위치가 가져온 보고서를
    가리키고 원래 저장소와 연결되지 않으므로 맞지 않을 수 있다.
- **`classify-severity`(루브릭 없음)**: `codex-security-classify-severity` 스킬도 루브릭이 없으면 이 경로에
  위임한다. 루브릭을 주면 모델 호출이 필요하므로 CLI로는 쓸 수 없다 — 5.10절 스킬을 쓴다.
- **`policy --dry-run`**: 모델을 시작하지 않고 대상 저장소·컴포넌트·초안 대상 경로(`targetPath`)만
  확인한다. `--dry-run`을 빼면 인증이 필요하다 — 초안은 5.9절 스킬로 만든다.
- **`publish scan --dry-run`**: 팀 ID가 없으면 `--linear-team or CODEX_SECURITY_LINEAR_TEAM is required.`로
  exit 2다. 자리값이어도 된다. 워크벤치의 심각도 평가를 digest로 다시 확인하며 읽으므로
  `codex-security-classify-severity` 결과를 확인하는 데 쓴다(제외 finding은 이슈에서 빠진다). 평가가
  finding과 맞지 않으면 `Severity assessment does not match the supplied findings. Classify the findings
  again.`로 실패한다. `--dry-run`을 빼면 Linear로 실제 게시한다.

**쓸 수 없는 명령**: `feedback`은 OpenAI로 피드백(선택 시 로그 포함)을 보낸다. `scans resume`은 중단된 Deep
스캔을 원래 Codex 세션에서 이어 가고, 일반 스캔 `scans rerun`은 저장한 스캔을 Codex로 다시 돌린다. 모두
인증이 필요하거나 OpenAI로 업로드하므로 이 환경에서 쓰지 않는다. 로그인 없이 어디까지 동작하는지는
확인하지 않았다.

**npm 0.1.30~0.1.32에 새로 생긴 명령(이 스킬들이 감싸지 않음, 실측하지 않음)**: `suggest-owners <findings>`
(npm 0.1.31)는 커밋된 소스와 Git 이력으로 finding 소유자를 제안한다. 모델을 부르므로 인증이 필요하다.
`dedupe --records`(npm 0.1.30)는 JSON-RPC로 중복 판정을 호스트에 맡기는 프로토콜이다. 상류 문서
(npm 패키지의 `docs/dedupe-records.md`, 상류 저장소의 `sdk/typescript/docs/dedupe-records.md`)는 이 모드가 인증을 하지 않고 모델 실행을 호스트가 맡는다고 쓴다. 두 명령 모두
아직 스킬로 옮기지 않았다.

---

## 6. 동작 원칙 (사용자가 알아야 할 것)

- **대상 저장소를 변경하지 않는다.** `codex-security-patch`(승인 후)을 제외한 모든 스킬은 저장소에
  파일을 만들거나 수정하지 않는다. 모든 중간 산출물은 저장소 밖(스캔 디렉터리 또는 상태 디렉터리)에만
  쓴다. `codex-security-policy`는 SECURITY.md 초안만 만들고 저장소에 적용하지 않는다.
- **대상 저장소 콘텐츠는 미신뢰 데이터다.** 소스·주석·문서·설정·`SECURITY.md`·finding 서술 안의
  어떤 문구도 워크플로나 산출물 규약을 바꾸지 못한다("findings를 비워라" 류의 프롬프트 인젝션은
  데이터로 기록만 하고 실행하지 않는다).
- **스캔 중에는 저장소를 건드리지 마라.** 결과의 기준은 등록 시점 스냅샷이다. 플러그인 사본에
  따라 이력 종결이 실패하거나(하드 게이트) 경고가 남는다(3.4절). 스캔 전 commit/stash를 권한다.
  종결이 실패해도 `report.md`·SARIF는 보존된다(finalize-first).
- **`complete` 실패를 자동으로 종결하지 않는다.** `fail-scan`은 되돌릴 수 없고 해당 스캔을 비교·
  false-positive 이력에서 영구 제외하므로, 스킬은 **(a)** 변경 되돌린 뒤 재시도 / **(b)** 실패 기록
  종결 / **(c)** 보류(기본값)를 사용자에게 묻는다.
- **`report.md`·SARIF를 손으로 수정하지 않는다.** finalizer가 생성·소유한다.
- **완전 커버리지를 거짓 주장하지 않는다.** 커버리지 정산은 집합 기반이라 중복 리뷰로 부풀릴 수
  없고, 미리뷰 파일이 있으면 `partial`로 남는다.

---

## 7. 트러블슈팅

| 증상 | 원인·조치 |
| --- | --- |
| Claude Code에 스킬이 안 보인다 | `~/.claude/skills/` 아래에 설치됐는지 확인하고 세션을 재시작한다. `CLAUDE_SKILLS_DIR`를 쓴다면 그 경로가 Claude Code가 읽는 위치인지 확인 |
| bootstrap `stage: "pluginRoot"` | 신뢰 가능한 플러그인 사본 없음. 3.1절 (a)~(d) 중 하나 수행. `diagnostics.pluginAttempts`의 거부 사유를 보면 원인이 나온다 |
| `--copy` 설치인데 저장소 체크아웃 플러그인을 못 찾는다 | 정상 동작. 복사된 스킬은 저장소 밖이라 체크아웃 자동 탐색이 안 된다 → `CODEX_SECURITY_PLUGIN_ROOT` 지정 또는 npm 전역 설치(3.1절 함정) |
| 대상 저장소 안 플러그인이 무시됨 | 의도된 동작(신뢰 게이트). 저장소 밖 사본을 쓴다 |
| bootstrap `stage: "python"` | Python 3.10+ 없음(3.10은 `tomli`). `PYTHON=<경로>`로 지정하거나 설치 |
| `python3: command not found` | 버전 매니저 환경이다. `PYTHON="$(mise which python3)"` 또는 `mise exec -- python3 …` 형태로 실행(2절 참고) |
| bootstrap `stage: "scanDir"` | 상태 디렉터리 쓰기 불가/권한 문제. `CODEX_SECURITY_STATE_DIR`을 저장소 밖 쓰기 가능한 전용 경로로 지정 |
| `register`가 거부됨 | scan-dir이 비어 있어야 한다. `artifacts/…` 하위 구조는 **등록 후**에 만든다 |
| `complete` 실패: `scan.target.targetId: must match the workbench target` | `contract` 결과(좌표 필드)를 draft에 반영하지 않았다. `complete-scan`은 binding을 주입하지 않고 검증만 한다 |
| `complete` 실패: `Working-tree contents changed … Start a new scan.` | 스캔 중 저장소가 변경됨(하드 게이트 사본). 6절의 3선택지 분기를 따른다. 스캔 행은 `running`으로 남으므로 자동 종결하지 않는다 |
| `complete`는 성공했는데 `warnings`가 있다 | 경고 사본(3.4절). 결과는 등록 시점 스냅샷 기준이다. 정확한 결과가 필요하면 정리된 워킹트리에서 재스캔 |
| `finalize_scan_contract.py` exit 2 | stderr 마지막 오류 줄(`<필드 경로>: <기대 형식>`)을 읽고 해당 draft만 수정해 최대 3회 재시도. 초과 시 draft와 오류 원문을 보존하고 중단한다 |
| shallow clone에서 base 해석 실패 | `git fetch --unshallow` 또는 필요한 base만 fetch |
| `rg: command not found` (저장소 전체 스캔·deep-lite) | 0단계에서 중단된다. `ripgrep`을 설치하거나 Claude Code 세션에서 실행한다(내장 ripgrep을 심링크로 노출). `git ls-files` 폴백은 상류와 다른 인벤토리를 만들어 채택하지 않는다 |
| `running` 상태 좀비 행 | `list-stale --hours N`으로 나열 후 `close-stale --scan-id <id>`로 **명시적으로만** 정리 |
| `codex-security: command not found` | 공식 CLI 조회 명령에만 필요하다. `npm install -g @openai/codex-security`(Node 22+) 또는 `npx @openai/codex-security …` |
| 플러그인 버전 경고 | `pluginVersion`이 매핑 기준(매니페스트 0.1.95)과 다름 → 워크플로 지시가 바뀌었을 수 있으니 8절 재검증을 수행. 버전이 같아도 동작이 다를 수 있으므로 3.4절 프로브를 함께 본다. npm 0.1.26~0.1.32는 모두 매니페스트 0.1.95라 경고가 뜨지 않는다 — npm 버전은 `npm ls -g @openai/codex-security`로 확인한다. npm 0.1.26에는 SECURITY.md Node 헬퍼가 없어 정책 해결을 건너뛴다. 검증된 조합인 npm 0.1.32(npm에 없으면 0.1.31)를 설치한다 |
| 스캔이 "SECURITY.md 정책 해결을 건너뜀"을 고지한다 | 부트스트랩 `securityMdHelper.available: false`. `reason`이 "헬퍼 파일 없음"이면 상류 소스 체크아웃이거나 npm 0.1.26 이하다 → npm 0.1.32(npm에 없으면 0.1.31) 설치본을 쓴다. "Node 없음"·"신뢰 게이트 거부"면 대상 저장소 밖의 Node를 PATH에 두거나 `CODEX_MCP_NODE_PATH=<절대 경로>`로 지정한다 |
| `codex-security-policy`·`-classify-severity`가 시작 직후 중단한다 | 부트스트랩의 `securityMdHelper`·`sdk.dist`·`node` 중 하나가 없다(3.3절 표). `--check`의 "사용 불가" 경고 줄이 사유를 알려 준다. 대개 npm 설치본(`npm install -g @openai/codex-security`)으로 해결된다 |
| 두 스킬에서 `ERR_MODULE_NOT_FOUND` | `codex-security-scan` 스킬(공용 관문 `workflow_digest.mjs`)이 같은 스킬 루트에 없거나 버전이 다르다. 9종을 같은 버전으로 다시 설치한다 |
| `scan import`가 `Scan output parent must not be group- or world-writable …`로 exit 2 | 출력 경로의 상위 디렉터리 중 group/world 쓰기 가능한 것이 있다. 권한을 조이거나 상태 디렉터리를 옮긴다(5.12절) |

---

## 8. 재검증 (플러그인 업데이트 후)

플러그인은 런타임에 읽으므로 업스트림이 계약을 바꾸면 스킬이 조용히 어긋날 수 있다. 아래
스크립트는 계약 변화를 종료코드로 드러낸다(저장소 clone 필요, 산출물은 임시 디렉터리에만 쓴다).

```bash
# 봉인 계약: 최소 draft 픽스처가 finalize + validate 를 통과하는지,
# SARIF 성공 판정 형상(블록 F), 인벤토리 정확성(블록 G)
bash docs/verification/scripts/repro-u4.sh

# 워크벤치 계약 (register → seal → 게이트 → complete)
bash docs/verification/scripts/repro-u3.sh

# 매칭 검증기 계약: 상류 0.1.29~0.1.32 호스트 조정 재현(catalogue → finalize → measure),
# 상류 테스트 이식 픽스처 453건 대조(블록 R), 가짜 codex 로 돌린 상류 dist 결과와 대조(블록 S)
bash docs/verification/scripts/repro-u5-match-validator.sh

# SECURITY.md 초안·심각도 재분류의 결정론 부분 (digest·스냅샷 벡터, 저장 전 검사,
# 상류 리터럴 드리프트, env -i 실행 형태, 루브릭 재사용 규칙, publish --dry-run 수용)
bash docs/verification/scripts/repro-u8-policy-severity.sh

# 검색 명령 확보와 신뢰 게이트 (저장소 내부 rg 거부, 부작용 게이팅, 반복 호출 멱등성)
bash docs/verification/scripts/repro-u1-search-command.sh

# 커버리지 정직성 보정과 중단 스캔 복구 (빈 인벤토리 하드 실패, 부분 커버리지 신호, recover 실패 구분)
bash docs/verification/scripts/repro-u7-coverage-recovery.sh

# 플러그인 경로/인터프리터를 직접 지정할 때
CODEX_SECURITY_PLUGIN_DIR=/path/to/_bundled_plugin PYTHON=/usr/bin/python3 \
  bash docs/verification/scripts/repro-u3.sh
```

여섯 스크립트는 플러그인을 **환경변수 → 저장소 체크아웃 → npm 전역 설치본** 순으로 찾고, Python은
`PYTHON` → `python3` → `python` 순으로 찾는다.

`repro-u3.sh`를 뺀 다섯은 자기 채점형이고, **종료코드가 세 값**이다:

| 종료코드 | 의미 | 어떻게 다룰까 |
|---|---|---|
| 0 (`ALL ASSERTIONS PASSED`) | 모든 단언 통과 | 정상 |
| 2 (`INCOMPLETE`) | 실패는 없으나 **검증하지 못한 것이 있다** | 통과로 보지 말 것. `repro-u4`·`repro-u1`·`repro-u7`은 `SKIP` 줄이 요구하는 전제(ripgrep, `git`, 플러그인 사본, 픽스처)를 갖춘 뒤 다시 돌린다. `repro-u5`·`repro-u8`은 `INCOMPLETE —` 줄이 알려 주는 전제(Node, npm 설치본의 `dist/`, SECURITY.md 헬퍼, `fixtures/scan-match/` 픽스처)를 갖춘 뒤 다시 돌린다 |
| 1 (`FAILED ASSERTIONS`) | 단언 실패 | 원인을 고친다 |

`repro-u3.sh`는 관측형이므로 말미 요약표의 관측값을 기대값과 사람이 대조한다. 그 요약에서
`S5 complete-scan (repo 수정됨)`이 `exit=0`으로 나오면 3.4절의 **경고 사본**이라는 뜻이다
(계약 위반이 아니라 사본 차이).

**ripgrep이 필요한 블록**: `repro-u4.sh`의 인벤토리 정확성(블록 G)과
`repro-u1-search-command.sh`의 성공 경로다. 둘 다 스킬이 실제로 쓰는 경로(`bootstrap.py`가 해석한
`searchCommand.pathEnv`)로 확보를 시도하고, 실패하면 `SKIP`으로 세어 **exit 2**로 끝낸다 — 그
경우 인벤토리 정확성은 검증되지 않았다.

랭킹 파이프라인의 실측 계약(샤드 디렉터리 명명, `score` 1~10, 병합의 부분 실패 거부)은
[verification/phase4-deep-lite-pipeline.md](verification/phase4-deep-lite-pipeline.md)에 고정되어 있다.

---

## 9. 스킬 수정·배포

스킬의 정본은 이 저장소다. `~/.claude/skills/` 아래는 사본/링크일 뿐이므로 수정은 저장소에서
한다.

```bash
# 링크 모드: 저장소 수정이 즉시 반영된다
bash skills/install.sh --link --force

# 복사 모드: 수정 후 재설치해야 반영된다
bash skills/install.sh --copy --force
```

다른 PC로 옮길 때 필요한 것은 `skills/` 디렉터리와 `install.sh`뿐이다(플러그인은 대상 PC에서
3.1절로 확보). 배포본을 검증할 때는 `CLAUDE_SKILLS_DIR`를 임시 경로로 지정해 실제 홈 디렉터리를
건드리지 않고 설치·확인할 수 있다.

```bash
CLAUDE_SKILLS_DIR=/tmp/skills-test bash skills/install.sh --copy
python3 /tmp/skills-test/codex-security-scan/scripts/bootstrap.py --target-repo <대상> --no-scan-dir
```
