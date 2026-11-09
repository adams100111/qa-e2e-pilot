#!/usr/bin/env bash
# Tests for skills/taking-surface-census/scripts/{crawl-safety,form-inventory}.js —
# the census crawl's click-safety classifier and its read-only form inventory.
#
# Both scripts are dual-mode: injected in-page via `browser_evaluate` they walk the
# real DOM; required under plain Node they export pure, DOM-free cores. These tests
# feed plain-object element/form DESCRIPTORS (no jsdom, no npm dependency) to the
# pure cores, plus one stub-DOM smoke test per script that drives the in-page walk.
#
# Pinned (plan 2026-11-09 ship-qa increment 1, Task 7):
#   - Arabic destructive labels are unsafe, including an icon button whose ONLY
#     name is an `aria-label` (Review Focus #1).
#   - English destructive labels are unsafe; `type=submit` is unsafe; any element
#     inside a non-GET form is unsafe.
#   - Tabs and "View details" style openers are safe.
#   - Unsafe wins when both an unsafe and a safe pattern match ("View and delete").
#   - Anything not on the allowlist is NOT safe (default deny).
#   - form-inventory reads required/maxLength/min/max/pattern constraints.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SAFETY="$ROOT/skills/taking-surface-census/scripts/crawl-safety.js"
INVENTORY="$ROOT/skills/taking-surface-census/scripts/form-inventory.js"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

OPTS='{"origin":"https://app.example.sa","denyPatterns":["/admin/exports"]}'

# cls <descriptorJson> <key> [optsJson] -> classify(desc, opts)[key]
cls() {
  node -e 'const m=require(process.argv[1]);const r=m.classify(JSON.parse(process.argv[2]),JSON.parse(process.argv[3]));process.stdout.write(String(r[process.argv[4]]));' \
    "$SAFETY" "$1" "${3:-$OPTS}" "$2" 2>&1
}
# inv <formDescriptorJson> <jsExpressionOverResult r>
inv() {
  node -e 'const m=require(process.argv[1]);const r=m.inventoryForm(JSON.parse(process.argv[2]));process.stdout.write(String(eval(process.argv[3])));' \
    "$INVENTORY" "$1" "$2" 2>&1
}

# --- modules load under plain node ------------------------------------------------
check "crawl-safety requires under node (no document)" \
  "$(node -e 'const m=require(process.argv[1]);process.stdout.write(typeof m.classify)' "$SAFETY" 2>&1)" "function"
check "form-inventory requires under node (no document)" \
  "$(node -e 'const m=require(process.argv[1]);process.stdout.write(typeof m.inventoryForm)' "$INVENTORY" 2>&1)" "function"

# --- arabic_delete_unsafe ---------------------------------------------------------
check "arabic_delete_unsafe: visible text 'حذف الفريق'" \
  "$(cls '{"tag":"button","type":"button","text":"حذف الفريق","selector":"#del"}' safe)" "false"
check "arabic_delete_unsafe: aria-label-only icon button" \
  "$(cls '{"tag":"button","type":"button","text":"","ariaLabel":"حذف","selector":"#icon-del"}' safe)" "false"
check "arabic_delete_unsafe: aria-label-only icon reason names the unsafe term" \
  "$(cls '{"tag":"button","type":"button","text":"","ariaLabel":"حذف","selector":"#icon-del"}' reason)" "unsafe-name"
check "arabic_delete_unsafe: label comes from aria-label" \
  "$(cls '{"tag":"button","type":"button","text":"","ariaLabel":"حذف","selector":"#icon-del"}' label)" "حذف"
check "arabic approve icon (اعتماد) via aria-label is unsafe" \
  "$(cls '{"tag":"button","type":"button","text":"","ariaLabel":"اعتماد الفكرة"}' safe)" "false"
check "arabic delete with tashkeel/tatweel still unsafe" \
  "$(cls '{"tag":"button","type":"button","text":"حَذْــف"}' safe)" "false"
check "arabic removal without hamza (ازالة) still unsafe" \
  "$(cls '{"tag":"button","type":"button","text":"ازالة العضو"}' safe)" "false"
check "arabic unsafe word hidden in title of a safe-named button is unsafe" \
  "$(cls '{"tag":"button","type":"button","text":"عرض","title":"حذف"}' safe)" "false"
check "arabic logout link is unsafe" \
  "$(cls '{"tag":"a","href":"/account","text":"تسجيل الخروج"}' safe)" "false"

# --- english_save_unsafe ----------------------------------------------------------
check "english_save_unsafe: 'Save changes' button" \
  "$(cls '{"tag":"button","type":"button","text":"Save changes"}' safe)" "false"
check "english_save_unsafe: reason" \
  "$(cls '{"tag":"button","type":"button","text":"Save changes"}' reason)" "unsafe-name"
check "english 'Sign out' link unsafe" \
  "$(cls '{"tag":"a","href":"/session","text":"Sign out"}' safe)" "false"

# --- tab_safe ---------------------------------------------------------------------
check "tab_safe: role=tab" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"Members"}' safe)" "true"
check "tab_safe: reason" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"Members"}' reason)" "tab"
check "arabic tab (الأعضاء) safe" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"الأعضاء"}' safe)" "true"

# --- view_details_safe ------------------------------------------------------------
check "view_details_safe: 'View details' button" \
  "$(cls '{"tag":"button","type":"button","text":"View details"}' safe)" "true"
check "view_details_safe: reason" \
  "$(cls '{"tag":"button","type":"button","text":"View details"}' reason)" "safe-name"
check "arabic 'عرض التفاصيل' button safe" \
  "$(cls '{"tag":"button","type":"button","text":"عرض التفاصيل"}' safe)" "true"
check "same-origin link safe" \
  "$(cls '{"tag":"a","href":"/hackathons/riyadh-water","text":"Riyadh water"}' safe)" "true"
check "aria-haspopup menu opener safe" \
  "$(cls '{"tag":"button","type":"button","ariaHaspopup":"menu","text":"Actions"}' safe)" "true"
check "summary disclosure safe" \
  "$(cls '{"tag":"summary","text":"Filters"}' safe)" "true"
check "binding regex is a substring match: 'Advanced' hits 'advance' -> unsafe" \
  "$(cls '{"tag":"button","type":"button","ariaExpanded":"false","text":"Advanced"}' safe)" "false"
check "aria-expanded disclosure safe" \
  "$(cls '{"tag":"button","type":"button","ariaExpanded":"false","text":"Options"}' safe)" "true"

# --- unsafe_wins_on_conflict ------------------------------------------------------
check "unsafe_wins_on_conflict: 'View and delete'" \
  "$(cls '{"tag":"button","type":"button","text":"View and delete"}' safe)" "false"
check "unsafe_wins_on_conflict: role=tab named 'Delete'" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"Delete"}' safe)" "false"
check "unsafe_wins_on_conflict: arabic 'عرض وحذف'" \
  "$(cls '{"tag":"button","type":"button","text":"عرض وحذف"}' safe)" "false"

# --- submit_in_post_form_unsafe ---------------------------------------------------
check "submit_in_post_form_unsafe: 'View' button inside POST form" \
  "$(cls '{"tag":"button","type":"button","text":"View","formMethod":"post"}' safe)" "false"
check "submit_in_post_form_unsafe: reason" \
  "$(cls '{"tag":"button","type":"button","text":"View","formMethod":"post"}' reason)" "inside-non-get-form"
check "type=submit unsafe even in a GET form" \
  "$(cls '{"tag":"button","type":"submit","text":"Show results","formMethod":"get"}' safe)" "false"
check "type=submit reason" \
  "$(cls '{"tag":"button","type":"submit","text":"Show results","formMethod":"get"}' reason)" "type-submit"
check "button with no type inside a form defaults to submit -> unsafe" \
  "$(cls '{"tag":"button","text":"Next","formMethod":"get"}' safe)" "false"
check "input type=submit unsafe" \
  "$(cls '{"tag":"input","type":"submit","value":"Open"}' safe)" "false"
check "type=button inside GET form with safe name stays safe" \
  "$(cls '{"tag":"button","type":"button","text":"Filter","formMethod":"get"}' safe)" "true"

# --- default deny and link guards -------------------------------------------------
check "unknown button name is not safe (default deny)" \
  "$(cls '{"tag":"button","type":"button","text":"Assign evaluators"}' safe)" "false"
check "default deny reason" \
  "$(cls '{"tag":"button","type":"button","text":"Assign evaluators"}' reason)" "not-allowlisted"
check "cross-origin link not safe" \
  "$(cls '{"tag":"a","href":"https://other.example.com/x","text":"Partner"}' reason)" "cross-origin"
check "download link not safe" \
  "$(cls '{"tag":"a","href":"/files/report.pdf","download":true,"text":"Report"}' reason)" "download"
check "crawlDenyPatterns link not safe" \
  "$(cls '{"tag":"a","href":"/admin/exports/42","text":"Exports"}' reason)" "deny-pattern"
check "link with data-method=post not safe" \
  "$(cls '{"tag":"a","href":"/teams/9","dataMethod":"post","text":"Team"}' safe)" "false"
check "link with data-confirm not safe" \
  "$(cls '{"tag":"a","href":"/teams/9","dataConfirm":"Sure?","text":"Team"}' safe)" "false"
check "link carrying _method= not safe" \
  "$(cls '{"tag":"a","href":"/teams/9?_method=DELETE","text":"Team"}' safe)" "false"
check "javascript: link not safe" \
  "$(cls '{"tag":"a","href":"javascript:void(0)","text":"Open"}' safe)" "false"
check "disabled element not safe" \
  "$(cls '{"tag":"button","type":"button","text":"Next","disabled":true}' reason)" "disabled"

# --- fix round 1 (security review) --------------------------------------------------
# C1: Arabic safe terms are anchored at the start of the name (optional leading ال).
check "C1: 'نقل إلى المرحلة التالية' is not safe" \
  "$(cls '{"tag":"button","type":"button","text":"نقل إلى المرحلة التالية"}' safe)" "false"
check "C1: 'فتح التسجيل' is not safe" \
  "$(cls '{"tag":"button","type":"button","text":"فتح التسجيل"}' safe)" "false"
check "C1: 'بدء العرض' is not safe" \
  "$(cls '{"tag":"button","type":"button","text":"بدء العرض"}' safe)" "false"
check "C1: 'بدء العرض' reason is not-allowlisted" \
  "$(cls '{"tag":"button","type":"button","text":"بدء العرض"}' reason)" "not-allowlisted"
check "C1: 'التفاصيل' (leading ال) still safe" \
  "$(cls '{"tag":"button","type":"button","text":"التفاصيل"}' safe)" "true"
check "C1: 'التالي' still safe" \
  "$(cls '{"tag":"button","type":"button","text":"التالي"}' safe)" "true"
# I1: only an explicit method/formmethod of get is GET; a form with no method is non-GET.
check "I1: 'Next' type=button inside a form with no method is unsafe" \
  "$(cls '{"tag":"button","type":"button","text":"Next","formMethod":""}' reason)" "inside-non-get-form"
check "I1: 'Edit' type=button inside a form with no method is unsafe" \
  "$(cls '{"tag":"button","type":"button","text":"Edit","formMethod":""}' safe)" "false"
check "I1: explicit GET still allows a safe-name button" \
  "$(cls '{"tag":"button","type":"button","text":"Edit","formMethod":"GET"}' safe)" "true"
# I2: safe-name disqualifiers -> not-allowlisted.
for name in "Open registration" "Show results" "Next stage" "Open voting" "View winners" "Edit phase"; do
  check "I2: '$name' button is not-allowlisted" \
    "$(cls "{\"tag\":\"button\",\"type\":\"button\",\"text\":\"$name\"}" reason)" "not-allowlisted"
done
check "I2: 'Open voting' role=menuitem is not-allowlisted" \
  "$(cls '{"tag":"div","role":"menuitem","text":"Open voting"}' reason)" "not-allowlisted"
check "I2: arabic 'عرض النتائج' is not-allowlisted" \
  "$(cls '{"tag":"button","type":"button","text":"عرض النتائج"}' reason)" "not-allowlisted"
check "I2: arabic 'فتح المرحلة' is not-allowlisted" \
  "$(cls '{"tag":"button","type":"button","text":"فتح المرحلة"}' reason)" "not-allowlisted"
check "I2: plain 'Open' still safe" \
  "$(cls '{"tag":"button","type":"button","text":"Open"}' safe)" "true"
# I3: unsafe verbs in the href path.
for h in "/invitations/abc/accept" "/notifications/5/mark-read" "/notifications/5/markread" "/teams/9/leave" "/teams/9/join" "/users/4/impersonate" "/email/verify/abc" "/ideas/3/approve" "/settings/toggle-dark" "/newsletter/unsubscribe" "/log-out" "/signout"; do
  check "I3: link to $h is unsafe-href" \
    "$(cls "{\"tag\":\"a\",\"href\":\"$h\",\"text\":\"Item\"}" reason)" "unsafe-href"
done
# M3: spaced log out / sign out in names.
check "M3: 'Log out' link is unsafe" \
  "$(cls '{"tag":"a","href":"/account","text":"Log out"}' safe)" "false"
check "M3: 'Sign - out' button is unsafe-name" \
  "$(cls '{"tag":"button","type":"button","text":"Sign - out"}' reason)" "unsafe-name"
# M4: ى→ي and ة→ه folded on both sides.
check "M4: 'موافقه' (ه written for ة) is still unsafe-name" \
  "$(cls '{"tag":"button","type":"button","text":"موافقه"}' reason)" "unsafe-name"
check "M4: normalizeText folds ى->ي and ة->ه" \
  "$(node -e 'const m=require(process.argv[1]);process.stdout.write(m.normalizeText("مستوى القائمة"))' "$SAFETY" 2>&1)" "مستوي القائمه"
check "M4: 'القائمه' (ه for ة) still matches the safe term" \
  "$(cls '{"tag":"button","type":"button","text":"القائمه"}' safe)" "true"
# Status-tab exception: tabs and links only, whole-name past-tense status with optional count.
check "status: 'Accepted (3)' tab is safe" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"Accepted (3)"}' safe)" "true"
check "status: 'Archived' link is safe" \
  "$(cls '{"tag":"a","href":"/ideas?status=archived","text":"Archived"}' safe)" "true"
check "status: arabic 'المقبولة' tab is safe" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"المقبولة"}' safe)" "true"
check "status: arabic 'مرفوض 4' tab is safe" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"مرفوض 4"}' safe)" "true"
check "status: 'Accepted' button is NOT exempt" \
  "$(cls '{"tag":"button","type":"button","text":"Accepted"}' safe)" "false"
check "status: 'Accept all' tab is NOT exempt (not a whole status word)" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"Accept all"}' safe)" "false"
check "status: 'Edit and resubmit' button is unsafe" \
  "$(cls '{"tag":"button","type":"button","text":"Edit and resubmit"}' safe)" "false"
check "status: 'Advanced' disclosure stays unsafe" \
  "$(cls '{"tag":"button","type":"button","ariaExpanded":"false","text":"Advanced"}' safe)" "false"
check "status: exempt tab with a destructive title is still unsafe" \
  "$(cls '{"tag":"button","type":"button","role":"tab","text":"Archived","title":"Delete all"}' safe)" "false"
# I5: selector must be unique on the page, else ambiguous-selector.
dup_smoke() {
  node -e '
    const path=process.argv[1];
    const m=require(path);
    function el(tag, attrs, text){
      return {tagName:tag.toUpperCase(), nodeType:1, textContent:text||"", innerText:text||"",
        getAttribute:function(n){return Object.prototype.hasOwnProperty.call(attrs,n)?attrs[n]:null;},
        hasAttribute:function(n){return Object.prototype.hasOwnProperty.call(attrs,n);},
        closest:function(){return null;}, form:null,
        getBoundingClientRect:function(){return {width:40,height:20};},
        parentNode:null, children:[], id:attrs.id||""};
    }
    const els=[el("a",{href:"/a",id:"dup"},"Ideas"), el("a",{href:"/b",id:"dup"},"Teams"), el("a",{href:"/c",id:"one"},"Events")];
    global.window={location:{origin:"https://app.example.sa"}};
    global.getComputedStyle=function(){return {display:"block",visibility:"visible",opacity:"1"};};
    global.document={querySelectorAll:function(sel){
        if(sel.charAt(0)==="#"){return els.filter(function(e){return "#"+e.id===sel;});}
        return els;},getElementById:function(){return null;},documentElement:{}};
    const r=m.SCAN({});
    process.stdout.write(r.map(function(x){return "["+x.selector+"]:"+x.safe+":"+x.reason;}).join(","));
  ' "$SAFETY" 2>&1
}
check "I5: duplicate selectors are ambiguous-selector with no selector; unique one stays safe" \
  "$(dup_smoke)" "[]:false:ambiguous-selector,[]:false:ambiguous-selector,[#one]:true:same-origin-link"

# --- fix round 2: object allowlisting for safe verbs ----------------------------------
# A safe verb is safe-name ONLY when the name is the bare verb (+ optional count/chevron), the
# next word is a detail object (details, more, menu, …), or the verb is edit/تعديل.
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  check "R2: '$name' button is not-allowlisted" \
    "$(cls "{\"tag\":\"button\",\"type\":\"button\",\"text\":\"$name\"}" reason)" "not-allowlisted"
done <<'LABELS'
فتح التصويت
فتح باب التصويت
فتح الترشح
فتح التقييم
فتح الجولة
فتح المسابقة
فتح الهاكاثون
فتح القفل
عرض الفائزين
عرض الجوائز
Open challenge
Open evaluation
Open submissions
Open applications
Open nominations
Open round
Open hackathon
View awards
Show prizes
Next round
LABELS
check "R2: 'Open hackathon' role=menuitem is not-allowlisted" \
  "$(cls '{"tag":"div","role":"menuitem","text":"Open hackathon"}' reason)" "not-allowlisted"
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  check "R2: '$name' button is safe-name" \
    "$(cls "{\"tag\":\"button\",\"type\":\"button\",\"text\":\"$name\"}" reason)" "safe-name"
done <<'LABELS'
View details
Open menu
Show more
عرض التفاصيل
فتح القائمة
Edit team
Next
Next step
التالي
Next ›
More (12)
عرض الكل
Previous page
Open
LABELS

# --- stub-DOM smoke: the in-page walk returns the documented shape ---------------
scan_smoke() {
  node -e '
    const path=process.argv[1];
    const m=require(path);
    function el(tag, attrs, text, form){
      return {tagName:tag.toUpperCase(), nodeType:1, textContent:text||"", innerText:text||"",
        getAttribute:function(n){return Object.prototype.hasOwnProperty.call(attrs,n)?attrs[n]:null;},
        hasAttribute:function(n){return Object.prototype.hasOwnProperty.call(attrs,n);},
        closest:function(){return form||null;}, form:form||null,
        getBoundingClientRect:function(){return {width:40,height:20};},
        parentNode:null, children:[], id:attrs.id||""};
    }
    const post={tagName:"FORM", getAttribute:function(n){return n==="method"?"post":null;}};
    const els=[el("a",{href:"/ideas",id:"l1"},"Ideas"), el("button",{type:"button","aria-label":"حذف",id:"b1"},""),
               el("button",{type:"button",id:"b2"},"View",post)];
    global.window={location:{origin:"https://app.example.sa",href:"https://app.example.sa/h"},getComputedStyle:function(){return {display:"block",visibility:"visible",opacity:"1"};}};
    global.getComputedStyle=global.window.getComputedStyle;
    global.document={querySelectorAll:function(sel){
        if(sel.charAt(0)==="#"){return els.filter(function(e){return "#"+e.id===sel;});}
        return els;},getElementById:function(){return null;},documentElement:{}};
    const r=m.SCAN({});
    process.stdout.write(r.map(function(x){return x.selector+":"+x.safe+":"+x.reason;}).join(","));
  ' "$SAFETY" 2>&1
}
check "SCAN() walks a stub DOM: link safe, aria-label delete unsafe, POST-form button unsafe" \
  "$(scan_smoke)" "#l1:true:same-origin-link,#b1:false:unsafe-name,#b2:false:inside-non-get-form"

# --- form_inventory_reads_constraints ---------------------------------------------
FORM='{"id":"idea-form","action":"/ideas","method":"post","fields":[
  {"tag":"input","name":"title","type":"text","required":true,"maxLength":"120"},
  {"tag":"input","name":"budget","type":"number","min":"0","max":"500000"},
  {"tag":"input","name":"phone","type":"tel","pattern":"05[0-9]{8}","ariaRequired":"true"},
  {"tag":"input","name":"starts_at","type":"date","min":"2026-11-10"},
  {"tag":"textarea","name":"summary","maxLength":"2000"},
  {"tag":"select","name":"city"},
  {"tag":"input","name":"_token","type":"hidden"},
  {"tag":"input","type":"submit","name":"go"}]}'
check "form_inventory_reads_constraints: formId" "$(inv "$FORM" 'r.formId')" "idea-form"
check "form_inventory_reads_constraints: method upper-cased" "$(inv "$FORM" 'r.method')" "POST"
check "form_inventory_reads_constraints: action" "$(inv "$FORM" 'r.action')" "/ideas"
check "form_inventory_reads_constraints: hidden + submit excluded" "$(inv "$FORM" 'r.fields.map(f=>f.name).join("|")')" "title|budget|phone|starts_at|summary|city"
check "form_inventory_reads_constraints: required" "$(inv "$FORM" 'r.fields[0].required')" "true"
check "form_inventory_reads_constraints: maxLength numeric" "$(inv "$FORM" 'typeof r.fields[0].maxLength+":"+r.fields[0].maxLength')" "number:120"
check "form_inventory_reads_constraints: number min/max numeric" "$(inv "$FORM" 'typeof r.fields[1].min+":"+r.fields[1].min+":"+r.fields[1].max')" "number:0:500000"
check "form_inventory_reads_constraints: aria-required counts" "$(inv "$FORM" 'r.fields[2].required')" "true"
check "form_inventory_reads_constraints: pattern" "$(inv "$FORM" 'r.fields[2].pattern')" "05[0-9]{8}"
check "form_inventory_reads_constraints: date min kept as string" "$(inv "$FORM" 'r.fields[3].min')" "2026-11-10"
check "form_inventory_reads_constraints: absent constraint is null" "$(inv "$FORM" 'r.fields[0].min===null&&r.fields[0].pattern===null')" "true"
check "form_inventory_reads_constraints: textarea type" "$(inv "$FORM" 'r.fields[4].type+":"+r.fields[4].maxLength')" "textarea:2000"
check "form_inventory_reads_constraints: select type" "$(inv "$FORM" 'r.fields[5].type')" "select"
check "form_inventory_reads_constraints: field keys exact" "$(inv "$FORM" 'Object.keys(r.fields[0]).join(",")')" "name,type,required,maxLength,min,max,pattern"
check "form without method defaults to GET" "$(inv '{"id":"search","fields":[]}' 'r.method')" "GET"

inv_smoke() {
  node -e '
    const path=process.argv[1];
    const m=require(path);
    function ctl(tag, attrs){
      return {tagName:tag.toUpperCase(), type:attrs.type||(tag==="select"?"select-one":tag==="textarea"?"textarea":"text"),
        getAttribute:function(n){return Object.prototype.hasOwnProperty.call(attrs,n)?attrs[n]:null;},
        hasAttribute:function(n){return Object.prototype.hasOwnProperty.call(attrs,n);}, form:null, closest:function(){return null;}};
    }
    const f={tagName:"FORM", id:"team-form",
      getAttribute:function(n){return {method:"post",action:"/teams",id:"team-form"}[n]||null;},
      querySelectorAll:function(){return [ctl("input",{name:"name",required:"",maxlength:"60"}), ctl("input",{name:"size",type:"number",min:"1",max:"5"})];}};
    const orphan=ctl("input",{name:"q",type:"search"});
    global.window={location:{href:"https://app.example.sa/teams",pathname:"/teams"}};
    global.document={querySelectorAll:function(sel){return sel==="form"?[f]:[orphan];}};
    const r=m.INVENTORY();
    process.stdout.write(r.map(function(x){return x.formId+":"+x.method+":"+x.fields.map(function(y){return y.name+"/"+y.maxLength+"/"+y.max;}).join(";");}).join(","));
  ' "$INVENTORY" 2>&1
}
check "INVENTORY() walks a stub DOM incl. fields outside any form" \
  "$(inv_smoke)" "team-form:POST:name/60/null;size/null/5,page:null:q/null/null"

# --- route_match_from_inertia_and_next ---------------------------------------------
# census.sh maps adapter `page:*` surfaces only through a visit's routeMatch = "page:<component>".
pc() {
  node -e 'const m=require(process.argv[1]);const a=process.argv[2]==="null"?null:process.argv[2];const b=process.argv[3]==="null"?null:process.argv[3];const r=m.pageComponent(a,b);process.stdout.write(r===null?"null":r);' \
    "$SAFETY" "$1" "$2" 2>&1
}
check "route_match_from_inertia_and_next: Inertia data-page .component" \
  "$(pc '{"component":"Admin/Hackathons/Show","props":{},"url":"/admin/hackathons/7"}' null)" "Admin/Hackathons/Show"
check "route_match_from_inertia_and_next: Next.js __NEXT_DATA__ .page" \
  "$(pc null '{"page":"/hackathons/[slug]","query":{"slug":"riyadh-water"}}')" "/hackathons/[slug]"
check "route_match_from_inertia_and_next: Inertia wins when both present" \
  "$(pc '{"component":"Ideas/Index"}' '{"page":"/ideas"}')" "Ideas/Index"
check "route_match_from_inertia_and_next: neither present -> null (routeMatch omitted)" "$(pc null null)" "null"
check "route_match_from_inertia_and_next: malformed JSON -> null" "$(pc '{not json' null)" "null"
check "route_match_from_inertia_and_next: empty component -> falls through to Next" \
  "$(pc '{"component":""}' '{"page":"/ideas"}')" "/ideas"
check "route_match_from_inertia_and_next: routeMatch helper prefixes page:" \
  "$(node -e 'const m=require(process.argv[1]);process.stdout.write(String(m.routeMatchFor("{\"component\":\"Teams/Show\"}",null)))' "$SAFETY" 2>&1)" "page:Teams/Show"
check "route_match_from_inertia_and_next: routeMatch helper null when unknown" \
  "$(node -e 'const m=require(process.argv[1]);process.stdout.write(String(m.routeMatchFor(null,null)))' "$SAFETY" 2>&1)" "null"
page_smoke() {
  node -e '
    const fs=require("fs"),vm=require("vm");
    const src=fs.readFileSync(process.argv[1],"utf8");
    const app={getAttribute:function(n){return n==="data-page"?JSON.stringify({component:"Admin/Teams/Index"}):null;}};
    const ctx={URL:URL,window:{location:{origin:"https://app.example.sa",pathname:"/"}},
      document:{querySelectorAll:function(){return [];},getElementById:function(id){return id==="app"?app:null;},
        querySelector:function(){return null;},documentElement:{}}};
    vm.runInNewContext(src,ctx);
    process.stdout.write(String(ctx.window.__qaRouteMatch));
  ' "$SAFETY" 2>&1
}
check "route_match_from_inertia_and_next: in-page run publishes window.__qaRouteMatch" "$(page_smoke)" "page:Admin/Teams/Index"

# --- injected as a browser_evaluate body, each script's completion value is its array ---
completion() {
  node -e '
    const fs=require("fs"),vm=require("vm");
    const src=fs.readFileSync(process.argv[1],"utf8");
    const ctx={URL:URL,window:{location:{origin:"https://app.example.sa",pathname:"/"}},
      document:{querySelectorAll:function(){return [];},getElementById:function(){return null;},documentElement:{}}};
    const r=vm.runInNewContext(src,ctx);
    process.stdout.write(Array.isArray(r)?"array":"NOT-ARRAY");
  ' "$1" 2>&1
}
check "crawl-safety.js source evaluates to an array in a page context" "$(completion "$SAFETY")" "array"
check "form-inventory.js source evaluates to an array in a page context" "$(completion "$INVENTORY")" "array"

echo
echo "crawl-safety tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
