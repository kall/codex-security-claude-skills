# Claude Local Security Skills (codex-security-claude-skills)

English | [한국어](README.ko.md)

6 Claude Code skills that run the [codex-security](https://github.com/openai/codex-security)
security scan workflow using **only a Claude Code subscription login** — no OpenAI/Codex
authentication required.

Claude Code itself acts as the LLM brain for the session. Validation, ID derivation, sealing,
and report generation are handled by the deterministic Python scripts bundled with the
codex-security plugin. The plugin is not vendored — it is discovered and used from whatever
is installed at runtime.

> This is a non-Codex execution path and is **not supported by upstream OpenAI.**

## Install (users)

Download the release tarball and install it. You can also just hand the link to a Claude Code
session and say "install this."

```bash
BASE=https://github.com/kall/codex-security-claude-skills/releases/latest/download
PKG=codex-security-claude-skills-<version>

curl -fsSLO "$BASE/$PKG.tar.gz"
curl -fsSL  "$BASE/SHA256SUMS" | sha256sum -c -
tar xzf "$PKG.tar.gz"
bash "$PKG/skills/install.sh" --copy --check
```

`--check` probes the bundled plugin, Python, and gate copy, and reports the results. If the
plugin is missing, it prints the install command (it does not install automatically):

```bash
npm install -g @openai/codex-security     # Node 22+
```

Restart Claude Code, then invoke:

```
/security-scan-local /path/to/repo
```

Full usage, environment variables, and troubleshooting:
**[docs/install-and-usage.md](docs/install-and-usage.md)**

## Skills

| Skill | Purpose | Modifies the repo |
| --- | --- | --- |
| `security-scan-local` | One-shot full-repo standard scan → sealed contract artifacts + `report.md` + SARIF | No |
| `security-diff-scan-local` | Scans only a diff (refs or working-tree) | No |
| `security-validate-local` | Judges a candidate finding's disposition | No |
| `security-patch-local` | Minimal fix for a security issue — two-stage approval | Yes (after approval) |
| `security-scan-match-local` | Matches findings with the same root cause across two completed scans | No |
| `security-deep-scan-local` | Reduced multi-pass deep scan (deep-lite — not equivalent to the official deep scan) | No |

## Requirements

Claude Code (subscription login) · Python 3.10+ · git · the codex-security bundled plugin.
Node 22+ is only needed for the plugin's npm install and for querying the official CLI's
history. Linux/macOS (Windows via WSL).

Verified combination: `@openai/codex-security@0.1.3` (plugin manifest `0.1.14`).

## Development

```bash
git clone https://github.com/kall/codex-security-claude-skills
cd codex-security-claude-skills
bash skills/install.sh --link --check     # linked install: edits take effect immediately
```

This repository does not contain the upstream source (`sdk/`), so developers also need to
obtain the plugin separately — either `npm install -g @openai/codex-security`, or clone the
upstream repo and set `CODEX_SECURITY_SDK_REPO=<clone path>`. **Working-tree gate handling
differs between copies even at the same plugin manifest version** (hard failure vs. warning),
so comparing two copies requires an upstream clone. See section 3.4 of the manual for details.

Check for contract regressions after updating the plugin:

```bash
bash docs/verification/scripts/repro-u4.sh    # sealing contract
bash docs/verification/scripts/repro-u3.sh    # workbench contract
```

- Release build/release process: [docs/releasing.md](docs/releasing.md)
- Design rationale and the 8 required contracts: [docs/solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md](docs/solutions/architecture-patterns/codex-security-plugin-without-openai-auth.md)
- Step-by-step empirical verification: [docs/verification/](docs/verification/)

## License

Apache-2.0. See [NOTICE](NOTICE) for upstream provenance and derivative relationship.
