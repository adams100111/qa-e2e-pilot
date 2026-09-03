# UX-suspicion adjudication doctrine (ADR-0019)

`ux-detectors.js` walks the live DOM and emits **suspicions** — `axis: 'ux-suspicion'`
findings that carry no verdict, no `suspectedLayer`, no `confidence`. A suspicion is
just "this looked wrong"; it is not yet a `fail`. `adjudicate.js` is the second stage:
it turns a suspicion into either a real verdict (`fail @ FE`, confidence set by how
strong the backing oracle is) or an `advisory` (observed, but not asserted as a bug),
or drops it entirely (`null`) when it is judged deliberate. This document is the
human-readable companion to the executable table in `adjudicate.js` — **edit both
together**; `ORACLE_GRADES` in `adjudicate.js` is the executable form of the table
below.

## 1. The oracle-vs-heuristic split (spec §2)

The project invariant is: **verdicts require an oracle** — an independent source of
truth the finding can be checked against, never the implementation's own output. A
suspicion detector on its own is a heuristic (it noticed a pattern); what makes it a
*verdict* is whether the thing it noticed is, by construction, unambiguous evidence of
a bug — no further corroboration needed — or merely suggestive.

- An **oracle-backed** suspicion (the DOM itself, or a translation catalog) becomes a
  real `fail` the moment adjudication resolves it.
- A **heuristic-only** suspicion (nothing but "these two boxes overlap") stays
  `advisory` unless something else — a definite oracle on the same element, a second
  independent signal — corroborates it.

This split is what keeps the QA pipeline's invariant intact: verdicts are exactly
`pass | fail | blocked | deferred | error`, never a sixth "maybe" state — a merely
suggestive finding is represented as `advisory`, not smuggled in as a low-confidence
`fail`.

## 2. The five oracle grades

`oracleGradeFor(detector)` classifies a detector id into one of five grades via
**longest-prefix-wins** matching against `ORACLE_GRADES` (a specific detector id, e.g.
`i18n-raw-key`, overrides its family's default, e.g. the bare `i18n-` prefix).

| Grade | Meaning | What `adjudicate()` yields |
|---|---|---|
| `definite-dom` | The rendered DOM/screenshot itself IS the oracle — `NaN`, `undefined`, `[object Object]`, a broken image, invisible (fg≈bg) text, a raw i18n key, a modal painted behind its own backdrop. No external source is needed to know these are wrong. | `fail @ FE`, confidence **high** — unconditionally, even black-box (§4 below). |
| `definite-catalog` | The oracle is a translation catalog, not the DOM alone — a script mismatch might be a legitimate brand/URL/proper noun in Latin script, so the catalog result decides. | Routed to `adjudicateI18n()` (§3) — `fail high`, `advisory`, or dropped (`null`), depending on `catalogResult`. |
| `standards` | A real, external oracle (WCAG 2.2 SC), but not a project-specific spec/domain rule — `contrast`, `target-size`. | `fail @ FE`, confidence **low** — a real verdict, just not backed by *this app's* domain oracle. |
| `behavioral-observed` | An `interaction-*` overlay-stack invariant was directly observed to break (e.g. one overlay's close destroying a sibling it shouldn't) — the violation itself is the oracle, no further corroboration needed to know *something* is wrong. Unlike `heuristic`, this is **always a verdict, never advisory**. | `fail @ FE`, confidence **low** until the shared open/route state the overlays bind to is localized in code, then **high** once `oracleInputs.corroborated` is `true`. |
| `heuristic` | No independent oracle at all — pattern-matched suspicion only (generic `overlap`, every `critic-*` suspicion from the layer-3 generative critic, and the default for any unrecognized detector id). | `advisory`, unless `oracleInputs.corroborated` is `true`, in which case a definite oracle elsewhere has confirmed it and it promotes to `fail @ FE` confidence **high**. |

Every `critic-*` detector id (the layer-3 generative critic — `skills/detecting-visual-ux/SKILL.md`
Step 4, ADR-0019 §5) carries the `heuristic` grade unconditionally, via the bare `critic-` prefix
entry in `ORACLE_GRADES` — the critic's own read, however confident it sounds, is never itself an
oracle. This is the load-bearing soundness guarantee for layer 3: a wider net (an LLM reading a
screenshot for "anything that looks off") could otherwise flood the report with false fails; routing
every one of its observations through this same `heuristic` grade means the critic can only ever
*raise a suspicion*, promoted to a verdict solely by a `definite-dom`/`definite-catalog`/
`behavioral-observed` finding corroborating it on the same element — exactly the same corroboration
path a generic `overlap` suspicion goes through. See
[generative-critic.md](generative-critic.md) for the critic's full prompt/rubric and suspicion shape.

All `interaction-*` detectors (the overlay-stack invariant checkers) carry the
`behavioral-observed` grade via the `interaction-` prefix entry in `ORACLE_GRADES`.
The key distinction from `heuristic` is that `behavioral-observed` is **never**
advisory: the invariant violation was directly observed, so it is a real defect the
moment it's seen — only the confidence (not the verdict) depends on whether the cause
has been localized in code.

## 3. Confidence-by-oracle-strength (spec §3)

Confidence is not a vibe — it tracks how strong the backing oracle is:

- **high** — the oracle is unambiguous: the DOM itself (`definite-dom`), a resolved
  catalog gap or an otherwise-complete-catalog convention violation
  (`definite-catalog` → `missing`/`empty`/completeness-derived `present-latin-eq-en`),
  heuristic corroboration by a definite oracle, or a `behavioral-observed` violation
  once the shared open/route state cause has been localized in code
  (`oracleInputs.corroborated`).
- **low** — the oracle is a general standards threshold (WCAG), not this app's own
  spec/domain rule (`standards` grade); or a `behavioral-observed` violation on
  observation alone, before the shared-state cause is localized in code. This mirrors
  the project-wide rule that confidence is low whenever the expected value could only
  come from backend/spec code the detector didn't independently verify — for
  `standards`, the "expected value" is a cross-app accessibility standard rather than
  this feature's own oracle; for `behavioral-observed`, the violation is real but its
  root cause in the shared state model is not yet localized.

There is no `medium` — this module never emits it, matching the two-value
`confidence: high | low` invariant.

## 4. The black-box degrade rule

A `definite-dom` finding needs **no source access** to be confidence `high`: the
rendered DOM (or a screenshot) already IS the evidence. `adjudicate({detector:
'i18n-raw-key', ...}, {hasSource: false})` still returns confidence `high` — whether
the agent can read backend/source code is irrelevant to a raw translation key literally
printed on the page. This is a deliberate exception to the general "low confidence when
the expected value can only come from backend code" rule: here the *observed* value
(the raw key, the `NaN`, the invisible text) is itself sufficient proof, independent of
any source access.

## 5. The i18n catalog table (§4.2) — verbatim

`definite-catalog` suspicions (`i18n-script-mismatch`, and any other `i18n-` detector
without a more specific grade) are resolved by `adjudicateI18n(catalogResult,
catalogCompleteness)`:

| `catalogResult` | Meaning | Verdict |
|---|---|---|
| `missing` | Key absent in the target-locale catalog | definite gap → **fail, high** |
| `empty` | Key present but empty in the target locale | definite gap → **fail, high** |
| `present-latin-legit` | Latin value that is a legitimate proper-noun/brand/URL/code identifier | deliberate → **dropped (`null`)** |
| `present-translated` | Correctly localized | correct, no finding → **dropped (`null`)** |
| `present-latin-eq-en` | Latin value equals the `en` string, reads as prose | suspected untranslated — see completeness rule below |
| `no-catalog` | Black-box: no catalog located to adjudicate against | observed-only → **advisory** |
| *(unrecognized)* | Falls through to the `no-catalog` behavior | **advisory** |

**"In the catalog" is not self-certifying (Q1).** A value merely being *present* in the
target-locale catalog does not by itself prove it is correctly translated —
`present-latin-legit` and `present-latin-eq-en` are both "present," yet one is dropped
and the other is a suspected bug. The oracle is whether the value reads as a
deliberate Latin token (brand, URL, code) versus untranslated prose that happens to
match the English string; catalog presence alone never resolves that distinction.

**The completeness-derived full-translation convention (Q7).** `present-latin-eq-en`
is a **verdict** (`fail, high`) only when `catalogCompleteness >= 0.9` — i.e. the
target-locale catalog is otherwise ≥90% translated, so "this app's convention is full
translation" can be inferred autonomously from the catalog itself, and a Latin
value that still equals the English fallback in an otherwise-complete catalog is a
real gap. Below that threshold the catalog is still substantially incomplete, so the
same observation is only **advisory** — the app may simply not have gotten to this
string yet, and asserting a `fail` would be asserting a completion convention nothing
has established.

## 6. The known-deliberate short-circuit (spec §6)

`adjudicate()` checks `isKnownDeliberate(suspicion, oracleInputs.knownDeliberate)`
**before** grading anything. If the agent (or a prior run) has already judged this
exact suspicion intentional, adjudication returns `null` immediately — no grade is
even computed. "Exact" is keyed by `deliberateKey(suspicion)`, which pairs the
detector id with its raw signal: `` `${detector}␟${rawSignal}` `` (U+241F SYMBOL FOR
UNIT SEPARATOR — chosen because it cannot appear in a detector id or a rendered
`rawSignal`, so the join is unambiguous without escaping). Two suspicions match only
when both the detector AND the raw signal are identical; a different raw signal on the
same detector (a different broken image, a different overlapping pair) is judged
independently.

## 7. The critic's coverage is estimated, not measured (ADR-0019 §11)

Layers 1-2 (the DOM detectors + this adjudication pipeline) are the C1 accuracy-harness's measured
gate (`tools/accuracy-harness/`) — recall/precision against a seeded taxonomy fixture, a number that
can be computed because the ground truth is known. Layer 3 (the generative critic) cannot be scored
the same way: you cannot measure recall against bugs that were never seeded, and a heuristic-graded
`critic-*` suspicion is by construction excluded from that gate's denominator whether or not it gets
corroborated into a verdict later. Treat the critic's contribution as *estimated* long-tail
coverage, never as an addition to the measured recall percentage — this is stated plainly in the
report, not implied by a bigger number.

## 8. Executable form

`skills/detecting-visual-ux/scripts/adjudicate.js` is the single source of truth for
the grade table (`ORACLE_GRADES`) and the classifier (`adjudicate`,
`adjudicateI18n`, `oracleGradeFor`, `deliberateKey`, `isKnownDeliberate`). This
document explains *why* the table reads the way it does; whenever the table changes,
update this doc's tables (§2, §5) in the same change.
