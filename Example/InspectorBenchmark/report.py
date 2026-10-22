"""Median of every metric over the runs with and without SWIFTUI_VIEW_DEBUG (min–max in brackets)."""
import json
import statistics
import sys

rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip().startswith("{")]
on = [r["metrics"] for r in rows if r["meta"]["SWIFTUI_VIEW_DEBUG"]]
off = [r["metrics"] for r in rows if not r["meta"]["SWIFTUI_VIEW_DEBUG"]]
meta = rows[0]["meta"]
print(f"{meta['device']}, iOS {meta['os']}: {len(off)} runs without, {len(on)} runs with SWIFTUI_VIEW_DEBUG")
print(f"{'metric':26} {'without':>24} {'with':>26} {'Δ':>9} {'Δ%':>6}")
for key in sorted(set().union(*[m.keys() for m in on + off])):
    a = [m[key] for m in off if key in m]
    b = [m[key] for m in on if key in m]
    if not a or not b:
        continue
    ma, mb = statistics.median(a), statistics.median(b)
    pct = f"{(mb - ma) / ma * 100:5.0f}%" if ma else "     –"
    cell = lambda m, xs: f"{m:8.1f} ({min(xs):.1f}–{max(xs):.1f})"
    print(f"{key:26} {cell(ma, a):>24} {cell(mb, b):>26} {mb - ma:9.1f} {pct}")
