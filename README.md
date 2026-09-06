# CyberGhost VPN for Omarchy

A Quickshell bar plugin for CyberGhost on Omarchy/Arch Linux. Choose a country, then **Connect**. Server, mode and protocol choices live under **Advanced settings**.

Plugins run unsandboxed with your user permissions inside the existing Omarchy shell. Review this repository, its commands and optional dependencies before installing it.

## Install and set up

```bash
omarchy plugin add https://github.com/27mfp/miguel.cyberghost.git --enable
```

Open the bar icon and follow the required setup steps:

1. **Dependencies:** WireGuard tools, Python requests and a `resolvconf` provider. The panel offers `openresolv` only when no provider is found; do not replace an existing DNS integration blindly.
2. **Account:** link your CyberGhost account. Native registration sends the password over stdin to the runner, uses verified HTTPS, and stores only the account identifier and device token/secret in private `~/.cyberghost/native.ini`.
3. **Connection helper:** install the root-owned helper in a visible terminal. Authorization is required. Updating the plugin also requires updating this helper when its version/capability changes.

Alternatively, run `bash ./install.sh` from the plugin directory for guided terminal setup. Each installation step asks before changing the system.

### Optional advanced features

The official `cyberghostvpn` CLI supplies exact server inventory, OpenVPN, torrent and streaming modes. Native WireGuard traffic mode has automatic fallback candidates without it.

Install the CLI from a source you trust. For the installed Linux CLI 1.4.1, run setup **from your desktop user's terminal**, using sudo as required by the vendor:

```bash
sudo cyberghostvpn --setup
```

When updating an existing configuration, explicitly type `y` at both **override original configuration** and **change account credentials**, then enter your account login. In CLI 1.4.1, pressing Enter means **no**, despite the `[Y/n]` prompt; it can print “Install completed” and exit successfully without configuring authentication.

Alternatively, from this plugin checkout run `python3 scripts/setup-vendor-cli.py` in your terminal, **without sudo on the Python command**. The wrapper invokes sudo itself and makes Enter select Yes at those two known confirmations. Explicit `n` still declines. Password input is unchanged, and the wrapper records no transcript. It does not patch the vendor binary.

This version constructs its configuration directory from `/home/` plus `SUDO_USER` (or `USER`), rather than respecting `HOME`. Do not launch it from a root login shell or assume a HOME override selects the account. Nonstandard home directories need separate compatibility validation.

The vendor CLI requires a locally stored account password. Use **Advanced settings → Recheck CLI setup** afterwards. An installed CLI is not necessarily configured, and local configuration does not prove successful vendor authentication.

**Before overwriting legacy configuration:** if `native.ini` is absent, native WireGuard may still depend on device credentials in `config.ini`. Back up that private file and preserve its native device credentials separately before allowing vendor setup to replace it.

**Credential separation:** vendor CLI setup owns `~/.cyberghost/config.ini`. Native registration never overwrites it. For compatibility, the plugin can read private legacy device credentials from that file when `native.ini` does not exist. A present but invalid native file fails rather than silently falling back. The vendor CLI has its own credential-storage policy; the plugin's no-saved-password guarantee applies only to native registration.

### Optional passwordless authorization

Helper installation defaults to normal Polkit authorization:

```bash
bash ./install-helper.sh
```

To explicitly allow passwordless connection lifecycle actions:

```bash
bash ./install-helper.sh --with-polkit-rule
```

The same option is available under **Advanced settings**. The rule permits processes running as `wheel` members to invoke the fixed helper without another prompt. It is not required. A helper-only update preserves an already-installed rule; it does not revoke authorization.

## Daily use

- Left-click the icon to open/close the panel.
- Select a country, then press **Connect**. Selecting a country alone never reconnects.
- Press **Disconnect** to stop the VPN. Background inventory/status work does not disable this action.
- Middle/right-click retains the quick connection toggle.
- **Advanced settings:** automatic or exact server, traffic/torrent/streaming, WireGuard/OpenVPN UDP/OpenVPN TCP.
- Changing preferences leaves the live connection alone; changes apply on the next connection.
- Connection details show the observed public IP/location, provider and available tunnel statistics. The eye button masks details, including the tooltip and geolocation mismatch text.
- Escape closes the panel; dropdowns handle Escape first. Controls support Tab/Enter.

“Automatic” selects by lowest reported load when live inventory is available, otherwise bounded fallback candidates. It does **not** measure the fastest latency or throughput.

## Network and security limits

| Mode | Backend |
| --- | --- |
| WireGuard + traffic | Native CyberGhost key exchange and `wg-quick` |
| OpenVPN, torrent, streaming | Official vendor CLI |

- Native HTTPS verifies certificates and hostnames. Configuration fields are validated to prevent injected WireGuard directives.
- The native tunnel includes IPv4 and IPv6 default routes. This is **not a kill switch**, nor proof of leak protection across every failure or reconnect.
- VPN DNS setup must succeed. The plugin no longer retries without DNS after `resolvconf` fails. Activation failures/timeouts attempt cleanup; failed cleanup can still need manual recovery.
- A stale-handshake warning is a diagnostic, not traffic blocking. **Tunnel active** reports observed tunnel state, not a guarantee of anonymity.
- Public-IP lookup sends a request to `ipwho.is`, throttled while connected and refreshed on panel open. Privacy mode masks displayed values; it does not disable this lookup.
- Only the fixed root-owned `/usr/local/bin/cyberghost-runner` is invoked through `pkexec`. It accepts restricted lifecycle actions, not registration or arbitrary config paths. The installer snapshots and verifies helper content before installation.
- Python subprocess/HTTP output and requests are bounded. Native API compatibility and vendor CLI availability remain external dependencies.

## Update

```bash
omarchy plugin update miguel.cyberghost
bash ~/.config/omarchy/plugins/miguel.cyberghost/install-helper.sh
```

The panel detects an incompatible helper and offers **Update helper**. It never silently installs privileged code. Version 1.6.0 requires the updated helper before connecting.

## Remove

Disconnect first, then remove the widget:

```bash
omarchy-shell miguel.cyberghost disconnect
omarchy plugin disable miguel.cyberghost
omarchy plugin remove miguel.cyberghost --yes
sudo rm -f /etc/polkit-1/rules.d/50-cyberghost.rules /usr/local/bin/cyberghost-runner
sudo rm -f /etc/wireguard/cyberghost.conf
rm -f ~/.local/state/cyberghost/polkit-rule-installed
# Optional: remove native credentials only
rm -f ~/.cyberghost/native.ini
```

Keep `~/.cyberghost/config.ini` if you use the vendor CLI. `fresh-install.sh` is a **destructive development reset**, not an ordinary upgrade: it removes the plugin/helper/native state, while preserving vendor credentials. Preserved legacy credentials may still satisfy account readiness.

## Development

Work in a real user-owned directory, never in packaged Omarchy source and never with symlinks inside the plugin folder. For a new checkout only:

```bash
git clone https://github.com/27mfp/miguel.cyberghost.git ~/.config/omarchy/plugins/miguel.cyberghost
cd ~/.config/omarchy/plugins/miguel.cyberghost
omarchy plugin validate "$PWD"
```

Saved changes hot-reload. Use `omarchy-shell shell rescanPlugins` for discovery. After adding/renaming entry-point files, an existing shell can retain a stale Qt file cache; a single `omarchy restart shell` may be needed. Never launch a second Quickshell process for the plugin.

```bash
pytest -q
ruff check .
ruff format --check .
python3 scripts/check_qml.py  # requires installed Omarchy/Quickshell metadata
bash scripts/test-qml.sh     # Qt tests; does not start Quickshell
omarchy plugin validate "$PWD"
```

See [architecture and review decisions](docs/architecture.md), [test strategy and validation limits](docs/testing.md), [real-shell visual checks](docs/visual-testing.md), and [installer reference](INSTALLER.md).

### IPC

```bash
omarchy-shell shell summon miguel.cyberghost '{}'
omarchy-shell shell hide miguel.cyberghost
omarchy-shell miguel.cyberghost connect PT
omarchy-shell miguel.cyberghost disconnect
omarchy-shell miguel.cyberghost refresh
```

`connect` requests a connection; it is not a disconnect toggle. The bar's middle/right-click remains a toggle.

## Troubleshooting

| Problem | Next step |
| --- | --- |
| Update helper appears | Run the bundled helper installer and recheck; the UI and installed helper must match. |
| CLI installed but exact servers unavailable | Complete CLI setup in the shell user's HOME, then recheck. Automatic native selection remains available. |
| DNS setup fails | Check your `resolvconf` provider and resolver integration. No DNS-less retry is attempted. |
| Certificate/key-exchange failure | Check subscription and network/vendor availability; do not disable TLS verification. |
| Plugin listed but cannot open | Validate the folder and inspect `qs log -p "$OMARCHY_PATH/shell" --tail 100`; rescan after structural changes. |
| `active: false` in plugin list | On this Omarchy version, `active` describes full-bar selection, not bar-widget health. Use enabled state and summon/hide to verify this widget. |
