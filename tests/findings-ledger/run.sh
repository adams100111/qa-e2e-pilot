#!/usr/bin/env bash
# tests/findings-ledger/run.sh — TDD suite for the findings ledger
# (plan 2026-09-23-error-honesty-invariants, Task 6).
#
# WHAT IS PINNED HERE (these are a CONTRACT consumed by Task 8's
# qa-verify.sh ledger-completeness / classification re-checks):
#
#   (A) `finding_observed` and `capture_probed` are registered schema events
#       in BOTH fold engines. journal.sh accepts ANY non-empty `event`
#       string, so an unregistered event appends successfully and is then
#       silently discarded by the fold as an `unknown-event` anomaly — the
#       exact silent-loss shape this task exists to remove. Registration is
#       asserted per-engine, because the schema set is DUPLICATED (fold.sh's
#       KNOWN_EVENTS_JSON for the jq pass, its inline python3 set for the
#       python3 pass) and registering in one leaves the other silently lossy.
#
#   (B) `checkpoint.json` carries a `findings` array with KEYED-SET
#       semantics on `findingKey`: first occurrence wins, a repeat collapses,
#       first-seen (seq) order is preserved, and there is NO count/occurrence
#       field anywhere in an entry — a count would re-introduce exactly the
#       resume double-counting this ledger exists to prevent.
#
#   (C) `findingKey` is DERIVED BY THE FOLD, never taken from the event.
#       Format (five `|`-separated components, verbatim from the plan's
#       Global Constraints):
#           <criterionId>|<source>|<method>|<url>|<status>
#       For `source == "console"` the event sets `method` and `url` to "" and
#       the URL COMPONENT of the key carries the normalized, 200-capped
#       `message` instead — still exactly five components. The fold deriving
#       the key (rather than trusting the event's advisory `findingKey`) is
#       what makes dedup a property of the fold instead of a property of
#       whichever emitter happened to run.
#
#   (D) `message` is normalized (ASCII whitespace runs collapsed to one
#       space, one leading/trailing space trimmed) and capped at 200
#       characters; `url` is capped at 1024 characters with the full length
#       carried in the integer `urlLen` and the untruncated url written to
#       the detail file at `detailRef`. Both caps are load-bearing for the
#       PIPE_BUF bound in (E), and the key derivation includes `urlLen` so
#       truncation cannot collide two long URLs of different length into one
#       finding — a finding silently hiding another is worse than a torn
#       write.
#
#   (E) A worst-case serialized event stays under the PIPE_BUF boundary of
#       4096 bytes (journal.sh:79-93) — above it an append is not guaranteed
#       torn-free, the fold then drops the torn line, that manufactures a
#       `seq-gap`, and under plan decision R15 a `seq-gap` marks the whole
#       run UNVERIFIED. One oversized URL must not be able to invalidate an
#       otherwise clean run, so the bound is asserted here against the FULL
#       documented budget rather than against a convenient example, and the
#       fold reports a contract breach (`finding-url-oversize`) instead of
#       silently truncating an event that was already at risk.
#
#   (F) Reserved names (`event`, `seq`, `t`, `childId`, `childSeq`) are never
#       carried from a caller: journal.sh restamps `seq`/`t`, and a projected
#       findings entry carries none of them.
#
#   (G) The jq and python3 engines agree — over the happy path AND over the
#       malformed/degenerate space (unregistered events, missing fields,
#       wrong types, empty arrays, duplicate keys, control characters).
#       stdout and stderr are compared SEPARATELY: a merged `2>&1`
#       comparison would pass a channel swap.
#
# ---------------------------------------------------------------------------
# RULE FOR WHOEVER EXTENDS THIS SUITE — read before adding a case
# ---------------------------------------------------------------------------
# PARITY ALONE CANNOT SEE A DIVERGENCE THE FIXTURES NEVER REACH. A
# dual-engine comparison only proves the two engines agree on the inputs it
# is given; a rule that one engine implements and the other does not is
# invisible until a fixture exercises it. This is how Wave 1 shipped two
# Critical engine divergences behind a green parity suite, and it is why the
# first draft of THIS suite let a python3-only mutation survive: fold.py had
# its 200-char cap deleted and every assertion still passed, because the
# python3 engine was only reached through parity fixtures whose messages were
# all shorter than the cap.
#
# So: every behavioural rule gets (1) a fixture that actually reaches it, and
# (2) a NAMED, engine-independent assertion run against BOTH engines — see
# `write_ledger_journal` + `ledger_asserts` below, which is the pattern to
# copy. Parity is the backstop, never the proof. And prove the assertion is
# live by deleting the rule from ONE engine and watching the suite go red.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../../skills/checkpointing-qa-memory/scripts"
FOLD="$SCRIPTS/fold.sh"
JOURNAL="$SCRIPTS/journal.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: findings-ledger: jq is required to make assertions in this suite" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- helpers ---------------------------------------------------------------
# All fold.sh/journal.sh invocations run with $WORK as cwd because QA_BASE
# defaults to the relative path .qa/runs.
emit()  { ( cd "$WORK" && bash "$JOURNAL" append "$1" "$2" ); }
fold1() { ( cd "$WORK" && bash "$FOLD" "$1" >/dev/null 2>&1 ); }
ckpt()  { echo "$WORK/.qa/runs/$1/checkpoint.json"; }
anom()  { echo "$WORK/.qa/runs/$1/fold-anomalies.json"; }
get()   { jq -r "$2" "$1" 2>/dev/null; }
# findings_keys <run-id> -> comma-joined findingKey values, in emitted order
findings_keys() { get "$(ckpt "$1")" '[.findings[].findingKey] | join(",")'; }
findings_len()  { get "$(ckpt "$1")" '.findings | length'; }

# net_finding <criterionId> <method> <url> <status-json> [message]
net_finding() {
  jq -cn --arg c "$1" --arg m "$2" --arg u "$3" --argjson s "$4" --arg msg "${5:-boom}" \
    '{event:"finding_observed",criterionId:$c,source:"network",channel:"driver-log",
      method:$m,url:$u,status:$s,originClass:"in-scope",statusClass:"fatal",
      message:$msg,detailRef:"evidence/EC1/findings/f1.json"}'
}
# con_finding <criterionId> <message>
con_finding() {
  jq -cn --arg c "$1" --arg msg "$2" \
    '{event:"finding_observed",criterionId:$c,source:"console",channel:"in-page",
      method:"",url:"",status:"",originClass:"in-scope",statusClass:"fatal",
      message:$msg,detailRef:""}'
}
repeat_char() { # repeat_char <char-or-string> <count>
  jq -rn --arg c "$1" --argjson n "$2" '[range(0; $n) | $c] | join("")'
}
# repeat_jchar <json-escape-without-quotes> <count> -- the argument is decoded
# as a JSON string first, so a control character or an astral-plane codepoint
# can be built without embedding a raw one in this file. --argjson is fed a
# single literal document, never a jq filter that could emit more than one.
repeat_jchar() {
  jq -rn --argjson c "\"$1\"" --argjson n "$2" '[range(0; $n) | $c] | join("")'
}

# ---------------------------------------------------------------------------
# test_finding_observed_registered_in_jq_engine
# ---------------------------------------------------------------------------
emit reg-jq '{"event":"run_started","runId":"reg-jq"}'
emit reg-jq "$(net_finding EC1 GET https://app.test/dash 500)"
( cd "$WORK" && QA_ENGINE=jq bash "$FOLD" reg-jq >/dev/null 2>&1 ); rc_reg_jq=$?
check "test_finding_observed_registered_in_jq_engine: fold exit 0" "$rc_reg_jq" "0"
check "test_finding_observed_registered_in_jq_engine: NOT an unknown-event anomaly" \
  "$(get "$(anom reg-jq)" '[.anomalies[] | select(.rule=="unknown-event")] | length')" "0"
check "test_finding_observed_registered_in_jq_engine: folded into checkpoint.findings" \
  "$(findings_len reg-jq)" "1"

# ---------------------------------------------------------------------------
# test_finding_observed_registered_in_python_engine — the schema set is
# DUPLICATED in fold.sh (jq literal + inline python3 set); this is the half
# that a jq-only edit leaves silently lossy.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  emit reg-py '{"event":"run_started","runId":"reg-py"}'
  emit reg-py "$(net_finding EC1 GET https://app.test/dash 500)"
  ( cd "$WORK" && QA_ENGINE=python3 bash "$FOLD" reg-py >/dev/null 2>&1 ); rc_reg_py=$?
  check "test_finding_observed_registered_in_python_engine: fold exit 0" "$rc_reg_py" "0"
  check "test_finding_observed_registered_in_python_engine: NOT an unknown-event anomaly" \
    "$(get "$(anom reg-py)" '[.anomalies[] | select(.rule=="unknown-event")] | length')" "0"
  check "test_finding_observed_registered_in_python_engine: folded into checkpoint.findings" \
    "$(findings_len reg-py)" "1"
else
  echo "SKIP - test_finding_observed_registered_in_python_engine: python3 not on this host"
fi

# ---------------------------------------------------------------------------
# test_capture_probed_registered_in_both_engines — registration only;
# capture_probed is NOT projected into the checkpoint (Task 7 emits it,
# Task 10 reads its `channel` off the journal).
# ---------------------------------------------------------------------------
emit cap-jq '{"event":"run_started","runId":"cap-jq"}'
emit cap-jq '{"event":"capture_probed","channel":"toolstream"}'
( cd "$WORK" && QA_ENGINE=jq bash "$FOLD" cap-jq >/dev/null 2>&1 ); rc_cap_jq=$?
check "test_capture_probed_registered_in_both_engines[jq]: fold exit 0" "$rc_cap_jq" "0"
check "test_capture_probed_registered_in_both_engines[jq]: NOT an unknown-event anomaly" \
  "$(get "$(anom cap-jq)" '[.anomalies[] | select(.rule=="unknown-event")] | length')" "0"
check "test_capture_probed_registered_in_both_engines[jq]: contributes no findings entry" \
  "$(findings_len cap-jq)" "0"
if command -v python3 >/dev/null 2>&1; then
  emit cap-py '{"event":"run_started","runId":"cap-py"}'
  emit cap-py '{"event":"capture_probed","channel":"toolstream"}'
  ( cd "$WORK" && QA_ENGINE=python3 bash "$FOLD" cap-py >/dev/null 2>&1 ); rc_cap_py=$?
  check "test_capture_probed_registered_in_both_engines[python3]: fold exit 0" "$rc_cap_py" "0"
  check "test_capture_probed_registered_in_both_engines[python3]: NOT an unknown-event anomaly" \
    "$(get "$(anom cap-py)" '[.anomalies[] | select(.rule=="unknown-event")] | length')" "0"
  check "test_capture_probed_registered_in_both_engines[python3]: contributes no findings entry" \
    "$(findings_len cap-py)" "0"
else
  echo "SKIP - test_capture_probed_registered_in_both_engines[python3]: python3 not on this host"
fi

# Control assertion: an event that is genuinely NOT registered still lands as
# an unknown-event anomaly — proves the two checks above are not vacuous
# (i.e. the unknown-event rule really does fire on this substrate).
emit unreg-run '{"event":"run_started","runId":"unreg-run"}'
emit unreg-run '{"event":"finding_observedX","criterionId":"EC1"}'
fold1 unreg-run
check "control: an UNregistered event IS an unknown-event anomaly (rule is live)" \
  "$(get "$(anom unreg-run)" '[.anomalies[] | select(.rule=="unknown-event" and .event=="finding_observedX")] | length')" "1"

# ---------------------------------------------------------------------------
# test_duplicate_finding_key_collapses
# ---------------------------------------------------------------------------
emit dup-run '{"event":"run_started","runId":"dup-run"}'
emit dup-run "$(net_finding EC1 GET https://app.test/dash 500)"
emit dup-run "$(net_finding EC1 GET https://app.test/dash 500)"
fold1 dup-run
check "test_duplicate_finding_key_collapses: one entry for two identical appends" \
  "$(findings_len dup-run)" "1"
check "test_duplicate_finding_key_collapses: derived findingKey format" \
  "$(findings_keys dup-run)" "EC1|network|GET|https://app.test/dash|500"
check "test_duplicate_finding_key_collapses: entry carries NO count field" \
  "$(get "$(ckpt dup-run)" '[.findings[] | keys[] | select(test("count|occurrences|seen|times"))] | length')" "0"

# ---------------------------------------------------------------------------
# test_resume_does_not_double_count — F1,F2,F3; interruption; a resumed run
# re-observes F2,F3 and newly observes F4. Exactly 4 findings.
# ---------------------------------------------------------------------------
emit resume-run '{"event":"run_started","runId":"resume-run"}'
emit resume-run "$(net_finding EC1 GET https://app.test/a 500)"
emit resume-run "$(net_finding EC1 GET https://app.test/b 500)"
emit resume-run "$(net_finding EC1 GET https://app.test/c 500)"
fold1 resume-run
check "test_resume_does_not_double_count: 3 findings before the interruption" \
  "$(findings_len resume-run)" "3"
# interruption: the run dies, the derived files are gone, the journal is not.
rm -f "$(ckpt resume-run)" "$(anom resume-run)" "$WORK/.qa/runs/resume-run/cursor.json"
emit resume-run "$(net_finding EC1 GET https://app.test/b 500)"
emit resume-run "$(net_finding EC1 GET https://app.test/c 500)"
emit resume-run "$(net_finding EC1 GET https://app.test/d 500)"
fold1 resume-run
check "test_resume_does_not_double_count: exactly 4 findings after re-observation" \
  "$(findings_len resume-run)" "4"
check "test_resume_does_not_double_count: first-seen order survives the resume" \
  "$(get "$(ckpt resume-run)" '[.findings[].url] | join(",")')" \
  "https://app.test/a,https://app.test/b,https://app.test/c,https://app.test/d"

# ---------------------------------------------------------------------------
# test_same_key_different_criterion_is_two_findings — breadth is signal; the
# key includes criterionId for exactly this reason.
# ---------------------------------------------------------------------------
emit breadth-run '{"event":"run_started","runId":"breadth-run"}'
emit breadth-run "$(net_finding EC1 GET https://app.test/dash 500)"
emit breadth-run "$(net_finding EC2 GET https://app.test/dash 500)"
fold1 breadth-run
check "test_same_key_different_criterion_is_two_findings: two entries" \
  "$(findings_len breadth-run)" "2"
check "test_same_key_different_criterion_is_two_findings: both criterionIds present" \
  "$(get "$(ckpt breadth-run)" '[.findings[].criterionId] | join(",")')" "EC1,EC2"

# ---------------------------------------------------------------------------
# test_first_seen_order_preserved — a late duplicate must not move an entry
# to the back (that is the last-wins tuple pattern, deliberately NOT used).
# ---------------------------------------------------------------------------
emit order-run '{"event":"run_started","runId":"order-run"}'
emit order-run "$(net_finding EC1 GET https://app.test/a 500)"
emit order-run "$(net_finding EC1 GET https://app.test/b 503)"
emit order-run "$(net_finding EC1 GET https://app.test/c 500)"
emit order-run "$(net_finding EC1 GET https://app.test/a 500)"
fold1 order-run
check "test_first_seen_order_preserved: order is a,b,c (late duplicate of a does not re-order)" \
  "$(get "$(ckpt order-run)" '[.findings[].url] | join(",")')" \
  "https://app.test/a,https://app.test/b,https://app.test/c"
check "test_first_seen_order_preserved: still three entries" "$(findings_len order-run)" "3"

# ---------------------------------------------------------------------------
# test_console_finding_keys_on_message — method/url are "", so the key's URL
# component carries the normalized message; two different messages are two
# findings, the same message twice is one.
# ---------------------------------------------------------------------------
emit console-run '{"event":"run_started","runId":"console-run"}'
emit console-run "$(con_finding EC1 'TypeError: x is not a function')"
emit console-run "$(con_finding EC1 'ReferenceError: y is not defined')"
emit console-run "$(con_finding EC1 'TypeError: x is not a function')"
fold1 console-run
check "test_console_finding_keys_on_message: two distinct messages -> two findings" \
  "$(findings_len console-run)" "2"
check "test_console_finding_keys_on_message: key carries the message in the url component" \
  "$(findings_keys console-run)" \
  "EC1|console||TypeError: x is not a function|,EC1|console||ReferenceError: y is not defined|"
check "test_console_finding_keys_on_message: projected url stays the empty string" \
  "$(get "$(ckpt console-run)" '[.findings[].url] | unique | join(",")')" ""
# Whitespace/control normalization is what makes "the same message" stable:
# a message differing only by a newline/tab run must NOT become a 2nd finding.
emit console-norm '{"event":"run_started","runId":"console-norm"}'
emit console-norm "$(jq -cn '{event:"finding_observed",criterionId:"EC1",source:"console",channel:"in-page",method:"",url:"",status:"",originClass:"in-scope",statusClass:"fatal",message:"boom  bang",detailRef:""}')"
emit console-norm "$(jq -cn '{event:"finding_observed",criterionId:"EC1",source:"console",channel:"in-page",method:"",url:"",status:"",originClass:"in-scope",statusClass:"fatal",message:" boom\tbang\n",detailRef:""}')"
fold1 console-norm
check "test_console_finding_keys_on_message: whitespace-normalized messages collapse to one finding" \
  "$(findings_len console-norm)" "1"
check "test_console_finding_keys_on_message: normalized message value" \
  "$(get "$(ckpt console-norm)" '.findings[0].message')" "boom bang"

# ---------------------------------------------------------------------------
# test_message_capped_at_200_chars
# ---------------------------------------------------------------------------
LONG_MSG="$(repeat_char x 400)"
emit cap-run '{"event":"run_started","runId":"cap-run"}'
emit cap-run "$(net_finding EC1 GET https://app.test/dash 500 "$LONG_MSG")"
fold1 cap-run
check "test_message_capped_at_200_chars: projected message length is 200" \
  "$(get "$(ckpt cap-run)" '.findings[0].message | length')" "200"
# And the cap is applied to the KEY component for a console finding too,
# so two console errors sharing their first 200 characters collapse.
emit cap-console '{"event":"run_started","runId":"cap-console"}'
emit cap-console "$(con_finding EC1 "${LONG_MSG}AAA")"
emit cap-console "$(con_finding EC1 "${LONG_MSG}BBB")"
fold1 cap-console
check "test_message_capped_at_200_chars: console keys share the capped prefix -> one finding" \
  "$(findings_len cap-console)" "1"
check "test_message_capped_at_200_chars: console key component is 200 chars" \
  "$(get "$(ckpt cap-console)" '.findings[0].findingKey | split("|") | .[3] | length')" "200"

# ---------------------------------------------------------------------------
# test_url_capped_at_1024_chars / test_urlLen_carries_full_length
#
# `url` is the one event field whose length comes from the application under
# test: observe.js records every fetch/XHR url, so a data: URI or a long
# query string reaches PIPE_BUF on its own. The contract therefore caps it at
# 1024 characters, carries the FULL length in the integer `urlLen`, and keeps
# the untruncated url in the detail file at `detailRef`. The fold enforces
# the cap on projection (defence in depth) and reports an event that arrived
# over the cap as `finding-url-oversize`, because such an event was already
# at risk of a torn append before the fold ever saw it.
# ---------------------------------------------------------------------------
URL_1024="https://app.test/?q=$(repeat_char q 1004)"
URL_2000="https://app.test/?q=$(repeat_char q 1980)"
URL_2001="https://app.test/?q=$(repeat_char q 1981)"
check "fixture sanity: URL_1024 is exactly 1024 chars" "${#URL_1024}" "1024"
check "fixture sanity: URL_2000 is exactly 2000 chars" "${#URL_2000}" "2000"

emit urlcap-run '{"event":"run_started","runId":"urlcap-run"}'
emit urlcap-run "$(net_finding EC1 GET "$URL_2000" 500)"
fold1 urlcap-run
check "test_url_capped_at_1024_chars: projected url is capped to 1024" \
  "$(get "$(ckpt urlcap-run)" '.findings[0].url | length')" "1024"
check "test_url_capped_at_1024_chars: projected url is the 1024-char prefix" \
  "$(get "$(ckpt urlcap-run)" '.findings[0].url')" "$URL_1024"
check "test_urlLen_carries_full_length: urlLen is the FULL length" \
  "$(get "$(ckpt urlcap-run)" '.findings[0].urlLen')" "2000"
check "test_urlLen_carries_full_length: urlLen is an integer, not a string" \
  "$(get "$(ckpt urlcap-run)" '.findings[0].urlLen | type')" "number"
check "test_url_capped_at_1024_chars: findingKey url component carries the capped url plus urlLen" \
  "$(get "$(ckpt urlcap-run)" '.findings[0].findingKey')" \
  "EC1|network|GET|${URL_1024}#2000|500"
check "test_url_capped_at_1024_chars: an over-cap event is reported, not silently truncated" \
  "$(get "$(anom urlcap-run)" '[.anomalies[] | select(.rule=="finding-url-oversize" and .urlLen==2000)] | length')" "1"

# A url AT or under the cap is untouched: no truncation marker, no anomaly.
emit urlshort-run '{"event":"run_started","runId":"urlshort-run"}'
emit urlshort-run "$(net_finding EC1 GET https://app.test/dash 500)"
emit urlshort-run "$(net_finding EC2 GET "$URL_1024" 500)"
fold1 urlshort-run
check "test_urlLen_carries_full_length: a short url has urlLen == its own length" \
  "$(get "$(ckpt urlshort-run)" '.findings[0].urlLen')" "21"
check "test_url_capped_at_1024_chars: a url AT the cap gets no truncation marker" \
  "$(get "$(ckpt urlshort-run)" '.findings[1].findingKey')" "EC2|network|GET|${URL_1024}|500"
check "test_url_capped_at_1024_chars: a url AT the cap raises no oversize anomaly" \
  "$(get "$(anom urlshort-run)" '[.anomalies[] | select(.rule=="finding-url-oversize")] | length')" "0"

# An emitter that already capped the url and supplied urlLen must produce the
# SAME key as one that passed the untruncated url — otherwise Task 8, which
# recomputes the key from the driver log, would disagree with the journal.
emit urlpre-run '{"event":"run_started","runId":"urlpre-run"}'
emit urlpre-run "$(jq -cn --arg u "$URL_1024" '{event:"finding_observed",criterionId:"EC1",source:"network",channel:"driver-log",method:"GET",url:$u,urlLen:2000,status:500,originClass:"in-scope",statusClass:"fatal",message:"boom",detailRef:"evidence/EC1/findings/f1.json"}')"
fold1 urlpre-run
check "test_url_capped_at_1024_chars: emitter-capped url + supplied urlLen yields the identical key" \
  "$(get "$(ckpt urlpre-run)" '.findings[0].findingKey')" \
  "$(get "$(ckpt urlcap-run)" '.findings[0].findingKey')"
check "test_url_capped_at_1024_chars: an already-capped event raises no oversize anomaly" \
  "$(get "$(anom urlpre-run)" '[.anomalies[] | select(.rule=="finding-url-oversize")] | length')" "0"

# ---------------------------------------------------------------------------
# test_truncated_urls_do_not_collide — two genuinely different long URLs
# sharing their first 1024 characters must stay two findings. Truncation that
# merged them would be a finding silently hiding another, which is strictly
# worse than the torn write the cap exists to prevent.
# ---------------------------------------------------------------------------
emit collide-run '{"event":"run_started","runId":"collide-run"}'
emit collide-run "$(net_finding EC1 GET "$URL_2000" 500)"
emit collide-run "$(net_finding EC1 GET "$URL_2001" 500)"
fold1 collide-run
check "test_truncated_urls_do_not_collide: same 1024-char prefix, different length -> two findings" \
  "$(findings_len collide-run)" "2"
check "test_truncated_urls_do_not_collide: the two keys differ only in urlLen" \
  "$(get "$(ckpt collide-run)" '[.findings[].findingKey | split("#") | .[1]] | join(",")')" "2000|500,2001|500"
# KNOWN AND ACCEPTED RESIDUAL, pinned here so it is not a surprise later:
# urlLen separates long URLs of DIFFERENT length. Two different URLs that
# share a 1024-char prefix AND have the same total length still collapse.
# That is a deliberate stopping point — distinguishing them needs a digest of
# the full url, which the event contract does not carry.
URL_A="https://app.test/?q=$(repeat_char q 1979)A"
URL_B="https://app.test/?q=$(repeat_char q 1979)B"
emit residual-run '{"event":"run_started","runId":"residual-run"}'
emit residual-run "$(net_finding EC1 GET "$URL_A" 500)"
emit residual-run "$(net_finding EC1 GET "$URL_B" 500)"
fold1 residual-run
check "residual (accepted): equal-length URLs sharing a 1024-char prefix DO still collapse" \
  "$(findings_len residual-run)" "1"

# ---------------------------------------------------------------------------
# test_truncation_without_detailRef_is_an_anomaly — when the url is truncated
# the untruncated form lives ONLY in the detail file; an empty detailRef
# means it is unrecoverable, so the fold says so.
# ---------------------------------------------------------------------------
emit noref-run '{"event":"run_started","runId":"noref-run"}'
emit noref-run "$(jq -cn --arg u "$URL_2000" '{event:"finding_observed",criterionId:"EC1",source:"network",channel:"driver-log",method:"GET",url:$u,status:500,originClass:"in-scope",statusClass:"fatal",message:"boom",detailRef:""}')"
fold1 noref-run
check "test_truncation_without_detailRef_is_an_anomaly: reported" \
  "$(get "$(anom noref-run)" '[.anomalies[] | select(.rule=="finding-detail-missing")] | length')" "1"
check "test_truncation_without_detailRef_is_an_anomaly: anomaly names the findingKey" \
  "$(get "$(anom noref-run)" '[.anomalies[] | select(.rule=="finding-detail-missing") | .findingKey] | .[0] | split("|") | .[0]')" "EC1"
check "test_truncation_without_detailRef_is_an_anomaly: a truncated url WITH a detailRef is not flagged" \
  "$(get "$(anom urlcap-run)" '[.anomalies[] | select(.rule=="finding-detail-missing")] | length')" "0"
check "test_truncation_without_detailRef_is_an_anomaly: an untruncated url with an empty detailRef is not flagged" \
  "$(get "$(anom console-run)" '[.anomalies[] | select(.rule=="finding-detail-missing")] | length')" "0"

# ---------------------------------------------------------------------------
# test_event_stays_under_pipe_buf — the serialized JOURNAL LINE (the unit
# that O_APPEND writes) for a worst-case event must be < 4096 bytes.
#
# THE FULL DOCUMENTED BUDGET, not a convenient example. Every field is at its
# contract maximum simultaneously:
#
#   "finding_observed"        16 bytes   (the event name itself)
#   criterionId          <=   64
#   source               <=    7   "network"
#   channel              <=   10   "driver-log"
#   method               <=    7   "OPTIONS"
#   url                  <= 1024   percent-encoded ASCII (see below)
#   urlLen               <=   15   digits
#   status               <=   19   "unhandled-exception"
#   originClass          <=   11   "third-party"
#   statusClass          <=    9   "non-fatal"
#   message              <=  200   codepoints, each up to 6 bytes once
#                                   JSON-escaped (a control character costs
#                                   \uXXXX) -> <= 1200 bytes
#   detailRef            <=  256
#   seq                  <=   15   digits, stamped by journal.sh
#   t                         20   stamped by journal.sh
#   + 14 key names, quotes, colons, commas, braces and the newline
#
# `url` is ASCII BY CONTRACT, not by assumption: RFC 3986 defines a URI as a
# sequence of characters from the US-ASCII set, and observe.js records the
# url the browser reports, which is already percent-encoded. The final case
# below pins what happens if that precondition is ever violated (a decoded
# IRI), so it is a tested boundary rather than an unstated assumption.
# ---------------------------------------------------------------------------
WC_CID="$(repeat_char c 64)"
WC_REF="evidence/$(repeat_char r 247)"
wc_event() { # wc_event <url> <message>
  jq -cn --arg c "$WC_CID" --arg u "$1" --arg r "$WC_REF" --arg m "$2" \
    '{event:"finding_observed",criterionId:$c,source:"network",channel:"driver-log",
      method:"OPTIONS",url:$u,urlLen:999999999999999,status:"unhandled-exception",
      originClass:"third-party",statusClass:"non-fatal",message:$m,detailRef:$r}'
}
line_bytes() { # line_bytes <run-id>
  wc -c < "$WORK/.qa/runs/$1/journal.ndjson" | tr -d ' '
}
bound() { # bound <run-id> -> under|over(N)
  local n; n="$(line_bytes "$1")"
  if [[ "$n" -lt 4096 ]]; then echo "under"; else echo "over($n)"; fi
}

# (1) every field at its ASCII maximum, all at once.
emit pb-ascii "$(wc_event "$URL_1024" "$(repeat_char m 200)")"
check "test_event_stays_under_pipe_buf: full budget, all fields at their ASCII maximum" \
  "$(bound pb-ascii)" "under"
echo "note - pipe-buf: full ASCII budget serializes to $(line_bytes pb-ascii) bytes (limit 4096)"

# (2) the message at its worst JSON expansion: 200 control characters, each
#     escaped to \uXXXX (6 bytes) by both engines.
CTL_MSG="$(repeat_jchar '\u0001' 200)"
emit pb-ctl "$(wc_event "$URL_1024" "$CTL_MSG")"
check "test_event_stays_under_pipe_buf: 200 control characters in message (6 bytes each)" \
  "$(bound pb-ctl)" "under"
echo "note - pipe-buf: control-char message budget serializes to $(line_bytes pb-ctl) bytes (limit 4096)"

# (3) the message at its worst UTF-8 expansion: 200 non-BMP codepoints.
EMOJI_MSG="$(repeat_jchar '\ud83d\ude00' 200)"
emit pb-emoji "$(wc_event "$URL_1024" "$EMOJI_MSG")"
check "test_event_stays_under_pipe_buf: 200 non-BMP codepoints in message" \
  "$(bound pb-emoji)" "under"
echo "note - pipe-buf: non-BMP message budget serializes to $(line_bytes pb-emoji) bytes (limit 4096)"

# (4) the 1024-char url cap is LOAD-BEARING: the same event with an uncapped
#     4000-character url blows past PIPE_BUF.
emit pb-uncapped "$(wc_event "https://app.test/?q=$(repeat_char q 3980)" "$(repeat_char m 200)")"
check "test_event_stays_under_pipe_buf: an UNcapped 4000-char url exceeds 4096 (cap is load-bearing)" \
  "$(bound pb-uncapped)" "over($(line_bytes pb-uncapped))"
# ...and the fold enforces the cap on projection anyway, and says the event
# breached the contract rather than absorbing it.
fold1 pb-uncapped
check "test_event_stays_under_pipe_buf: fold caps an over-long url to 1024 on projection" \
  "$(get "$(ckpt pb-uncapped)" '.findings[0].url | length')" "1024"
check "test_event_stays_under_pipe_buf: fold reports the over-cap event" \
  "$(get "$(anom pb-uncapped)" '[.anomalies[] | select(.rule=="finding-url-oversize")] | length')" "1"

# (5) the 200-char message cap is load-bearing too.
emit pb-longmsg "$(wc_event "$URL_1024" "$(repeat_char m 4000)")"
check "test_event_stays_under_pipe_buf: an UNcapped 4000-char message exceeds 4096 (cap is load-bearing)" \
  "$(bound pb-longmsg)" "over($(line_bytes pb-longmsg))"
fold1 pb-longmsg
check "test_event_stays_under_pipe_buf: fold caps an over-long message to 200 on projection" \
  "$(get "$(ckpt pb-longmsg)" '.findings[0].message | length')" "200"

# (6) the ASCII precondition, pinned: a 1024-CODEPOINT non-ASCII url (a
#     decoded IRI, 4 bytes per codepoint) reaches 4096 bytes on the url alone,
#     so the contract requires the browser-reported percent-encoded url. This
#     is asserted, not assumed — an emitter that passes a decoded IRI breaks
#     the bound, and the fold flags it because its CHARACTER length is at the
#     cap while its byte length is not.
IRI_URL="$(repeat_jchar '\ud83d\ude00' 1024)"
emit pb-iri "$(wc_event "$IRI_URL" "$(repeat_char m 200)")"
check "test_event_stays_under_pipe_buf: a 1024-codepoint non-ASCII url DOES breach the bound" \
  "$(bound pb-iri)" "over($(line_bytes pb-iri))"

# ---------------------------------------------------------------------------
# test_event_carries_no_reserved_field_names — reserved: event, seq, t,
# childId, childSeq. A caller-supplied seq is NEVER carried: journal.sh
# restamps it, and the projected entry carries none of the reserved names.
# ---------------------------------------------------------------------------
emit reserved-run '{"event":"run_started","runId":"reserved-run"}'
emit reserved-run "$(jq -cn '{event:"finding_observed",criterionId:"EC1",source:"network",channel:"driver-log",method:"GET",url:"https://app.test/r",status:500,originClass:"in-scope",statusClass:"fatal",message:"boom",detailRef:"",seq:9999,childId:"forged",childSeq:7}')"
fold1 reserved-run
check "test_event_carries_no_reserved_field_names: caller-supplied seq is overwritten by journal.sh" \
  "$(jq -r 'select(.event=="finding_observed") | .seq' "$WORK/.qa/runs/reserved-run/journal.ndjson")" "2"
check "test_event_carries_no_reserved_field_names: projected entry has none of the reserved names" \
  "$(get "$(ckpt reserved-run)" '[.findings[0] | keys[] | select(. == "seq" or . == "t" or . == "childId" or . == "childSeq" or . == "event")] | length')" "0"
check "test_event_carries_no_reserved_field_names: projected entry is exactly the contract fields" \
  "$(get "$(ckpt reserved-run)" '.findings[0] | keys | join(",")')" \
  "channel,criterionId,detailRef,findingKey,message,method,originClass,source,status,statusClass,url,urlLen"

# A journal with no finding at all still carries findings: [] (stable shape
# for Task 8, which must be able to tell "no findings" from "no field").
emit empty-run '{"event":"run_started","runId":"empty-run"}'
fold1 empty-run
check "shape: a finding-free run still has findings == []" \
  "$(get "$(ckpt empty-run)" '(.findings | type) + ":" + (.findings | length | tostring)')" "array:0"

# ---------------------------------------------------------------------------
# test_jq_and_python_folds_agree — happy path AND the malformed/degenerate
# space. stdout and stderr compared SEPARATELY (a merged 2>&1 comparison
# would pass a channel swap).
# ---------------------------------------------------------------------------
# A malformed/degenerate journal: an unregistered event, a finding with EVERY
# field missing, wrong types (number/bool/array/object/float where a string
# is expected), an empty array, duplicate keys, and control characters
# (including NUL) in the message.
write_parity_journal() { # write_parity_journal <run-id>
  local d="$WORK/.qa/runs/$1"
  mkdir -p "$d"
  {
    printf '%s\n' '{"event":"run_started","runId":"parity","seq":1,"t":"2026-09-23T00:00:01Z"}'
    printf '%s\n' '{"event":"totally_unknown","criterionId":"EC0","seq":2,"t":"2026-09-23T00:00:02Z"}'
    printf '%s\n' '{"event":"finding_observed","seq":3,"t":"2026-09-23T00:00:03Z"}'
    printf '%s\n' '{"event":"finding_observed","criterionId":42,"source":true,"channel":[],"method":[],"url":{"a":1},"status":500.7,"originClass":null,"statusClass":"fatal","message":12,"detailRef":null,"seq":4,"t":"2026-09-23T00:00:04Z"}'
    printf '%s\n' '{"event":"finding_observed","criterionId":"EC1","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/x","status":500,"originClass":"in-scope","statusClass":"fatal","message":"boom","detailRef":"","seq":5,"t":"2026-09-23T00:00:05Z"}'
    printf '%s\n' '{"event":"finding_observed","criterionId":"EC1","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/x","status":500,"originClass":"in-scope","statusClass":"fatal","message":"boom","detailRef":"","seq":6,"t":"2026-09-23T00:00:06Z"}'
    printf '%s\n' '{"event":"finding_observed","criterionId":"EC1","source":"console","channel":"in-page","method":"","url":"","status":"","originClass":"in-scope","statusClass":"fatal","message":"ctl\u0000a\u0001b\u001bc\td\ne\u00a0f   g","detailRef":"","seq":7,"t":"2026-09-23T00:00:07Z"}'
    printf '%s\n' '{"event":"finding_observed","criterionId":"EC2","source":"console","channel":"in-page","method":"","url":"","status":"","originClass":"in-scope","statusClass":"fatal","message":"","detailRef":"","seq":8,"t":"2026-09-23T00:00:08Z"}'
    printf '%s\n' '{"event":"capture_probed","channel":"none","seq":9,"t":"2026-09-23T00:00:09Z"}'
    printf '%s\n' '{"event":"finding_observed","criterionId":"EC3","source":"network","channel":"driver-log","method":"POST","url":"https://third.example/beacon","status":"unhandled-exception","originClass":"third-party","statusClass":"fatal","message":"  leading and trailing  ","detailRef":"evidence/EC3/findings/a.json","seq":10,"t":"2026-09-23T00:00:10Z"}'
    printf '%s\n' '{"event":"criterion_started","scenarioId":"S1","criterionId":"EC1","personaId":"alice","seq":11,"t":"2026-09-23T00:00:11Z"}'
    printf '%s\n' '{"event":"criterion_verdict","scenarioId":"S1","criterionId":"EC1","personaId":"alice","verdict":"fail","confidence":"high","evidenceRefs":[],"kinds":[],"seq":12,"t":"2026-09-23T00:00:12Z"}'
  } > "$d/journal.ndjson"
}

parity_case() { # parity_case <label> <journal-writer-fn>
  local label="$1" writer="$2"
  local rjq="parity-${label}-jq" rpy="parity-${label}-py"
  "$writer" "$rjq"; "$writer" "$rpy"

  ( cd "$WORK" && bash "$FOLD" "$rjq" >"$WORK/${rjq}.out" 2>"$WORK/${rjq}.err" ); local rc_jq=$?
  # Mask jq by PATH (same idiom as tests/fold/run.sh) so the python3 branch
  # is reached through fold.sh's real auto-detect, not only via QA_ENGINE.
  local FAKEBIN="$WORK/fakebin-${label}"
  mkdir -p "$FAKEBIN"
  local tool tp
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash tr; do
    tp="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tp" ]] && ln -sf "$tp" "$FAKEBIN/$tool"
  done
  ( cd "$WORK" && PATH="$FAKEBIN" bash "$FOLD" "$rpy" >"$WORK/${rpy}.out" 2>"$WORK/${rpy}.err" ); local rc_py=$?

  check "test_jq_and_python_folds_agree[${label}]: jq engine exit 0" "$rc_jq" "0"
  check "test_jq_and_python_folds_agree[${label}]: python3 engine exit 0" "$rc_py" "0"
  # stdout: canonicalized (sorted keys, compact) so only VALUES are compared,
  # never the two engines' serialization/escaping conventions.
  check "test_jq_and_python_folds_agree[${label}]: stdout canonically equal" \
    "$(bash "$JOURNAL" canonical < "$WORK/${rjq}.out")" \
    "$(bash "$JOURNAL" canonical < "$WORK/${rpy}.out")"
  # stderr: compared RAW and separately.
  check "test_jq_and_python_folds_agree[${label}]: stderr byte-equal" \
    "$(cat "$WORK/${rjq}.err")" "$(cat "$WORK/${rpy}.err")"
  check "test_jq_and_python_folds_agree[${label}]: checkpoint.json canonically equal" \
    "$(bash "$JOURNAL" canonical < "$(ckpt "$rjq")")" \
    "$(bash "$JOURNAL" canonical < "$(ckpt "$rpy")")"
  check "test_jq_and_python_folds_agree[${label}]: fold-anomalies.json canonically equal" \
    "$(bash "$JOURNAL" canonical < "$(anom "$rjq")")" \
    "$(bash "$JOURNAL" canonical < "$(anom "$rpy")")"
  check "test_jq_and_python_folds_agree[${label}]: cursor.json canonically equal" \
    "$(bash "$JOURNAL" canonical < "$WORK/.qa/runs/${rjq}/cursor.json")" \
    "$(bash "$JOURNAL" canonical < "$WORK/.qa/runs/${rpy}/cursor.json")"
}

write_happy_journal() { # write_happy_journal <run-id>
  local d="$WORK/.qa/runs/$1"
  mkdir -p "$d"
  {
    printf '%s\n' '{"event":"run_started","runId":"happy","seq":1,"t":"2026-09-23T00:00:01Z"}'
    printf '%s\n' '{"event":"finding_observed","criterionId":"EC1","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/a","status":500,"originClass":"in-scope","statusClass":"fatal","message":"boom","detailRef":"evidence/EC1/findings/a.json","seq":2,"t":"2026-09-23T00:00:02Z"}'
    printf '%s\n' '{"event":"finding_observed","criterionId":"EC1","source":"console","channel":"in-page","method":"","url":"","status":"","originClass":"in-scope","statusClass":"fatal","message":"TypeError: x is not a function","detailRef":"","seq":3,"t":"2026-09-23T00:00:03Z"}'
    printf '%s\n' '{"event":"capture_probed","channel":"driver-log","seq":4,"t":"2026-09-23T00:00:04Z"}'
  } > "$d/journal.ndjson"
}

# A journal that exercises the WHOLE ledger behaviour space — dedup, breadth,
# first-seen order with a late duplicate, the console message key, and the
# 200-char cap — in ONE fixture, so that every behavioural assertion below
# can be made against BOTH engines. Asserting these only against the default
# (jq) engine is not enough: a python3-only regression (e.g. a dropped
# `[:200]` in fold.py's nmsg) would then be invisible, because the parity
# comparison alone cannot see a divergence in behaviour the fixtures never
# reach. This fixture is the reason the per-engine loop below exists.
L200="$(repeat_char L 200)"
L400="$(repeat_char L 400)"
LEDGER_URL_1024="https://app.test/?u=$(repeat_char u 1004)"
LEDGER_URL_2000="https://app.test/?u=$(repeat_char u 1980)"
LEDGER_URL_2001="https://app.test/?u=$(repeat_char u 1981)"
check "fixture sanity: LEDGER_URL_1024 is exactly 1024 chars" "${#LEDGER_URL_1024}" "1024"
check "fixture sanity: LEDGER_URL_2000 is exactly 2000 chars" "${#LEDGER_URL_2000}" "2000"
check "fixture sanity: LEDGER_URL_2001 is exactly 2001 chars" "${#LEDGER_URL_2001}" "2001"
write_ledger_journal() { # write_ledger_journal <run-id>
  local d="$WORK/.qa/runs/$1"
  mkdir -p "$d"
  local n=1
  ledger_line() { # ledger_line <event-json-without-seq-or-t>
    jq -c --argjson sq "$n" --arg tt "2026-09-23T00:00:0${n}Z" '. + {seq: $sq, t: $tt}' <<< "$1"
    n=$((n+1))
  }
  {
    ledger_line '{"event":"run_started","runId":"ledger"}'
    ledger_line "$(net_finding EC1 GET https://app.test/a 500)"
    ledger_line "$(net_finding EC1 GET https://app.test/b 503)"
    ledger_line "$(net_finding EC1 GET https://app.test/a 500)"
    ledger_line "$(net_finding EC2 GET https://app.test/a 500)"
    ledger_line "$(con_finding EC1 "${L200}AAA")"
    ledger_line "$(con_finding EC1 "${L200}BBB")"
    ledger_line "$(net_finding EC3 GET https://app.test/c 500 "$L400")"
    ledger_line "$(net_finding EC4 GET "$LEDGER_URL_2000" 500)"
    ledger_line "$(net_finding EC4 GET "$LEDGER_URL_2001" 500)"
    # EC5: a truncated url with an EMPTY detailRef — the untruncated form is
    # unrecoverable. EC6: an emitter that already capped the url and supplied
    # urlLen. Both live in THIS fixture, which is folded under both engines,
    # because a rule reached only under the default engine is a rule only
    # half-tested: two fold.py mutations (finding-detail-missing removed,
    # url_len ignoring the supplied urlLen) survived while these two rows
    # existed only in single-engine cases above.
    ledger_line "$(jq -cn --arg u "$LEDGER_URL_2000" '{event:"finding_observed",criterionId:"EC5",source:"network",channel:"driver-log",method:"GET",url:$u,status:500,originClass:"in-scope",statusClass:"fatal",message:"boom",detailRef:""}')"
    ledger_line "$(jq -cn --arg u "$LEDGER_URL_1024" '{event:"finding_observed",criterionId:"EC6",source:"network",channel:"driver-log",method:"GET",url:$u,urlLen:2000,status:500,originClass:"in-scope",statusClass:"fatal",message:"boom",detailRef:"evidence/EC6/findings/a.json"}')"
    ledger_line '{"event":"capture_probed","channel":"driver-log"}'
  } > "$d/journal.ndjson"
}

# ledger_asserts <engine-label> <run-id> — the SAME expectations, asserted
# per engine. Values are engine-independent by construction (kstr/nmsg are
# total functions with identical semantics in fold.jq and fold.py), so a
# divergence shows up as a named behavioural failure and not merely as a
# canonical-inequality diff.
ledger_asserts() {
  local eng="$1" run="$2"
  check "ledger[${eng}]: nine findings after dedup" "$(findings_len "$run")" "9"
  check "ledger[${eng}]: keyed-set collapse + breadth + first-seen order" \
    "$(get "$(ckpt "$run")" '[.findings[].criterionId] | join(",")')" "EC1,EC1,EC2,EC1,EC3,EC4,EC4,EC5,EC6"
  check "ledger[${eng}]: duplicate of the first finding did not re-order or re-add" \
    "$(get "$(ckpt "$run")" '[.findings[] | select(.source=="network" and (.criterionId | test("^EC[123]$"))) | .url] | join(",")')" \
    "https://app.test/a,https://app.test/b,https://app.test/a,https://app.test/c"
  check "ledger[${eng}]: console key component capped at 200" \
    "$(get "$(ckpt "$run")" '.findings[3].findingKey | split("|") | .[3] | length')" "200"
  check "ledger[${eng}]: two console messages sharing 200 chars collapsed to one" \
    "$(get "$(ckpt "$run")" '[.findings[] | select(.source=="console")] | length')" "1"
  check "ledger[${eng}]: over-long network message capped to 200" \
    "$(get "$(ckpt "$run")" '.findings[4].message | length')" "200"
  check "ledger[${eng}]: capped message is the 200-char prefix" \
    "$(get "$(ckpt "$run")" '.findings[4].message')" "$L200"
  check "ledger[${eng}]: no count field on any entry" \
    "$(get "$(ckpt "$run")" '[.findings[] | keys[] | select(test("count|occurrences|seen|times"))] | length')" "0"
  # url cap / urlLen / no-collision, asserted PER ENGINE — a fold.py-only
  # regression in the cap is invisible to the parity comparison alone,
  # because parity cannot see a divergence the fixtures never reach.
  check "ledger[${eng}]: over-cap url projected at 1024 characters" \
    "$(get "$(ckpt "$run")" '[.findings[] | select(.criterionId=="EC4") | .url | length] | join(",")')" "1024,1024"
  check "ledger[${eng}]: urlLen carries the full lengths" \
    "$(get "$(ckpt "$run")" '[.findings[] | select(.criterionId=="EC4") | .urlLen] | join(",")')" "2000,2001"
  check "ledger[${eng}]: same 1024-char prefix, different length -> two findings" \
    "$(get "$(ckpt "$run")" '[.findings[] | select(.criterionId=="EC4")] | length')" "2"
  check "ledger[${eng}]: truncated keys carry the urlLen discriminator" \
    "$(get "$(ckpt "$run")" '[.findings[] | select(.criterionId=="EC4") | .findingKey | split("#") | .[1]] | join(",")')" "2000|500,2001|500"
  check "ledger[${eng}]: every over-cap event is reported as a contract breach" \
    "$(get "$(anom "$run")" '[.anomalies[] | select(.rule=="finding-url-oversize")] | length')" "3"
  check "ledger[${eng}]: truncation with an empty detailRef is reported" \
    "$(get "$(anom "$run")" '[.anomalies[] | select(.rule=="finding-detail-missing") | .findingKey | split("|") | .[0]] | join(",")')" "EC5"
  check "ledger[${eng}]: an emitter-supplied urlLen is honoured" \
    "$(get "$(ckpt "$run")" '[.findings[] | select(.criterionId=="EC6") | [(.url | length), .urlLen] | join("/")] | join(",")')" "1024/2000"
  check "ledger[${eng}]: an emitter-capped url still keys with the urlLen discriminator" \
    "$(get "$(ckpt "$run")" '[.findings[] | select(.criterionId=="EC6") | .findingKey | split("#") | .[1]] | join(",")')" "2000|500"
  check "ledger[${eng}]: an already-capped event is NOT reported as a breach" \
    "$(get "$(anom "$run")" '[.anomalies[] | select(.rule=="finding-url-oversize") | .findingKey | split("|") | .[0]] | join(",")')" "EC4,EC4,EC5"
  check "ledger[${eng}]: urlLen is an integer on every entry" \
    "$(get "$(ckpt "$run")" '[.findings[] | .urlLen | type] | unique | join(",")')" "number"
}

if command -v python3 >/dev/null 2>&1; then
  parity_case happy     write_happy_journal
  parity_case malformed write_parity_journal
  parity_case ledger    write_ledger_journal
  ledger_asserts jq      parity-ledger-jq
  ledger_asserts python3 parity-ledger-py

  # Named, engine-independent assertions on the malformed case, so a
  # divergence is not the only thing this fixture can catch: the degenerate
  # rows must fold to SPECIFIC values, not merely to the same value twice.
  MR="parity-malformed-jq"
  check "malformed: unregistered event is still an unknown-event anomaly" \
    "$(get "$(anom "$MR")" '[.anomalies[] | select(.rule=="unknown-event" and .event=="totally_unknown")] | length')" "1"
  check "malformed: all-fields-missing finding folds to the all-empty key" \
    "$(get "$(ckpt "$MR")" '.findings[0].findingKey')" "||||"
  check "malformed: wrong-typed fields coerce (number criterionId, non-integer status)" \
    "$(get "$(ckpt "$MR")" '.findings[1].findingKey')" "42||||"
  check "malformed: duplicate network finding collapses" \
    "$(get "$(ckpt "$MR")" '[.findings[] | select(.url=="https://app.test/x")] | length')" "1"
  # Codepoints, not JSON text: the two engines escape a NUL/NBSP differently
  # on the wire (that is what `canonical` exists to normalize), so the VALUE
  # is what this asserts. NUL/SOH/ESC/NBSP survive; TAB/LF and the 3-space
  # run collapse to one space each.
  check "malformed: control characters normalized in the console message" \
    "$(get "$(ckpt "$MR")" '.findings[3].message | explode | tostring')" \
    "[99,116,108,0,97,1,98,27,99,32,100,32,101,160,102,32,103]"
  check "malformed: empty console message keys on the empty string" \
    "$(get "$(ckpt "$MR")" '.findings[4].findingKey')" "EC2|console|||"
  check "malformed: leading/trailing whitespace trimmed, literal status preserved" \
    "$(get "$(ckpt "$MR")" '.findings[5].findingKey')" \
    "EC3|network|POST|https://third.example/beacon|unhandled-exception"
  check "malformed: message trimmed" \
    "$(get "$(ckpt "$MR")" '.findings[5].message')" "leading and trailing"
  check "malformed: six findings total" "$(findings_len "$MR")" "6"
  check "malformed: pre-existing criteria projection untouched" \
    "$(get "$(ckpt "$MR")" '[.criteria[].criterion_id] | join(",")')" "EC1"
else
  echo "SKIP - test_jq_and_python_folds_agree: python3 not on this host, cannot exercise both engines"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
