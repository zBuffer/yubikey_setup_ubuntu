import re, sys

# Only things that can CHANGE the machine or block on the user. ssh-add -L/-l
# and systemctl is-active/is-enabled/show/status are queries, not mutations.
MUTATORS = r"(confirm|confirm_typed|run_interactive|ask|apt_install|sudo)"
MUTATING_SUB = [
    (r"ssh-add", r"^ssh-add\s+(-[dDse]\b|[^-])"),
    (r"systemctl", r"^systemctl\s+(--user\s+)?(enable|disable|start|stop|restart|reload|mask|unmask|reset-failed)\b"),
    (r"ykman", r"^ykman\s+.*\b(reset|change-pin|change-puk|change-management-key|generate|import|delete)\b"),
]
REPORTS = ("check_all", "check_gcr", "piv_teleport_report", "piv_slot_report",
           "pam_report", "pcsc_holders", "pkcs11_bridges", "fido_pin_state")

def strip_strings(line):
    # Remove "..." and '...' so message text cannot look like a command.
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'[^']*'", "''", line)
    return line

s = open(sys.argv[1]).read()
bad = []
for fn in REPORTS:
    m = re.search(rf"^{fn}\(\) \{{.*?^\}}", s, re.S | re.M)
    if not m:
        continue
    for line in m.group(0).split("\n"):
        st = line.strip()
        if not st or st.startswith("#"):
            continue
        code = strip_strings(st)
        # a mutator in COMMAND position: line start, or after ; && || then else do (
        if re.search(rf"(^|[;&|(]|\b(then|else|do)\b)\s*!?\s*{MUTATORS}\b", code):
            bad.append(f"{fn}: {st[:70]}")
            continue
        for tool, pat in MUTATING_SUB:
            for seg in re.split(r"[;&|(]|\bthen\b|\belse\b|\bdo\b", code):
                seg = seg.strip().lstrip("!").strip()
                if seg.startswith(tool) and re.search(pat, seg):
                    bad.append(f"{fn}: {st[:70]}")
                    break
if bad:
    print("; ".join(bad))
    sys.exit(1)
sys.exit(0)
