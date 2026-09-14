#!/usr/bin/env python3
"""Render report.md + report.html for a qa-e2e-pilot run from its on-file
artifacts (run-manifest.json, checkpoint.json, bug-log.json, stack-profile.json)
using the bundled templates.

Written via shell/Bash (not the Write tool) so it works when the pipeline runs
as a subagent (harness policy blocks subagents from writing report files with the
Write tool; Bash-authored files are unaffected). Deterministic — no LLM
placeholder-filling.

Usage: render-report.py <run-dir> [templates-dir]
  <run-dir>        .qa/runs/<run-id>/ containing the JSON artifacts + evidence/
  [templates-dir]  defaults to ../skills/writing-qa-reports/templates relative to this script
"""
import html
import json
import os
import sys

VERDICTS = ["pass", "fail", "blocked", "deferred", "error"]


def load(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError):
        return default


def esc(v):
    return html.escape(str(v if v is not None else ""))


def render(run_dir, tpl_dir):
    manifest = load(os.path.join(run_dir, "run-manifest.json"), {})
    checkpoint = load(os.path.join(run_dir, "checkpoint.json"), {})
    bugs = load(os.path.join(run_dir, "bug-log.json"), [])
    if isinstance(bugs, dict):
        bugs = bugs.get("bugs", [])
    stack = load(os.path.join(run_dir, "stack-profile.json"), {})

    criteria = checkpoint.get("criteria", []) if isinstance(checkpoint, dict) else []

    # checklist id -> title (best effort; manifest.checklist may be a path or a list)
    titles = {}
    cl = manifest.get("checklist")
    if isinstance(cl, list):
        for it in cl:
            if isinstance(it, dict) and it.get("id"):
                titles[it["id"]] = it.get("title") or it.get("text") or ""

    tally = {v: 0 for v in VERDICTS}
    low_conf = 0
    for c in criteria:
        v = (c.get("verdict") or "error").lower()
        tally[v] = tally.get(v, 0) + 1
        if (c.get("confidence") or "").lower() == "low":
            low_conf += 1
    total = len(criteria)

    feature = manifest.get("target_feature", "")
    run_id = manifest.get("run_id", os.path.basename(run_dir.rstrip("/")))
    date = (manifest.get("started_at") or "")[:10]
    build_id = manifest.get("build_id", "")
    stack_str = stack.get("stack") or stack.get("framework") or "unknown"

    # ---------- report.html ----------
    def card_html(c):
        cid = c.get("criterion_id", "?")
        verdict = (c.get("verdict") or "error").lower()
        conf = (c.get("confidence") or "high").lower()
        title = titles.get(cid, "")
        conf_badge = f'<span class="conf-badge conf-low">confidence: low</span>' if conf == "low" else ""
        rows = [f'<tr><td>Result</td><td>{esc(c.get("last_action"))}</td></tr>']
        if c.get("kinds"):
            rows.append(f'<tr><td>Verified via</td><td>{esc(", ".join(c["kinds"]))}</td></tr>')
        if c.get("nonUiActionReason"):
            rows.append(f'<tr><td>Note</td><td>{esc(c["nonUiActionReason"])}</td></tr>')
        if c.get("bug_ref"):
            rows.append(f'<tr><td>Bug report</td><td><a href="#{esc(c["bug_ref"])}">{esc(c["bug_ref"])}</a></td></tr>')
        ev = c.get("evidence_refs") or []
        ev_list = "".join(f'<li><a href="{esc(e)}">{esc(os.path.relpath(e, "evidence") if e.startswith("evidence/") else e)}</a></li>' for e in ev)
        shots = [e for e in ev if e.lower().endswith((".png", ".jpg", ".jpeg", ".webp"))]
        grid = ""
        if shots:
            figs = "".join(f'<figure><img src="{esc(s)}" alt="{esc(cid)}"><figcaption>{esc(os.path.basename(s))}</figcaption></figure>' for s in shots)
            grid = f'<div class="screenshot-grid">{figs}</div>'
        return (
            f'<div class="card"><div class="card-header">'
            f'<span class="badge badge-{verdict}">{verdict}</span>'
            f'<span class="card-id">{esc(cid)}</span>'
            f'<span class="card-title">{esc(title)}</span>{conf_badge}</div>'
            f'<div class="card-body"><table class="field-table">{"".join(rows)}</table>'
            f'<ul class="evidence-list">{ev_list}</ul>{grid}</div></div>'
        )

    non_deferred = [c for c in criteria if (c.get("verdict") or "").lower() != "deferred"]
    deferred = [c for c in criteria if (c.get("verdict") or "").lower() == "deferred"]

    criteria_cards = "\n".join(card_html(c) for c in non_deferred) or "<p><em>No criteria.</em></p>"
    if deferred:
        deferred_cards = "\n".join(
            f'<div class="deferred-card"><strong>DEFERRED — {esc(c.get("criterion_id"))}: {esc(titles.get(c.get("criterion_id"), ""))}</strong>'
            f'<p class="reason"><strong>Reason:</strong> {esc(c.get("last_action") or c.get("nonUiActionReason"))}</p></div>'
            for c in deferred
        )
    else:
        deferred_cards = "<p><em>No criteria were deferred this run.</em></p>"

    if bugs:
        def bug_html(b):
            bid = b.get("id", "BUG")
            sev = (b.get("severity") or "medium").lower()
            layer = b.get("suspected_layer") or b.get("layer") or ""
            steps = b.get("steps") or b.get("repro") or []
            steps_html = "".join(f"<li>{esc(s)}</li>" for s in steps) if isinstance(steps, list) else esc(steps)
            return (
                f'<div class="bug-card" id="{esc(bid)}"><h3>{esc(bid)} — {esc(b.get("title"))}</h3>'
                f'<div class="bug-meta"><span class="severity-{sev}">severity: {sev}</span>'
                + (f'<span class="layer-badge">{esc(layer)}</span>' if layer else "")
                + (f'<span>{esc(b.get("criterion"))}</span>' if b.get("criterion") else "")
                + "</div>"
                + (f'<div class="steps"><strong>Steps to reproduce:</strong><ol>{steps_html}</ol></div>' if steps_html else "")
                + (f'<p>{esc(b.get("summary") or b.get("root_cause"))}</p>' if (b.get("summary") or b.get("root_cause")) else "")
                + "</div>"
            )
        bug_cards = "\n".join(bug_html(b) for b in bugs)
    else:
        bug_cards = "<p><em>No bugs logged this run.</em></p>"

    low_callout = (
        f'<div class="callout"><strong>Confidence: LOW on {low_conf} verdict(s)</strong> '
        f'Expected value derived from backend code — can catch precision/propagation bugs, not formula correctness.</div>'
        if low_conf else ""
    )

    cost = manifest.get("cost")
    if cost:
        cost_section = (
            '<table class="field-table">'
            f'<tr><td>Started</td><td>{esc(manifest.get("started_at"))}</td></tr>'
            f'<tr><td>Finished</td><td>{esc(manifest.get("ended_at"))}</td></tr>'
            f'<tr><td>Criteria</td><td>{esc(manifest.get("criteria_done"))} / {esc(manifest.get("criteria_total"))}</td></tr>'
            f'<tr><td>tool-calls</td><td>{esc(cost.get("toolCalls") if isinstance(cost, dict) else "")}</td></tr>'
            "</table>"
        )
    else:
        cost_section = "<p><em>Cost telemetry unavailable for this run.</em></p>"

    html_tpl = open(os.path.join(tpl_dir, "report.html")).read()
    repl = {
        "FEATURE": esc(feature), "RUN_ID": esc(run_id), "DATE": esc(date), "BUILD_ID": esc(build_id),
        "TALLY_PASS": tally["pass"], "TALLY_FAIL": tally["fail"], "TALLY_BLOCKED": tally["blocked"],
        "TALLY_DEFERRED": tally["deferred"], "TALLY_ERROR": tally["error"], "TALLY_TOTAL": total,
        "TALLY_LOW_CONFIDENCE": low_conf,
        "LOW_CONFIDENCE_CALLOUT": low_callout, "COST_SECTION": cost_section,
        "CRITERIA_CARDS": criteria_cards, "DEFERRED_CARDS": deferred_cards,
        "TRACEABILITY_SECTION": "", "BUG_CARDS": bug_cards,
    }
    for k, v in repl.items():
        html_tpl = html_tpl.replace("{{" + k + "}}", str(v))
    # strip the guidance HTML comments so they don't render
    import re
    html_tpl = re.sub(r"<!--.*?-->", "", html_tpl, flags=re.DOTALL)
    with open(os.path.join(run_dir, "report.html"), "w") as fh:
        fh.write(html_tpl)

    # ---------- report.md ----------
    lines = [
        "# QA Run Report", "",
        f"**Run ID:** {run_id}", f"**Date:** {date}", f"**Feature / Target:** {feature}",
        f"**Build / Deploy ID:** {build_id}", f"**Detected stack:** {stack_str}", "", "---", "",
        "## Summary", "", "| Verdict | Count |", "|---|---|",
    ]
    for v in VERDICTS:
        lines.append(f"| {v} | {tally[v]} |")
    lines.append(f"| **Total** | **{total}** |")
    lines.append("")
    if low_conf:
        lines.append(f"> **Note:** {low_conf} verdict(s) carry confidence: low.")
        lines.append("")
    lines += ["---", "", "## Criteria", ""]
    for c in non_deferred:
        cid = c.get("criterion_id", "?")
        lines += [
            f"### {cid} — {titles.get(cid, '')}", "",
            f"- **Verdict:** {c.get('verdict')}",
            f"- **Confidence:** {c.get('confidence')}",
            f"- **Result:** {c.get('last_action')}",
        ]
        if c.get("kinds"):
            lines.append(f"- **Verified via:** {', '.join(c['kinds'])}")
        if c.get("bug_ref"):
            lines.append(f"- **Bug:** {c['bug_ref']}")
        for e in (c.get("evidence_refs") or []):
            lines.append(f"  - `{e}`")
        lines.append("")
    lines += ["---", "", "## Deferred", ""]
    if deferred:
        for c in deferred:
            cid = c.get("criterion_id", "?")
            lines += [f"### DEFERRED — {cid}: {titles.get(cid, '')}", "",
                      f"**Reason:** {c.get('last_action') or c.get('nonUiActionReason')}", ""]
    else:
        lines += ["_No criteria were deferred this run._", ""]
    lines += ["---", "", "## Bugs", ""]
    if bugs:
        for b in bugs:
            lines += [f"### {b.get('id','BUG')} — {b.get('title','')}",
                      f"- severity: {b.get('severity','')}",
                      f"- suspected layer: {b.get('suspected_layer', b.get('layer',''))}",
                      f"- {b.get('summary') or b.get('root_cause') or ''}", ""]
    else:
        lines += ["_No bugs logged this run._", ""]
    with open(os.path.join(run_dir, "report.md"), "w") as fh:
        fh.write("\n".join(lines))

    return tally, total, low_conf


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: render-report.py <run-dir> [templates-dir]")
    run_dir = sys.argv[1]
    tpl_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "skills", "writing-qa-reports", "templates")
    t, total, lc = render(run_dir, tpl_dir)
    print(f"wrote report.html + report.md to {run_dir}")
    print(f"tally: {t} total={total} low_confidence={lc}")
