# Installer reference

| Script | Purpose | Privileges |
| --- | --- | --- |
| `install.sh` | Guided dependency/account/helper setup. Optional AUR CLI installation is a separate trust decision. | Explicit terminal sudo for packages/helper. |
| `install-helper.sh` | Install/update the fixed, root-owned connection helper. | Explicit terminal sudo; no mutable plugin path is executed as root. |
| `fresh-install.sh` | Destructive developer reset/reinstall, not a normal upgrade. | Removes installed helper/rule with authorization. |

## Helper options

```bash
bash install-helper.sh                     # helper only, normal authorization
bash install-helper.sh --with-polkit-rule  # explicit passwordless opt-in
bash install-helper.sh --no-polkit-rule    # equivalent to helper-only default
```

Helper-only updates **preserve existing Polkit rules**. To revoke passwordless access, remove `/etc/polkit-1/rules.d/50-cyberghost.rules` with authorization and remove the user UI marker at `~/.local/state/cyberghost/polkit-rule-installed`.

The installer snapshots regular source files before asking for sudo, copies them into a new root-only staging directory, verifies SHA-256 digests, and installs the fixed files. It rejects unsafe source/staging paths. Reinstall after a helper version or capability update; the panel detects mismatches.

## State ownership

- `~/.cyberghost/native.ini`: plugin-native account identifier and device token/secret, private permissions; no password.
- `~/.cyberghost/config.ini`: vendor CLI/legacy state. Native registration and developer reset do not overwrite/delete it.
- `/usr/local/bin/cyberghost-runner`: root-owned lifecycle helper.
- `/etc/wireguard/cyberghost.conf`: root-owned generated tunnel configuration, including the private WireGuard key.
- `/etc/polkit-1/rules.d/50-cyberghost.rules`: optional authorization rule.
- `~/.local/state/cyberghost/polkit-rule-installed`: user-owned UI marker, not authorization.

`omarchy plugin add` only installs the repository; it does not run these scripts or authorize system changes. The plugin stays in the existing shell process. Complete setup through its panel or a visible terminal.
