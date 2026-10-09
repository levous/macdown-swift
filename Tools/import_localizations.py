#!/usr/bin/env python3
"""Imports MacDown's original translations into App/Localizable.xcstrings.

The original app localized its interface through per-language .strings files
generated from xibs (whose comments record the English source text) plus
Localizable.strings (keyed by English text). This script:

1. collects English → translation pairs for every language from those files,
2. extracts the localizable English strings used by the Swift sources, and
3. writes a String Catalog with a translation for every string that has one,
   adding the translations in Tools/port_translations.json for strings that
   are new in the port (marked as needing review: they aren't the original
   translators').

It also copies each language's Credits.rtf (shown in the About panel).

Usage:
    python3 Tools/import_localizations.py /path/to/original/macdown
"""

import collections
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "Sources" / "MacDownKit", ROOT / "App"]
CATALOG = ROOT / "App" / "Localizable.xcstrings"
CREDITS_DIR = ROOT / "App" / "Localization"
PORT_TRANSLATIONS = ROOT / "Tools" / "port_translations.json"

# Keys looked up directly (not English text).
PLURAL_KEYS = [
    "WORDS_PLURAL_STRING",
    "CHARACTERS_PLURAL_STRING",
    "CHARACTERS_NO_SPACES_PLURAL_STRING",
]

COMMENT_RE = re.compile(
    r'/\*\s*Class = "[^"]*";\s*(?P<prop>[\w.]+) = "(?P<english>(?:[^"\\]|\\.)*)";'
    r'\s*ObjectID = "(?P<oid>[^"]+)";\s*\*/\s*'
    r'"(?P<key>[^"]+)"\s*=\s*"(?P<value>(?:[^"\\]|\\.)*)";',
    re.S,
)


def read_strings(path):
    """Parses a .strings file into a dict using plutil."""
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                         capture_output=True, check=True)
    return json.loads(out.stdout)


def read_text(path):
    data = path.read_bytes()
    for encoding in ("utf-8", "utf-16"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1")


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def collect_translations(localization_dir):
    """Returns {language: {english: Counter(translation)}}."""
    result = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    for lproj in sorted(localization_dir.glob("*.lproj")):
        language = lproj.stem
        if language in ("Base", "en"):
            continue
        for strings in lproj.glob("*.strings"):
            if strings.name == "InfoPlist.strings" or strings.stat().st_size == 0:
                continue
            try:
                table = read_strings(strings)
            except subprocess.CalledProcessError:
                print(f"warning: could not parse {strings}", file=sys.stderr)
                continue
            if strings.name == "Localizable.strings":
                for key, value in table.items():
                    if value:
                        result[language][key][value] += 1
                continue
            # xib strings: English source text lives in the comments.
            for m in COMMENT_RE.finditer(read_text(strings)):
                english = unescape(m.group("english"))
                value = table.get(m.group("key"))
                if english and value and m.group("key").endswith(m.group("prop")):
                    result[language][english][value] += 1
    return result


LITERAL = r'"((?:[^"\\\n]|\\.)*)"'
PATTERNS = [
    # SwiftUI views and helpers taking a LocalizedStringKey first.
    re.compile(r'\b(?:Text|Button|Toggle|Menu|Picker|Section|LabeledContent|'
               r'CommandMenu|Label)\(\s*' + LITERAL),
    re.compile(r'String\(localized:\s*' + LITERAL),
    re.compile(r'LocalizedStringKey\(\s*' + LITERAL),
    re.compile(r'\.help\(\s*' + LITERAL),
    # Toolbar helpers: button("ToolbarIcon…", "Label") / icon(…, "Label").
    re.compile(r'\b(?:button|icon)\(\s*"[^"]*",\s*' + LITERAL),
    # Toolbar button groups: group("Label") { … }.
    re.compile(r'\bgroup\(\s*' + LITERAL),
]
# Every literal inside LocalizedStringKey(…), e.g. ternaries spanning lines.
KEY_BLOCK = re.compile(r'LocalizedStringKey\((.*?)\)\)', re.S)
MULTILINE = re.compile(r'String\(localized:\s*"""\n(.*?)\n\s*"""', re.S)


def swift_literal_to_key(literal):
    """Converts a Swift string literal body to a localization key."""
    # Interpolations become format specifiers (integers in this code base).
    key = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '%lld', literal)
    return unescape(key)


def extract_keys():
    keys = set()
    for base in SOURCES:
        for path in base.rglob("*.swift"):
            text = path.read_text()
            for pattern in PATTERNS:
                for literal in pattern.findall(text):
                    if literal and not literal.startswith(("Toolbar", "Preferences")):
                        keys.add(swift_literal_to_key(literal))
            for block in KEY_BLOCK.findall(text):
                for literal in re.findall(LITERAL, block):
                    keys.add(swift_literal_to_key(literal))
            for block in MULTILINE.findall(text):
                lines = [line.strip() for line in block.splitlines()]
                joined = ""
                for line in lines:
                    if line.endswith("\\"):
                        joined += line[:-1]
                    else:
                        joined += line + "\n"
                keys.add(unescape(joined.rstrip("\n")))
    keys.update(PLURAL_KEYS)
    return keys


def translation_for(key, table):
    if key in table:
        return table[key].most_common(1)[0][0]
    # "Header %lld" ← "Header 1" with the number generalized.
    if "%lld" in key:
        sample = key.replace("%lld", "1")
        if sample in table:
            value = table[sample].most_common(1)[0][0]
            if "1" in value:
                return value.replace("1", "%lld", 1)
    # Trailing colon / ellipsis variants.
    for variant in (key.rstrip(":"), key + ":", key.replace("…", "..."),
                    key.replace("...", "…")):
        if variant != key and variant in table:
            value = table[variant].most_common(1)[0][0]
            if key.endswith(":") and not variant.endswith(":"):
                value = value + ":"
            elif variant.endswith(":") and not key.endswith(":"):
                value = value.rstrip(":：")
            return value
    return None


def add_port_translations(strings):
    """Adds the translations of strings that are new in the port."""
    port = json.loads(PORT_TRANSLATIONS.read_text())
    for key, values in port.items():
        # Interpolated text (not integers) is %@ at runtime; extraction
        # guessed %lld.
        strings.pop(key.replace("%@", "%lld"), None)
        entry = strings.get(key) or {}
        localizations = entry.setdefault("localizations", {})
        for language, value in values.items():
            localizations.setdefault(language, {
                "stringUnit": {"state": "needs_review", "value": value}
            })
        strings[key] = entry


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    original = pathlib.Path(sys.argv[1]).resolve()
    localization_dir = original / "MacDown" / "Localization"
    translations = collect_translations(localization_dir)
    keys = sorted(extract_keys())

    english_plurals = read_strings(localization_dir / "en.lproj" / "Localizable.strings")

    strings = {}
    coverage = collections.Counter()
    for key in keys:
        entry = {"localizations": {}}
        if key in english_plurals:
            entry["localizations"]["en"] = {
                "stringUnit": {"state": "translated", "value": english_plurals[key]}
            }
        for language in sorted(translations):
            value = translation_for(key, translations[language])
            if value is not None:
                entry["localizations"][language] = {
                    "stringUnit": {"state": "translated", "value": value}
                }
                coverage[language] += 1
        if not entry["localizations"]:
            entry = {}
        strings[key] = entry
    add_port_translations(strings)

    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2,
                                  sort_keys=True) + "\n")

    # Credits shown in the About panel.
    if CREDITS_DIR.exists():
        shutil.rmtree(CREDITS_DIR)
    for credits in sorted(localization_dir.glob("*.lproj/Credits.rtf")):
        target = CREDITS_DIR / credits.parent.name / "Credits.rtf"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(credits, target)

    print(f"{len(keys)} strings written to {CATALOG.relative_to(ROOT)}")
    for language in sorted(translations):
        print(f"  {language:8} {coverage[language]:4} translated")


if __name__ == "__main__":
    main()
