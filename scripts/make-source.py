#!/usr/bin/env python3
"""Generate the release feed from the exact unsigned Frame Link IPA."""

import argparse
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
from zipfile import ZipFile


def version_number(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError(f"Invalid numeric app version: {value!r}")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def make_source(ipa, tag, listing, previous=None):
    source = copy.deepcopy(listing)
    if len(source["apps"]) != 1:
        raise ValueError("The release source must contain exactly one app")
    app = source["apps"][0]
    with ZipFile(ipa) as archive:
        names = archive.namelist()
        # shortcut: one unsigned app only; inspect nested permissions before adding extensions/frameworks.
        if any(name.endswith("embedded.mobileprovision") or "/_CodeSignature/" in name for name in names):
            raise ValueError("Publish an unsigned IPA without provisioning profiles or signatures")
        info_paths = [name for name in names if name.startswith("Payload/") and name.endswith("/Info.plist")]
        if info_paths != ["Payload/FrameLink.app/Info.plist"]:
            raise ValueError("Expected one FrameLink.app without nested apps, extensions, or frameworks")
        if archive.testzip() is not None:
            raise ValueError("Corrupt IPA archive")
        info = plistlib.loads(archive.read(info_paths[0]))
        if "Payload/FrameLink.app/" + info["CFBundleExecutable"] not in names:
            raise ValueError("IPA executable is missing")
    if info["CFBundleIdentifier"] != app["bundleIdentifier"]:
        raise ValueError("IPA bundle identifier does not match the listing")
    version = info["CFBundleShortVersionString"]
    number = version_number(version)
    version_number(info["CFBundleVersion"])
    version_number(info["MinimumOSVersion"])
    if tag != f"v{version}":
        raise ValueError(f"Tag must be v{version} to match the packaged app version")
    privacy = {key: value for key, value in info.items() if key.startswith("NS") and key.endswith("UsageDescription")}
    if not privacy or any(not isinstance(value, str) or not value.strip() for value in privacy.values()):
        raise ValueError("IPA must contain nonempty privacy descriptions")
    history = []
    if previous is not None:
        old_apps = previous["apps"]
        if len(old_apps) != 1 or old_apps[0]["bundleIdentifier"] != app["bundleIdentifier"]:
            raise ValueError("Previous feed does not belong to this app")
        history = copy.deepcopy(old_apps[0]["versions"])
        if not isinstance(history, list) or not history:
            raise ValueError("Previous published feed has no version history")
        for old in history:
            if number <= version_number(old["version"]):
                raise ValueError("New release must be newer than every published version")
            expected = f"{source['website']}/releases/download/v{old['version']}/FrameLink.ipa"
            if old["downloadURL"] != expected:
                raise ValueError("Previous release URL does not match this repository")
    app["name"] = info["CFBundleDisplayName"]
    app["versions"] = [{
        "version": version,
        "buildVersion": info["CFBundleVersion"],
        "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "downloadURL": f"{source['website']}/releases/download/{tag}/FrameLink.ipa",
        "size": Path(ipa).stat().st_size,
        "minOSVersion": info["MinimumOSVersion"],
    }] + history
    app["appPermissions"] = {"entitlements": [], "privacy": privacy}
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("tag")
    parser.add_argument("output", type=Path)
    parser.add_argument("--previous-source", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    listing = json.loads((root / "distribution/source.json").read_text())
    previous = json.loads(args.previous_source.read_text()) if args.previous_source else None
    source = make_source(args.ipa, args.tag, listing, previous)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")
    print(f"Generated {args.output} from {args.ipa} ({args.ipa.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
