# YubiKey git signing (FIDO2) — setup on a new machine

`yubikey-git-signing.sh` in this folder automates all of this: run it with
`--check` for a read-only report, or with no arguments for the menu.

Signing key: `sk-ssh-ed25519@openssh.com`, application `ssh:git-signing`,
resident (stored on the YubiKey), `verify-required` (FIDO2 PIN + touch per signature).

## 0. Prerequisites

Nothing to install on a normal Ubuntu/Debian desktop. The FIDO2 stack ships with
`openssh-client`, which hard-depends on `libfido2-1 (>= 1.8.0)`:

    /usr/lib/openssh/ssh-sk-helper   <- openssh-client
    libfido2.so.1                    <- libfido2-1

Device permissions come from udev's own `60-fido-id.rules` + `70-uaccess.rules`,
which put an ACL for the logged-in user on `/dev/hidrawN`. No extra package.

Minimum versions: OpenSSH 8.4+ (sk keys 8.2, `-O verify-required` 8.4),
git 2.34+ (`gpg.format=ssh`). Check with:

    ssh -V; git --version; ldd /usr/lib/openssh/ssh-sk-helper | grep fido

If `ssh-sk-helper` is missing: `sudo apt install openssh-client`.

NOT needed: pcscd, opensc, ykman, yubico-piv-tool. Those are the PIV stack.
`ykman` is only needed to set or check the FIDO2 PIN (`sudo apt install
yubikey-manager` — the snap is broken on Ubuntu 26.04, use apt).

### Graphical tool (optional)

Yubico publishes **no .deb**. The release index and the GitHub release for
7.5.0 both carry `.tar.gz` + detached `.sig` for Linux, `.msi` for Windows and
`.dmg` for macOS — nothing else. The Flathub build (`com.yubico.yubioath`) is
not publisher-verified and trails upstream.

    V=7.5.0   # https://developers.yubico.com/yubioath-flutter/Releases/
    B=yubico-authenticator-$V-linux-x64.tar.gz
    U=https://developers.yubico.com/yubioath-flutter/Releases/$B
    curl -fLO "$U" && curl -fLO "$U.sig"
    gpg --verify "$B.sig" "$B"          # prints the key id it needs
    gpg --recv-keys <that key id>       # on a fresh keyring, then verify again

`gpg --verify` saying *Good signature* is not enough on its own: the primary
key fingerprint it reports must appear on
<https://developers.yubico.com/Software_Projects/Software_Signing.html>.
The signature's issuer is often a **subkey**, so compare the *primary* key
line, not the issuer. `yubikey-git-signing.sh` does all of this and refuses to
unpack otherwise.

Then unpack somewhere stable and register the launcher — the `.desktop` file
records an absolute path, so run the integration script only after the
directory is at its final location:

    mkdir -p ~/.local/opt/yubico-authenticator ~/.local/share/applications
    tar -xzf "$B" -C ~/.local/opt/yubico-authenticator --strip-components=1
    ~/.local/opt/yubico-authenticator/desktop_integration.sh --install

`--strip-components=1` because the directory inside the tarball is not named
after the file, and `~/.local/share/applications` because the integration
script writes into it with `>` without creating it.

The app reaches FIDO2 over USB HID (udev handles that), but PIV and OATH go
over the smartcard interface, which needs `pcscd` running. It does not
participate in git signing at all — it is a management GUI.

### sudo and login (pam_u2f)

Separate credential, same FIDO2 applet — `pamu2fcfg` registers its own, so
`ssh:git-signing` is untouched. Everything hangs off one file,
`/etc/pam.d/common-u2f`, which the services `@include`:

| mode | stanza |
|---|---|
| password **OR** key | `auth sufficient pam_u2f.so …` |
| password **AND** key | `auth required pam_u2f.so …` |
| key only | `auth sufficient pam_u2f.so …` then `auth required pam_deny.so` |

The script's "Use the key for sudo and login" item stages the candidate as a
throwaway PAM service, proves it with `pamtester` (both with the key in and
with it out), and only then swaps it in — behind a `systemd-run` timer that
restores `/etc/pam.d` after 3 minutes unless you cancel it by running
`sudo -k && sudo systemctl stop yubikey-pam-rollback.timer` in a new terminal.
That sudo goes through the new stack, so succeeding at it is the proof.

**key-only does not cover everything.** There is no `/etc/pam.d/polkit-1` on
Ubuntu, so `pkexec` and the GUI admin prompts fall back to `/etc/pam.d/other`.
If you narrow the includes and drop `other`, pkexec still grants root on the
password alone. `sshd` never uses this stack. And `gdm-password` runs
`pam_gnome_keyring`, which unlocks the login keyring from the password you
type — log in on the key alone and the keyring stays locked, so you get an
unlock prompt every session.

**If you are locked out:** Ubuntu keeps the root account locked, so it is the
GRUB recovery menu (hold Shift at boot → Advanced → recovery → root shell,
`mount -o remount,rw /`) or a live USB. Then:

    tar xzf /var/backups/pam.d-<timestamp>.tgz -C /etc

Two more things that bite in the locking modes: registrations are tied to
`origin=pam://<hostname>`, so renaming the machine invalidates them; and the
FIDO2 PIN shares its 8-try budget with git signing, so blocking it forces
`ykman fido reset`, which destroys the signing key too.

### Teleport (PIV) on the same key

Teleport's hardware key support uses the **PIV** applet over `pcscd`, not FIDO2,
so it does not disturb git signing. `yubikey-git-signing.sh` has a
"Prepare PIV for Teleport" item under "Same key, other uses" that checks pcscd, reports anything else
holding the card, shows what `tsh` would do with each of its default slots
(9a/9c/9d/9e), offers to change the PIV PIN and PUK, and pins
`TELEPORT_ADD_KEYS_TO_AGENT=no` so software-key logins stay out of
gcr-ssh-agent. It creates no key and never changes the management key —
`tsh` needs the factory one. See `teleport-piv-coexistence.md`.

## 1. Recover the key from the YubiKey

The credential is resident, so it can be re-downloaded anywhere. It must NOT live
in `~/.ssh` (see Trap 1). `ssh-keygen -K` writes into the CURRENT directory:

    mkdir -m 700 -p ~/.config/git/keys
    cd ~/.config/git/keys
    ssh-keygen -K

Asks for the FIDO2 PIN and a touch. It prints the filenames it wrote. OpenSSH names them
`id_<type>_rk_<application>` and strips the leading `ssh:`, so
`ssh:git-signing` lands as `id_ed25519_sk_rk_git-signing`. Do not rely on the
name — `-K` downloads every resident `ssh:` credential on the key, so identify
the right one by its embedded application string:

    for f in *.pub; do
      printf '%s -> ' "$f"
      cut -d' ' -f2 "$f" | base64 -d | tr -c '[:print:]' '\n' | grep -m1 '^ssh:'
    done

Then rename the matching pair:

    mv id_ed25519_sk_rk_git-signing     id_ed25519_sk_git
    mv id_ed25519_sk_rk_git-signing.pub id_ed25519_sk_git.pub
    chmod 600 id_ed25519_sk_git

## 2. git config

Use absolute paths — git does not tilde-expand `user.signingkey`.

    git config --global gpg.format ssh
    git config --global user.signingkey "$HOME/.config/git/keys/id_ed25519_sk_git"
    git config --global gpg.ssh.allowedSignersFile "$HOME/.config/git/allowed_signers"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true

## 3. allowed_signers

Regenerate from the public key — it stores key material, not a path, so it is
machine-independent and can simply be copied between machines:

    printf '%s %s\n' lance.chong@cyberowl.io \
      "$(cut -d' ' -f1,2 ~/.config/git/keys/id_ed25519_sk_git.pub)" \
      > ~/.config/git/allowed_signers

## 4. Verify

    cd "$(mktemp -d)" && git init -q && git commit --allow-empty -m "signing test" \
      && git log --show-signature -1

Expect `Good "git" signature for lance.chong@cyberowl.io`. Anything else is a
failure — see traps below.

## Traps

1. **Never put the key in `~/.ssh` on a GNOME machine.** gcr-ssh-agent advertises
   any keypair found there, and `ssh-keygen -Y sign` prefers an agent holding a
   matching fingerprint over the file on disk. gcr cannot sign with FIDO2 keys, so
   you get `agent refused operation`. Check with `ssh-add -l` — the ED25519-SK line
   must NOT appear.

   Moving the file out is not enough on its own: gcr caches the key in memory, so
   it keeps advertising it until you remove it or restart the agent.

       ssh-add -d ~/.config/git/keys/id_ed25519_sk_git.pub
       systemctl --user restart gcr-ssh-agent.service

   Last resort: a `gpg.ssh.program` wrapper script that does
   `unset SSH_AUTH_SOCK; exec /usr/bin/ssh-keygen "$@"` (must be a script; git
   does not shell-split that setting).

2. **Two different PINs.** `ssh-keygen` prompting "Enter PIN for authenticator" wants
   the FIDO2 PIN, not the PIV PIN. FIDO2 allows 8 wrong attempts, then a reset that
   wipes every FIDO credential on the key. Check first: `ykman fido info`.

3. **GUI git clients need an askpass.** With `verify-required` the PIN prompt goes to
   `/dev/tty`, so VS Code / JetBrains commits fail. Install `ssh-askpass-gnome` and
   set `SSH_ASKPASS=/usr/bin/ssh-askpass` in `~/.config/environment.d/`, then log
   out and back in. OpenSSH falls back to askpass on its own when there is no tty,
   so that is enough. `SSH_ASKPASS_REQUIRE=prefer` is optional and makes terminal
   commits pop a GUI dialog too. Alternatively regenerate the key without
   `-O verify-required` (touch alone is still required).

4. **`incorrect passphrase supplied to decrypt private key`** does not mean the file
   has a passphrase. It is OpenSSH's wording for "needed the FIDO2 PIN, had no way
   to ask".

## Forge

Upload the `.pub` as a **Signing** key, not an Authentication key (GitHub allows the
same key as both — they are separate entries). GitHub and GitLab verify
`sk-ssh-ed25519@openssh.com`. Azure DevOps does not display SSH signature
verification at all.

## If the key is ever lost

The resident credential is the only copy; the private scalar never leaves the token
and cannot be backed up. Generate a second key on a backup YubiKey and add both
lines to `allowed_signers` and to the forge.

## Regenerating from scratch (no resident copy to recover)

    ssh-keygen -t ed25519-sk -O resident -O application=ssh:git-signing \
      -O verify-required -C "lance.chong@cyberowl.io git signing" \
      -f ~/.config/git/keys/id_ed25519_sk_git

`ed25519-sk` needs YubiKey firmware 5.2.3+; below that use `-t ecdsa-sk`.
A new key means a new fingerprint: update `allowed_signers` and the forge.
