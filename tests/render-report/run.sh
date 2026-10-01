#!/usr/bin/env bash
# Tests for the deterministic report renderer (engine 0.10.0, ADR-0028):
# scripts/render-report.sh / render-report.js (+ the render-report.py shim),
# rendered against the committed fixture run in tests/render-report/fixture-run
# (small real PNGs: before/after, a persona-scoped labelled shot, a loose
# pre-0.10.0 image, an image altered after recording, a pass with none, a
# deferred row, a qa-verify override, a hostile string in last_action).
# Single engine by design: the renderer is dependency-free node only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SH="$ROOT/scripts/render-report.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected to contain '$3')"; FAIL=$((FAIL+1)); fi; }
lacks() { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected NOT to contain '$3')"; FAIL=$((FAIL+1)); fi; }
count() { grep -o -- "$2" "$1" | wc -l | tr -d ' '; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.qa/runs"
cp -R "$HERE/fixture-run" "$WORK/.qa/runs/fx"

out="$(cd "$WORK" && bash "$SH" .qa/runs/fx 2>&1)"; rc=$?
check "render exits 0" "$rc" "0"
contains "summary line printed" "$out" "tally: pass=4 fail=2 blocked=1 deferred=1 error=0 total=8"
H="$WORK/.qa/runs/fx/report.html"; M="$WORK/.qa/runs/fx/report.md"
check "report.html written" "$([[ -s "$H" ]] && echo yes)" "yes"
check "report.md written" "$([[ -s "$M" ]] && echo yes)" "yes"
HTML="$(cat "$H")"; MD="$(cat "$M")"

# self-contained / offline
check "no external src/href (http, //cdn)" "$(grep -Eo '(src|href)="(https?:)?//' "$H" | wc -l | tr -d ' ')" "0"
check "no external stylesheet/script tags" "$(grep -Eic '<link |<script[^>]+src=' "$H")" "0"
check "no template slot left" "$(grep -c '{{' "$H")" "0"
# thumbnails + groups
check "6 card thumbnails (C1x2, C2, C3, C4 legacy, C7)" "$(count "$H" 'class="shot-link"')" "6"
contains "relative image path" "$HTML" 'href="evidence/C1/screenshot-before.png"'
contains "persona-scoped path" "$HTML" 'src="evidence/admin/C3/screenshot-after-table.png"'
check "C1's two shots share one lightbox group" "$(count "$H" 'data-group="c-c1"')" "2"
contains "caption names criterion + phase" "$HTML" 'data-caption="C1 · after · full page"'
contains "caption names persona + label" "$HTML" 'data-caption="C3 · admin · after (table)"'
contains "before is ordered first" "$(grep -o 'data-caption="C1[^"]*"' "$H" | head -1)" "before"
# lightbox + gallery + filter
contains "lightbox dialog present" "$HTML" 'id="lb" hidden role="dialog" aria-modal="true"'
contains "Escape handler" "$HTML" '"Escape"'
contains "arrow-key navigation" "$HTML" '"ArrowRight"'
contains "all-screenshots gallery container" "$HTML" 'id="gallery"'
contains "verdict filter" "$HTML" 'data-filter="fail"'
# evidence honesty
contains "legacy loose image marked unbound" "$HTML" "not provenance-bound"
contains "altered image marked" "$HTML" "ALTERED after recording"
contains "pass without screenshot is called out" "$HTML" "No screenshot recorded for this criterion."
contains "binding pointer shown" "$HTML" "seq:7"
# verdicts: verifier wins
contains "C7 shown as fail (qa-verify override)" "$HTML" 'id="c-c7" data-verdict="fail"'
contains "override is explained" "$HTML" "in-run pass → overridden by qa-verify"
contains "verifier reason rendered" "$HTML" "screenshot TAMPERED"
contains "run-level record rendered" "$HTML" "__screenshots__"
contains "screenshot coverage line" "$HTML" "4 of 6 pass/fail criteria carry a recorded screenshot"
contains "deferred reason" "$HTML" "Round-close math requires a closed round"
contains "bug appendix" "$HTML" 'id="bug-bug-1"'
contains "checklist.json title used" "$HTML" "Admin totals"
# escaping
lacks "hostile last_action is escaped" "$HTML" "<script>alert(1)</script>"
contains "escaped form present" "$HTML" "&lt;script&gt;alert(1)&lt;/script&gt;"
check "exactly one script element (the template's)" "$(grep -c '<script' "$H")" "1"
# markdown
contains "md: relative image link" "$MD" "![C1 · after · full page](evidence/C1/screenshot-after.png)"
contains "md: legacy marked" "$MD" "(not provenance-bound)"
contains "md: override noted" "$MD" "**fail** (in-run pass, overridden by qa-verify)"
contains "md: missing screenshot noted" "$MD" "_No screenshot recorded._"

# deterministic: a re-render is byte-identical
cp "$H" "$WORK/first.html"; cp "$M" "$WORK/first.md"
( cd "$WORK" && bash "$SH" fx --quiet ); rc=$?
check "re-render by bare run-id from the project root" "$rc" "0"
check "re-render is byte-identical (html)" "$(cmp -s "$H" "$WORK/first.html" && echo same)" "same"
check "re-render is byte-identical (md)" "$(cmp -s "$M" "$WORK/first.md" && echo same)" "same"

# --embed: one portable file
cp -R "$HERE/fixture-run" "$WORK/emb"
( cd "$WORK" && bash "$SH" emb --embed --quiet ) 2>/dev/null; rc=$?
check "--embed renders (by path)" "$rc" "0"
check "--embed: every thumbnail is a data: URI" "$(grep -o 'class="shot-link" href="data:image/png;base64,' "$WORK/emb/report.html" | wc -l | tr -d ' ')" "6"
check "--embed: no relative image src left" "$(grep -c 'src="evidence/' "$WORK/emb/report.html")" "0"
contains "--embed: md still links relatively" "$(cat "$WORK/emb/report.md")" "](evidence/C1/screenshot-before.png)"

# a run with no verification.json says so; a run with no evidence still renders
mkdir -p "$WORK/bare"; printf '%s' '{"criteria":[{"criterion_id":"Z1","verdict":"pass","confidence":"high"}]}' > "$WORK/bare/checkpoint.json"
( cd "$WORK" && bash "$SH" bare --quiet ); rc=$?
check "minimal run renders" "$rc" "0"
contains "unverified run is labelled" "$(cat "$WORK/bare/report.html")" "Not independently verified"

# errors
out="$(cd "$WORK" && bash "$SH" nope 2>&1)"; rc=$?
check "missing run exits 1" "$rc" "1"; contains "missing run message" "$out" "no checkpoint.json"

# the 0.7.1-0.9.0 entry point still works
( cd "$WORK" && python3 "$ROOT/scripts/render-report.py" .qa/runs/fx >/dev/null ); rc=$?
check "render-report.py shim delegates" "$rc|$(cmp -s "$H" "$WORK/first.html" && echo same)" "0|same"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
