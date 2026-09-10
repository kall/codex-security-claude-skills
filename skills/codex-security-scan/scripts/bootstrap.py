#!/usr/bin/env python3
"""codex-security-scan 스킬의 단일 부트스트랩 스크립트.

네 가지를 한 번에 결정하고 그 결과를 JSON 한 덩어리로 stdout에 출력한다.

  1. 신뢰할 수 있는 Codex Security 번들 플러그인 루트 (+ pluginVersion)
  2. 플러그인을 실행할 Python 인터프리터 (3.10+; 3.10은 tomli 필요)
  3. 스캔 산출물 디렉터리(scanDir) — 대상 저장소 **밖**, 0700, 비어 있음
  4. 신뢰 게이트를 통과한 검색 명령(ripgrep) — `--require-search`/`--probe-search` 일 때만.
     상류 인벤토리 스크립트가 `rg` 를 PATH 에서만 해석하므로 PATH 통로를 만들어 준다.
     함께 내보내는 `trustedPathEnv` 는 대상 저장소 내부 항목을 제거한 PATH 다 —
     플러그인 스크립트를 자식 프로세스로 돌릴 때 원시 $PATH 대신 이 값을 쓴다.

이 JSON이 이후 모든 단계(register-cli-scan, 산출물 작성, finalize)의 경로
source-of-truth 다. 스킬 문서는 이 스크립트를 한 번 호출하고 그 결과만 사용한다.

참조 구현(수정하지 않고 모방한다):
  - sdk/typescript/src/runtime.ts
      bundledPluginRoot() / hasPluginManifest() / pluginMetadata()
      resolvePluginPython() / usablePython()
      codexSecurityStateDirectory() / preparePersistentScanRoot() / safePrefix()
  - sdk/typescript/src/trusted-executable.ts: resolveTrustedExecutable()
  - sdk/typescript/src/api.ts: requireOutputOutsideRepository()

핵심 보안 규칙(KTD4): 스캔 대상 저장소는 신뢰할 수 없는 코드다.
  - 대상 저장소 안의 어떤 경로도 플러그인 루트/Python 인터프리터로 채택하지 않는다.
  - 스캔 산출물도 대상 저장소 안에 쓰지 않는다(대상 코드가 산출물을 조작 가능).

사용법:
    python3 bootstrap.py [--target-repo PATH] [--skip-python]
                         [--scan-dir PATH | --no-scan-dir]
                         [--require-search | --probe-search]

성공: exit 0 + {"ok": true, ...} (SUCCESS_KEYS 참고)
실패: exit 1 + {"ok": false, "stage": ..., "error": <한국어 안내>, ...}
      stage 는 arguments / pluginRoot / python / searchCommand / trustedPathEnv /
      scanDir 중 하나다.

산출물 파일 권한 규약: 본 스크립트는 **디렉터리만** 0700으로 만든다.
이후 단계에서 scanDir 안에 만드는 파일(scan-manifest.json, findings.json,
coverage.json, report.md, *.sarif 등)은 0600으로 생성해야 한다
(예: os.open(path, O_WRONLY|O_CREAT|O_EXCL, 0o600) 또는 umask 077).
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import glob
import json
import os
import re
import stat
import shlex
import subprocess
import sys
from pathlib import Path

PLUGIN_NAME = "codex-security"
NPM_PACKAGE = "@openai/codex-security"
MANIFEST_RELATIVE = Path(".codex-plugin") / "plugin.json"
MAX_PLUGIN_MANIFEST_SIZE = 1024 * 1024  # runtime.ts: MAX_PLUGIN_MANIFEST_SIZE
PLUGIN_ROOT_ENV = "CODEX_SECURITY_PLUGIN_ROOT"
STATE_DIR_ENV = "CODEX_SECURITY_STATE_DIR"
CODEX_HOME_ENV = "CODEX_HOME"
MAX_ANCESTOR_DEPTH = 8  # sdk-repo 후보 탐색 시 조상 디렉터리 상한

DIR_MODE = 0o700  # scanDir/scansRoot/stateDir 권한
ARTIFACT_MODE = 0o600  # 이후 단계가 만드는 산출물 파일 권한(문서화용 상수)
MAX_SCAN_DIR_ATTEMPTS = 50  # 같은 초에 여러 번 호출될 때 접미사 재시도 상한

# 검색 명령(ripgrep) 해석. 상류 generate_in_scope_files.py 는 `rg` 를 하드코딩하고
# 경로를 받는 인자가 없으므로, 전달 통로는 자식 프로세스의 PATH 뿐이다.
SEARCH_COMMAND = "rg"
CLAUDE_EXECPATH_ENV = "CLAUDE_CODE_EXECPATH"
RIPGREP_MARKER = "ripgrep"  # `rg --version` 첫 줄에 반드시 있는 문자열
SEARCH_SHIM_BASENAME = "search-shim"
# rg 는 이 변수가 가리키는 파일의 플래그를 무조건 적용한다. 상류 인벤토리
# 스크립트는 `--no-config` 를 주지 않으므로, 저장소가 환경을 얹을 수 있는
# 상황(.envrc/direnv 등)에서 `--glob '!src/**'` 같은 플래그로 커버리지 분모를
# 조용히 줄일 수 있다. 실측(u4 픽스처, 축을 구분해서): `--glob=!src/**` 는 rg 열거를
# 3→1 로, 커버리지 분모를 4→2 로 줄인다. `--glob=!*` 면 rg 열거는 0 이지만 분모는
# git add-back(추적 AND gitignore된 파일)이 남아 **1** 이다 — 분모가 진짜 0 이 되는
# 것은 그 집합이 빈 저장소에서뿐이고, 그때는 정산이 exit 3 으로 잡는다. 상류는
# rg 의 exit 1 을 정상으로 받아 경고를 남기지 않는다. `--pre` 류 실행 플래그는
# rg 가 파일 내용을 읽는 검색 모드에서만 발동하고 `rg --files`·`rg --version`
# 에서는 실행되지 않으므로(실측), 이 파이프라인의 위협면은 분모 조작이다.
# PATH 만 정화하고 이 변수를 남기면 정화가 반쪽이 된다.
RIPGREP_CONFIG_ENV = "RIPGREP_CONFIG_PATH"

# 자식 환경은 **허용 목록**으로 짠다. 거부 목록은 구조가 틀렸다 — 위협면이
# "우리가 부르는 서드파티 바이너리(git/npm/python/rg)가 읽는 임의의 환경변수"
# 이므로 열거는 상류 버전이 올라갈 때마다 뒤처진다. 실제로 거부 목록을 2개에서
# 8개로 늘렸는데도 더 강한 채널 셋이 그대로 남아 있었다(전부 재현):
#   - GIT_CONFIG_COUNT/GIT_CONFIG_KEY_* → `core.fsmonitor` 로 임의 명령 실행.
#     대상은 상류가 `cwd=대상 저장소` 로 돌리는 바로 그 `git ls-files` 다.
#   - GIT_DIR/GIT_WORK_TREE → `git rev-parse --show-toplevel` 을 하이재킹해
#     **신뢰 경계 자체**를 옮긴다(저장소 내부 rg 가 채택된다).
#   - NODE_OPTIONS="--require <저장소 JS>" → `npm root -g` 자식에서 실행.
# `TZ` 는 넣지 않는다 — glibc 는 그것을 **tzfile 경로**로 해석한다(`TZ=:/path`
# 또는 `TZ=/path`). 즉 경로형 값이므로 `CHECKED_PATH_ENV` 와 같은 저장소-밖 검사
# 없이는 통과시킬 수 없는데, 정당한 소비자가 없어 검사를 붙이는 대신 통째로
# 제외했다: 자식은 `git ls-files`·`git diff`·`rg`·`npm root -g`·`python` 이고
# `LC_ALL=C` 를 강제하므로 TZ 에 의존하지 않으며, 산출물 타임스탬프는 부모가
# 만든다. (구체적 악용 경로를 실측한 것은 아니다 — 방어적 제외다. 한때 이 자리에
# `git log` 날짜 필터를 근거로 적었는데, 스킬·번들 플러그인 어디에도 `git log`
# 호출이 없어 성립하지 않는 서술이었다.)
PROBE_CHILD_ENV_ALLOW = ("LANG", "TERM", "SYSTEMROOT")

# 경로 값이라 통과 전에 대상 저장소 밖임을 확인해야 하는 것. `TMPDIR` 을 무검증
# 통과시키면 저장소가 그것을 자기 안으로 돌려 (a) 상류의 `tempfile.TemporaryFile()`
# 스테이징 위치를 정하고 (b) `tempfile.gettempdir()` 를 경유해 프로브 HOME 까지
# 저장소 내부로 만든다(실측). 경로형 변수만 검사를 면제하는 것은 재설계의 논리와
# 어긋난다.
CHECKED_PATH_ENV = ("TMPDIR",)

# 정당한 용도가 없어 통째로 버리는 것 (순수 코드 주입 채널). 허용 목록 방식에서는
# pop 할 대상이 없지만, "왜 허용 목록인가"의 근거로 열거를 남긴다.
HARD_DROP_ENV = (
    "LD_PRELOAD",
    "LD_AUDIT",
    "DYLD_INSERT_LIBRARIES",
    "GCONV_PATH",
    "BASH_ENV",
)

# 경로 목록이라 통째로 버리면 정상 환경이 깨질 수 있는 것 — 커스텀 libdir 로 링크된
# 인터프리터(conda·수동 빌드)는 이 변수에 의존할 수 있다. 저장소 내부 항목만
# 걷어내 위험과 가용성을 함께 잡는다. (이 환경의 rg 14.1.1·claude-shim 은 변수
# 없이도 동작하므로, "없으면 깨진다"는 재현 조건을 특정하지 못해 단정하지 않는다.)
FILTERED_PATHLIST_ENV = ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH")

# 제어문자를 담은 값은 통과시키지 않는다. 이 값들은 소비자 셸 명령으로 보간되고,
# 개행이 들어가면 인용으로도 안전을 보장하기 어렵다.
_CONTROL_CHARS = frozenset(chr(c) for c in range(32)) | {"\x7f"}


def env_value_safe(value: str) -> bool:
    """자식 환경·소비자 계약에 실어도 되는 값인가.

    제어문자 외에 **surrogateescape** 도 배제한다. `os.environ` 은 비-UTF8 바이트를
    U+DC80~U+DCFF 범위의 서로게이트로 담는데, 그것은 제어문자 집합에 없으므로
    필터를 통과한 뒤 `emit()` 의 `json.dumps(ensure_ascii=False)` 에서
    UnicodeEncodeError 로 죽는다 — 문서화한 실패 계약
    (`exit 1 + {"ok": false, "stage": ...}`)이 저장소가 통제하는 값 하나로 깨진다.

    (주의: 이 독스트링에 그 문자를 escape 로 적으면 **파일 자체가** 서로게이트를
    담게 되어 컴파일 단계에서 죽는다 — 실제로 그렇게 만들었다가 고쳤다.)
    """
    if _CONTROL_CHARS & set(value):
        return False
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def sanitize_pathlist(value: str, protected_root: Path) -> str:
    """경로 목록 환경변수에서 대상 저장소를 통해 도달되는 항목을 제거한다."""
    kept: list[str] = []
    for entry in value.split(os.pathsep):
        if not entry or not os.path.isabs(entry):
            continue
        if within_target(protected_root, Path(entry)):
            continue
        resolved = str(real(entry))
        if resolved not in kept:
            kept.append(resolved)
    return os.pathsep.join(kept)


# 저장소의 local git config 가 임의 명령으로 바뀔 수 있는 키. **드라이버 이름은
# 저장소가 커밋한 `.gitattributes` 가 정하므로 고정 키 열거로는 닫을 수 없다** —
# 그래서 이름 부분을 정규식으로 잡고 실제 정의된 키를 열거해 무력화한다(실측:
# `.gitattributes` 에 `* filter=pwn diff=pwn` 을 커밋하고 `.git/config` 에
# `filter.pwn.clean` 을 두면 `git diff --raw` 에서 실행됐다).
_GIT_DRIVER_KEY_RE = re.compile(
    r"^(?:filter\..+\.(?:clean|smudge|process)|diff\..+\.(?:command|textconv))$"
)

# 열거 결과 캐시. 같은 (저장소, PATH) 조합이면 자식 환경을 만들 때마다
# `git config` 를 다시 돌리지 않는다.
_GIT_DRIVER_CACHE: dict[tuple[str, str], tuple[tuple[tuple[str, str], ...], str | None]] = {}


def git_config_overrides(protected_root: Path) -> list[tuple[str, str]]:
    """저장소 local config 의 실행 채널을 못 박는 정적 오버라이드 목록.

    **이 목록의 유일한 정의 지점이다** — `coverage_reconcile.py` 는 사본을 두지
    않고 이 함수를 import 해서 쓴다. 같은 보안 규칙의 두 사본은 반드시 어긋난다.

    전역 `safe.directory` 는 우리가 통제하는 `GIT_CONFIG_*` 로 되돌려 준다(HOME
    재지정으로 잃으면 소유자가 다른 저장소에서 상류 add-back 집합이 경고 없이
    사라지고 diff 모드는 하드 실패한다 — 실측). 그런데 `safe.directory` 가 막는
    것은 정확히 "git 이 저장소 자신의 `.git/config` 를 신뢰하는가"이므로, 강제와
    함께 그것이 여는 문을 닫는다. 환경 config 는 저장소 local 을 덮는다(실측).
    """
    return [
        ("safe.directory", str(protected_root)),
        ("core.fsmonitor", ""),
        ("core.hooksPath", os.devnull),
        ("core.gitProxy", ""),
        ("core.sshCommand", ""),
        ("core.alternateRefsCommand", ""),
        ("core.pager", ""),
        ("diff.external", ""),
        ("uploadpack.packObjectsHook", ""),
    ]


def git_driver_overrides(
    protected_root: Path, base_env: dict[str, str]
) -> tuple[list[tuple[str, str]], str | None]:
    """저장소 local config 에 정의된 filter/diff 드라이버를 열거해 무력화 목록을 만든다.

    `git_config_overrides()` 의 고정 열거로 닫히지 않는 클래스를 닫는다. 반환값은
    (오버라이드 목록, 진단 메모).

    안전성: `git config --local --includes --list` 는 어떤 드라이버도 호출하지
    않는다(실측: 열거만으로는 아무것도 실행되지 않았다). `--includes` 가 필요하다 —
    `--local` 만 주면 `.git/config` 의 `include.path` 로 끌어온 파일에 정의된
    드라이버가 목록에서 빠진다(실측).

    실패(rc != 0)는 **"읽을 local config 가 없다"** 로 취급한다. `config --local`
    은 다른 서브커맨드와 똑같은 저장소 탐색·설정 읽기 경로를 쓰므로, 여기서 읽지
    못하는 설정은 `git diff` 도 읽지 못한다. git 자체가 없으면 채널 자체가 도달
    불가다(상류도 같은 PATH 에서 git 을 해석한다).
    """
    cache_key = (str(protected_root), base_env.get("PATH", ""))
    cached = _GIT_DRIVER_CACHE.get(cache_key)
    if cached is not None:
        return list(cached[0]), cached[1]

    overrides: list[tuple[str, str]] = []
    note: str | None = None
    if not os.path.exists(os.path.join(str(protected_root), ".git")):
        note = None  # git 저장소가 아니다 — local config 가 없다.
    else:
        try:
            completed = subprocess.run(
                [
                    "git", "-C", str(protected_root),
                    "config", "--local", "--includes", "--list", "-z",
                ],
                capture_output=True, text=True, timeout=15, check=False, env=base_env,
            )
        except (OSError, subprocess.SubprocessError) as error:
            note = f"git 드라이버 키 열거 실패(채널 도달 불가로 취급): {error}"
        else:
            if completed.returncode != 0:
                note = "저장소 local git config 를 읽지 못했다(무력화할 드라이버 없음)."
            else:
                seen: set[str] = set()
                for record in completed.stdout.split("\0"):
                    if not record:
                        continue
                    key = record.split("\n", 1)[0]
                    lowered = key.lower()
                    if lowered in seen or not _GIT_DRIVER_KEY_RE.match(lowered):
                        continue
                    if not env_value_safe(key):
                        continue
                    seen.add(lowered)
                    overrides.append((key, ""))
                if overrides:
                    note = (
                        "저장소 local git config 의 filter/diff 드라이버를 무력화했다: "
                        + ", ".join(key for key, _ in overrides)
                    )
    _GIT_DRIVER_CACHE[cache_key] = (tuple(overrides), note)
    return overrides, note


def probe_child_env(
    environ: dict[str, str], protected_root: Path, path_value: str, state_dir: Path
) -> dict[str, str]:
    """서드파티 바이너리를 돌릴 자식 환경을 허용 목록으로 구성한다.

    HOME 재지정만으로는 부족하다 — `GIT_CONFIG_GLOBAL` 등 설정 경로를 **직접**
    무력화한다. 이유가 둘이다:
      1. HOME 은 저장소가 TMPDIR 을 통해 간접 통제할 수 있었다(실측).
      2. `--no-scan-dir` 실행에서는 state_dir 가 아직 없어 존재하지 않는 HOME 을
         내보내게 된다.

    전역 `safe.directory` 는 우리가 통제하는 `GIT_CONFIG_*` 로 되돌려 준다. HOME
    재지정으로 그것을 잃으면 소유자가 다른 저장소(컨테이너 바인드 마운트·CI)에서
    상류 add-back 집합이 **경고 없이** 사라지고 diff 모드는 하드 실패한다(실측).
    `GIT_CONFIG_COUNT` 를 우리가 덮어쓰므로 부모가 얹은 값은 자동으로 무효화된다.

    남는 동작 변경: 사용자 전역 gitignore(`~/.config/git/ignore`,
    `core.excludesFile`)가 적용되지 않아 커버리지 분모가 로컬 git 설정과 달라질 수
    있다(실측: 1→2 파일). 방향은 개선(재현성)이지만 사용자가 아는 편이 낫다 —
    SKILL.md 와 계약 문서에 명기한다.
    """
    child: dict[str, str] = {}
    for key, value in environ.items():
        if key.upper() not in PROBE_CHILD_ENV_ALLOW:
            continue
        if not env_value_safe(value):
            continue
        child[key] = value
    for name in CHECKED_PATH_ENV:
        raw = environ.get(name)
        if not raw or not os.path.isabs(raw):
            continue
        if not env_value_safe(raw) or within_target(protected_root, Path(raw)):
            continue
        child[name] = str(real(raw))
    for name in FILTERED_PATHLIST_ENV:
        raw = environ.get(name)
        if raw and env_value_safe(raw):
            filtered = sanitize_pathlist(raw, protected_root)
            if filtered:
                child[name] = filtered
    child["PATH"] = path_value
    child["HOME"] = str(state_dir)
    child["LC_ALL"] = "C"
    # 설정 경로를 직접 무력화한다(HOME 에 의존하지 않는다).
    child["GIT_CONFIG_NOSYSTEM"] = "1"
    child["GIT_CONFIG_GLOBAL"] = os.devnull
    # npm 은 user/global config 가 **같은 경로**면 "double-loading config" 로 죽는다
    # (실측: 둘 다 /dev/null 로 주면 `npm root -g` 가 exit 1). 서로 다른, 존재하지
    # 않는 경로를 준다 — 없는 파일은 조용히 건너뛴다.
    child["npm_config_userconfig"] = str(state_dir / ".npmrc-none-user")
    child["npm_config_globalconfig"] = str(state_dir / ".npmrc-none-global")
    # 전역 safe.directory 소실을 되돌리면서(순수 회귀였다) 그것이 여는 문을 함께
    # 닫는다 — 근거는 git_config_overrides() 독스트링. 목록은 한 곳에만 둔다.
    #
    # 고정 키 열거로 닫히지 않는 클래스가 하나 남는다: `.gitattributes` 가 이름을
    # 고르는 filter/diff 드라이버다. 그래서 정적 목록으로 환경을 만든 뒤, **그 환경
    # 으로** 저장소 local config 를 열거해 정의된 드라이버 키까지 못 박는다
    # (`git config --list` 는 드라이버를 호출하지 않는다 — 실측).
    _git_overrides = git_config_overrides(protected_root)

    def _apply_git_overrides(pairs: list[tuple[str, str]]) -> None:
        child["GIT_CONFIG_COUNT"] = str(len(pairs))
        for index, (key, value) in enumerate(pairs):
            child[f"GIT_CONFIG_KEY_{index}"] = key
            child[f"GIT_CONFIG_VALUE_{index}"] = value

    _apply_git_overrides(_git_overrides)
    child[RIPGREP_CONFIG_ENV] = ""
    child["PYTHONDONTWRITEBYTECODE"] = "1"
    _driver_overrides, _ = git_driver_overrides(protected_root, dict(child))
    if _driver_overrides:
        _apply_git_overrides(_git_overrides + _driver_overrides)
    return child

# 성공 JSON의 최상위 키(계약). 이후 단계는 이 키만 신뢰한다.
SUCCESS_KEYS = (
    "ok",
    "pluginRoot",
    "pluginVersion",
    "pluginSource",
    "python",
    "trustedPathEnv",
    "trustedChildEnv",
    "trustedChildEnvShell",
    "shellQuoted",
    "searchCommand",
    "scanDir",
    "scansRoot",
    "stateDir",
    "repoRoot",
    "diagnostics",
)

# runtime.ts usablePython()의 인라인 검사 코드를 그대로 복제한다.
PYTHON_CHECK = (
    "import importlib.util,sys\n"
    "if sys.version_info < (3, 10): raise SystemExit(1)\n"
    "if sys.version_info < (3, 11) and importlib.util.find_spec('tomli') is None: raise SystemExit(1)\n"
    "print('codex-security-python-ok')"
)
PYTHON_OK_MARKER = "codex-security-python-ok"

INSTALL_GUIDANCE = (
    "신뢰할 수 있는 Codex Security 번들 플러그인을 찾지 못했습니다. 다음 중 하나를 수행하세요:\n"
    f"  1) 전역 설치:  npm install -g {NPM_PACKAGE}\n"
    f"  2) npx 실행:   npx -y {NPM_PACKAGE} --version   (npx 캐시에 내려받음)\n"
    f"  3) 저장소 체크아웃: git clone https://github.com/openai/codex-security "
    "후 plugins/codex-security(구 레이아웃은 sdk/typescript/_bundled_plugin) 사용\n"
    f"  4) 이미 설치본이 있다면 {PLUGIN_ROOT_ENV}=<플러그인 루트> 로 지정\n"
    "주의: 스캔 대상 저장소 내부(node_modules 포함)의 플러그인 사본은 신뢰하지 않으므로 사용되지 않습니다."
)

SEARCH_GUIDANCE = (
    "전체 스캔 인벤토리는 상류 scripts/generate_in_scope_files.py 가 만들고 그 스크립트는 "
    "ripgrep(`rg`)을 PATH 에서만 해석합니다. 신뢰할 수 있는 `rg` 를 확보하지 못했습니다.\n"
    "  1) ripgrep 설치:  apt install ripgrep / brew install ripgrep / cargo install ripgrep\n"
    f"  2) Claude Code 세션이라면 {CLAUDE_EXECPATH_ENV} 가 실행 가능한 claude 바이너리를 "
    "가리키는지 확인하세요(내장 ripgrep 을 심링크로 노출합니다).\n"
    "주의: 인벤토리는 커버리지 분모이므로 추측으로 만들지 않습니다. `git ls-files` 폴백은 "
    "미추적 파일을 놓쳐 상류와 다른 집합을 만들기 때문에 채택하지 않습니다."
)

PYTHON_GUIDANCE = (
    "번들 Codex Security 플러그인은 Python 3.10 이상을 요구합니다(3.10은 tomli도 필요). "
    "PYTHON 환경변수로 인터프리터를 지정하거나 python3/python 을 PATH에 추가하세요."
)

SCAN_DIR_GUIDANCE = (
    f"스캔 산출물 디렉터리는 대상 저장소 밖의 비어 있는 새 디렉터리여야 하며 권한은 0700 입니다. "
    f"{STATE_DIR_ENV}=<쓰기 가능한 전용 디렉터리> 로 상태 디렉터리를 옮기거나, "
    "--scan-dir 로 조건을 만족하는 경로를 직접 지정하세요."
)


# --------------------------------------------------------------------------
# 경로 유틸
# --------------------------------------------------------------------------
def real(path: os.PathLike[str] | str) -> Path:
    """realpath. 존재하지 않으면 절대경로로 정규화만 한다 (trusted-executable.ts 동일)."""
    try:
        return Path(os.path.realpath(str(path)))
    except OSError:
        return Path(os.path.abspath(str(path)))


def is_within(root: Path, candidate: Path) -> bool:
    """candidate가 root와 같거나 root 하위인가 (trusted-executable.ts isWithin)."""
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def literal(path: os.PathLike[str] | str) -> Path:
    """심볼릭 링크를 따라가지 않고 정규화만 한 절대경로."""
    return Path(os.path.abspath(os.path.expanduser(str(path))))


def same_dir(a: Path, b: Path) -> bool:
    """두 경로가 같은 디렉터리인가 (st_dev, st_ino 동일성).

    문자열 비교로는 못 잡는 것을 잡는다 — 대소문자 무시 파일시스템
    (APFS/HFS+/NTFS)에서 `/Users/me/Proj` 와 `/users/me/proj` 는 같은
    디렉터리인데 `Path.relative_to` 는 어휘적·대소문자 구분 비교라 다르다고 본다.
    bind mount 로 같은 트리를 두 경로에 노출한 경우도 여기서 걸린다.
    """
    try:
        sa, sb = a.stat(), b.stat()
    except OSError:
        return False
    return (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino)


def within_target(target_repo: Path, candidate: Path) -> bool:
    """후보가 대상 저장소 내부(= 신뢰할 수 없음)인가. True이면 거부해야 한다.

    "저장소를 **통해서** 도달되는가"를 판정한다. 세 번을 고쳤고 그때마다 우회가
    남았으므로, 지금은 원본 표기의 **성분 접두사를 하나씩 늘려 가며** 각 단계를
    realpath 로 해석한다. 이 형태여야 하는 이유:

      - realpath 만 보면 저장소가 커밋한 심링크(`repo/evilbin -> /outside`)가
        통과한다(1차 우회).
      - 리터럴만 더해도 저장소가 별칭 경로로도 도달 가능하면 통과한다
        (`/alias/proj/evilbin`, 2차 우회).
      - **정규화된 리터럴의 조상을 순회하는 것으로도 부족하다.** `abspath` 는
        `..` 를 심링크 해석 **전에** 어휘적으로 접어버리므로,
        `/proc/self/cwd/sub/../../proj/evilbin` 처럼 저장소를 통과한 뒤 `..` 로
        빠져나가는 표기는 저장소 접두사가 사라진다(3차 우회, 종단간 재현).
        성분을 하나씩 붙여 매 단계 realpath 하면 `..` 가 적용되기 **전에**
        저장소를 지나갔다는 사실이 드러난다.

    비교는 `is_within`(어휘) 과 `same_dir`(inode) 를 함께 쓴다 — 후자가 대소문자
    무시 파일시스템과 bind mount 를 덮는다.
    """
    if is_within(target_repo, real(candidate)):
        return True

    raw = Path(os.path.expanduser(str(candidate)))
    if not raw.is_absolute():
        raw = Path(os.getcwd()) / raw
    prefix = Path(raw.anchor or os.sep)
    # parts[0] 은 anchor 다. 나머지를 순서대로 붙이며 매 단계 해석한다.
    for part in raw.parts[1:]:
        prefix = prefix / part
        resolved = real(prefix)
        if is_within(target_repo, resolved) or same_dir(resolved, target_repo):
            return True
    return is_within(target_repo, literal(candidate))


def expand_home(value: str) -> str:
    """runtime.ts expandHome(). `~` 와 `~/`(또는 `~\\`)만 확장한다(`~user` 아님)."""
    if value == "~":
        return str(Path.home())
    if value.startswith("~/") or value.startswith("~\\"):
        return str(Path.home() / value[2:].lstrip("/\\"))
    return value


def safe_prefix(value: str) -> str:
    """runtime.ts safePrefix(). 파일명에 안전한 저장소 이름."""
    return re.sub(r"[^A-Za-z0-9._-]", "-", os.path.basename(value.rstrip("/\\"))) or "repository"


def untrusted_provenance(canonical: Path) -> str | None:
    """채택 후보의 소유권/권한이 신뢰할 수 없으면 사유를 반환한다.

    다른 사용자 소유이거나 **누구나 쓰기 가능**(world-writable)한
    디렉터리·매니페스트는 로컬의 다른 사용자·프로세스가 플러그인 코드를 심을 수
    있으므로 거부한다. group-writable(예: umask 002의 정상 저장소 체크아웃)은
    거부하지 않는다 — 실증된 공격(다른 사용자가 조상 디렉터리에 심는 경우)은
    uid 검사와 world-writable 검사로 이미 차단되고, 공유 그룹 위험은
    보고서의 Residual Risk로 남긴다.
    """
    allowed_uids = {0, os.getuid()} if hasattr(os, "getuid") else set()
    for check in (canonical, canonical / MANIFEST_RELATIVE):
        try:
            info = check.stat()
        except OSError as error:
            return f"권한 확인 실패: {check} ({error})"
        if allowed_uids and info.st_uid not in allowed_uids:
            return f"신뢰할 수 없는 소유자(uid={info.st_uid}): {check}"
        if info.st_mode & stat.S_IWOTH:
            return f"누구나 쓰기 가능한 경로(mode={oct(stat.S_IMODE(info.st_mode))}): {check}"
    return None


def is_regular_file(path: Path) -> bool:
    """runtime.ts isRegularFile(): 심볼릭 링크가 아닌 일반 파일."""
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode)


def has_plugin_manifest(root: Path) -> bool:
    """runtime.ts hasPluginManifest()."""
    return is_regular_file(root / MANIFEST_RELATIVE)


# --------------------------------------------------------------------------
# 매니페스트 검증 (runtime.ts pluginMetadata)
# --------------------------------------------------------------------------
def plugin_metadata(root: Path) -> tuple[str, str]:
    """(name, version) 반환. 검증 실패 시 ValueError."""
    manifest_path = root / MANIFEST_RELATIVE
    try:
        info = manifest_path.lstat()
    except OSError as error:
        raise ValueError(f"플러그인 매니페스트를 읽을 수 없음: {manifest_path} ({error})") from error
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"플러그인 매니페스트가 일반 파일이 아님: {manifest_path}")
    if info.st_size > MAX_PLUGIN_MANIFEST_SIZE:
        raise ValueError(
            f"플러그인 매니페스트가 너무 큼({info.st_size} > {MAX_PLUGIN_MANIFEST_SIZE}): {manifest_path}"
        )
    # O_NOFOLLOW: 심볼릭 링크 교체(TOCTOU) 차단. runtime.ts와 동일한 의도.
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(str(manifest_path), flags)
    except OSError as error:
        raise ValueError(f"플러그인 매니페스트 열기 실패: {manifest_path} ({error})") from error
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            raise ValueError("읽기 직전에 플러그인 매니페스트가 변경됨")
        raw = os.read(fd, info.st_size)
        after = os.fstat(fd)
        if (after.st_dev, after.st_ino, after.st_size) != (
            info.st_dev,
            info.st_ino,
            info.st_size,
        ):
            raise ValueError("읽는 중에 플러그인 매니페스트가 변경됨")
    finally:
        os.close(fd)

    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"플러그인 매니페스트 JSON 파싱 실패: {manifest_path} ({error})") from error

    if not isinstance(manifest, dict) or manifest.get("name") != PLUGIN_NAME:
        raise ValueError(
            f"플러그인 매니페스트의 name이 '{PLUGIN_NAME}' 이어야 함 "
            f"(실제: {manifest.get('name') if isinstance(manifest, dict) else type(manifest).__name__!r})"
        )
    version = manifest.get("version")
    if not isinstance(version, str) or not version.strip():
        raise ValueError("플러그인 매니페스트에 비어 있지 않은 version이 필요함")
    return PLUGIN_NAME, version


# --------------------------------------------------------------------------
# 후보 수집
# --------------------------------------------------------------------------
def npm_global_root(target_repo: Path) -> tuple[Path | None, str]:
    """`npm root -g` 결과. (경로, 진단문자열).

    npm은 신뢰할 수 있는 PATH 항목(대상 저장소 밖)에서만 해석하고 정화된
    child env로 실행한다. `shutil.which` + 상속 env를 쓰면 대상 저장소가
    PATH에 `./node_modules/.bin`을 얹어 임의 코드를 실행시킬 수 있다.
    """
    resolved = resolve_trusted_executable("npm", dict(os.environ), target_repo)
    if resolved is None:
        return None, "신뢰할 수 있는 PATH에 npm이 없음"
    npm, child_env = resolved
    try:
        completed = subprocess.run(
            [str(npm), "root", "-g"],
            capture_output=True,
            text=True,
            env=child_env,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        return None, f"npm root -g 실행 실패: {error}"
    if completed.returncode != 0:
        return None, f"npm root -g 실패(exit {completed.returncode}): {completed.stderr.strip()}"
    root = completed.stdout.strip().splitlines()
    if not root:
        return None, "npm root -g 출력이 비어 있음"
    return Path(root[-1].strip()), f"npm root -g = {root[-1].strip()}"


def npx_cache_bases(target_repo: Path) -> list[Path]:
    """npx 캐시 루트 후보. npm은 $npm_config_cache 를 존중하므로 함께 확인한다.

    단, 대상 저장소가 설정한 캐시 경로(대상 내부)는 제외한다 — 그렇지 않으면
    대상 저장소가 glob 대상과 후보를 조종할 수 있다.
    """
    bases: list[Path] = []
    configured = os.environ.get("npm_config_cache") or os.environ.get("NPM_CONFIG_CACHE")
    if configured and within_target(target_repo, Path(configured).expanduser()):
        configured = None
    if configured:
        bases.append(Path(configured).expanduser() / "_npx")
    bases.append(Path.home() / ".npm" / "_npx")
    if sys.platform == "win32":
        appdata = os.environ.get("LOCALAPPDATA")
        if appdata:
            bases.append(Path(appdata) / "npm-cache" / "_npx")
    unique: list[Path] = []
    for base in bases:
        if base not in unique:
            unique.append(base)
    return unique


# 상류 저장소 체크아웃 안에서 플러그인 소스가 놓이는 상대 경로들.
# 상류가 레이아웃을 옮겼으므로 둘 다 시도한다:
#   plugins/codex-security          — 현재(npm 0.1.25 시점 소스 트리)
#   sdk/typescript/_bundled_plugin  — 과거 레이아웃(옛 체크아웃 호환)
# npm 배포본 안에서는 여전히 `_bundled_plugin` 이므로 그 경로는 별도로 다룬다.
SDK_REPO_RELATIVE = (
    ("plugins", "codex-security"),
    ("sdk", "typescript", "_bundled_plugin"),
)


def skill_repo_candidates(script_path: Path) -> list[Path]:
    """스킬 개발용 저장소 체크아웃 후보.

    - CODEX_SECURITY_SDK_REPO 환경변수(있으면)
    - 스크립트 위치에서 상위로 올라가며 SDK_REPO_RELATIVE 의 각 레이아웃 탐색
    """
    candidates: list[Path] = []
    configured = os.environ.get("CODEX_SECURITY_SDK_REPO")
    if configured:
        base = Path(configured).expanduser()
        for parts in SDK_REPO_RELATIVE:
            candidates.append(base.joinpath(*parts))
    here = real(script_path).parent
    # 무제한으로 `/`까지 올라가면 `/tmp/_bundled_plugin`, `/_bundled_plugin` 같은
    # 공유·전역 쓰기 가능 경로가 후보가 되어 다른 로컬 사용자가 플러그인을 심을 수
    # 있다. 저장소 마커(.git)에서 멈추고 깊이도 제한한다.
    for parent in [here, *here.parents][:MAX_ANCESTOR_DEPTH]:
        for parts in SDK_REPO_RELATIVE:
            candidates.append(parent.joinpath(*parts))
        candidates.append(parent / "_bundled_plugin")
        if (parent / ".git").exists():
            break
    return candidates


def collect_candidates(
    script_path: Path, target_repo: Path
) -> tuple[list[tuple[str, Path]], list[str]]:
    """(source, path) 후보 목록과 진단 로그를 우선순위 순서로 만든다."""
    candidates: list[tuple[str, Path]] = []
    notes: list[str] = []

    global_root, note = npm_global_root(target_repo)
    notes.append(note)
    if global_root is not None:
        candidates.append(("npm-global", global_root / NPM_PACKAGE / "_bundled_plugin"))

    for base in npx_cache_bases(target_repo):
        pattern = str(base / "*" / "node_modules" / NPM_PACKAGE / "_bundled_plugin")
        hits = sorted(glob.glob(pattern))
        notes.append(f"npx 캐시 {base}: {len(hits)}건")
        for hit in hits:
            candidates.append(("npx-cache", Path(hit)))

    for candidate in skill_repo_candidates(script_path):
        candidates.append(("sdk-repo", candidate))

    # 관측용 프로브: 대상 저장소의 node_modules 사본은 신뢰 게이트에서 반드시 거부된다.
    # 후보 목록의 맨 뒤에 두어, 존재할 경우 "거부됨" 기록이 남도록 한다(절대 채택되지 않음).
    planted = target_repo / "node_modules" / NPM_PACKAGE / "_bundled_plugin"
    if has_plugin_manifest(real(planted)):
        notes.append(f"대상 저장소 내부에 플러그인 사본 발견(신뢰하지 않음): {planted}")
        candidates.append(("target-node_modules", planted))

    return candidates, notes


# --------------------------------------------------------------------------
# 플러그인 루트 결정
# --------------------------------------------------------------------------
def resolve_plugin_root(target_repo: Path, script_path: Path) -> dict:
    """성공 시 {"pluginRoot","pluginVersion","source"}, 실패 시 ValueError."""
    attempts: list[dict] = []

    configured = (os.environ.get(PLUGIN_ROOT_ENV) or "").strip()
    if configured:
        path = Path(configured).expanduser()
        canonical = real(path)
        # 명시 지정도 동일한 신뢰 게이트를 통과해야 하며, 실패 시 fall-through 없이 즉시 실패.
        # 리터럴+realpath 둘 다 검사해 심볼릭 링크 우회를 막는다.
        if within_target(target_repo, path):
            raise TrustError(
                f"{PLUGIN_ROOT_ENV} 가 스캔 대상 저장소 내부를 가리킴: {canonical} "
                f"(대상: {target_repo}). 대상 저장소는 신뢰할 수 없는 코드이므로 플러그인을 제공할 수 없습니다.",
                attempts,
            )
        if not has_plugin_manifest(canonical):
            raise TrustError(
                f"{PLUGIN_ROOT_ENV} 경로에 {MANIFEST_RELATIVE} 가 없음: {canonical}",
                attempts,
            )
        provenance = untrusted_provenance(canonical)
        if provenance is not None:
            raise TrustError(f"{PLUGIN_ROOT_ENV} 채택 거부 — {provenance}", attempts)
        _, version = plugin_metadata(canonical)  # ValueError 전파
        return {
            "pluginRoot": str(canonical),
            "pluginVersion": version,
            "source": PLUGIN_ROOT_ENV,
            "attempts": attempts,
            "notes": [],
        }

    candidates, notes = collect_candidates(script_path, target_repo)
    seen: set[Path] = set()
    for source, candidate in candidates:
        canonical = real(candidate)
        if canonical in seen:
            continue
        seen.add(canonical)
        record = {"source": source, "path": str(candidate), "realpath": str(canonical)}
        # 리터럴+realpath 둘 다 검사: 대상 저장소 내부 경로거나 저장소 밖을 가리키는
        # 심볼릭 링크면 거부한다(KTD4).
        if within_target(target_repo, candidate):
            record["result"] = "rejected"
            record["reason"] = "스캔 대상 저장소 내부 경로/심링크 (KTD4: 대상 코드는 플러그인을 제공할 수 없음)"
            attempts.append(record)
            continue
        if not has_plugin_manifest(canonical):
            record["result"] = "skipped"
            record["reason"] = f"{MANIFEST_RELATIVE} 없음"
            attempts.append(record)
            continue
        try:
            _, version = plugin_metadata(canonical)
        except ValueError as error:
            record["result"] = "rejected"
            record["reason"] = str(error)
            attempts.append(record)
            continue
        provenance = untrusted_provenance(canonical)
        if provenance is not None:
            record["result"] = "rejected"
            record["reason"] = provenance
            attempts.append(record)
            continue
        record["result"] = "accepted"
        record["pluginVersion"] = version
        attempts.append(record)
        return {
            "pluginRoot": str(canonical),
            "pluginVersion": version,
            "source": source,
            "attempts": attempts,
            "notes": notes,
        }

    raise TrustError(INSTALL_GUIDANCE, attempts, notes)


class TrustError(ValueError):
    def __init__(self, message: str, attempts: list[dict], notes: list[str] | None = None):
        super().__init__(message)
        self.attempts = attempts
        self.notes = notes or []


# --------------------------------------------------------------------------
# Python 인터프리터 판정 (runtime.ts resolvePluginPython/usablePython)
# --------------------------------------------------------------------------
def is_python_path_candidate(candidate: str) -> bool:
    """runtime.ts isPythonPathCandidate()."""
    return "/" in candidate or "\\" in candidate or candidate.startswith(".")


def trusted_path_entries(environ: dict[str, str], protected_root: Path) -> list[Path]:
    """protected_root 내부 PATH 항목을 제거한 정규화 PATH 목록 (resolveTrustedExecutable).

    계약 1 은 리터럴 경로와 realpath **둘 다** 대상 저장소 밖일 것을 요구한다.
    realpath 만 보면 저장소가 커밋한 심링크 디렉터리(`repo/evilbin -> /outside/bin`)가
    살아남고, 그 항목이 `trustedPathEnv`·`searchCommand.pathEnv` 에 실린다.
    소비자는 이 값을 PATH 로 **교체**하므로 상류 스크립트의 `rg`·`git` 이 저장소를
    통해서만 도달되는 디렉터리에서 해석된다 — 합성 저장소로 재현 확인했다.
    """
    entries: list[Path] = []
    raw = environ.get("PATH", "")
    for entry in raw.split(os.pathsep):
        if not entry or not os.path.isabs(entry):
            continue
        canonical = real(entry)
        if not canonical.exists():
            continue
        if within_target(protected_root, Path(entry)):
            continue
        if canonical not in entries:
            entries.append(canonical)
    return entries


def resolve_trusted_executable(
    candidate: str,
    environ: dict[str, str],
    protected_root: Path,
    state_dir: Path | None = None,
) -> tuple[Path, dict[str, str]] | None:
    """resolveTrustedExecutable()의 POSIX 경로 부분 복제."""
    entries = trusted_path_entries(environ, protected_root)
    path_like = "/" in candidate or "\\" in candidate
    if path_like:
        probes = [(None, Path(os.path.abspath(os.path.expanduser(candidate))))]
    else:
        probes = [(entry, entry / candidate) for entry in entries]

    unsafe_entries: set[Path] = set()
    executable: Path | None = None
    for entry, probe in probes:
        canonical = real(probe)
        if not canonical.exists():
            continue
        if is_within(protected_root, canonical):
            if entry is not None:
                unsafe_entries.add(entry)
            continue
        if not canonical.is_file() or not os.access(str(canonical), os.X_OK):
            continue
        if executable is None:
            executable = canonical
    if executable is None:
        return None

    # `tempfile.gettempdir()` 를 쓰면 안 된다 — 그것은 TMPDIR 을 존중하고 TMPDIR 은
    # 미신뢰 환경에서 그대로 받는 값이라, 대상 저장소가 TMPDIR 을 자기 안으로 돌리면
    # 프로브 HOME 이 저장소 내부가 된다(실측). TMPDIR 이 없어도 /tmp 는 1777 이라
    # 로컬 타 사용자가 같은 채널을 얻는다. state_dir 가 아직 없으면 존재하지 않는
    # 경로를 HOME 으로 내보내는데, probe_child_env 가 설정 경로를 직접 무력화하므로
    # HOME 이 실존하지 않아도 무해하다.
    neutral_home = state_dir if state_dir is not None else Path(os.devnull)
    child_env = probe_child_env(
        environ,
        protected_root,
        os.pathsep.join(str(entry) for entry in entries if entry not in unsafe_entries),
        neutral_home,
    )
    return executable, child_env


def usable_python(
    candidate: str, environ: dict[str, str], protected_root: Path
) -> tuple[Path, str] | None:
    """runtime.ts usablePython(). 통과 시 (실행파일, 버전문자열)."""
    resolved = resolve_trusted_executable(
        os.path.expanduser(candidate) if is_python_path_candidate(candidate) else candidate,
        environ,
        protected_root,
    )
    if resolved is None:
        return None
    executable, child_env = resolved
    try:
        completed = subprocess.run(
            [str(executable), "-I", "-B", "-c", PYTHON_CHECK],
            capture_output=True,
            text=True,
            env=child_env,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.stdout.strip() != PYTHON_OK_MARKER:
        return None
    return executable, python_version(executable, child_env)


def python_version(executable: Path, child_env: dict[str, str]) -> str:
    """보고용 버전 문자열. 버전 형태가 아니면 'unknown'."""
    try:
        raw = subprocess.run(
            [str(executable), "-I", "-B", "-c", "import sys;print(sys.version.split()[0])"],
            capture_output=True,
            text=True,
            env=child_env,
            timeout=5,
            check=False,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return raw if re.fullmatch(r"\d+\.\d+(\.\d+)?\S*", raw) else "unknown"


def resolve_plugin_python(protected_root: Path) -> dict:
    """runtime.ts resolvePluginPython()의 PYTHON → python3 → python 체인."""
    environ = dict(os.environ)
    attempts: list[dict] = []

    inherited = (environ.get("PYTHON") or "").strip()
    if inherited:
        resolved = usable_python(inherited, environ, protected_root)
        attempts.append(
            {
                "source": "PYTHON",
                "candidate": inherited,
                "result": "accepted" if resolved else "rejected",
            }
        )
        if resolved:
            return {"path": str(resolved[0]), "version": resolved[1], "source": "PYTHON", "attempts": attempts}
        # runtime.ts는 여기서 즉시 실패하지만(requirePython), 본 스크립트는 계획서 지시대로
        # 다음 후보로 진행하고 그 사실을 attempts에 남긴다.
        attempts[-1]["note"] = (
            "runtime.ts requirePython()은 PYTHON 지정이 실패하면 즉시 오류를 던진다. "
            "본 스크립트는 계획대로 다음 후보로 폴백한다."
        )

    for candidate in ("python3", "python"):
        resolved = usable_python(candidate, environ, protected_root)
        attempts.append(
            {
                "source": "PATH",
                "candidate": candidate,
                "result": "accepted" if resolved else "rejected",
            }
        )
        if resolved:
            return {"path": str(resolved[0]), "version": resolved[1], "source": candidate, "attempts": attempts}

    raise PythonError(PYTHON_GUIDANCE, attempts)


class PythonError(ValueError):
    def __init__(self, message: str, attempts: list[dict]):
        super().__init__(message)
        self.attempts = attempts


# --------------------------------------------------------------------------
# 스캔 디렉터리 준비 (runtime.ts codexSecurityStateDirectory/preparePersistentScanRoot)
# --------------------------------------------------------------------------
class SearchCommandError(ValueError):
    def __init__(self, message: str, attempts: list[dict], notes: list[str] | None = None):
        super().__init__(message)
        self.attempts = attempts
        self.notes = notes or []


# --------------------------------------------------------------------------
# 검색 명령(ripgrep) 해석
#
# 상류 references/core-scan.md 는 "기존 ripgrep 실행 파일을 선호하되 DotSlash·
# bootstrap 등 다운로드 가능한 래퍼는 거부하고 git grep/find/grep 으로 폴백"하라고
# 규정한다. 우리는 두 지점에서 의도적으로 갈라진다(P5-KTD2):
#   (a) Claude Code 바이너리를 `rg` 심링크로 노출한다. 이 심링크는 부트스트랩이
#       만들어 내는 래퍼이므로 규칙의 bootstrap 래퍼 금지에도 걸리지만, ripgrep 을
#       내장하고 있어 다운로드는 일어나지 않는다.
#   (b) git grep/find/grep 폴백을 인벤토리 경로에서는 채택하지 않는다. 폴백 산출물은
#       상류 인벤토리 집합과 달라 커버리지 분모가 어긋난다.
#
# 핵심 보안 규칙(KTD4 승계): PATH 에서 찾은 `rg` 도 플러그인 루트와 같은 신뢰
# 게이트를 통과해야 한다. 대상 저장소가 ./node_modules/.bin 을 PATH 에 얹으면
# 저장소가 커밋한 rg 가 채택되어 임의 코드가 실행되고, 설령 실행에 이르지 않아도
# 잘린 파일 목록이 커버리지 분모를 조용히 줄인다.
# --------------------------------------------------------------------------
def probe_ripgrep(
    executable: Path, child_env: dict[str, str], cwd: Path
) -> tuple[str | None, str]:
    """해석된 명령이 실제로 ripgrep 인지 실행해서 확인한다.

    반환은 `(버전 첫 줄 또는 None, 사유)`. 사유는 attempts 에 그대로 실어 실패
    원인을 구분한다 — 타임아웃·기동 실패·마커 불일치가 모두 "ripgrep 이 아님"
    으로 뭉개지면 사용자가 없는 문제를 쫓게 된다.

    버전 문자열 대조만으로는 부족하다. 상류 인벤토리 스크립트는 rg 종료코드 0과 1을
    모두 정상으로 받으므로, argv[0] 디스패치가 사라진 바이너리가 인자를 삼키고 0/1로
    끝나면 엉뚱한 목록이 그대로 분모가 된다(빈 목록 하드 실패로는 잡히지 않는다).
    cwd 는 대상 저장소 밖이어야 한다 — 저장소 안에서 돌리면 저장소 설정을 읽는
    바이너리에 통제권이 넘어간다.
    """
    try:
        completed = subprocess.run(
            [str(executable), "--version"],
            capture_output=True,
            text=True,
            env=child_env,
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,  # 대화형 바이너리가 부모 stdin 을 소비하지 않게
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, "timeout(10s)"
    except OSError as error:
        return None, f"oserror: {error}"
    except subprocess.SubprocessError as error:
        return None, f"subprocess: {error}"
    if completed.returncode != 0:
        return None, f"exit {completed.returncode}"
    first = completed.stdout.strip().splitlines()[0].strip() if completed.stdout.strip() else ""
    if RIPGREP_MARKER not in first.lower():
        return None, "marker-missing"
    return first, "ok"


def create_search_shim_dir(state_dir: Path, notes: list[str]) -> Path:
    """상태 디렉터리 아래 고정 이름의 전용 shim 디렉터리를 확보한다(0700).

    PATH 앞에 붙는 디렉터리이므로 매번 소유자·권한을 재검증한다. 고정 이름을
    쓰는 이유는 두 가지다 — (a) 타임스탬프 이름을 쓰면 검색 명령을 쓰는 스캔마다
    디렉터리가 하나씩 영구히 쌓인다(정리 주체가 없다), (b) Claude Code 바이너리
    경로에 버전이 박혀 있어 심링크는 갱신 때마다 어차피 다시 만들어야 한다.

    재사용하되 신뢰는 하지 않는다: 이미 존재하면 audit_directory 로 소유자·권한을
    다시 검사하고, 안에 있는 심링크는 아래 호출부가 현재 host 로 다시 만든다.
    """
    candidate = state_dir / SEARCH_SHIM_BASENAME
    created = False
    if not candidate.exists():
        try:
            os.mkdir(str(candidate), DIR_MODE)
            created = True
        except FileExistsError:
            pass  # 경쟁: 아래 audit_directory 가 검증한다
        except OSError as error:
            raise SearchCommandError(
                f"검색 명령 shim 디렉터리를 만들 수 없음: {candidate} ({error})", [], notes
            ) from error
    if candidate.is_symlink():
        raise SearchCommandError(
            f"검색 명령 shim 디렉터리가 심링크입니다(거부): {candidate}", [], notes
        )
    if created:
        os.chmod(str(candidate), DIR_MODE)  # umask 보정
    try:
        audit_directory(candidate, created=created, label="searchShim", notes=notes)
    except ScanDirError as error:
        raise SearchCommandError(str(error), [], notes) from error
    return candidate


def resolve_search_command(
    target_repo: Path, state_dir: Path, environ: dict[str, str]
) -> dict:
    """성공 시 {"path","source","pathPrefix","version","attempts","notes"}.

    해석 순서: (1) 신뢰 게이트를 통과한 PATH 의 `rg`, (2) Claude Code 바이너리를
    `rg` 이름으로 노출한 심링크. 둘 다 실패하면 SearchCommandError.
    """
    attempts: list[dict] = []
    notes: list[str] = []
    probe_cwd = real(state_dir)

    # (1) PATH 의 rg — 플러그인 루트와 같은 신뢰 게이트를 통과해야 한다.
    resolved = resolve_trusted_executable(SEARCH_COMMAND, environ, target_repo, state_dir)
    if resolved is None:
        attempts.append(
            {
                "source": "trusted-path",
                "result": "rejected",
                "reason": "신뢰할 수 있는 PATH 항목에서 rg 실행 파일을 찾지 못함",
            }
        )
    elif within_target(target_repo, resolved[0]):
        # 방어적 잔여 검사다. 리터럴/realpath 이중 검사는 이제 항목 열거 지점
        # (trusted_path_entries)에서 수행하므로 여기까지 오지 않는 것이 정상이다.
        # 두 호출 사이에 파일시스템이 바뀌는 TOCTOU 만 이 분기를 켠다.
        attempts.append(
            {
                "source": "trusted-path",
                "result": "rejected",
                "path": str(resolved[0]),
                "reason": "채택 직전 재검사에서 대상 저장소 내부로 바뀜(TOCTOU 의심)",
            }
        )
    else:
        executable, child_env = resolved
        version, reason = probe_ripgrep(executable, child_env, probe_cwd)
        if version is None:
            attempts.append(
                {
                    "source": "trusted-path",
                    "result": "rejected",
                    "path": str(executable),
                    "reason": f"실행했지만 ripgrep 으로 동작하지 않음 ({reason})",
                }
            )
        else:
            attempts.append(
                {"source": "trusted-path", "result": "accepted", "path": str(executable)}
            )
            return {
                "path": str(executable),
                "source": "trusted-executable",
                "pathPrefix": None,
                "pathEnv": child_env["PATH"],
                "version": version,
                "attempts": attempts,
                "notes": notes,
            }

    # (2) Claude Code 바이너리를 rg 로 노출. multicall 이라 argv[0]이 rg 면 내장
    #     ripgrep 으로 동작한다(문서화되지 않은 내부 규약 — 그래서 매번 프로브한다).
    requested = environment_value(CLAUDE_EXECPATH_ENV, environ)
    host: Path | None = None
    if requested:
        # within_target 은 리터럴과 realpath 를 둘 다 본다. real() 결과를 넘기면
        # 리터럴 검사가 무의미해지므로 확장만 한 원본 경로를 넘긴다.
        expanded = Path(os.path.abspath(os.path.expanduser(requested)))
        candidate = real(expanded)
        if within_target(target_repo, expanded):
            attempts.append(
                {
                    "source": CLAUDE_EXECPATH_ENV,
                    "result": "rejected",
                    "path": str(candidate),
                    "reason": "대상 저장소 내부 경로",
                }
            )
        elif not is_regular_file(candidate) or not os.access(str(candidate), os.X_OK):
            attempts.append(
                {
                    "source": CLAUDE_EXECPATH_ENV,
                    "result": "rejected",
                    "path": str(candidate),
                    "reason": "실행 가능한 정규 파일이 아님",
                }
            )
        else:
            host = candidate
    else:
        attempts.append(
            {
                "source": CLAUDE_EXECPATH_ENV,
                "result": "rejected",
                "reason": "환경변수가 설정되지 않음",
            }
        )

    if host is None:
        trusted = resolve_trusted_executable("claude", environ, target_repo, state_dir)
        if trusted is not None:
            host = trusted[0]
            attempts.append(
                {"source": "trusted-path-claude", "result": "candidate", "path": str(host)}
            )

    if host is None:
        raise SearchCommandError(SEARCH_GUIDANCE, attempts, notes)

    shim_dir = create_search_shim_dir(state_dir, notes)
    link = shim_dir / SEARCH_COMMAND
    # shim 디렉터리는 고정 이름으로 재사용하므로 심링크가 이미 있을 수 있다.
    # Claude Code 바이너리 경로에는 버전이 박혀 있어 갱신 때마다 대상이 바뀌므로
    # 매번 현재 host 로 **원자 교체**한다(임시 이름 → os.replace).
    # 그냥 os.symlink 를 부르면 두 번째 실행이 FileExistsError 로 죽는다.
    # staging 이름에 pid 를 넣는다. 고정 이름이면 os.replace 자체는 원자적이어도
    # staging 슬롯이 경쟁 자원이 되어, 동시 실행 시 한쪽의 unlink 가 다른 쪽의
    # staging 을 지우고 os.replace 가 ENOENT 로 죽는다(동시 120회 중 2회 실측).
    staging = shim_dir / f".{SEARCH_COMMAND}.{os.getpid()}.new"
    try:
        if staging.is_symlink() or staging.exists():
            os.unlink(str(staging))
        os.symlink(str(host), str(staging))
        os.replace(str(staging), str(link))
    except OSError as error:
        try:
            os.unlink(str(staging))
        except OSError:
            pass
        raise SearchCommandError(
            f"{SEARCH_GUIDANCE}\n원인: rg 심링크를 만들 수 없음 ({error})", attempts, notes
        ) from error

    entries = trusted_path_entries(environ, target_repo)
    child_env = probe_child_env(
        environ,
        target_repo,
        os.pathsep.join([str(shim_dir), *(str(e) for e in entries)]),
        state_dir,
    )
    version, reason = probe_ripgrep(link, child_env, probe_cwd)
    if version is None and reason == "timeout(10s)":
        version, reason = probe_ripgrep(link, child_env, probe_cwd)  # 부하 타임아웃 1회 재시도
    if version is None:
        attempts.append(
            {
                "source": "claude-shim",
                "result": "rejected",
                "path": str(link),
                "reason": (
                    "심링크를 실행했지만 ripgrep 으로 동작하지 않음 "
                    f"({reason} — multicall 규약 변경 가능)"
                ),
            }
        )
        raise SearchCommandError(SEARCH_GUIDANCE, attempts, notes)

    attempts.append({"source": "claude-shim", "result": "accepted", "path": str(link)})
    notes.append(
        f"Claude Code 바이너리를 rg 로 노출: {link} → {host} "
        "(이 디렉터리는 인벤토리 호출의 PATH 앞에만 붙인다)"
    )
    return {
        "path": str(link),
        "source": "claude-shim",
        "pathPrefix": str(shim_dir),
        "pathEnv": child_env["PATH"],
        "version": version,
        "attempts": attempts,
        "notes": notes,
    }


class ScanDirError(ValueError):
    def __init__(self, message: str, notes: list[str] | None = None):
        super().__init__(f"{message}\n{SCAN_DIR_GUIDANCE}")
        self.notes = notes or []


def environment_value(requested: str, environ: dict[str, str]) -> str | None:
    """runtime.ts codexSecurityStateDirectory()의 내부 environmentValue().

    정확한 대문자 키를 먼저 보고, 없으면 대문자로 변환해 일치하는 키를 찾는다
    (SDK가 Windows 대소문자 비민감 환경을 위해 두는 폴백이며, 값이 공백이면 무시).
    SDK와 동일한 상태 디렉터리를 골라야 `codex-security scans list` 이력이
    공유되므로 폴백까지 그대로 복제한다.
    """
    exact = (environ.get(requested) or "").strip()
    if exact:
        return exact
    for name, value in environ.items():
        if name.upper() == requested and (value or "").strip():
            return value.strip()
    return None


def state_directory(environ: dict[str, str]) -> Path:
    """runtime.ts codexSecurityStateDirectory() 복제.

    CODEX_SECURITY_STATE_DIR → $CODEX_HOME/state/plugins/codex-security
    → ~/.codex/state/plugins/codex-security
    """
    configured = environment_value(STATE_DIR_ENV, environ)
    if configured is not None:
        return Path(os.path.abspath(expand_home(configured)))
    codex_home = environment_value(CODEX_HOME_ENV, environ) or str(Path.home() / ".codex")
    return Path(os.path.abspath(expand_home(codex_home))) / "state" / "plugins" / PLUGIN_NAME


def scan_timestamp(now: _datetime.datetime | None = None) -> str:
    """ISO 8601 basic format(UTC). `:` 를 쓰지 않아 파일명으로 안전하다."""
    moment = now or _datetime.datetime.now(_datetime.timezone.utc)
    return moment.astimezone(_datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def unsafe_to_tighten(path: Path) -> bool:
    """이미 존재하던 디렉터리를 chmod 0700 해도 되는지 판단(되면 False).

    CODEX_SECURITY_STATE_DIR 를 $HOME 이나 `/` 같은 공용 경로로 지정한 경우
    그 디렉터리를 0700으로 바꾸면 관계없는 것들이 깨진다. 그런 경로는 손대지
    않고 세부 검사(쓰기 권한 여부)로 판단한다.
    """
    canonical = real(path)
    home = real(Path.home())
    return (
        str(canonical) == canonical.anchor
        or canonical == home
        or is_within(canonical, home)  # canonical이 home의 조상
    )


def audit_directory(path: Path, created: bool, label: str, notes: list[str]) -> None:
    """디렉터리 소유자/권한 검증. 필요하면 0700으로 조인다. 불가하면 ScanDirError."""
    try:
        info = os.stat(str(path))
    except OSError as error:
        raise ScanDirError(f"{label} 디렉터리 상태 확인 실패: {path} ({error})", notes) from error
    if not stat.S_ISDIR(info.st_mode):
        raise ScanDirError(f"{label} 경로가 디렉터리가 아님: {path}", notes)
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise ScanDirError(
            f"{label} 디렉터리가 다른 사용자 소유(uid={info.st_uid})여서 권한을 조일 수 없음: {path}",
            notes,
        )
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o077 == 0:
        return
    if created or not unsafe_to_tighten(path):
        try:
            os.chmod(str(path), DIR_MODE)
        except OSError as error:
            raise ScanDirError(
                f"{label} 디렉터리 권한을 0700으로 조일 수 없음: {path} (mode={oct(mode)}, {error})",
                notes,
            ) from error
        notes.append(f"{label} 권한을 {oct(mode)} → 0700 으로 조정: {path}")
        return
    # $HOME 등 공용 경로는 건드리지 않는다. 다른 사용자가 쓸 수 있으면 거부,
    # 읽기만 가능하면 하위 scans 루트(0700)로 실질 격리가 되므로 경고만 남긴다.
    if mode & 0o022:
        raise ScanDirError(
            f"{label} 디렉터리가 다른 사용자에게 쓰기 허용(mode={oct(mode)})이며 공용 경로라 "
            f"권한을 조일 수 없음: {path}",
            notes,
        )
    notes.append(
        f"경고: {label} 디렉터리가 다른 사용자에게 읽기 허용(mode={oct(mode)})이지만 공용 경로라 "
        f"권한을 변경하지 않음: {path}"
    )


def make_private_directory(path: Path, label: str, notes: list[str]) -> None:
    """없는 상위 경로까지 0700으로 만들고, path 자체를 검증한다.

    umask 와 무관하게 0700이 되도록 mkdir 후 명시적으로 chmod 한다.
    """
    missing: list[Path] = []
    cursor = path
    while not cursor.exists():
        missing.append(cursor)
        if cursor.parent == cursor:
            break
        cursor = cursor.parent
    for target in reversed(missing):
        try:
            os.mkdir(str(target), DIR_MODE)
        except FileExistsError:
            continue  # 경쟁 상황: 아래 audit_directory 가 검증한다
        except OSError as error:
            raise ScanDirError(f"{label} 디렉터리를 만들 수 없음: {target} ({error})", notes) from error
        os.chmod(str(target), DIR_MODE)  # umask 보정
    audit_directory(path, created=bool(missing), label=label, notes=notes)


def create_leaf_scan_dir(scans_root: Path, repo_root: Path, notes: list[str]) -> Path:
    """scans_root 아래에 `<repo>-<timestamp>` 새 디렉터리를 만든다(항상 신규·빈 디렉터리)."""
    base = f"{safe_prefix(str(repo_root))}-{scan_timestamp()}"
    for attempt in range(1, MAX_SCAN_DIR_ATTEMPTS + 1):
        name = base if attempt == 1 else f"{base}-{attempt}"
        candidate = scans_root / name
        try:
            os.mkdir(str(candidate), DIR_MODE)
        except FileExistsError:
            continue
        except OSError as error:
            raise ScanDirError(
                f"스캔 디렉터리를 만들 수 없음: {candidate} ({error})", notes
            ) from error
        os.chmod(str(candidate), DIR_MODE)  # umask 보정
        return candidate
    raise ScanDirError(
        f"스캔 디렉터리 이름이 계속 충돌함({base}-2..{MAX_SCAN_DIR_ATTEMPTS}): {scans_root}", notes
    )


def prepare_explicit_scan_dir(requested: Path, repo_root: Path, notes: list[str]) -> Path:
    """--scan-dir 로 지정된 경로를 검증/생성한다. 비어 있는 새 디렉터리여야 한다."""
    try:
        info = requested.lstat()
    except FileNotFoundError:
        make_private_directory(requested, "스캔", notes)
        return requested
    except OSError as error:
        raise ScanDirError(f"스캔 디렉터리 상태 확인 실패: {requested} ({error})", notes) from error

    if stat.S_ISLNK(info.st_mode):
        raise ScanDirError(
            f"스캔 디렉터리가 심볼릭 링크임(산출물이 다른 위치로 새어나갈 수 있음): {requested}", notes
        )
    if not stat.S_ISDIR(info.st_mode):
        raise ScanDirError(f"스캔 디렉터리 경로가 디렉터리가 아님: {requested}", notes)
    audit_directory(requested, created=False, label="스캔", notes=notes)
    try:
        existing = os.listdir(str(requested))
    except OSError as error:
        raise ScanDirError(f"스캔 디렉터리를 읽을 수 없음: {requested} ({error})", notes) from error
    if existing:
        raise ScanDirError(
            f"스캔 디렉터리가 비어 있지 않음({len(existing)}개 항목): {requested}. "
            "기존 결과를 보존하려면 다른 경로를 지정하세요.",
            notes,
        )
    return requested


def require_state_dir_outside_repo(repo_root: Path, state_dir: Path) -> None:
    """상태 디렉터리는 언제나 대상 저장소 밖이어야 한다 (api.ts requireOutputOutsideRepository).

    --scan-dir / --no-scan-dir 로 이번 실행이 상태 디렉터리를 만들지 않더라도
    성공 JSON의 stateDir 는 이후 단계(workbench DB 등)가 쓰는 경로이므로
    대상 저장소 내부를 가리키면 그 자리에서 실패시킨다.
    """
    if within_target(repo_root, state_dir):
        raise ScanDirError(
            f"상태 디렉터리가 스캔 대상 저장소 내부임: {state_dir} (대상: {repo_root}). "
            "대상 저장소 안에는 스캔 산출물·이력 DB를 쓸 수 없습니다(대상 코드가 산출물을 조작할 수 있음)."
        )


def prepare_scan_dir(repo_root: Path, state_dir: Path, requested: str | None) -> dict:
    """scanDir/scansRoot/stateDir 를 확정한다. 실패 시 ScanDirError."""
    notes: list[str] = []

    if requested is not None:
        scan_dir = literal(requested)
        if within_target(repo_root, scan_dir):
            raise ScanDirError(
                f"--scan-dir 가 스캔 대상 저장소 내부를 가리킴: {scan_dir} (대상: {repo_root}). "
                "대상 저장소 안에는 스캔 산출물을 쓸 수 없습니다.",
                notes,
            )
        scan_dir = prepare_explicit_scan_dir(scan_dir, repo_root, notes)
        if within_target(repo_root, scan_dir):  # 생성 후 재확인(TOCTOU)
            raise ScanDirError(f"스캔 디렉터리가 대상 저장소 내부로 해석됨: {scan_dir}", notes)
        return {
            "scanDir": str(scan_dir),
            "scansRoot": None,
            "stateDir": str(state_dir),
            "notes": notes,
        }

    make_private_directory(state_dir, "상태", notes)
    scans_root = state_dir / "scans"
    make_private_directory(scans_root, "scans 루트", notes)
    scan_dir = create_leaf_scan_dir(scans_root, repo_root, notes)
    if within_target(repo_root, scan_dir):  # 상태 디렉터리가 저장소 안을 가리키는 심링크였던 경우
        os.rmdir(str(scan_dir))
        raise ScanDirError(f"스캔 디렉터리가 대상 저장소 내부로 해석됨: {scan_dir}", notes)
    return {
        "scanDir": str(scan_dir),
        "scansRoot": str(scans_root),
        "stateDir": str(state_dir),
        "notes": notes,
    }


# --------------------------------------------------------------------------
def default_target_repo() -> str:
    """--target-repo 미지정 시 신뢰 경계. cwd의 git 최상위, 없으면 cwd.

    git 도 신뢰 경계 밖(cwd 밖) PATH 항목에서만 해석한다 — 대상 저장소가
    PATH에 얹은 `./node_modules/.bin/git` 같은 사본을 실행하지 않기 위함.
    """
    cwd = real(os.getcwd())
    resolved = resolve_trusted_executable("git", dict(os.environ), cwd)
    if resolved is None:
        return str(cwd)
    git, child_env = resolved
    try:
        completed = subprocess.run(
            [str(git), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            env=child_env,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return str(cwd)
    top = completed.stdout.strip()
    if completed.returncode == 0 and top:
        return top
    return str(cwd)


def emit(payload: dict) -> None:
    """성공·실패 JSON 을 stdout 에 낸다.

    서로게이트(비-UTF8 바이트가 surrogateescape 로 들어온 것)를 안전하게 치환한다.
    페이로드에는 환경·경로에서 온 문자열이 여러 경로로 섞이므로 한 곳만 걸러서는
    부족하다 — 하나라도 남으면 `print` 가 flush 시점에 UnicodeEncodeError 로 죽고,
    문서화한 실패 계약(`exit 1 + {"ok": false, "stage": …}`)이 깨져 소비자가
    트레이스백을 받는다(실측: TERM 에 비-UTF8 바이트 하나로 재현).
    """
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    # 인코딩 불가 문자를 치환해 계약을 지킨다. 정상 경로에서는 무변화다.
    safe = text.encode("utf-8", errors="replace").decode("utf-8")
    print(safe)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target-repo",
        default=None,
        help="스캔 대상 저장소(신뢰할 수 없는 코드). 기본값: cwd의 git 최상위(없으면 cwd)",
    )
    parser.add_argument("--skip-python", action="store_true", help="Python 인터프리터 판정을 건너뜀")
    parser.add_argument(
        "--scan-dir",
        default=None,
        help="스캔 산출물 디렉터리를 직접 지정(대상 저장소 밖 + 비어 있음 + 0700 검사는 동일 적용)",
    )
    parser.add_argument(
        "--no-scan-dir",
        action="store_true",
        help="스캔 디렉터리를 만들지 않고 플러그인/Python만 해석(다른 도구·테스트용)",
    )
    parser.add_argument(
        "--require-search",
        action="store_true",
        help=(
            "검색 명령(ripgrep) 확보를 필수로 만든다. 실패 시 exit 1. 저장소 전체 스캔과 "
            "deep-lite 는 인벤토리를 상류 generate_in_scope_files.py 에 위임하므로 이 "
            "플래그를 쓴다. diff 스캔은 diff 모드가 git 만 쓰므로 필요 없고, validate·"
            "patch·verify-fix·scan-match 는 인벤토리를 만들지 않으므로 필요 없다"
        ),
    )
    parser.add_argument(
        "--probe-search",
        action="store_true",
        help=(
            "검색 명령을 해석해 보고만 하고 실패해도 exit 0 을 유지한다(install.sh --check "
            "진단용). --require-search 와 함께 주면 --require-search 가 이긴다"
        ),
    )
    args = parser.parse_args(argv)

    # target-repo 미지정 시 cwd의 하위 디렉터리에서 호출되면 신뢰 경계가 너무
    # 좁아진다(경계 위의 대상 저장소 코드가 신뢰 대상이 됨). git 최상위로 넓혀
    # 저장소 전체를 미신뢰 경계로 잡는다. git 저장소가 아니면 cwd로 폴백한다.
    target_repo = real(args.target_repo if args.target_repo is not None else default_target_repo())
    script_path = Path(__file__)
    environ = dict(os.environ)

    if args.no_scan_dir and args.scan_dir is not None:
        emit(
            {
                "ok": False,
                "stage": "arguments",
                "error": "--scan-dir 와 --no-scan-dir 는 함께 쓸 수 없습니다. 하나만 지정하세요.",
                "repoRoot": str(target_repo),
            }
        )
        return 1

    try:
        plugin = resolve_plugin_root(target_repo, script_path)
    except TrustError as error:
        emit(
            {
                "ok": False,
                "stage": "pluginRoot",
                "error": str(error),
                "repoRoot": str(target_repo),
                "attempts": error.attempts,
                "notes": error.notes,
            }
        )
        return 1
    except ValueError as error:
        emit(
            {
                "ok": False,
                "stage": "pluginRoot",
                "error": str(error),
                "repoRoot": str(target_repo),
            }
        )
        return 1

    python: dict | None = None
    if not args.skip_python:
        try:
            python = resolve_plugin_python(target_repo)
        except PythonError as error:
            emit(
                {
                    "ok": False,
                    "stage": "python",
                    "error": str(error),
                    "repoRoot": str(target_repo),
                    "pluginRoot": plugin["pluginRoot"],
                    "pluginVersion": plugin["pluginVersion"],
                    "attempts": error.attempts,
                }
            )
            return 1

    state_dir = state_directory(environ)
    search: dict | None = None
    search_error: SearchCommandError | None = None
    search_notes: list[str] = []
    # 검색 명령 해석은 **요청받을 때만** 수행한다. 무조건 돌리면 검색을 쓰지 않는
    # 스킬(validate·patch·verify-fix·scan-match)도 호출마다 상태 디렉터리를 만들고
    # 프로브 서브프로세스를 돌리며 shim 디렉터리를 남긴다.
    if args.require_search or args.probe_search:
        try:
            require_state_dir_outside_repo(target_repo, state_dir)
            make_private_directory(state_dir, "stateDir", search_notes)
            search = resolve_search_command(target_repo, state_dir, environ)
        except ScanDirError as error:
            # 삼키지 않는다. --no-scan-dir 이면 아래 scanDir 블록이 재검사하지
            # 않으므로, 삼키면 --require-search 가 ok:true 로 통과해 버린다.
            search_error = SearchCommandError(str(error), [], error.notes)
        except SearchCommandError as error:
            search_error = error

    if args.require_search and search is None:
        detail = search_error or SearchCommandError(SEARCH_GUIDANCE, [], search_notes)
        emit(
            {
                "ok": False,
                "stage": "searchCommand",
                "error": str(detail),
                "repoRoot": str(target_repo),
                "pluginRoot": plugin["pluginRoot"],
                "pluginVersion": plugin["pluginVersion"],
                "stateDir": str(state_dir),
                "attempts": detail.attempts,
                "notes": search_notes + detail.notes,
            }
        )
        return 1

    # 정화 PATH 가 비면 소비자가 PATH="" 로 자식을 띄워 `git` 조차 해석하지 못한다.
    # 빈 문자열을 내보내면 그 실패가 "PATH 를 그대로 쓰라"는 지시를 어긴 것처럼
    # 보이므로, 여기서 원인을 정확히 말하고 멈춘다.
    trusted_path_env = os.pathsep.join(
        str(entry) for entry in trusted_path_entries(environ, target_repo)
    )
    if not trusted_path_env:
        emit(
            {
                "ok": False,
                "stage": "trustedPathEnv",
                "error": (
                    "PATH 에서 대상 저장소 밖의 절대경로 항목을 하나도 찾지 못했습니다. "
                    "플러그인 스크립트는 정화된 PATH 로 실행해야 하므로 진행할 수 없습니다. "
                    "저장소 밖의 표준 경로(예: /usr/bin)를 PATH 에 포함해 다시 실행하세요."
                ),
                "repoRoot": str(target_repo),
                "pluginRoot": plugin["pluginRoot"],
                "pluginVersion": plugin["pluginVersion"],
                "stateDir": str(state_dir),
                "notes": search_notes,
            }
        )
        return 1

    scan: dict = {"scanDir": None, "scansRoot": None, "stateDir": str(state_dir), "notes": []}
    try:
        require_state_dir_outside_repo(target_repo, state_dir)
        if not args.no_scan_dir:
            scan = prepare_scan_dir(target_repo, state_dir, args.scan_dir)
    except ScanDirError as error:
        emit(
            {
                "ok": False,
                "stage": "scanDir",
                "error": str(error),
                "repoRoot": str(target_repo),
                "pluginRoot": plugin["pluginRoot"],
                "pluginVersion": plugin["pluginVersion"],
                "stateDir": str(state_dir),
                "notes": error.notes,
            }
        )
        return 1

    # emit() 의 errors="replace" 는 **진단·메시지 필드의 최후 안전망**이다. 경로
    # 축에는 적용돼선 안 된다 — 치환하면 ok:true 페이로드에 존재하지 않는 경로가
    # 실려 나가고(실측: 저장소 경로에 비-UTF8 바이트 1개 → repoRoot 가 U+FFFD 로
    # 바뀐 채 rc=0), 소비자는 그것을 `--repo`·`git -C` 에 넣어 "다른(없는) 저장소를
    # 스캔했다"는 결과를 만든다. 문서화한 실패 계약과 반대 방향의 조용한 오성공이다.
    for _axis, _value in (
        ("repoRoot", str(target_repo)),
        ("pluginRoot", plugin["pluginRoot"]),
        ("trustedPathEnv", trusted_path_env),
        ("stateDir", str(state_dir)),
        ("scanDir", scan["scanDir"]),
        ("scansRoot", scan["scansRoot"]),
        ("pythonPath", None if python is None else python["path"]),
        ("searchPathEnv", None if search is None else search["pathEnv"]),
    ):
        if _value is None or env_value_safe(_value):
            continue
        emit(
            {
                "ok": False,
                "stage": "arguments",
                "error": (
                    f"{_axis} 경로에 UTF-8 로 표현할 수 없는 바이트가 있습니다 — "
                    "치환해서 내보내면 존재하지 않는 경로를 스캔하게 됩니다. "
                    "대상 저장소·상태 디렉터리 경로를 UTF-8 로 표현 가능한 이름으로 "
                    "바꾸고 다시 실행하세요."
                ),
            }
        )
        return 1

    emit(
        {
            "ok": True,
            "pluginRoot": plugin["pluginRoot"],
            "pluginVersion": plugin["pluginVersion"],
            "pluginSource": plugin["source"],
            "python": (
                None
                if python is None
                else {
                    "path": python["path"],
                    "version": python["version"],
                    "source": python["source"],
                }
            ),
            # 대상 저장소 내부 항목을 제거한 PATH. 플러그인 스크립트를 자식
            # 프로세스로 돌릴 때 **이 값을 그대로 PATH 로 넣는다**(앞에 덧붙이지
            # 않는다). 상류 generate_in_scope_files.py 는 `rg` 뿐 아니라 `git` 도
            # PATH 에서 해석해 `cwd=대상 저장소` 로 실행하므로, 원시 $PATH 를
            # 물려주면 저장소가 커밋한 ./node_modules/.bin/git 이 실행된다(실측).
            "trustedPathEnv": trusted_path_env,
            # 소비자가 `env -i` 로 그대로 쓰는 KEY=VALUE 목록. PATH 정화만으로는
            # 반쪽이다 — 상류 generate_in_scope_files.py 는 `env=` 를 넘기지 않아
            # 부모 환경을 전부 상속하고, 거기에는 PATH 보다 강한 채널이 있다:
            # GIT_CONFIG_KEY_*(core.fsmonitor 로 임의 명령 실행), GIT_DIR/
            # GIT_WORK_TREE(신뢰 경계 이동), NODE_OPTIONS, LD_PRELOAD — 전부 재현.
            # 이 목록은 그 호출에 **PATH 대신** 쓴다.
            "trustedChildEnv": [
                f"{key}={value}"
                for key, value in sorted(
                    probe_child_env(
                        environ, target_repo, trusted_path_env, state_dir
                    ).items()
                )
            ],
            # 셸 명령에 그대로 붙일 수 있는 인용된 형태. **소비자는 이 값을 쓴다.**
            # 위 배열을 공백으로 이어 보간하면 값에 담긴 공백·따옴표·`$` 가 소비자
            # 셸에서 단어 분리·명령 치환된다 — 그 셸은 `env -i` **밖**이라 정화가
            # 적용되지 않는다(재현: 저장소가 얹은 TERM 값이 실행됐다). 공백만 있어도
            # 선의의 사용자에게 exit 127 이 난다.
            "trustedChildEnvShell": " ".join(
                shlex.quote(f"{key}={value}")
                for key, value in sorted(
                    probe_child_env(
                        environ, target_repo, trusted_path_env, state_dir
                    ).items()
                )
            ),
            "searchCommand": (
                None
                if search is None
                else {
                    "path": search["path"],
                    "source": search["source"],
                    "pathPrefix": search["pathPrefix"],
                    "pathEnv": search["pathEnv"],
                    "version": search["version"],
                }
            ),
            # 셸 명령에 보간되는 값은 **전부** 인용된 형태를 함께 낸다. 한 축만
            # 인용하면 계약이 반쪽이다 — `trustedChildEnv` 를 인용한 뒤에도 같은
            # 명령줄의 `PATH="<pathEnv>"`·`mkdir -p "<scanDir>/…"` 로 `$()` 가
            # 그대로 실행됐다(재현). 이중인용은 명령 치환을 막지 못한다.
            # 이 값들의 출처는 미신뢰 환경이다 — scanDir/stateDir 는
            # CODEX_SECURITY_STATE_DIR, pathEnv 는 PATH 항목의 디렉터리 이름.
            "shellQuoted": {
                "repoRoot": shlex.quote(str(target_repo)),
                "pluginRoot": shlex.quote(plugin["pluginRoot"]),
                "trustedPathEnv": shlex.quote(trusted_path_env),
                "stateDir": shlex.quote(str(state_dir)),
                "scanDir": (
                    None if scan["scanDir"] is None else shlex.quote(scan["scanDir"])
                ),
                "scansRoot": (
                    None if scan["scansRoot"] is None else shlex.quote(scan["scansRoot"])
                ),
                "pythonPath": (
                    None if python is None else shlex.quote(python["path"])
                ),
                "searchPathEnv": (
                    None if search is None else shlex.quote(search["pathEnv"])
                ),
            },
            "scanDir": scan["scanDir"],
            "scansRoot": scan["scansRoot"],
            "stateDir": scan["stateDir"],
            "repoRoot": str(target_repo),
            "diagnostics": {
                "artifactFileMode": oct(ARTIFACT_MODE),
                "pluginAttempts": plugin.get("attempts", []),
                "pluginNotes": plugin.get("notes", []),
                "pythonAttempts": [] if python is None else python.get("attempts", []),
                "searchAttempts": (
                    search_error.attempts if search_error is not None
                    else ([] if search is None else search.get("attempts", []))
                ),
                "searchNotes": search_notes
                + (
                    search_error.notes if search_error is not None
                    else ([] if search is None else search.get("notes", []))
                ),
                "searchError": None if search_error is None else str(search_error),
                "scanDirNotes": scan.get("notes", []),
            },
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
