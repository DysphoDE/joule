#!/usr/bin/env python3
"""Extracts every localizable string from the sources (via the Swift compiler),
checks it against Localization/translations.json and writes Resources/<lang>.lproj.

Source strings are German. Exits non-zero when a translation is missing or its
placeholders do not match, so a build never ships half-translated text.
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGUAGES = ["en", "fr", "es"]
# Keys that read the same in every language: units, names, pure placeholders.
IDENTICAL = {"", "%", "%/h", "%@", "%@ %%", "%@ %@", "%@ Wh", "%@ · %@", "%@ → %@ %%", "%lld", "%lld %%",
             "–", "−%@ %%", "W", "Wh", "Joule", "macOS", "App", "Apps", "Tool", "GPU %@"}
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld|%)")
POSITION = re.compile(r"%\d+\$")


def extract(out):
    subprocess.run(["swift", "build", "--product", "Joule"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    products = os.path.join(ROOT, ".build/out/Products/Debug")
    if not os.path.isdir(products):
        products = os.path.join(ROOT, ".build/debug/Modules")
    obj = os.path.join(out, "obj")
    os.makedirs(obj)
    for module, sources, extra in [("JouleCore", "Sources/JouleCore/*.swift", []),
                                   ("Joule", "Sources/Joule/*.swift", ["-I", products])]:
        files = sorted(glob.glob(os.path.join(ROOT, sources)))
        subprocess.run(["xcrun", "swiftc", "-c", "-parse-as-library", "-wmo", "-module-name", module, *extra,
                        "-emit-localized-strings", "-emit-localized-strings-path", out, *files,
                        "-o", os.path.join(obj, module + ".o")], cwd=ROOT, check=True)
    keys = set()
    for path in glob.glob(os.path.join(out, "*.stringsdata")):
        for items in json.load(open(path))["tables"].values():
            keys.update(item["key"] for item in items)
    return keys


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main():
    with tempfile.TemporaryDirectory() as tmp:
        keys = extract(tmp)
    table = json.load(open(os.path.join(ROOT, "Localization/translations.json")))
    problems = []
    for key in sorted(keys):
        if key in IDENTICAL:
            continue
        if key not in table:
            problems.append(f"fehlt: {key!r}")
            continue
        expected = sorted(PLACEHOLDER.findall(key))
        for lang, value in zip(LANGUAGES, table[key]):
            # "%2$@" and "%@" are the same placeholder in another position.
            if sorted(POSITION.sub("%", p) for p in PLACEHOLDER.findall(value)) != expected:
                problems.append(f"Platzhalter {lang}: {key!r} → {value!r}")
    unused = sorted(set(table) - keys)
    for key in unused:
        print(f"unbenutzt: {key!r}")
    if problems:
        print("\n".join(problems))
        sys.exit(1)

    for index, lang in enumerate(["de", *LANGUAGES]):
        folder = os.path.join(ROOT, "Resources", f"{lang}.lproj")
        os.makedirs(folder, exist_ok=True)
        lines = []
        for key in sorted(keys):
            value = key if lang == "de" or key in IDENTICAL else table[key][index - 1]
            lines.append(f'"{escape(key)}" = "{escape(value)}";')
        with open(os.path.join(folder, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    print(f"{len(keys)} Schlüssel, Sprachen: de, {', '.join(LANGUAGES)}")


if __name__ == "__main__":
    main()
