#!/usr/bin/env python3
"""codex-security-scan 스킬의 단일 부트스트랩 스크립트.

세 가지를 한 번에 결정하고 그 결과를 JSON 한 덩어리로 stdout에 출력한다.

  1. 신뢰할 수 있는 Codex Security 번들 플러그인 루트 (+ pluginVersion)
  2. 플러그인을 실행할 Python 인터프리터 (3.10+; 3.10은 tomli 필요)
  3. 스캔 산출물 디렉터리(scanDir) — 대상 저장소 **밖**, 0700, 비어 있음

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

성공: exit 0 + {"ok": true, ...} (SUCCESS_KEYS 참고)
실패: exit 1 + {"ok": false, "stage": ..., "error": <한국어 안내>, ...}

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

# 성공 JSON의 최상위 키(계약). 이후 단계는 이 키만 신뢰한다.
SUCCESS_KEYS = (
    "ok",
    "pluginRoot",
    "pluginVersion",
    "pluginSource",
    "python",
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
    "후 sdk/typescript/_bundled_plugin 사용\n"
    f"  4) 이미 설치본이 있다면 {PLUGIN_ROOT_ENV}=<플러그인 루트> 로 지정\n"
    "주의: 스캔 대상 저장소 내부(node_modules 포함)의 플러그인 사본은 신뢰하지 않으므로 사용되지 않습니다."
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


def within_target(target_repo: Path, candidate: Path) -> bool:
    """후보가 대상 저장소 내부(= 신뢰할 수 없음)인가.

    리터럴 경로(심링크 미해석)와 realpath 둘 중 하나라도 대상 저장소 내부이면
    True. realpath만 검사하면 대상 저장소가 저장소 밖을 가리키는 심볼릭 링크를
    커밋해 게이트를 우회할 수 있다(KTD4 위반). True이면 거부해야 한다.
    """
    return is_within(target_repo, literal(candidate)) or is_within(target_repo, real(candidate))


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


def skill_repo_candidates(script_path: Path) -> list[Path]:
    """스킬 개발용 저장소 체크아웃 후보.

    - CODEX_SECURITY_SDK_REPO 환경변수(있으면)
    - 스크립트 위치에서 상위로 올라가며 sdk/typescript/_bundled_plugin 탐색
    """
    candidates: list[Path] = []
    configured = os.environ.get("CODEX_SECURITY_SDK_REPO")
    if configured:
        candidates.append(Path(configured).expanduser() / "sdk" / "typescript" / "_bundled_plugin")
    here = real(script_path).parent
    # 무제한으로 `/`까지 올라가면 `/tmp/_bundled_plugin`, `/_bundled_plugin` 같은
    # 공유·전역 쓰기 가능 경로가 후보가 되어 다른 로컬 사용자가 플러그인을 심을 수
    # 있다. 저장소 마커(.git)에서 멈추고 깊이도 제한한다.
    for parent in [here, *here.parents][:MAX_ANCESTOR_DEPTH]:
        candidates.append(parent / "sdk" / "typescript" / "_bundled_plugin")
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
    """protected_root 내부 PATH 항목을 제거한 정규화 PATH 목록 (resolveTrustedExecutable)."""
    entries: list[Path] = []
    raw = environ.get("PATH", "")
    for entry in raw.split(os.pathsep):
        if not entry or not os.path.isabs(entry):
            continue
        canonical = real(entry)
        if not canonical.exists():
            continue
        if is_within(protected_root, canonical):
            continue
        if canonical not in entries:
            entries.append(canonical)
    return entries


def resolve_trusted_executable(
    candidate: str, environ: dict[str, str], protected_root: Path
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

    child_env = {k: v for k, v in environ.items() if k.upper() != "PATH"}
    child_env["PATH"] = os.pathsep.join(
        str(entry) for entry in entries if entry not in unsafe_entries
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
    print(json.dumps(payload, ensure_ascii=False, indent=2))


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
            "scanDir": scan["scanDir"],
            "scansRoot": scan["scansRoot"],
            "stateDir": scan["stateDir"],
            "repoRoot": str(target_repo),
            "diagnostics": {
                "artifactFileMode": oct(ARTIFACT_MODE),
                "pluginAttempts": plugin.get("attempts", []),
                "pluginNotes": plugin.get("notes", []),
                "pythonAttempts": [] if python is None else python.get("attempts", []),
                "scanDirNotes": scan.get("notes", []),
            },
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
