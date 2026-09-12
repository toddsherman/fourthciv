#!/usr/bin/env python3
"""Cheap packaging checks; --smoke also packages an existing app without rebuilding it.

    python3 scripts/test_dmg.py
    FOURTHCIV_DMG_PYTHON=/path/to/python3.12 python3 scripts/test_dmg.py --smoke
"""
import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from build_dmg import APP_NAME, HELP_NAME, ROOT, UNSIGNED_NAME, app_manifest, build, load_layout, settings_for


class PackagingTests(unittest.TestCase):
    def test_invalid_layout_is_rejected_before_packaging(self):
        valid = load_layout()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "layout.json"
            for field, value in (("width", "720"), ("height", 0), ("iconSize", 10_000)):
                invalid = copy.deepcopy(valid)
                invalid[field] = value
                path.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    load_layout(path)
            invalid = copy.deepcopy(valid)
            invalid["iconLocations"][APP_NAME] = [720, 235]
            path.write_text(json.dumps(invalid))
            with self.assertRaises(ValueError):
                load_layout(path)
            invalid["iconLocations"]["Unexpected.txt"] = [5, 5]
            path.write_text(json.dumps(invalid))
            with self.assertRaises(ValueError):
                load_layout(path)

    def test_only_intended_installer_items_are_included(self):
        settings = settings_for(Path("/fixture/Fourth Civ.app"), Path("/fixture/background.tiff"), load_layout())
        names = {item[1] if isinstance(item, tuple) else Path(item).name for item in settings["files"]}
        self.assertEqual(names, {APP_NAME, HELP_NAME})
        self.assertEqual(settings["symlinks"], {"Applications": "/Applications"})
        self.assertNotIn(APP_NAME, settings["hide_extensions"])  # Keep signed app FinderInfo untouched.
        self.assertEqual(settings["hide_extensions"], [HELP_NAME])
        unsigned = settings_for(Path("/fixture/Fourth Civ.app"), Path("/fixture/background.tiff"),
                                load_layout(), Path("/fixture") / UNSIGNED_NAME)
        self.assertIn("/fixture/" + UNSIGNED_NAME, unsigned["files"])
        self.assertGreater(unsigned["icon_locations"][UNSIGNED_NAME][1], load_layout()["height"])
        self.assertEqual(unsigned["scroll_position"], (0, 0))

    def test_existing_output_and_broken_symlink_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "published.dmg"
            output.write_bytes(b"immutable release")
            with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                build(root, output)
            self.assertEqual(output.read_bytes(), b"immutable release")
            output.unlink()
            output.symlink_to(root / "absent.dmg")
            with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                build(root, output)
            self.assertTrue(output.is_symlink())

    def test_integrity_comparison_detects_bytes_modes_and_framework_symlink_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / APP_NAME
            framework = app / "Contents/Frameworks/Fixture.framework"
            version = framework / "Versions/B"
            version.mkdir(parents=True)
            executable = version / "Fixture"
            executable.write_bytes(b"fixture executable")
            executable.chmod(0o755)
            (framework / "Versions/Current").symlink_to("B")
            (framework / "Fixture").symlink_to("Versions/Current/Fixture")
            before = app_manifest(app)
            copied = root / "Copied.app"
            shutil.copytree(app, copied, symlinks=True)
            self.assertEqual(before, app_manifest(copied))
            self.assertEqual(before["Contents/Frameworks/Fixture.framework/Versions/Current"], ("link", "B"))
            executable.write_bytes(b"modified executable")
            self.assertNotEqual(before, app_manifest(app))
            executable.write_bytes(b"fixture executable")
            executable.chmod(0o644)
            self.assertNotEqual(before, app_manifest(app))
            executable.chmod(0o755)
            (framework / "Versions/Current").unlink()
            (framework / "Versions/Current").symlink_to("A")
            self.assertNotEqual(before, app_manifest(app))


def smoke(app: Path) -> None:
    app = app.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="fourthciv-dmg-smoke-") as temporary:
        root = Path(temporary)
        payload = root / "payload"
        payload.mkdir()
        # The builder resolves this input link and copies the app with ditto.
        # There is no need to build or make a second mutable app copy here.
        (payload / APP_NAME).symlink_to(app, target_is_directory=True)
        (payload / UNSIGNED_NAME).write_text("Local packaging test only. Do not distribute.\n")
        output = root / "FourthCiv-Packaging-Smoke-UNSIGNED.dmg"
        subprocess.run(["bash", str(ROOT / "scripts/build-dmg.sh"), str(payload), str(output)], check=True)
        before = output.stat()
        refused = subprocess.run(["bash", str(ROOT / "scripts/build-dmg.sh"), str(payload), str(output)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if refused.returncode == 0 or b"Refusing to overwrite" not in refused.stderr or output.stat() != before:
            raise AssertionError("Packaging did not preserve an existing installer")
        print("DMG smoke check passed using the existing app; no app build, launch, or signing performed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--app", type=Path, default=ROOT / "dist" / APP_NAME)
    arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PackagingTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if arguments.smoke:
        smoke(arguments.app)
