#!/usr/bin/env python3
"""Flag a variable that is written in a function BEFORE its own `local`.

bash creates the local at the point the `local` runs, so an earlier write in
the same function lands on the global and is then shadowed by an empty local.
That silently discarded a user's choice once already (the `vendor` bug).
"""
import re, sys

src = open(sys.argv[1]).read().split("\n")
bad = []
fn = None
start = 0
body = []

def check(fn, start, body):
    locals_at = {}
    writes_at = {}
    for off, line in enumerate(body):
        st = line.strip()
        if st.startswith("#"):
            continue
        m = re.match(r"local\s+(.*)", st)
        if m:
            for decl in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)(?:=|\b)", m.group(1)):
                locals_at.setdefault(decl, off)
            continue
        for w in re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\+?=", st):
            writes_at.setdefault(w, off)
    for name, loff in locals_at.items():
        woff = writes_at.get(name)
        if woff is not None and woff < loff:
            bad.append(f"{fn}: '{name}' written at line {start+woff+1} "
                       f"but declared local at line {start+loff+1}")

for i, line in enumerate(src):
    m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\) \{", line)
    if m:
        fn, start, body = m.group(1), i + 1, []
        continue
    if fn is not None:
        if line == "}":
            check(fn, start, body)
            fn = None
        else:
            body.append(line)

if bad:
    print("\n".join("  " + b for b in bad))
    sys.exit(1)
print("  no variable is written before its own local")
