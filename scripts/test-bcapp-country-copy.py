#!/usr/bin/env python3
"""Tests which copy of a duplicated app the artifact index picks.

Run: python3 scripts/test-bcapp-country-copy.py
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _bcapp  # noqa: E402

spec = importlib.util.spec_from_file_location("keep", os.path.join(HERE, "resolve-keep-app-ids.py"))
keep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keep)

PLATFORM = "platform/Applications/BaseApp/Source/Base Application.app"
COUNTRY = "app/Applications.US/Base Application.app"


def write_app(root: str, relative: str, version: str) -> str:
    path = os.path.join(root, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("NavxManifest.xml",
                   f'<Package><App Id="base" Name="Base Application" Publisher="P" Version="{version}" /></Package>')
    return path


class CountryCopyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name

    def picked(self, loader, platform_first: bool) -> str:
        """Path the loader picks, with the walk order forced (it is filesystem dependent)."""
        found = sorted(os.walk(self.dir), key=lambda w: (os.sep + "platform" in w[0]) != platform_first)
        with mock.patch("os.walk", return_value=found):
            return os.path.relpath(loader(self.dir)["base"]["path"], self.dir)

    def assert_picks(self, expected: str):
        for loader in (_bcapp.load_artifact_apps, keep.load_artifact_apps):
            for platform_first in (True, False):
                with self.subTest(loader=loader.__module__, platform_first=platform_first):
                    self.assertEqual(self.picked(loader, platform_first), expected)

    def test_country_copy_wins_a_version_tie(self):
        write_app(self.dir, PLATFORM, "28.5.1.1")
        write_app(self.dir, COUNTRY, "28.5.1.1")
        self.assert_picks(COUNTRY)

    def test_country_copy_wins_over_a_newer_platform_copy(self):
        write_app(self.dir, PLATFORM, "28.5.1.2")
        write_app(self.dir, COUNTRY, "28.5.1.1")
        self.assert_picks(COUNTRY)

    def test_platform_copy_is_used_when_it_is_the_only_one(self):
        write_app(self.dir, PLATFORM, "28.5.1.1")
        self.assert_picks(PLATFORM)

    def test_highest_version_wins_between_country_copies(self):
        write_app(self.dir, COUNTRY, "28.5.1.1")
        newer = "app/Extensions/Base Application.app"
        write_app(self.dir, newer, "28.5.1.2")
        self.assertEqual(self.picked(_bcapp.load_artifact_apps, True), newer)


if __name__ == "__main__":
    unittest.main()
