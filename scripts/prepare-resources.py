"""Assemble a bilingual bundle from the source catalogs and public resources."""
import argparse
import json
import plistlib
import re
import shutil
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
contents = args.app / "Contents"
resources = contents / "Resources"
resources.mkdir(parents=True, exist_ok=True)
project = (root / "Compositor.xcodeproj/project.pbxproj").read_text()
version = re.search(r"MARKETING_VERSION = ([^;]+);", project).group(1)
build = re.search(r"CURRENT_PROJECT_VERSION = ([^;]+);", project).group(1)
info = plistlib.loads((root / "Config/Info.plist").read_bytes())
info.update({
    "CFBundleExecutable": "Compositor",
    "CFBundleIdentifier": "com.wonderassembly.compositor.zh-Hans",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "LSMinimumSystemVersion": "26.0",
    "LSApplicationCategoryType": "public.app-category.graphics-design",
    "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True,
    "NSHumanReadableCopyright": "Compositor: Copyright © 2026 Wonder Assembly LLC. See bundled licenses.",
})
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
(contents / "PkgInfo").write_bytes(b"APPL????")
for path in (root / "Compositor/Resources").iterdir():
    if path.suffix in (".txt", ".icns"):
        shutil.copyfile(path, resources / path.name)
for name in ("Localizable", "InfoPlist"):
    catalog = json.loads((root / f"Compositor/{name}.xcstrings").read_text())
    for locale in ("en", "zh-Hans"):
        values = {
            key: entry.get("localizations", {}).get(locale, {}).get("stringUnit", {}).get("value", key)
            for key, entry in catalog["strings"].items()
        }
        if name == "InfoPlist" and locale == "en":
            values.update(CFBundleName="Compositor", CFBundleDisplayName="Compositor")
        folder = resources / f"{locale}.lproj"
        folder.mkdir(exist_ok=True)
        (folder / f"{name}.strings").write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
print(f"Prepared Compositor / 叠绘 {version} ({build})")
