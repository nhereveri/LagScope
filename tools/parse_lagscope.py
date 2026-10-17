#!/usr/bin/env python3
"""Summarize a LagScope SavedVariables file without dumping the whole thing.

Usage:
    python3 parse_lagscope.py "/path/to/WTF/Account/<account>/SavedVariables/LagScope.lua"
"""
import re
import sys
from collections import Counter, defaultdict

src = open(sys.argv[1], encoding="utf-8", errors="replace").read()


def block(key):
    """Return the text inside ["key"] = { ... }, brace balanced."""
    m = re.search(r'\["%s"\]\s*=\s*\{' % re.escape(key), src)
    if not m:
        return ""
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
    return ""


def records(text):
    """Parse an array of { ["k"] = v, ... } entries into a list of dicts."""
    out, depth, start = [], 0, None
    for j, ch in enumerate(text):
        if ch == "{":
            if depth == 0:
                start = j
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                out.append(text[start + 1:j])
    parsed = []
    for chunk in out:
        d = {}
        for k, v in re.findall(r'\["(\w+)"\]\s*=\s*([^,\n]+)', chunk):
            v = v.strip().strip('"')
            try:
                d[k] = float(v) if "." in v else int(v)
            except ValueError:
                d[k] = v
        d["_top"] = re.findall(r'"([A-Za-z0-9_!\-]+ [\d.]+ms)"', chunk)
        parsed.append(d)
    return parsed


def pairs(text):
    """Parse ["key"] = number entries (the errors table)."""
    return {k: int(v) for k, v in re.findall(r'\["([^"]+)"\]\s*=\s*(\d+)\s*,', text)}


lat = records(block("latency"))
print("=" * 70)
print("LATENCY  (%d samples)" % len(lat))
if lat:
    w = [e.get("w", 0) for e in lat]
    h = [e.get("h", 0) for e in lat]
    print("  world: min %d  median %d  max %d" % (min(w), sorted(w)[len(w)//2], max(w)))
    print("  home : min %d  median %d  max %d" % (min(h), sorted(h)[len(h)//2], max(h)))
    print("  samples with world > 400 ms: %d of %d" % (sum(1 for x in w if x > 400), len(w)))
    print("\n  every sample:")
    for e in lat:
        print("   %s  world %5d  home %4d  up %5.2f  down %6.2f KB/s  msgs %5d  (%s)"
              % (e.get("at", "?"), e.get("w", 0), e.get("h", 0), e.get("up", 0),
                 e.get("down", 0), e.get("msgs", 0), e.get("context", "?")))

print("=" * 70)
rows = []
for prefix, body in re.findall(r'\["([^"]+)"\]\s*=\s*\{(.*?)\}', block("traffic"), flags=re.S):
    c = re.search(r'\["count"\]\s*=\s*(\d+)', body)
    b = re.search(r'\["bytes"\]\s*=\s*(\d+)', body)
    rows.append((prefix, int(c.group(1)) if c else 0, int(b.group(1)) if b else 0))
rows.sort(key=lambda r: -r[2])
print("ADDON TRAFFIC SENT  (%d prefixes, %d messages, %d bytes)"
      % (len(rows), sum(r[1] for r in rows), sum(r[2] for r in rows)))
for prefix, c, b in rows[:12]:
    print("  %-20s %7d msgs %10d B" % (prefix, c, b))

print("=" * 70)
err = pairs(block("errors"))
print("LUA ERRORS  (%d total)" % sum(err.values()))
for name, n in sorted(err.items(), key=lambda kv: -kv[1])[:12]:
    print("  %-26s %5d" % (name, n))

print("=" * 70)
sp = records(block("spikes"))
print("FRAME HITCHES  (%d)" % len(sp))
if sp:
    blame, ctx = Counter(), defaultdict(int)
    for e in sp:
        for t in e["_top"][:1]:
            blame[t.rsplit(" ", 1)[0]] += 1
        ctx[e.get("context", "?")] += 1
    print("  worst frames:")
    for e in sorted(sp, key=lambda x: -x.get("frameMs", 0))[:8]:
        print("   %s %7.0f ms  lat %5d  (%s)  %s"
              % (e.get("at", "?"), e.get("frameMs", 0), e.get("latency", 0),
                 e.get("context", "?"), " | ".join(e["_top"][:2])))
    print("  led the hitch:")
    for name, n in blame.most_common(8):
        print("   %-28s %4d" % (name, n))
    print("  context:")
    for c, n in sorted(ctx.items(), key=lambda kv: -kv[1]):
        print("   %-28s %4d" % (c, n))
