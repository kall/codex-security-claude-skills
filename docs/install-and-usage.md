# Claude 보안 스킬 — 설치 및 사용 가이드

**Claude Code만 설치된 PC**에서 이 스킬 6종을 설치해 쓰는 방법을 다룬다. OpenAI/Codex 인증
(ChatGPT 로그인, `OPENAI_API_KEY`)은 **필요하지 않다** — Claude Code 구독 로그인만 있으면 된다.

LLM 두뇌 역할은 Claude Code 세션 자신이 맡고, 검증·ID 파생·봉인·리포트 생성은 `codex-security`
번들 플러그인의 결정론(deterministic) Python 스크립트가 담당한다. 플러그인은 벤더링하지 않고
**설치된 것을 런타임에 찾아 쓴다.**

> **지원 범위**: 이 실행 경로는 비(非) Codex 경로이며 **업스트림 OpenAI 지원 대상이 아니다.**

- 설계 배경과 필수 계약 8개: [solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md](solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md)
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

`--check`가 실행 환경을 프로브해 번들 플러그인 경로·버전·게이트 사본과 Python을 보고한다.
플러그인이 없으면 설치할 명령을 안내한다(**자동 설치는 하지 않는다** — 전역 npm 환경 변경은
사용자 결정이다):

```bash
npm install -g @openai/codex-security                 # Node 22+
bash "$PKG/skills/install.sh" --copy --force --check   # 다시 확인
```

Claude Code를 재시작한 뒤 `/security-scan-local <저장소>` 로 호출한다. 언제든 프로브만 다시
돌릴 수 있다:

```bash
bash "$PKG/skills/install.sh" --check-only
```

수동 설치(저장소 clone)나 세부 옵션은 3절을 본다.

---

## 1. 스킬 목록

| 스킬 | 용도 | 저장소 변경 |
| --- | --- | --- |
| `security-scan-local` | 저장소 전체 1회 표준 스캔 → 봉인 계약 산출물 + `report.md` + SARIF | 없음 |
| `security-diff-scan-local` | 변경분(커밋/브랜치 refs 또는 working-tree)만 스캔 | 없음 |
| `security-validate-local` | 후보 finding 진위 판정(disposition) | 없음 |
| `security-patch-local` | 보안 이슈 최소 수정 — **2단 승인** | **있음(승인 후)** |
| `security-scan-match-local` | 완료된 스캔 2개 사이 동일 근본 원인 finding 매칭 | 없음 |
| `security-deep-scan-local` | 다중 패스 심층 스캔의 축소판(**deep-lite** — 공식 deep과 비동등) | 없음 |

`security-scan-local`이 공통 규칙의 정본이다(bootstrap, 금지 필드, 커버리지 정산, 리페어 루프,
워크벤치 수명주기). 나머지는 차이점만 정의하고 이를 참조한다.

---

## 2. 사전 요구사항

새 PC에서 아래 4개만 확인하면 된다.

```bash
claude --version     # Claude Code (구독 로그인 완료 상태)
python3 --version    # 3.10 이상 (3.10 이면 tomli 도 필요: pip install tomli)
git --version        # 필수
node --version       # 22 이상 — 3.1절 플러그인 npm 설치에 필요
```

| 항목 | 요구 | 없을 때 |
| --- | --- | --- |
| Claude Code | 구독 로그인 세션 | OpenAI 키는 불필요하며 설정해도 쓰이지 않는다 |
| Python | 3.10+ (3.10은 `tomli`) | 설치 후 `PYTHON=<경로>`로 지정 가능 |
| git | 필수 | 대상 해석·diff·인벤토리 폴백에 사용 |
| Node.js | 22+ | 플러그인을 npm 대신 3.1절 (c)·(d) 방법으로 확보하면 불필요 |
| ripgrep (`rg`) | 선택 | 없으면 `git ls-files`로 자동 폴백(그 사실이 보고에 남는다) |

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

# (c) 저장소 체크아웃 사용 (Node 불필요)
git clone https://github.com/openai/codex-security
#   → <clone>/sdk/typescript/_bundled_plugin

# (d) 이미 어딘가에 사본이 있으면 경로를 직접 지정 (셸 프로필에 넣어두면 편하다)
export CODEX_SECURITY_PLUGIN_ROOT=/path/to/_bundled_plugin
```

**중요 — (c)를 쓸 때의 함정**: 저장소 체크아웃 후보는 **스킬 스크립트 위치의 상위 디렉터리**에서만
탐색한다. 즉 3.2절에서 스킬을 `~/.claude/skills/`로 **복사**하면 그 사본은 저장소 밖에 있으므로
체크아웃 자동 탐색이 되지 않는다. (c)를 쓰려면 `--link` 모드로 설치하거나 `CODEX_SECURITY_PLUGIN_ROOT`
(또는 `CODEX_SECURITY_SDK_REPO=<clone 경로>`)를 지정하라.

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
| `--check` | 설치 후 플러그인·Python·게이트 사본을 프로브해 보고. 플러그인이 없으면 exit 1 + 설치 명령 안내(자동 설치 없음) |
| `--check-only` | 설치를 건너뛰고 프로브만 수행 |
| `--force` | 대상 경로가 이미 있을 때 덮어쓰기 |

스킬 이름을 인자로 주면 일부만 설치할 수 있지만, `bootstrap.py`는 `security-scan-local`에만
있고 모든 스킬이 이를 참조하므로 **6종 전체 설치를 기본으로 두라**.

설치 위치는 `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/<스킬이름>`이다. 대상 경로가 이미 있으면
설치를 **거부**하며 `--force`로만 덮어쓴다.

| 모드 | 동작 | 용도 |
| --- | --- | --- |
| `--copy` | 실제 복사본 | 다른 PC 배포. 저장소를 지워도 동작한다. 갱신은 `--copy --force` 재설치 |
| `--link` (기본) | 저장소 디렉터리로 심볼릭 링크 | 스킬 개발. 저장소 수정이 즉시 반영된다 |

복사 모드로 설치했다면 저장소 clone은 지워도 되지만, 3.1절 (c) 자동 탐색과 8절 재검증
스크립트는 저장소가 있어야 쓸 수 있다.

### 3.3 설치 확인

Claude Code를 재시작하고 스킬 목록에 6종이 보이는지, 그리고 부트스트랩이 플러그인을 찾는지
확인한다.

```bash
ls "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" | grep security-

python3 "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/security-scan-local/scripts/bootstrap.py \
  --target-repo /path/to/target-repo --no-scan-dir
```

새 PC(mise·저장소 없음, npm 전역 설치)에서의 실측 성공 출력:

```json
{
  "ok": true,
  "pluginRoot": "<npm root -g>/@openai/codex-security/_bundled_plugin",
  "pluginVersion": "0.1.14",
  "pluginSource": "npm-global",
  "python": { "path": "/usr/bin/python3.14", "version": "3.14.4", "source": "python3" },
  "scanDir": null,
  "scansRoot": null,
  "stateDir": "/home/<user>/.codex/state/plugins/codex-security",
  "repoRoot": "/path/to/target-repo",
  "diagnostics": { "pluginAttempts": [ { "source": "npm-global", "result": "accepted", "pluginVersion": "0.1.14" } ] }
}
```

`ok: false`면 `stage`(`pluginRoot` / `python` / `scanDir` / `arguments`)와 `error`의 한국어 안내를
그대로 따른다. `diagnostics.pluginAttempts`에 후보별 채택/거부 사유가 남으므로 왜 못 찾았는지
바로 알 수 있다.

### 3.4 플러그인 사본별 동작 차이 확인 (권장)

**`pluginVersion`만으로는 동작을 구분할 수 없다.** npm 배포본(`@openai/codex-security@0.1.3`)과
GitHub 저장소 체크아웃이 **둘 다 플러그인 매니페스트 0.1.14를 보고하면서 워킹트리 게이트 동작이
다르다**(실측). 아래로 내 PC가 어느 쪽인지 확인해 둔다.

```bash
PLUGIN=$(python3 "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/security-scan-local/scripts/bootstrap.py \
  --target-repo /path/to/target-repo --no-scan-dir | python3 -c 'import json,sys;print(json.load(sys.stdin)["pluginRoot"])')

grep -q "def require_unchanged_target" "$PLUGIN/scripts/workbench_db.py" \
  && echo "하드 게이트 사본: 스캔 중 저장소가 변경되면 이력 종결(complete)이 실패한다" \
  || echo "경고 사본: 변경돼도 종결은 성공하고 경고만 남는다(결과는 등록 시점 스냅샷 기준)"
```

| 사본 | 스캔 중 워킹트리 변경 후 종결 시 | 실측 메시지 |
| --- | --- | --- |
| GitHub 저장소 체크아웃 | `complete-scan` **실패**(스캔 행은 `running` 유지) → 스킬이 3선택지를 묻는다 | `Working-tree contents changed while the scan was running. Start a new scan.` |
| npm 배포본 0.1.3 | **성공 종결 + 경고** | `Working-tree contents changed while the scan was running; results were saved for the original snapshot.` |

두 사본은 게이트 조건(등록 시 저장한 스냅샷 다이제스트 비교)은 같고 **위반 시 처리만** 다르다
(하드 실패 vs 경고). 어느 쪽이든 스킬은 정직하게 보고한다 — 실패면 3선택지를 묻고, 경고면 그
문구를 최종 보고에 그대로 싣는다(둘 다 실측 확인).

다만 **결과의 기준 시점은 등록 시점 스냅샷**이므로, 정확한 스캔을 원하면 사본과 무관하게 스캔 전
commit/stash를 권한다.

### 3.5 제거

```bash
rm -rf "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/security-{scan,validate,patch,diff-scan,scan-match,deep-scan}-local
npm uninstall -g @openai/codex-security   # 플러그인까지 지울 때
```

스캔 이력·산출물은 `~/.codex/state/plugins/codex-security/`에 남으므로 필요하면 별도로 지운다.

---

## 4. 환경변수

전부 선택이다. 기본값으로 동작한다.

| 변수 | 역할 |
| --- | --- |
| `CODEX_SECURITY_PLUGIN_ROOT` | 플러그인 루트 직접 지정(탐색 생략) |
| `CODEX_SECURITY_SDK_REPO` | 저장소 체크아웃 경로 지정(`<경로>/sdk/typescript/_bundled_plugin` 사용) |
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
/security-scan-local /path/to/target-repo
/security-diff-scan-local --diff origin/main
/security-patch-local docs/finding.md
```

```
"이 저장소 전체를 보안 스캔해줘"          → security-scan-local
"이번 브랜치 변경분만 보안 검토해줘"       → security-diff-scan-local
"이 finding이 진짜 취약점인지 판정해줘"    → security-validate-local
```

**대상 저장소 루트를 명시하라.** 생략하면 cwd의 git 최상위로 추정하는데, 모노레포 하위
패키지에서 호출하면 신뢰 경계가 좁아진다.

첫 실행 때 Claude가 사용자에게 알리는 것: 선택된 플러그인의 절대 경로와 `pluginVersion`,
그리고 스캔 중 저장소를 건드리지 말라는 권고. 부트스트랩이 실패하면 원인과 조치를 한국어로
안내하고 중단한다.

### 5.2 표준 전체 스캔 — `/security-scan-local`

```
/security-scan-local /path/to/target-repo
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

### 5.3 변경분 스캔 — `/security-diff-scan-local`

| 인자 | 대상 | base / head |
| --- | --- | --- |
| `--diff BASE [--head HEAD]` | 커밋/브랜치 refs | base=BASE, head=HEAD(기본 현재 HEAD) |
| `--working-tree [--base REF]` | 스테이지+미스테이지 로컬 패치 | base=REF(기본 HEAD) |
| (인자 없음) | working-tree | base=HEAD |

```
/security-diff-scan-local --diff origin/main
/security-diff-scan-local --diff v1.2.0 --head HEAD
/security-diff-scan-local --working-tree
```

위협 모델은 **저장소 전체 범위**에서, 리뷰는 **diff 범위**에서 수행한다. working-tree 스캔은
등록 시점의 워킹트리 다이제스트가 기준이므로 **스캔이 끝날 때까지 파일을 저장하지 마라**
(플러그인 사본에 따라 이력 종결이 실패하거나 경고가 남는다 — 3.4절).

### 5.4 finding 판정 — `/security-validate-local`

```
/security-validate-local <scanDir>/artifacts/02_discovery/candidate_ledger.jsonl   # ledger 모드
/security-validate-local "src/db.py:42 의 f-string SQL 조립이 SQLi 인지 판정"        # 단독 모드
```

- **ledger 모드**: 원장의 모든 행에 `validation` 객체를 하나씩 추가하고, discovery 필드와 행
  순서를 보존하며 원자적으로 재작성한다. 이미 판정된 행은 재판정 여부를 먼저 묻는다.
- **단독 모드**: 같은 판정 구조를 한국어 보고서로 출력한다.

disposition은 `reportable` / `suppressed` / `not_applicable` / `deferred` 4값이다. 데모·테스트·로컬
전용이라는 이유로 실제 버그를 기각하지 않는다.

### 5.5 이슈 수정 — `/security-patch-local` (2단 승인)

```
/security-patch-local <finding 서술 파일 또는 텍스트>
```

이 시리즈에서 **유일하게 저장소를 변경하고 저장소가 정의한 코드를 실행**할 수 있는 스킬이다.

1. **1단 승인 — 수정 diff**: 최소 수정안을 diff로 제시하고, 승인 후에만 적용한다. 거부하면
   저장소는 무변경으로 남는다.
2. **2단 승인 — 게이트 실행**: 저장소가 정의한 테스트/체크 명령(`package.json`의 `scripts.test`,
   `Makefile` 타깃, `.pre-commit-config.yaml` 등)은 **대상 저장소가 완전히 제어하는 임의 코드**다.
   명령 원문과 정의 파일 경로를 보여주고 **별도 승인**을 받으며, 기본값은 미실행이다.

outcome은 `fixed`(수정 적용 **및 게이트 통과**) / `no_change`(이미 안전함이 증거로 확인) /
`blocked`(재현 불가·동작 변경 유발·정책 결정 필요) 3값이다. 게이트를 실행하지 않았으면 `fixed`로
보고하지 않고 "게이트 미실행"을 명시한다.

> 세션 퍼미션이 `acceptEdits`/`bypassPermissions`면 편집·실행이 프롬프트 없이 진행되므로, 그때는
> **SKILL.md의 2단 승인 지침이 유일한 게이트**다. 스킬은 이 사실을 먼저 고지한다. 보안 수정을
> 검토하며 진행하려면 기본 퍼미션 모드에서 쓰는 편이 안전하다.

### 5.6 스캔 간 매칭 — `/security-scan-match-local`

```
/security-scan-match-local <before-scan-id> <after-scan-id>
```

완료(sealed) 스캔 2개 사이에서 제목·CWE·fingerprint·위치가 달라도 **동일 근본 원인·동일 수정으로
해결되는** finding을 그룹화해 이력을 연결한다(공식 `scans match` 대체 — 그 명령은 SDK가 Codex
스레드를 직접 여는 유일한 지점이라 OpenAI 인증 없이는 막혀 있다).

매칭 입력에는 대상 저장소 코드에서 파생된 텍스트가 그대로 들어가므로, 판정은 **도구를 제한한
격리 서브에이전트**(파일 쓰기·Bash·네트워크 없음, JSON만 반환)가 수행한다. 저장 전
`validate_matches.py` 검증을 반드시 통과시키고, 거부되면 사유를 전달해 재판정한다. 저장 후:

```bash
codex-security scans compare <before-scan-id> <after-scan-id>
```

두 스캔 모두 5.7절 워크벤치 등록을 거쳐야 하며, 일괄 매칭(`--all`)은 지원하지 않는다(쌍 단위만).

### 5.7 deep-lite 스캔 — `/security-deep-scan-local`

```
/security-deep-scan-local /path/to/target-repo
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

### 5.8 워크벤치 이력 통합 (선택)

스캔을 공식 CLI 이력과 호환시키려면 워크벤치 상태 DB에 등록·종결한다. 순수 로컬 스캔만 원하면
건너뛰면 되고, 그 스캔은 `scans list`에 나타나지 않는다. 스킬에 "이력에 등록해줘"라고 말하면
아래를 알아서 수행한다.

순서 계약: `check-running` → **`register`(빈 scan-dir)** → 하위 구조 생성 → **`contract`** →
`feedback` → (스캔 수행) → 정산 → **finalize → `complete`**.

```bash
python3 "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"/security-scan-local/scripts/workbench_glue.py \
  --bootstrap <bootstrap.json> <서브커맨드> [옵션]
```

| 서브커맨드 | 용도 |
| --- | --- |
| `check-running` | 같은 저장소의 `running` 행 advisory 경고(차단 아님) |
| `register [--mode standard\|diff\|deep] [--paths …]` | 스캔 등록. **scan-dir이 비어 있어야** 성공 |
| `contract --scan-id <id>` | draft가 사전 일치시켜야 하는 좌표 필드 조회 |
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

---

## 6. 동작 원칙 (사용자가 알아야 할 것)

- **대상 저장소를 변경하지 않는다.** `security-patch-local`(승인 후)을 제외한 모든 스킬은 저장소에
  파일을 만들거나 수정하지 않는다. 모든 중간 산출물은 스캔 디렉터리 아래에만 쓴다.
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
| `rg: command not found` | `git ls-files` 폴백으로 자동 진행(그 사실이 보고에 남는다) |
| `running` 상태 좀비 행 | `list-stale --hours N`으로 나열 후 `close-stale --scan-id <id>`로 **명시적으로만** 정리 |
| `codex-security: command not found` | 공식 CLI 조회 명령에만 필요하다. `npm install -g @openai/codex-security`(Node 22+) 또는 `npx @openai/codex-security …` |
| 플러그인 버전 경고 | `pluginVersion`이 매핑 기준(0.1.14)과 다름 → 워크플로 지시가 바뀌었을 수 있으니 8절 재검증을 수행. 버전이 같아도 동작이 다를 수 있으므로 3.4절 프로브를 함께 본다 |

---

## 8. 재검증 (플러그인 업데이트 후)

플러그인은 런타임에 읽으므로 업스트림이 계약을 바꾸면 스킬이 조용히 어긋날 수 있다. 아래
스크립트는 계약 변화를 종료코드로 드러낸다(저장소 clone 필요, 산출물은 임시 디렉터리에만 쓴다).

```bash
# 최소 draft 픽스처가 finalize + validate 를 통과하는지
bash docs/verification/scripts/repro-u4.sh

# 워크벤치 계약 (register → seal → 게이트 → complete)
bash docs/verification/scripts/repro-u3.sh

# 플러그인 경로/인터프리터를 직접 지정할 때
CODEX_SECURITY_PLUGIN_DIR=/path/to/_bundled_plugin PYTHON=/usr/bin/python3 \
  bash docs/verification/scripts/repro-u3.sh
```

두 스크립트는 플러그인을 **환경변수 → 저장소 체크아웃 → npm 전역 설치본** 순으로 찾고, Python은
`PYTHON` → `python3` → `python` 순으로 찾는다.

`repro-u3.sh`의 요약에서 `S5 complete-scan (repo 수정됨)`이 `exit=0`으로 나오면 3.4절의 **경고
사본**이라는 뜻이다(계약 위반이 아니라 사본 차이).

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
python3 /tmp/skills-test/security-scan-local/scripts/bootstrap.py --target-repo <대상> --no-scan-dir
```
