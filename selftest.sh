#!/usr/bin/env bash
# Regression harness for yubikey-git-signing.sh.
#
# Every check here corresponds to a defect found by a review round. Run it after
# each change: a round of fixes is only done when this still passes.
#
# Read-only. Nothing here touches /etc, apt, systemd, gpg keyrings or the YubiKey.

set -uo pipefail

SCRIPT=${1:-./yubikey-git-signing.sh}
[[ -f ${SCRIPT} ]] || { printf 'no such script: %s\n' "${SCRIPT}" >&2; exit 2; }
SCRIPT=$(readlink -f "${SCRIPT}")
WORK=$(mktemp -d) || exit 2
trap 'rm -rf "${WORK}"' EXIT

PASS=0 FAIL=0
# (( x++ )) returns 1 when x was 0, so these must end with an explicit status
# or 'ok ... || no ...' fires the failure branch on the very first check.
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$(( PASS + 1 )); return 0; }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n ${2:-} ]] && printf '        %s\n' "$2"; FAIL=$(( FAIL + 1 )); return 0; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# Pull named functions out of the script into a sourceable stub file.
stub() {
    local out=$1; shift
    {
        printf 'set -uo pipefail\n'
        printf 'PLAIN=0; MENU_INDEX=-1; IN_ALT=0; TTY_TOUCHED=0\n'
        printf 'ACCENT=""; MUTED=""; BOLD=""; RESET=""; TITLE=""; WARNC=""; OKC=""; ERRC=""\n'
        printf 'G_PTR=">"; G_H="-"; G_DOT="."; G_OK="+"; G_BAD="x"; G_WARN="!"; G_ARROW=">"\n'
        printf 'ALT_ON=""; ALT_OFF=""; HIDE_CUR=""; SHOW_CUR=""\n'
        printf 'FAIL_COUNT=0; WARN_COUNT=0\n'
        printf 'PAM_MAP_DEFAULT="/etc/u2f_mappings"; PAM_MARKER="# managed"\n'
        printf 'PAM_VENDOR_DIR="${PAM_VENDOR_DIR:-/usr/lib/pam.d}"\n'
        printf 'ok(){ :; }; bad(){ :; }; info(){ :; }; note(){ :; }; warn(){ :; }\n'
        printf 'blank(){ printf "\\n"; }; hint(){ :; }; rwarn(){ :; }\n'
        printf 'banner(){ printf "B\\n%%.0s" 1 2 3 4 5 6; }\n'
        printf 'term_width(){ printf 80; }\n'
        printf 'repeat_char(){ printf ""; }\n'
        printf 'enter_alt(){ :; }; leave_alt(){ :; }\n'
        local fn
        for fn in "$@"; do
            sed -n "/^${fn}() {/,/^}/p" "${SCRIPT}"
        done
    } > "${out}"
}

# ---------------------------------------------------------------- CLI contract
group "CLI contract"
bash -n "${SCRIPT}" && ok "bash -n parses" || no "bash -n parses"
"${SCRIPT}" --version >/dev/null 2>&1 && ok "--version exits 0" || no "--version exits 0"
"${SCRIPT}" --help    >/dev/null 2>&1 && ok "--help exits 0"    || no "--help exits 0"
"${SCRIPT}" --bogus   >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "bad option exits 2" || no "bad option exits 2"
"${SCRIPT}" --check   >/dev/null 2>&1; rc=$?
[[ ${rc} -eq 0 || ${rc} -eq 1 ]] && ok "--check exits 0 or 1 (got ${rc})" || no "--check exit code" "got ${rc}"

n=$("${SCRIPT}" --check 2>&1 | cat -v | grep -c '\^\[')
(( n == 0 )) && ok "piped --check emits no ANSI escapes" || no "piped --check emits no ANSI escapes" "${n} found"

# --------------------------------------------------------------- menu wiring
group "Menu wiring"
python3 - "${SCRIPT}" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
b = re.search(r"main_menu\(\) \{.*?\n\}", s, re.S).group(0)
L = [l for l in re.findall(r'^\s+"([^"]*)"(?: \\| \|\| return 0)$', b, re.M)
     if l != "What would you like to do?"]
sel = [l for l in L if not l.startswith("--")]
arms = re.findall(r'^\s+(\d+)\)', b, re.M)
sys.exit(0 if len(sel) == len(arms) and [str(i) for i in range(len(sel))] == arms else 1)
PY
[[ $? -eq 0 ]] && ok "menu indices match the case arms" || no "menu indices match the case arms"

stub "${WORK}/menu.sh" ui_menu term_height
cat >> "${WORK}/menu.sh" <<'EOF'
OPTS=("Guided setup" "-- Set up" "Install tools" "Set the PIN" "Create the key"
      "Enrol on GitHub" "Install askpass" "-- Already have a key" "Reimport"
      "-- Check and repair" "Dependency check" "Fix agent interception"
      "-- Same key, other uses" "PIV for Teleport" "sudo and login" "--" "Quit")
SEL=(); for o in "${OPTS[@]}"; do [[ $o == --* ]] || SEL+=("$o"); done
term_height(){ printf '%s' "${ROWS:-40}"; }
ui_menu "t" "${OPTS[@]}" > "${OUT:-/dev/null}"
printf 'IDX=%s LABEL=%s\n' "${MENU_INDEX}" "${SEL[${MENU_INDEX}]:-NONE}"
EOF

nav() { printf '%b' "$1" | timeout 20 script -qec "ROWS=${2:-40} OUT=${3:-/dev/null} bash ${WORK}/menu.sh" /dev/null 2>/dev/null | grep -a '^IDX=' | tr -d '\r'; }

[[ $(nav '\n') == "IDX=0 LABEL=Guided setup" ]] && ok "Enter selects the first item" || no "Enter selects the first item" "$(nav '\n')"
[[ $(nav 'jj\n') == "IDX=2 LABEL=Set the PIN" ]] && ok "j steps over headings" || no "j steps over headings" "$(nav 'jj\n')"
[[ $(nav 'k\n') == "IDX=11 LABEL=Quit" ]] && ok "k from the top wraps to the end" || no "k wraps" "$(nav 'k\n')"
[[ -z $(nav '\033[1;5A') ]] && ok "Ctrl+Up selects nothing" || no "Ctrl+Up selects nothing" "$(nav '\033[1;5A')"
[[ -z $(nav '\033[15~') ]]  && ok "F5 selects nothing"      || no "F5 selects nothing" "$(nav '\033[15~')"
[[ $(nav '\033[B\n') == "IDX=1 LABEL=Install tools" ]] && ok "Down arrow still works" || no "Down arrow still works"

for rows in 16 20 24 30 40; do
  nav '\n' "${rows}" "${WORK}/frame.${rows}" >/dev/null
  lines=$(wc -l < "${WORK}/frame.${rows}" 2>/dev/null || echo 999)
  ptr=$(grep -c '>' "${WORK}/frame.${rows}" 2>/dev/null || echo 0)
  if (( lines <= rows && ptr > 0 )); then ok "menu fits ${rows} rows with the pointer visible (${lines} lines)"
  else no "menu fits ${rows} rows" "${lines} lines, pointer hits ${ptr}"; fi
done

# --------------------------------------------------- plain-mode input handling
group "Plain-mode input"
stub "${WORK}/plain.sh" ui_menu term_height
sed -i 's/^PLAIN=0;/PLAIN=1;/' "${WORK}/plain.sh"
cat >> "${WORK}/plain.sh" <<'EOF'
OPTS=("one" "-- h" "two" "three")
if ui_menu "t" "${OPTS[@]}" >/dev/null 2>&1; then printf 'ACCEPT=%s\n' "$MENU_INDEX"
else printf 'QUIT\n'; fi
printf 'ALIVE\n'
EOF
p() { printf '%b' "$1" | timeout 10 bash "${WORK}/plain.sh" 2>/dev/null | tr '\n' ' '; }
[[ $(p 'abc\n2\n')  == *"ACCEPT=1"*"ALIVE"* ]] && ok "letters re-prompt"          || no "letters re-prompt" "$(p 'abc\n2\n')"
[[ $(p '08\n2\n')   == *"ACCEPT=1"*"ALIVE"* ]] && ok "08 re-prompts, no abort"    || no "08 re-prompts" "$(p '08\n2\n')"
[[ $(p '99\n1\n')   == *"ACCEPT=0"*"ALIVE"* ]] && ok "out of range re-prompts"    || no "out of range re-prompts" "$(p '99\n1\n')"
[[ $(p '\n\n3\n')   == *"ACCEPT=2"*"ALIVE"* ]] && ok "empty line re-prompts"      || no "empty line re-prompts" "$(p '\n\n3\n')"
[[ $(p 'q\n')       == *"QUIT"*"ALIVE"*     ]] && ok "only q quits"               || no "only q quits" "$(p 'q\n')"

# ------------------------------------------------------------ key backup logic
group "Key backup and abort"
stub "${WORK}/bk.sh" backup_existing_key backup_commit restore_backup restore_term abort_cleanup
cat >> "${WORK}/bk.sh" <<'EOF'
KEY_PRIV="$1/key"; KEY_PUB="$1/key.pub"; BACKUP_PRIV=""; BACKUP_PUB=""
trap 'abort_cleanup; restore_term' EXIT
trap 'abort_cleanup; restore_term; exit 130' INT TERM
printf 'OLD\n' > "$KEY_PRIV"; printf 'OLDP\n' > "$KEY_PUB"
backup_existing_key
case "$2" in
  success) printf 'NEW\n' > "$KEY_PRIV"; printf 'NEWP\n' > "$KEY_PUB"; backup_commit ;;
  abort)   kill -INT $$; sleep 5 ;;
esac
EOF
for mode in success abort; do
  d="${WORK}/bk-${mode}"; mkdir -p "${d}"
  bash "${WORK}/bk.sh" "${d}" "${mode}" >/dev/null 2>&1
  got=$(cat "${d}/key" 2>/dev/null || echo MISSING)
  case "${mode}:${got}" in
    success:NEW) ok "successful keygen keeps the new key" ;;
    abort:OLD)   ok "abort restores the previous key" ;;
    *)           no "backup ${mode}" "key contains ${got}" ;;
  esac
done

# ---------------------------------------------------------- archive containment
group "Archive link containment"
stub "${WORK}/ct.sh"
cat >> "${WORK}/ct.sh" <<'EOF'
contain() {
  local staging=$1 l target bad_link=""
  while IFS= read -r l; do
    [[ -z ${l} ]] && continue
    target=$(realpath -m -- "${l}" 2>/dev/null) || target=""
    case ${target} in "${staging}"|"${staging}"/*) ;; *) bad_link=${l}; break ;; esac
  done < <(find "${staging}" -type l 2>/dev/null)
  [[ -n ${bad_link} ]] && return 1
  return 0
}
EOF
mkdir -p "${WORK}/b/top/sub"
( cd "${WORK}/b" || exit
  : > top/authenticator; chmod +x top/authenticator
  ln -sf './../../../../../../bin/true' top/e1
  ln -sf '..'                           top/e2
  ln -sf 'a/../../..'                   top/e3
  ln -sf '/etc/passwd'                  top/e4
  ln -sf '../authenticator'             top/sub/legit
  for n in e1 e2 e3 e4; do tar czf "${WORK}/${n}.tgz" top/authenticator "top/${n}" 2>/dev/null; done
  tar czf "${WORK}/legit.tgz" top/authenticator top/sub/legit 2>/dev/null )
for a in e1 e2 e3 e4; do
  st=$(mktemp -d); tar xzf "${WORK}/${a}.tgz" -C "${st}" --strip-components=1 2>/dev/null
  bash -c "source '${WORK}/ct.sh'; contain '${st}'" && no "escaping link ${a} refused" || ok "escaping link ${a} refused"
  rm -rf "${st}"
done
st=$(mktemp -d); tar xzf "${WORK}/legit.tgz" -C "${st}" --strip-components=1 2>/dev/null
bash -c "source '${WORK}/ct.sh'; contain '${st}'" && ok "in-archive relative link accepted" || no "in-archive relative link accepted"
rm -rf "${st}"

# --------------------------------------------------------------- PAM parsing
group "PAM stanza parsing"
stub "${WORK}/pam.sh" pam_u2f_line pam_map_file pam_map_entries pam_current_opts pam_detect_mode pam_mode_label pam_stanza pam_map_merge expand_tilde
printf 'auth sufficient pam_u2f.so authfile=/etc/u2f_mappings cue\n' > "${WORK}/st-or"
printf 'auth required pam_u2f.so authfile=/etc/u2f_mappings cue\n'   > "${WORK}/st-and"
printf 'auth sufficient pam_u2f.so authfile=/x cue\nauth required pam_deny.so\n' > "${WORK}/st-key"
printf 'auth [success=1 default=ignore] pam_u2f.so nouserok\n'       > "${WORK}/st-cust"
printf 'auth\tsufficient\tpam_u2f.so\tauthfile=/etc/m\tcue\n'        > "${WORK}/st-tab"
printf 'auth sufficient pam_u2f.so\n'                                 > "${WORK}/st-bare"
printf '#auth sufficient pam_u2f.so authfile=/old cue\nauth required pam_u2f.so cue\n' > "${WORK}/st-cmt"
pm() { bash -c "source '${WORK}/pam.sh'; PAM_U2F_FILE='${WORK}/$1'; $2"; }
for pair in "st-or:or" "st-and:and" "st-key:keyonly" "st-cust:custom"; do
  f=${pair%%:*}; want=${pair##*:}
  [[ $(pm "${f}" pam_detect_mode) == "${want}" ]] && ok "detect ${want}" || no "detect ${want}" "$(pm "${f}" pam_detect_mode)"
done
[[ $(pm nope pam_detect_mode) == none ]] && ok "detect none (absent file)" || no "detect none"
[[ $(pm st-tab pam_map_file) == /etc/m ]] && ok "tab-separated authfile parses" || no "tab-separated authfile" "$(pm st-tab pam_map_file)"
[[ $(pm st-bare pam_current_opts) == "" ]] && ok "option-less stanza yields no options" || no "option-less stanza" "[$(pm st-bare pam_current_opts)]"
[[ $(pm st-cmt pam_current_opts) == "cue" ]] && ok "commented line ignored" || no "commented line ignored" "[$(pm st-cmt pam_current_opts)]"

printf 'alice:c1\nbob:c2\n' > "${WORK}/map"
out=$(bash -c "source '${WORK}/pam.sh'; pam_map_merge '${WORK}/map' alice cNEW" 2>/dev/null)
[[ $(grep -c . <<<"${out}") -eq 2 && ${out} == *"alice:c1:cNEW"* && ${out} == *"bob:c2"* ]] \
  && ok "merge extends the user's line and keeps others" || no "merge extends the line" "${out}"
chmod 000 "${WORK}/map"
bash -c "source '${WORK}/pam.sh'; pam_map_merge '${WORK}/map' x y" >/dev/null 2>&1 \
  && no "unreadable map refused" || ok "unreadable map refused"
chmod 644 "${WORK}/map"

[[ $(bash -c "source '${WORK}/pam.sh'; HOME=/h expand_tilde '~/a'") == /h/a ]] && ok "expand_tilde expands ~/" || no "expand_tilde expands ~/"
[[ $(bash -c "source '${WORK}/pam.sh'; HOME=/h expand_tilde '/abs'") == /abs ]] && ok "expand_tilde leaves absolute paths" || no "expand_tilde absolute"

# ------------------------------------------------------------- FIDO PIN states
group "FIDO2 PIN states"
stub "${WORK}/pin.sh" fido_pin_state
cat >> "${WORK}/pin.sh" <<'EOF'
YKMAN=stub
ykman() { printf '%s\n' "${FAKE}"; }
EOF
pin() { FAKE="$1" bash -c "source '${WORK}/pin.sh'; YKMAN=ykman; fido_pin_state" 2>/dev/null; }
for pair in "PIN: 8 attempt(s) remaining:set 8" "PIN: Not set:unset -" "PIN: Blocked:blocked 0" \
            "PIN: Disabled:disabled -" "PIN: Not supported:unsupported -"; do
  in=${pair%:*}; want=${pair##*:}
  [[ $(pin "${in}") == "${want}" ]] && ok "PIN state: ${in}" || no "PIN state: ${in}" "got [$(pin "${in}")]"
done
[[ $(pin "$(printf 'PIN: 5 attempt(s) remaining\nPIN is temporarily blocked.')") == "tempblocked -" ]] \
  && ok "PIN state: temporarily blocked" || no "PIN state: temporarily blocked"
[[ $(pin "$(printf 'PIN: 8 attempt(s) remaining\nNOTE: The FIDO PIN must be changed')") == "mustchange -" ]] \
  && ok "PIN state: must be changed" || no "PIN state: must be changed"

# ------------------------------------------------------ escape-key handling
group "Escape sequences"
stub "${WORK}/esc.sh" ui_menu term_height
cat >> "${WORK}/esc.sh" <<'EOF'
term_height(){ printf 40; }
OPTS=("one" "-- h" "two" "three" "four")
SEL=(); for o in "${OPTS[@]}"; do [[ $o == --* ]] || SEL+=("$o"); done
if ui_menu "t" "${OPTS[@]}" >/dev/null 2>&1; then printf 'SELECT %s
' "${SEL[$MENU_INDEX]}" > "$RES"
else printf 'CANCELLED
' > "$RES"; fi
EOF
# Hold stdin open briefly after the keys: 'script' tears the session down at
# EOF, which can kill the stub before it writes its result file. Without this
# the bare-ESC check passes or fails at random.
esc() {
    : > "${WORK}/res"
    { printf '%b' "$1"; sleep 0.6; } \
        | timeout 15 script -qec "RES=${WORK}/res bash ${WORK}/esc.sh" /dev/null >/dev/null 2>&1
    tr -d '\r' < "${WORK}/res"
}
check_esc() {
    local label=$1 keys=$2 want=$3 got
    got=$(esc "${keys}")
    [[ ${got} == "${want}" ]] && ok "${label}" || no "${label}" "got [${got}] want [${want}]"
}
check_esc "Enter selects"                    '\n'          "SELECT one"
check_esc "Down arrow moves"                 '\033[B\n'    "SELECT two"
check_esc "Alt+j ignored, next key survives" '\033j\n'     "SELECT one"
check_esc "bare ESC cancels"                 '\033'        "CANCELLED"
check_esc "q cancels"                        'q'           "CANCELLED"
check_esc "Ctrl+Up ignored"                  '\033[1;5A\n' "SELECT one"
check_esc "F5 ignored"                       '\033[15~\n'  "SELECT one"
check_esc "jj navigates past a heading"      'jj\n'        "SELECT three"
check_esc "Alt+Space does not cancel"        '\033 \n'      "SELECT one"
check_esc "Alt+Enter does not cancel"        '\033\n\n'     "SELECT one"

# ---------------------------------------------------- PAM config resolution
group "PAM service source"
stub "${WORK}/src.sh" pam_service_source
src() { PAM_DIR="$1" bash -c "source '${WORK}/src.sh'; PAM_DIR='$1'; pam_service_source '$2'"; }
mkdir -p "${WORK}/etcpam"; printf '@include common-auth
' > "${WORK}/etcpam/sudo"
[[ $(src "${WORK}/etcpam" sudo) == "${WORK}/etcpam/sudo" ]] && ok "an /etc file wins" || no "an /etc file wins"
if [[ -f /usr/lib/pam.d/polkit-1 ]]; then
  [[ $(src "${WORK}/etcpam" polkit-1) == /usr/lib/pam.d/polkit-1 ]] \
    && ok "vendor file found when /etc has none (polkit-1)" || no "vendor file found"
else
  ok "no vendor polkit-1 on this system (skipped)"
fi
[[ $(src "${WORK}/etcpam" no-such-svc) == other ]] && ok "falls back to 'other' only when neither exists" || no "other fallback"

# ------------------------------------------------- PAM include insertion sed
group "PAM include insertion"
d="${WORK}/ins"; mkdir -p "${d}"
printf '@include common-auth
@include common-account
'      > "${d}/plain"
printf '  @include common-auth  
@include common-account
'  > "${d}/spaced"
ins() {
  grep -qE '^[[:space:]]*@include[[:space:]]+common-u2f[[:space:]]*$' "$1" && return 0
  sed -i -E '0,/^[[:space:]]*@include[[:space:]]+common-auth[[:space:]]*$/s//@include common-u2f\n&/' "$1"
}
ins "${d}/plain";  ins "${d}/plain"
ins "${d}/spaced"; ins "${d}/spaced"
[[ $(grep -c 'common-u2f' "${d}/plain")  -eq 1 ]] && ok "exact include line: inserted once"   || no "exact include line"
[[ $(grep -c 'common-u2f' "${d}/spaced") -eq 1 ]] && ok "indented include line: inserted once" || no "indented include line"
[[ $(head -1 "${d}/plain") == "@include common-u2f" ]] && ok "inserted before common-auth" || no "inserted before common-auth"

# ------------------------------------------------------- PAM coverage logic
group "PAM coverage decision"
stub "${WORK}/cov.sh" pam_service_includes pam_core_covered pam_core_uncovered pam_has_anchor pam_includers
cat >> "${WORK}/cov.sh" <<'EOF'
PAM_CORE_SERVICES="sudo sudo-i login gdm-password"
EOF
mkpam() {
  local d=$1; shift; rm -rf "${d}"; mkdir -p "${d}"
  local svc
  for svc in sudo sudo-i login gdm-password cron other; do
    printf '@include common-auth
@include common-account
' > "${d}/${svc}"
  done
  for svc in "$@"; do
    printf '@include common-u2f
@include common-auth
' > "${d}/${svc}"
  done
}
cov() { PAM_DIR="$1" bash -c "source '${WORK}/cov.sh'; PAM_DIR='$1'; $2"; }

mkpam "${WORK}/p-none"
[[ -z $(cov "${WORK}/p-none" pam_core_covered) ]] && ok "fresh machine: no core service covered" || no "fresh machine covered"
[[ $(cov "${WORK}/p-none" pam_core_uncovered) == "sudo sudo-i login gdm-password " ]]   && ok "fresh machine: all four need wiring" || no "fresh machine uncovered" "$(cov "${WORK}/p-none" pam_core_uncovered)"

mkpam "${WORK}/p-part" sudo
[[ $(cov "${WORK}/p-part" pam_core_covered) == "sudo " ]] && ok "partial: sudo reported covered" || no "partial covered"
[[ $(cov "${WORK}/p-part" pam_core_uncovered) == "sudo-i login gdm-password " ]]   && ok "partial: the other three still need wiring" || no "partial uncovered" "$(cov "${WORK}/p-part" pam_core_uncovered)"

# the case the round-2 guard got wrong: only NON-core services include it
mkpam "${WORK}/p-noncore" cron other
[[ -z $(cov "${WORK}/p-noncore" pam_core_covered) ]]   && ok "non-core includers do not count as coverage" || no "non-core counted as coverage"

mkpam "${WORK}/p-all" sudo sudo-i login gdm-password
[[ -z $(cov "${WORK}/p-all" pam_core_uncovered) ]] && ok "fully wired: nothing left to add" || no "fully wired"

# a comment and a backup file must not be mistaken for a real include
mkpam "${WORK}/p-cmt"
printf '#@include common-u2f
@include common-auth
' > "${WORK}/p-cmt/sudo"
printf '@include common-u2f
' > "${WORK}/p-cmt/sudo~"
[[ -z $(cov "${WORK}/p-cmt" pam_core_covered) ]] && ok "commented include does not count" || no "commented include counted"
[[ $(cov "${WORK}/p-cmt" pam_includers) != *"sudo~"* ]] && ok "editor backup not listed as an includer" || no "backup listed"

# an existing file with no common-auth anchor must be refused, not silently skipped
stub "${WORK}/anch.sh" pam_service_source pam_source_has_anchor
mkdir -p "${WORK}/p-anch" "${WORK}/p-anch-vendor"
printf 'auth required pam_unix.so\n' > "${WORK}/p-anch/polkit-1"
# point the vendor dir at an empty sandbox too, or the REAL
# /usr/lib/pam.d/polkit-1 is found and the "no file anywhere" case is untestable
mkdir -p "${WORK}/novendor"
anch() { bash -c "source '${WORK}/anch.sh'; PAM_DIR='$1'; PAM_VENDOR_DIR='${2:-${WORK}/novendor}'; pam_source_has_anchor polkit-1"; }
anch "${WORK}/p-anch" && no "anchor-less polkit-1 reported as anchorable" \
    || ok "anchor-less polkit-1 correctly refused"
printf '@include common-auth\n' > "${WORK}/p-anch/polkit-1"
anch "${WORK}/p-anch" && ok "polkit-1 with an anchor is accepted" || no "anchored polkit-1 refused"
anch "${WORK}/p-anch-vendor" && no "missing polkit-1 reported as anchorable" \
    || ok "a service with no file at all is refused"
# and the vendor file IS consulted when /etc has none
mkdir -p "${WORK}/vend"; printf '@include common-auth\n' > "${WORK}/vend/polkit-1"
anch "${WORK}/p-anch-vendor" "${WORK}/vend" && ok "an anchored vendor file is accepted" \
    || no "anchored vendor file refused"

# merging into a mapping file with no trailing newline must not glue lines together
printf 'bob:aaa,bbb,es256,+presence' > "${WORK}/nonl"
out=$(bash -c "source '${WORK}/pam.sh'; pam_map_merge '${WORK}/nonl' lance 'ccc,ddd'" 2>/dev/null)
[[ $(grep -c . <<<"${out}") -eq 2 && ${out} == *"bob:aaa,bbb,es256,+presence"* ]] \
    && ok "merge into a file with no final newline keeps the lines separate" \
    || no "merge glued the new entry onto the previous line" "${out}"

printf 'no anchor here
' > "${WORK}/p-none/gdm-password"
cov "${WORK}/p-none" "pam_has_anchor gdm-password" && no "missing anchor detected" || ok "missing anchor detected"
cov "${WORK}/p-none" "pam_has_anchor sudo" && ok "present anchor detected" || no "present anchor detected"

# ------------------------------------------- read-only report purity
group "Read-only reports stay read-only"
# --check calls these. A prompt or a mutating command in one of them means the
# read-only report can change the machine. (This nearly happened once: a PIV
# reset offer was moved into piv_teleport_report by mistake.)
if python3 "$(dirname "${SCRIPT}")/purity-check.py" "${SCRIPT}" >"${WORK}/purity" 2>&1; then
    ok "no prompts or mutations inside the --check reports"
else
    no "report functions prompt or mutate" "$(cat "${WORK}/purity")"
fi

# ----------------------------------------------- firmware capability
group "PIV firmware capability"
stub "${WORK}/fw.sh" piv_reports_defaults ver_at_least
fw() { bash -c "source '${WORK}/fw.sh'; piv_reports_defaults 'PIV version:              $1' && echo yes || echo no"; }
[[ $(fw 5.8.0) == yes ]] && ok "5.8.0 can report the defaults"  || no "5.8.0 capability"
[[ $(fw 5.3.0) == yes ]] && ok "5.3.0 can report the defaults"  || no "5.3.0 capability"
[[ $(fw 5.2.7) == no  ]] && ok "5.2.7 cannot (no reset offered)" || no "5.2.7 capability"
[[ $(fw 4.3.1) == no  ]] && ok "4.3.1 cannot"                    || no "4.3.1 capability"
[[ $(bash -c "source '${WORK}/fw.sh'; piv_reports_defaults '' && echo yes || echo no") == no ]] \
    && ok "empty ykman output is not treated as capable" || no "empty output capability"

# the stale-library marker must match the FILE name, not a directory in the path
stale() { printf '%s\n' "$1" | grep -qE '/[^/ ]*(opensc|pkcs11|pcsclite)[^/ ]* \(deleted\)$'; }
stale '/usr/lib/x86_64-linux-gnu/pkcs11/p11-kit-trust.so (deleted)' \
    && no "a pkcs11/ DIRECTORY marks a process stale" || ok "pkcs11/ in the path does not mark a process stale"
stale '/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so (deleted)' \
    && ok "a deleted opensc-pkcs11.so does mark it stale" || no "opensc-pkcs11.so not detected"
stale '/memfd:pulseaudio (deleted)' \
    && no "an unrelated deleted mapping marks it stale" || ok "unrelated deleted mappings ignored"

# ------------------------------------------------------ small helpers
group "Helpers"
stub "${WORK}/help.sh" ver_at_least ya_arch pub_blob pub_application update_allowed_signers
v() { bash -c "source '${WORK}/help.sh'; ver_at_least '$1' '$2' && echo yes || echo no"; }
[[ $(v 2.4.1 2.4.1) == yes ]] && ok "ver_at_least: equal versions"            || no "ver_at_least equal"
[[ $(v 2.4.2 2.4.1) == yes ]] && ok "ver_at_least: newer passes"              || no "ver_at_least newer"
[[ $(v 2.4.0 2.4.1) == no  ]] && ok "ver_at_least: older fails"               || no "ver_at_least older"
[[ $(v 1.8.24 2.4.1) == no ]] && ok "ver_at_least: 1.8.24 < 2.4.1"            || no "ver_at_least 1.8.24"
[[ $(v 2.10.0 2.9.0) == yes ]] && ok "ver_at_least: 2.10 > 2.9 (not string order)" || no "ver_at_least 2.10 vs 2.9"

# allowed_signers must gain the key once and never duplicate it
AS="${WORK}/as"; mkdir -p "${AS}"
printf 'ssh-ed25519 AAAAKEYBLOB== comment
' > "${AS}/key.pub"
{ echo 'set -uo pipefail'; echo 'ok(){ :; }'; echo "ALLOWED_SIGNERS="${AS}/allowed_signers""
  sed -n '/^pub_blob() {/,/^}/p' "${SCRIPT}"
  sed -n '/^update_allowed_signers() {/,/^}/p' "${SCRIPT}"
  echo 'update_allowed_signers "$1" "$2"'; } > "${WORK}/as.sh"
printf 'someone@else.test ssh-ed25519 AAAAOTHER== other
' > "${AS}/allowed_signers"
bash "${WORK}/as.sh" "${AS}/key.pub" me@example.test >/dev/null 2>&1
bash "${WORK}/as.sh" "${AS}/key.pub" me@example.test >/dev/null 2>&1
[[ $(grep -c 'AAAAKEYBLOB==' "${AS}/allowed_signers") -eq 1 ]] \
    && ok "allowed_signers: the key appears once after two runs" \
    || no "allowed_signers duplicated the key" "$(cat "${AS}/allowed_signers")"
grep -q 'someone@else.test' "${AS}/allowed_signers" \
    && ok "allowed_signers: other principals are preserved" || no "other principals lost"
[[ $(head -c 2 <(stat -c '%a' "${AS}/allowed_signers")) == 64 ]] \
    && ok "allowed_signers: mode 644" || no "allowed_signers mode" "$(stat -c '%a' "${AS}/allowed_signers")"

# a changed email for the same key must replace the line, not add one
bash "${WORK}/as.sh" "${AS}/key.pub" new@example.test >/dev/null 2>&1
[[ $(grep -c 'AAAAKEYBLOB==' "${AS}/allowed_signers") -eq 1 ]] \
    && ok "allowed_signers: re-running with a new email replaces the line" \
    || no "allowed_signers kept a stale line"

# ------------------------------------------------------- signing policy
group "Signing policy"
# sk_policy reads the flags byte from ssh-keygen's debug output. A fake
# ssh-keygen stands in so no key or YubiKey is needed; it also records its
# arguments, so a call that could prompt for a passphrase is caught.
stub "${WORK}/pol.sh" sk_policy sk_policy_label sk_policy_needs sk_policy_opts
FK="${WORK}/fakebin"; mkdir -p "${FK}"
cat > "${FK}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_ARGS}"
[[ -n ${FAKE_FLAGS:-} ]] && printf 'debug1: sk_application: "ssh:git-signing", sk_flags 0x%s\n' "${FAKE_FLAGS}" >&2
printf 'sk-ssh-ed25519@openssh.com AAAA\n'
EOF
chmod +x "${FK}/ssh-keygen"
pol() { FAKE_FLAGS=$1 FAKE_ARGS="${WORK}/fkargs" PATH="${FK}:${PATH}" \
        bash -c "source '${WORK}/pol.sh'; sk_policy /dev/null"; }
[[ $(pol 25) == pin+touch ]] && ok "0x25 (resident, PIN, touch) reads as pin+touch" || no "0x25" "$(pol 25)"
[[ $(pol 24) == pin ]]       && ok "0x24 reads as pin (no touch)"                  || no "0x24" "$(pol 24)"
[[ $(pol 21) == touch ]]     && ok "0x21 reads as touch only"                       || no "0x21" "$(pol 21)"
[[ $(pol 20) == none ]]      && ok "0x20 reads as none"                             || no "0x20" "$(pol 20)"
[[ $(pol 05) == pin+touch ]] && ok "non-resident 0x05 reads as pin+touch"           || no "0x05" "$(pol 05)"
pol "" >/dev/null && no "no flags line still returned a policy" || ok "no flags line: sk_policy fails"
pol 25 >/dev/null
grep -qx -- '-P' "${WORK}/fkargs" && [[ $(grep -A1 -x -- '-P' "${WORK}/fkargs" | tail -1) == "" ]] \
    && ok "sk_policy passes -P \"\" so a passphrase-protected file fails instead of prompting" \
    || no "sk_policy could prompt for a passphrase" "$(tr '\n' ' ' < "${WORK}/fkargs")"

opts() { bash -c "source '${WORK}/pol.sh'; sk_policy_opts '$1' | tr '\n' ' '"; }
[[ $(opts pin+touch) == "-O verify-required " ]] \
    && ok "pin+touch creates with -O verify-required" || no "pin+touch opts" "$(opts pin+touch)"
bash -c "source '${WORK}/pol.sh'; sk_policy_opts pin" >/dev/null \
    && no "PIN-only can still be created" || ok "PIN-only is not a creatable policy"
[[ -z $(opts touch) ]] && ok "touch creates with no extra options" || no "touch opts" "$(opts touch)"
bash -c "source '${WORK}/pol.sh'; sk_policy_opts bogus" >/dev/null \
    && no "an unknown policy produced options" || ok "an unknown policy is rejected"

# the create step offers exactly PIN + touch and touch only, and passes the
# options as an array (an empty one for touch)
CK=$(sed -n '/^step_create_key() {/,/^}/p' "${SCRIPT}")
for o in "FIDO2 PIN + touch" "Touch only"; do
    grep -qF "\"${o}" <<<"${CK}" && ok "create offers: ${o}" || no "create does not offer: ${o}"
done
grep -qiF "PIN only" <<<"${CK}" && no "create still offers PIN only" || ok "create does not offer PIN only"
grep -qF '"${sk_opts[@]}"' <<<"${CK}" \
    && ok "ssh-keygen gets the policy options as a quoted array" || no "policy options not passed as an array"

# ------------------------------------------------ signature verification
group "Tarball signature verification"
# ya_verify decides whether a download is trustworthy. Exercised here with
# throwaway keys and a local import in place of the keyserver fetch.
if command -v gpg >/dev/null 2>&1; then
    G="${WORK}/gpg"; mkdir -p "${G}/home"; chmod 700 "${G}/home"
    export GNUPGHOME="${G}/home"
    gpg --batch --quiet --passphrase '' --quick-generate-key 'T <t@example.invalid>' ed25519 sign never 2>/dev/null
    PRIMARY=$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
    gpg --batch --quiet --passphrase '' --quick-add-key "${PRIMARY}" ed25519 sign never 2>/dev/null
    SUB=$(gpg --list-keys --with-colons "${PRIMARY}" 2>/dev/null | awk -F: '/^fpr/{f=$10} END{print f}')
    printf 'payload\n' > "${G}/f.tgz"
    gpg --batch --quiet --yes --detach-sign -u "${SUB}!" -o "${G}/f.tgz.sig" "${G}/f.tgz" 2>/dev/null
    gpg --export -a "${PRIMARY}" > "${G}/key.asc" 2>/dev/null
    printf 'payload\nevil\n' > "${G}/bad.tgz"; cp "${G}/f.tgz.sig" "${G}/bad.tgz.sig"
    printf 'not a signature\n' > "${G}/junk.sig"
    unset GNUPGHOME

    mkver() {   # $1 = allowlist fingerprint
        {
            printf 'set -uo pipefail\n'
            printf 'ok(){ printf "ACCEPT\\n"; }; bad(){ printf "REJECT %%s\\n" "$1"; }\n'
            printf 'info(){ :; }; note(){ :; }; blank(){ :; }\n'
            printf 'YA_SIGNING_URL=x\nYA_KEYS=(%s)\n' "$1"
            sed -n '/^ya_gpg_cleanup() {/,/^}/p' "${SCRIPT}"
            sed -n '/^ya_verify() {/,/^}/p' "${SCRIPT}"
        } > "${WORK}/ver.sh"
        # local import instead of a keyserver round trip
        python3 - "${WORK}/ver.sh" "${G}/key.asc" <<'PY2'
import re, sys
p, key = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r"    for ks in hkps://.*?\n    done\n",
           f'    GNUPGHOME="${{gnupghome}}" gpg --batch --quiet --import "{key}" 2>/dev/null && rc=0\n',
           s, flags=re.S)
open(p, "w").write(s)
PY2
        printf 'ya_verify "$@"\n' >> "${WORK}/ver.sh"
    }

    mkver "${PRIMARY}"
    r=$(timeout 60 bash "${WORK}/ver.sh" "${G}/f.tgz" "${G}/f.tgz.sig" 2>/dev/null | tail -1)
    [[ ${r} == ACCEPT* ]] && ok "subkey signature accepted when the PRIMARY key is listed" \
        || no "subkey signature accepted" "${r}"
    r=$(timeout 60 bash "${WORK}/ver.sh" "${G}/bad.tgz" "${G}/bad.tgz.sig" 2>/dev/null | tail -1)
    [[ ${r} == REJECT* ]] && ok "tampered payload rejected" || no "tampered payload rejected" "${r}"
    r=$(timeout 60 bash "${WORK}/ver.sh" "${G}/f.tgz" "${G}/junk.sig" 2>/dev/null | tail -1)
    [[ ${r} == REJECT* ]] && ok "junk signature rejected" || no "junk signature rejected" "${r}"

    mkver "${SUB}"
    r=$(timeout 60 bash "${WORK}/ver.sh" "${G}/f.tgz" "${G}/f.tgz.sig" 2>/dev/null | tail -1)
    [[ ${r} == REJECT* ]] && ok "listing only the SUBKEY is not enough" || no "subkey-only allowlist accepted" "${r}"

    mkver "0000000000000000000000000000000000000000"
    r=$(timeout 60 bash "${WORK}/ver.sh" "${G}/f.tgz" "${G}/f.tgz.sig" 2>/dev/null | tail -1)
    [[ ${r} == REJECT* ]] && ok "unlisted key rejected" || no "unlisted key rejected" "${r}"

    # With both keyservers unreachable, the user's own keyring is the fallback.
    # Build a verifier whose keyserver loop always fails, and point GNUPGHOME at
    # a keyring that already holds the key.
    {
        printf 'set -uo pipefail\n'
        printf 'ok(){ printf "ACCEPT\\n"; }; bad(){ printf "REJECT %%s\\n" "$1"; }\n'
        printf 'info(){ :; }; note(){ :; }; blank(){ :; }\n'
        printf 'YA_SIGNING_URL=x\nYA_KEYS=(%s)\n' "${PRIMARY}"
        sed -n '/^ya_gpg_cleanup() {/,/^}/p' "${SCRIPT}"
        sed -n '/^ya_verify() {/,/^}/p' "${SCRIPT}"
        printf 'ya_verify "$@"\n'
    } > "${WORK}/verks.sh"
    # make every keyserver fetch fail
    sed -i 's|--keyserver "${ks}" --recv-keys "${issuer}" 2>/dev/null|--keyserver "invalid://nowhere" --recv-keys "${issuer}" 2>/dev/null|' "${WORK}/verks.sh"
    r=$(GNUPGHOME="${G}/home" timeout 90 bash "${WORK}/verks.sh" "${G}/f.tgz" "${G}/f.tgz.sig" 2>/dev/null | tail -1)
    [[ ${r} == ACCEPT* ]] && ok "falls back to the user's own keyring when keyservers fail" \
        || no "keyring fallback did not work" "${r}"
    # and with an EMPTY user keyring it must still refuse
    mkdir -p "${G}/empty"; chmod 700 "${G}/empty"
    r=$(GNUPGHOME="${G}/empty" timeout 90 bash "${WORK}/verks.sh" "${G}/f.tgz" "${G}/f.tgz.sig" 2>/dev/null | tail -1)
    [[ ${r} == REJECT* ]] && ok "no keyserver and an empty keyring still refuses" \
        || no "accepted with no key available" "${r}"
    GNUPGHOME="${G}/empty" gpgconf --kill all >/dev/null 2>&1
    GNUPGHOME="${G}/home" gpgconf --kill all >/dev/null 2>&1
else
    ok "gpg not available (signature checks skipped)"
fi

# ------------------------------------------- the PAM root transaction
group "PAM root script (sandboxed)"
# The most dangerous code in the file. pam_root_script was split out of
# pam_commit precisely so it can be run here against a fake /etc/pam.d instead
# of only being read.
stub "${WORK}/root.sh" pam_root_script
cat >> "${WORK}/root.sh" <<'EOF'
PAM_U2F_FILE=/etc/pam.d/common-u2f
PAM_VENDOR_DIR=${PAM_VENDOR_DIR:-/usr/lib/pam.d}
PAM_ROLLBACK_UNIT=yubikey-pam-rollback
PAM_TEST_SVC=/etc/pam.d/yubikey-pam-test
PAM_PROBE_SVC=/etc/pam.d/yubikey-pam-probe
pam_root_script "$@"
EOF

SB="${WORK}/sandbox"
mkdir -p "${SB}/etc/pam.d" "${SB}/usr/lib/pam.d" "${SB}/var/backups"
for svc in sudo sudo-i login gdm-password cron cups; do
    printf '@include common-auth\n@include common-account\n' > "${SB}/etc/pam.d/${svc}"
done
printf '@include common-u2f\n@include common-auth\n' > "${SB}/etc/pam.d/cron"
printf '@include common-auth\n@include common-account\n' > "${SB}/usr/lib/pam.d/polkit-1"
printf '# stanza\nauth sufficient pam_u2f.so cue\n' > "${WORK}/stage"

bash "${WORK}/root.sh" keyonly 'authfile=/etc/u2f_mappings cue' 'cron' 'sudo login gdm-password' \
    'polkit-1' "${SB}/var/backups/b.tgz" "${WORK}/stage" 'true' > "${WORK}/rootgen" 2>/dev/null
# retarget at the sandbox and neutralise the bits that need a real system
sed -e "s|/etc/pam.d/|${SB}/etc/pam.d/|g" \
    -e "s|/usr/lib/pam.d/|${SB}/usr/lib/pam.d/|g" \
    -e "s|^mkdir -p /var/backups|mkdir -p ${SB}/var/backups|" \
    -e "s|-C /etc pam.d|-C ${SB}/etc pam.d|" \
    -e 's|^systemctl |true systemctl |' \
    -e 's|^systemd-run |true systemd-run |' \
    -e 's|install -m 0644 -o root -g root|install -m 0644|' \
    "${WORK}/rootgen" > "${WORK}/rootrun"
bash "${WORK}/rootrun" >/dev/null 2>&1 && ok "generated root script runs without error" \
    || no "generated root script runs without error"

inc() { grep -qE '^[[:space:]]*@include[[:space:]]+common-u2f[[:space:]]*$' "${SB}/etc/pam.d/$1"; }
inc sudo          && ok "sudo gained the include"          || no "sudo gained the include"
inc login         && ok "login gained the include"         || no "login gained the include"
inc gdm-password  && ok "gdm-password gained the include"  || no "gdm-password gained the include"
inc cron          && no "cron keeps the include (should have been narrowed)" || ok "cron lost the include"
[[ -f ${SB}/etc/pam.d/polkit-1 ]] && ok "polkit-1 copied from the vendor directory" || no "polkit-1 copied"
# an /etc/pam.d/polkit-1 that already exists must be edited, not replaced
SB2="${WORK}/sandbox2"
mkdir -p "${SB2}/etc/pam.d" "${SB2}/usr/lib/pam.d" "${SB2}/var/backups"
printf 'VENDOR\n@include common-auth\n'      > "${SB2}/usr/lib/pam.d/polkit-1"
printf 'CUSTOM\n@include common-auth\n'      > "${SB2}/etc/pam.d/polkit-1"
printf '@include common-auth\n'               > "${SB2}/etc/pam.d/sudo"
bash "${WORK}/root.sh" keyonly 'cue' '' 'sudo' 'polkit-1' \
    "${SB2}/var/backups/b.tgz" "${WORK}/stage" 'true' > "${WORK}/rootgen2" 2>/dev/null
sed -e "s|/etc/pam.d/|${SB2}/etc/pam.d/|g" -e "s|/usr/lib/pam.d/|${SB2}/usr/lib/pam.d/|g" \
    -e "s|^mkdir -p /var/backups|mkdir -p ${SB2}/var/backups|" -e "s|-C /etc pam.d|-C ${SB2}/etc pam.d|" \
    -e 's|^systemctl |true systemctl |' -e 's|^systemd-run |true systemd-run |' \
    -e 's|install -m 0644 -o root -g root|install -m 0644|' "${WORK}/rootgen2" > "${WORK}/rootrun2"
bash "${WORK}/rootrun2" >/dev/null 2>&1
[[ $(grep -c CUSTOM "${SB2}/etc/pam.d/polkit-1") -eq 1 ]] \
    && ok "an existing polkit-1 is edited, not overwritten by the vendor copy" \
    || no "existing polkit-1 was overwritten"
grep -qE '^[[:space:]]*@include[[:space:]]+common-u2f' "${SB2}/etc/pam.d/polkit-1" \
    && ok "the existing polkit-1 gained the include" || no "existing polkit-1 gained the include"
inc polkit-1      && ok "polkit-1 gained the include"      || no "polkit-1 gained the include"
[[ -f ${SB}/etc/pam.d/common-u2f ]] && ok "common-u2f installed" || no "common-u2f installed"
[[ $(head -1 "${SB}/etc/pam.d/sudo") == "@include common-u2f" ]] \
    && ok "include sits before common-auth" || no "include sits before common-auth"

# running it twice must not duplicate anything
bash "${WORK}/rootrun" >/dev/null 2>&1
[[ $(grep -c 'common-u2f' "${SB}/etc/pam.d/sudo") -eq 1 ]] \
    && ok "re-running does not duplicate the include" || no "re-running duplicates the include"

# ------------------------------------------------ the rollback command
group "PAM rollback (sandboxed)"
# Prove the rollback puts the machine back: restores what existed, and removes
# what this run created (common-u2f, and any vendor-copied service).
stub "${WORK}/undo.sh" pam_undo_command
cat >> "${WORK}/undo.sh" <<'EOF'
PAM_U2F_FILE=/etc/pam.d/common-u2f
pam_undo_command "$@"
EOF
RB="${WORK}/rb"
mkdir -p "${RB}/etc/pam.d" "${RB}/var"
printf '@include common-auth\n' > "${RB}/etc/pam.d/sudo"
printf 'ORIGINAL\n'             > "${RB}/etc/pam.d/login"
# backup taken BEFORE the change: no common-u2f, no polkit-1
tar czf "${RB}/var/b.tgz" -C "${RB}/etc" pam.d 2>/dev/null
# the change: edit sudo, create common-u2f and polkit-1
printf '@include common-u2f\n@include common-auth\n' > "${RB}/etc/pam.d/sudo"
printf 'MODIFIED\n'                                   > "${RB}/etc/pam.d/login"
printf 'auth sufficient pam_u2f.so cue\n'             > "${RB}/etc/pam.d/common-u2f"
printf '@include common-u2f\n@include common-auth\n' > "${RB}/etc/pam.d/polkit-1"

UNDO=$(bash "${WORK}/undo.sh" "${RB}/var/b.tgz" 'polkit-1')
printf '%s\n' "${UNDO}" | sed -e "s|-C /etc|-C ${RB}/etc|" -e "s|'/etc/pam.d/|'${RB}/etc/pam.d/|g" \
    -e "s|'/etc/pam.d/common-u2f'|'${RB}/etc/pam.d/common-u2f'|" > "${WORK}/undorun"
sed -i "s|rm -f '/etc/pam.d/|rm -f '${RB}/etc/pam.d/|g" "${WORK}/undorun"
( cd "${RB}/etc" && bash "${WORK}/undorun" ) >/dev/null 2>&1 && ok "rollback command runs" || no "rollback command runs"

[[ $(cat "${RB}/etc/pam.d/login") == "ORIGINAL" ]] \
    && ok "rollback restored a modified file" || no "rollback restored a modified file" "$(cat "${RB}/etc/pam.d/login")"
[[ $(head -1 "${RB}/etc/pam.d/sudo") == "@include common-auth" ]] \
    && ok "rollback removed the added include" || no "rollback removed the added include"
[[ ! -f ${RB}/etc/pam.d/common-u2f ]] \
    && ok "rollback deleted the created common-u2f" || no "rollback left common-u2f behind"
[[ ! -f ${RB}/etc/pam.d/polkit-1 ]] \
    && ok "rollback deleted the vendor-copied polkit-1" || no "rollback left polkit-1 behind"

# a common-u2f that EXISTED before must be restored, not deleted
RB2="${WORK}/rb2"; mkdir -p "${RB2}/etc/pam.d" "${RB2}/var"
printf 'OLD STANZA\n' > "${RB2}/etc/pam.d/common-u2f"
tar czf "${RB2}/var/b.tgz" -C "${RB2}/etc" pam.d 2>/dev/null
printf 'NEW STANZA\n' > "${RB2}/etc/pam.d/common-u2f"
U2=$(bash "${WORK}/undo.sh" "${RB2}/var/b.tgz" '')
printf '%s\n' "${U2}" | sed -e "s|-C /etc|-C ${RB2}/etc|" -e "s|rm -f '/etc/pam.d/|rm -f '${RB2}/etc/pam.d/|g" > "${WORK}/undorun2"
( cd "${RB2}/etc" && bash "${WORK}/undorun2" ) >/dev/null 2>&1
[[ $(cat "${RB2}/etc/pam.d/common-u2f" 2>/dev/null) == "OLD STANZA" ]] \
    && ok "a pre-existing common-u2f is restored, not deleted" \
    || no "pre-existing common-u2f not restored" "$(cat "${RB2}/etc/pam.d/common-u2f" 2>/dev/null || echo DELETED)"

# ------------------------------------------------- step reachability
group "Key steps are reachable"
# Moving a block once left an `if` unclosed, nesting the rest of step_pam --
# including the commit -- inside it, so "password OR key" would have done
# nothing. bash -n cannot see that; indentation can.
if python3 "$(dirname "${SCRIPT}")/lint-reachable.py" "${SCRIPT}" >"${WORK}/reach" 2>&1; then
    ok "key steps run unconditionally in their function"
else
    no "a key step is conditionally nested" "$(cat "${WORK}/reach")"
fi

# ---------------------------------------------- local-after-use bug class
group "Variable scope hygiene"
# A variable written before its own `local` lands on the global and is then
# shadowed by an empty local. This silently discarded the user's pkexec choice.
if python3 "$(dirname "${SCRIPT}")/lint-locals.py" "${SCRIPT}" >"${WORK}/locals" 2>&1; then
    ok "no variable written before its own local"
else
    no "variable written before its own local" "$(cat "${WORK}/locals")"
fi

# ------------------------------------------------- status-leak bug class
group "Exit-status hygiene"
# A one-line function ending in (( x++ )) returns 1 the first time it runs.
python3 - "${SCRIPT}" <<'PY2'
import re, sys
s = open(sys.argv[1]).read()
bad = []
for m in re.finditer(r'^([a-zA-Z_][a-zA-Z0-9_]*)\(\) \{(.*)\}\s*$', s, re.M):
    body = m.group(2)
    if re.search(r'\(\( *[A-Za-z_]+\+\+ *\)\) *;? *$', body.strip()):
        bad.append(m.group(1))
if bad:
    print(" ".join(bad)); sys.exit(1)
sys.exit(0)
PY2
[[ $? -eq 0 ]] && ok "no one-line function ends in (( x++ ))" || no "one-line function ends in (( x++ ))"

# ------------------------------------------------------------------- summary
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
