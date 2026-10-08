#!/usr/bin/env python3
"""Derive display versions from VERSION and the nearest reachable release tag."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = re.compile(r"\d+\.\d+(?:\.\d+)?\Z")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def version_info(root=ROOT):
    base = (root / "VERSION").read_text().strip()
    if not RELEASE.fullmatch(base):
        raise ValueError("VERSION must contain a numeric release, such as 1.0 or 1.0.1")
    tags = [tag for tag in git(root, "tag", "--merged", "HEAD").splitlines() if RELEASE.fullmatch(tag)]
    tag = None
    if tags:
        args = ["describe", "--tags", "--abbrev=0"]
        for candidate in tags:
            args += ["--match", candidate]
        tag = git(root, *args)
    count = int(git(root, "rev-list", "--count", f"{tag}..HEAD" if tag else "HEAD"))
    display = base if tag == base and count == 0 else f"{base}-{count}"
    return {"base": base, "display": display, "commitsSinceRelease": count,
            "releaseTag": tag, "commit": git(root, "rev-parse", "HEAD"),
            "build": str(int(git(root, "rev-list", "--count", "HEAD")))}


def write_plist(plist_path, info, template=None):
    with (template or plist_path).open("rb") as handle:
        plist = plistlib.load(handle)
    # Apple bundle versions stay numeric; all app-facing versions use display.
    plist["CFBundleShortVersionString"] = info["base"]
    plist["CFBundleVersion"] = info["build"]
    plist["CodexUsageViewerDisplayVersion"] = info["display"]
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    with plist_path.open("wb") as handle:
        plistlib.dump(plist, handle, fmt=plistlib.FMT_BINARY)


def write_bundle(bundle, info):
    write_plist(bundle / "Contents/Info.plist", info)
    resources = bundle / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (resources / "BuildVersion.json").write_text(json.dumps(info, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-bundle", type=Path)
    parser.add_argument("--write-plist", type=Path)
    parser.add_argument("--plist-template", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    info = version_info()
    if args.write_bundle:
        write_bundle(args.write_bundle, info)
    if args.write_plist:
        write_plist(args.write_plist, info, args.plist_template)
    print(json.dumps(info) if args.json else info["display"])


if __name__ == "__main__":
    main()
