# Installer reference

Published listing: [CyberGhost VPN for Omarchy](https://plugins.omarchy.org/plugin.html?id=miguel.cyberghost)

Since 1.7.0 the plugin installs nothing as root. The tunnel is an in-memory NetworkManager WireGuard connection that the plugin creates as your user. NetworkManager's Polkit policy authorizes it, just as it does for Omarchy's own network panel.

| Script | Purpose | Privileges |
| --- | --- | --- |
| `install.sh` | Guided setup: `python-requests` if missing, account link, and removal of pre-1.7 files. Does not install the vendor CLI. | `sudo pacman` only if `python-requests` is missing. |
| `scripts/remove-legacy-helper.sh` | Removes the root helper, Polkit rule and generated config left by releases before 1.7. The panel opens it in Omarchy's floating terminal. | One explicit `sudo` step, run in a visible terminal. |
| `fresh-install.sh` | Destructive developer reset and reinstall, not a normal upgrade. | Removes legacy root files with authorization. |

## Legacy cleanup rules

`remove-legacy-helper.sh` refuses to run while a tunnel from the old helper is still up, because only that helper can remove it. Disconnect from the panel first. It then removes only files it can recognize:

- `/usr/local/bin/cyberghost-runner`: only a root-owned regular file carrying the plugin's version marker.
- `/etc/polkit-1/rules.d/50-cyberghost.rules`: only if its sole program match is the old helper, or it is one of the pre-1.5 rules that let `python3` run the user-writable plugin runner as root. Those older rules are a standing root grant and are always removed. A customized rule is left alone and reported.
- `/etc/wireguard/cyberghost.conf` (only when no `cyberghost` interface exists) and `/run/lock/cyberghost.lock`.

## State ownership

- `~/.cyberghost/native.ini`: plugin-native account identifier, device token/secret and the login session token (JWT) with the numeric account id. Mode 0600, owned by you, never the password. The session token reads CyberGhost's live server list (`/my/servers/filters/74`, the same endpoint the official CLI uses), which the device token cannot. It is checked locally for expiry and never sent once expired. Connects then fall back to probing, and **Link account** refreshes it. **Log out** deletes the whole file.
- `~/.cyberghost/config.ini`: vendor CLI/legacy state. Native registration and developer reset do not overwrite or delete it.
- NetworkManager profile **CyberGhost VPN** (interface `cyberghost`): created with `save no`, so it is never written to `/etc/NetworkManager/system-connections`. It is restricted to your user (`connection.permissions`). Its per-session private key reaches NetworkManager over stdin (`nmcli connection edit`), never through argv. Disconnect deletes it, and it also disappears when NetworkManager restarts.

- `~/.cache/cyberghost/servers.json`: public server names from your last live lookup per country (no credentials), used for 30 days before the bundled snapshot takes over again.
- `servers.json` (in the plugin): snapshot of CyberGhost's server names. Maintainers refresh it with `python3 scripts/update-servers.py` after linking an account. It is paced and backs off on rate limits (about 8 minutes).

`omarchy plugin add` only installs the repository; it does not run these scripts or authorize system changes. The plugin stays in the existing shell process.
