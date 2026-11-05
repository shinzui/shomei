#!/usr/bin/env python3
"""Check source-derived review coverage and explicit child-plan ownership."""

from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
expected = set()
for source in (root / "docs/reviews").glob("*.md"):
    text = source.read_text()
    review = re.search(r"^reviewId: (REV-\d+)$", text, re.M)
    if review and 1 <= int(review[1][4:]) <= 10:
        expected.update(f"{review[1]}.{n}" for n in re.findall(r"^\*\*(\d+)\.", text, re.M))
assert len(expected) == 108, f"Original finding count changed: {len(expected)}"

ledger = (root / "docs/review-remediation/findings.md").read_text()
seen = set()
parents = set()
for line in ledger.splitlines():
    match = re.match(r"\| \[?((?:REV-\d+\.\d+(?:\.\d+)?)|EXTRA-\d+)", line)
    if not match:
        continue
    handle = match[1]
    if "--closed" in sys.argv:
        columns = [part.strip() for part in line.split("|")][1:-1]
        assert columns[3] in {
            "Fixed", "Existing decision verified", "Owner-approved decision", "Inapplicable with proof"
        }, f"Unclosed row: {handle} ({columns[3]})"
        evidence = columns[4]
        assert "Pending" not in evidence and re.search(r"\b[0-9a-f]{7,40}\b", evidence), (
            f"Missing commit-pinned evidence: {handle}"
        )
    assert handle not in seen, f"Duplicate ledger row: {handle}"
    seen.add(handle)
    if re.fullmatch(r"REV-\d+\.\d+", handle):
        parents.add(handle)
    elif handle.startswith("REV-"):
        assert handle.rsplit(".", 1)[0] in expected, f"Unknown parent: {handle}"
    owner = re.search(r"\| EP-([1-7]) \|", line)
    assert owner, f"Missing owner: {handle}"
    plan = next((root / "docs/plans").glob(f"{61 + int(owner[1])}-*.md"))
    acceptance = plan.read_text().split("## Validation and Acceptance", 1)[1]
    assert handle in re.findall(r"REV-\d+\.\d+(?:\.\d+)?|EXTRA-\d+", acceptance), (
        f"{handle} not named in {plan.name} acceptance"
    )
assert parents == expected, f"Missing: {expected - parents}; unexpected: {parents - expected}"
print(f"Inventory accepted: {len(parents)} parents, {len(seen)} total rows; all owners explicit")
