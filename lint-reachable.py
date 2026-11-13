#!/usr/bin/env python3
"""Assert that key steps run unconditionally within their function.

Moving a block once left `if [[ ${newmode} != or ]]` unclosed, which quietly
nested the rest of step_pam -- including the commit -- inside it, so choosing
"password OR key" would have done nothing at all. `bash -n` cannot see that:
the file still parses. Indentation can, as long as the file is consistently
indented, which this one is.
"""
import re, sys

# (function, call that must sit at the function's own base indentation)
RULES = [
    ("step_pam",          "pam_commit "),
    ("step_pam",          "pam_stage_and_test "),
    ("step_create_key",   "configure_git "),
    ("step_piv_teleport", "piv_teleport_report"),
    ("main",              "main_menu"),
]

src = open(sys.argv[1]).read().split("\n")
bad = []
for fn, call in RULES:
    try:
        start = next(i for i, l in enumerate(src) if l.startswith(f"{fn}() {{"))
    except StopIteration:
        bad.append(f"{fn}: function not found")
        continue
    end = next(i for i in range(start + 1, len(src)) if src[i] == "}")
    hits = [(i, src[i]) for i in range(start, end) if src[i].lstrip().startswith(call)]
    if not hits:
        bad.append(f"{fn}: no call to {call.strip()}")
        continue
    if not any(len(l) - len(l.lstrip()) == 4 for _, l in hits):
        cols = sorted({len(l) - len(l.lstrip()) for _, l in hits})
        bad.append(f"{fn}: every '{call.strip()}' is nested (columns {cols}); "
                   f"expected one at column 4")

if bad:
    print("\n".join("  " + b for b in bad))
    sys.exit(1)
print("  key steps run unconditionally in their function")
