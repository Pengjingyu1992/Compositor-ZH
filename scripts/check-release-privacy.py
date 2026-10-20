#!/usr/bin/env python3
"""Reject common embedded credentials and personal home paths in release files."""
import argparse
import re
import subprocess
from pathlib import Path

RULES = {
    "private key": rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----",
    "GitHub token": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})",
    "API token": rb"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}",
    "AWS access key": rb"(?:AKIA|ASIA)[A-Z0-9]{16}",
    "credential URL": rb"https?://[^\s/:@]+:[^\s/@]+@",
    "personal home path": rb"/(?:Users|home)/[A-Za-z0-9_.-]+/",
}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bundle", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
tracked = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).split(b"\0")
candidates = [root / path.decode() for path in tracked if path]
# A tracked deletion is not a release file; do not restore an intentionally removed local platform tree.
paths = [path for path in candidates if path.is_file()]
if args.bundle:
    paths.extend(path for path in args.bundle.rglob("*") if path.is_file())
failures = []
for path in paths:
    data = path.read_bytes()
    for name, pattern in RULES.items():
        if re.search(pattern, data):
            failures.append((str(path.relative_to(root)) if path.is_relative_to(root) else path.name, name))
for path, name in failures:
    print(f"FAIL: {path}: {name}")  # Never print matched credential contents.
print(f"Privacy pattern scan: {len(paths)} files, {len(failures)} findings")
raise SystemExit(bool(failures))
