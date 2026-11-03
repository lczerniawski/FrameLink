#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("make_source", ROOT / "scripts/make-source.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SourceChecks(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.ipa = Path(self.work.name) / "FrameLink.ipa"
        self.listing = json.loads((ROOT / "distribution/source.json").read_text())
        self.info = {
            "CFBundleDisplayName": "Frame Link",
            "CFBundleIdentifier": "com.lczerniawski.framelink",
            "CFBundleExecutable": "FrameLink",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "7",
            "MinimumOSVersion": "26.0",
            "NSCameraUsageDescription": "Use the camera.",
            "NSPhotoLibraryUsageDescription": "Delete selected original photos.",
        }

    def package(self, extra=None):
        with ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/FrameLink.app/Info.plist", plistlib.dumps(self.info))
            archive.writestr("Payload/FrameLink.app/FrameLink", b"unsigned executable fixture")
            for path, value in (extra or {}).items():
                archive.writestr(path, value)

    def test_metadata_comes_from_exact_ipa(self):
        self.package()
        original = copy.deepcopy(self.listing)
        source = module.make_source(self.ipa, "v1.0", self.listing)
        app = source["apps"][0]
        release = app["versions"][0]
        self.assertEqual(release["size"], self.ipa.stat().st_size)
        self.assertEqual((release["version"], release["buildVersion"], release["minOSVersion"]), ("1.0", "7", "26.0"))
        self.assertEqual(release["downloadURL"], "https://github.com/lczerniawski/FrameLink/releases/download/v1.0/FrameLink.ipa")
        self.assertEqual(app["appPermissions"], {"entitlements": [], "privacy": {
            "NSCameraUsageDescription": "Use the camera.",
            "NSPhotoLibraryUsageDescription": "Delete selected original photos.",
        }})
        self.assertEqual(self.listing, original)

    def test_keep_history_but_reject_duplicate_or_older_release(self):
        self.package()
        previous = module.make_source(self.ipa, "v1.0", self.listing)
        original = copy.deepcopy(previous)
        self.info["CFBundleShortVersionString"] = "1.1"
        self.package()
        source = module.make_source(self.ipa, "v1.1", self.listing, previous)
        self.assertEqual([item["version"] for item in source["apps"][0]["versions"]], ["1.1", "1.0"])
        self.assertEqual(source["apps"][0]["versions"][1], previous["apps"][0]["versions"][0])
        self.assertEqual(previous, original)
        for version in ("1.0", "0.9", "1.0.0"):
            with self.subTest(version=version):
                self.info["CFBundleShortVersionString"] = version
                self.package()
                with self.assertRaises(ValueError):
                    module.make_source(self.ipa, f"v{version}", self.listing, previous)

    def test_version_order_is_numeric(self):
        self.info["CFBundleShortVersionString"] = "1.9"
        self.package()
        previous = module.make_source(self.ipa, "v1.9", self.listing)
        self.info["CFBundleShortVersionString"] = "1.10"
        self.package()
        source = module.make_source(self.ipa, "v1.10", self.listing, previous)
        self.assertEqual(source["apps"][0]["versions"][0]["version"], "1.10")

    def test_reject_wrong_tag_identity_and_empty_privacy(self):
        self.package()
        with self.assertRaises(ValueError):
            module.make_source(self.ipa, "v2.0", self.listing)
        for key, value in (("CFBundleIdentifier", "com.example.other"), ("CFBundleShortVersionString", "1.0-beta"), ("NSCameraUsageDescription", "")):
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.package()
                with self.assertRaises(ValueError):
                    module.make_source(self.ipa, "v1.0", self.listing)
                self.info[key] = original

    def test_reject_profiles_signatures_and_nested_permissions(self):
        for path in ("Payload/FrameLink.app/embedded.mobileprovision", "Payload/FrameLink.app/_CodeSignature/CodeResources", "Payload/FrameLink.app/PlugIns/Widget.appex/Info.plist"):
            with self.subTest(path=path):
                self.package({path: b"fixture"})
                with self.assertRaises(ValueError):
                    module.make_source(self.ipa, "v1.0", self.listing)

    def test_reject_unrelated_or_redirected_history(self):
        self.package()
        previous = module.make_source(self.ipa, "v1.0", self.listing)
        self.info["CFBundleShortVersionString"] = "1.1"
        self.package()
        previous["apps"][0]["versions"][0]["downloadURL"] = "https://example.invalid/other.ipa"
        with self.assertRaises(ValueError):
            module.make_source(self.ipa, "v1.1", self.listing, previous)
        previous["apps"][0]["bundleIdentifier"] = "com.example.other"
        with self.assertRaises(ValueError):
            module.make_source(self.ipa, "v1.1", self.listing, previous)


if __name__ == "__main__":
    unittest.main()
