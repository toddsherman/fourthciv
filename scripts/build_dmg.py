#!/usr/bin/env python3
"""Build and verify the styled installer without launching or scripting Finder.

dmgbuild uses ditto and writes .DS_Store directly. Finder/DiskImageMounter opens
the volume normally; deprecated bless --openfolder is not used on Apple silicon.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Fourth Civ.app"
HELP_NAME = "Installation help.txt"
UNSIGNED_NAME = "UNSIGNED-TEST-BUILD.txt"


def run(*arguments: object, capture: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run([str(argument) for argument in arguments], check=True,
                          stdout=subprocess.PIPE if capture else None)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def load_layout(path: Path = ROOT / "Resources/DMG/layout.json") -> dict:
    layout = json.loads(path.read_text())
    for field in ("width", "height", "iconSize"):
        require(type(layout.get(field)) is int and layout[field] > 0, f"Invalid DMG {field}")
    require(layout["iconSize"] <= min(layout["width"], layout["height"]), "DMG icons exceed window size")
    locations = layout.get("iconLocations", {})
    require(set(locations) == {APP_NAME, "Applications", HELP_NAME}, "Unexpected DMG layout items")
    for name, position in locations.items():
        require(isinstance(position, list) and len(position) == 2 and all(type(v) is int for v in position),
                f"Invalid icon position for {name}")
        require(0 <= position[0] < layout["width"] and 0 <= position[1] < layout["height"],
                f"Icon position outside DMG window: {name}")
    return layout


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def app_manifest(app: Path) -> dict:
    """Compare all bundle bytes, executable modes, directories and symlink targets.

    Code signature verification separately checks the signed bundle and nested code.
    """
    entries = {}
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            entries[relative] = ("link", os.readlink(path))
        elif stat.S_ISREG(mode):
            entries[relative] = ("file", stat.S_IMODE(mode), digest(path))
        elif stat.S_ISDIR(mode):
            entries[relative] = ("directory", stat.S_IMODE(mode))
        else:
            raise ValueError(f"Unsupported bundle entry: {relative}")
    return entries


def verify_signature(app: Path) -> None:
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    run("/usr/bin/codesign", "--verify", "--strict", app / "Contents/MacOS/fourthciv-cli")


def settings_for(app: Path, background: Path, layout: dict, unsigned_notice: Path | None = None) -> dict:
    locations = {name: tuple(position) for name, position in layout["iconLocations"].items()}
    files = [(str(app), APP_NAME), str(ROOT / "Resources/DMG" / HELP_NAME)]
    if unsigned_notice is not None:
        files.append(str(unsigned_notice))
        locations[UNSIGNED_NAME] = (100, layout["height"] + 80)
    return {
        "format": "UDZO", "filesystem": "HFS+",
        "files": files, "symlinks": {"Applications": "/Applications"},
        # Finder normally hides .app already. Setting its FinderInfo to force the
        # extension hidden would make strict signature verification reject it.
        "hide_extensions": [HELP_NAME],
        "icon": str(app / "Contents/Resources/FourthCiv.icns"),
        "background": str(background), "default_view": "icon-view",
        "window_rect": ((160, 160), (layout["width"], layout["height"])),
        "show_status_bar": False, "show_tab_view": False, "show_toolbar": False,
        "show_pathbar": False, "show_sidebar": False, "sidebar_width": 0,
        "arrange_by": None, "grid_spacing": 80, "scroll_position": (0, 0),
        "show_icon_preview": False, "show_item_info": False, "label_pos": "bottom",
        "text_size": 14, "icon_size": layout["iconSize"], "icon_locations": locations,
        "include_icon_view_settings": True, "include_list_view_settings": False,
    }


@contextmanager
def mounted_readonly(image: Path):
    with tempfile.TemporaryDirectory(prefix="fourthciv-dmg-mount-") as directory:
        mount = Path(directory) / "volume"
        mount.mkdir()
        attached = False
        try:
            result = run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                         "-mountpoint", mount, "-plist", image, capture=True)
            attached = True
            entities = plistlib.loads(result.stdout)["system-entities"]
            require(any(Path(entry.get("mount-point", "/")).resolve() == mount.resolve() for entry in entities), "Image mounted at unexpected location")
            yield mount
        finally:
            if attached or os.path.ismount(mount):
                for attempt in range(3):
                    detached = subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)],
                                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    if detached.returncode == 0:
                        break
                    time.sleep(1)
                else:
                    # Detach only the unique temporary mount owned by this check.
                    run("/usr/bin/hdiutil", "detach", "-force", mount)


def verify_image(image: Path, source_app: Path, layout: dict, background: Path,
                 unsigned_notice: Path | None = None, source_manifest: dict | None = None) -> dict:
    from ds_store import DSStore
    from mac_alias import Alias

    expected_manifest = source_manifest if source_manifest is not None else app_manifest(source_app)
    settings = settings_for(source_app, background, layout, unsigned_notice)
    with mounted_readonly(image) as mount:
        expected_names = {APP_NAME, "Applications", HELP_NAME}
        if unsigned_notice is not None:
            expected_names.add(UNSIGNED_NAME)
        require({path.name for path in mount.iterdir() if not path.name.startswith(".")} == expected_names,
                "Unexpected visible files in the installer")
        require((mount / "Applications").is_symlink() and os.readlink(mount / "Applications") == "/Applications",
                "Applications shortcut does not point to /Applications")
        require((mount / HELP_NAME).read_bytes() == (ROOT / "Resources/DMG" / HELP_NAME).read_bytes(), "Installation help changed")
        if unsigned_notice is not None:
            require((mount / UNSIGNED_NAME).read_bytes() == unsigned_notice.read_bytes(), "Unsigned-build notice missing or changed")
        require(digest(mount / ".background.tiff") == digest(background), "DMG background differs from generated artwork")
        require(digest(mount / ".VolumeIcon.icns") == digest(source_app / "Contents/Resources/FourthCiv.icns"), "DMG volume icon differs from app")
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            require(store["."]["icvl"] == (b"type", b"icnv"), "Finder default view is not icon view")
            window, icons = store["."]["bwsp"], store["."]["icvp"]
            require(window["WindowBounds"] == f"{{{{160, 160}}, {{{layout['width']}, {layout['height']}}}}}", "Incorrect Finder window bounds")
            require(all(window.get(key) is False for key in (
                "ShowStatusBar", "ShowTabView", "ShowToolbar", "ShowPathbar", "ShowSidebar", "ContainerShowSidebar")),
                "Unexpected Finder window controls")
            require(icons["iconSize"] == layout["iconSize"] and icons["arrangeBy"] == "none", "Incorrect icon size or automatic arrangement")
            require(icons["scrollPositionX"] == 0 and icons["scrollPositionY"] == 0, "Finder initial scroll position is not zero")
            require(icons["backgroundType"] == 2, "Finder background is not an image")
            alias = Alias.from_bytes(icons["backgroundImageAlias"])
            require(alias.target.filename == ".background.tiff" and alias.target.posix_path.lstrip("/") == ".background.tiff",
                    "Background alias does not refer to artwork inside this volume")
            for name, location in settings["icon_locations"].items():
                require(tuple(store[name]["Iloc"]) == location, f"Incorrect Finder position for {name}")
        for name in (HELP_NAME,):
            require(run("/usr/bin/GetFileInfo", "-aE", mount / name, capture=True).stdout.strip() == b"1", f"Visible extension for {name}")
        require(app_manifest(mount / APP_NAME) == expected_manifest, "Copied app bytes, modes, or framework symlinks changed")
        verify_signature(mount / APP_NAME)
    require(app_manifest(source_app) == expected_manifest, "Source app changed during packaging")
    return {"visibleItems": sorted(expected_names), "window": [layout["width"], layout["height"]],
            "iconSize": layout["iconSize"], "appEntriesVerified": len(expected_manifest),
            "background": "verified", "signature": "verified", "frameworkSymlinks": "preserved"}


def verify_artwork(directory: Path, layout: dict) -> None:
    for name, scale in (("background.png", 1), ("background@2x.png", 2), ("background.tiff", 1)):
        result = run("/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", directory / name, capture=True).stdout.decode()
        dimensions = {key: int(value) for key, value in re.findall(r"(pixelWidth|pixelHeight): (\d+)", result)}
        require(dimensions == {"pixelWidth": layout["width"] * scale, "pixelHeight": layout["height"] * scale},
                f"Incorrect dimensions for {name}")
    run("/usr/bin/swift", ROOT / "scripts/verify-dmg-artwork.swift", directory)


def build(payload: Path, output: Path) -> dict:
    payload = payload.resolve(strict=True)
    output = output.absolute()
    require(output.suffix.lower() == ".dmg", "Output filename must end in .dmg")
    require(not os.path.lexists(output), f"Refusing to overwrite existing output: {output}")
    app = (payload / APP_NAME).resolve(strict=True)
    require(app.is_dir(), f"Missing {APP_NAME} in payload")
    require((ROOT / "Resources/DMG" / HELP_NAME).is_file(), "Missing Installation help.txt")
    unsigned_notice = payload / UNSIGNED_NAME if (payload / UNSIGNED_NAME).is_file() else None
    layout = load_layout()
    verify_signature(app)
    manifest = app_manifest(app)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Build privately in the destination filesystem, then publish with an atomic,
    # non-overwriting hard link only after every verification succeeds.
    with tempfile.TemporaryDirectory(prefix=".fourthciv-dmg-", dir=output.parent) as temporary:
        work = Path(temporary)
        artwork = work / "artwork"
        run("/usr/bin/swift", ROOT / "scripts/make-dmg-background.swift", artwork)
        verify_artwork(artwork, layout)
        image = work / "installer.dmg"
        volume = "Fourth Civ — UNSIGNED TEST" if unsigned_notice is not None else "Fourth Civ"
        import dmgbuild

        dmgbuild.build_dmg(str(image), volume,
                           settings=settings_for(app, artwork / "background.tiff", layout, unsigned_notice),
                           lookForHiDPI=False)
        report = verify_image(image, app, layout, artwork / "background.tiff", unsigned_notice, manifest)
        os.link(image, output)
    print(f"Verified installer: {output}")
    print(json.dumps(report, indent=2))
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("payload_directory", type=Path)
    parser.add_argument("output_dmg", type=Path)
    arguments = parser.parse_args()
    build(arguments.payload_directory, arguments.output_dmg)


if __name__ == "__main__":
    main()
