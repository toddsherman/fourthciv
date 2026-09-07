#!/usr/bin/env python3
"""Build an isolated native Sparkle/SwiftUI regression; never launch the node."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import uuid


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_app", type=Path, help="A published Fourth Civ.app copy; only read")
    parser.add_argument("--output", type=Path, required=True, help="A new, empty test directory")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = args.source_app.resolve()
    output = args.output.resolve()
    metadata = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    target_build = int(metadata["CFBundleVersion"])
    if target_build <= 1:
        parser.error("Source app must have a published build greater than 1")
    framework = root / ".build/debug/Sparkle.framework"
    if not framework.is_dir():
        parser.error("Run swift build first to obtain the pinned Sparkle framework")
    if output.exists():
        parser.error("Output must not exist; use a fresh directory for each test")
    output.mkdir(parents=True)
    host = output / "installed/Fourth Civ.app"
    app = output / "Popup Update Test.app"
    run("ditto", source, host)
    metadata["CFBundleVersion"] = str(target_build - 1)
    (host / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
    run("codesign", "--force", "--sign", "-", host)
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Frameworks").mkdir()
    run("ditto", framework, app / "Contents/Frameworks/Sparkle.framework")
    info = dict(
        CFBundleIdentifier=f"ai.fourthciv.popup-test-{uuid.uuid4().hex[:12]}",
        CFBundleName="Fourth Civ Popup Update Test", CFBundleExecutable="PopupUpdateTest",
        CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="1.0",
        LSMinimumSystemVersion="14.0", TestHostPath=str(host),
        TestOutputDirectory=str(output), TestTargetBuild=target_build,
    )
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run("swiftc", "-parse-as-library", root / "scripts/update-popup-test.swift",
        root / "Sources/FourthCivApp/Updates.swift", root / "Sources/FourthCivApp/Theme.swift",
        "-F", framework.parent, "-framework", "Sparkle", "-framework", "AppKit",
        "-framework", "SwiftUI", "-Xlinker", "-rpath", "-Xlinker",
        "@executable_path/../Frameworks", "-o", app / "Contents/MacOS/PopupUpdateTest")
    run("codesign", "--force", "--sign", "-", app)
    print(f"Prepared: {app}")
    print(f"Expected installed/relaunched build: {target_build} or later")
    print("Launch only the test harness above; do not launch the isolated host app.")


if __name__ == "__main__":
    main()
