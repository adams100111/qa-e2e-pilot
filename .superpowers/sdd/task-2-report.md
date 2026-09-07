# Task 2 report — interaction-ux dead-end false positive (W3-5a)

## Status
DONE

## Worktree / branch
`/home/dev/repos/qa-e2e-pilot/.claude/worktrees/agent-a08f61bba34d66802` — branch `worktree-agent-a08f61bba34d66802`

## Fix summary
`extractOverlayStack()` now appends a base-context descriptor (`id:"__base-context__"`,
`baseContext:true`, `present:` computed from `<main>`/`<body>` visibility+size+content, browser-only,
dependency-free) to every captured stack. `checkNoDeadEnd(afterClose)` splits the stack into real
overlays (filters out the `baseContext` entry) vs. the base descriptor: suspicion fires only when
real-overlay presence is zero AND the base descriptor is absent or `present:false`. Old-style bare
arrays (no base descriptor, e.g. hand-fed fixtures / pre-fix extraction shape) still resolve exactly
as before — no base entry found ⇒ treated as base absent. No other invariant checker's behavior
changes (they match specific overlay ids, unaffected by the extra descriptor).

## Consumer check
Grepped `skills/detecting-interaction-ux/` for `extractOverlayStack`/`checkNoDeadEnd` consumers.
`SKILL.md` documents `browser_evaluate(extractOverlayStack)` → `S0..S3` and `checkNoDeadEnd(S3)` as a
single-array-argument call — unchanged signature, still returns "an array"; description of the
Negative-control / Mini-Evals scenarios remains accurate (an extra trailing base descriptor doesn't
contradict any of them). `tools/accuracy-harness/scorer/ux-measure.js` only imports
`checkStackIntegrity` (untouched). No consumer outside the two allowed files required a change.

## Test summary
`tests/interaction-ux/run.sh`: added a clean-close fixture (empty overlays + healthy base
descriptor → `null`, no suspicion) and a true-dead-end negative control (empty overlays + inert
base descriptor → `interaction-dead-end`). Full suite: `PASS=12 FAIL=0`, exit 0. `node --check` and
`bash -n` clean across the whole repo. `ux-measure.js` still loads/imports cleanly (only uses the
untouched `checkStackIntegrity`).

## Concerns
None — behaviorally backward-compatible for every existing fixture shape; only the two allowed
files were touched.

## Report path
`.superpowers/sdd/task-2-report.md` (this file, worktree-local)
