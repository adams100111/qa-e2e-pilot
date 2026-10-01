# ADR-0028 — Screenshots are mandatory, bound evidence; the report is rendered, not written

## Status

Accepted (2026-10-01). Engine 0.10.0. Extends [ADR-0018](./0018-out-of-agent-evidence-enforcement.md)
(provenance binding, qa-verify) and [ADR-0027](./0027-fail-fast-record-time-and-real-driver-shapes.md)
(refuse at record time what can never verify). Adds no verdict, confidence level or suspected layer.

## Context

A real 0.8.1 run (`desk-group-scope`, 32 criteria) produced a report with no picture in it: 0 image
files under `evidence/`, 0 `<img>` in `report.html`. Two causes:

1. **Nothing required a screenshot.** The report templates had optional "screenshot slots";
   `driving-browser-qa` never told the agent to call `browser_take_screenshot`; no gate looked. When
   screenshots were taken in other runs they landed wherever the Playwright MCP resolved the
   `filename` (its workspace root — `~/repos/ec1-desk-card.png` for a project in
   `~/projects/innovation`), outside the run, unbound to anything.
2. **The report was hand-filled.** The agent copied an HTML template and replaced placeholders. A
   0.7.1 Python renderer existed but only listed `evidence_refs` and had no viewer. A hand-filled
   report shows what the agent chose to type, not what the run recorded.

## Decision

**A. A screenshot is evidence with provenance, like any other kind.** `record-evidence.sh <run>
<crit> screenshot --phase before|after` files the image under the criterion's evidence dir with a
sidecar `{phase, image, sha256, bytes, fullPage, sourceFile, binding, provenance.sourceRef}`.

**B. Bind by content, at capture.** For every `browser_take_screenshot` the capture hook resolves the
saved file (the call's `filename`, else the result's link; tried against the hook's `cwd`,
`$CLAUDE_PROJECT_DIR`, `$PWD`, `$PLAYWRIGHT_MCP_OUTPUT_DIR`) and records `screenshot: {file, path,
sha256, bytes}` on the toolstream event — before the agent can touch the file. The recorded image must
hash to that value. A toolstream without the hash (pre-0.10.0, or a harness converting `session.md`)
falls back to the file name — weaker, and recorded as `binding: "filename"`.

**C. Refuse at record time** (ADR-0027): a file that is not what the captured call saved, a pointer at
any tool other than `browser_take_screenshot`, a capture another sidecar of the run already claims
(one capture evidences one screenshot — no laundering one picture across criteria), a description
instead of `seq:<N>`, a non-image (by magic bytes), anything over 25 MB.

**D. Gate at checkpoint, where it can still be fixed.** `checkpoint.sh` refuses a `pass` or `fail`
without a recorded, intact screenshot when the run's toolstream holds a captured browser call — the
browser was up, so the screenshot is one call away. `blocked` is never refused (it can be decided
before a page loads) and a run with no browser capture only gets a NOTE.

**E. qa-verify: forged overrides, missing degrades.** For each pass, `screenshot-evidence.sh status`
re-hashes every recorded image and re-binds every sidecar through `provenance.sh`:
- altered after recording, missing image, malformed sidecar, unbound, or a capture claimed twice →
  **override to fail** (the AC-1 forgery signal), whatever the requirement setting;
- no screenshot at all → **confidence: low** with a reason, **never an override**. The pass's truth
  rests on its bake/computed/probe/action-trace evidence, which qa-verify re-checks independently; a
  missing picture makes it less reviewable, not wrong. This is also what keeps runs recorded before
  0.10.0 verifiable: re-verified, every pass degrades with a reason that names the cause, instead of
  every pass being overridden and the run becoming unverifiable.
- fail rows are not re-checked by qa-verify (it re-checks passes); their screenshot findings go to one
  record-only `__screenshots__` record (confidence low), which, like `__phase-surface__`, never flips
  the exit code.

`report.requireScreenshots` (default `true`; `QA_REQUIRE_SCREENSHOTS` overrides) turns the
requirement — the checkpoint refusal and the no-screenshot degrade — off for a driver that cannot take
screenshots. It never turns the forgery checks off.

**F. The report is rendered.** `scripts/render-report.sh` (over `render-report.js`, dependency-free
node) builds `report.html` + `report.md` from `checkpoint.json`, `verification.json`, the manifest,
checklist, bug-log and `evidence/`. Verifier verdicts win and overrides are labelled. Each card has a
thumbnail grid; a click opens a full-screen viewer (Esc / outside click closes, arrow keys and buttons
step through the criterion's images; an "All screenshots" gallery steps through all). Inline CSS + JS
only, relative paths, works from `file://`; `--embed` inlines the images for one portable file. It
renders any run, including older ones (loose images are shown marked "not provenance-bound").
`render-report.py` remains as a shim.

## Consequences

- Behaviour changes: a `pass`/`fail` on a browser-driven run is refused at checkpoint without a
  screenshot; re-verifying an older run degrades its passes to `confidence: low` (exit code unchanged);
  qa-verify can override a pass for a tampered/reused/unbound screenshot; `__screenshots__` may appear
  in `verification.json`.
- Agents need to know where the driver saved a file: the Playwright MCP resolves a relative
  `filename` against its workspace root and refuses absolute paths outside it. The hook records the
  resolved path, `record-evidence.sh` uses it, and `--file` covers the rest.
- Residuals: binding proves the image is what a real capture call saved, not that it was taken while
  this criterion was being verified (a screenshot taken earlier for no criterion can be claimed by
  any one criterion once). The name fallback (no hash) binds any file with the captured name. The
  renderer is node-only (single engine), like the other node tooling.
