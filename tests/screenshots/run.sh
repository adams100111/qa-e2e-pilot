#!/usr/bin/env bash
# Tests for mandatory screenshot evidence (engine 0.10.0, ADR-0028):
#   - capture -> record: record-evidence.sh screenshot binds the image to the
#     browser_take_screenshot call the capture hook hashed, and REFUSES at
#     record time everything that could never verify (wrong tool, foreign or
#     altered file, a capture another criterion already claimed, a
#     description instead of a pointer, a non-image);
#   - provenance.sh kind screenshot (hash binding, filename fallback);
#   - screenshot-evidence.sh status (tampered / duplicate / unbound);
#   - checkpoint.sh's screenshot gate (pass/fail refused without one on a
#     browser-driven run; blocked + no-browser runs only NOTE; opt-outs);
#   - qa-verify.sh: missing -> degrade (never override), forged -> override,
#     fail rows -> record-only "__screenshots__", requireScreenshots:false.
# Every block runs under BOTH engines: jq, and python3 via a fakebin PATH
# that hides jq from every script (record-evidence.sh decides by `command -v`).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$ROOT/scripts/capture-hook.sh"
REC="$ROOT/skills/checkpointing-qa-memory/scripts/record-evidence.sh"
SHOT="$ROOT/skills/checkpointing-qa-memory/scripts/screenshot-evidence.sh"
CKPT="$ROOT/skills/checkpointing-qa-memory/scripts/checkpoint.sh"
PROV="$ROOT/scripts/provenance.sh"
QAV="$ROOT/scripts/qa-verify.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected to contain '$3'; got '$2')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset QA_REQUIRE_SCREENSHOTS

# fakebin: every tool on PATH except jq (python3 leg).
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
IFS=':' read -ra _dirs <<< "$PATH"
for d in "${_dirs[@]}" /usr/bin /bin; do
  [[ -d "$d" ]] || continue
  for t in "$d"/*; do
    n="${t##*/}"; [[ "$n" == jq ]] && continue
    [[ -x "$t" && ! -e "$FAKEBIN/$n" ]] && ln -s "$t" "$FAKEBIN/$n" 2>/dev/null
  done
done

mkpng() { # <path> <seed> — a real (tiny) PNG, distinct per seed
  python3 - "$1" "$2" <<'PY'
import struct, zlib, sys
s = int(sys.argv[2])
raw = b''.join(b'\x00' + bytes([s % 256, (s * 7) % 256, (s * 13) % 256]) * 4 for _ in range(3))
ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', 4, 3, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))
PY
}

for ENG in jq python3; do
  P="$WORK/p-$ENG"; rm -rf "$P"; mkdir -p "$P/.qa/runs/r1" "$P/shots"
  echo r1 > "$P/.qa/runs/latest"
  if [[ "$ENG" == jq ]]; then EP="$PATH"; else EP="$FAKEBIN"; fi
  run() { ( cd "$P" && PATH="$EP" QA_ENGINE="$ENG" "$@" ); }
  hook_shot() { # <filename> — simulate the driver saving + the capture hook seeing it
    printf '%s' '{"tool_name":"mcp__plugin_playwright_playwright__browser_take_screenshot","tool_input":{"filename":"'"$1"'","fullPage":true,"scale":"css"},"tool_response":[{"type":"text","text":"### Result\n- [Screenshot of full page]('"$1"')"}],"cwd":"'"$P"'"}' \
      | ( cd "$P" && PATH="$EP" QA_ENGINE="$ENG" bash "$HOOK" >/dev/null 2>&1 )
  }
  hook_tool() { # <tool-suffix>
    printf '%s' '{"tool_name":"mcp__plugin_playwright_playwright__'"$1"'","tool_input":{"element":"Save","ref":"e1"},"tool_response":[],"cwd":"'"$P"'"}' \
      | ( cd "$P" && PATH="$EP" QA_ENGINE="$ENG" bash "$HOOK" >/dev/null 2>&1 )
  }
  seq_last() { tail -n1 "$P/.qa/runs/r1/toolstream.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["seq"])'; }

  # --- record time ---------------------------------------------------------
  hook_tool browser_click                      # seq 1
  mkpng "$P/shots/c1-after.png" 11; hook_shot shots/c1-after.png   # seq 2
  out="$(run bash "$REC" r1 C1 screenshot --phase after 2>&1)"; rc=$?
  check "[$ENG] record: newest captured shot is bound (exit 0)" "$rc" "0"
  check "[$ENG] record: prints the image path" "$out" "evidence/C1/screenshot-after.png"
  SC="$P/.qa/runs/r1/evidence/C1/screenshot-after.json"
  check "[$ENG] record: image copied" "$(cmp -s "$P/shots/c1-after.png" "$P/.qa/runs/r1/evidence/C1/screenshot-after.png" && echo same)" "same"
  check "[$ENG] record: sidecar sourceRef = the screenshot seq" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["provenance"]["sourceRef"])' "$SC")" "seq:2"
  check "[$ENG] record: binding by the hook's sha256" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binding"])' "$SC")" "sha256"
  check "[$ENG] record: fullPage taken from the captured args" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fullPage"])' "$SC")" "True"

  out="$(run bash "$REC" r1 C2 screenshot --phase after --source-ref seq:2 2>&1)"; rc=$?
  check "[$ENG] refuse: a capture already claimed by C1" "$rc" "1"; contains "[$ENG] refuse: claimed message" "$out" "already claimed"
  out="$(run bash "$REC" r1 C2 screenshot --phase after --source-ref seq:1 2>&1)"; rc=$?
  check "[$ENG] refuse: pointer at a browser_click" "$rc" "1"; contains "[$ENG] refuse: wrong-tool message" "$out" "not browser_take_screenshot"
  out="$(run bash "$REC" r1 C2 screenshot --phase after --source-ref 'browser_take_screenshot of the table' 2>&1)"; rc=$?
  check "[$ENG] refuse: a description is not a pointer" "$rc" "1"
  out="$(run bash "$REC" r1 C2 screenshot --phase after --source-ref seq:99 2>&1)"; rc=$?
  check "[$ENG] refuse: dangling seq" "$rc" "1"
  mkpng "$P/shots/forged.png" 99
  out="$(run bash "$REC" r1 C2 screenshot --phase after --file shots/forged.png 2>&1)"; rc=$?
  check "[$ENG] refuse: an image no captured call produced" "$rc" "1"
  printf 'not an image' > "$P/shots/notes.png"
  out="$(run bash "$REC" r1 C2 screenshot --phase after --file shots/notes.png 2>&1)"; rc=$?
  check "[$ENG] refuse: not a PNG/JPEG/WebP by magic bytes" "$rc" "1"; contains "[$ENG] refuse: magic message" "$out" "magic bytes"
  mkpng "$P/shots/c2.png" 21; hook_shot shots/c2.png          # seq 3, hashed
  mkpng "$P/shots/c2.png" 22                                   # overwritten AFTER capture
  out="$(run bash "$REC" r1 C2 screenshot --phase after --source-ref seq:3 --file shots/c2.png 2>&1)"; rc=$?
  check "[$ENG] refuse: file altered after the hook hashed it" "$rc" "1"; contains "[$ENG] refuse: sha message" "$out" "sha256 differs"
  out="$(run bash "$REC" r1 C2 screenshot 2>&1)"; rc=$?
  check "[$ENG] refuse: --phase required" "$rc" "1"
  out="$(run bash "$REC" r1 C2 screenshot --phase after --label 'a/b' 2>&1)"; rc=$?
  check "[$ENG] refuse: label must be a token" "$rc" "1"
  check "[$ENG] refuse: nothing was written for C2" "$(ls "$P/.qa/runs/r1/evidence/C2" 2>/dev/null | wc -l | tr -d ' ')" "0"

  # Saved straight into the evidence dir (workspace root == project root): no copy needed.
  mkdir -p "$P/.qa/runs/r1/evidence/admin/C3"
  mkpng "$P/.qa/runs/r1/evidence/admin/C3/screenshot-before.png" 31
  hook_shot .qa/runs/r1/evidence/admin/C3/screenshot-before.png
  out="$(run bash "$REC" r1 C3 screenshot --phase before --persona admin 2>&1)"; rc=$?
  check "[$ENG] record: in-place file, persona-scoped" "$rc|$out" "0|evidence/admin/C3/screenshot-before.png"

  # Pre-0.10.0 / non-Claude toolstream event: no hash -> bound by file name.
  mkpng "$P/shots/legacy.png" 41
  printf '%s\n' '{"tool":"mcp__plugin_playwright_playwright__browser_take_screenshot","args":{"filename":"shots/legacy.png"},"responseBody":"","seq":50,"ts":"2026-10-01T00:00:00Z"}' >> "$P/.qa/runs/r1/toolstream.jsonl"
  out="$(run bash "$REC" r1 C4 screenshot --phase after --file shots/legacy.png 2>&1)"; rc=$?
  check "[$ENG] record: hashless event binds by file name" "$rc" "0"
  check "[$ENG] record: binding filename" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["binding"], d["provenance"]["sourceRef"])' "$P/.qa/runs/r1/evidence/C4/screenshot-after.json")" "filename seq:50"
  mkpng "$P/shots/other-name.png" 41
  out="$(run bash "$REC" r1 C5 screenshot --phase after --source-ref seq:50 --file shots/other-name.png 2>&1)"; rc=$?
  check "[$ENG] refuse: hashless event, different file name" "$rc" "1"

  # --- provenance.sh kind screenshot ----------------------------------------
  check "[$ENG] provenance: recorded sidecar bound" "$(run bash "$PROV" check r1 "$SC")" "bound"
  check "[$ENG] provenance: pointer at a click -> unbound" \
    "$(run bash "$PROV" check r1 '{"kind":"screenshot","sha256":"x","sourceFile":"a.png","provenance":{"sourceRef":"seq:1"}}')" "unbound"
  check "[$ENG] provenance: hash mismatch -> unbound" \
    "$(run bash "$PROV" check r1 '{"kind":"screenshot","sha256":"deadbeef","sourceFile":"c1-after.png","provenance":{"sourceRef":"seq:2"}}')" "unbound"
  check "[$ENG] provenance: no pointer, filename match on a hashless event -> bound" \
    "$(run bash "$PROV" check r1 '{"kind":"screenshot","sha256":"x","sourceFile":"/x/legacy.png"}')" "bound"

  # --- status: integrity, duplicates ------------------------------------------
  st="$(run bash "$SHOT" status r1 C1)"
  check "[$ENG] status: valid + bound" "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["valid"], d["bound"], len(d["problems"]))' "$st")" "1 1 0"
  cp "$SC" "$P/.qa/runs/r1/evidence/C4/screenshot-after-dup.json"
  cp "$P/.qa/runs/r1/evidence/C1/screenshot-after.png" "$P/.qa/runs/r1/evidence/C4/screenshot-after.png.bak"
  python3 - "$P/.qa/runs/r1/evidence/C4/screenshot-after-dup.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["image"] = "screenshot-after.png.bak"; json.dump(d, open(sys.argv[1], "w"))
PY
  st="$(run bash "$SHOT" status r1 C4)"
  contains "[$ENG] status: a second sidecar claiming the same capture -> duplicate" "$st" '"problem":"duplicate"'
  rm -f "$P/.qa/runs/r1/evidence/C4/screenshot-after-dup.json" "$P/.qa/runs/r1/evidence/C4/screenshot-after.png.bak"

  # --- checkpoint gate --------------------------------------------------------
  out="$(run bash "$CKPT" r1 G1 pass 2>&1)"; rc=$?
  check "[$ENG] gate: pass with no screenshot on a browser-driven run refused" "$rc" "1"; contains "[$ENG] gate: says how to fix" "$out" "record-evidence.sh r1 G1 screenshot --phase after"
  out="$(run bash "$CKPT" r1 G1 fail --bug-ref B1 2>&1)"; rc=$?
  check "[$ENG] gate: fail with no screenshot refused too" "$rc" "1"
  out="$(run bash "$CKPT" r1 G1 blocked 2>&1)"; rc=$?
  check "[$ENG] gate: blocked never refused" "$rc" "0"; contains "[$ENG] gate: blocked gets a NOTE" "$out" "no recorded screenshot"
  out="$(run bash "$CKPT" r1 C1 pass 2>&1)"; rc=$?
  check "[$ENG] gate: pass with a recorded screenshot accepted" "$rc" "0"
  out="$(cd "$P" && PATH="$EP" QA_ENGINE="$ENG" QA_REQUIRE_SCREENSHOTS=false bash "$CKPT" r1 G2 pass 2>&1)"; rc=$?
  check "[$ENG] gate: QA_REQUIRE_SCREENSHOTS=false opts out" "$rc" "0"
  echo '{"report":{"requireScreenshots":false}}' > "$P/.qa/config.json"
  out="$(run bash "$CKPT" r1 G3 pass 2>&1)"; rc=$?
  check "[$ENG] gate: report.requireScreenshots:false opts out" "$rc" "0"
  rm -f "$P/.qa/config.json"
  # tamper the recorded image -> the gate no longer counts it
  mkpng "$P/.qa/runs/r1/evidence/C1/screenshot-after.png" 77
  out="$(run bash "$CKPT" r1 C1 pass 2>&1)"; rc=$?
  check "[$ENG] gate: an image altered after recording does not count" "$rc" "1"
  cp "$P/shots/c1-after.png" "$P/.qa/runs/r1/evidence/C1/screenshot-after.png"
  # no browser in the toolstream -> NOTE only
  mkdir -p "$P/.qa/runs/r2"; printf '%s\n' '{"tool":"Bash","args":{},"seq":1}' > "$P/.qa/runs/r2/toolstream.jsonl"
  out="$(run bash "$CKPT" r2 N1 pass 2>&1)"; rc=$?
  check "[$ENG] gate: no captured browser call -> NOTE, accepted" "$rc" "0"

  # --- qa-verify ---------------------------------------------------------------
  Q="$WORK/q-$ENG"; rm -rf "$Q"; mkdir -p "$Q/.qa/runs/v1" "$Q/shots"; echo v1 > "$Q/.qa/runs/latest"
  qrun() { ( cd "$Q" && PATH="$EP" QA_ENGINE="$ENG" "$@" ); }
  qshot() { printf '%s' '{"tool_name":"mcp__plugin_playwright_playwright__browser_take_screenshot","tool_input":{"filename":"'"$1"'","scale":"css"},"tool_response":[],"cwd":"'"$Q"'"}' | ( cd "$Q" && PATH="$EP" QA_ENGINE="$ENG" bash "$HOOK" >/dev/null 2>&1 ); }
  for c in A B T F; do
    qrun bash "$REC" v1 "$c" computed --oracle 1 --observed 1 --match true >/dev/null
  done
  mkpng "$Q/shots/a.png" 51; qshot shots/a.png; qrun bash "$REC" v1 A screenshot --phase after >/dev/null
  mkpng "$Q/shots/t.png" 52; qshot shots/t.png; qrun bash "$REC" v1 T screenshot --phase after >/dev/null
  qrun bash "$CKPT" v1 A pass --kinds computed >/dev/null 2>&1
  qrun bash "$CKPT" v1 T pass --kinds computed >/dev/null 2>&1
  ( cd "$Q" && PATH="$EP" QA_ENGINE="$ENG" QA_REQUIRE_SCREENSHOTS=false bash "$CKPT" v1 B pass --kinds computed >/dev/null 2>&1 )
  ( cd "$Q" && PATH="$EP" QA_ENGINE="$ENG" QA_REQUIRE_SCREENSHOTS=false bash "$CKPT" v1 F fail --bug-ref X >/dev/null 2>&1 )
  mkpng "$Q/.qa/runs/v1/evidence/T/screenshot-after.png" 53     # tamper after recording
  qrun bash "$QAV" v1 >/dev/null 2>&1; rc=$?
  V="$Q/.qa/runs/v1/verification.json"
  vf() { python3 -c 'import json,sys
for r in json.load(open(sys.argv[1])):
    if r["criterionId"] == sys.argv[2]:
        print(r["verifierVerdict"], r["confidence"], " || ".join(r["reasons"])); break' "$V" "$1"; }
  check "[$ENG] qa-verify: a tampered screenshot overrides (exit 1)" "$rc" "1"
  check "[$ENG] qa-verify: bound screenshot -> pass, high" "$(vf A)" "pass high "
  contains "[$ENG] qa-verify: missing screenshot -> pass, LOW (degrade, never override)" "$(vf B)" "pass low no screenshot evidence"
  contains "[$ENG] qa-verify: tampered -> fail" "$(vf T)" "fail high screenshot TAMPERED"
  contains "[$ENG] qa-verify: fail row without a screenshot -> __screenshots__ record" "$(vf __screenshots__)" "pass low fail F: no screenshot evidence"
  cp "$Q/shots/t.png" "$Q/.qa/runs/v1/evidence/T/screenshot-after.png"
  ( cd "$Q" && PATH="$EP" QA_ENGINE="$ENG" QA_REQUIRE_SCREENSHOTS=false bash "$QAV" v1 >/dev/null 2>&1 ); rc=$?
  check "[$ENG] qa-verify: restored image + requirement off -> exit 0" "$rc" "0"
  check "[$ENG] qa-verify: requirement off -> no degrade for B" "$(vf B)" "pass high "
  check "[$ENG] qa-verify: requirement off -> no __screenshots__ record" "$(vf __screenshots__)" ""
  rm -f "$Q/.qa/runs/v1/toolstream.jsonl"
  qrun bash "$QAV" v1 >/dev/null 2>&1
  contains "[$ENG] qa-verify: screenshot but no toolstream -> low (no-toolstream degrade)" "$(vf A)" "pass low no toolstream captured"
done

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
