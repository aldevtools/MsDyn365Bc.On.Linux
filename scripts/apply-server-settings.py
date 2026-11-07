#!/usr/bin/env python3
"""Apply BC_SERVER_SETTINGS to the service tier's CustomSettings.config (issue #218).

    apply-server-settings.py <CustomSettings.config>

BC_SERVER_SETTINGS holds Key=Value pairs, one per line or separated by ';'. Each
key's value is set, and a key the file does not have is added to <appSettings>.
Blank lines and lines starting with '#' are skipped.

/bc/service is a volume, so a value set on one boot would stay on the next. The
first time a key is changed, its original value (or that it was absent) is saved
next to the config, and every boot restores those originals before applying the
current list. Removing a key from BC_SERVER_SETTINGS therefore puts it back.
"""
import json
import os
import re
import sys
from xml.sax.saxutils import escape

KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.]*$")


def parse(raw):
    pairs = []
    for line in re.split(r"[;\n]", raw):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            sys.exit(f"ERROR: BC_SERVER_SETTINGS entry '{line}' is not Key=Value")
        key, value = (part.strip() for part in line.split("=", 1))
        if not KEY_RE.match(key):
            sys.exit(f"ERROR: BC_SERVER_SETTINGS key '{key}' is not a setting name")
        pairs.append((key, value))
    return pairs


def entry_re(key):
    return re.compile(r'<add\s+key="' + re.escape(key) + r'"\s+value="([^"]*)"\s*/>')


def read_value(text, key):
    m = entry_re(key).search(text)
    return None if m is None else m.group(1)


def write_value(text, key, value):
    """value None removes the entry. value is already XML-escaped."""
    rx = entry_re(key)
    if value is None:
        return re.sub(r'[ \t]*' + rx.pattern + r'[ \t]*\r?\n?', "", text, count=1)
    if rx.search(text):
        return rx.sub(lambda _: f'<add key="{key}" value="{value}" />', text, count=1)
    if "</appSettings>" not in text:
        sys.exit("ERROR: CustomSettings.config has no </appSettings>")
    nl = "\r\n" if "\r\n" in text else "\n"
    return text.replace("</appSettings>", f'  <add key="{key}" value="{value}" />{nl}</appSettings>', 1)


def main():
    config = sys.argv[1]
    saved_path = os.path.join(os.path.dirname(config), ".bc-server-settings-original.json")
    with open(config, "rb") as f:
        raw = f.read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")

    saved = {}
    if os.path.exists(saved_path):
        with open(saved_path) as f:
            saved = json.load(f)
    for key, original in saved.items():
        text = write_value(text, key, original)

    pairs = parse(os.environ.get("BC_SERVER_SETTINGS", ""))
    for key, value in pairs:
        if key not in saved:
            saved[key] = read_value(text, key)
        before = read_value(text, key)
        # The value goes inside value="...", so the double quote is escaped too.
        text = write_value(text, key, escape(value, {'"': "&quot;"}))
        print(f"{key} = {value}" + ("" if before is not None else " (added)"))

    # Keep only the keys still being changed; the rest are back to their originals.
    saved = {k: v for k, v in saved.items() if k in {p[0] for p in pairs}}
    with open(config, "w", encoding="utf-8-sig" if bom else "utf-8", newline="") as f:
        f.write(text)
    if saved:
        with open(saved_path, "w") as f:
            json.dump(saved, f)
    elif os.path.exists(saved_path):
        os.remove(saved_path)


if __name__ == "__main__":
    main()
