# Claude Security Skills (codex-security-claude-skills)

English | [한국어](README.ko.md)

9 Claude Code skills that run the [codex-security](https://github.com/openai/codex-security)
security scan workflow using **only a Claude Code subscription login** — no OpenAI/Codex
authentication required. SECURITY.md drafting and severity reclassification are included.

Claude Code itself acts as the LLM brain for the session. Validation, ID derivation, sealing,
and report generation are handled by the deterministic Python scripts bundled with the
codex-security plugin. The plugin is not vendored — it is discovered and used from whatever
is installed at runtime.

> This is a non-Codex execution path and is **not supported by upstream OpenAI.**

## Install (users)

Download the release tarball and install it. Or just paste this into a Claude Code session:

```
Install https://github.com/kall/codex-security-claude-skills/releases/tag/v0.5.1
```

```bash
BASE=https://github.com/kall/codex-security-claude-skills/releases/latest/download
PKG=codex-security-claude-skills-<version>

curl -fsSLO "$BASE/$PKG.tar.gz"
curl -fsSL  "$BASE/SHA256SUMS" | sha256sum -c -
tar xzf "$PKG.tar.gz"
bash "$PKG/skills/install.sh" --copy --check
```

`--check` probes the bundled plugin, Python, the search command (ripgrep), and the gate copy,
then reports the results. Its exit code has three values: **0 = fine / 2 = partial (ripgrep
unavailable — whole-repository scans cannot start) / 1 = failure**. If the
plugin is missing, it prints the install command (it does not install automatically):

```bash
npm install -g @openai/codex-security     # Node 22+
```

Restart Claude Code, then invoke:

```
/codex-security-scan /path/to/repo
```

Full usage, environment variables, and troubleshooting:
**[docs/install-and-usage.md](docs/install-and-usage.md)**

## Skills

| Skill | Purpose | Modifies the repo |
| --- | --- | --- |
| `codex-security-scan` | One-shot full-repo standard scan → sealed contract artifacts + `report.md` + SARIF | No |
| `codex-security-diff-scan` | Scans only a diff (refs or working-tree) | No |
| `codex-security-validate` | Judges a candidate finding's disposition | No |
| `codex-security-patch` | Minimal fix for a security issue — two-stage approval | Yes (after approval) |
| `codex-security-verify-fix` | Verifies whether an applied fix actually closed the original vulnerability (read-only) | No |
| `codex-security-scan-match` | Matches findings with the same root cause across two completed scans | No |
| `codex-security-deep-scan` | Reduced multi-pass deep scan (deep-lite — not equivalent to the official deep scan) | No |
| `codex-security-policy` | Drafts a SECURITY.md for a repository or component — the draft is saved outside the repo only | No |
| `codex-security-classify-severity` | Reclassifies a completed scan's findings against a rubric — results go to the scan directory and the workbench | No |

## Requirements

Claude Code (subscription login) · Python 3.10+ · git · the codex-security bundled plugin.
Node 22+ is needed for the plugin's npm install, the scan's candidate normalization (npm 0.2.0
moved it to an upstream Node helper), scoped-path and diff scans (npm 0.3.0 moved `bind-repo-scopes` and
`copy-deep-review-input` to the Node helper), the scan's SECURITY.md policy resolution (upstream Node helper),
`codex-security-policy` and `codex-security-classify-severity`, and for querying the official CLI's history.
Linux/macOS (Windows via WSL).

Verified combination: `@openai/codex-security@0.5.1` (plugin manifest `0.1.95`). npm 0.1.26 through
0.5.1 all report manifest `0.1.95`, so the manifest version warning cannot tell them apart. The skills
detect version-specific behavior from plugin files instead, and `--check` also shows the npm version.
Install npm 0.5.1. On an isolated install of npm 0.5.1, all five self-check scripts exit 0. With npm 0.5.0,
only checks P7 and P11 of `repro-u8` fail, because one line of the shared policy instructions changed in 0.5.1
and the pinned literal now follows 0.5.1 (an intended drift detection). The results below for 0.4.0 and
earlier are from the v0.5.0 release and were not re-run this time: on isolated installs of npm 0.4.0 and
0.3.0, all five scripts exited 0. With npm 0.2.0, `repro-u4`, `repro-u1`, `repro-u7`, and `repro-u5` pass
(checks for 0.4.0-only behavior print NOTE there); `repro-u8` fails one check, P7, because the policy progress text changed in 0.3.0 and the
pinned literal now follows 0.3.0+ (an intended drift detection). npm 0.1.32 and earlier were not
re-verified this time.

From npm 0.2.0 the scan skills need the npm package: an upstream source checkout has no built Node
helper, so candidate normalization is unavailable and the scans stop at step 0. npm 0.3.0, 0.4.0, 0.5.0, and 0.5.1 add
more state-database migrations (per-scan severity tables in 0.3.0, issue receipts in 0.4.0, scan source scopes
in 0.5.0, deep-scan worker thread history in 0.5.1); back up
`~/.codex/state/plugins/codex-security` before upgrading a global install.

The deep-lite skill changed with npm 0.4.0: upstream removed the ranking helpers, so deep-lite now reviews
the whole inventory twice in independent passes (about twice the cost of a standard scan) instead of
ranking and selecting the top files.

**Do not run `codex-security skills add` (npm 0.5.1 still has it).** It deletes `~/.claude/skills/codex-security-<command>`
and replaces it with a link to an upstream skill that only calls the login-requiring CLI. Six names collide
with these skills (scan, policy, patch, validate, verify-fix, classify-severity). `install.sh --check`
reports overwritten skills; reinstall with `bash skills/install.sh --force` (`--copy --force` for copies).

## Development

```bash
git clone https://github.com/kall/codex-security-claude-skills
cd codex-security-claude-skills
bash skills/install.sh --link --check     # linked install: edits take effect immediately
```

This repository does not contain the upstream source (`sdk/`), so developers also need to
obtain the plugin separately — either `npm install -g @openai/codex-security`, or clone the
upstream repo and set `CODEX_SECURITY_SDK_REPO=<clone path>`. As of plugin manifest `0.1.95`
both copies handle the working-tree gate the same way (completion succeeds with a warning);
older copies (`0.1.14`) diverged between hard failure and warning, so `--check` still probes
for it. See section 3.4 of the manual for details. An upstream checkout has no built `mcp/` or
`dist/`, so SECURITY.md policy resolution, `codex-security-policy`, and
`codex-security-classify-severity` need the npm install.

Check for contract regressions after updating the plugin:

```bash
bash docs/verification/scripts/repro-u4.sh                 # sealing contract + inventory accuracy
bash docs/verification/scripts/repro-u1-search-command.sh  # search-command acquisition + trust gate
bash docs/verification/scripts/repro-u7-coverage-recovery.sh  # coverage honesty + recovery path
bash docs/verification/scripts/repro-u5-match-validator.sh # match validator
bash docs/verification/scripts/repro-u8-policy-severity.sh # SECURITY.md drafting + severity reclassification (deterministic parts)
bash docs/verification/scripts/repro-u3.sh                 # workbench contract (observational)
```

The first five are self-scoring: **exit 0** = every assertion passed, **exit 2** (`INCOMPLETE`) =
no failures but some blocks could not be verified because a prerequisite was missing (this is *not*
a pass), **exit 1** = assertion failure. Whole-repository scans require ripgrep, because the
upstream inventory script resolves `rg` from PATH only; when PATH has no `rg`, the skill exposes
Claude Code's embedded ripgrep through a symlink. With neither available a scan will not start and
`repro-u4.sh` and `repro-u1-search-command.sh` exit 2.

- Release build/release process: [docs/releasing.md](docs/releasing.md)
- Design rationale and the 13 required contracts: [docs/solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md](docs/solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md)
- Step-by-step empirical verification: [docs/verification/](docs/verification/)

## License

Apache-2.0. See [NOTICE](NOTICE) for upstream provenance and derivative relationship.
