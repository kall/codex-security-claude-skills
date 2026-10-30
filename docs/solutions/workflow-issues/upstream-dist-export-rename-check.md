---
title: "상류 dist 함수 이름 변경은 리터럴 대조로 안 보인다 — 정합 첫 단계에 import 멤버를 두 버전 dist와 대조하기"
date: 2026-10-30
category: workflow-issues
module: codex-security-claude-skills
problem_type: workflow_issue
component: tooling
related_components:
  - testing_framework
severity: medium
applies_when:
  - "상류 codex-security 새 태그에 맞춰 스킬을 정합할 때(정합 1단계, 자기채점 전에)"
  - "스킬 .mjs가 loadUpstream으로 상류 npm 패키지 dist 모듈을 불러 쓸 때"
  - "고정 리터럴 원본 대조가 '변경 없음'이라 영향이 없다고 판단하려 할 때"
symptoms:
  - "npm 0.8.2 정합에서 고정 리터럴 원본 11개가 모두 변경 없음이었는데 policy prepare가 TypeError: runtime.requirePrivatePolicyOutputDirectory is not a function으로 멈췄다"
  - "바뀐 함수는 runtime.ts에 있었고, runtime.ts는 docs/releasing.md 7절 대조 목록에 없었다"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
tags: [codex-security, upstream-alignment, dist-export, api-rename, loadupstream, policy]
---

# 상류 dist 함수 이름 변경은 리터럴 대조로 안 보인다

## Context

스킬의 Node 스크립트(`policy_draft.mjs`, `classify_severity.mjs`, `workflow_digest.mjs` 등)는 상류 프롬프트를 다시 쓰지 않는다. 대신
설치된 npm 패키지의 `dist/*.js`를 `loadUpstream(sdkDist, "<module>.js")`로 import해 상류 함수를 그대로 부른다. 그래서 상류가
**export 이름**을 바꾸면 스킬은 실행 중에 `TypeError: <ns>.<name> is not a function`으로 깨진다.

`docs/releasing.md` 7절의 재대조는 **고정한 영문 리터럴의 원본 파일**(`scan-comparison.ts`, `severity-review.ts`, `remediation.ts`,
`security-policy.ts` 등)만 `git diff`로 본다. npm 0.8.2(#2120)는 그 목록 밖의 `runtime.ts`에서
`requirePrivatePolicyOutputDirectory`를 `preparePolicyOutputDirectory`로 바꿨다. 대조는 11개 파일 모두 "변경 없음"이었고,
`repro-u8`을 돌린 뒤에야 policy `prepare`가 깨진 것을 알았다(P3~P11 113건 FAIL).

이번에는 `repro-u8`이 그 경로를 실제로 실행해서 잡혔다. 하지만 자기채점은 **자기가 실행하는 경로만** 증명한다
([녹색 기준선 러닝](upstream-alignment-green-baseline-misses-glue-path-break.md)). 오류 처리 분기나 드문 옵션에서만 부르는 dist 함수가
바뀌면 녹색인 채로 지나간다.

## Guidance

1. **정합 1단계에서, 자기채점보다 먼저, 스킬이 import하는 dist 멤버를 새·직전 버전 dist와 대조한다.** 실행 경로와 관계없이
   스킬 소스에 이름이 나오는 멤버를 전부 본다. 몇 초면 끝나고, 실패하면 어느 파일의 어느 멤버인지 바로 나온다.
2. **두 버전 결과를 함께 본다.** 한쪽에만 없는 멤버가 이름 변경 후보다. 0.8.2에서는 0.8.2에 `requirePrivatePolicyOutputDirectory`가,
   0.8.1에 `preparePolicyOutputDirectory`가 없었다. 스킬이 지원 범위의 옛 버전도 돌려야 하므로, 고칠 때는
   `ns.newName ?? ns.oldName`처럼 사본에 있는 쪽을 고르고 둘 다 없으면 명확한 오류로 멈춘다.
3. **이름이 같아도 의미가 바뀔 수 있다.** #2120은 이름과 함께 POSIX 검사를 0700에서 소유자 검사로 완화했다. 스킬이 상류 검사에
   기대던 보장(출력 디렉터리 비공개)은 스킬이 직접 다시 검사한다(`requirePrivateDirectory`). 대조에서 이름 변경을 찾으면 상류
   diff로 의미 변화도 읽는다.
4. **결과의 오탐을 걸러 읽는다.** 아래 스크립트는 `runtime.js` 같은 모듈 이름 문자열도 `runtime.js.js`로 잡는다. 확장자가 붙은 항목은
   무시한다.

```js
// 사용: node check-exports.mjs <설치본>/dist $(grep -rl loadUpstream skills --include='*.mjs')
import { readFileSync } from "node:fs";
const [dist, ...files] = process.argv.slice(2);
const missing = []; let checked = 0;
for (const f of files) {
  const src = readFileSync(f, "utf8");
  // const ns = await loadUpstream(x, "mod.js")  →  ns.member 참조를 모은다
  for (const [, v, mod] of src.matchAll(/(?:const|let) (\w+) = (?:\([^)]*\) \? )?await loadUpstream\([^,()]+,\s*"([\w.-]+\.js)"\)/g)) {
    const m = await import(`${dist}/${mod}`);
    for (const n of new Set([...src.matchAll(new RegExp(`\\b${v}\\??\\.(\\w+)`, "g"))].map((x) => x[1]))) {
      checked++; if (!(n in m)) missing.push(`${f}: ${mod}.${n}`);
    }
  }
  // const { a, b } = await loadUpstream(x, "mod.js")
  for (const [, names, mod] of src.matchAll(/const \{([^}]+)\} = await loadUpstream\([^,()]+,\s*"([\w.-]+\.js)"\)/g)) {
    const m = await import(`${dist}/${mod}`);
    for (const n of names.split(",").map((s) => s.trim().split(":")[0].trim()).filter(Boolean)) {
      checked++; if (!(n in m)) missing.push(`${f}: ${mod}.${n}`);
    }
  }
}
console.log(JSON.stringify({ checked, missing }, null, 1));
```

0.8.2 정합(2026-10-30)에서 이 스크립트는 멤버 98개를 확인했다. 오탐을 빼면 두 버전에서 서로 다른 것은 위 함수 쌍뿐이었다. 수정 뒤
`repro-u8`은 0.8.2·0.8.1 모두 OK 332였다.

**적용 범위.** 이 대조는 `loadUpstream`으로 부르는 Node dist만 본다. Python 스크립트(`finalize_scan_contract.py` 등)를 명령행으로
부르는 경로와 Node 헬퍼(`launch_codex_security_mcp --helper …`)의 인자 변경은 잡지 못한다. 0.8.0의 `bind-repo-scopes --coverage` 삭제가
그 예다. 그쪽은 자기채점과 종단간 스모크 테스트가 맡는다.

## Related

- [녹색 기준선 러닝](upstream-alignment-green-baseline-misses-glue-path-break.md) — 자기채점이 실행 경로만 증명한다는 원칙, 정합마다 스모크 테스트
- `docs/releasing.md` 7절 — 고정 리터럴 원본 재대조 목록(이 대조와 별개)
- `docs/plans/2026-10-30-1000-chore-codex-security-082-alignment.md` — 0.8.2 정합 기록
