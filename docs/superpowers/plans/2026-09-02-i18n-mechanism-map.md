# i18n Mechanism Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Have `detecting-stack-profile`'s `detect-stack.sh` detect *where translations live* for the target stack (Laravel `lang/{ar,en}/*.php` + flat `lang/<locale>.json`, and/or a JS catalog `locales/<lng>/<ns>.json`) and record it as an `i18n` map on every `stack-profile.json` component, so a later localization phase can resolve a rendered string → key → catalog entry. The map is **data-driven** (catalog roots, library packages, and mechanism live in `stack-signatures.json`, not the engine), reports **per-catalog `mechanism`** so a fullstack repo carrying BOTH Laravel and JS catalogs is represented faithfully, points each catalog `path` at the **actual file** (with `namespace`) so keys are resolvable, and **degrades to `signal: weak`** with a *distinct* evidence reason for "no catalog directory found" vs "directory present but no supported (php/json) catalog" (Rails `yml` / Django `po`) — never failing the run.

**Architecture:** Additive change to one bundled script **plus a data-only extension of `stack-signatures.json`** (this is the correct call, not a shortcut: `SKILL.md` and the schema spec both state "the engine is a generic matcher; all knowledge is data … add a stack by appending a row — no engine code changes." i18n knowledge therefore belongs in the signatures file, keyed per stack.). Two new dependency-tolerant helpers (`i18n_absent`, `detect_i18n`) do a read-only filesystem scan whose **roots, library packages, and mechanism are read from the matched signature rows**; `detect_i18n` unions the i18n of *every* signature actually present in the repo (manifest + package match), so a Laravel+React repo reports both mechanisms and both libraries. The helpers are wired into all three component emit paths (code-based, runtime-fingerprint, generic fallback) so the `i18n` key is always present. Because `build-adapter.sh` copies `skills/`, `scripts/`, and `docs/` verbatim into `dist/<harness>/`, every source edit here must be followed by a **`dist/` regeneration + byte-oracle** re-run (see Global Constraints). Verified by extending the bash smoke runner `tests/detect-stack/run.sh` with new fixtures. No new runtime dependencies.

**Tech Stack:** Bash (`set -uo pipefail`), `jq` (already required by `detect-stack.sh main()`), `find`/`grep`/bash regex (POSIX filesystem scan), bash test runner with a `check`/`get` helper. Adapter generator (`scripts/build-adapter.sh`) + byte-oracle gate (`scripts/validate-adapters.sh`).

## Global Constraints

- **`jq` OR `python3` fallback convention.** `detect-stack.sh` already hard-requires `jq` inside `main()` (`have jq || { echo '{"error":"jq required for detection"}' | emit; return 0; }`, line 140) and only uses `python3` for the `cfg()` config-read fallback. The new i18n helpers run **only after** that `jq` guard and inside functions that already `have jq || return 0`, so they may use `jq` unconditionally. Do **not** add a new hard dependency. (CLAUDE.md "Bundled scripts depend on jq OR python3".) Note: like the rest of detection, the i18n scan does not run on a `python3`-only box — this is pre-existing script behavior, not a new regression.
- **Data-driven (no hardcoded roots/libs/mechanism in the engine).** The catalog `roots`, i18n `libraryPackages`, and `mechanism` label for each stack live in `stack-signatures.json` (`.stacks[].i18n` + `._fallback.i18n`). `detect_i18n` READS them from the matched rows; the script holds only the generic scan procedure. Adding a new stack's i18n convention is a signatures-file edit, never an engine edit — the same contract the rest of the detector already honors (`SKILL.md` "Extending (zero engine code)"; schema spec "signatures = data").
- **Degrade gracefully — never hard-fail, with an honest reason.** Unknown stacks, black-box targets, and repos with no catalog yield `i18n: {present:false, signal:"weak", …}`, not an error or non-zero exit. The absent-map `evidence` distinguishes: `"no i18n catalog directory found"` (none of the declared roots exist) vs `"i18n catalog directory present but no locale-named php/json catalog found (e.g. unsupported yml/po, or non-locale filenames)"` (a root exists but yields nothing usable — Rails `config/locales/*.yml`, Django `locale/**/*.po`, or a stray `locales/config.json`). (SKILL.md overview; spec §2 "degrade to `signal: weak` … never silently dropped".)
- **Signal is one-way into Confidence.** The `i18n.signal` (`strong|weak`) is a *detection* attribute. A `weak` i18n signal *causes* a later localization criterion's verdict `confidence` to be `low`; never the reverse, never the same field. (CONTEXT.md "Signal".)
- **The map only LOCATES; it never JUDGES.** The i18n map records catalog file paths/formats/locales/libraries/mechanisms. Whether an `ar` value is *correctly* translated is the held localization-adjudication step, out of scope here. Key *presence* is a definite oracle; a present-but-Latin value is a downstream deliberateness heuristic. (Spec §2, §4 family 2.)
- **Locale sanity gate.** Both the per-locale-dir branch and the flat-json branch admit a path segment as a locale **only** if it matches `^[a-z]{2}([-_][A-Za-z]{2,4})?$` (matches `en`, `ar`, `en_US`, `pt-BR`, `zh-Hant`; rejects `config`, `manifest`, `messages`, `schema`). This kills the false-positive where any `*.json` under a root would otherwise be catalogued as a locale. (Known limitation: 3-letter-only tags like `fil`/`yue` are not admitted; documented, acceptable for the Laravel+JS scope.)
- **Portability — regenerate `dist/` and re-run the byte-oracle after EVERY source edit.** `scripts/build-adapter.sh` assembles each `dist/<harness>/` via `cp -R skills scripts docs CONTEXT.md …` (line 69), so `detect-stack.sh`, `stack-signatures.json`, `SKILL.md` (all under `skills/`) **and** the schema spec (under `docs/`) are copied **byte-identical** into `dist/{claude,codex,pi,opencode}/`. They are byte-identical today (`cmp` confirms). Any edit here staled all four copies; `scripts/validate-adapters.sh` (the byte-oracle: rebuilds all four adapters, byte-matches the Claude build, and static-checks every core `.sh/.js/.json`) will fail until the copies are regenerated. Therefore each Task ends by rebuilding `dist/` and running the byte-oracle as a CI-parity gate; `dist/` is git-ignored and is **never** committed.
- **Tests are bash runners at `tests/<name>/run.sh`.** Extend `tests/detect-stack/run.sh`; assertions use its existing `check "name" "$got" "$want"` and `get "$file" '<jq-filter>'` helpers. New fixtures live under `tests/detect-stack/fixtures/`. (`tests/` is NOT copied into `dist/`.)
- **Validate before every commit:**
  - `bash -n skills/detecting-stack-profile/scripts/detect-stack.sh` (syntax),
  - `python3 -c "import json;json.load(open('<f>'))"` for every new `*.json` fixture **and** for `skills/detecting-stack-profile/references/stack-signatures.json` (edited),
  - `bash tests/detect-stack/run.sh` prints `FAIL=0` and exits 0,
  - `bash scripts/validate-adapters.sh` exits 0 (byte-oracle + core static checks; it internally rebuilds `dist/`),
  - `bash tests/portability/run.sh` prints `FAIL=0` (PCRE grep/perl parity — `detect_i18n` uses no `grep -P`, so it stays green; run it because the portability suite is the CI gate for anything copied into `dist/`),
  - run `bash tests/portability/run.sh && bash scripts/validate-adapters.sh` as a CI-parity gate; `dist/` is **git-ignored and is never committed**. (CLAUDE.md "Validate before committing".)
- **Commit messages contain no Claude/Anthropic attribution and no `Co-Authored-By` trailer.** (User global rule — overrides the repo CLAUDE.md trailer note.)

---

### Task 1: i18n signature data + data-driven helpers + Laravel detection + weak-signal degrade

Add per-stack `i18n` blocks to `stack-signatures.json` (Laravel + two unsupported-format backends + `_fallback`), add the `i18n_absent` / `manifest_path` / `detect_i18n` helpers (data-driven; php-dir + json-dir + flat-json branches with the locale gate; per-catalog `mechanism`; file-level `path` + `namespace`), and wire them into **all three** emit paths. Extend the Laravel fixture with a `lang/` catalog (incl. a non-locale `config.json` to prove the gate) and assert the map; assert the unknown-repo fallback and the runtime-only component degrade to `present:false`/`signal:weak`.

**Files:**
- Modify: `skills/detecting-stack-profile/references/stack-signatures.json` — add an `i18n` key to the `laravel`, `rails`, and `django` stack objects and to `_fallback`.
- Modify: `skills/detecting-stack-profile/scripts/detect-stack.sh` — insert three helpers after line 52; wire `detect_i18n "$repo"` into `detect_code_component` (the `jq -n` at lines 89-96); wire `i18n_absent` into `detect_runtime_component` (the `jq -n` at lines 126-133) and the `main()` fallback (the `jq -n` at lines 169-174).
- Create: `tests/detect-stack/fixtures/laravel/lang/en/messages.php`
- Create: `tests/detect-stack/fixtures/laravel/lang/ar/messages.php`
- Create: `tests/detect-stack/fixtures/laravel/lang/en.json`
- Create: `tests/detect-stack/fixtures/laravel/lang/config.json`  *(non-locale — must NOT be catalogued)*
- Test: `tests/detect-stack/run.sh` — append Cases 6-8 after Case 5 (after line 48), before the `echo "---"` summary (line 50).

**Interfaces:**
- Consumes: `stack-signatures.json` `.stacks[].i18n` (`{roots[], libraryPackages[], mechanism}`) and `._fallback.i18n`; `$repo` (already computed by `detect_code_component`). No new args to any existing function beyond `detect_i18n`'s single `repo`.
- Produces:
  - `i18n_absent(reason) → stdout JSON` — the absent map:
    `{present:false, libraries:[], mechanisms:[], catalogs:[], locales:[], signal:"weak", evidence:[<reason>]}`.
  - `manifest_path(repo, manifest) → stdout` — the matched manifest file for a stack row (glob or exact), or nothing.
  - `detect_i18n(repo) → stdout JSON` — unions the i18n of every signature present in `repo`:
    `{present:true, libraries:[…], mechanisms:[…distinct…], catalogs:[{root,locale,format:"php"|"json",mechanism,path,namespace}], locales:[…], signal:"strong", evidence:[…]}`, else delegates to `i18n_absent` with the appropriate reason.
  - Every `components[]` entry in `stack-profile.json` now carries an `i18n` object. Later phases (`detecting-visual-ux` localization family, `analyzing-feature-ui`) read `components[].i18n`.

- [ ] **Step 1: Add the i18n signature blocks**

In `skills/detecting-stack-profile/references/stack-signatures.json`, add an `"i18n"` key to the `laravel`, `rails`, and `django` stack objects, and to `_fallback`. (Placement inside each object is free; put it after `"orm"` for readability.)

Laravel:
```json
"i18n": { "roots": ["lang", "resources/lang"], "libraryPackages": ["laravel-lang/lang", "laravel-lang/common"], "mechanism": "laravel-lang" }
```
Rails (its `config/locales/*.yml` is an unsupported format → exercises the "directory present but unsupported" degrade):
```json
"i18n": { "roots": ["config/locales"], "libraryPackages": ["rails-i18n"], "mechanism": "rails-yml" }
```
Django (its `locale/**/*.po` is unsupported → same degrade branch):
```json
"i18n": { "roots": ["locale"], "libraryPackages": [], "mechanism": "gettext-po" }
```
`_fallback` (unknown stack ⇒ nothing to locate; empty roots keep it absent):
```json
"i18n": { "roots": [], "libraryPackages": [], "mechanism": "none" }
```

- [ ] **Step 2: Create the Laravel catalog fixture files**

`tests/detect-stack/fixtures/laravel/lang/en/messages.php`:
```php
<?php

return [
    'welcome' => 'Welcome',
    'title' => 'Deliverables',
];
```

`tests/detect-stack/fixtures/laravel/lang/ar/messages.php`:
```php
<?php

return [
    'welcome' => 'مرحبا',
    'title' => 'المخرجات',
];
```

`tests/detect-stack/fixtures/laravel/lang/en.json`:
```json
{ "Save": "Save", "Cancel": "Cancel" }
```

`tests/detect-stack/fixtures/laravel/lang/config.json` *(a non-locale JSON that must be ignored by the locale gate)*:
```json
{ "note": "not a locale file" }
```

- [ ] **Step 3: Write the failing tests**

In `tests/detect-stack/run.sh`, insert immediately **after** the Case 5 block (after line 48) and **before** the `echo "---"` summary line:

```bash
# Case 6: Laravel i18n mechanism map — php per-locale dirs + flat lang/<locale>.json; non-locale json ignored
OUT6="$(mktemp)"
QA_REPOS="$FIX/laravel" bash "$ENGINE" --no-runtime --out "$OUT6" >/dev/null 2>&1
check "i18n present"      "$(get "$OUT6" '.components[0].i18n.present')"                                        "true"
check "i18n mechanism"    "$(get "$OUT6" '.components[0].i18n.mechanisms | index("laravel-lang") != null')"    "true"
check "i18n signal"       "$(get "$OUT6" '.components[0].i18n.signal')"                                         "strong"
check "i18n locale ar"    "$(get "$OUT6" '.components[0].i18n.locales | index("ar") != null')"                 "true"
check "i18n locale en"    "$(get "$OUT6" '.components[0].i18n.locales | index("en") != null')"                 "true"
check "i18n has php"      "$(get "$OUT6" '[.components[0].i18n.catalogs[].format] | index("php") != null')"    "true"
check "i18n has json"     "$(get "$OUT6" '[.components[0].i18n.catalogs[].format] | index("json") != null')"   "true"
check "i18n file path"    "$(get "$OUT6" '[.components[0].i18n.catalogs[] | select(.format=="php") | .path] | index("lang/ar/messages.php") != null')" "true"
check "i18n namespace"    "$(get "$OUT6" '[.components[0].i18n.catalogs[] | select(.format=="php") | .namespace] | index("messages") != null')" "true"
check "i18n gate config"  "$(get "$OUT6" '.components[0].i18n.locales | index("config") == null')"             "true"

# Case 7: unknown repo → fallback component's i18n degrades to present:false / signal:weak (never fails)
OUT7="$(mktemp)"
QA_REPOS="$FIX/unknown" bash "$ENGINE" --no-runtime --out "$OUT7" >/dev/null 2>&1
check "i18n absent present" "$(get "$OUT7" '.components[0].i18n.present')" "false"
check "i18n absent signal"  "$(get "$OUT7" '.components[0].i18n.signal')"  "weak"

# Case 8: runtime-only component (no repo to scan) still carries a weak i18n map
OUT8="$(mktemp)"
bash "$ENGINE" --no-code --headers-file "$FIX/server/laravel-headers.txt" --out "$OUT8" >/dev/null 2>&1
check "i18n runtime present" "$(get "$OUT8" '.components[0].i18n.present')" "false"
check "i18n runtime signal"  "$(get "$OUT8" '.components[0].i18n.signal')"  "weak"
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bash tests/detect-stack/run.sh`
Expected: Cases 6-8 FAIL because `.components[0].i18n` does not exist yet (`get` returns empty). Cases 1-5 still `ok`. Final line reports a non-zero `FAIL=` and the script exits non-zero.

- [ ] **Step 5: Add the three i18n helper functions**

In `skills/detecting-stack-profile/scripts/detect-stack.sh`, insert this block immediately **after** line 52 (the closing `fi` of the `REPOS` config-read block) and **before** the `# ── code-based detection …` comment on line 54:

```bash
# ── i18n mechanism map (data-driven) ──────────────────────────────────────────
# Locate WHERE translations live so a later localization phase can resolve a
# rendered string → key → catalog entry. Read-only filesystem scan whose roots,
# library packages, and mechanism come from stack-signatures.json (.stacks[].i18n
# + ._fallback.i18n) — the engine holds only the generic procedure. LOCATES only,
# never judges. Degrades to a present:false / signal:weak map with a distinct
# reason; never hard-fails. jq is guaranteed here (callers run after the have-jq
# guards). NOTE: LOCALE_RE is used UNQUOTED in [[ =~ ]] (quoting makes it literal).
LOCALE_RE='^[a-z]{2}([-_][A-Za-z]{2,4})?$'

i18n_absent() {  # $1 = reason
  jq -n --arg r "${1:-no i18n catalog directory found}" \
    '{present:false, libraries:[], mechanisms:[], catalogs:[], locales:[], signal:"weak", evidence:[$r]}'
}

manifest_path() {  # <repo> <manifest-glob-or-name>  → echoes the matched file or nothing
  local repo="$1" manifest="$2"
  if [[ "$manifest" == \** ]]; then
    find "$repo" -maxdepth 2 -name "$manifest" 2>/dev/null | head -1
  elif [[ -f "$repo/$manifest" ]]; then
    printf '%s' "$repo/$manifest"
  fi
}

# detect_i18n <repo>  → echoes the i18n map JSON, unioned across EVERY signature
# actually present in the repo (manifest + package match), so a fullstack repo
# reports both mechanisms and both libraries; each catalog is tagged with its
# row's mechanism, and each path points at the real file (with namespace).
detect_i18n() {
  local repo="$1"
  [[ -d "$repo" ]] || { i18n_absent "no repo path to scan"; return 0; }
  local n; n="$(jq '.stacks | length' "$SIGNATURES")"
  local cats="[]" libs="[]" locset="" rootseen=0 i
  for i in $(seq 0 $((n-1))); do
    jq -e ".stacks[$i].i18n" "$SIGNATURES" >/dev/null 2>&1 || continue
    local manifest mfile mech
    manifest="$(jq -r ".stacks[$i].manifest" "$SIGNATURES")"
    mfile="$(manifest_path "$repo" "$manifest")"
    [[ -n "$mfile" ]] || continue
    # same gate as detect_code_component: require a package signature in the manifest,
    # so a bare package.json does not fire every JS stack's i18n rows.
    local pkgmatch=0 p
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      grep -q -- "$p" "$mfile" 2>/dev/null && pkgmatch=1
    done < <(jq -r ".stacks[$i].packages[]?" "$SIGNATURES")
    [[ "$pkgmatch" -eq 1 ]] || continue
    mech="$(jq -r ".stacks[$i].i18n.mechanism" "$SIGNATURES")"
    # i18n library packages from THIS manifest
    local L
    while IFS= read -r L; do
      [[ -z "$L" ]] && continue
      if grep -q -- "\"$L\"" "$mfile" 2>/dev/null; then
        libs="$(jq -c --arg l "$L" 'if index($l) then . else . + [$l] end' <<< "$libs")"
      fi
    done < <(jq -r ".stacks[$i].i18n.libraryPackages[]?" "$SIGNATURES")
    # catalog scan across THIS stack's declared roots
    local root
    while IFS= read -r root; do
      [[ -z "$root" ]] && continue
      local dir="$repo/$root"
      [[ -d "$dir" ]] || continue
      rootseen=1
      # per-locale subdirectories: one catalog entry PER FILE (php or json), namespace=file stem
      local sub loc
      while IFS= read -r sub; do
        [[ -n "$sub" ]] || continue
        loc="$(basename "$sub")"
        [[ "$loc" =~ $LOCALE_RE ]] || continue
        local f fmt ns
        while IFS= read -r f; do
          [[ -n "$f" ]] || continue
          case "$f" in *.php) fmt="php" ;; *.json) fmt="json" ;; *) continue ;; esac
          ns="$(basename "$f")"; ns="${ns%.*}"
          cats="$(jq -c --arg r "$root" --arg l "$loc" --arg f "$fmt" --arg m "$mech" \
                     --arg p "$root/$loc/$(basename "$f")" --arg ns "$ns" \
            '. + [{root:$r, locale:$l, format:$f, mechanism:$m, path:$p, namespace:$ns}]' <<< "$cats")"
          locset="$locset $loc"
        done < <(find "$sub" -maxdepth 1 -type f \( -name '*.php' -o -name '*.json' \) 2>/dev/null | sort)
      done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
      # flat per-locale JSON files (Laravel lang/<locale>.json); namespace null
      local jf base
      while IFS= read -r jf; do
        [[ -n "$jf" ]] || continue
        base="$(basename "$jf" .json)"
        [[ "$base" =~ $LOCALE_RE ]] || continue
        cats="$(jq -c --arg r "$root" --arg l "$base" --arg m "$mech" --arg p "$root/$base.json" \
          '. + [{root:$r, locale:$l, format:"json", mechanism:$m, path:$p, namespace:null}]' <<< "$cats")"
        locset="$locset $base"
      done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort)
    done < <(jq -r ".stacks[$i].i18n.roots[]?" "$SIGNATURES")
  done
  if [[ "$cats" == "[]" ]]; then
    if [[ "$rootseen" -eq 1 ]]; then
      i18n_absent "i18n catalog directory present but no locale-named php/json catalog found (e.g. unsupported yml/po, or non-locale filenames)"
    else
      i18n_absent "no i18n catalog directory found"
    fi
    return 0
  fi
  cats="$(jq -c 'unique' <<< "$cats")"   # dedup when two rows share a root (e.g. next + react-router both declare "locales")
  local locs mechs evid
  locs="$(printf '%s\n' $locset | sort -u | grep -v '^$' | jq -R . | jq -sc .)"
  mechs="$(jq -c '[.[].mechanism] | unique' <<< "$cats")"
  evid="$(jq -c '[.[] | "code: " + .path] | unique' <<< "$cats")"
  jq -n --argjson cats "$cats" --argjson locs "$locs" --argjson libs "$libs" \
        --argjson mechs "$mechs" --argjson evid "$evid" \
    '{present:true, libraries:$libs, mechanisms:$mechs, catalogs:$cats, locales:$locs, signal:"strong", evidence:$evid}'
}
```

- [ ] **Step 6: Wire `detect_i18n` into the code-based emit path**

In `detect_code_component`, replace the `jq -n` emit block at lines 89-96:

```bash
    jq -n --argjson row "$(jq ".stacks[$i]" "$SIGNATURES")" \
          --arg repo "$repo" --arg fr "$fr" --arg ev "code: $mfile ($id)" '{
      role: $row.role, path: $repo, language: $row.language, languageVersion: "",
      framework: $row.id, frameworkVersion: "", packages: [],
      router: $row.router, frontend: { routing: $fr },
      orm: $row.orm, auth: $row.auth, commands: $row.commands,
      buildIdSource: "none", playbook: $row.playbook,
      signal: "strong", evidence: [$ev], drift: [] }'
```

with (compute the map first, pass it as `--argjson i18n`, add the `i18n:` field):

```bash
    local i18n_json; i18n_json="$(detect_i18n "$repo")"
    jq -n --argjson row "$(jq ".stacks[$i]" "$SIGNATURES")" \
          --arg repo "$repo" --arg fr "$fr" --arg ev "code: $mfile ($id)" \
          --argjson i18n "$i18n_json" '{
      role: $row.role, path: $repo, language: $row.language, languageVersion: "",
      framework: $row.id, frameworkVersion: "", packages: [],
      router: $row.router, frontend: { routing: $fr },
      orm: $row.orm, auth: $row.auth, commands: $row.commands,
      buildIdSource: "none", playbook: $row.playbook, i18n: $i18n,
      signal: "strong", evidence: [$ev], drift: [] }'
```

- [ ] **Step 7: Wire `i18n_absent` into the runtime and fallback emit paths**

In `detect_runtime_component`, replace the `jq -n` emit block at lines 126-133 with (a runtime-only component has no repo to scan → always absent):

```bash
    jq -n --argjson row "$(jq ".stacks[$i]" "$SIGNATURES")" \
          --arg ev "runtime: header/cookie match" \
          --argjson i18n "$(i18n_absent "runtime-only component — no repo scanned")" '{
      role: $row.role, path: null, language: $row.language, languageVersion: "",
      framework: $row.id, frameworkVersion: "", packages: [],
      router: $row.router, frontend: { routing: $row.frontendRouting },
      orm: $row.orm, auth: $row.auth, commands: $row.commands,
      buildIdSource: "none", playbook: $row.playbook, i18n: $i18n,
      signal: "weak", evidence: [$ev], drift: [] }'
```

Then, in `main()`, replace the fallback `jq -n` block at lines 169-174 with:

```bash
    fb="$(jq -n --argjson row "$(jq '._fallback' "$SIGNATURES")" \
              --argjson i18n "$(i18n_absent "no i18n catalog directory found")" '{
      role:$row.role, path:null, language:$row.language, languageVersion:"",
      framework:"generic", frameworkVersion:"", packages:[],
      router:$row.router, frontend:{routing:$row.frontendRouting},
      orm:$row.orm, auth:$row.auth, commands:$row.commands,
      buildIdSource:"none", playbook:$row.playbook, i18n:$i18n, signal:"weak", evidence:["fallback"], drift:[] }')"
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bash -n skills/detecting-stack-profile/scripts/detect-stack.sh && python3 -c "import json;json.load(open('skills/detecting-stack-profile/references/stack-signatures.json'))" && bash tests/detect-stack/run.sh`
Expected: `bash -n` and the JSON check exit 0; the runner prints every `ok - i18n …` line for Cases 6-8, Cases 1-5 remain `ok`, final line `PASS=<N> FAIL=0`, exit 0. In particular `i18n has php`/`i18n has json` are both `true`, `i18n file path` = `lang/ar/messages.php`, `i18n namespace` includes `messages`, and `config` is NOT a locale.

- [ ] **Step 9: Regenerate `dist/` and run the byte-oracle**

```bash
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh
bash tests/portability/run.sh
```
Expected: `validate-adapters.sh` exits 0 (all four adapters rebuild, the Claude byte-oracle matches, and the edited `detect-stack.sh` / `stack-signatures.json` pass their static checks); `tests/portability/run.sh` prints `FAIL=0`.

- [ ] **Step 10: Commit**

```bash
git add skills/detecting-stack-profile/scripts/detect-stack.sh \
        skills/detecting-stack-profile/references/stack-signatures.json \
        tests/detect-stack/run.sh tests/detect-stack/fixtures/laravel/lang dist
git commit -m "feat(stack-profile): data-driven i18n mechanism map (Laravel lang dirs + json), weak-degrade on no catalog"
```

---

### Task 2: JS catalogs + i18n libraries — added with ZERO engine change (proves the data-driven design)

Support JS per-locale JSON subdirectories (`locales/<lng>/<ns>.json`, the i18next/react-intl layout), the i18n **library** from `package.json`, and an app carrying BOTH Laravel and JS catalogs — **entirely by appending `i18n` blocks to `stack-signatures.json`**. No `detect-stack.sh` change: Task 1's `detect_i18n` already reads roots/libraries/mechanism from the rows and scans php+json. Add fixtures + assertions for `mechanism: js-catalog`, a library in `libraries[]`, a both-mechanism repo, and a negative-control (non-locale json → `present:false`).

**Files:**
- Modify: `skills/detecting-stack-profile/references/stack-signatures.json` — add an `i18n` key to the `nextjs` and `react-router` stack objects.
- Create: `tests/detect-stack/fixtures/react-intl/package.json`
- Create: `tests/detect-stack/fixtures/react-intl/locales/en/messages.json`
- Create: `tests/detect-stack/fixtures/react-intl/locales/ar/messages.json`
- Create: `tests/detect-stack/fixtures/fullstack/composer.json`  *(laravel/framework → matches laravel)*
- Create: `tests/detect-stack/fixtures/fullstack/package.json`   *(react-router-dom + react-intl)*
- Create: `tests/detect-stack/fixtures/fullstack/lang/ar/messages.php`
- Create: `tests/detect-stack/fixtures/fullstack/locales/ar/messages.json`
- Create: `tests/detect-stack/fixtures/nolocale/package.json`    *(react-router-dom)*
- Create: `tests/detect-stack/fixtures/nolocale/locales/config.json`  *(non-locale json only)*
- Test: `tests/detect-stack/run.sh` — append Cases 9-11 after Case 8, before the `echo "---"` summary.

**Interfaces:**
- Consumes: `.stacks[nextjs|react-router].i18n` (roots incl. `locales`; JS `libraryPackages`).
- Produces: `detect_i18n` — unchanged shape; `mechanisms` now includes `js-catalog` for JS repos and BOTH values for a fullstack repo; `libraries` carries the detected JS package(s). No new keys.

- [ ] **Step 1: Add the JS i18n signature blocks**

In `stack-signatures.json`, add `"i18n"` to `nextjs` and `react-router` (order matters only for the library list — check the more specific package before its core; `detect_i18n` records all that match, so order affects only readability):

`nextjs`:
```json
"i18n": { "roots": ["locales", "public/locales", "src/locales", "messages"], "libraryPackages": ["next-intl", "next-i18next", "react-i18next", "react-intl", "i18next"], "mechanism": "js-catalog" }
```
`react-router`:
```json
"i18n": { "roots": ["locales", "src/locales", "public/locales"], "libraryPackages": ["react-i18next", "react-intl", "@lingui/core", "i18next"], "mechanism": "js-catalog" }
```

- [ ] **Step 2: Create the fixtures**

`tests/detect-stack/fixtures/react-intl/package.json` (`react-router-dom` makes the code detector match `react-router`; `react-intl` is the i18n library — no package name contains the substring `next`, so `nextjs` does not falsely match):
```json
{
  "name": "web",
  "private": true,
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "react-router-dom": "^6.22.0",
    "react-intl": "^6.6.0"
  }
}
```
`tests/detect-stack/fixtures/react-intl/locales/en/messages.json`:
```json
{ "app.title": "Deliverables", "app.save": "Save" }
```
`tests/detect-stack/fixtures/react-intl/locales/ar/messages.json`:
```json
{ "app.title": "المخرجات", "app.save": "حفظ" }
```

Both-mechanism fixture (Laravel `lang/*.php` AND JS `locales/*.json` in one repo):
`tests/detect-stack/fixtures/fullstack/composer.json`:
```json
{ "name": "app", "require": { "laravel/framework": "^11.0" } }
```
`tests/detect-stack/fixtures/fullstack/package.json`:
```json
{ "name": "app-web", "private": true, "dependencies": { "react-router-dom": "^6.22.0", "react-intl": "^6.6.0" } }
```
`tests/detect-stack/fixtures/fullstack/lang/ar/messages.php`:
```php
<?php

return [ 'title' => 'المخرجات' ];
```
`tests/detect-stack/fixtures/fullstack/locales/ar/messages.json`:
```json
{ "app.title": "المخرجات" }
```

Negative-control fixture (a JS repo whose only file under a scanned root is a non-locale json):
`tests/detect-stack/fixtures/nolocale/package.json`:
```json
{ "name": "web", "private": true, "dependencies": { "react-router-dom": "^6.22.0" } }
```
`tests/detect-stack/fixtures/nolocale/locales/config.json`:
```json
{ "featureFlags": true }
```

- [ ] **Step 3: Write the failing tests**

In `tests/detect-stack/run.sh`, insert immediately **after** the Case 8 block and **before** the `echo "---"` summary line:

```bash
# Case 9: JS i18n catalog — per-locale JSON subdirs + library read from package.json
OUT9="$(mktemp)"
QA_REPOS="$FIX/react-intl" bash "$ENGINE" --no-runtime --out "$OUT9" >/dev/null 2>&1
check "js i18n present"   "$(get "$OUT9" '.components[0].i18n.present')"                                     "true"
check "js i18n mechanism" "$(get "$OUT9" '.components[0].i18n.mechanisms | index("js-catalog") != null')"   "true"
check "js i18n library"   "$(get "$OUT9" '.components[0].i18n.libraries | index("react-intl") != null')"    "true"
check "js i18n signal"    "$(get "$OUT9" '.components[0].i18n.signal')"                                      "strong"
check "js i18n locale ar" "$(get "$OUT9" '.components[0].i18n.locales | index("ar") != null')"              "true"
check "js i18n json fmt"  "$(get "$OUT9" '[.components[0].i18n.catalogs[].format] | index("json") != null')" "true"
check "js i18n ns"        "$(get "$OUT9" '[.components[0].i18n.catalogs[].namespace] | index("messages") != null')" "true"

# Case 10: fullstack repo (Laravel php + JS json) → BOTH mechanisms, JS library present
OUT10="$(mktemp)"
QA_REPOS="$FIX/fullstack" bash "$ENGINE" --no-runtime --out "$OUT10" >/dev/null 2>&1
check "both mech laravel"  "$(get "$OUT10" '.components[0].i18n.mechanisms | index("laravel-lang") != null')" "true"
check "both mech js"       "$(get "$OUT10" '.components[0].i18n.mechanisms | index("js-catalog") != null')"   "true"
check "both lib react-intl" "$(get "$OUT10" '.components[0].i18n.libraries | index("react-intl") != null')"   "true"

# Case 11: negative control — non-locale json under a scanned root → present:false, "directory present" reason
OUT11="$(mktemp)"
QA_REPOS="$FIX/nolocale" bash "$ENGINE" --no-runtime --out "$OUT11" >/dev/null 2>&1
check "negctrl present"  "$(get "$OUT11" '.components[0].i18n.present')"                                        "false"
check "negctrl reason"   "$(get "$OUT11" '.components[0].i18n.evidence | join(" ") | contains("directory present")')" "true"
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bash tests/detect-stack/run.sh`
Expected: Cases 9-11 FAIL — with no `nextjs`/`react-router` `i18n` block yet, `detect_i18n` finds no matching stack for these repos, so `.components[0].i18n.present` is `false` for Case 9/10 and the `mechanisms`/`libraries` filters are empty. (Case 11 may already pass by accident once the block is added, but must fail-then-pass alongside 9/10.) Cases 1-8 still `ok`.

- [ ] **Step 5: (already done in Step 1) — confirm NO script change is needed**

Re-run: `bash tests/detect-stack/run.sh`
Expected: after the Step-1 signature additions alone, Cases 9-11 turn `ok` with **no edit to `detect-stack.sh`** — the payoff of the data-driven design (Q3): a new stack's i18n convention is data, not code. `js i18n mechanism` includes `js-catalog`, `js i18n library` includes `react-intl`; the fullstack repo reports both `laravel-lang` and `js-catalog` (component[0] is `laravel` — first match — but its i18n unions the JS catalog from the co-located `package.json`); the negative control is `present:false` with the "directory present" reason. **Case 6 still passes** (Laravel php dirs resolve `format:"php"`, `mechanisms` still includes `laravel-lang`). Final line `PASS=<N> FAIL=0`.

- [ ] **Step 6: Regenerate `dist/` + byte-oracle, then commit**

```bash
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh && bash tests/portability/run.sh
git add skills/detecting-stack-profile/references/stack-signatures.json \
        tests/detect-stack/run.sh \
        tests/detect-stack/fixtures/react-intl tests/detect-stack/fixtures/fullstack tests/detect-stack/fixtures/nolocale \
        dist
git commit -m "feat(stack-profile): JS i18n catalogs + libraries via signatures data (no engine change); both-mechanism + negative-control"
```

---

### Task 3: Document the i18n map in the skill AND the schema spec

Record the new `i18n` field where the profile's schema and handoffs are documented: a `SKILL.md` validation-checklist item, a handoff line, a mini-eval, **and** the component-object schema block in the stack-auto-detection design spec (the schema of record that `detect-stack.sh` line 3 points at). Documentation only — no script change.

**Files:**
- Modify: `skills/detecting-stack-profile/SKILL.md` — add one checklist bullet in "Step 2" (after line 71), one handoff bullet in "Step 3" (after line 78), and mini-eval #5 (after line 124).
- Modify: `docs/superpowers/specs/2026-06-06-stack-auto-detection-design.md` — add the `i18n` object to the component-object JSON block (the schema example around lines 151-176, alongside `buildIdSource`/`playbook`/`drift`).

**Interfaces:**
- Consumes / Produces: none (prose + schema example). `SKILL.md` body must stay **< 500 lines** (CLAUDE.md); it is ~130 lines, so the additions are safe.

- [ ] **Step 1: Add the validation checklist item**

In `SKILL.md`, in "Step 2 — Validate the profile", insert after the `primary.backend / primary.frontend …` bullet (after line 71):

```markdown
- [ ] Each `components[].i18n` map locates where translations live: `mechanisms[]`
      (`laravel-lang` | `js-catalog` | `rails-yml` | `gettext-po` | `none`; an array
      because a fullstack repo can carry more than one), `catalogs[]` (each
      `{locale, format: php|json, mechanism, path, namespace}` — `path` points at the
      actual file so keys are resolvable), `locales[]`, and `libraries[]`.
      `present: false` with `signal: weak` means no catalog was found — the `evidence`
      distinguishes "no catalog directory found" from "directory present but no
      supported php/json catalog" (Rails yml / Django po). The map only **locates**
      the catalog (a key-*presence* oracle for a later phase); it never judges whether
      a value is correctly translated. A `weak` i18n signal degrades a dependent
      localization criterion's verdict `confidence` to `low` (never the reverse).
```

- [ ] **Step 2: Add the handoff line to the consumer phase**

In "Step 3 — Hand the profile to later phases", insert after the `writing-qa-reports …` bullet (after line 78):

```markdown
- **detecting-visual-ux** (localization family) reads each `components[].i18n`
  map to resolve a rendered string → key → catalog entry (opening the file at
  `catalogs[].path`). The map locates the catalog; the localization
  **adjudication** (deliberate-vs-bug) is a separate, later step, out of scope
  for detection.
```

- [ ] **Step 3: Add mini-eval #5**

Append after existing item 4 in "Mini-Evals (given → catch)" (after line 124):

```markdown

5. **i18n catalog located for key resolution.** *Given* a Laravel+React app with
   `lang/ar/messages.php` + `lang/en.json` AND a JS `locales/ar/messages.json`.
   *Catch* the profile emits `i18n.mechanisms: [laravel-lang, js-catalog]` with
   per-file `catalogs[].path`/`namespace` and `locales: [ar, en]`, and
   `libraries` includes `react-intl` — so the localization family can resolve a
   rendered `deliverables.title` → the `ar` catalog file and flag a **missing**
   key (presence oracle) — degrading instead to `i18n.signal: weak` with an
   honest "no catalog directory found" reason when a black-box target ships no
   catalog, never failing the Run.
```

- [ ] **Step 4: Add the `i18n` object to the schema spec**

In `docs/superpowers/specs/2026-06-06-stack-auto-detection-design.md`, in the component-object JSON block (the schema example listing `buildIdSource`, `playbook`, `drift`), add the `i18n` object so the schema of record matches the emitter:

```json
"i18n": {
  "present": true,
  "libraries": ["react-intl"],
  "mechanisms": ["laravel-lang", "js-catalog"],
  "catalogs": [
    { "root": "lang", "locale": "ar", "format": "php", "mechanism": "laravel-lang", "path": "lang/ar/messages.php", "namespace": "messages" }
  ],
  "locales": ["ar", "en"],
  "signal": "strong",
  "evidence": ["code: lang/ar/messages.php"]
}
```
(For an absent map: `present:false`, `libraries:[]`, `mechanisms:[]`, `catalogs:[]`, `locales:[]`, `signal:"weak"`, `evidence:["no i18n catalog directory found"]`.)

- [ ] **Step 5: Validate body length, regenerate `dist/`, commit**

```bash
awk 'END{print NR}' skills/detecting-stack-profile/SKILL.md    # expect well under 500 (~150)
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh
git add skills/detecting-stack-profile/SKILL.md docs/superpowers/specs/2026-06-06-stack-auto-detection-design.md
git commit -m "docs(stack-profile): document the i18n mechanism map field, its consumer, and the schema"
```

---

## Self-Review

**1. Spec coverage** (spec §4 family 2 + §2):
- "i18n mechanism map (Laravel `lang/{ar,en}` + JSON, and/or JS/Inertia catalog)" → Task 1 (Laravel `lang/<locale>/*.php` + `lang/<locale>.json`, data-driven) + Task 2 (JS `locales/<lng>/<ns>.json`, added as signatures data). ✅
- "degrade to `signal: weak` (advisory) when no catalog found" → Task 1 Cases 7-8 + Task 2 Case 11 assert `present:false`/`signal:weak`; `i18n_absent` wired into all three emit paths, with two distinct honest reasons. ✅
- "catalog is a definite oracle for key PRESENCE only … the map just locates, it does not judge" → Global Constraint + documented in Task 3; `catalogs[].path`/`namespace` point at the real files so the presence oracle is actually resolvable. ✅
- Matches existing `stack-profile.json` schema/style: additive per-component `i18n` key alongside `signal`; helpers reuse the `jq -n --argjson …` idiom and the `have jq` guards; the schema-of-record spec is updated in Task 3 (no silent drift). ✅
- CONTEXT.md Signal one-way mapping respected (constraint + checklist bullet). ✅

**2. Grill fixes applied:**
- **Q1 (portability):** every Task regenerates `dist/` (`build-adapter.sh` ×4) and runs the byte-oracle (`validate-adapters.sh`) + `tests/portability/run.sh` as a CI-parity gate (`dist/` git-ignored, never committed); added to the Global validate list. ✅
- **Q2 (schema doc):** Task 3 Step 4 adds the `i18n` object to `2026-06-06-stack-auto-detection-design.md`. ✅
- **Q3 (data-drive):** roots/libraryPackages/mechanism live in `stack-signatures.json` (`.stacks[].i18n` + `._fallback.i18n`); `detect_i18n` reads them; Task 2 adds JS support with **zero** engine change. ✅
- **Q4 (locale gate):** `LOCALE_RE` gates both the dir and flat-json branches; Task 1 asserts `config` is not a locale; Task 2 Case 11 is the `present:false` negative control. ✅
- **Q5 (mechanism/library):** `mechanisms[]` (per-catalog `mechanism` unioned) + `libraries[]`; `detect_i18n` unions every signature present in the repo (manifest **and** package match) and scans each manifest; Task 2 Case 10 is the both-mechanism fixture. ✅
- **Q6 (path/namespace):** dir catalogs emit one entry per file with `path` = real file and `namespace` = file stem; flat json `path` = the file, `namespace` null; asserted in Cases 6 and 9. ✅
- **Q7 (degrade reason):** two distinct `i18n_absent` reasons; the `rootseen` branch fires for Rails yml / Django po / non-locale json; asserted in Case 11. ✅

**3. Placeholder scan:** none — every step shows exact fixture contents, exact old→new script text, exact signature JSON, exact assertions, and exact commands + expected output.

**4. Type consistency:** `i18n_absent(reason)`, `manifest_path(repo, manifest)`, and `detect_i18n(repo)` are called identically everywhere; emitted keys (`present, libraries, mechanisms, catalogs, locales, signal, evidence`) and catalog sub-keys (`root, locale, format, mechanism, path, namespace`) are identical across `i18n_absent`, `detect_i18n`, every `get` assertion, and the Task-3 schema block. `mechanisms`/`libraries` are arrays in all sites; `--argjson i18n` / `i18n:` matches across all three emit paths. The package-match gate mirrors `detect_code_component`, so a bare `package.json` cannot fire unrelated JS stacks' i18n rows.
