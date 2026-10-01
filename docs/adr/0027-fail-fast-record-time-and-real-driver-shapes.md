# ADR-0027 — Fail at record time, read the real driver, and give API-only criteria one recorded write

## Status

Accepted (2026-10-01). Engine 0.9.0. Refines [ADR-0018](./0018-out-of-agent-evidence-enforcement.md)
(provenance binding, required-kinds, the block-hook), [ADR-0015](./0015-human-interaction-discipline.md)
(human-action classification), [ADR-0012](./0012-per-role-scope-and-cross-role-tests.md) (shared
criteria and identity), and the 0.8.0 load-window gate. It adds no verdict, no confidence level
and no suspected layer.

## Context

Two real runs against one Laravel app on 2026-10-01 (`desk-group-scope`, 32 criteria;
`register-choose-later`, 61 criteria) matched the oracle on nearly every criterion and still
verified badly: run 2 had 27 genuine passes overridden to `fail` as AC-1 forgery, 20 criteria
`blocked`, and both runs failed `__run-checks__`. Every cause was tooling, and every one recurred
across both runs although the second agent was told to avoid them. Nine findings:

1. **The mutation classifier read prose, not structure.** `mutation-flag.sh` matched bare verbs
   in `action`/`title`, so "compare rows as a **set**", "Do NOT **submit**", "the **change**
   marker", a quoted "**Edit** my registration" button and `/hackathons/**create**` made six
   read-only criteria (all tagged `read-only`, all `humanAction: false`) require `human-action`
   evidence; they ended `blocked`.
2. **`--source-ref` accepted any string, then qa-verify called it forgery.** Run 2 recorded every
   bake with a description (`tinker:HackathonRegistration::find(454)`). `provenance.sh` treats a
   present `sourceRef` as an authoritative pointer, could not resolve it, and returned `unbound`.
   With the description stripped, the same artifacts bind by containment (34 of 35 did).
3. **`--session-calls` accepted any JSON.** Run 1 recorded plain strings
   (`["click combobox", ...]`), run 2 a `{tool: count}` map and, by default, `[]` —
   `record-evidence.sh` wrote an explicit `sessionCalls: []` whenever neither `--session-calls`
   nor `--session-log` was given, which `provenance.sh` correctly reads as the forged-trace
   signal. All were guaranteed `unbound`. Post-hoc correction is (rightly) tampering, so the only
   recovery was a re-run.
4. **The findings channel was dead against the real driver.** qa-verify parsed each event's
   `responseBody` as the raw observe object or a raw JSON array of requests. The Playwright MCP
   returns neither: every result is a content array `[{"type":"text","text":"### Result\n...\n###
   Ran Playwright code ..."}]`, and the 4000-byte body cap cuts that wrapper mid-string (observe's
   `domDigest` alone exceeds it), so it never parses; `browser_network_requests` answers with a
   markdown list (`12. [GET] https://... => [200]`). Run 2 injected `observe.js` verbatim and
   still verified `findingsChannel: "none"`. The suite never caught it because every fixture
   fabricated the raw shape.
5. **Load-window gaps were discovered only at verify time** (7 and 4 auxiliary navigations —
   login, locale switch, logout recovery), when they can no longer be closed.
6. **`--save-session` absence was silent.** Both runs had `saveSession: true` and no session log.
7. **The agent had no `browser_drag`/`browser_drop`**, so a dnd-kit board criterion was deferred.
8. **API-only criteria had no permitted write.** Authorization and server-validation assertions
   on a disposable env with `allowApiWrites: true` were blocked: the block-hook denies any mutating
   `browser_evaluate` (even the documented `backend-probe.js` write path), and the host harness
   denies out-of-browser `curl`.
9. **Shared admin criteria were always downgraded.** On a multi-persona project a persona-less
   high-stakes pass degraded to `low` even though omitting `--persona` is correct for a shared
   criterion (ADR-0012) and the admin identity had been captured at login.

## Decision

**A. Refuse at record time anything that can never verify.** `record-evidence.sh` validates
`--source-ref` (only `seq:<N>`/`<N>`, and the seq must exist when a toolstream exists) and
`--session-calls` (a non-empty array of objects naming a `class` or `tool`), exiting 1 with a
message that says what to pass. With neither `--session-calls` nor `--session-log` it writes no
`sessionCalls` key, so the act-phase steps bind against the captured interaction tools — the same
strength as an agent-supplied `--session-calls`. The tamper rule is unchanged: evidence is still
never corrected after the fact; it is simply never accepted in a shape that cannot verify.

**B. A descriptive `sourceRef` is no claim.** `provenance.sh` treats only a well-formed pointer as
authoritative; anything else falls back to containment, exactly as if it were absent. A
well-formed pointer that dangles stays `unbound`. This is never weaker than omission, and keeps
artifacts recorded by ≤0.8.1 verifiable.

**C. Structured classification first.** `mutation-flag.sh` precedence: `kinds ∋ human-action`
and a mutating `httpMethod` → mutating (never overridable); then an explicit `mutates: true|false`
or the `read-only` tag; then `humanAction: true` → mutating; only then prose — lowercased, with
negated clauses and URL/path tokens removed, `set` only as "set X to|on|off", plus an uppercase
`POST|PUT|PATCH|DELETE`. `read-only` outranks `humanAction: true` because rows that only *drive*
a control (a switcher, a search box) carry both and write nothing (0.8.1 ignored `humanAction`);
on any other row `humanAction: true` now requires the trace even when the prose verb ("withdraw",
"remind", "advance") is not in the list — a strengthening. The declaration lives on the human-reviewed frozen plan row, the trust
boundary the `read-only` tag's bake suppression already sat on; nothing the run's agent writes
during verification is consulted. `validate-checklist-json.sh` rejects `mutates: false` beside a
human-action requirement.

**D. Read the real driver, at capture time.** `toolstream.sh extract-observed` unwraps the MCP
content array from the FULL response (before the cap) into a compact `observed` field on the
event; `toolstream.sh observed-rows` is qa-verify's single reader (the `observed` field, then the
legacy raw shapes, then the MCP-wrapped body for pre-0.9.0 toolstreams). One jq library and one
python3 library implement both, so capture and verify cannot drift. Regression fixtures are the
real shapes.

**E. Tell the agent at the call, not after the run.** The capture hook returns PostToolUse
`additionalContext` (advisory, never blocking) for: a first observe round or request list that
yielded no findings (the channel is not being captured); every `browser_navigate` (read the load
window next); and, once at the third browser call, a missing session log. The block-hook denies
the next `browser_navigate` of a live run while the previous one's load window is unread
(`enforcement.loadWindowGate: false` opts out; the verify-time check stays). Preflight reports
`save-session: detected|absent` with how to enable it (`PLAYWRIGHT_MCP_SAVE_SESSION`).

**F. One sanctioned, recorded write for API-only criteria.** The block-hook admits exactly one
mutating `browser_evaluate` shape — `backend-probe.js` verbatim plus one `probe(<strict JSON>)`
call with a same-origin relative url — and only when `allowApiWrites`, a disposable
`seedableEnvMarker` and `environment != production` hold (`write-probe-gate.js`). Strict JSON
carries no expression, so nothing else rides along. A row tagged `api-write` proves its act with
`probe` evidence instead of `human-action`, and qa-verify overrides it unless that evidence is
bound by `--source-ref seq:<N>` to the captured sanctioned write and the config still allows
writes. It goes through the browser, not a `probe.sh`, because the browser carries the session and
CSRF and is already captured; an out-of-browser script would be denied by the same host harness.
ADR-0015 is untouched: `api-write` is for acts with no UI affordance by design, never a shortcut
around one a human could perform.

**G. Bind a shared criterion to its role's capture.** A persona-less high-stakes pass on a
multi-persona project is bound to `evidence/<row role>/identity.json` with exactly the
persona-scoped rules (verify / degrade / override on an `expectedSubject` mismatch). Without such a
capture it still degrades, and the reason now names the command that records one.

**H. Drag and drop are human-path tools** (`browser_drag`, `browser_drop` added to the agent's
tool list; the gates already classified them as human-path).

## Consequences

- Things that now fail fast (behaviour change): a descriptive or dangling `--source-ref`, a
  malformed or empty `--session-calls`, and the next `browser_navigate` while a load window is
  unread. Each message says how to proceed.
- Runs that verified `findingsChannel: "none"` now have a channel; a re-verify of an existing run
  can newly report in-scope 5xx findings the run never journaled (the 2026-10-01 run 2 toolstream
  holds several `GET .../superset/data/... 500`s). That is the check working, not a regression.
- The classifier now recognises a quoted method key (`{"method":"POST"}`), which previously
  slipped past it entirely — a strengthening of the block-hook and the act-phase lint.
- Residuals: the plan row is trusted for `read-only`/`mutates` exactly as it already was for bake
  suppression — a dishonestly authored plan is a plan-review problem, not something this layer can
  detect. `observed` is capped (100 network rows, non-2xx first; 50 console rows), and non-2xx rows
  are kept first, so only a page with more than 100 failing requests in one response can lose one. A legacy toolstream whose
  observe body was cut mid-wrapper still contributes nothing for that round.
