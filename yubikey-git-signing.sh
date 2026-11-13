#!/usr/bin/env bash
#
# yubikey-git-signing.sh
#
# Set up a YubiKey for git commit signing over SSH, using the FIDO2 applet.
# No PIV, no pcscd, no PKCS#11, no ssh-agent.
#
#   ./yubikey-git-signing.sh          interactive menu
#   ./yubikey-git-signing.sh --check  read-only dependency report
#   ./yubikey-git-signing.sh --help
#
# Deliberately NOT using `set -e`: a grep with no match must not kill the UI.
set -uo pipefail

VERSION="1.14.0"

# ----------------------------------------------------------------------------
# Paths. Keys live in ~/.config/git/keys, never in ~/.ssh -- see check_gcr().
# ----------------------------------------------------------------------------
KEY_DIR="${HOME}/.config/git/keys"
KEY_NAME="id_ed25519_sk_git"
KEY_PRIV="${KEY_DIR}/${KEY_NAME}"
KEY_PUB="${KEY_PRIV}.pub"
ALLOWED_SIGNERS="${HOME}/.config/git/allowed_signers"
ENV_DIR="${HOME}/.config/environment.d"
ENV_FILE="${ENV_DIR}/10-ssh-askpass.conf"
SK_APPLICATION="ssh:git-signing"

MIN_SSH_MAJOR=8
MIN_SSH_MINOR=4
MIN_GIT_MAJOR=2
MIN_GIT_MINOR=34

YKMAN=""
YKMAN_BROKEN_SNAP=""
PLAIN=0
FAIL_COUNT=0
WARN_COUNT=0
GCR_FAILED=0

# ----------------------------------------------------------------------------
# Theme
# ----------------------------------------------------------------------------
setup_theme() {
    local depth=0
    depth=$(tput colors 2>/dev/null) || depth=0
    [[ -z ${depth} || ${depth} == *[!0-9]* ]] && depth=0

    # [[ -t 1 ]] matters as much as the rest: without it, `--check > report.txt`
    # or a pipe into tee captures raw escape sequences.
    if [[ -n ${NO_COLOR:-} ]] || (( depth < 8 )) || [[ ${TERM:-dumb} == dumb ]] \
       || [[ ${FORCE_PLAIN:-0} == 1 ]] || [[ ! -t 1 ]]; then
        PLAIN=1
    fi

    if (( PLAIN )); then
        RESET="" BOLD="" DIM="" ACCENT="" TITLE="" OKC="" WARNC="" ERRC="" MUTED=""
        HIDE_CUR="" SHOW_CUR="" ALT_ON="" ALT_OFF=""
    else
        RESET=$'\033[0m'
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        if (( depth >= 256 )); then
            ACCENT=$'\033[38;5;79m'
            TITLE=$'\033[38;5;117m'
            OKC=$'\033[38;5;78m'
            WARNC=$'\033[38;5;214m'
            ERRC=$'\033[38;5;203m'
            MUTED=$'\033[38;5;245m'
        else
            ACCENT=$'\033[36m' TITLE=$'\033[36m' OKC=$'\033[32m'
            WARNC=$'\033[33m' ERRC=$'\033[31m' MUTED=$'\033[37m'
        fi
        HIDE_CUR=$'\033[?25l'
        SHOW_CUR=$'\033[?25h'
        ALT_ON=$'\033[?1049h'
        ALT_OFF=$'\033[?1049l'
    fi

    # Box glyphs: Unicode only when the locale says it is safe.
    #
    # Concatenating LANG and LC_ALL is wrong: LC_ALL=C with LANG=en_US.UTF-8
    # gives "en_US.UTF-8C", which matches UTF, while bash is in the C locale and
    # ${#s} then counts bytes, so the banner border drifts. Ask for the charmap
    # the process actually has, and fall back to the documented precedence.
    local charmap
    charmap=$(locale charmap 2>/dev/null) || charmap=""
    [[ -z ${charmap} ]] && charmap=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
    if [[ ${charmap} == *[Uu][Tt][Ff]* ]] && (( ! PLAIN )); then
        G_TL="+" G_TR="+" G_BL="+" G_BR="+" G_H="-" G_V="|"
        G_TL=$'╭' G_TR=$'╮' G_BL=$'╰' G_BR=$'╯'
        G_H=$'─'  G_V=$'│'
        G_OK=$'✔' G_BAD=$'✘' G_WARN=$'▲' G_DOT=$'·'
        G_PTR=$'▸' G_ARROW=$'→' G_KEY=$'•'
    else
        G_TL="+" G_TR="+" G_BL="+" G_BR="+" G_H="-" G_V="|"
        G_OK="OK" G_BAD="XX" G_WARN="!!" G_DOT="-"
        G_PTR=">" G_ARROW="->" G_KEY="*"
    fi
}

term_height() {
    local h
    h=$(tput lines 2>/dev/null) || h=0
    [[ -z ${h} || ${h} == *[!0-9]* ]] && h=24
    (( h < 10 )) && h=10
    printf '%s' "${h}"
}

term_width() {
    local w
    w=$(tput cols 2>/dev/null) || w=80
    [[ -z ${w} || ${w} == *[!0-9]* ]] && w=80
    (( w > 84 )) && w=84
    (( w < 40 )) && w=40
    printf '%s' "${w}"
}

repeat_char() {
    local ch=$1 n=$2 out=""
    while (( n-- > 0 )); do out+="${ch}"; done
    printf '%s' "${out}"
}

# Visible length, ignoring ANSI escapes.
vis_len() {
    local s=$1
    s=$(printf '%s' "${s}" | sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g')
    printf '%s' "${#s}"
}

# ----------------------------------------------------------------------------
# Output primitives
# ----------------------------------------------------------------------------
banner() {
    local w title sub pad
    w=$(term_width)
    title="YubiKey  ${G_ARROW}  git commit signing"
    sub="FIDO2 / ed25519-sk  ${G_DOT}  no agent, no PKCS#11"
    printf '\n'
    printf '%s%s%s%s%s\n' "${ACCENT}" "${G_TL}" "$(repeat_char "${G_H}" $((w-2)))" "${G_TR}" "${RESET}"
    pad=$(( w - 4 - $(vis_len "${title}") ))
    (( pad < 0 )) && pad=0
    printf '%s%s%s %s%s%s%s %s%s\n' "${ACCENT}" "${G_V}" "${RESET}" \
        "${BOLD}${TITLE}" "${title}" "${RESET}" "$(repeat_char ' ' "${pad}")" \
        "${ACCENT}${G_V}" "${RESET}"
    pad=$(( w - 4 - $(vis_len "${sub}") ))
    (( pad < 0 )) && pad=0
    printf '%s%s%s %s%s%s%s %s%s\n' "${ACCENT}" "${G_V}" "${RESET}" \
        "${MUTED}" "${sub}" "${RESET}" "$(repeat_char ' ' "${pad}")" \
        "${ACCENT}${G_V}" "${RESET}"
    printf '%s%s%s%s%s\n' "${ACCENT}" "${G_BL}" "$(repeat_char "${G_H}" $((w-2)))" "${G_BR}" "${RESET}"
    printf '\n'
}

section() {
    local w
    w=$(term_width)
    printf '\n%s%s%s\n' "${BOLD}${TITLE}" "$1" "${RESET}"
    printf '%s%s%s\n\n' "${MUTED}" "$(repeat_char "${G_H}" $((w-2)))" "${RESET}"
}

ok()    { printf '  %s%s%s %s\n' "${OKC}"   "${G_OK}"   "${RESET}" "$1"; }
bad()   { printf '  %s%s%s %s\n' "${ERRC}"  "${G_BAD}"  "${RESET}" "$1"; }
warn()  { printf '  %s%s%s %s\n' "${WARNC}" "${G_WARN}" "${RESET}" "$1"; }
info()  { printf '  %s%s%s %s\n' "${MUTED}" "${G_DOT}"  "${RESET}" "$1"; }
note()  { printf '    %s%s%s\n' "${MUTED}" "$1" "${RESET}"; }
blank() { printf '\n'; }

hint() { printf '  %s%s%s\n' "${MUTED}" "$1" "${RESET}"; }

pause() {
    (( PLAIN )) && return 0
    printf '\n  %spress enter to continue%s' "${MUTED}" "${RESET}"
    read -r _ || true
    printf '\n'
}

die() { bad "$1"; exit 1; }

# ----------------------------------------------------------------------------
# Terminal state
# ----------------------------------------------------------------------------
IN_ALT=0
enter_alt() { (( PLAIN )) && return 0; printf '%s%s' "${ALT_ON}" "${HIDE_CUR}"; IN_ALT=1; TTY_TOUCHED=1; }
leave_alt() {
    (( PLAIN )) && return 0
    printf '%s' "${SHOW_CUR}"
    (( IN_ALT )) && printf '%s' "${ALT_OFF}"
    IN_ALT=0
    return 0
}

# Set the moment we put the terminal into a state the user did not ask for.
TTY_TOUCHED=0

restore_term() {
    if (( IN_ALT )); then printf '%s' "${ALT_OFF}"; IN_ALT=0; fi
    printf '%s' "${SHOW_CUR:-}"
    # Only reset the line discipline if we changed it. 'stty sane' on every
    # exit wipes the user's own settings (-ixon, a custom erase) and, worse,
    # knocks a pager reading the same tty out of raw mode on `--check | less`.
    if (( TTY_TOUCHED )); then
        stty sane 2>/dev/null
        TTY_TOUCHED=0
    fi
}
# A backup taken by backup_existing_key lives between the mv and the keygen
# result. If we die in that window -- Ctrl-C at the PIN or touch prompt, or the
# terminal closing -- the restore in step_create_key never runs and the user is
# left with no key while git still points at one. Put it back on the way out.
abort_cleanup() {
    # Only rescue when the key is actually missing. After a successful keygen
    # the markers may still be set, and restoring then would put the OLD key
    # back over the new one on a perfectly normal exit.
    [[ -f ${KEY_PRIV:-} ]] && return 0
    if [[ -n ${BACKUP_PRIV:-} || -n ${BACKUP_PUB:-} ]]; then
        restore_backup >/dev/null 2>&1
        printf '\n  previous signing key put back\n'
    fi
}
trap 'abort_cleanup; restore_term' EXIT
trap 'abort_cleanup; restore_term; printf "\n"; exit 130' INT TERM

# Hand the terminal back to a child that needs real input (PIN prompts, sudo,
# touch confirmations). Never run those inside the alternate screen.
run_interactive() {
    local rc
    leave_alt
    TTY_TOUCHED=1; stty sane 2>/dev/null
    printf '\n  %s%s %s%s\n\n' "${MUTED}" "${G_ARROW}" "$*" "${RESET}"
    "$@"
    rc=$?
    printf '\n'
    if (( rc == 0 )); then ok "finished"; else bad "exited ${rc}"; fi
    return ${rc}
}

confirm() {
    local prompt=$1 default=${2:-n} ans
    leave_alt
    TTY_TOUCHED=1; stty sane 2>/dev/null
    if [[ ${default} == y ]]; then
        printf '  %s%s%s [Y/n] ' "${BOLD}" "${prompt}" "${RESET}"
    else
        printf '  %s%s%s [y/N] ' "${BOLD}" "${prompt}" "${RESET}"
    fi
    read -r ans || ans=""
    ans=${ans:-${default}}
    [[ ${ans} == [Yy]* ]]
}

# Typed confirmation for anything destructive.
confirm_typed() {
    local word=$1 prompt=$2 ans
    leave_alt
    TTY_TOUCHED=1; stty sane 2>/dev/null
    printf '  %s%s%s\n' "${WARNC}" "${prompt}" "${RESET}"
    printf '  type %s%s%s to proceed: ' "${BOLD}" "${word}" "${RESET}"
    read -r ans || ans=""
    [[ ${ans} == "${word}" ]]
}

ask() {
    local prompt=$1 default=${2:-} ans
    # The prompt goes to stderr: callers capture this function's stdout.
    leave_alt >&2
    TTY_TOUCHED=1; stty sane 2>/dev/null
    if [[ -n ${default} ]]; then
        printf '  %s%s%s [%s]: ' "${BOLD}" "${prompt}" "${RESET}" "${default}" >&2
    else
        printf '  %s%s%s: ' "${BOLD}" "${prompt}" "${RESET}" >&2
    fi
    read -r ans || ans=""
    printf '%s' "${ans:-${default}}"
}

# ----------------------------------------------------------------------------
# Arrow-key menu. Sets MENU_INDEX. Returns 1 if cancelled.
# ----------------------------------------------------------------------------
MENU_INDEX=0
# An option whose text begins with "-- " is a heading: shown, never selectable.
# MENU_INDEX counts selectable entries only, so a menu without headings
# behaves exactly as it did before.
ui_menu() {
    local title=$1; shift
    local -a opts=("$@") sel=()
    local n=${#opts[@]} cur=0 key rest more guard i w m d

    for (( i = 0; i < n; i++ )); do
        [[ ${opts[i]} == --* ]] || sel+=("${i}")
    done
    m=${#sel[@]}
    (( m == 0 )) && return 1

    if (( PLAIN )); then
        printf '\n%s\n' "${title}"
        d=0
        for (( i = 0; i < n; i++ )); do
            if [[ ${opts[i]} == "--" ]]; then
                printf '\n'
            elif [[ ${opts[i]} == --* ]]; then
                printf '\n  %s\n' "${opts[i]#-- }"
            else
                (( d++ ))
                printf '   %2d) %s\n' "${d}" "${opts[i]}"
            fi
        done
        # Re-prompt on a typo. Returning 1 here reads as "cancelled" to the
        # caller, and in main_menu that quits the whole program.
        while :; do
            printf 'select [1-%d, q]: ' "${m}"
            read -r key || key=q
            [[ ${key} == [Qq]* ]] && return 1
            if [[ -z ${key} || ${key} == *[!0-9]* ]]; then
                printf '  enter a number between 1 and %d, or q to go back\n' "${m}"
                continue
            fi
            # '08' and '09' are invalid octal: a bare (( )) on them raises
            # "value too great for base" and aborts the whole script.
            if (( ${#key} > 3 )); then
                printf '  out of range\n'; continue
            fi
            key=$((10#${key}))
            if (( key < 1 || key > m )); then
                printf '  out of range\n'; continue
            fi
            MENU_INDEX=$((key-1))
            return 0
        done
    fi

    enter_alt
    w=$(term_width)
    while :; do
        printf '\033[H\033[2J'
        banner
        printf '  %s%s%s\n' "${BOLD}${TITLE}" "${title}" "${RESET}"

        # The frame is banner + title + options + footer. On an 80x24 terminal
        # a 21-line option list pushes the banner and the selected row off the
        # top, so the pointer is invisible and Enter fires something unseen.
        # Show a window around the cursor instead.
        local rows budget first last j used full
        rows=$(term_height)
        # Banner 6 + title 1 + footer 3. Count RENDERED rows, not entries: a
        # heading prints a blank line then its text, so it costs two.
        budget=$(( rows - 10 ))
        (( budget < 4 )) && budget=4
        full=0
        for (( j = 0; j < n; j++ )); do
            if [[ ${opts[j]} == --* ]]; then full=$(( full + 2 )); else full=$(( full + 1 )); fi
        done
        if (( full <= budget )); then
            first=0; last=$(( n - 1 ))
        else
            # Two marker lines eat into the budget once we are windowing.
            budget=$(( budget - 2 ))
            (( budget < 2 )) && budget=2
            first=${sel[cur]}; last=${sel[cur]}; used=1
            while :; do
                if (( first > 0 )); then
                    j=$(( first - 1 ))
                    [[ ${opts[j]} == --* ]] && used=$(( used + 2 )) || used=$(( used + 1 ))
                    (( used > budget )) && break
                    first=${j}
                fi
                if (( last < n - 1 )); then
                    j=$(( last + 1 ))
                    [[ ${opts[j]} == --* ]] && used=$(( used + 2 )) || used=$(( used + 1 ))
                    (( used > budget )) && break
                    last=${j}
                fi
                (( first == 0 && last == n - 1 )) && break
            done
        fi
        (( first > 0 )) && printf '    %s... %d more above%s\n' "${MUTED}" "${first}" "${RESET}"
        for (( i = first; i <= last; i++ )); do
            if [[ ${opts[i]} == "--" ]]; then
                printf '\n'
            elif [[ ${opts[i]} == --* ]]; then
                printf '\n  %s%s%s\n' "${MUTED}" "${opts[i]#-- }" "${RESET}"
            elif (( i == sel[cur] )); then
                printf '  %s%s %s%s%s\n' "${ACCENT}" "${G_PTR}" "${BOLD}" "${opts[i]}" "${RESET}"
            else
                printf '    %s%s%s\n' "${MUTED}" "${opts[i]}" "${RESET}"
            fi
        done
        (( last < n - 1 )) && printf '    %s... %d more below%s\n' "${MUTED}" "$(( n - 1 - last ))" "${RESET}"
        printf '\n  %s%s%s\n' "${MUTED}" \
            "$(repeat_char "${G_H}" $((w-4)))" "${RESET}"
        printf '  %sup/down or j/k to move  %s  enter to select  %s  q to quit%s\n' \
            "${MUTED}" "${G_DOT}" "${G_DOT}" "${RESET}"

        # rc 0 with an empty key is Enter; a failure is EOF, which must not
        # count as a selection -- otherwise a closed stdin activates an item.
        IFS= read -rsn1 key || { leave_alt; return 1; }
        if [[ ${key} == $'\033' ]]; then
            # One byte at a time, with IFS= so whitespace is kept. Reading two
            # at once made Alt+<letter> swallow the next keystroke; letting IFS
            # strip the byte made Alt+Space indistinguishable from a bare
            # Escape, which quits the menu. The read's exit status is what
            # separates "a byte arrived" from "nothing came".
            rest=""; more=""; local got=0
            IFS= read -rsn1 -t 0.05 more && got=1
            rest=${more}
            if [[ ${rest} == '[' || ${rest} == 'O' ]]; then
                # CSI or SS3: drain to the final byte, so the tail of a
                # modified arrow (ESC[1;5A) cannot reach the digit branch.
                guard=0
                while (( guard++ < 10 )); do
                    more=""
                    read -rsn1 -t 0.05 more
                    [[ -z ${more} ]] && break
                    rest+="${more}"
                    case ${more} in [A-Za-z~]) break ;; esac
                done
                key="ESC${rest:0:2}"
            elif (( got )); then
                key="ESC-meta"      # Alt+<char>, including Alt+Space
            else
                key="ESC"           # nothing followed: bare Escape, cancel
            fi
        fi
        case ${key} in
            'ESC[A'|k|K) (( cur-- )); (( cur < 0 )) && cur=$((m-1)) ;;
            'ESC[B'|j|J) (( cur++ )); (( cur >= m )) && cur=0 ;;
            'ESC')       leave_alt; return 1 ;;
            q|Q)         leave_alt; return 1 ;;
            ""|$'\n')    MENU_INDEX=${cur}; leave_alt; return 0 ;;
            [1-9])       i=$(( key - 1 )); if (( i < m )); then MENU_INDEX=${i}; leave_alt; return 0; fi ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Detection helpers
# ----------------------------------------------------------------------------
version_ge() {
    # version_ge MAJOR MINOR MIN_MAJOR MIN_MINOR
    (( $1 > $3 )) && return 0
    (( $1 == $3 && $2 >= $4 )) && return 0
    return 1
}

ssh_version() {
    local raw major minor
    raw=$(ssh -V 2>&1)
    [[ ${raw} =~ OpenSSH_([0-9]+)\.([0-9]+) ]] || return 1
    major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
    printf '%s %s' "${major}" "${minor}"
}

git_version() {
    local raw major minor
    raw=$(git --version 2>/dev/null)
    [[ ${raw} =~ ([0-9]+)\.([0-9]+) ]] || return 1
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

find_sk_helper() {
    local p
    for p in /usr/lib/openssh/ssh-sk-helper /usr/libexec/openssh/ssh-sk-helper \
             /usr/lib/ssh/ssh-sk-helper /usr/local/libexec/ssh-sk-helper; do
        [[ -x ${p} ]] && { printf '%s' "${p}"; return 0; }
    done
    return 1
}

detect_ykman() {
    local c out
    YKMAN=""; YKMAN_BROKEN_SNAP=""
    for c in /usr/bin/ykman /usr/local/bin/ykman "$(command -v ykman 2>/dev/null)"; do
        [[ -n ${c} && -x ${c} ]] || continue
        out=$("${c}" --version 2>&1)
        if [[ ${out} == *snap-confine* || ${out} == *"cannot continue"* ]]; then
            YKMAN_BROKEN_SNAP="${c}"
            continue
        fi
        YKMAN="${c}"
        return 0
    done
    return 1
}

# A missing fido2-tools must not block setup: ssh-keygen does not need it.
require_device() {
    if ! command -v fido2-token >/dev/null 2>&1; then
        info "fido2-tools not installed -- skipping device detection"
        return 0
    fi
    if [[ -z $(fido_devices) ]]; then
        warn "no FIDO2 device detected -- plug the YubiKey in and retry"
        return 1
    fi
    return 0
}

fido_devices() {
    command -v fido2-token >/dev/null 2>&1 || return 1
    fido2-token -L 2>/dev/null
}

# "set" | "unset" | "unknown";  prints "state retries"
fido_pin_state() {
    local out line
    [[ -n ${YKMAN} ]] || { printf 'unknown -'; return 1; }
    out=$("${YKMAN}" fido info 2>&1) || { printf 'unknown -'; return 1; }
    line=$(printf '%s\n' "${out}" | grep -i '^PIN:' | head -1)
    if [[ -z ${line} ]]; then printf 'unknown -'; return 1; fi
    if [[ ${line} == *[Nn]ot\ set* ]]; then printf 'unset -'; return 0; fi
    # These arrive as separate lines, so the PIN: line still says "N attempts"
    # and the applet looks healthy when it is not usable.
    if [[ ${out} == *"temporarily blocked"* ]]; then printf 'tempblocked -'; return 0; fi
    if [[ ${out} == *"must be changed"* ]]; then printf 'mustchange -'; return 0; fi
    if [[ ${line} =~ ([0-9]+)[[:space:]]*attempt ]]; then
        printf 'set %s' "${BASH_REMATCH[1]}"; return 0
    fi
    # ykman prints 'PIN: Blocked' once the retries are gone, and Disabled or
    # Not supported in other states. None of those is a usable PIN, and calling
    # them 'set' turns a bricked applet into a green tick.
    case ${line} in
        *[Bb]locked*)       printf 'blocked 0'; return 0 ;;
        *[Dd]isabled*)      printf 'disabled -'; return 0 ;;
        *[Nn]ot\ supported*) printf 'unsupported -'; return 0 ;;
    esac
    printf 'set -'
}

# Application string embedded in an sk public key, e.g. ssh:git-signing
pub_application() {
    cut -d' ' -f2 "$1" 2>/dev/null | base64 -d 2>/dev/null \
        | tr -c '[:print:]' '\n' | grep -m1 '^ssh:' 
}

pub_blob() { cut -d' ' -f1,2 "$1" 2>/dev/null; }

# Signing policy of an sk private key, read from its flags byte: 0x01 is user
# presence (touch), 0x04 user verification (PIN).  The handle is unencrypted
# (-N ""), so ssh-keygen loads it without the YubiKey; -P "" makes a
# passphrase-protected file fail instead of prompting.  ssh-keygen only logs
# the flags at debug level, hence -v and the stderr scrape.
# Prints pin+touch, pin, touch or none.
sk_policy() {
    local hex flags
    hex=$(ssh-keygen -v -y -P "" -f "$1" 2>&1 >/dev/null </dev/null \
        | sed -n 's/.*sk_flags 0x\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' | head -1)
    [[ -n ${hex} ]] || return 1
    flags=$(( 16#${hex} ))
    if (( flags & 4 )); then
        if (( flags & 1 )); then printf 'pin+touch'; else printf 'pin'; fi
    elif (( flags & 1 )); then
        printf 'touch'
    else
        printf 'none'
    fi
}

sk_policy_label() {
    case $1 in
        pin+touch) printf 'FIDO2 PIN + touch' ;;
        pin)       printf 'FIDO2 PIN only (no touch)' ;;
        touch)     printf 'touch only (no PIN)' ;;
        none)      printf 'no PIN and no touch' ;;
        *)         printf 'unknown' ;;
    esac
}

# What each signature asks of you, for prompts.
sk_policy_needs() {
    case $1 in
        pin+touch) printf 'the FIDO2 PIN and a touch' ;;
        pin)       printf 'the FIDO2 PIN' ;;
        touch)     printf 'a touch' ;;
        none)      printf 'nothing' ;;
        *)         printf 'the FIDO2 PIN and/or a touch' ;;
    esac
}

# ssh-keygen -O options for each policy the create step offers, one per line.
# No PIN-only choice: without the touch, anything that has seen the PIN can
# sign, GitHub's verifier rejects the signatures, and ssh-keygen -K brings the
# key back touch-required anyway.
sk_policy_opts() {
    case $1 in
        pin+touch) printf '%s\n' -O verify-required ;;
        touch)     ;;
        *)         return 1 ;;
    esac
}

askpass_binary() {
    local p
    for p in /usr/bin/ssh-askpass /usr/lib/openssh/gnome-ssh-askpass \
             /usr/libexec/openssh/gnome-ssh-askpass /usr/bin/ksshaskpass; do
        [[ -x ${p} ]] && { printf '%s' "${p}"; return 0; }
    done
    return 1
}

clipboard_copy() {
    if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-copy >/dev/null 2>&1; then
        wl-copy < "$1" && return 0
    fi
    if [[ -n ${DISPLAY:-} ]] && command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard < "$1" && return 0
    fi
    return 1
}

need_root_check() {
    if [[ ${EUID} -eq 0 ]]; then
        die "Do not run this as root. It configures your user's git and keys. sudo is used only for package installs."
    fi
}

# ----------------------------------------------------------------------------
# 5. Dependency check (read-only)
# ----------------------------------------------------------------------------
check_all() {
    local v major minor helper devs ndev state retries val blob app policy
    local lddout

    FAIL_COUNT=0; WARN_COUNT=0
    section "Dependency check"

    # --- OpenSSH ---
    if v=$(ssh_version); then
        read -r major minor <<<"${v}"
        if version_ge "${major}" "${minor}" "${MIN_SSH_MAJOR}" "${MIN_SSH_MINOR}"; then
            ok "OpenSSH ${major}.${minor} (need ${MIN_SSH_MAJOR}.${MIN_SSH_MINOR}+)"
        else
            bad "OpenSSH ${major}.${minor} is too old (need ${MIN_SSH_MAJOR}.${MIN_SSH_MINOR}+ for -O verify-required)"
            (( FAIL_COUNT++ ))
        fi
    else
        bad "cannot determine OpenSSH version"; (( FAIL_COUNT++ ))
    fi

    # --- git ---
    if v=$(git_version); then
        read -r major minor <<<"${v}"
        if version_ge "${major}" "${minor}" "${MIN_GIT_MAJOR}" "${MIN_GIT_MINOR}"; then
            ok "git ${major}.${minor} (need ${MIN_GIT_MAJOR}.${MIN_GIT_MINOR}+ for gpg.format=ssh)"
        else
            bad "git ${major}.${minor} is too old (need ${MIN_GIT_MAJOR}.${MIN_GIT_MINOR}+)"
            (( FAIL_COUNT++ ))
        fi
    else
        bad "git not found"; (( FAIL_COUNT++ ))
    fi

    # --- FIDO plumbing ---
    if helper=$(find_sk_helper); then
        # not piped into grep -q: an early grep exit SIGPIPEs ldd and pipefail
    # turns that into a false "not linked" (measured at ~0.7% of runs)
    if lddout=$(ldd "${helper}" 2>/dev/null) && grep -qi fido <<<"${lddout}"; then
            ok "ssh-sk-helper present and linked against libfido2"
            note "${helper}"
        else
            warn "ssh-sk-helper found but not linked against libfido2"
            note "${helper}"
            (( WARN_COUNT++ ))
        fi
    else
        bad "ssh-sk-helper not found -- install openssh-client"
        (( FAIL_COUNT++ ))
    fi

    # --- device ---
    if devs=$(fido_devices) && [[ -n ${devs} ]]; then
        ndev=$(printf '%s\n' "${devs}" | grep -c .)
        if (( ndev == 1 )); then
            ok "FIDO2 device detected"
        else
            warn "${ndev} FIDO2 devices detected -- leave only one plugged in"
            (( WARN_COUNT++ ))
        fi
        printf '%s\n' "${devs}" | while read -r line; do [[ -n ${line} ]] && note "${line}"; done
        # Process substitution, not a pipe: a piped while-loop runs in a
        # subshell and every WARN_COUNT++ inside it is discarded.
        while read -r dev; do
            [[ -c ${dev} ]] || continue
            if [[ -r ${dev} && -w ${dev} ]]; then
                note "${dev} readable and writable by ${USER}"
            else
                warn "${dev} not accessible -- check udev uaccess rules"
                note "the key cannot be used for signing until this is fixed"
                (( WARN_COUNT++ ))
            fi
        done < <(printf '%s\n' "${devs}" | cut -d: -f1)
    elif command -v fido2-token >/dev/null 2>&1; then
        warn "no FIDO2 device detected -- plug the YubiKey in"
        (( WARN_COUNT++ ))
    else
        info "fido2-tools not installed (optional, used for device detection)"
    fi

    # --- ykman ---
    if detect_ykman; then
        ok "ykman available: ${YKMAN}"
    else
        warn "ykman not available (needed only to manage the FIDO2 PIN)"
        (( WARN_COUNT++ ))
    fi
    if [[ -n ${YKMAN_BROKEN_SNAP} ]]; then
        warn "broken snap ykman shadowing PATH: ${YKMAN_BROKEN_SNAP}"
        note "snap-confine refuses to start it; use the apt package instead"
        (( WARN_COUNT++ ))
    fi

    # --- graphical tool (optional, never a failure) ---
    if [[ -x ${YA_DIR}/authenticator ]]; then
        info "Yubico Authenticator: ${YA_DIR}"
    elif flatpak info com.yubico.yubioath >/dev/null 2>&1; then
        info "Yubico Authenticator: flatpak (com.yubico.yubioath)"
    elif command -v ykman-gui >/dev/null 2>&1; then
        info "graphical tool: ykman-gui (retired upstream)"
    fi

    # --- FIDO2 PIN ---
    if [[ -n ${YKMAN} ]]; then
        read -r state retries <<<"$(fido_pin_state)"
        case ${state} in
            set)
                if [[ ${retries} == "-" ]]; then
                    ok "FIDO2 PIN is set"
                elif (( retries >= 5 )); then
                    ok "FIDO2 PIN is set (${retries} attempts remaining)"
                else
                    warn "FIDO2 PIN is set but only ${retries} attempts remain"
                    note "8 wrong attempts forces a reset that wipes every FIDO credential"
                    (( WARN_COUNT++ ))
                fi ;;
            unset)
                warn "no FIDO2 PIN set -- required before creating a resident key"
                (( WARN_COUNT++ )) ;;
            blocked)
                bad "FIDO2 PIN is BLOCKED -- no attempts left"
                note "signing cannot work until the FIDO applet is reset, and a"
                note "reset destroys every FIDO credential including this key"
                (( FAIL_COUNT++ )) ;;
            disabled|unsupported)
                warn "FIDO2 PIN reported as ${state} by ykman"
                (( WARN_COUNT++ )) ;;
            tempblocked)
                bad "FIDO2 PIN is temporarily blocked -- unplug and re-insert the key"
                (( FAIL_COUNT++ )) ;;
            mustchange)
                bad "the FIDO2 PIN must be changed before it can be used"
                note "ykman fido access change-pin"
                (( FAIL_COUNT++ )) ;;
            *)
                info "FIDO2 PIN state unknown (is the key plugged in?)" ;;
        esac
    fi

    # --- git configuration ---
    blank
    val=$(git config --global --get gpg.format 2>/dev/null)
    if [[ ${val} == ssh ]]; then ok "gpg.format = ssh"
    else bad "gpg.format is '${val:-unset}', expected 'ssh'"; (( FAIL_COUNT++ )); fi

    val=$(git config --global --get user.signingkey 2>/dev/null)
    if [[ -z ${val} ]]; then
        bad "user.signingkey is unset"; (( FAIL_COUNT++ ))
    elif [[ ${val} == *.pub ]]; then
        bad "user.signingkey points at a .pub file: ${val}"
        note "with a .pub, ssh-keygen asks the agent instead of the token"
        (( FAIL_COUNT++ ))
    elif [[ ! -f $(expand_tilde "${val}") ]]; then
        bad "user.signingkey file does not exist: ${val}"; (( FAIL_COUNT++ ))
    else
        ok "user.signingkey = ${val}"
        if [[ $(expand_tilde "${val}") == "${HOME}/.ssh/"* ]]; then
            warn "the key lives in ~/.ssh -- gcr-ssh-agent will advertise it and break signing"
            (( WARN_COUNT++ ))
        fi
    fi

    val=$(git config --global --get commit.gpgsign 2>/dev/null)
    if [[ ${val} == true ]]; then ok "commit.gpgsign = true"
    else warn "commit.gpgsign is '${val:-unset}' -- commits will not be signed by default"; (( WARN_COUNT++ )); fi

    val=$(git config --global --get gpg.ssh.allowedSignersFile 2>/dev/null)
    if [[ -z ${val} ]]; then
        warn "gpg.ssh.allowedSignersFile is unset -- you cannot verify your own signatures locally"
        (( WARN_COUNT++ ))
    elif [[ ! -f $(expand_tilde "${val}") ]]; then
        warn "allowed_signers file missing: ${val}"; (( WARN_COUNT++ ))
    else
        ok "allowed_signers = ${val}"
        if [[ -f ${KEY_PUB} ]]; then
            blob=$(pub_blob "${KEY_PUB}")
            if grep -qF -- "${blob#* }" "$(expand_tilde "${val}")" 2>/dev/null; then
                ok "signing key is listed in allowed_signers"
            else
                warn "signing key is NOT listed in allowed_signers"; (( WARN_COUNT++ ))
            fi
        fi
    fi

    # --- key file ---
    if [[ -f ${KEY_PRIV} ]]; then
        ok "key handle present: ${KEY_PRIV}"
        if [[ -f ${KEY_PUB} ]]; then
            app=$(pub_application "${KEY_PUB}")
            [[ -n ${app} ]] && note "application: ${app}"
            note "$(ssh-keygen -lf "${KEY_PUB}" 2>/dev/null)"
        fi
        if policy=$(sk_policy "${KEY_PRIV}"); then
            case ${policy} in
                none)
                    warn "signing policy: $(sk_policy_label none) -- anything on this machine can sign"
                    (( WARN_COUNT++ )) ;;
                *)
                    ok "signing policy: $(sk_policy_label "${policy}")" ;;
            esac
        fi
    else
        info "no key at ${KEY_PRIV} yet"
    fi

    # --- the gcr trap ---
    check_gcr

    # --- askpass ---
    blank
    if v=$(askpass_binary); then
        ok "askpass helper: ${v}"
        if [[ -n ${SSH_ASKPASS:-} ]]; then
            ok "SSH_ASKPASS is set in this shell"
        else
            info "SSH_ASKPASS not set in this shell (GUI git clients may not prompt for the PIN)"
        fi
    else
        warn "no askpass helper installed -- GUI git clients cannot prompt for the FIDO2 PIN"
        (( WARN_COUNT++ ))
    fi

    # --- sudo/login, only when something is configured (info only) ---
    if [[ -f ${PAM_U2F_FILE} ]]; then
        blank
        info "sudo/login: $(pam_mode_label "$(pam_detect_mode)") via pam_u2f"
    fi

    # --- Teleport PIV, only once you have opted in ---
    # Reports with info/warn only and touches no counter: a machine that does
    # not use Teleport must get the same exit code as before.
    if command -v tsh >/dev/null 2>&1 || [[ -f ${TELEPORT_ENV_FILE} ]]; then
        blank
        printf '  %s%s%s\n' "${BOLD}" "Teleport PIV readiness" "${RESET}"
        blank
        piv_teleport_report
    fi

    # --- summary ---
    blank
    if (( FAIL_COUNT == 0 && WARN_COUNT == 0 )); then
        ok "${BOLD}everything looks correct${RESET}"
    else
        printf '  %s%d failure(s), %d warning(s)%s\n' "${BOLD}" "${FAIL_COUNT}" "${WARN_COUNT}" "${RESET}"
    fi
    blank
}

# The trap that cost a session: gcr-ssh-agent advertises any keypair in ~/.ssh,
# and ssh-keygen prefers an agent holding a matching key over the file on disk.
check_gcr() {
    local blob listing
    GCR_FAILED=0
    blank
    if [[ -f "${HOME}/.ssh/${KEY_NAME}" || -f "${HOME}/.ssh/${KEY_NAME}.pub" ]]; then
        bad "a copy of the signing key is in ~/.ssh -- move it out"
        note "gcr-ssh-agent advertises any keypair it finds there"
        note "  mv ~/.ssh/${KEY_NAME}* ${KEY_DIR}/"
        # Deliberately NOT GCR_FAILED: that flag offers 'ssh-add -d' plus an
        # agent restart, which does nothing about a file sitting on disk.
        (( FAIL_COUNT++ ))
    fi
    [[ -f ${KEY_PUB} ]] || { info "agent interception check skipped (no key yet)"; return 0; }


    blob=$(pub_blob "${KEY_PUB}"); blob=${blob#* }
    listing=$(ssh-add -L 2>/dev/null)
    if [[ -z ${listing} ]]; then
        ok "no agent is advertising the signing key"
        return 0
    fi
    if printf '%s\n' "${listing}" | grep -qF -- "${blob}"; then
        bad "an ssh-agent is advertising the signing key -- signing will fail"
        note "ssh-keygen will delegate to the agent, which cannot drive a FIDO2 token"
        note "the agent caches keys in memory, so moving the file out is not enough"
        note "fix: use the 'Fix agent interception' menu item, or run:"
        note "  ssh-add -d ${KEY_PUB}"
        note "  systemctl --user restart gcr-ssh-agent.service"
        (( FAIL_COUNT++ )); GCR_FAILED=1
        return 1
    fi
    ok "no agent is advertising the signing key"
    return 0
}

# ----------------------------------------------------------------------------
# 1. Install management tools
# ----------------------------------------------------------------------------
apt_install() {
    local -a pkgs=("$@") missing=()
    local p
    for p in "${pkgs[@]}"; do
        dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q "ok installed" || missing+=("${p}")
    done
    if (( ${#missing[@]} == 0 )); then
        ok "already installed: ${pkgs[*]}"
        return 0
    fi
    info "will install: ${missing[*]}"
    confirm "Run sudo apt-get install?" y || { info "skipped"; return 1; }
    run_interactive sudo apt-get install -y "${missing[@]}"
}

# ----------------------------------------------------------------------------
# Yubico Authenticator -- official tarball
#
# Yubico ships no .deb for this app.  Their release index and the GitHub
# release for 7.5.0 both carry .tar.gz + detached .sig for Linux, .msi for
# Windows, .dmg for macOS -- no .deb anywhere.  So the install is: fetch,
# verify the signature against Yubico's published signing keys, unpack into
# ~/.local/opt, register the .desktop file.
# ----------------------------------------------------------------------------
YA_DIR="${HOME}/.local/opt/yubico-authenticator"
YA_LINK="${HOME}/.local/bin/yubico-authenticator"
YA_BASE_URL="https://developers.yubico.com/yubioath-flutter/Releases"
YA_GH_API="https://api.github.com/repos/Yubico/yubioath-flutter/releases/latest"
YA_SIGNING_URL="https://developers.yubico.com/Software_Projects/Software_Signing.html"

# Primary key fingerprints of the Yubico developers who currently sign
# releases, copied from ${YA_SIGNING_URL} on 2026-11-11.  A signature that
# does not chain to one of these is refused: "Good signature" on its own says
# only that *somebody* signed it.
YA_KEYS=(
    0A3B0262BCA1705307D5FF06BCA00FD4B2168C0A
    1D7308B0055F5AEF36944A8F27A9C24D9588EA0F
    20EE325B86A81BCBD3E56798F04367096FBA95E8
    268583B64786F50F807456DA8CED3A80D41C0DCB
    355C8C0186CC96CBA49F9CD8DAA17C2953914D9D
    57A9DEED4C6D962A923BB691816F3ED99921835E
    78D997D53E9C0A2A205392ED14A19784723C9988
    7FBB6186957496D58C751AC20E777DD85755AA4A
    9E885C0302F9BB9167529C2D5CBA11E6ADC7BCD1
    AF511D2CBC0F973E5D308054325C8E4AE2E6437D
    B6042E2BD1FDBC2BCA8588B2FF8D3B45B7B875A9
    B70D62AA6A31AD6B9E4F9F4BDC8888925D25CA7A
    C28ED3753F01B4B097A1B306948B29C5F1E063ED
    F475928225229F58460640EAD91777C175533EE5
)

ya_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  printf 'x64'   ;;
        aarch64|arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

# Latest tag from the GitHub release API; the filenames carry the same string.
ya_latest_version() {
    local tag
    tag=$(curl -fsSL --max-time 20 "${YA_GH_API}" 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [[ ${tag} =~ ^[0-9]+(\.[0-9]+)*[a-z]?$ ]] || return 1
    printf '%s' "${tag}"
}

ya_remote_size() {
    local bytes
    bytes=$(curl -fsSLI --max-time 20 "$1" 2>/dev/null \
        | grep -i '^content-length:' | tail -1 | tr -cd '0-9')
    [[ -n ${bytes} ]] || return 1
    printf '%s MB' "$(( bytes / 1048576 ))"
}

# Verify tarball against its detached signature in a throwaway keyring, then
# require the *primary* key to be one Yubico lists.  Yubico's own page warns
# that the signature's issuer may be a subkey, so the issuer cannot be
# checked against the list directly -- only VALIDSIG's primary fingerprint.
ya_gpg_cleanup() {
    GNUPGHOME="$1" gpgconf --kill all >/dev/null 2>&1
    rm -rf "$1"
}

ya_verify() {
    local tarball=$1 sig=$2
    local gnupghome packets issuer status primary ks k rc=1

    if ! command -v gpg >/dev/null 2>&1; then
        bad "gpg is not installed -- cannot verify the download"
        note "install it with: sudo apt-get install gnupg"
        return 1
    fi

    gnupghome=$(mktemp -d) || return 1
    chmod 700 "${gnupghome}"

    packets=$(GNUPGHOME="${gnupghome}" gpg --list-packets "${sig}" 2>/dev/null)
    # Prefer the full fingerprint subpacket; fall back to the 64-bit key id,
    # which is all an older signature carries.
    issuer=$(grep -oiE 'issuer fpr[^)]*[0-9A-F]{40}' <<<"${packets}" \
        | grep -oiE '[0-9A-F]{40}' | head -1)
    [[ -n ${issuer} ]] || issuer=$(grep -oiE 'keyid [0-9A-F]{16}' <<<"${packets}" \
        | grep -oiE '[0-9A-F]{16}' | head -1)
    if [[ -z ${issuer} ]]; then
        bad "could not read the signature -- is it a detached OpenPGP signature?"
        ya_gpg_cleanup "${gnupghome}"; return 1
    fi
    info "signed by key ${issuer}"

    for ks in hkps://keys.openpgp.org hkps://keyserver.ubuntu.com; do
        info "fetching the signing key from ${ks#hkps://}"
        GNUPGHOME="${gnupghome}" gpg --batch --quiet \
            --keyserver "${ks}" --recv-keys "${issuer}" 2>/dev/null
        # gpg exits 0 for "new key but contains no user ID - skipped", which
        # keys.openpgp.org returns for several Yubico signers. Taking that as
        # success skips the next keyserver and the verify then fails with
        # NO_PUBKEY, which we would have reported as a BAD SIGNATURE.
        if GNUPGHOME="${gnupghome}" gpg --batch --list-keys "${issuer}" \
                >/dev/null 2>&1; then
            rc=0; break
        fi
        info "${ks#hkps://} returned no usable key, trying the next one"
    done
    if (( rc != 0 )); then
        # Last resort: the user's own keyring. The hints below used to tell
        # people to 'gpg --recv-keys' into ~/.gnupg and re-run, which could
        # never help, because this function only ever looked at keyservers.
        if gpg --batch --export "${issuer}" 2>/dev/null \
                | GNUPGHOME="${gnupghome}" gpg --batch --quiet --import 2>/dev/null \
           && GNUPGHOME="${gnupghome}" gpg --batch --list-keys "${issuer}" >/dev/null 2>&1; then
            info "using the copy already in your own keyring"
            rc=0
        fi
    fi
    if (( rc != 0 )); then
        bad "could not fetch the signing key -- refusing to install unverified"
        # Deliberately not printing the download paths: the caller removes the
        # working directory as soon as this returns, so a command naming them
        # would fail with "No such file or directory".
        note "import the key, then run this step again:"
        note "  gpg --recv-keys ${issuer}"
        note "check it against ${YA_SIGNING_URL} first"
        ya_gpg_cleanup "${gnupghome}"; return 1
    fi

    status=$(GNUPGHOME="${gnupghome}" gpg --batch --status-fd 1 \
        --verify "${sig}" "${tarball}" 2>/dev/null)
    ya_gpg_cleanup "${gnupghome}"

    if ! grep -q '^\[GNUPG:\] GOODSIG' <<<"${status}"; then
        # Say which failure it is. "BAD SIGNATURE" for a missing or expired key
        # accuses the file of something it did not do.
        if grep -q '^\[GNUPG:\] NO_PUBKEY' <<<"${status}"; then
            bad "no public key for this signature -- cannot verify"
            note "fetch it yourself and retry:  gpg --recv-keys ${issuer}"
        elif grep -q '^\[GNUPG:\] EXPKEYSIG' <<<"${status}"; then
            bad "the signing key has expired -- not installing"
        elif grep -q '^\[GNUPG:\] REVKEYSIG' <<<"${status}"; then
            bad "the signing key has been REVOKED -- do not install this"
        else
            bad "BAD SIGNATURE -- the download does not match the signature"
            note "the download has been discarded; do not try to recover it"
        fi
        return 1
    fi
    primary=$(awk '/^\[GNUPG:\] VALIDSIG/ { print $12 }' <<<"${status}" | head -1)
    if [[ -z ${primary} ]]; then
        bad "gpg reported no primary key fingerprint -- refusing to install"
        return 1
    fi

    for k in "${YA_KEYS[@]}"; do
        if [[ ${primary} == "${k}" ]]; then
            ok "good signature from a published Yubico key"
            note "primary key ${primary}"
            return 0
        fi
    done

    bad "signed by a key Yubico does not list: ${primary}"
    note "the signature is valid but the key is not one of the 14 this script"
    note "knows about -- Yubico may have added a signer since 2026-11-11"
    note "check the list before trusting it: ${YA_SIGNING_URL}"
    return 1
}

install_yubico_authenticator() {
    local arch version base url sig_url workdir tarball sig size staging backup c
    local listing

    for c in curl tar; do
        command -v "${c}" >/dev/null 2>&1 || { bad "${c} is required"; return 1; }
    done

    arch=$(ya_arch) || {
        bad "no official build for $(uname -m) -- Yubico ships x64 and arm64 only"
        return 1
    }

    info "asking GitHub for the current release"
    version=$(ya_latest_version)
    if [[ -z ${version} ]]; then
        warn "could not read the latest version automatically"
        version=$(ask "Version to install (see ${YA_BASE_URL})")
        [[ -n ${version} ]] || { info "cancelled"; return 1; }
    fi

    base="yubico-authenticator-${version}-linux-${arch}.tar.gz"
    url="${YA_BASE_URL}/${base}"
    sig_url="${url}.sig"
    size=$(ya_remote_size "${url}") || size="unknown size"

    blank
    info "version:     ${version}"
    info "file:        ${base}  (${size})"
    info "from:        ${YA_BASE_URL}/"
    info "installs to: ${YA_DIR}"
    blank
    note "this downloads a tarball and its OpenPGP signature, checks the"
    note "signature against Yubico's published signing keys, and unpacks it"
    note "under your home directory -- nothing is installed system-wide"
    blank
    confirm "Download and install?" y || { info "cancelled"; return 1; }

    workdir=$(mktemp -d) || return 1
    tarball="${workdir}/${base}"
    sig="${workdir}/${base}.sig"

    blank
    info "downloading the tarball"
    if ! curl -fL --progress-bar --max-time 900 -o "${tarball}" "${url}"; then
        bad "download failed: ${url}"
        note "check the version against ${YA_BASE_URL}"
        rm -rf "${workdir}"; return 1
    fi
    info "downloading the signature"
    if ! curl -fsSL --max-time 60 -o "${sig}" "${sig_url}"; then
        bad "could not fetch the signature -- refusing to install unverified"
        rm -rf "${workdir}"; return 1
    fi

    blank
    if ! ya_verify "${tarball}" "${sig}"; then
        rm -rf "${workdir}"
        return 1
    fi

    # Refuse anything that would write outside the staging directory.
    #
    # This MUST NOT be piped into grep -q: grep exits at the first match, tar
    # takes SIGPIPE, and under 'set -o pipefail' the pipeline returns 141, so
    # the 'if' is false and the guard silently fails open. Measured: on a
    # 20k-entry archive whose first member is /etc/passwd, the piped form let
    # it through 10 times out of 10. Read the listing into a variable first.
    if ! listing=$(tar -tzf "${tarball}" 2>/dev/null) || [[ -z ${listing} ]]; then
        bad "could not read the archive listing -- refusing to unpack"
        rm -rf "${workdir}"; return 1
    fi
    if grep -qE '^/|(^|/)\.\.(/|$)' <<<"${listing}"; then
        bad "the archive contains absolute or parent paths -- refusing to unpack"
        rm -rf "${workdir}"; return 1
    fi

    mkdir -p "${HOME}/.local/opt" || { rm -rf "${workdir}"; return 1; }
    staging=$(mktemp -d "${HOME}/.local/opt/.ya-stage-XXXXXX") || {
        rm -rf "${workdir}"; return 1
    }
    # The link check below resolves each target with realpath, so the staging
    # path has to be resolved too. If ~/.local or ~/.local/opt is a symlink --
    # stow and dotfile managers do this -- every legitimate link would resolve
    # to a different prefix and the install would be refused.
    staging=$(realpath -- "${staging}" 2>/dev/null) || {
        bad "could not resolve the staging directory"; rm -rf "${workdir}"; return 1
    }
    blank
    info "unpacking"
    # --strip-components=1: the directory inside the tarball is not named
    # after the file, so do not depend on either name.
    if ! tar -xzf "${tarball}" -C "${staging}" --strip-components=1; then
        bad "unpacking failed"
        rm -rf "${workdir}" "${staging}"; return 1
    fi
    rm -rf "${workdir}"

    # Link containment, checked AFTER extraction by resolving each link.
    #
    # Matching the target text from 'tar -tv' is both too narrow and too broad:
    # it misses './../..', bare '..' and 'a/../../..', while rejecting a
    # perfectly legal '../sibling' that stays inside the archive. GNU tar also
    # rewrites hardlink targets before printing them, so that half never fires.
    # Resolving the extracted link is the only test that means anything.
    local l target bad_link=""
    while IFS= read -r l; do
        [[ -z ${l} ]] && continue
        target=$(realpath -m -- "${l}" 2>/dev/null) || target=""
        case ${target} in
            "${staging}"|"${staging}"/*) ;;
            *) bad_link=${l}; break ;;
        esac
    done < <(find "${staging}" -type l 2>/dev/null)
    if [[ -n ${bad_link} ]]; then
        bad "the archive contains a link pointing outside it -- refusing"
        note "${bad_link#"${staging}"/} -> $(readlink -- "${bad_link}" 2>/dev/null)"
        rm -rf "${staging}"; return 1
    fi

    # -x follows symlinks, so this must come after the containment check.
    if [[ ! -x ${staging}/authenticator ]]; then
        bad "no 'authenticator' binary in the archive -- not installing"
        rm -rf "${staging}"; return 1
    fi

    backup=""
    if [[ -e ${YA_DIR} ]]; then
        backup="${YA_DIR}.bak-$(date +%Y%m%d-%H%M%S)"
        if ! mv "${YA_DIR}" "${backup}"; then
            bad "could not move the existing install aside"
            rm -rf "${staging}"; return 1
        fi
    fi
    if ! mv "${staging}" "${YA_DIR}"; then
        bad "could not move the new version into place"
        [[ -n ${backup} ]] && mv "${backup}" "${YA_DIR}"
        rm -rf "${staging}"; return 1
    fi
    ok "installed: ${YA_DIR}/authenticator"
    [[ -n ${backup} ]] && note "previous version kept at ${backup}"

    # The desktop file bakes in an absolute path, so run this only once the
    # directory is at its final location.
    if [[ -x ${YA_DIR}/desktop_integration.sh ]]; then
        # upstream writes the .desktop file with > and never creates the dir
        mkdir -p "${HOME}/.local/share/applications"
        run_interactive "${YA_DIR}/desktop_integration.sh" --install
    else
        warn "no desktop_integration.sh in the archive -- no menu entry created"
    fi

    mkdir -p "${HOME}/.local/bin"
    if ln -sfn "${YA_DIR}/authenticator" "${YA_LINK}"; then
        ok "command: ${YA_LINK}"
        case ":${PATH}:" in
            *":${HOME}/.local/bin:"*) ;;
            *) note "~/.local/bin is not on PATH in this shell" ;;
        esac
    fi

    blank
    info "the app talks to the YubiKey two different ways:"
    note "FIDO2 (PIN, passkeys) goes over USB HID -- udev handles access"
    note "PIV and OATH go over the smartcard interface -- that needs pcscd"
    blank
    # Guard exactly as step_piv_teleport does: without this, declining the
    # install leads to an offer to enable a unit that does not exist.
    if ! apt_install pcscd || \
       ! dpkg-query -W -f='${Status}' pcscd 2>/dev/null | grep -q 'ok installed'; then
        warn "pcscd is not installed -- PIV and OATH will not work in the app"
    elif command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet pcscd.socket || systemctl is-active --quiet pcscd; then
            ok "pcscd is running"
        elif systemctl is-enabled --quiet pcscd.socket 2>/dev/null; then
            ok "pcscd.socket is enabled (starts on demand)"
        else
            warn "pcscd is not enabled -- PIV and OATH will not work"
            confirm "Enable pcscd.socket now?" y \
                && run_interactive sudo systemctl enable --now pcscd.socket
        fi
    fi

    blank
    note "optional: QR-code scanning on Wayland needs gnome-screenshot"
    note "upgrades are manual -- rerun this step when a new version lands"
}

install_yubico_authenticator_flatpak() {
    warn "the Flathub build is not publisher-verified and trails upstream"
    note "Flathub reports verified:false for com.yubico.yubioath, and its"
    note "newest build was 7.4.1 when this script was written"
    blank
    confirm "Install it anyway?" n || { info "skipped"; return 0; }

    if ! command -v flatpak >/dev/null 2>&1; then
        apt_install flatpak || return 1
    fi
    # --user install needs a USER-scope remote; a system one does not satisfy it
    if ! flatpak remotes --user 2>/dev/null | grep -q flathub; then
        info "adding the flathub remote (user scope)"
        run_interactive flatpak remote-add --if-not-exists --user \
            flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    fi
    run_interactive flatpak install --user -y flathub com.yubico.yubioath
}

step_install_tools() {
    section "YubiKey management tools"

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "apt-get not found -- this step only supports Debian/Ubuntu"
        note "install the equivalents by hand: yubikey-manager, fido2-tools"
        pause; return 1
    fi

    info "CLI/TUI tool: ykman (package: yubikey-manager)"
    info "device detection: fido2-tools"
    blank
    apt_install yubikey-manager fido2-tools

    detect_ykman
    if [[ -n ${YKMAN_BROKEN_SNAP} ]]; then
        blank
        warn "a snap-installed ykman is shadowing PATH and cannot start"
        note "${YKMAN_BROKEN_SNAP}"
        if confirm "Remove the broken snap?" n; then
            run_interactive sudo snap remove yubikey-manager
        elif [[ -x /usr/bin/ykman ]] && /usr/bin/ykman --version >/dev/null 2>&1; then
            note "use the full path /usr/bin/ykman to avoid it"
        else
            note "install the apt package to get a working ykman:"
            note "  sudo apt-get install yubikey-manager"
        fi
    fi

    blank
    ui_menu "Graphical tool (optional)" \
        "Yubico Authenticator -- official tarball from yubico.com, signature checked" \
        "Yubico Authenticator -- Flathub build (not publisher-verified, trails upstream)" \
        "YubiKey Manager Qt   -- apt, retired upstream" \
        "Skip -- the command line is enough" || { info "skipped"; return 0; }

    case ${MENU_INDEX} in
        0) install_yubico_authenticator ;;
        1) install_yubico_authenticator_flatpak ;;
        2)
            apt_install yubikey-manager-qt
            note "upstream retired this app; Debian/Ubuntu still carry 1.2.5"
            ;;
        3) info "skipped" ;;
    esac
    pause
}

# ----------------------------------------------------------------------------
# 2. Initial FIDO2 setup
# ----------------------------------------------------------------------------
step_fido_init() {
    local state retries

    section "FIDO2 applet setup"

    if ! detect_ykman; then
        bad "ykman is not available"
        note "run 'Install the YubiKey management tools' from the menu first"
        pause; return 1
    fi
    require_device || { pause; return 1; }

    info "current state:"
    blank
    "${YKMAN}" fido info 2>&1 | while read -r line; do note "${line}"; done
    blank

    read -r state retries <<<"$(fido_pin_state)"
    case ${state} in
        unset)
            warn "no FIDO2 PIN is set"
            note "a PIN is required before a resident credential can be created"
            blank
            if confirm "Set a FIDO2 PIN now?" y; then
                hint "This is the FIDO2 PIN, NOT your PIV PIN. 4-63 characters."
                run_interactive "${YKMAN}" fido access change-pin
            fi
            ;;
        set)
            if [[ ${retries} == "-" ]]; then
                ok "a FIDO2 PIN is already set"
            else
                ok "a FIDO2 PIN is already set (${retries} attempts remaining)"
            fi
            blank
            if confirm "Change the FIDO2 PIN?" n; then
                hint "You will be asked for the CURRENT FIDO2 PIN first."
                run_interactive "${YKMAN}" fido access change-pin
            fi
            ;;
        tempblocked)
            bad "the FIDO2 PIN is temporarily blocked"
            note "unplug the YubiKey and put it back in to clear this"
            ;;
        mustchange)
            warn "the FIDO2 PIN must be changed before it can be used"
            confirm "Change it now?" y && run_interactive "${YKMAN}" fido access change-pin
            ;;
        blocked)
            bad "the FIDO2 PIN is BLOCKED -- every attempt has been used"
            note "only a FIDO2 reset clears this, and it destroys every"
            note "credential on the applet, including the git signing key"
            ;;
        disabled|unsupported)
            warn "ykman reports the FIDO2 PIN as ${state}"
            ;;
        *)
            warn "could not read the PIN state"
            ;;
    esac

    blank
    hint "Advanced: a FIDO2 reset erases EVERY FIDO credential and passkey on this"
    hint "YubiKey, for every site, and cannot be undone. Only do this on a new key."
    if confirm "Show the reset option?" n; then
        if confirm_typed "RESET" "This wipes all FIDO2 credentials on the device."; then
            note "the device must be re-inserted immediately before a reset is accepted"
            run_interactive "${YKMAN}" fido reset
        else
            info "reset cancelled"
        fi
    fi
    pause
}

# ----------------------------------------------------------------------------
# Shared: install key files + wire up git
# ----------------------------------------------------------------------------
BACKUP_PRIV=""
BACKUP_PUB=""

backup_existing_key() {
    local stamp
    BACKUP_PRIV=""; BACKUP_PUB=""
    [[ -f ${KEY_PRIV} || -f ${KEY_PUB} ]] || return 0
    stamp=$(date +%Y%m%d-%H%M%S)
    if [[ -f ${KEY_PRIV} ]] && mv "${KEY_PRIV}" "${KEY_PRIV}.bak-${stamp}"; then
        BACKUP_PRIV="${KEY_PRIV}.bak-${stamp}"
    fi
    if [[ -f ${KEY_PUB} ]] && mv "${KEY_PUB}" "${KEY_PUB}.bak-${stamp}"; then
        BACKUP_PUB="${KEY_PUB}.bak-${stamp}"
    fi
    info "existing key backed up with suffix .bak-${stamp}"
}

# If key creation fails we must not leave git pointing at a missing file.
# The new key is in place; the backup is now just an old file on disk, not
# something to be put back. Clearing the markers disarms abort_cleanup.
backup_commit() { BACKUP_PRIV=""; BACKUP_PUB=""; }

restore_backup() {
    local restored=0
    [[ -n ${BACKUP_PRIV} && -f ${BACKUP_PRIV} ]] && mv "${BACKUP_PRIV}" "${KEY_PRIV}" && restored=1
    [[ -n ${BACKUP_PUB}  && -f ${BACKUP_PUB}  ]] && mv "${BACKUP_PUB}"  "${KEY_PUB}"  && restored=1
    BACKUP_PRIV=""; BACKUP_PUB=""
    (( restored )) && info "previous key restored"
    return 0
}

update_allowed_signers() {
    local pub=$1 email=$2 blob b64 tmp
    blob=$(pub_blob "${pub}")
    b64=${blob#* }
    mkdir -p "$(dirname "${ALLOWED_SIGNERS}")"
    touch "${ALLOWED_SIGNERS}"
    tmp=$(mktemp) || return 1
    grep -vF -- "${b64}" "${ALLOWED_SIGNERS}" > "${tmp}" 2>/dev/null
    printf '%s %s\n' "${email}" "${blob}" >> "${tmp}"
    mv "${tmp}" "${ALLOWED_SIGNERS}"
    chmod 644 "${ALLOWED_SIGNERS}"
    ok "allowed_signers updated: ${ALLOWED_SIGNERS}"
}

configure_git() {
    local email=$1 name
    name=$(git config --global --get user.name 2>/dev/null)
    if [[ -z ${name} ]]; then
        name=$(ask "Your name for git commits")
        [[ -n ${name} ]] && git config --global user.name "${name}"
    fi
    git config --global user.email "${email}"
    git config --global gpg.format ssh
    git config --global user.signingkey "${KEY_PRIV}"
    git config --global gpg.ssh.allowedSignersFile "${ALLOWED_SIGNERS}"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
    ok "git configured (user.signingkey = ${KEY_PRIV})"
}

resolve_email() {
    local email
    email=$(git config --global --get user.email 2>/dev/null)
    [[ -z ${email} ]] && email=$(ask "Email for the signing identity")
    printf '%s' "${email}"
}

run_test_commit() {
    local dir rc
    dir=$(mktemp -d) || { bad "cannot create a temporary directory"; return 1; }
    ( cd "${dir}" && git init -q \
        && run_interactive git commit --allow-empty -m "signing test" \
        && git log --show-signature -1 \
        && git verify-commit HEAD )
    rc=$?
    rm -rf "${dir}"
    blank
    if (( rc == 0 )); then
        ok "signing works and the signature verifies against allowed_signers"
    else
        bad "the test commit did not produce a verifiable signature"
    fi
    return ${rc}
}

post_install_checks() {
    blank
    if ! check_gcr; then
        blank
        if confirm "Fix it now (remove the key from the running agent)?" y; then
            fix_agent_core
        fi
    fi
    blank
    local needs
    needs=$(sk_policy_needs "$(sk_policy "${KEY_PRIV}")")
    if confirm "Run a real test commit now? (needs ${needs})" y; then
        run_test_commit
    fi
}

# ----------------------------------------------------------------------------
# 3. Create the git signing credential
# ----------------------------------------------------------------------------
step_create_key() {
    local email state retries app policy
    local -a sk_opts=()

    section "Create a FIDO2 credential for git signing"

    require_device || { pause; return 1; }

    if detect_ykman; then
        read -r state retries <<<"$(fido_pin_state)"
        if [[ ${state} == unset ]]; then
            bad "no FIDO2 PIN is set"
            note "run 'Set the FIDO2 PIN' from the menu first"
            note "a resident credential cannot be created without a PIN"
            pause; return 1
        fi
        case ${state} in
            tempblocked)
                bad "the FIDO2 PIN is temporarily blocked -- ssh-keygen would fail"
                note "unplug the YubiKey and put it back in, then try again"
                pause; return 1 ;;
            mustchange)
                bad "the FIDO2 PIN must be changed before it can be used"
                note "run 'Set the FIDO2 PIN' from the menu, or: ykman fido access change-pin"
                pause; return 1 ;;
            blocked)
                bad "the FIDO2 PIN is blocked -- every attempt has been used"
                note "only a FIDO2 reset clears this, and it wipes every credential"
                pause; return 1 ;;
        esac
        [[ ${retries} != "-" ]] && info "FIDO2 PIN: ${retries} attempts remaining"
    fi

    # Never clobber a working credential.
    if [[ -f ${KEY_PRIV} ]]; then
        blank
        warn "a signing key already exists at ${KEY_PRIV}"
        app=$(pub_application "${KEY_PUB}" 2>/dev/null)
        [[ -n ${app} ]] && note "application: ${app}"
        note "creating a new credential with the same application string replaces"
        note "the one on the YubiKey. Every place it is enrolled stops verifying."
        blank
        if ! confirm_typed "REGENERATE" "This invalidates your current signing key everywhere it is enrolled."; then
            info "cancelled -- use 'Reimport' if you just need the key on this machine"
            pause; return 1
        fi
    fi

    email=$(resolve_email)
    [[ -z ${email} ]] && { bad "no email given"; pause; return 1; }

    blank
    ui_menu "Protection for each signature" \
        "FIDO2 PIN + touch   (recommended; GUI clients need an askpass helper)" \
        "Touch only          (simpler for IDE commits, no PIN per signature)" \
        || { info "cancelled"; return 1; }
    if (( MENU_INDEX == 0 )); then policy=pin+touch; else policy=touch; fi
    mapfile -t sk_opts < <(sk_policy_opts "${policy}")

    mkdir -p -m 700 "${KEY_DIR}"
    backup_existing_key

    blank
    hint "The YubiKey will ask for the FIDO2 PIN (not the PIV PIN), then a touch."
    hint "If ssh-keygen reports that a resident key already exists on the token,"
    hint "answer n and use Reimport -- answering y replaces that credential."
    blank
    if ! run_interactive ssh-keygen -t ed25519-sk \
            -O resident -O application="${SK_APPLICATION}" "${sk_opts[@]}" \
            -C "${email} git signing" -N "" -f "${KEY_PRIV}"; then
        bad "key generation failed"
        note "firmware older than 5.2.3 does not support ed25519-sk -- try -t ecdsa-sk"
        restore_backup
        pause; return 1
    fi

    backup_commit
    chmod 700 "${KEY_DIR}"; chmod 600 "${KEY_PRIV}"; chmod 644 "${KEY_PUB}"
    ok "each signature will need $(sk_policy_needs "${policy}")"
    configure_git "${email}"
    update_allowed_signers "${KEY_PUB}" "${email}"
    post_install_checks
    blank
    step_github_instructions
    pause
}

# ----------------------------------------------------------------------------
# 6. Reimport an existing resident credential
# ----------------------------------------------------------------------------
step_reimport() {
    local tmp email found pub priv app base new_policy

    section "Reimport an existing FIDO2 git signing key"

    require_device || { pause; return 1; }

    info "ssh-keygen -K downloads every resident SSH credential on the key"
    info "into the current directory; we run it in a scratch directory and keep"
    info "only the one whose application is ${SK_APPLICATION}."
    blank
    hint "You will be asked for the FIDO2 PIN (not the PIV PIN), then a touch."
    blank

    tmp=$(mktemp -d) || { bad "cannot create a temporary directory"; pause; return 1; }
    if ! ( cd "${tmp}" && run_interactive ssh-keygen -K -N "" ); then
        bad "download failed"
        note "if it says 'no keys to download', the credential is not resident:"
        note "regenerate it with -O resident, or copy the key files by hand"
        rm -rf "${tmp}"; pause; return 1
    fi

    found=""
    for pub in "${tmp}"/*.pub; do
        [[ -f ${pub} ]] || continue
        app=$(pub_application "${pub}")
        base=${pub%.pub}
        info "found $(basename "${base}")  ${G_ARROW}  ${app:-no application}"
        [[ ${app} == "${SK_APPLICATION}" ]] && found="${base}"
    done

    if [[ -z ${found} ]]; then
        blank
        bad "no resident credential with application ${SK_APPLICATION}"
        note "use 'Create' instead, or check you are using the right YubiKey"
        rm -rf "${tmp}"; pause; return 1
    fi

    priv="${found}"; pub="${found}.pub"
    blank
    ok "matched $(basename "${priv}")"

    email=$(resolve_email)
    [[ -z ${email} ]] && { bad "no email given"; rm -rf "${tmp}"; pause; return 1; }

    mkdir -p -m 700 "${KEY_DIR}"
    backup_existing_key
    if ! { mv "${priv}" "${KEY_PRIV}" && mv "${pub}" "${KEY_PUB}"; }; then
        bad "could not move the key into ${KEY_DIR}"
        restore_backup
        rm -rf "${tmp}"; pause; return 1
    fi
    rm -rf "${tmp}"
    chmod 700 "${KEY_DIR}"; chmod 600 "${KEY_PRIV}"; chmod 644 "${KEY_PUB}"
    ok "installed as ${KEY_PRIV}"
    new_policy=$(sk_policy "${KEY_PRIV}") \
        && info "each signature will need $(sk_policy_needs "${new_policy}")"

    configure_git "${email}"
    update_allowed_signers "${KEY_PUB}" "${email}"
    post_install_checks
    pause
}

# ----------------------------------------------------------------------------
# 4. GUI askpass
# ----------------------------------------------------------------------------
step_askpass() {
    local bin

    section "GUI askpass helper"

    info "With 'verify-required', the FIDO2 PIN prompt goes to /dev/tty."
    info "Commits from VS Code, JetBrains or any GUI client have no tty, so they"
    info "fail unless an askpass helper can show a dialog instead."
    blank

    if bin=$(askpass_binary); then
        ok "already installed: ${bin}"
    else
        info "installing ssh-askpass-gnome"
        apt_install ssh-askpass-gnome || { pause; return 1; }
        bin=$(askpass_binary) || { bad "still no askpass helper found"; pause; return 1; }
        ok "installed: ${bin}"
    fi

    blank
    if confirm "Set SSH_ASKPASS for GUI sessions (${ENV_FILE})?" y; then
        mkdir -p "${ENV_DIR}"
        if ! {
            printf '# written by yubikey-git-signing.sh\n'
            printf 'SSH_ASKPASS=%s\n' "${bin}"
        } > "${ENV_FILE}"; then
            bad "could not write ${ENV_FILE}"
            pause; return 1
        fi
        ok "wrote ${ENV_FILE}"
        note "systemd user sessions read this at login -- log out and back in"

        blank
        hint "SSH_ASKPASS_REQUIRE=prefer makes even terminal commits pop a GUI dialog."
        hint "Leave it off if you prefer typing the PIN in the terminal."
        if confirm "Also set SSH_ASKPASS_REQUIRE=prefer?" n; then
            printf 'SSH_ASKPASS_REQUIRE=prefer\n' >> "${ENV_FILE}"
            ok "added SSH_ASKPASS_REQUIRE=prefer"
        fi
    fi
    pause
}

# ----------------------------------------------------------------------------
# GitHub enrolment
# ----------------------------------------------------------------------------
step_github_instructions() {
    local email

    section "Enrol the public key on GitHub"

    if [[ ! -f ${KEY_PUB} ]]; then
        warn "no public key at ${KEY_PUB} yet -- create or reimport one first"
        pause; return 1
    fi

    email=$(git config --global --get user.email 2>/dev/null)

    printf '  %s1.%s open %shttps://github.com/settings/ssh/new%s\n' "${BOLD}" "${RESET}" "${ACCENT}" "${RESET}"
    printf '  %s2.%s set %sKey type%s to %sSigning Key%s  (NOT Authentication Key)\n' \
        "${BOLD}" "${RESET}" "${BOLD}" "${RESET}" "${BOLD}" "${RESET}"
    printf '  %s3.%s give it a title, e.g. "YubiKey git signing"\n' "${BOLD}" "${RESET}"
    printf '  %s4.%s paste the key below into %sKey%s\n' "${BOLD}" "${RESET}" "${BOLD}" "${RESET}"
    blank
    printf '%s%s%s\n' "${MUTED}" "$(cat "${KEY_PUB}")" "${RESET}"
    blank
    note "the same key may also be added separately as an Authentication Key"
    if [[ -n ${email} ]]; then
        note "for the Verified badge, ${email} must be a verified email on the account"
    fi
    blank

    if clipboard_copy "${KEY_PUB}"; then
        ok "public key copied to the clipboard"
    else
        info "no clipboard tool available (install wl-clipboard or xclip)"
    fi

    # gh is an outward-facing action: always ask.
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        blank
        if confirm "Upload it to GitHub now with gh?" n; then
            run_interactive gh ssh-key add "${KEY_PUB}" --type signing --title "YubiKey git signing"
        fi
    fi
    # Explicit: without this the function returns whatever the last command
    # said, so declining the upload, or a failed gh, would read as the no-key
    # early return and the caller would skip its pause.
    return 0
}

# step_github_instructions returns non-zero ONLY on its no-key early return,
# where it has already paused. Any other outcome -- including a failed
# 'gh ssh-key add' -- must still pause, or the menu redraw wipes the error.
step_github() { step_github_instructions || return 0; pause; }

# ----------------------------------------------------------------------------
# Remediation: un-advertise the key from a running agent
# ----------------------------------------------------------------------------
fix_agent_core() {
    local blob listing

    if [[ ! -f ${KEY_PUB} ]]; then
        warn "no signing key yet -- nothing to un-advertise"
        return 1
    fi

    blob=$(pub_blob "${KEY_PUB}"); blob=${blob#* }
    listing=$(ssh-add -L 2>/dev/null)
    if ! grep -qF -- "${blob}" <<<"${listing}"; then
        ok "no agent is advertising the signing key -- nothing to do"
        return 0
    fi

    warn "an ssh-agent is advertising the signing key"
    info "gcr-ssh-agent picks up keypairs found in ~/.ssh and keeps them cached"
    info "in memory, so moving the file out is not enough once it is loaded."
    info "ssh-keygen prefers an agent holding a matching key over the file on"
    info "disk, and gcr cannot drive a FIDO2 token -- hence 'agent refused'."
    blank

    if confirm "Remove it from the running agent?" y; then
        run_interactive ssh-add -d "${KEY_PUB}"
    fi

    listing=$(ssh-add -L 2>/dev/null)
    if grep -qF -- "${blob}" <<<"${listing}"; then
        blank
        warn "still advertised -- the agent needs a restart"
        if confirm "Restart gcr-ssh-agent?" y; then
            run_interactive systemctl --user restart gcr-ssh-agent.service
        fi
    fi

    blank
    listing=$(ssh-add -L 2>/dev/null)
    if grep -qF -- "${blob}" <<<"${listing}"; then
        bad "the key is still advertised"
        note "fall back to a wrapper script set as gpg.ssh.program that does:"
        note '  unset SSH_AUTH_SOCK; exec /usr/bin/ssh-keygen "$@"'
        note "it must be a script -- git does not shell-split that setting"
        return 1
    fi
    ok "the agent no longer advertises the signing key"
    return 0
}

step_fix_agent() {
    section "Fix agent interception"
    fix_agent_core
    pause
}

# ----------------------------------------------------------------------------
# Menu
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# PIV preparation for Teleport
#
# Teleport's hardware key support reaches the PIV applet over PC/SC through
# go-piv -- not PKCS#11, and not an ssh-agent.  That is a different applet and
# a different transport from the FIDO2 key used for git signing above, so the
# two coexist.  What breaks Teleport is anything else holding the card:
# piv-go connects with SCARD_SHARE_EXCLUSIVE.
#
# This step only prepares the ground.  It deliberately creates no key and
# never touches the management key: tsh generates its own key on first login
# with the policy the cluster asks for, signs it into the slot with an
# O=teleport certificate, and requires the factory management key to do so.
# ----------------------------------------------------------------------------
TELEPORT_ENV_FILE="${ENV_DIR}/20-teleport.conf"

# true when $1 >= $2, comparing dotted version strings
# ykman can only report whether the PIN, PUK and management key are still the
# factory values on firmware 5.3 and later: yubikit's *_metadata calls are
# version-gated and ykman swallows the NotSupportedError. On older firmware the
# warnings simply never appear, and reading that absence as "not default" would
# have us offer a destructive reset on a factory-fresh key.
piv_reports_defaults() {
    local v
    v=$(printf '%s\n' "$1" | sed -n 's/^PIV version:[[:space:]]*//p' | head -1)
    [[ -z ${v} ]] && return 1
    ver_at_least "${v}" 5.3.0
}

ver_at_least() {
    [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1) == "$2" ]]
}

# Teleport's default slot per cluster policy, from
# api/utils/keys/hardwarekey/slot.go
piv_slot_policy() {
    case $1 in
        9a) printf 'hardware_key' ;;
        9c) printf 'hardware_key_touch' ;;
        9d) printf 'hardware_key_touch_and_pin' ;;
        9e) printf 'hardware_key_pin' ;;
        *)  printf 'unknown' ;;
    esac
}

# Processes connected to pcscd, as "pid|name|live|stale".  /proc lists sockets
# by inode, never by path, so the inode has to be matched the long way round.
pcsc_holders() {
    local inode p exe fds
    local seen=" "
    for inode in $(ss -x 2>/dev/null | grep pcscd.comm \
                   | grep -oE '[0-9]{5,}' | sort -u); do
        for p in /proc/[0-9]*; do
            # One line per process: a client with several sockets would
            # otherwise be reported, and counted, once per connection.
            [[ ${seen} == *" ${p##*/} "* ]] && continue
            # not piped into grep -q: under pipefail an early grep exit
            # SIGPIPEs ls, the pipeline returns 141 and a matching process is
            # skipped. Read the listing, then test it.
            fds=$(ls -l "${p}/fd" 2>/dev/null) || continue
            grep -q "socket:\[${inode}\]" <<<"${fds}" || continue
            exe=$(readlink "${p}/exe" 2>/dev/null)
            # ss -x lists both ends of each connection, so the daemon's own
            # inode is in the set. Reporting "pcscd is connected to pcscd" as
            # a warning is noise, and now a counted one.
            case ${exe##*/} in pcscd) continue ;; esac
            seen+="${p##*/} "
            # A mapping marked (deleted) means the library was removed out from
            # under a long-lived process: the connection dies with it and
            # cannot come back.
            # the marker is space-separated at end of line, not glued to the path
            # Anchored at the last '/': without that, 'pkcs11' matched the
            # directory in /usr/lib/.../pkcs11/p11-kit-trust.so and any deleted
            # library under it marked the process stale.
            if grep -qE '/[^/ ]*(opensc|pkcs11|pcsclite)[^/ ]* \(deleted\)$' "${p}/maps" 2>/dev/null; then
                printf '%s|%s|stale\n' "${p##*/}" "${exe##*/}"
            else
                printf '%s|%s|live\n' "${p##*/}" "${exe##*/}"
            fi
        done
    done
}

# PKCS#11 modules that could open the card behind your back.  p11-kit-trust is
# a certificate store, not a driver; gnome-keyring's module is restricted with
# enable-in and is its own secret store.
pkcs11_bridges() {
    p11-kit list-modules 2>/dev/null | sed -n 's/^module: //p' \
        | grep -vxE 'p11-kit-trust|gnome-keyring'
}

piv_slot_report() {
    local slot policy has_key cert subject
    for slot in 9a 9c 9d 9e; do
        policy=$(piv_slot_policy "${slot}")
        has_key=0
        timeout 15 "${YKMAN}" piv keys info "${slot}" >/dev/null 2>&1 && has_key=1
        cert=$(timeout 15 "${YKMAN}" piv certificates export "${slot}" - 2>/dev/null)

        if [[ -z ${cert} ]]; then
            if (( has_key )); then
                rwarn "${slot}  ${policy}: key present, no certificate"
                note "tsh overwrites this slot with no prompt"
            else
                ok "${slot}  ${policy}: empty -- tsh will generate here"
            fi
            continue
        fi

        subject=""
        command -v openssl >/dev/null 2>&1 && \
            subject=$(printf '%s\n' "${cert}" | openssl x509 -noout -subject 2>/dev/null)

        case ${subject} in
            *"O = teleport"*|*"O=teleport"*)
                ok "${slot}  ${policy}: already a Teleport slot -- tsh reuses it" ;;
            *)
                rwarn "${slot}  ${policy}: certificate belongs to something else"
                [[ -n ${subject} ]] && note "${subject#subject=}"
                note "tsh prints this certificate and asks before overwriting" ;;
        esac
    done
}

# Read-only summary, reused by the menu step and by --check.
piv_teleport_report() {
    local ver line pid name state mods found=0

    info "pcscd -- the smartcard service Teleport talks to"
    # ${Version} is still set for a package in 'deinstall ok config-files',
    # so ask about Status first.
    if dpkg-query -W -f='${Status}' pcscd 2>/dev/null | grep -q 'ok installed'; then
        ver=$(dpkg-query -W -f='${Version}' pcscd 2>/dev/null); ver=${ver%%-*}
    else
        ver=""
    fi
    if [[ -z ${ver} ]]; then
        rwarn "pcscd is not installed -- Teleport cannot reach the PIV applet"
    elif ver_at_least "${ver}" 2.4.1; then
        ok "pcscd ${ver} (Teleport recommends 2.4.1+)"
    elif ver_at_least "${ver}" 1.8.24; then
        rwarn "pcscd ${ver} -- over the 1.8.24 minimum, but 2.4.1+ is recommended"
    else
        rwarn "pcscd ${ver} is below the 1.8.24 minimum Teleport asks for"
    fi
    if [[ -n ${ver} ]] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet pcscd.socket || systemctl is-active --quiet pcscd; then
            ok "pcscd is running"
        elif systemctl is-enabled --quiet pcscd.socket 2>/dev/null; then
            ok "pcscd.socket is enabled (starts on demand)"
        else
            rwarn "pcscd is not enabled -- PIV will not work"
        fi
    fi

    blank
    info "anything else holding the card (piv-go connects exclusively)"
    while IFS='|' read -r pid name state; do
        [[ -z ${pid} ]] && continue
        found=1
        if [[ ${state} == stale ]]; then
            info "${name} (pid ${pid}) -- stale, its library was removed"
            note "harmless; the connection goes when that process restarts"
        else
            rwarn "${name} (pid ${pid}) is connected to pcscd"
            note "a connection is not a lock, but it can become one"
        fi
    done < <(pcsc_holders)
    (( found )) || ok "nothing is connected to pcscd"

    mods=$(pkcs11_bridges)
    if [[ -n ${mods} ]]; then
        rwarn "PKCS#11 modules that can open the card: $(printf '%s' "${mods}" | tr '\n' ' ')"
        note "desktop key tools load these through p11-kit and keep the card busy"
    else
        ok "no PKCS#11 module bridges to the card"
    fi

    if dpkg-query -W -f='${Status}' scdaemon 2>/dev/null | grep -q "ok installed"; then
        rwarn "scdaemon is installed -- gpg can claim the card"
        note "put 'disable-ccid' and 'pcsc-shared' in ~/.gnupg/scdaemon.conf"
    else
        ok "scdaemon is not installed -- gpg cannot claim the card"
    fi

    blank
    info "PIV applet"
    if [[ -z ${YKMAN} ]]; then
        rwarn "ykman not available -- cannot read the PIV applet"
        return 0
    fi
    local pivinfo
    pivinfo=$(timeout 20 "${YKMAN}" piv info 2>/dev/null)
    if [[ -z ${pivinfo} ]]; then
        rwarn "could not read the PIV applet (is the YubiKey plugged in?)"
        return 0
    fi
    printf '%s\n' "${pivinfo}" | grep -E '^(PIV version|PIN tries|PUK tries)' \
        | while read -r line; do note "${line}"; done

    if ! piv_reports_defaults "${pivinfo}"; then
        info "this firmware cannot report whether the PIN, PUK and management"
        note "key are still the factory values (needs PIV 5.3+), so they are"
        note "not checked here"
    elif printf '%s' "${pivinfo}" | grep -q 'default Management key'; then
        ok "management key is the factory default -- which is what tsh needs"
    else
        rwarn "management key is NOT the factory default"
        note "tsh fails with 'smart card error 6982' unless you reset PIV or"
        note "generate the slot key yourself; see --help for the reset option"
    fi
    if piv_reports_defaults "${pivinfo}"; then
        if printf '%s' "${pivinfo}" | grep -q 'default PIN'; then
            rwarn "PIV PIN is still the factory default (123456)"
        else
            ok "PIV PIN has been changed from the default"
        fi
        if printf '%s' "${pivinfo}" | grep -q 'default PUK'; then
            rwarn "PUK is still the factory default (12345678)"
        else
            ok "PUK has been changed from the default"
        fi
    fi

    blank
    info "what tsh would do with each default slot"
    piv_slot_report

    blank
    info "agent isolation"
    if [[ -f ${TELEPORT_ENV_FILE} ]] && grep -q 'TELEPORT_ADD_KEYS_TO_AGENT=no' "${TELEPORT_ENV_FILE}" 2>/dev/null; then
        ok "TELEPORT_ADD_KEYS_TO_AGENT=no set in ${TELEPORT_ENV_FILE}"
    else
        rwarn "TELEPORT_ADD_KEYS_TO_AGENT is not pinned to 'no'"
        note "software-key logins would be pushed into gcr-ssh-agent and cached"
    fi
}

# Write a p11-kit user module file that stops ONE program loading a module.
# A user file replaces the system file of the same name, so it has to carry
# the system file's own contents too.
exclude_pkcs11_module() {
    local mod=$1 prog=$2 sys user f line s2
    sys="/usr/share/p11-kit/modules/${mod}.module"
    if [[ ! -f ${sys} ]]; then
        bad "no system module file for ${mod} -- not writing anything"
        return 1
    fi
    if grep -q '^enable-in:' "${sys}" 2>/dev/null; then
        info "${mod} already restricted with enable-in -- leaving it alone"
        return 0
    fi
    user="${HOME}/.config/pkcs11/modules/${mod}.module"
    mkdir -p "${HOME}/.config/pkcs11/modules"

    # Carry forward any programs already excluded, in the system file or in a
    # user file from an earlier run. Dropping them would silently re-enable the
    # module for those programs.
    local existing=""
    for f in "${sys}" "${user}"; do
        [[ -f ${f} ]] || continue
        while read -r line; do
            line=${line#disable-in:}
            existing+="${line//,/ } "
        done < <(grep -h '^disable-in:' "${f}" 2>/dev/null)
    done
    local want="" seen prog2
    for prog2 in ${existing} "${prog}"; do
        [[ -z ${prog2} ]] && continue
        seen=0
        for s2 in ${want}; do [[ ${s2} == "${prog2}" ]] && seen=1; done
        (( seen )) || want+="${prog2} "
    done
    want=${want% }

    if [[ -f ${user} ]]; then
        blank
        warn "${user} already exists"
        note "current: $(grep -h '^disable-in:' "${user}" 2>/dev/null | tr '\n' ' ')"
        note "new:     disable-in: ${want// /, }"
        confirm "Replace it?" y || { info "left alone"; return 0; }
    fi

    if ! {
        printf '# written by yubikey-git-signing.sh\n'
        grep -vE '^[[:space:]]*(#|$)|^disable-in:' "${sys}"
        printf 'disable-in: %s\n' "${want// /, }"
    } > "${user}"; then
        bad "could not write ${user}"
        return 1
    fi
    ok "wrote ${user}"
    note "will no longer load ${mod}: ${want}"
    note "a program already running keeps it until it restarts"
}

step_piv_teleport() {
    section "PIV preparation for Teleport"

    # Nothing else on this menu path populates YKMAN, so without this the whole
    # PIV section silently reports "ykman not available" on a machine that has it.
    detect_ykman

    warn "hardware key support is a Teleport ENTERPRISE feature"
    note "on Community/OSS there is nothing here to configure"
    blank
    info "The git signing key above lives in the FIDO2 applet and goes over USB"
    info "HID. Teleport uses the PIV applet over pcscd. Different applet,"
    info "different transport -- they do not compete for each other."
    blank
    pause

    piv_teleport_report
    blank

    # --- pcscd ---
    if ! dpkg-query -W -f='${Status}' pcscd 2>/dev/null | grep -q "ok installed"; then
        if confirm "Install pcscd now?" y; then
            # Only offer to enable the unit if the package actually arrived:
            # otherwise this prompts to enable something that does not exist.
            if apt_install pcscd && \
               dpkg-query -W -f='${Status}' pcscd 2>/dev/null | grep -q 'ok installed'; then
                command -v systemctl >/dev/null 2>&1 && \
                    confirm "Enable pcscd.socket?" y && \
                    run_interactive sudo systemctl enable --now pcscd.socket
            else
                warn "pcscd was not installed -- Teleport will not reach the PIV applet"
            fi
        fi
        blank
    fi

    # --- PKCS#11 bridges ---
    local mods first prog
    mods=$(pkcs11_bridges)
    if [[ -n ${mods} ]]; then
        first=$(printf '%s\n' "${mods}" | head -1)
        blank
        info "A PKCS#11 module (${first}) can open the card from desktop key tools."
        info "You can stop one program loading it without removing the package."
        prog=$(ask "Program to exclude (blank to skip)" "")
        if [[ -n ${prog} ]]; then
            exclude_pkcs11_module "${first}" "${prog}"
        fi
        blank
    fi

    # --- PIN and PUK ---
    if [[ -n ${YKMAN} ]]; then
        local pivinfo
        pivinfo=$(timeout 20 "${YKMAN}" piv info 2>/dev/null)
        # An empty read means no key, no pcscd or a timeout -- NOT a changed
        # management key. Without this guard the negative grep below is true on
        # empty input and the script offers to wipe the PIV applet.
        if [[ -z ${pivinfo} ]]; then
            blank
            warn "could not read the PIV applet -- skipping the PIN and key checks"
            note "is the YubiKey plugged in, and is pcscd running?"
            pivinfo=""
        fi
    fi
    if [[ -n ${YKMAN} && -n ${pivinfo} ]]; then
        # Offered BEFORE the PIN and PUK prompts: a reset returns both to the
        # factory values, so asking afterwards would silently undo whatever
        # the user had just set.
        if piv_reports_defaults "${pivinfo}" && \
           ! printf '%s' "${pivinfo}" | grep -q 'default Management key'; then
            blank
            warn "the management key is not the factory default"
            note "tsh needs the default one; resetting PIV restores it and wipes"
            note "every PIV key and certificate. FIDO2 is a separate applet, so"
            note "your git signing key is NOT affected."
            if confirm_typed RESET "This erases all PIV keys and certificates."; then
                if run_interactive "${YKMAN}" piv reset; then
                    # The reset put the PIN and PUK back to 123456 / 12345678,
                    # so the checks below must see the NEW state. If the re-read
                    # comes back empty (key pulled, pcscd hiccup) keep the old
                    # text rather than silently skipping both prompts.
                    local after
                    after=$(timeout 20 "${YKMAN}" piv info 2>/dev/null)
                    if [[ -n ${after} ]]; then
                        pivinfo=${after}
                    else
                        warn "could not re-read the PIV applet after the reset"
                        note "the PIN and PUK are back to 123456 / 12345678 --"
                        note "run this step again to change them"
                    fi
                fi
            fi
        fi

        if printf '%s' "${pivinfo}" | grep -q 'default PIN'; then
            blank
            warn "the PIV PIN is still the factory default"
            note "this is the PIV PIN, not your FIDO2 PIN -- they are separate"
            note "you will be asked for the CURRENT pin first; the default is 123456"
            if confirm "Change the PIV PIN now?" y; then
                run_interactive "${YKMAN}" piv access change-pin
            fi
        fi
        if printf '%s' "${pivinfo}" | grep -q 'default PUK'; then
            blank
            note "the PUK unblocks a PIN locked by too many wrong tries"
            note "the factory default is 12345678"
            if confirm "Change the PUK now?" y; then
                run_interactive "${YKMAN}" piv access change-puk
            fi
        fi
    fi

    # --- agent isolation ---
    blank
    info "tsh adds SOFTWARE keys to \$SSH_AUTH_SOCK by default, which on this"
    info "desktop is gcr-ssh-agent -- the same agent that cached the signing key."
    info "Hardware keys are never added: they are not a raw key type."
    blank
    if confirm "Pin TELEPORT_ADD_KEYS_TO_AGENT=no (${TELEPORT_ENV_FILE})?" y; then
        mkdir -p "${ENV_DIR}"
        if ! {
            printf '# written by yubikey-git-signing.sh\n'
            printf 'TELEPORT_ADD_KEYS_TO_AGENT=no\n'
        } > "${TELEPORT_ENV_FILE}"; then
            bad "could not write ${TELEPORT_ENV_FILE}"
        else
        ok "wrote ${TELEPORT_ENV_FILE}"
        note "systemd user sessions read this at login -- log out and back in"
        blank
        hint "for terminals before that, add this to ~/.bashrc yourself:"
        hint "  export TELEPORT_ADD_KEYS_TO_AGENT=no"
        fi
    fi

    blank
    info "next: install a tsh matching your cluster's major version, then"
    info "'tsh login'. It creates its own key and certificate in the slot."
    pause
}

# ----------------------------------------------------------------------------
# YubiKey for sudo and login (pam_u2f)
#
# This uses the FIDO2 applet, like git signing, but a SEPARATE credential:
# pamu2fcfg registers its own and records the handle in the mapping file, so
# nothing here touches ssh:git-signing.
#
# Everything is driven from one file, /etc/pam.d/common-u2f, which the
# services @include.  Three shapes:
#
#   or       auth sufficient pam_u2f.so ...      key works, password still does
#   and      auth required   pam_u2f.so ...      key AND password
#   keyonly  auth sufficient pam_u2f.so ...      key only; pam_deny stops the
#            auth required   pam_deny.so         stack before the password
#
# A mistake here costs you sudo and the GDM login, so every change is staged
# to a scratch service, proven with pamtester, and committed behind a timer
# that puts the old files back unless you cancel it.
# ----------------------------------------------------------------------------
PAM_DIR="${PAM_DIR:-/etc/pam.d}"
# libpam searches /etc/pam.d first, then this vendor directory.
PAM_VENDOR_DIR="${PAM_VENDOR_DIR:-/usr/lib/pam.d}"
PAM_U2F_FILE="${PAM_DIR}/common-u2f"
PAM_TEST_SVC="/etc/pam.d/yubikey-pam-test"
PAM_PROBE_SVC="/etc/pam.d/yubikey-pam-probe"
# One default, used by BOTH the stanza and registration: if they ever
# disagree, auth reads one file and pamu2fcfg writes another.
PAM_MAP_DEFAULT="/etc/u2f_mappings"
PAM_ROLLBACK_UNIT="yubikey-pam-rollback"
PAM_MARKER="# managed by yubikey-git-signing.sh"
# What the user actually asked for; everything else is collateral.
PAM_CORE_SERVICES="sudo sudo-i login gdm-password"

# A glob is NOT expanded inside [[ -e ]], so this has to be a real expansion.
# git expands a leading ~ in path settings; [[ -f ~/x ]] on the literal string
# does not, so a perfectly good config reads as a missing file.
expand_tilde() {
    case $1 in
        "~")    printf '%s' "${HOME}" ;;
        "~/"*)  printf '%s/%s' "${HOME}" "${1#\~/}" ;;
        *)      printf '%s' "$1" ;;
    esac
}

pam_u2f_present() {
    local f
    for f in /usr/lib/*/security/pam_u2f.so /lib/*/security/pam_u2f.so; do
        [[ -e ${f} ]] && return 0
    done
    return 1
}

# The authfile= the stanza points at, or pam_u2f's own default.
# The active pam_u2f line: not a comment, and not the second one.
pam_u2f_line() {
    grep -vE '^[[:space:]]*#' "${PAM_U2F_FILE}" 2>/dev/null | grep -m1 'pam_u2f\.so'
}

pam_map_file() {
    local f
    # [^ ] stops at a space but not a tab, and a hand-edited stanza is often
    # tab-separated: that returned 'path<TAB>cue' and pam_register then wrote a
    # file named after the whole string. Stop at any whitespace.
    f=$(pam_u2f_line | grep -oE 'authfile=[^[:space:]]+' | head -1)
    if [[ -n ${f} ]]; then printf '%s' "${f#authfile=}"; return; fi
    # No authfile= in an EXISTING stanza means pam_u2f is using its own default,
    # which is per-user -- not PAM_MAP_DEFAULT. Registering into the wrong file
    # would write credentials that pam_u2f never reads.
    if [[ -f ${PAM_U2F_FILE} ]]; then
        printf '%s' "${XDG_CONFIG_HOME:-${HOME}/.config}/Yubico/u2f_keys"
    else
        printf '%s' "${PAM_MAP_DEFAULT}"
    fi
}

# How many credentials are registered for a user in the mapping file.
pam_map_entries() {
    local map=$1 user=$2 line
    line=$(grep -m1 "^${user}:" "${map}" 2>/dev/null) || return 0
    printf '%s' "${line}" | awk -F: '{print NF-1}'
}

# none | or | and | keyonly | custom
pam_detect_mode() {
    local body
    [[ -f ${PAM_U2F_FILE} ]] || { printf 'none'; return; }
    body=$(grep -vE '^\s*#|^\s*$' "${PAM_U2F_FILE}" 2>/dev/null)
    if   grep -q 'pam_deny' <<<"${body}" && grep -q 'sufficient.*pam_u2f' <<<"${body}"; then
        printf 'keyonly'
    elif grep -qE '^auth\s+required\s+pam_u2f' <<<"${body}" \
         && ! grep -q 'pam_deny' <<<"${body}"; then
        printf 'and'
    elif grep -qE '^auth\s+sufficient\s+pam_u2f' <<<"${body}" \
         && ! grep -q 'pam_deny' <<<"${body}"; then
        printf 'or'
    else
        printf 'custom'
    fi
}

pam_mode_label() {
    case $1 in
        none)    printf 'not configured' ;;
        or)      printf 'password OR key' ;;
        and)     printf 'password AND key' ;;
        keyonly) printf 'key only' ;;
        *)       printf 'something this script does not recognise' ;;
    esac
}

# Services that @include common-u2f.
pam_includers() {
    # Match the directive, not the string: a comment, a note or a sudo~ backup
    # otherwise counts as a service that reads the stack.
    local f
    grep -rlE '^[[:space:]]*@include[[:space:]]+common-u2f[[:space:]]*$' \
        "${PAM_DIR}/" 2>/dev/null | while read -r f; do
        f=${f##*/}
        case ${f} in
            *~|*.bak|*.orig|*.rpmsave|*.pacsave|*.pacnew|*.dpkg-*|*.ucf-*) continue ;;
        esac
        printf '%s\n' "${f}"
    done | sort
}

# Does one service actually include the stack?
pam_service_includes() {
    grep -qE '^[[:space:]]*@include[[:space:]]+common-u2f[[:space:]]*$' \
        "${PAM_DIR}/$1" 2>/dev/null
}

# Core services that already read the stack, and those that do not. Split out
# so the coverage decision can be exercised without a live /etc/pam.d.
pam_core_covered() {
    local svc out=""
    for svc in ${PAM_CORE_SERVICES}; do
        [[ -f ${PAM_DIR}/${svc} ]] || continue
        pam_service_includes "${svc}" && out+="${svc} "
    done
    printf '%s' "${out}"
}

pam_core_uncovered() {
    local svc out=""
    for svc in ${PAM_CORE_SERVICES}; do
        [[ -f ${PAM_DIR}/${svc} ]] || continue
        pam_service_includes "${svc}" || out+="${svc} "
    done
    printf '%s' "${out}"
}

# Where libpam will actually find a service's config. It searches /etc/pam.d
# first and then the VENDOR directory /usr/lib/pam.d; only when neither has a
# file does it fall back to 'other'. polkit-1 is the case that matters: Ubuntu
# ships no /etc/pam.d/polkit-1, but polkitd ships /usr/lib/pam.d/polkit-1, so
# pkexec never reaches 'other'.
pam_service_source() {
    if [[ -f ${PAM_DIR}/$1 ]]; then printf '%s/%s' "${PAM_DIR}" "$1"
    elif [[ -f ${PAM_VENDOR_DIR}/$1 ]]; then printf '%s/%s' "${PAM_VENDOR_DIR}" "$1"
    else printf 'other'; fi
}

# Same question as pam_has_anchor, but asked of the file the service ACTUALLY
# reads -- which for polkit-1 is usually the vendor copy, not one in /etc.
pam_source_has_anchor() {
    local src
    src=$(pam_service_source "$1")
    [[ ${src} == other ]] && return 1
    grep -qE '^[[:space:]]*@include[[:space:]]+common-auth[[:space:]]*$' "${src}" 2>/dev/null
}

# A service can only be wired up if it has a common-auth line to anchor to.
pam_has_anchor() {
    grep -qE '^[[:space:]]*@include[[:space:]]+common-auth[[:space:]]*$' \
        "${PAM_DIR}/$1" 2>/dev/null
}

# Keep whatever options are already there; they encode the admin's choices.
pam_current_opts() {
    local line rest
    line=$(pam_u2f_line)
    [[ -z ${line} ]] && { printf 'authfile=%s cue' "${PAM_MAP_DEFAULT}"; return; }
    # '${line#*pam_u2f.so }' needs a literal space: a tab-separated stanza, or
    # one with no options at all, returned the WHOLE line as the options.
    rest=${line#*pam_u2f.so}
    rest=${rest#"${rest%%[![:space:]]*}"}
    printf '%s' "${rest}"
}

# The candidate file for a mode.
pam_stanza() {
    local mode=$1 opts=$2
    printf '%s\n' "${PAM_MARKER}"
    case ${mode} in
        or)
            printf '%s\n' "auth sufficient pam_u2f.so ${opts}" ;;
        and)
            printf '%s\n' "auth required pam_u2f.so ${opts}" ;;
        keyonly)
            printf '%s\n' "auth sufficient pam_u2f.so ${opts}"
            printf '%s\n' "auth required pam_deny.so" ;;
    esac
}

# warn(), but counted: a warning the summary ignores is a warning that lies.
# Explicit status: a function ending in (( x++ )) returns 1 when x was 0,
# which leaks into any caller that tests it or ends on this call.
rwarn() { warn "$1"; WARN_COUNT=$(( WARN_COUNT + 1 )); return 0; }

pam_report() {
    local mode map entries svc core extra

    if ! pam_u2f_present; then
        rwarn "pam_u2f is not installed -- the YubiKey cannot be used for sudo"
        note "install it with: sudo apt-get install libpam-u2f pamu2fcfg"
        return 0
    fi
    ok "pam_u2f is installed"

    mode=$(pam_detect_mode)
    case ${mode} in
        none)   info "sudo/login: not configured for the YubiKey" ;;
        custom) warn "${PAM_U2F_FILE} is in a shape this script does not recognise"
                grep -vE '^\s*#|^\s*$' "${PAM_U2F_FILE}" 2>/dev/null \
                    | while read -r svc; do note "${svc}"; done
                note "it will be left alone" ;;
        *)      ok "mode: $(pam_mode_label "${mode}")" ;;
    esac

    [[ ${mode} == none ]] && return 0

    map=$(pam_map_file)
    if [[ -r ${map} ]]; then
        entries=$(pam_map_entries "${map}" "${USER}")
        if [[ -z ${entries} || ${entries} == 0 ]]; then
            rwarn "no credential registered for ${USER} in ${map}"
        else
            ok "${entries} credential(s) registered for ${USER} in ${map}"
            note "entries are not keys: several can live on one YubiKey"
        fi
    else
        rwarn "mapping file ${map} is missing or unreadable"
    fi

    if [[ -z $(pam_includers) ]]; then
        rwarn "no service includes common-u2f -- nothing reads this configuration"
        note "the file exists but sudo and login never consult it"
    fi

    core=""; extra=""
    while read -r svc; do
        [[ -z ${svc} ]] && continue
        if [[ " ${PAM_CORE_SERVICES} " == *" ${svc} "* ]]; then core+="${svc} "
        elif [[ ${svc} == polkit-1 ]]; then core+="${svc} "   # covered deliberately
        else extra+="${svc} "; fi
    done < <(pam_includers)
    [[ -n ${core} ]] && ok "covers: ${core}"
    if [[ -n ${extra} ]]; then
        rwarn "also covers: ${extra}"
        note "'other' only covers services with no file of their own -- not pkexec,"
        note "which uses the vendor file /usr/lib/pam.d/polkit-1"
    fi
}

# Merge a new credential into the mapping file, on stdout.  pam_u2f reads
# only the FIRST line for a user, so a new credential has to extend that line
# rather than start another one.
pam_map_merge() {
    local map=$1 user=$2 cred=$3 existing
    # Exists but unreadable (root-owned 0600, say): rewriting from what we can
    # see would drop every other user's line. Refuse instead.
    if [[ -e ${map} && ! -r ${map} ]]; then
        bad "${map} exists but is not readable by ${USER}" >&2
        note "re-run the registration with enough privilege to read it" >&2
        return 1
    fi
    if [[ -r ${map} ]] && existing=$(grep -m1 "^${user}:" "${map}" 2>/dev/null); then
        grep -v "^${user}:" "${map}" 2>/dev/null
        printf '%s:%s\n' "${existing}" "${cred}"
    else
        # Not 'cat': a mapping file written by hand may lack a final newline,
        # and the new entry would then be glued onto the last line, corrupting
        # another user's credential and losing this one. awk terminates every
        # record it prints.
        [[ -r ${map} ]] && awk '{ print }' "${map}" 2>/dev/null
        printf '%s:%s\n' "${user}" "${cred}"
    fi
    return 0
}

# Register another credential.  pamu2fcfg makes its own; ssh:git-signing is
# untouched.
pam_register() {
    local map=$1 out tmpout tmp
    tmpout=$(mktemp) || return 1

    blank
    info "touch the YubiKey when it blinks; it may ask for the FIDO2 PIN first"
    blank
    # Run it directly, NOT through run_interactive: we need pamu2fcfg's own
    # stdout, and its prompts go to stderr, which must stay on the terminal.
    leave_alt
    stty sane 2>/dev/null
    printf '\n  %s%s pamu2fcfg -n%s\n\n' "${MUTED}" "${G_ARROW}" "${RESET}"
    if ! pamu2fcfg -n > "${tmpout}"; then
        blank
        bad "pamu2fcfg failed -- nothing was written to ${map}"
        rm -f "${tmpout}"
        return 1
    fi
    out=$(grep -m1 ',' "${tmpout}")
    out=${out#:}
    rm -f "${tmpout}"
    if [[ -z ${out} ]]; then
        bad "registration produced nothing usable -- not changing ${map}"
        return 1
    fi
    blank
    ok "got a credential handle"

    tmp=$(mktemp) || return 1
    pam_map_merge "${map}" "${USER}" "${out}" > "${tmp}" || { rm -f "${tmp}"; return 1; }

    blank
    # A map under $HOME is the user's own; only a system-wide one needs root.
    if [[ ${map} == "${HOME}/"* ]]; then
        info "writing ${map}"
        mkdir -p "$(dirname "${map}")"
        if install -m 0600 "${tmp}" "${map}"; then
            ok "credential added"
            rm -f "${tmp}"
            return 0
        fi
        rm -f "${tmp}"
        bad "could not write ${map}"
        return 1
    fi
    info "writing ${map} (needs root)"
    if run_interactive sudo install -m 0644 -o root -g root "${tmp}" "${map}"; then
        ok "credential added"
        rm -f "${tmp}"
        return 0
    fi
    rm -f "${tmp}"
    bad "could not write ${map}"
    return 1
}

# Put the candidate in a scratch service and prove it with pamtester before
# anything real is touched.  pamtester runs as you, not root: the mapping file
# is world-readable and unix_chkpwd checks your own password.
pam_stage_and_test() {
    local mode=$1 opts=$2 stage probe ok_in=0

    if ! command -v pamtester >/dev/null 2>&1; then
        warn "pamtester is not installed -- it is how this change is proven safe"
        apt_install pamtester || return 1
        command -v pamtester >/dev/null 2>&1 || return 1
    fi

    stage=$(mktemp) || return 1
    { pam_stanza "${mode}" "${opts}"; printf '@include common-auth\n'; } > "${stage}"
    probe=$(mktemp) || { rm -f "${stage}"; return 1; }
    # The probe has no common-auth, so only the key can pass it. Without that,
    # test 1 in OR mode passes on the password even when the key path is broken.
    printf 'auth required pam_u2f.so %s\n' "${opts}" > "${probe}"

    blank
    info "staging two scratch services (nothing real changes yet)"
    if ! run_interactive sudo install -m 0644 -o root -g root "${stage}" "${PAM_TEST_SVC}"; then
        rm -f "${stage}" "${probe}"; return 1
    fi
    if ! run_interactive sudo install -m 0644 -o root -g root "${probe}" "${PAM_PROBE_SVC}"; then
        run_interactive sudo rm -f "${PAM_TEST_SVC}" >/dev/null 2>&1
        rm -f "${stage}" "${probe}"; return 1
    fi
    rm -f "${stage}" "${probe}"

    blank
    section "Test 1 of 2 -- the key on its own"
    info "no password fallback in this one, so only the key can pass it"
    blank
    if run_interactive pamtester "${PAM_PROBE_SVC##*/}" "${USER}" authenticate; then
        ok "the key authenticated on its own"
        ok_in=1
    else
        bad "the key could NOT authenticate -- registration or mapping is wrong"
    fi

    if (( ok_in )); then
        blank
        section "Test 2 of 2 -- with the YubiKey removed"
        case ${mode} in
            or) info "this must still SUCCEED, using your password alone" ;;
            *)  info "this must FAIL -- that is the point of the mode" ;;
        esac
        blank
        if ! confirm "Unplug the YubiKey, then continue" y; then
            info "cancelled -- nothing was changed"
            run_interactive sudo rm -f "${PAM_TEST_SVC}" "${PAM_PROBE_SVC}" >/dev/null 2>&1
            return 1
        fi
        blank
        if run_interactive pamtester "${PAM_TEST_SVC##*/}" "${USER}" authenticate; then
            if [[ ${mode} == or ]]; then
                ok "password alone still works"
            else
                bad "it authenticated WITHOUT the key -- the mode is not doing its job"
                ok_in=0
            fi
        else
            if [[ ${mode} == or ]]; then
                bad "password alone failed -- this would lock you out"
                ok_in=0
            else
                ok "refused without the key, as intended"
            fi
        fi
        blank
        # Not a confirm: there is no "no" to honour here, and a question whose
        # answer is ignored is the same defect this review keeps finding.
        info "plug the YubiKey back in"
        pause
    fi

    run_interactive sudo rm -f "${PAM_TEST_SVC}" "${PAM_PROBE_SVC}" >/dev/null 2>&1
    (( ok_in )) || { blank; bad "the candidate did not behave correctly -- nothing was changed"; return 1; }
    return 0
}

# One sudo call does the lot.  Order matters: every later sudo goes through the
# NEW stack, so a rollback scheduled after the swap could never be scheduled.
# The root script, on stdout. Split out of pam_commit so the harness can
# run it against a sandboxed /etc/pam.d: this is the most dangerous code in
# the file and it was previously impossible to exercise without root.
# The rollback command, on stdout. Restoring the tar cannot delete a file
# created AFTER it was taken, so every file this run may create is removed
# explicitly -- each guarded on the backup not containing that path, so a file
# that existed before is restored rather than deleted.
pam_undo_command() {
    local backup=$1 vendor=${2:-} out svc2
    out="tar xzf '${backup}' -C /etc"
    out+="; tar tzf '${backup}' | grep -qx 'pam.d/common-u2f' || rm -f '${PAM_U2F_FILE}'"
    for svc2 in ${vendor}; do
        out+="; tar tzf '${backup}' | grep -qx 'pam.d/${svc2}' || rm -f '/etc/pam.d/${svc2}'"
    done
    printf '%s' "${out}"
}

pam_root_script() {
    local mode=$1 opts=$2 narrow=$3 add=${4:-} vendor=${5:-}
    local backup=$6 stage=$7 undo=$8
    local svc
        printf 'set -e\n'
    printf 'mkdir -p /var/backups\n'
    printf 'tar czf %q -C /etc pam.d\n' "${backup}"
    # clear a timer left behind by an earlier run, or systemd-run refuses
    # the name and set -e aborts us before the swap
    printf 'systemctl stop %q.timer 2>/dev/null || true\n' "${PAM_ROLLBACK_UNIT}"
    printf 'systemctl reset-failed %q 2>/dev/null || true\n' "${PAM_ROLLBACK_UNIT}"
    # dead man's switch, armed BEFORE the swap
    # Restoring the tar cannot delete a file that was created after it was
    # taken, so a rolled-back machine would keep an orphan common-u2f and
    # read as "already configured" next time. Remove it unless the backup
    # actually contains one.
    printf 'systemd-run --on-active=180 --unit=%q --description=%q /bin/sh -c %q >/dev/null\n' \
        "${PAM_ROLLBACK_UNIT}" "revert YubiKey PAM change" \
        "${undo}"
    printf 'install -m 0644 -o root -g root %q %q\n' "${stage}" "${PAM_U2F_FILE}"
    if [[ -n ${narrow} ]]; then
        for svc in ${narrow}; do
            printf 'sed -i -E %q /etc/pam.d/%q\n' \
                '/^[[:space:]]*@include[[:space:]]+common-u2f[[:space:]]*$/d' "${svc}"
        done
    fi
    # Wire the stack into services that do not include it yet. Without this
    # the file can be swapped in while nothing reads it, and a locking mode
    # would be reported as active while sudo still takes the password alone.
    # A service whose only config is the vendor file needs that file copied
    # into /etc/pam.d first; editing /usr/lib/pam.d would be overwritten by
    # the next package update.
    if [[ -n ${vendor} ]]; then
        for svc in ${vendor}; do
            # the [ -f ] guard already makes this conditional, and cp -n
            # warns that its behaviour is non-portable
            printf '[ -f /etc/pam.d/%q ] || cp %q/%q /etc/pam.d/%q\n' \
                "${svc}" "${PAM_VENDOR_DIR}" "${svc}" "${svc}"
            printf 'grep -qE %q /etc/pam.d/%q || sed -i -E %q /etc/pam.d/%q\n' \
                '^[[:space:]]*@include[[:space:]]+common-u2f[[:space:]]*$' "${svc}" \
                '0,/^[[:space:]]*@include[[:space:]]+common-auth[[:space:]]*$/s//@include common-u2f\n&/' \
                "${svc}"
        done
    fi
    if [[ -n ${add} ]]; then
        for svc in ${add}; do
            # Same tolerance as pam_service_includes / pam_has_anchor:
            # a strict ^...$ here would silently match nothing on a file
            # with an indented or trailing-space include, and the guard
            # would already have counted the service as wired.
            printf 'grep -qE %q /etc/pam.d/%q || sed -i -E %q /etc/pam.d/%q\n' \
                '^[[:space:]]*@include[[:space:]]+common-u2f[[:space:]]*$' "${svc}" \
                '0,/^[[:space:]]*@include[[:space:]]+common-auth[[:space:]]*$/s//@include common-u2f\n&/' \
                "${svc}"
        done
    fi
    printf 'rm -f %q %q\n' "${PAM_TEST_SVC}" "${PAM_PROBE_SVC}"
}

pam_commit() {
    local mode=$1 opts=$2 narrow=$3 add=${4:-} vendor=${5:-}
    local ts backup rootscript stage svc

    local undo
    ts=$(date +%Y%m%d-%H%M%S)
    backup="/var/backups/pam.d-${ts}.tgz"

    # Restoring the tar cannot delete a file created AFTER it was taken, so
    # every file this run may create has to be cleaned up explicitly:
    # common-u2f, and any service copied out of the vendor directory. Each
    # cleanup is guarded on the backup not containing that path, so a file that
    # existed before is restored rather than removed.
    undo=$(pam_undo_command "${backup}" "${vendor}")
    stage=$(mktemp) || return 1
    pam_stanza "${mode}" "${opts}" > "${stage}"

    rootscript=$(mktemp) || { rm -f "${stage}"; return 1; }
    pam_root_script "${mode}" "${opts}" "${narrow}" "${add}" "${vendor}" \
        "${backup}" "${stage}" "${undo}" > "${rootscript}"

    blank
    info "applying, with a 3 minute automatic rollback armed first"
    if ! run_interactive sudo bash "${rootscript}"; then
        rm -f "${stage}" "${rootscript}"
        bad "apply failed -- check 'sudo systemctl list-timers' for a pending rollback"
        return 1
    fi
    rm -f "${stage}" "${rootscript}"

    blank
    ok "applied. Backup: ${backup}"
    blank
    warn "YOU HAVE 3 MINUTES. Open a NEW terminal and run:"
    blank
    printf '      %ssudo -k && sudo systemctl stop %s.timer%s\n' \
        "${BOLD}" "${PAM_ROLLBACK_UNIT}" "${RESET}"
    blank
    note "that sudo authenticates through the new stack, so if it works you are"
    note "fine and the rollback is cancelled. If it does not, do nothing and"
    note "everything goes back by itself."
    blank
    note "to undo later:"
    note "  sudo sh -c \"${undo}\""
    return 0
}

step_pam() {
    local mode newmode map entries opts narrow svc keys vendor=""

    section "YubiKey for sudo and login"

    info "This uses the FIDO2 applet, like git signing, but registers its own"
    info "credential -- ssh:git-signing is not touched."
    blank
    pam_report
    blank

    if ! pam_u2f_present; then
        confirm "Install pam_u2f now?" y || { pause; return 1; }
        apt_install libpam-u2f pamu2fcfg || { pause; return 1; }
        blank
    fi
    # The module and the registration tool ship separately: the module can be
    # present while pamu2fcfg is not, and registration would then fail.
    if ! command -v pamu2fcfg >/dev/null 2>&1; then
        warn "pamu2fcfg is missing -- credentials cannot be registered without it"
        confirm "Install it?" y && apt_install pamu2fcfg
        command -v pamu2fcfg >/dev/null 2>&1 || { bad "still not available"; pause; return 1; }
        blank
    fi

    mode=$(pam_detect_mode)
    if [[ ${mode} == custom ]]; then
        bad "${PAM_U2F_FILE} was written by hand or by another tool"
        note "this script will not edit a stanza it does not understand"
        pause; return 1
    fi

    map=$(pam_map_file)
    opts=$(pam_current_opts)
    entries=$(pam_map_entries "${map}" "${USER}")
    entries=${entries:-0}

    # --- credentials ---
    if (( entries == 0 )); then
        blank
        warn "no credential is registered for ${USER}"
        confirm "Register this YubiKey now?" y || { pause; return 1; }
        pam_register "${map}" || { pause; return 1; }
        entries=$(pam_map_entries "${map}" "${USER}"); entries=${entries:-0}
    else
        blank
        info "${entries} credential(s) registered. A SECOND physical key is the"
        info "difference between losing a key and losing the machine."
        if confirm "Register another key now?" n; then
            pam_register "${map}" && entries=$((entries+1))
        fi
    fi

    # --- how many physical keys, really ---
    blank
    info "Entries are not keys: several entries can live on one YubiKey."
    keys=$(ask "How many physical YubiKeys are registered?" "1")
    [[ ${keys} =~ ^[0-9]+$ ]] || keys=1

    # --- mode ---
    blank
    ui_menu "How should sudo and login authenticate?" \
        "Password OR key   -- key is a shortcut, password still works" \
        "Password AND key  -- both every time" \
        "Key only          -- no password fallback" \
        "Cancel" || { info "cancelled"; pause; return 0; }
    case ${MENU_INDEX} in
        0) newmode=or ;;
        1) newmode=and ;;
        2) newmode=keyonly ;;
        *) info "cancelled"; pause; return 0 ;;
    esac

    if [[ ${newmode} == "${mode}" ]]; then
        blank
        info "already in $(pam_mode_label "${mode}") mode"
        confirm "Rewrite it anyway?" n || { pause; return 0; }
    fi

    # --- the things that bite ---
    if [[ ${newmode} != or ]]; then
        blank
        section "Read this before continuing"
        warn "in $(pam_mode_label "${newmode}") mode, no key means no sudo and no login"
        note "the lock screen uses gdm-password, so it is covered too"
        note "Ubuntu leaves the root account locked, so recovery without the key"
        note "means the GRUB recovery menu or a live USB"
        blank
        note "the FIDO2 PIN shares its 8-try budget with git signing; blocking it"
        note "needs 'ykman fido reset', which destroys the git signing key too"
        blank
        note "registrations are tied to origin pam://$(hostname) -- renaming this"
        note "machine invalidates them"
        blank
        note "sshd does not use this stack and is unaffected"
        blank
        note "gdm-password also runs pam_gnome_keyring, which unlocks the login"
        note "keyring with the password you type. Log in on the key alone and"
        note "the keyring stays locked, so you get an unlock prompt each session."
        blank
        if (( keys < 2 )); then
            warn "you have ONE key. If it is lost or broken, you are locked out."
            confirm_typed LOCKME "This can lock you out of your own machine." \
                || { info "cancelled"; pause; return 0; }
        else
            confirm "Continue?" n || { info "cancelled"; pause; return 0; }
        fi
    fi

    # --- PIN for key-only ---
    if [[ ${newmode} == keyonly && ${opts} != *pinverification=1* ]]; then
        blank
        warn "without a PIN, key-only means anyone holding the key gets root"
        note "that is weaker than the password it replaces"
        if confirm "Require the FIDO2 PIN as well as a touch?" y; then
            opts="${opts} pinverification=1"
        fi
    fi

    # --- pkexec / polkit ---
    # Deliberately NOT inside the narrowing block: whether pkexec is covered has
    # nothing to do with whether some unrelated service already includes the
    # stack, and on a first run there is nothing to narrow at all.
    if [[ ${newmode} != or ]]; then
        local psrc
        psrc=$(pam_service_source polkit-1)
        # The question is whether polkit-1 READS the stack, not where its file
        # lives. An /etc/pam.d/polkit-1 that exists but lacks the include --
        # kept across a release upgrade, or copied to customise -- used to skip
        # this whole block on a location test and leave pkexec password-only.
        if ! pam_service_includes polkit-1; then
            warn "pkexec and the GUI admin prompts will NOT require the key"
            note "they read ${psrc}, which this stack is not part of,"
            note "so root stays reachable with the password alone"
            blank
            if [[ ${psrc} == other ]]; then
                note "polkit-1 has no file of its own here, so there is nothing"
                note "to add the include to -- covering it is not offered"
            elif ! pam_source_has_anchor polkit-1; then
                # The include is inserted before '@include common-auth'. Without
                # that line the sed matches nothing and exits 0, so the script
                # would report success having changed nothing at all.
                warn "${psrc} has no '@include common-auth' line to anchor to"
                note "this script will not edit it; add the include by hand if"
                note "you want pkexec to require the key"
            else
                if [[ ${psrc} == "${PAM_DIR}/polkit-1" ]]; then
                    note "its file already exists; the include would be added there"
                else
                    note "covering them means copying that vendor file to"
                    note "${PAM_DIR}/polkit-1 and adding the include there"
                fi
                if confirm "Cover pkexec too?" y; then
                    # Either way pam_root_script's vendor branch does the right
                    # thing: it skips the copy when the file already exists and
                    # adds the include only when it is missing.
                    vendor+="polkit-1 "
                    ok "will add the include to ${PAM_DIR}/polkit-1"
                fi
            fi
            blank
        fi
    fi

    # --- scope ---
    narrow=""
    while read -r svc; do
        [[ -z ${svc} ]] && continue
        [[ " ${PAM_CORE_SERVICES} " == *" ${svc} "* ]] && continue
        # polkit-1 is covered on purpose when the user asked for pkexec; do not
        # then offer to strip it as if it were stray.
        [[ ${svc} == polkit-1 ]] && continue
        narrow+="${svc} "
    done < <(pam_includers)
    if [[ -n ${narrow} ]]; then
        blank
        info "common-u2f is also included by: ${narrow}"
        note "'other' is only consulted for services with no file of their own"
        note "cron and cups have no business asking for a touch"
        blank
        if [[ ${newmode} == or ]]; then
            confirm "Limit it to ${PAM_CORE_SERVICES}?" n || narrow=""
        else
            warn "in this mode every service in that list would demand the key"
            confirm "Limit it to ${PAM_CORE_SERVICES}?" y || narrow=""
        fi
        if [[ -n ${narrow} && ${newmode} != or ]]; then
            if confirm "Keep 'other' covered as well?" n; then
                narrow=${narrow//other /}
                info "'other' keeps the include"
            fi
        fi
    fi

    # --- make sure something will actually read the file ---
    # pamtester uses its own scratch service, so a passing test says nothing
    # about whether sudo and login include this stack at all.
    # Coverage has to be judged on the state this change will LEAVE BEHIND.
    # Asking "does anything include it today?" is wrong twice over: narrowing
    # can strip the only includers, and a machine where sudo has it but
    # gdm-password does not looks covered while half of what you asked for is
    # still password-only.
    local add="" covered="" uncovered="" svc
    covered=$(pam_core_covered)
    uncovered=$(pam_core_uncovered)

    if [[ -n ${uncovered} ]]; then
        blank
        warn "these do not include common-u2f yet: ${uncovered}"
        [[ -n ${covered} ]] && note "already covered: ${covered}"
        note "a service that does not include it keeps taking the password alone,"
        note "however the tests go -- pamtester uses its own scratch service"
        blank
        if confirm "Add the include to them?" y; then
            for svc in ${uncovered}; do
                if ! pam_has_anchor "${svc}"; then
                    warn "/etc/pam.d/${svc} has no common-auth line to anchor to -- skipping"
                    continue
                fi
                add+="${svc} "
            done
            [[ -n ${add} ]] && ok "will add the include to: ${add}"
        fi
    fi

    if [[ -z ${covered}${add} ]]; then
        blank
        bad "after this change nothing would read the configuration"
        note "sudo and login would still take the password alone -- stopping"
        pause; return 1
    fi
    blank
    info "after this change the stack will be read by: ${covered}${add}"

    # --- prove it, then commit ---
    blank
    pam_stage_and_test "${newmode}" "${opts}" || { pause; return 1; }
    pam_commit "${newmode}" "${opts}" "${narrow}" "${add}" "${vendor}"
    pause
}

# The read-only report, plus the two things people always want next.
step_check() {
    check_all
    if (( GCR_FAILED )); then
        blank
        confirm "Fix the agent interception now?" y && fix_agent_core
    fi
    blank
    local needs
    needs=$(sk_policy_needs "$(sk_policy "${KEY_PRIV}")")
    confirm "Run a real signing test? (needs ${needs})" n \
        && run_test_commit
    pause
}

# The five setup steps in the order they depend on each other.
step_guided() {
    local s

    section "Guided setup"
    info "Runs the setup steps in the order they depend on each other:"
    note "tools  ->  FIDO2 PIN  ->  signing key (with GitHub enrolment)  ->  askpass"
    blank
    info "Each one is also on the menu on its own, so you can stop any time."
    blank
    confirm "Start?" y || return 0

    # step_create_key ends by printing the GitHub enrolment itself, so running
    # step_github here as well showed the whole thing, and the gh upload
    # prompt, a second time.
    for s in step_install_tools step_fido_init step_create_key step_askpass; do
        "${s}" || {
            blank
            warn "that step did not finish cleanly"
            confirm "Carry on with the rest anyway?" n || return 1
        }
    done

    blank
    section "Checking the result"
    step_check
}

main_menu() {
    while :; do
        ui_menu "What would you like to do?" \
            "Guided setup -- the whole thing, in order" \
            "-- Set up git signing, step by step" \
            "Install the YubiKey management tools" \
            "Set the FIDO2 PIN" \
            "Create the git signing key" \
            "Enrol the key on GitHub" \
            "Install the GUI askpass helper" \
            "-- Already have a key" \
            "Reimport it from the YubiKey" \
            "-- Check and repair" \
            "Run the dependency check" \
            "Fix agent interception (gcr caching the key)" \
            "-- Same key, other uses" \
            "Prepare PIV for Teleport (hardware key support)" \
            "Use the key for sudo and login (PAM)" \
            "--" \
            "Quit" || return 0

        case ${MENU_INDEX} in
            0)  step_guided ;;
            1)  step_install_tools ;;
            2)  step_fido_init ;;
            3)  step_create_key ;;
            4)  step_github ;;
            5)  step_askpass ;;
            6)  step_reimport ;;
            7)  step_check ;;
            8)  step_fix_agent ;;
            9)  step_piv_teleport ;;
            10) step_pam ;;
            11) return 0 ;;
        esac
    done
}

usage() {
    cat <<USAGE
yubikey-git-signing.sh ${VERSION}

Set up a YubiKey for git commit signing over SSH, using the FIDO2 applet:
no pcscd, no PKCS#11, no ssh-agent.

It can also prepare the PIV applet for Teleport hardware key support, which
is a separate applet on the same key and does need pcscd.

  (no arguments)   interactive menu
  --check          read-only dependency and configuration report
  --no-color       disable colour and interactive UI
  --version        print version
  --help           this text

Keys are written to ${KEY_DIR}, never ~/.ssh: gcr-ssh-agent
advertises any keypair found in ~/.ssh, and ssh-keygen prefers an agent that
holds a matching key -- which cannot drive a FIDO2 token.
USAGE
}

main() {
    local arg
    for arg in "$@"; do
        case ${arg} in
            --no-color|--no-colour) FORCE_PLAIN=1 ;;
        esac
    done
    setup_theme
    need_root_check

    for arg in "$@"; do
        case ${arg} in
            --help|-h)    usage; exit 0 ;;
            --version|-V) printf '%s\n' "${VERSION}"; exit 0 ;;
            --check|-c)   banner; check_all; exit $(( FAIL_COUNT > 0 ? 1 : 0 )) ;;
            --no-color|--no-colour) ;;
            *) printf 'unknown option: %s\n' "${arg}" >&2; usage; exit 2 ;;
        esac
    done

    if [[ ! -t 0 || ! -t 1 ]]; then
        banner
        printf '  %s\n\n' "Not an interactive colour terminal -- running the read-only check."
        check_all
        printf '  Run this in a terminal for the interactive menu, or see --help.\n\n'
        exit $(( FAIL_COUNT > 0 ? 1 : 0 ))
    fi

    main_menu
    printf '\n'
    ok "done"
    blank
}

main "$@"
