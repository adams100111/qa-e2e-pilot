# qa-kit review-follow-ups — design (S1/S2/SP1 + doc tidy)

> **Status:** design draft 2026-09-05. Cleans up the judgement-call findings from the two inline code reviews
> of increment 7 + its first fix (PRs #60/#61) and the doc-sync work (PRs #62–#65). **Engine byte-for-byte
> untouched; qa-kit byte-oracle + all suites stay green.** Small, low-risk, no new qa-kit behaviour.

## 1. Problem — the outstanding findings

Two inline reviews left a handful of *judgement-call* findings (nothing urgent, all verified against the code):

- **S1 / SP2 — install-script duplication.** The S2 fix wired each of the 3 `install-<h>.sh` with an identical
  `field()` helper + the same four field reads + a near-identical guard→build→mkdir→copy flow. Same logic shape
  in three files (Shotgun Surgery on any install change).
- **S2 — silent default on a missing profile key.** `field() { … .get('$1','') }` returns `''` for an
  absent/typo'd key, so `cp … "$PROJ/$AGENT_DIR/"` with an empty dir writes to the project root instead of
  failing loudly.
- **SP1 — the qa-kit CI suite list is hardcoded in `adapters.yml`.** A newly-added qa-kit test dir runs
  **ungated** until someone remembers to edit the workflow.
- **Doc tidy** — `docs/harness-adapters.md` lacks a qa-kit-specific "manual accuracy run" note; the engine
  adapter READMEs still say "16 skills" (now 17).

Measured fact bounding the CI decision: **a blanket `for d in tests/*/run.sh` glob is not viable** — running the
full 44-suite corpus locally **timed out at 2 min** (several *engine* suites are slow or hang without a live
app). So auto-enrolling *everything* is off the table; the fix must stay qa-kit-scoped.

## 2. Decisions (recommended; open at the review gate)

**D1 — Extract `qa-kit/harnesses/_install-common.sh`; installers become thin wrappers.** The common file holds
the whole flow, parameterised by a `HARNESS` variable the wrapper sets and the profile fields it reads
(`agentExt`, `agentDir`, `cmdDir`, `pluginRoot`, `engineSkillsDir`). Each `install-<h>.sh` collapses to:

```bash
#!/usr/bin/env bash
HARNESS=pi
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_install-common.sh"
```

The agent filename (`qa-kit.md` vs `qa-kit.toml`) derives from `agentExt`. The one genuine per-harness extra —
opencode's `opencode-skills` prerequisite echo — is a `[ "$HARNESS" = opencode ]` branch in the common file (a
single conditional, not a reason to keep three copies). *Note:* the engine keeps standalone per-harness
installers; this shared-lib is a **qa-kit-local** choice, justified because qa-kit's three are near-identical
where the engine's diverge (different MCP handling). Kills S1/SP2.

**`source` semantics the plan must honour (grill G1/G4):** the wrapper sets `HARNESS=…` then
`source …/_install-common.sh` with the project-dir still in `$1`. Inside the sourced file: (a) use **`$0`** in
the usage/`:?` message so it names the *wrapper* (`install-pi.sh`), not `_install-common.sh`; (b) resolve `ROOT`
and `PROFILE` from **the common file's own `BASH_SOURCE[0]`** (`qa-kit/harnesses/_install-common.sh` →
`ROOT=../..`, `PROFILE=../harness-profiles.qakit.json`), never the wrapper's; (c) `set -euo pipefail` lives in
the common file; (d) the opencode `opencode-skills` echo is preserved as the `[ "$HARNESS" = opencode ]` branch.

**D2 — `field()` fails loud on a missing key — via the CALLER, not inside the subshell (grill G2).** `field`
reads `['$1']` (KeyError on absence), prints a clear `missing harnesses.<h>.<field>` to **stderr**, and
**returns non-zero**. It **cannot** `die`/`exit` the installer itself — it runs inside `$(…)`, whose `exit`
only leaves the subshell. So every read is `VAR="$(field x)" || exit 1` (an explicit `||`, because `set -e`
does not reliably catch a failed command substitution in an assignment). Result: a profile typo/removal fails
at install with a legible error instead of an empty path that writes to the project root. Fixes S2.

**D3 — Single-source the qa-kit CI list in `qa-kit/scripts/run-qakit-ci.sh`.** One script runs
`validate-qakit-adapters.sh` + the qa-kit suites (the list lives here, the *obvious* place). `adapters.yml`'s
`qa-kit` job calls just this script, so adding a suite never touches the workflow again, and developers get a
one-command local gate. The list is still explicit (not a glob) — deliberately, per the measured fact above —
but now has exactly one home. Fixes SP1.

**D4 — Broader engine-corpus CI: explicitly deferred, with the reason recorded.** The whole `tests/` corpus
(engine suites included) is ungated, but a full glob is unsafe (D-fact: 2-min timeout / hangs). Wiring the
engine suites needs each vetted green in a clean CI image (node deps, no-live-app behaviour) — a **maintainer
decision**, tracked in `docs/doc-sync-todo.md`, not done here. The spec records *why* so it isn't re-litigated.

**D5 — Doc tidy (qa-kit-owned only).** Add a short "qa-kit manual accuracy run" note to the qa-kit section of
`docs/harness-adapters.md` (a shared doc; mirrors the engine's procedure, points at the co-install contract).
**Explicitly NOT here:** the engine adapter READMEs' "Runs the same 16 skills" → 17 fix. Those files
(`harnesses/{pi,codex,opencode}/README.md`) are **engine-owned**, and correcting them from a *qa-kit* change
would breach the engine-untouched discipline that has held all along. It's a real (17 is correct) but *engine*
doc concern — leave it as a separate engine-doc item in `docs/doc-sync-todo.md`, fixed under an engine change, not
this one.

## 3. Non-goals / invariants

- **Engine untouched** — no change to root `core/`/`commands/`/`skills/`/`scripts/`/`harness-profiles.json`/
  `build-adapter.sh`/`validate-adapters.sh`/`qa-verify`. (D5 edits *engine adapter READMEs*, which are docs, not
  the byte-oracle'd engine sources — confirm they're outside `validate-adapters.sh`'s diff before editing.)
- **Claude byte-oracle stays green** — D1–D3 touch only install scripts + a CI runner, never `qa-kit/core/` or
  the generator's output, so `validate-qakit-adapters.sh` is unaffected. Re-run it + `tests/qakit-adapters` +
  the install smoke (positive + abort) after D1/D2.
- No new qa-kit behaviour; the 7 qa-kit runtime scripts and the generator are unchanged.

## 4. Testing

- **Install smoke (positive + abort) for all 3 harnesses** must still pass after D1/D2 — the same temp-dir
  checks used in increment 7 (fake engine skills dir → files land in the right per-harness dirs; empty dir →
  abort).
- **Missing-field negative check for D2 — via a profile override, never the committed file (grill G3).**
  `_install-common.sh` reads `PROFILE` from an env-overridable `QAKIT_PROFILE` (default: the committed
  `qa-kit/harness-profiles.qakit.json`). The test copies the profile to a temp file, removes `agentDir`, runs an
  installer with `QAKIT_PROFILE=<temp>` against a fake-skills project dir, and asserts a **non-zero exit + a
  stderr message naming the missing field** — with **no edit to the real profile and no `git checkout`** to undo
  (the destructive-git rule stands).
- `run-qakit-ci.sh` (D3) run locally → all green; then `adapters.yml`'s `qa-kit` job (calling it) green in real CI.
- `validate-qakit-adapters.sh` + `tests/qakit-adapters/run.sh` green (byte-oracle unaffected).
- **Honest boundary unchanged:** still no live end-to-end qa-kit run per non-Claude harness — that remains the
  manual accuracy run (D4/D5 note it, don't close it).

## 5. Scope / phasing

Small enough for one plan, but naturally three independent tasks + docs: **(1)** `_install-common.sh` + wrappers
+ fail-loud `field()` (D1/D2) with the smoke/negative tests; **(2)** `run-qakit-ci.sh` + `adapters.yml` rewire
(D3); **(3)** doc tidy (D5). D4 is a decision, not a task (a one-line reason already in the todo). Each task
ends green and independently reviewable.
