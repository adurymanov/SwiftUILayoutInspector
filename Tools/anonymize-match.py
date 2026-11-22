#!/usr/bin/env python3
"""Anonymize a matching recording (LAYOUT_INSPECTOR_MATCH_DUMP) so it can be kept as a test fixture.

usage: anonymize-match.py IN.json OUT.json

Type names become T1, T2…, texts and strings s1, s2… (the same name or string gets the same token everywhere), and
the host descriptions are dropped. Boxes, nesting and hosts stay: they are what the matching reads.
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = json.load(open(sys.argv[1]))
    types, strings = {}, {}

    def type_token(name):
        return types.setdefault(name, f"T{len(types) + 1}")

    def string_token(value):
        return strings.setdefault(value, f"s{len(strings) + 1}")

    data_in = data["input"]
    for view in data_in["views"]:
        view["type"] = type_token(view["type"])
        if view.get("strings") is not None:
            view["strings"] = sorted(string_token(s) for s in view["strings"])
    for component in data_in["components"]:
        component["type"] = type_token(component["type"])
        component["texts"] = sorted(string_token(s) for s in component["texts"])
    data["hosts"] = [{"type": "Host", "frame": h["frame"], "hidden": h["hidden"], "alpha": h["alpha"], "chain": []}
                     for h in data.get("hosts", [])]
    json.dump(data, open(sys.argv[2], "w"), sort_keys=True, separators=(",", ":"))


if __name__ == "__main__":
    main()
