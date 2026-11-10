---
description: Show the project's QA state in one place — constitution, specs, every run's progress, verdicts, bugs and ship readiness, the active run's live cursor and the known-defect registry — as an HTML page, a terminal view or JSON. Read-only.
argument-hint: [html|tui|json] [--out <file>] [--refresh <sec>] [--watch <sec>] [--open]
disable-model-invocation: false
---

Show where this project's QA stands. **Read-only**: the dashboard reads `.qa/` and writes only the
HTML file it is asked for. Full input: `$ARGUMENTS` (default mode `html`).

The script is `scripts/qa-dashboard.sh` in the qa-e2e-pilot plugin (`${CLAUDE_PLUGIN_ROOT}/scripts/`
on Claude Code; the plugin checkout's `scripts/` on other harnesses). Run it from the project root,
or pass `--project <dir>`.

## What to do

1. Pick the mode from `$ARGUMENTS`: `html` (default), `tui` or `json`. Pass the remaining flags through.
   - `html [--out <file>] [--refresh <sec>] [--watch <sec>] [--open]` writes one self-contained page
     (default `.qa/dashboard.html`): no external requests, light and dark, opens from `file://`.
     `--refresh` makes an open tab reload on that period, keeping its scroll, open sections and
     filters. `--watch` keeps rewriting the page every N seconds until Ctrl-C (it implies the same
     `--refresh`); like `tui --watch`, only suggest it for the user's own terminal, never run it inside
     this session. `--open` opens the page in the default browser.
   - `tui [--watch <sec>]` prints the terminal view. `--watch` redraws every N seconds until Ctrl-C;
     only suggest it when the user runs the command in their own terminal, never inside this session.
   - `json` prints the model for another tool or agent.
2. Run `bash "<plugin>/scripts/qa-dashboard.sh" <mode> [flags]`.
3. Report briefly: the path written (html), or the few lines that matter — runs `running` / `stalled`
   (with the run id and `/qa-resume <run-id>` for a stalled one), the active run's progress and ETA,
   any spec whose analysis is `BLOCKED`, any `NOT SHIP-READY` run, and outstanding or expired known
   defects. Quote the numbers the dashboard printed; never recompute verdicts yourself.

## What it shows

The HTML page leads with each target's **latest run in people's terms**: a readiness line
(`In progress`, `Stalled`, `Not ready to ship`, `Every check passed`, or the ship verdict when the run
has one) with one sentence of facts; the live run's checks done, time left and the check running now;
**journeys** from the spec's `journeys.json` (or checks grouped by role when there are none), each a
line of stops shaped and coloured by verdict that opens to its numbered checks; and **bugs**, most
severe first, each opening to what happened and what should happen, filterable by severity, journey
and text. Other targets fold below it. Everything else sits under **Records**:

- **Header**: constitution version and role count, profile/environment/gates from `.qa/config.json`,
  plugin version.
- **Specs** (`.qa/specs/<target>/`): criteria, P1/P2 journeys, oracle sources
  (`human`/`spec`/`llm-suggested`), the `/qa-analyze` verdict (`BLOCKED`/`OK`, stale when older than
  the checklist), coverage %, run count, role drift against the constitution.
- **Runs** (newest first): status — `running` (criteria left and the journal moved in the last 30
  minutes, `--stall-minutes` to change), `stalled` (criteria left, journal idle longer), `paused`
  (the manifest says so), `complete` — progress, rate per hour and ETA for a running run, verdict
  counts and low-confidence passes, bugs by severity, verified, ship readiness and a link to
  `report.html`. Verdicts, supersession and ship readiness come from `render-report.js` itself, so
  the dashboard always agrees with the report.
- **Active runs**: current phase, criterion and persona, the last 10 journal events, the latest
  bugs, and a stalled warning.
- **Trends** per target across runs (pass, fail, blocked, bugs) and the **known-defect registry**
  (`scripts/known-defects.sh status`: outstanding, expired, cleared).

It never reads `.qa/auth`, never prints a credential, and redacts strings with the same
`enforcement.redactedKeys` / `secretPatterns` rules as `scripts/bug-export.sh`.
