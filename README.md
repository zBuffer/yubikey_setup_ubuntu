<div align="center">

# 🔑 YubiKey setup for Ubuntu

**One script to enrol a YubiKey as your Git signing key, your Teleport hardware key,
and your sudo/login factor — without the usual GNOME agent pitfalls.**

![Bash](https://img.shields.io/badge/bash-5%2B-4EAA25?logo=gnubash&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu%20%2F%20Debian-E95420?logo=ubuntu&logoColor=white)
![YubiKey](https://img.shields.io/badge/YubiKey-5%20series-84BD00?logo=yubico&logoColor=white)
![Self-test](https://img.shields.io/badge/self--test-126%20checks-blue)

</div>

---

## Contents

- [Quick start](#-quick-start)
- [What it sets up](#-what-it-sets-up)
- [Requirements](#-requirements)
- [The menu](#-the-menu)
- [sudo and login (PAM)](#-sudo-and-login-pam)
- [Teleport (PIV)](#-teleport-piv)
- [Doing it by hand](#-doing-it-by-hand)
- [Troubleshooting](#-troubleshooting)
- [Development](#-development)

---

## 🚀 Quick start

```bash
git clone https://github.com/zBuffer/yubikey_setup_ubuntu.git
cd yubikey_setup_ubuntu
./yubikey-git-signing.sh --check   # read-only report, changes nothing
./yubikey-git-signing.sh           # interactive menu
```

Pick **Guided setup** for the whole thing in order. Run it as yourself, not with
`sudo`: the script asks before anything that needs root.

| Flag | Does |
|---|---|
| *(none)* | Interactive menu |
| `--check` | Read-only dependency and configuration report |
| `--no-color` | Plain output, no full-screen UI |
| `--version` / `--help` | What they say |

---

## ✨ What it sets up

One YubiKey has separate applets for separate jobs. They don't interfere with each other.

| Use | Applet | Transport | Needs pcscd |
|---|---|---|:---:|
| **Git commit & tag signing** | FIDO2 | USB HID | ❌ |
| **sudo & login** (`pam_u2f`) | FIDO2 | USB HID | ❌ |
| **Teleport hardware key** | PIV | CCID / PC/SC | ✅ |

**The signing key** is `sk-ssh-ed25519@openssh.com`. It is *resident*, so it's stored
on the YubiKey and can be recovered on any machine. Its application string is
`ssh:git-signing`, and it is created with `verify-required`, so every signature needs
the FIDO2 PIN **and** a touch. The private scalar never leaves the token.

> [!IMPORTANT]
> Keys are written to `~/.config/git/keys/`, **never `~/.ssh/`**. On GNOME,
> `gcr-ssh-agent` advertises every keypair it finds in `~/.ssh`. `ssh-keygen` then prefers
> that agent over the file, and the agent can't drive a FIDO2 token, so signing fails
> with `agent refused operation`. See [Troubleshooting](#-troubleshooting).

---

## 📋 Requirements

Nothing to install on a normal Ubuntu or Debian desktop. FIDO2 support ships with
`openssh-client`, which depends on `libfido2-1`. udev's stock rules already give the
logged-in user access to the key.

| Component | Minimum | Why |
|---|---|---|
| OpenSSH | **8.4** | `sk` keys arrived in 8.2, `-O verify-required` in 8.4 |
| git | **2.34** | `gpg.format=ssh` |
| YubiKey firmware | **5.2.3** | `ed25519-sk`; use `ecdsa-sk` below that |

```bash
ssh -V; git --version; ldd /usr/lib/openssh/ssh-sk-helper | grep fido
```

**Optional:**

- `yubikey-manager` (`ykman`) to set or check the FIDO2 PIN. Install it with apt; the
  snap is broken on Ubuntu 26.04.
- `pcscd` for PIV/Teleport and for the OATH and PIV pages of Yubico Authenticator.
- `ssh-askpass-gnome` so GUI git clients can ask for the PIN.

You **don't** need `opensc`, `yubico-piv-tool` or any PKCS#11 module for Git signing.

---

## 🧭 The menu

```text
Guided setup — the whole thing, in order

Set up git signing, step by step
   Install the YubiKey management tools
   Set the FIDO2 PIN
   Create the git signing key
   Enrol the key on GitHub
   Install the GUI askpass helper

Already have a key
   Reimport it from the YubiKey

Check and repair
   Run the dependency check
   Fix agent interception (gcr caching the key)

Same key, other uses
   Prepare PIV for Teleport (hardware key support)
   Use the key for sudo and login (PAM)
```

<details>
<summary><b>Yubico Authenticator (GUI) — install options</b></summary>

<br>

Yubico publishes **no `.deb`**. The script offers three options:

1. **The official tarball from yubico.com.** The script verifies its detached GPG signature
   and checks that the *primary* key fingerprint is on Yubico's
   [published signing keys](https://developers.yubico.com/Software_Projects/Software_Signing.html).
   The signing key is often a subkey, so comparing the primary is the step people miss. The
   archive is checked for path traversal and escaping symlinks before it's unpacked to
   `~/.local/opt/yubico-authenticator`.
2. **Flathub** (`com.yubico.yubioath`). Not publisher-verified, and it lags behind upstream.
3. **YubiKey Manager Qt** from apt. Retired upstream.

The GUI is a management tool only. Git signing doesn't use it.

</details>

---

## 🔐 sudo and login (PAM)

Uses `pam_u2f` with **its own credential**, so your Git signing key is untouched. Pick one of three modes:

| Mode | Behaviour | Stanza in `/etc/pam.d/common-u2f` |
|---|---|---|
| **Password OR key** | Key is a shortcut; password still works | `auth sufficient pam_u2f.so …` |
| **Password AND key** | Both, every time | `auth required pam_u2f.so …` |
| **Key only** | No password fallback | `auth sufficient pam_u2f.so …` + `auth required pam_deny.so` |

### Safety net

You can't lock yourself out without noticing first:

1. The new config is **staged as a throwaway PAM service** and tested with `pamtester`,
   once with the key plugged in and once with it removed.
2. Only then does it go live, with a **3-minute dead-man's switch**: a `systemd-run` timer
   restores `/etc/pam.d` unless you cancel it from a **new** terminal:
   ```bash
   sudo -k && sudo systemctl stop yubikey-pam-rollback.timer
   ```
   That `sudo` runs through the new stack, so getting through it proves the change works.
3. A tarball of the previous `/etc/pam.d` is kept in `/var/backups/`.

> [!WARNING]
> **Key-only mode doesn't cover everything.**
> - **`pkexec` / polkit** reads `/usr/lib/pam.d/polkit-1`, not `/etc/pam.d/other`, so it
>   stays password-only unless you let the script create `/etc/pam.d/polkit-1`, which
>   overrides the vendor file. The script offers this in the locking modes.
> - **`sshd`** never goes through this stack.
> - **GDM login** with the key alone leaves the GNOME keyring locked, because
>   `pam_gnome_keyring` unlocks it with the password you typed. Expect an unlock prompt
>   every session.

> [!CAUTION]
> - Registrations are tied to `origin=pam://<hostname>`. **Renaming the machine
>   invalidates them.**
> - The FIDO2 PIN gives you **8 attempts in total**, shared with Git signing. Running out
>   forces `ykman fido reset`, which also **destroys your signing key**.

<details>
<summary><b>Locked out? Recovery steps</b></summary>

<br>

Ubuntu keeps the root account locked, so you need the GRUB recovery menu or a live USB:

1. Hold **Shift** at boot → *Advanced options* → *recovery mode* → *root shell*
2. Remount and restore:
   ```bash
   mount -o remount,rw /
   tar xzf /var/backups/pam.d-<timestamp>.tgz -C /etc
   ```

</details>

---

## 🛰️ Teleport (PIV)

Teleport's hardware-key support talks to the **PIV** applet through `pcscd`. Git signing
uses FIDO2, so the two never collide. **Prepare PIV for Teleport**:

- checks that `pcscd` is installed and running
- reports **anything else connected to the card**. This matters because `tsh` uses
  `piv-go`, which connects with `SCARD_SHARE_EXCLUSIVE`, so a PKCS#11 bridge such as
  `opensc-pkcs11` loaded by Seahorse or gnome-keyring will make `tsh` fail
- shows what `tsh` would do with each default slot (`9a` / `9c` / `9d` / `9e`)
- offers to change the PIV **PIN** and **PUK** away from the factory defaults
- sets `TELEPORT_ADD_KEYS_TO_AGENT=no` so software-key logins stay out of `gcr-ssh-agent`

It deliberately **creates no key and never changes the management key**. `tsh`
generates its own key on first login and needs the factory management key to do that.

---

## 🛠️ Doing it by hand

<details>
<summary><b>Manual Git signing setup, step by step</b></summary>

<br>

**1. Recover the resident key from the YubiKey.** `ssh-keygen -K` writes into the current
directory and asks for the FIDO2 PIN and a touch.

```bash
mkdir -m 700 -p ~/.config/git/keys && cd ~/.config/git/keys
ssh-keygen -K
```

`-K` downloads *every* resident `ssh:` credential, so identify yours by its embedded
application string:

```bash
for f in *.pub; do
  printf '%s -> ' "$f"
  cut -d' ' -f2 "$f" | base64 -d | tr -c '[:print:]' '\n' | grep -m1 '^ssh:'
done
```

```bash
mv id_ed25519_sk_rk_git-signing     id_ed25519_sk_git
mv id_ed25519_sk_rk_git-signing.pub id_ed25519_sk_git.pub
chmod 600 id_ed25519_sk_git
```

**2. Configure git.** Use absolute paths, because git doesn't expand `~` in `user.signingkey`.

```bash
git config --global gpg.format ssh
git config --global user.signingkey "$HOME/.config/git/keys/id_ed25519_sk_git"
git config --global gpg.ssh.allowedSignersFile "$HOME/.config/git/allowed_signers"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

**3. Write `allowed_signers`.** It holds key material rather than a path, so you can copy
it between machines.

```bash
printf '%s %s\n' "$(git config user.email)" \
  "$(cut -d' ' -f1,2 ~/.config/git/keys/id_ed25519_sk_git.pub)" \
  > ~/.config/git/allowed_signers
```

**4. Verify.**

```bash
cd "$(mktemp -d)" && git init -q \
  && git commit --allow-empty -m "signing test" \
  && git log --show-signature -1
```

Expect `Good "git" signature for <your email>`. Anything else means it failed.

**Starting from scratch** (no resident key yet):

```bash
ssh-keygen -t ed25519-sk -O resident -O application=ssh:git-signing \
  -O verify-required -C "$(git config user.email) git signing" \
  -f ~/.config/git/keys/id_ed25519_sk_git
```

A new key has a new fingerprint, so update `allowed_signers` and your forge.

**Forge.** Upload the `.pub` as a **Signing key**, not an Authentication key. They're
separate entries, and you can add the same key as both. GitHub and GitLab both verify
`sk-ssh-ed25519@openssh.com` signatures. Azure DevOps doesn't show SSH signature status.

</details>

---

## 🩺 Troubleshooting

<details>
<summary><b><code>agent refused operation</code></b> — gcr-ssh-agent is intercepting</summary>

<br>

The key was in `~/.ssh` at some point, and `gcr-ssh-agent` cached it. Moving the file
isn't enough, because the agent keeps it in memory:

```bash
ssh-add -d ~/.config/git/keys/id_ed25519_sk_git.pub
systemctl --user restart gcr-ssh-agent.service
ssh-add -l    # the ED25519-SK line must NOT appear
```

If that doesn't fix it, point `gpg.ssh.program` at a wrapper script that runs
`unset SSH_AUTH_SOCK; exec /usr/bin/ssh-keygen "$@"`. It has to be a script, because git
doesn't split that setting into words.

The menu's **Fix agent interception** does all of this for you.

</details>

<details>
<summary><b>"Enter PIN for authenticator"</b> — which PIN?</summary>

<br>

It wants the **FIDO2** PIN, not the PIV PIN. They're separate. FIDO2 allows 8 wrong
attempts, and after that only a reset helps, which wipes every FIDO credential on the key.
Check how many you have left with `ykman fido info`.

</details>

<details>
<summary><b>Commits fail from VS Code / JetBrains</b></summary>

<br>

With `verify-required`, the PIN prompt goes to `/dev/tty`, and GUI apps don't have one.
Install `ssh-askpass-gnome`, then put `SSH_ASKPASS=/usr/bin/ssh-askpass` in a file under
`~/.config/environment.d/` and log out and back in. OpenSSH falls back to askpass on its
own when there's no tty.

You can also recreate the key without `-O verify-required`. A touch is still required.

</details>

<details>
<summary><b><code>incorrect passphrase supplied to decrypt private key</code></b></summary>

<br>

This doesn't mean the file has a passphrase. It's how OpenSSH reports that it needed the
FIDO2 PIN and had no way to ask for it. See the previous item.

</details>

<details>
<summary><b>Lost the YubiKey?</b></summary>

<br>

The resident credential is the only copy of the key, and it can't be backed up. Create a
second key on a **backup YubiKey** and add both public keys to `allowed_signers` and to
your forge.

</details>

---

## 🧪 Development

`selftest.sh` is a regression harness. It's **read-only**: it doesn't touch `/etc`, apt,
systemd, your GPG keyrings or the YubiKey. Run it after every change:

```bash
./selftest.sh ./yubikey-git-signing.sh
```

It doesn't just read the risky code, it runs it:

- runs the **PAM root transaction and its rollback** against a sandboxed `/etc/pam.d`
- runs **tarball signature verification** with throwaway GPG keys, including the subkey case
- drives the **menu through a pty** at several terminal heights
- runs the archive **path-traversal and symlink** guards against hostile tarballs

It also calls three small linters. Each one was added after a particular bug got past review:

| Linter | Enforces |
|---|---|
| `purity-check.py` | No prompts or changes inside anything `--check` calls |
| `lint-locals.py` | No variable is written before its own `local` declaration |
| `lint-reachable.py` | Key steps aren't accidentally nested inside a conditional |

