// workflow_digest.mjs — 상류 npm 패키지 dist/ 함수를 직접 호출하는 공용 Node 관문.
//
// 왜 재구현하지 않는가(P6-KTD11 + U7 결정): 상류 `workflowDigest`는 키를 JS 문자열 비교로
// 재귀 정렬한 뒤 `JSON.stringify`한 값의 SHA-256이다. Python `json.dumps`는 숫자 표기와
// astral 문자 키 정렬에서 달라질 수 있다. SECURITY.md 스냅샷 digest(`inheritedPolicySha256`)도
// 링크 체인·정규 파일·Git 메타데이터 규칙이 얽혀 있다. npm 0.1.29 번들의 `dist/`가 이
// 함수들을 export하므로(phase0-results.md 0.1.29 부록 4번), 부트스트랩이 채택한 패키지의
// dist를 import해서 **상류 코드 그대로** 계산한다. 소스 체크아웃(dist 없음)이면 실패한다.
//
// 실행 형태(P6-KTD6) — 반드시 이렇게 부른다:
//   env -i <trusted_child_env> <node> <이 파일> <subcommand> [--key value ...] [--json <obj> | --json-file <path>]
// 셰뱅을 두지 않는다. 셰뱅(`#!/usr/bin/env node`)으로 실행하면 PATH의 첫 `node`가 선택되고,
// 대상 저장소가 PATH에 `node_modules/.bin`을 얹은 환경이면 저장소가 커밋한 node가 실행된다.
// `env -i`를 빼면 호출 환경의 `NODE_OPTIONS=--require <저장소 JS>`가 그대로 적용된다(실측).
// 이 스크립트는 NODE_OPTIONS나 node 실행 옵션이 남아 있으면 실행을 거부한다(심층 방어 —
// --require 는 이미 실행된 뒤이므로 이것이 1차 방어선은 아니다. 1차 방어선은 `env -i`다).
//
// 출력: 성공이면 stdout에 JSON 1개(`{"ok": true, ...}`)와 exit 0. 실패면 stdout에
// `{"ok": false, "subcommand", "error", "upstreamError"?}`와 exit 2. 사용법 오류는 exit 1.
//
// 하위 명령:
//   digest              --sdk-dist D --json '{"value": <임의 JSON>}'  → {"sha256"} (상류 workflowDigest)
//   policy-snapshot     --sdk-dist D --repository R [--path P]       → 대상·인벤토리·스냅샷 digest
//   policy-stage-parse  --sdk-dist D --json-file F                   → 상류 strict 파서로 검증한 4키 결과
//   severity-read       --sdk-dist D --state-dir S --python P --scan-dir DIR
//                       → 상류 readScanSeverityClassification(publish 가 쓰는 읽기 경로, digest 재확인 포함)
//
// 상류 모듈은 UPSTREAM_MODULES 허용 목록으로만 연다. 심각도 재분류(U8)의 분류·저장 흐름은
// ../../codex-security-classify-severity/scripts/classify_severity.mjs 가 이 관문을 import 해서 쓴다.

import { createHash } from "node:crypto";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { lstat } from "node:fs/promises";
import { isAbsolute, join, relative, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// 이 관문이 여는 상류 dist 모듈. 늘릴 때는 여기에 추가한다.
export const UPSTREAM_MODULES = Object.freeze([
  "finding-workflow.js",
  "security-policy.js",
  "runtime.js",
  "targets.js",
  "codex-prompt.js",
  // U8 심각도 재분류: 분류·체크포인트·결과 파일·읽기 경로를 상류 함수 그대로 쓴다.
  "classify-severity.js",
  "classify-scan-severity.js",
  // prepare 의 읽기 전용 load: 워크벤치 DB 사본에 상류 SeverityStore.checkpoint().load 를 그대로 부른다.
  "severity-store.js",
  "saved-scan.js",
  "contract.js",
]);

// 부트스트랩 resolve_sdk()와 같은 표식. 이 파일이 없으면 npm dist가 아니다.
const SDK_DIST_MARKER = "finding-workflow.js";

export class GatewayError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "GatewayError";
    this.details = details;
  }
}

// ---------------------------------------------------------------------------
// 공용 상수·유틸 — policy_draft.mjs·classify_severity.mjs 가 함께 쓴다
// ---------------------------------------------------------------------------
// 우리 계약: 조립된 서브에이전트 프롬프트 상한. scan-match·policy·severity 가 같은 값을 쓴다 — 부모가 한 번의
// Agent 호출로 프롬프트 전문을 내보내야 하므로 scan-match 실행 한도(P6-KTD5)와 같은 근거를 쓴다.
export const MAX_PROMPT_CHARACTERS = 80_000;

/** shlex.quote 와 같은 규칙. 부모가 셸 명령에 경로를 보간할 때 이 값을 **맨몸으로** 쓴다. */
export function shellQuote(value) {
  if (/^[A-Za-z0-9@%+=:,./_-]+$/.test(value)) return value;
  return `'${value.replaceAll("'", "'\"'\"'")}'`;
}

export function isInside(root, candidate) {
  const rel = relative(root, candidate);
  return rel === "" || (!rel.startsWith(`..${sep}`) && rel !== ".." && !isAbsolute(rel));
}

export async function requirePrivateDirectory(path, label) {
  const metadata = await lstat(path).catch(() => null);
  if (metadata === null || !metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new GatewayError(`${label} 가 실제 디렉터리가 아니다: ${path}`);
  }
  if ((metadata.mode & 0o077) !== 0) {
    throw new GatewayError(`${label} 권한이 0700 이 아니다: ${path}`);
  }
  if (process.geteuid && metadata.uid !== process.geteuid()) {
    throw new GatewayError(`${label} 가 현재 사용자 소유가 아니다: ${path}`);
  }
}

export function stripSingleFence(text) {
  // 서브에이전트가 JSON 을 코드 펜스 하나로 감싼 경우만 벗긴다(그 밖의 산문이 있으면 그대로 두어 상류 파서가 거부한다).
  const match = /^\s*```(?:json)?[ \t]*\n([\s\S]*?)\n```\s*$/u.exec(text);
  return match ? match[1] : text;
}

/** P6-KTD6 심층 방어: 환경 교체 없이 실행됐으면 거부한다. */
export function requireCleanNodeEnvironment() {
  if ((process.env.NODE_OPTIONS ?? "").trim() !== "") {
    throw new GatewayError(
      "NODE_OPTIONS 가 설정된 환경에서 실행됐다. 호출 환경의 Node 옵션(--require 등)이 적용됐을 수 있다. " +
        "`env -i <trusted_child_env> <node> <스크립트> …` 형태로 다시 실행하라(P6-KTD6).",
    );
  }
  if (process.execArgv.length > 0) {
    throw new GatewayError(
      `node 실행 옵션이 붙은 채 실행됐다(${JSON.stringify(process.execArgv)}). ` +
        "`<node> <스크립트>` 형태로만 실행하라(P6-KTD6).",
    );
  }
}

/** 부트스트랩 sdk.dist 를 검증하고 realpath 를 돌려준다. */
export function resolveSdkDist(sdkDist) {
  if (typeof sdkDist !== "string" || sdkDist === "") {
    throw new GatewayError(
      "--sdk-dist 가 없다. 부트스트랩 결과의 sdk.dist 를 넘겨라. sdk.dist 가 null 이면 상류 소스 " +
        "체크아웃이라 dist/ 함수를 쓸 수 없다 — `npm install -g @openai/codex-security` 설치본을 쓰라.",
    );
  }
  if (!sdkDist.startsWith("/")) {
    throw new GatewayError(`--sdk-dist 는 절대 경로여야 한다: ${sdkDist}`);
  }
  let canonical;
  try {
    canonical = realpathSync(sdkDist);
  } catch (error) {
    throw new GatewayError(`SDK dist 경로를 확인할 수 없다: ${sdkDist} (${error.message})`);
  }
  let marker;
  try {
    marker = statSync(join(canonical, SDK_DIST_MARKER));
  } catch {
    marker = null;
  }
  if (marker === null || !marker.isFile()) {
    throw new GatewayError(
      `SDK dist 에 ${SDK_DIST_MARKER} 가 없다: ${canonical}. npm 설치본의 dist/ 가 아니다.`,
    );
  }
  return canonical;
}

const moduleCache = new Map();

/** 허용 목록의 상류 dist 모듈을 import 한다. */
export async function loadUpstream(sdkDist, moduleName) {
  if (!UPSTREAM_MODULES.includes(moduleName)) {
    throw new GatewayError(`허용 목록에 없는 상류 모듈: ${moduleName}`);
  }
  const dist = resolveSdkDist(sdkDist);
  const key = `${dist}\u0000${moduleName}`;
  if (!moduleCache.has(key)) {
    moduleCache.set(key, import(pathToFileURL(join(dist, moduleName)).href));
  }
  return await moduleCache.get(key);
}

export function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

/**
 * 상류 규칙 그대로 정책 대상·인벤토리·스냅샷을 계산한다.
 * - 대상: resolveSecurityPolicyTarget (둘러싼 Git worktree 루트 = repository, 상대 경로 = scope)
 * - 인벤토리: inspectSecurityPolicySources (컴포넌트 아래 정책 + .github/docs 신고 정책)
 * - 보호 루트: securityPolicyProtectedRoots + gitMetadataPaths (api.ts #validatePolicyInputs 와 같은 합성)
 * - 스냅샷: readSecurityPolicySnapshot → previousContent, inheritedPolicySha256
 * - previousPolicySha256: 상류 매니페스트 규칙(previousContent 가 null 이면 null, 아니면 sha256)
 */
export async function policySnapshot(sdkDist, repository, path = ".") {
  const sp = await loadUpstream(sdkDist, "security-policy.js");
  const target = await sp.resolveSecurityPolicyTarget(repository, path);
  const sources = await sp.inspectSecurityPolicySources(target);
  const protectedRoots = [
    ...new Set([
      ...(await sp.securityPolicyProtectedRoots(target)),
      ...sources.gitMetadataPaths,
    ]),
  ];
  const gitMetadataPaths = [
    ...new Set([...protectedRoots.slice(1), ...sources.gitMetadataPaths]),
  ];
  const snapshot = await sp.readSecurityPolicySnapshot(
    target,
    undefined,
    gitMetadataPaths,
  );
  return {
    target: { ...target },
    targetObject: target, // 같은 프로세스 안에서 상류 바인딩(WeakMap)을 쓰는 호출용
    policyPaths: sources.policyPaths,
    gitMetadataPaths,
    protectedRoots,
    previousContent: snapshot.previousContent,
    previousPolicySha256:
      snapshot.previousContent === null ? null : sha256Hex(snapshot.previousContent),
    inheritedPolicySha256: snapshot.inheritedPolicySha256,
  };
}

/**
 * 심각도 재분류가 상류 함수에 넘기는 환경. 신뢰 환경(`env -i <trusted_child_env>`)은 HOME 을 stateDir 로
 * 바꾸므로, CODEX_SECURITY_STATE_DIR 를 빠뜨리면 상류가 `<HOME>/.codex/state/plugins/codex-security`
 * (빈 워크벤치)를 쓴다. 결과 파일은 생기지만 publish 가 읽는 워크벤치에는 행이 없다(P6-KTD12).
 * PYTHON 은 부트스트랩이 해석한 인터프리터로 고정한다(상류 resolvePluginPython 이 먼저 본다).
 */
export function severityEnvironment(stateDir, python) {
  if (typeof stateDir !== "string" || !stateDir.startsWith("/")) {
    throw new GatewayError(`--state-dir 는 절대 경로여야 한다(부트스트랩 stateDir): ${stateDir}`, { usage: true });
  }
  if (typeof python !== "string" || !python.startsWith("/")) {
    throw new GatewayError(`--python 은 절대 경로여야 한다(부트스트랩 python.path): ${python}`, { usage: true });
  }
  return { ...process.env, CODEX_SECURITY_STATE_DIR: stateDir, PYTHON: python };
}

/**
 * 상류 publish 와 같은 읽기 경로로 저장된 심각도 분류를 읽는다.
 * contract.js loadContractWithScanDirectory(봉인 확인) → classify-scan-severity.js
 * readScanSeverityClassification(SeverityStore.read: digest 가 같은 행만 채택, 개수 부족이면 incomplete →
 * validateSeverityClassification: finding digest·occurrenceId·결정 일관성 재확인).
 */
export async function readSeverityClassification(sdkDist, { scanDir, stateDir, python, expectedScanId }) {
  const environment = severityEnvironment(stateDir, python);
  const contractModule = await loadUpstream(sdkDist, "contract.js");
  const runtime = await loadUpstream(sdkDist, "runtime.js");
  const scanSeverity = await loadUpstream(sdkDist, "classify-scan-severity.js");
  const { contract, scanDirectory } = await contractModule.loadContractWithScanDirectory(scanDir, {
    pluginRoot: await runtime.bundledPluginRoot(),
    expectedScanId,
  });
  const scanId = contract.manifest.scan.id;
  const classification = await scanSeverity.readScanSeverityClassification(
    scanDirectory,
    scanId,
    contract.findings.findings,
    undefined,
    environment,
  );
  return { scanId, scanDirectory, contract, classification: classification ?? null };
}

// ---------------------------------------------------------------------------
// CLI 공용부
// ---------------------------------------------------------------------------

function camel(name) {
  return name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
}

/**
 * argv(하위 명령 뒤) → 인자 객체. --json / --json-file 로 JSON 객체를 먼저 받고 플래그가 덮어쓴다.
 * options.booleans: 값 없이 쓰는 플래그(camelCase 이름) → true.
 * options.repeatable: 여러 번 쓸 수 있는 플래그(camelCase 이름) → 문자열 배열(순서 유지).
 * 두 목록에 없는 플래그는 기존과 같이 값 하나를 받고, 반복되면 마지막 값이 이긴다.
 */
export function parseArgs(argv, options = {}) {
  const booleans = new Set(options.booleans ?? []);
  const repeatable = new Set(options.repeatable ?? []);
  const flags = {};
  let base = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      throw new GatewayError(`알 수 없는 인자: ${token}`, { usage: true });
    }
    const name = token.slice(2);
    if (booleans.has(camel(name))) {
      flags[camel(name)] = true;
      continue;
    }
    const value = argv[index + 1];
    if (value === undefined) {
      throw new GatewayError(`${token} 에 값이 없다`, { usage: true });
    }
    index += 1;
    if (name === "json") {
      base = parseJsonObject(value === "-" ? readFileSync(0, "utf8") : value, "--json");
    } else if (name === "json-file") {
      base = parseJsonObject(readFileSync(value, "utf8"), `--json-file ${value}`);
    } else if (repeatable.has(camel(name))) {
      (flags[camel(name)] ??= []).push(value);
    } else {
      flags[camel(name)] = value;
    }
  }
  return { ...base, ...flags };
}

function parseJsonObject(text, label) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw new GatewayError(`${label} 가 JSON 이 아니다: ${error.message}`, { usage: true });
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new GatewayError(`${label} 는 JSON 객체여야 한다`, { usage: true });
  }
  return value;
}

export function emit(payload) {
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
}

function upstreamMessage(error) {
  if (error instanceof GatewayError) return undefined;
  const name = error?.name ?? "Error";
  return `${name}: ${error?.message ?? String(error)}`;
}

/**
 * 하위 명령 표를 받아 CLI를 돌린다. 핸들러가 객체를 돌려주면 {"ok":true,...}로 내보낸다.
 * 핸들러가 {raw: string}을 돌려주면 그 문자열을 그대로 stdout 에 쓴다(프롬프트 텍스트용).
 * 핸들러가 {exitCode, payload}를 돌려주면 그 값으로 끝낸다(부분 성공 보고용).
 */
export async function runCli(handlers, argv = process.argv.slice(2)) {
  const [subcommand, ...rest] = argv;
  if (subcommand === undefined || !Object.hasOwn(handlers, subcommand)) {
    emit({
      ok: false,
      subcommand: subcommand ?? null,
      error: `하위 명령이 필요하다: ${Object.keys(handlers).join(" | ")}`,
    });
    return 1;
  }
  try {
    requireCleanNodeEnvironment();
    // 핸들러에 parseOptions({booleans, repeatable})가 붙어 있으면 그 규칙으로 파싱한다.
    const args = parseArgs(rest, handlers[subcommand].parseOptions ?? {});
    const result = await handlers[subcommand](args);
    if (result && typeof result.raw === "string") {
      process.stdout.write(result.raw);
      return 0;
    }
    if (result && typeof result.exitCode === "number") {
      emit({ subcommand, ...result.payload });
      return result.exitCode;
    }
    emit({ ok: true, subcommand, ...result });
    return 0;
  } catch (error) {
    const usage = error instanceof GatewayError && error.details?.usage === true;
    emit({
      ok: false,
      subcommand,
      error:
        error instanceof GatewayError
          ? error.message
          : "상류 함수가 입력을 거부했다. upstreamError 를 사용자에게 그대로 전하라.",
      ...(upstreamMessage(error) === undefined ? {} : { upstreamError: upstreamMessage(error) }),
      ...(error instanceof GatewayError && error.details && !usage
        ? { details: error.details }
        : {}),
    });
    return usage ? 1 : 2;
  }
}

// ---------------------------------------------------------------------------
// 이 파일의 하위 명령
// ---------------------------------------------------------------------------

export function requireString(args, key) {
  const value = args[key];
  if (typeof value !== "string" || value === "") {
    const flag = `--${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`;
    const hint =
      key === "sdkDist"
        ? " — 부트스트랩 결과의 sdk.dist 를 넘겨라(null 이면 소스 체크아웃이라 쓸 수 없다)"
        : "";
    throw new GatewayError(`${flag} 가 필요하다${hint}`, { usage: true });
  }
  return value;
}

export const HANDLERS = {
  async digest(args) {
    if (!Object.hasOwn(args, "value")) {
      throw new GatewayError('--json \'{"value": …}\' 또는 --json-file 로 value 를 넘겨라', {
        usage: true,
      });
    }
    const fw = await loadUpstream(requireString(args, "sdkDist"), "finding-workflow.js");
    return { sha256: fw.workflowDigest(args.value) };
  },

  async "policy-snapshot"(args) {
    const result = await policySnapshot(
      requireString(args, "sdkDist"),
      requireString(args, "repository"),
      typeof args.path === "string" && args.path !== "" ? args.path : ".",
    );
    return {
      target: result.target,
      policyPaths: result.policyPaths,
      gitMetadataPaths: result.gitMetadataPaths,
      protectedRoots: result.protectedRoots,
      previousPresent: result.previousContent !== null,
      previousPolicySha256: result.previousPolicySha256,
      inheritedPolicySha256: result.inheritedPolicySha256,
    };
  },

  async "policy-stage-parse"(args) {
    const sp = await loadUpstream(requireString(args, "sdkDist"), "security-policy.js");
    const value = Object.hasOwn(args, "value") ? args.value : undefined;
    if (value === undefined) {
      throw new GatewayError('--json \'{"value": …}\' 또는 --json-file 로 value 를 넘겨라', {
        usage: true,
      });
    }
    return { result: sp.parseSecurityPolicyStageResult(value) };
  },

  async "severity-read"(args) {
    const { scanId, scanDirectory, classification } = await readSeverityClassification(
      requireString(args, "sdkDist"),
      {
        scanDir: requireString(args, "scanDir"),
        stateDir: requireString(args, "stateDir"),
        python: requireString(args, "python"),
      },
    );
    return { scanId, scanDir: scanDirectory, present: classification !== null, classification };
  },
};

function invokedDirectly() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  process.exitCode = await runCli(HANDLERS);
}
