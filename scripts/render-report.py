#!/usr/bin/env python3
"""Compatibility shim (engine 0.10.0, ADR-0028): the report renderer is now
scripts/render-report.js — one deterministic implementation with screenshot
thumbnails and a full-screen viewer. This keeps the 0.7.1-0.9.0 command
`python3 scripts/render-report.py <run-dir>` working by handing over to it.

Usage: render-report.py <run-dir> [templates-dir] [--embed]
"""
import os
import shutil
import sys

here = os.path.dirname(os.path.abspath(__file__))
node = shutil.which("node")
if not node:
    sys.exit("render-report: node is required (scripts/render-report.js)")
args = sys.argv[1:]
if not args:
    sys.exit("usage: render-report.py <run-dir> [templates-dir] [--embed]")
out = [node, os.path.join(here, "render-report.js"), args[0]]
for a in args[1:]:
    out += ["--templates", a] if not a.startswith("--") else [a]
os.execv(node, out)
