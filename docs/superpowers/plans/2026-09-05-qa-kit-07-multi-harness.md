# qa-kit increment 7 — multi-harness portability (Codex · Pi · opencode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.
>
> Design: `docs/superpowers/specs/2026-09-05-qa-kit-multi-harness-portability-design.md` (grill-hardened ×2).

**Goal:** Generate qa-kit's step-command adapters for **codex, pi, opencode** from one tokenized
`qa-kit/core/`, mirroring the engine's ADR-0017 machinery **qa-kit-owned**, with the qa-e2e-pilot **engine
byte-for-byte unchanged** and the **Claude qa-kit files reproduced byte-for-byte** by the new generator.

**Architecture:** A qa-kit-owned copy of the engine's `core/→dist/<h>/` pipeline: `qa-kit/core/` (persona +
5 command bodies, tokenized) + `qa-kit/harness-profiles.qakit.json` + `qa-kit/scripts/build-qakit-adapter.sh` +
`qa-kit/scripts/validate-qakit-adapters.sh` + `qa-kit/harnesses/<h>/` glue. Claude qa-kit becomes
**generated-and-committed**; a Claude byte-oracle guards drift. The 8 cross-plugin references become tokens
rendered per harness: 7 are **engine skills** (`{{SKILL_REF:<name>}}`), 1 is the **engine's `qa-run` command**
(`{{ENGINE_RUN}}`). qa-kit's own scripts are reached via `{{PLUGIN_ROOT}}`.

**Tech Stack:** Bash + `python3` (the engine's `build-adapter.sh` idiom — jq-free render); no `grep -P`/`perl`/`node`.

## Global Constraints

- **Engine untouched.** No change to root `core/`, `commands/`, `skills/`, `scripts/`, `harness-profiles.json`,
  `build-adapter.sh`, `validate-adapters.sh`, `qa-verify.sh`, `agents/`. qa-kit's generator MAY **read**
  `harness-profiles.json` read-only. Verify with `git diff --name-only` after every task.
- **Claude byte-oracle.** `build-qakit-adapter.sh claude` must reproduce the **current committed**
  `qa-kit/commands/*.md` + `qa-kit/agents/qa-kit.md` byte-for-byte. Snapshot them as the golden in Task 1
  BEFORE extracting `qa-kit/core/`. The committed Claude files must not change.
- **No fork/vendor (ADR-0001).** The 7 engine skills are referenced, never copied into qa-kit.
- **Never commit `qa-kit/dist/`** — add it to `.gitignore` in Task 1.
- **No attribution / `Co-Authored-By`.** Dual-engine scripts stay `jq`/`python3`; render is python3 (j
  q-free, exactly like `build-adapter.sh`).
- **Packaging/composition only — zero behaviour change** to the 7 qa-kit scripts or the command *logic*; only
  the Claude-specific *literals* become tokens.

### The token set (rendered by `build-qakit-adapter.sh`)

| Token | claude | pi | codex | opencode |
|---|---|---|---|---|
| `{{SKILL_REF:<name>}}` | `/qa-e2e-pilot:<name>` | `the \`<name>\` skill` | `the \`<name>\` skill` | `the \`skills_<name>\` tool` |
| `{{ENGINE_RUN}}` | `/qa-e2e-pilot:qa-run` | `the \`/qa-run\` prompt` | `the \`/qa-run\` prompt` | `the \`/qa-run\` command` |
| `{{QAKIT_CMD:<name>}}` | `/<name>` | `the \`/<name>\` prompt` | `the \`/<name>\` prompt` | `the \`/<name>\` command` |
| `{{PLUGIN_ROOT}}` | `${CLAUDE_PLUGIN_ROOT}` | `.pi/qa-kit` | `.codex/qa-kit` | `.opencode/qa-kit` |
| `{{PERSONA_BODY}}` | (agent body inlined by the manifest template) | — | — | — |

The 7 engine skills (verified present under `skills/<name>/`): `detecting-stack-profile`, `ingesting-spec-kit`,
`discovering-user-roles`, `confirming-discovered-roles`, `fanning-out-criteria`, `generating-qa-checklist`,
`analyzing-feature-ui`. `qa-run` is the engine's **command**, rendered by `{{ENGINE_RUN}}` (not a skill).
`qa-status` references **no** engine skill and **no** `{{PLUGIN_ROOT}}` — it renders identically on every harness.

## File Structure

```
qa-kit/
  core/                              NEW  persona-body.md + commands/{qa-constitution,qa-spec,qa-scenarios,qa-analyze,qa-status}.md (tokenized)
  harness-profiles.qakit.json        NEW  per-harness: skillRef, engineRun, qakitCmd, pluginRoot, agentExt, agentDir, cmdDir, filesDir
  scripts/
    build-qakit-adapter.sh           NEW  render qa-kit/dist/<h>/ from core + profile + harnesses/<h>/
    validate-qakit-adapters.sh       NEW  build all 4 + Claude byte-oracle + residual-{{token}} check
  harnesses/{pi,codex,opencode}/     NEW  manifest.tmpl (agent wrapper) + install-<h>.sh + README.md
  dist/<h>/                          BUILD OUTPUT (git-ignored)
  commands/*.md  agents/qa-kit.md    GENERATED-AND-COMMITTED (claude) — byte-identical to `build ... claude`
tests/qakit-adapters/run.sh          NEW  cross-harness render assertions
```

---

## Task 1: `qa-kit/core/` extraction + generator + Claude byte-repro (the golden)

**Files:** Create `qa-kit/core/persona-body.md`, `qa-kit/core/commands/{qa-constitution,qa-spec,qa-scenarios,qa-analyze,qa-status}.md`,
`qa-kit/harness-profiles.qakit.json`, `qa-kit/scripts/build-qakit-adapter.sh`; Modify `.gitignore`.
Golden: current committed `qa-kit/commands/*.md` + `qa-kit/agents/qa-kit.md`.

**Interfaces:**
- Produces: `build-qakit-adapter.sh <claude|pi|codex|opencode>` → writes `qa-kit/dist/<h>/{agent/,commands/,scripts/,templates/}`.
  For `claude`, `dist/claude/commands/*.md` ≡ committed `qa-kit/commands/*.md` and `dist/claude/agent/qa-kit.md` ≡ committed `qa-kit/agents/qa-kit.md`.

- [ ] **Step 1: Snapshot the golden.**
```bash
mkdir -p /tmp/qakit-golden/commands
cp qa-kit/commands/*.md /tmp/qakit-golden/commands/
cp qa-kit/agents/qa-kit.md /tmp/qakit-golden/qa-kit.md
```

- [ ] **Step 2: Write `qa-kit/harness-profiles.qakit.json`** (the four rows; values are the token table above):
```json
{
  "harnesses": {
    "claude":   { "skillRef": "/qa-e2e-pilot:{name}", "engineRun": "/qa-e2e-pilot:qa-run", "qakitCmd": "/{name}",
                  "pluginRoot": "${CLAUDE_PLUGIN_ROOT}", "agentExt": "md" },
    "pi":       { "skillRef": "the `{name}` skill", "engineRun": "the `/qa-run` prompt", "qakitCmd": "the `/{name}` prompt",
                  "pluginRoot": ".pi/qa-kit", "agentExt": "md", "agentDir": ".pi/agents", "cmdDir": ".pi/prompts", "filesDir": ".pi/qa-kit" },
    "codex":    { "skillRef": "the `{name}` skill", "engineRun": "the `/qa-run` prompt", "qakitCmd": "the `/{name}` prompt",
                  "pluginRoot": ".codex/qa-kit", "agentExt": "toml", "agentDir": ".codex/agents", "cmdDir": ".codex/prompts", "filesDir": ".codex/qa-kit" },
    "opencode": { "skillRef": "the `skills_{name}` tool", "engineRun": "the `/qa-run` command", "qakitCmd": "the `/{name}` command",
                  "pluginRoot": ".opencode/qa-kit", "agentExt": "md", "agentDir": ".opencode/agent", "cmdDir": ".opencode/command", "filesDir": ".opencode/qa-kit" }
  }
}
```

- [ ] **Step 3: Extract `qa-kit/core/` from the golden.** For each command + the agent body, copy the golden
  text and replace ONLY the Claude-specific literals with tokens:
  - `/qa-e2e-pilot:<skill>` (the 7 skills) → `{{SKILL_REF:<skill>}}`
  - `/qa-e2e-pilot:qa-run` → `{{ENGINE_RUN}}`
  - any qa-kit inter-command ref `/qa-<name>` (e.g. "next: `/qa-scenarios`") → `{{QAKIT_CMD:qa-<name>}}`
  - `${CLAUDE_PLUGIN_ROOT}` → `{{PLUGIN_ROOT}}`
  - The agent body → `qa-kit/core/persona-body.md`; the command frontmatter stays in each `core/commands/<name>.md`.
  - `qa-status.md` has no tokens — copy verbatim.
  - **Tokenize only refs that INVOKE** a skill/command, not every string mention. Over-tokenizing still passes
    the Claude byte-oracle (claude renders back identically) but produces awkward prose on other harnesses
    (`the \`/qa-spec\` prompt` where a plain noun was meant) — the manual accuracy run is the only catch, so
    keep tokens to genuine invocations. When unsure, leave the literal (a bare `/qa-spec` reads fine everywhere).
  Also create `qa-kit/harnesses/claude/manifest.tmpl` = the agent frontmatter wrapper:
```
---
name: qa-kit
description: <copy the exact description line from the golden agent frontmatter>
---
{{PERSONA_BODY}}
```

- [ ] **Step 4: Write `qa-kit/scripts/build-qakit-adapter.sh`** — model on `scripts/build-adapter.sh`
  (python3 render, temp-file render script per its NOTE). Read the qa-kit profile fields for `<h>`; render with
  a python replacer that handles **parametric** tokens:
```python
import sys, os, re, json
h = os.environ["H"]; prof = json.load(open(os.environ["PROFILE"]))["harnesses"][h]
data = sys.stdin.read()
def sub_param(tok, tmpl):
    # {{TOK:name}} -> tmpl with {name} replaced
    return re.sub(r"\{\{%s:([a-z0-9-]+)\}\}" % tok,
                  lambda m: tmpl.replace("{name}", m.group(1)), data)
data = sub_param("SKILL_REF", prof["skillRef"])
data = sub_param("QAKIT_CMD", prof["qakitCmd"])
data = data.replace("{{ENGINE_RUN}}", prof["engineRun"])
data = data.replace("{{PLUGIN_ROOT}}", prof["pluginRoot"])
if "PERSONA_BODY_FILE" in os.environ:
    data = data.replace("{{PERSONA_BODY}}", open(os.environ["PERSONA_BODY_FILE"]).read().rstrip("\n"))
sys.stdout.write(data)
```
  Assemble `qa-kit/dist/<h>/`: `rm -rf` then `mkdir -p agent commands`; render each `core/commands/*.md` →
  `dist/<h>/commands/<name>.md`; render `core/persona-body.md` → a temp file, then render
  `harnesses/<h>/manifest.tmpl` (with `PERSONA_BODY_FILE` set) → `dist/<h>/agent/qa-kit.<agentExt>`; `cp -R`
  `qa-kit/scripts qa-kit/templates` into `dist/<h>/` (copied verbatim — the 7 scripts unchanged). Fail if any
  `{{` survives in `dist/<h>/agent` or `dist/<h>/commands`.
  **Codex `'''` guard (mirror `build-adapter.sh:78-80`):** when `H=codex`, before rendering, abort if
  `qa-kit/core/persona-body.md` contains a literal `'''` — it would break the codex TOML `'''…'''` literal
  string: `if [ "$H" = codex ] && grep -q "'''" "$QAKIT/core/persona-body.md"; then echo "ERROR: persona body contains ''' — breaks codex TOML literal" >&2; exit 1; fi`.

- [ ] **Step 5: Build claude and prove byte-identity to the golden.**
```bash
bash qa-kit/scripts/build-qakit-adapter.sh claude
diff -u /tmp/qakit-golden/qa-kit.md qa-kit/dist/claude/agent/qa-kit.md && echo "AGENT OK"
for f in qa-constitution qa-spec qa-scenarios qa-analyze qa-status; do
  diff -u /tmp/qakit-golden/commands/$f.md qa-kit/dist/claude/commands/$f.md || { echo "DRIFT: $f"; exit 1; }
done; echo "COMMANDS OK"
```
  Expected: `AGENT OK` + `COMMANDS OK`, zero diff. If any diff, fix the `core/` extraction (a literal became a
  token that renders differently, or a token was missed) until identical. **The committed Claude files are the
  spec; the generator conforms to them, never the reverse.**

- [ ] **Step 6: Ignore the build output.** Append to `.gitignore`:
```
qa-kit/dist/
```

- [ ] **Step 7: Commit.**
```bash
git add qa-kit/core qa-kit/harness-profiles.qakit.json qa-kit/harnesses/claude qa-kit/scripts/build-qakit-adapter.sh .gitignore
git commit -m "feat(qa-kit): tokenized core + generator; Claude adapter byte-reproduces committed files"
```

---

## Task 2: `validate-qakit-adapters.sh` — the committed Claude byte-oracle gate

**Files:** Create `qa-kit/scripts/validate-qakit-adapters.sh`.

**Interfaces:** `validate-qakit-adapters.sh` (no args) → builds all four adapters, asserts Claude dist ≡ committed
`qa-kit/commands` + `qa-kit/agents`, greps for residual `{{` in every `dist/<h>/agent`+`commands`; exit 0 on OK.

- [ ] **Step 1: Write the script** (model on `scripts/validate-adapters.sh`):
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"        # qa-kit/
REPO="$(cd "$ROOT/.." && pwd)"
for h in claude pi codex opencode; do bash "$ROOT/scripts/build-qakit-adapter.sh" "$h"; done
# Claude byte-oracle: committed == generated
diff -r "$ROOT/commands" "$ROOT/dist/claude/commands" >/dev/null || { echo "byte-oracle FAIL: commands drift"; exit 1; }
diff "$ROOT/agents/qa-kit.md" "$ROOT/dist/claude/agent/qa-kit.md" >/dev/null || { echo "byte-oracle FAIL: agent drift"; exit 1; }
# no residual tokens anywhere
if grep -rn '{{' "$ROOT"/dist/*/agent "$ROOT"/dist/*/commands ; then echo "residual token"; exit 1; fi
echo "validate-qakit-adapters: OK"
```

- [ ] **Step 2: Run → `OK`.** `bash qa-kit/scripts/validate-qakit-adapters.sh`.
- [ ] **Step 3: Negative check** — introduce a one-char change in `qa-kit/commands/qa-status.md`, re-run,
  confirm it FAILS the byte-oracle, then revert the change (do NOT commit the tamper).
- [ ] **Step 4: Commit.** `git add qa-kit/scripts/validate-qakit-adapters.sh && git commit -m "test(qa-kit): validate-qakit-adapters — Claude byte-oracle + residual-token gate"`

---

## Task 3: Pi adapter (validated-first harness)

**Files:** Create `qa-kit/harnesses/pi/{manifest.tmpl, install-pi.sh, README.md}`. (Profile `pi` row already in Task 1.)

**Interfaces:** `install-pi.sh <project-dir>` installs the engine pi adapter's *dependency* contract + qa-kit's
commands/agent/scripts into pi's dirs; renders qa-kit skill refs to bare names resolved from `.pi/agents/skills/`.

- [ ] **Step 1: `qa-kit/harnesses/pi/manifest.tmpl`** (agent wrapper, pi md frontmatter — mirror
  `harnesses/pi/manifest.tmpl`):
```
---
name: qa-kit
description: <same description as core; single line>
tools: read, bash, edit, write, mcp
---
{{PERSONA_BODY}}
```

- [ ] **Step 2: `qa-kit/harnesses/pi/install-pi.sh`** — build pi, then place qa-kit files beside the engine's
  (which must already be installed — preflight it):
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"      # repo root
QAKIT="$ROOT/qa-kit"
PROJ="${1:?usage: install-pi.sh <project-dir>}"
# co-install contract: the engine pi adapter must already be installed (its skills feed qa-kit's bare-name refs)
[ -d "$PROJ/.pi/agents/skills/detecting-stack-profile" ] || { echo "ERROR: engine pi adapter not installed — run harnesses/pi/install-pi.sh first (qa-kit reuses its skills)"; exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" pi
mkdir -p "$PROJ/.pi/prompts" "$PROJ/.pi/agents" "$PROJ/.pi/qa-kit/scripts" "$PROJ/.pi/qa-kit/templates"
cp "$QAKIT/dist/pi/agent/qa-kit.md" "$PROJ/.pi/agents/"
cp "$QAKIT/dist/pi/commands/"*.md "$PROJ/.pi/prompts/"
cp -R "$QAKIT/dist/pi/scripts/." "$PROJ/.pi/qa-kit/scripts/"
cp -R "$QAKIT/dist/pi/templates/." "$PROJ/.pi/qa-kit/templates/" 2>/dev/null || true
echo "Installed qa-kit Pi adapter into $PROJ (.pi/). qa-kit scripts under .pi/qa-kit/ ({{PLUGIN_ROOT}})."
echo "Skill refs resolve to the engine's .pi/agents/skills/. Manual accuracy run: see qa-kit/harnesses/pi/README.md."
```

- [ ] **Step 3: `qa-kit/harnesses/pi/README.md`** — prerequisites (engine pi adapter installed FIRST), the
  co-install contract (D5), install command, the bare-name skill-resolution note, and the "manual accuracy run"
  honest boundary (no headless e2e). Mirror `harnesses/pi/README.md`'s shape.

- [ ] **Step 4: Build + assert pi tokens rendered.**
```bash
bash qa-kit/scripts/build-qakit-adapter.sh pi
grep -q 'the `detecting-stack-profile` skill' qa-kit/dist/pi/commands/qa-spec.md && echo "SKILL_REF ok"
grep -q '.pi/qa-kit/scripts' qa-kit/dist/pi/commands/qa-spec.md && echo "PLUGIN_ROOT ok"
! grep -rn '{{' qa-kit/dist/pi/commands qa-kit/dist/pi/agent && echo "no residual"
bash -n qa-kit/harnesses/pi/install-pi.sh && echo "install syntax ok"
```

- [ ] **Step 5: Commit.** `git add qa-kit/harnesses/pi && git commit -m "feat(qa-kit): Pi adapter — install + agent manifest + README (bare-name skill refs, co-install contract)"`

---

## Task 4: Codex adapter

**Files:** Create `qa-kit/harnesses/codex/{manifest.tmpl, install-codex.sh, README.md}`.

- [ ] **Step 1: `qa-kit/harnesses/codex/manifest.tmpl`** — codex TOML agent (mirror `harnesses/codex/manifest.tmpl`;
  it embeds the body in a `'''...'''` literal). Include the `'''`-guard note. Shape:
```toml
name = "qa-kit"
instructions = '''
{{PERSONA_BODY}}
'''
```
  (Copy the exact key names + structure from `harnesses/codex/manifest.tmpl`.)

- [ ] **Step 2: `qa-kit/harnesses/codex/install-codex.sh`** — build codex; preflight the engine codex adapter
  (skills at **`.agents/skills/`** — codex's split layout); place qa-kit agent → `.codex/agents/qa-kit.toml`,
  commands → `.codex/prompts/`, scripts/templates → `.codex/qa-kit/`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; QAKIT="$ROOT/qa-kit"
PROJ="${1:?usage: install-codex.sh <project-dir>}"
[ -d "$PROJ/.agents/skills/detecting-stack-profile" ] || { echo "ERROR: engine codex adapter not installed — run harnesses/codex/install-codex.sh first"; exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" codex
mkdir -p "$PROJ/.codex/agents" "$PROJ/.codex/prompts" "$PROJ/.codex/qa-kit/scripts" "$PROJ/.codex/qa-kit/templates"
cp "$QAKIT/dist/codex/agent/qa-kit.toml" "$PROJ/.codex/agents/"
cp "$QAKIT/dist/codex/commands/"*.md "$PROJ/.codex/prompts/"
cp -R "$QAKIT/dist/codex/scripts/." "$PROJ/.codex/qa-kit/scripts/"
cp -R "$QAKIT/dist/codex/templates/." "$PROJ/.codex/qa-kit/templates/" 2>/dev/null || true
echo "Installed qa-kit Codex adapter into $PROJ. qa-kit scripts under .codex/qa-kit/. Skills resolve from .agents/skills/."
```

- [ ] **Step 3: `qa-kit/harnesses/codex/README.md`** — prerequisites (engine codex adapter first; note the
  `.agents/skills/` vs `.codex/agents/` split), co-install contract, manual accuracy boundary.

- [ ] **Step 4: Build + assert.**
```bash
bash qa-kit/scripts/build-qakit-adapter.sh codex
test -f qa-kit/dist/codex/agent/qa-kit.toml && echo "toml agent ok"
grep -q 'the `detecting-stack-profile` skill' qa-kit/dist/codex/commands/qa-spec.md && echo "SKILL_REF ok"
grep -q '.codex/qa-kit/scripts' qa-kit/dist/codex/commands/qa-spec.md && echo "PLUGIN_ROOT ok"
! grep -rn '{{' qa-kit/dist/codex/commands qa-kit/dist/codex/agent && echo "no residual"
bash -n qa-kit/harnesses/codex/install-codex.sh && echo "install syntax ok"
```

- [ ] **Step 5: Commit.** `git add qa-kit/harnesses/codex && git commit -m "feat(qa-kit): Codex adapter — TOML agent + install (.agents/skills split) + README"`

---

## Task 5: opencode adapter

**Files:** Create `qa-kit/harnesses/opencode/{manifest.tmpl, install-opencode.sh, README.md}`.

- [ ] **Step 1: `qa-kit/harnesses/opencode/manifest.tmpl`** — opencode md agent (mirror
  `harnesses/opencode/manifest.tmpl`). Shape:
```
---
name: qa-kit
description: <same description>
---
{{PERSONA_BODY}}
```

- [ ] **Step 2: `qa-kit/harnesses/opencode/install-opencode.sh`** — build opencode; preflight the engine
  opencode adapter (`.opencode/skills/`) **and** warn about the `opencode-skills` plugin prerequisite; place
  agent → `.opencode/agent/qa-kit.md`, commands → `.opencode/command/`, scripts/templates → `.opencode/qa-kit/`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; QAKIT="$ROOT/qa-kit"
PROJ="${1:?usage: install-opencode.sh <project-dir>}"
[ -d "$PROJ/.opencode/skills/detecting-stack-profile" ] || { echo "ERROR: engine opencode adapter not installed — run harnesses/opencode/install-opencode.sh first"; exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" opencode
mkdir -p "$PROJ/.opencode/agent" "$PROJ/.opencode/command" "$PROJ/.opencode/qa-kit/scripts" "$PROJ/.opencode/qa-kit/templates"
cp "$QAKIT/dist/opencode/agent/qa-kit.md" "$PROJ/.opencode/agent/"
cp "$QAKIT/dist/opencode/commands/"*.md "$PROJ/.opencode/command/"
cp -R "$QAKIT/dist/opencode/scripts/." "$PROJ/.opencode/qa-kit/scripts/"
cp -R "$QAKIT/dist/opencode/templates/." "$PROJ/.opencode/qa-kit/templates/" 2>/dev/null || true
echo "Installed qa-kit opencode adapter into $PROJ. REQUIRES the 'opencode-skills' plugin enabled in opencode.json"
echo "(else skills_<name> tools are inert) — see qa-kit/harnesses/opencode/README.md."
```

- [ ] **Step 3: `qa-kit/harnesses/opencode/README.md`** — prerequisites (engine opencode adapter + the
  `opencode-skills` community plugin, quoting the engine README's requirement), co-install contract, the
  `skills_<name>` tool form, manual accuracy boundary.

- [ ] **Step 4: Build + assert.**
```bash
bash qa-kit/scripts/build-qakit-adapter.sh opencode
grep -q 'the `skills_detecting-stack-profile` tool' qa-kit/dist/opencode/commands/qa-spec.md && echo "SKILL_REF(tool) ok"
grep -q '.opencode/qa-kit/scripts' qa-kit/dist/opencode/commands/qa-spec.md && echo "PLUGIN_ROOT ok"
! grep -rn '{{' qa-kit/dist/opencode/commands qa-kit/dist/opencode/agent && echo "no residual"
bash -n qa-kit/harnesses/opencode/install-opencode.sh && echo "install syntax ok"
```

- [ ] **Step 5: Commit.** `git add qa-kit/harnesses/opencode && git commit -m "feat(qa-kit): opencode adapter — skills_<name> tool refs + install (opencode-skills prereq) + README"`

---

## Task 6: Cross-harness render test suite

**Files:** Create `tests/qakit-adapters/run.sh`.

**Interfaces:** `tests/qakit-adapters/run.sh` — builds all 4, asserts per-harness rendering + engine-skill existence.

- [ ] **Step 1: Write the test:**
```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$DIR/../.."
B="$REPO/qa-kit/scripts/build-qakit-adapter.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
for h in claude pi codex opencode; do bash "$B" "$h" >/dev/null; done
D="$REPO/qa-kit/dist"
# (a) all 5 commands + agent emitted per harness, right agent ext
for h in claude pi codex opencode; do
  n=$(ls "$D/$h/commands" | wc -l | tr -d ' '); check "$h has 5 commands" "$n" "5"
done
check "claude agent md"   "$(ls "$D/claude/agent")"   "qa-kit.md"
check "codex agent toml"  "$(ls "$D/codex/agent")"    "qa-kit.toml"
# (b) skill refs render per harness (qa-spec references detecting-stack-profile)
grep -q '/qa-e2e-pilot:detecting-stack-profile' "$D/claude/commands/qa-spec.md"        && check "claude slug" ok ok
grep -q 'the `detecting-stack-profile` skill'  "$D/pi/commands/qa-spec.md"             && check "pi bare"    ok ok
grep -q 'the `detecting-stack-profile` skill'  "$D/codex/commands/qa-spec.md"          && check "codex bare" ok ok
grep -q 'the `skills_detecting-stack-profile` tool' "$D/opencode/commands/qa-spec.md"  && check "oc tool"    ok ok
# (c) no residual tokens anywhere
for h in claude pi codex opencode; do
  if grep -rq '{{' "$D/$h/commands" "$D/$h/agent"; then check "$h no residual" bad ok; else check "$h no residual" ok ok; fi
done
# (d) every rendered engine-skill name resolves to a real engine skills/<name>/ dir (the composition's fragility)
for s in detecting-stack-profile ingesting-spec-kit discovering-user-roles confirming-discovered-roles fanning-out-criteria generating-qa-checklist analyzing-feature-ui; do
  check "engine skill $s exists" "$([ -d "$REPO/skills/$s" ] && echo y)" "y"
done
# (e) Claude byte-oracle (committed == generated)
diff -rq "$REPO/qa-kit/commands" "$D/claude/commands" >/dev/null && check "claude cmd byte-oracle" ok ok || check "claude cmd byte-oracle" drift ok
diff -q "$REPO/qa-kit/agents/qa-kit.md" "$D/claude/agent/qa-kit.md" >/dev/null && check "claude agent byte-oracle" ok ok || check "claude agent byte-oracle" drift ok
echo "qakit-adapters: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run → `FAIL=0`.** `bash tests/qakit-adapters/run.sh`.
- [ ] **Step 3: Commit.** `git add tests/qakit-adapters && git commit -m "test(qa-kit): cross-harness adapter render suite (skill-ref forms, byte-oracle, engine-skill existence)"`

---

## Task 7: Docs — flip the "Claude-only" narrative + ADR-0024

**Files:** Modify `docs/harness-adapters.md`, `docs/adr/0022-qa-kit-process-shell.md`, `qa-kit/README.md`,
`CLAUDE.md`; Create `docs/adr/0024-qa-kit-multi-harness.md`.

- [ ] **Step 1: `docs/harness-adapters.md`** — replace "Installing qa-kit (Claude only, for now)" + "Non-Claude
  qa-kit is not built yet" with the shipped install: per-harness `qa-kit/harnesses/<h>/install-<h>.sh`, the
  **engine-adapter-first co-install contract**, and the opencode `opencode-skills` prerequisite.
- [ ] **Step 2: `docs/adr/0022`** — add a superseded note: "v1 Claude-only (§…) is lifted by ADR-0024
  (increment 7); qa-kit now generates codex/pi/opencode adapters from `qa-kit/core/`, engine still untouched."
- [ ] **Step 3: Create `docs/adr/0024-qa-kit-multi-harness.md`** — decisions: mirror ADR-0017 qa-kit-owned;
  skill composition = per-harness reference (claude slug / codex·pi bare / opencode `skills_<name>`) resolved
  from the engine's co-installed shared skills dir (the grill-2 correction — no path/vendor); Claude
  generated-and-committed + byte-oracle; co-install contract; the 7 qa-kit scripts unchanged. Consequences:
  engine untouched; co-install ordering; opencode's `opencode-skills` dependency; manual accuracy run per harness.
- [ ] **Step 4: `qa-kit/README.md`** — add a "Running on other harnesses" section (the four installers, the
  co-install contract, per-harness skill-ref forms). `CLAUDE.md` — update the qa-kit layout block (add
  `qa-kit/core/`, `harness-profiles.qakit.json`, `build-qakit-adapter.sh`, `validate-qakit-adapters.sh`,
  `harnesses/`) and note qa-kit is no longer Claude-only.
- [ ] **Step 5: Final gate + commit.**
```bash
bash qa-kit/scripts/validate-qakit-adapters.sh          # OK
bash tests/qakit-adapters/run.sh                        # FAIL=0
bash scripts/validate-adapters.sh                       # engine byte-oracle still OK
git diff --name-only main...HEAD | grep -E '^(core/|commands/|skills/|scripts/build-adapter|scripts/validate-adapters|harness-profiles.json|qa-verify)' && echo "!!! ENGINE TOUCHED" || echo "engine untouched OK"
for d in constitution spec-snapshot qa-kit-enforcement runconfig-merge data-baseline check-fixtures detect-seed auto-seed qa-kit-phases qakit-adapters; do bash tests/$d/run.sh >/dev/null && echo "$d ok"; done
git add docs qa-kit/README.md CLAUDE.md && git commit -m "docs(qa-kit): multi-harness install + ADR-0024 + harness-adapters flip + README/CLAUDE (engine untouched)"
```

---

## Self-Review

**1. Spec coverage:** D1 core+profile+generator+validator → Tasks 1/2; D2 generated-and-committed + byte-repro →
Task 1 Step 5 + Task 2; D3 skill composition per-harness → the token table + Tasks 3/4/5 asserts + Task 6(b);
D4 `{{PLUGIN_ROOT}}` → token table + Task asserts; D5 co-install contract → each install-<h>.sh preflight +
READMEs; D6 scripts unchanged/hooks prose → scripts copied verbatim, no hook work; §6 tests → Task 6; doc/ADR
updates → Task 7. ✅

**2. Placeholder scan:** full JSON profile (Task 1.2), full render python (1.4), full validate script (2.1),
full install scripts (3/4/5.2), full test (6.1), exact assert commands. The `core/` extraction (1.3) is a
mechanical literal→token substitution constrained by the Task-1.5 byte-oracle (any error shows as a diff), not
a vague step. install READMEs reference the concrete engine `harnesses/<h>/README.md` as the shape to mirror.

**3. Type consistency:** tokens `{{SKILL_REF:<name>}}`/`{{ENGINE_RUN}}`/`{{QAKIT_CMD:<name>}}`/`{{PLUGIN_ROOT}}`/
`{{PERSONA_BODY}}` used identically in the profile, generator, and asserts. Profile fields
(`skillRef`/`engineRun`/`qakitCmd`/`pluginRoot`/`agentExt`/`agentDir`/`cmdDir`/`filesDir`) consistent across
Task 1.2 and the install scripts. The 7 engine skill names identical in the constraints, Task 1.3, and Task 6(d).

## Execution Handoff

SDD or inline. **Task 1 is the linchpin** (the Claude byte-repro golden) and gates everything — do it first and
do not proceed until `AGENT OK` + `COMMANDS OK` with zero diff. Then Task 2 (gate), then pi → codex → opencode
(3→4→5, independent), Task 6 (consolidated test), Task 7 (docs). The engine stays untouched throughout; a live
end-to-end qa-kit run on each non-Claude harness is the **manual accuracy run** (honest boundary), not a
headless test.
