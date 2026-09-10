# Installer reference

Published listing: [CyberGhost VPN for Omarchy](https://plugins.omarchy.org/plugin.html?id=miguel.cyberghost)

| Script | Purpose | Privileges |
| --- | --- | --- |
| `install.sh` | Guided native WireGuard dependency/account/helper setup. Does not install the vendor CLI. | Explicit terminal sudo for packages/helper. |
| `install-helper.sh` | Install/update the fixed, root-owned connection helper. | Explicit terminal sudo; no mutable plugin path is executed as root. |
| `fresh-install.sh` | Destructive developer reset/reinstall, not a normal upgrade. | Removes installed helper/rule with authorization. |

## Helper options

```bash
bash install-helper.sh                     # helper only, normal authorization
bash install-helper.sh --with-polkit-rule  # explicit passwordless opt-in
bash install-helper.sh --no-polkit-rule    # equivalent to helper-only default
bash install-helper.sh --revoke-polkit-rule # explicitly revoke this plugin rule
```

Helper-only updates **preserve existing Polkit rules**. `--with-polkit-rule` generates a rule for the installing user only (and still requires that user to remain in `wheel`). `--revoke-polkit-rule` removes that rule only when its bytes still match the generated snapshot; customized or failed removals are refused and the UI marker is retained. The normal installer never silently revokes authorization.

The installer snapshots regular source files before asking for sudo, copies them into a new root-only staging directory, verifies SHA-256 digests, and publishes fixed files through atomic renames. It rejects unsafe source/staging paths and only cleans staging it created successfully. These digests provide checkout-to-install integrity, not release provenance; use a trusted checkout or an independently verified signed release when provenance matters. Reinstall after a helper version or capability update; the panel detects mismatches.

## State ownership

- `~/.cyberghost/native.ini`: plugin-native account identifier and device token/secret, private permissions; no password.
- `~/.cyberghost/config.ini`: vendor CLI/legacy state. Native registration and developer reset do not overwrite/delete it.
- `/usr/local/bin/cyberghost-runner`: root-owned lifecycle helper.
- `/run/lock/cyberghost.lock`: persistent root-owned lifecycle lock; it is never removed after use.
- `/etc/wireguard/cyberghost.conf`: root-owned generated tunnel configuration, including the private WireGuard key.
- `/etc/polkit-1/rules.d/50-cyberghost.rules`: optional authorization rule.
- `~/.local/state/cyberghost/polkit-rule-installed`: user-owned UI marker, not authorization.

`omarchy plugin add` only installs the repository; it does not run these scripts or authorize system changes. The plugin stays in the existing shell process. Complete setup through its panel or a visible terminal.
