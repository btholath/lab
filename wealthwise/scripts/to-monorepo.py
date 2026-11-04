#!/usr/bin/env python3
"""Adapt WealthWise's GitHub workflows for a repo where it lives in a subfolder (e.g. btholath/lab/wealthwise)."""
import os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
proj = os.path.dirname(here)
try:
    root = subprocess.check_output(["git", "-C", proj, "rev-parse", "--show-toplevel"], text=True).strip()
except Exception:
    sys.exit("Not inside a git repository.")
prefix = os.path.relpath(proj, root).replace(os.sep, "/")
if prefix == ".":
    sys.exit("WealthWise is at the repository root: nothing to do.")

src = os.path.join(proj, ".github", "workflows")
if not os.path.exists(os.path.join(src, "ci.yml")):
    sys.exit("Already migrated (see <repo root>/.github/workflows).")
dst = os.path.join(root, ".github", "workflows")
os.makedirs(dst, exist_ok=True)

def sub(text, old, new, count=1):
    if old not in text:
        sys.exit(f"Expected text not found (workflow changed?): {old[:60]!r}")
    return text.replace(old, new) if count == 0 else text.replace(old, new, count)

ci = open(os.path.join(src, "ci.yml")).read()
paths = f"['{prefix}/**', '.github/workflows/wealthwise-ci.yml']"
ci = sub(ci, "name: CI\n", "name: WealthWise CI\n")
ci = sub(ci, "on:\n  push: { branches: [main] }\n  pull_request:\n",
         f"on:\n  push:\n    branches: [main]\n    paths: {paths}\n  pull_request:\n    paths: {paths}\n")
ci = sub(ci, "group: ci-${{ github.ref }}", "group: wealthwise-ci-${{ github.ref }}")
ci = sub(ci, "permissions:\n  contents: read\n",
         f"permissions:\n  contents: read\n\ndefaults:\n  run:\n    working-directory: {prefix}\n")
ci = sub(ci, "defaults: { run: { working-directory: web } }", f"defaults: {{ run: {{ working-directory: {prefix}/web }} }}")
ci = sub(ci, "cache-dependency-path: web/package-lock.json", f"cache-dependency-path: {prefix}/web/package-lock.json")
ci = sub(ci, "path: TestResults", f"path: {prefix}/TestResults")

rel = open(os.path.join(src, "release.yml")).read()
rel = sub(rel, "name: Release\n", "name: WealthWise Release\n")
rel = sub(rel, 'tags: ["v*.*.*"]', 'tags: ["wealthwise-v*.*.*"]')
rel = sub(rel, '${GITHUB_REF_NAME#v}', '${GITHUB_REF_NAME#wealthwise-v}')
rel = sub(rel, "context: .\n", f"context: {prefix}\n", 0)
rel = sub(rel, "file: api/Dockerfile", f"file: {prefix}/api/Dockerfile")
rel = sub(rel, "file: web/Dockerfile", f"file: {prefix}/web/Dockerfile")

open(os.path.join(dst, "wealthwise-ci.yml"), "w").write(ci)
open(os.path.join(dst, "wealthwise-release.yml"), "w").write(rel)
for f in ("ci.yml", "release.yml"):
    os.remove(os.path.join(src, f))
try:
    os.rmdir(src); os.rmdir(os.path.dirname(src))
except OSError:
    pass
rb = os.path.join(proj, "docs", "confluence", "05-release-runbook.md")
if os.path.exists(rb):
    t = open(rb).read().replace("git tag v1.4.0 && git push origin v1.4.0", "git tag wealthwise-v1.4.0 && git push origin wealthwise-v1.4.0")
    open(rb, "w").write(t)
print(f"Workflows written to {os.path.relpath(dst, os.getcwd())}/wealthwise-ci.yml and wealthwise-release.yml")
