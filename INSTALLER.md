# Installer reference

Published listing: [CyberGhost VPN for Omarchy](https://plugins.omarchy.org/plugin.html?id=miguel.cyberghost)

Since 1.7.0 the plugin installs nothing as root. The tunnel is an in-memory NetworkManager WireGuard connection that the plugin creates as your user. NetworkManager's Polkit policy authorizes it, just as it does for Omarchy's own network panel.

| Script | Purpose | Privileges |
| --- | --- | --- |
| `install.sh` | Guided setup: `python-requests` if missing, account link, and removal of pre-1.7 files. Does not install the vendor CLI. | `sudo pacman` only if `python-requests` is missing. |
| `scripts/remove-legacy-helper.sh` | Removes recognized root helper and Polkit rule files left by releases before 1.7. The panel opens it in Omarchy's floating terminal. | One explicit `sudo` step, run in a visible terminal. |
| `fresh-install.sh` | Destructive developer reset and reinstall, not a normal upgrade. | Removes legacy root files with authorization. |

## Legacy cleanup rules

`remove-legacy-helper.sh` refuses to run while a tunnel from the old helper is still up, because only that helper can remove it. Disconnect from the panel first. It then removes only files it can recognize:

- `/usr/local/bin/cyberghost-runner`: only a root-owned regular file carrying the plugin's version marker.
- `/etc/polkit-1/rules.d/50-cyberghost.rules`: only if its sole program match is the old helper, or it is one of the pre-1.5 rules that let `python3` run the user-writable plugin runner as root. Those older rules are a standing root grant and are always removed. A customized rule is left alone and reported.
- `/etc/wireguard/cyberghost.conf` is preserved because historical configs have no unique ownership marker. Remove it manually only if you know it is obsolete.
- `/run/lock/cyberghost.lock` is preserved. Removing an advisory lock path can bypass serialization if another process still holds its old inode.

Cleanup rechecks that no `cyberghost` interface exists after authorization; disconnect before running it, including a new NetworkManager tunnel. Developer reset uses `--yes --strict`: unknown helpers and customized rules cause it to abort before removing the installed plugin.

## State ownership

- `~/.cyberghost/native.ini`: plugin-native account identifier, device token/secret and the login session token (JWT) with the numeric account id. Mode 0600, owned by you, never the password. The session token reads CyberGhost's live server list (`/my/servers/filters/74`, the same endpoint the official CLI uses), which the device token cannot. It is checked locally for expiry and never sent once expired. Connects then fall back to probing. Disconnect first, then **Link account** refreshes it; linking is serialized with other lifecycle operations and refuses an active or unverifiable tunnel. **Log out** deletes the whole file.
- `~/.cyberghost/config.ini`: vendor CLI/legacy state. Native registration and developer reset do not overwrite or delete it.
- NetworkManager profile **CyberGhost VPN** (interface `cyberghost`): created with `save no`, so it is never written to `/etc/NetworkManager/system-connections`. It is restricted to your user (`connection.permissions`). Its per-session private key reaches NetworkManager over stdin (`nmcli connection edit`), never through argv. Disconnect deletes it, and it also disappears when NetworkManager restarts.

- `~/.cache/cyberghost/servers.json`: public server names for each country (no credentials), built from your own account. A background sync fills it while your login session is valid, paced at one country every 5 s, stopping at any rate limit and resuming later. Countries refreshed within a week are skipped. Connects refresh their own country. Entries do not expire, because every connect probes the names first.

`omarchy plugin add` only installs the repository; it does not run these scripts or authorize system changes. The plugin stays in the existing shell process.
