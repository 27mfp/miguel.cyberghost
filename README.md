# CyberGhost VPN for Omarchy

A native WireGuard bar plugin for the Omarchy shell. Choose a country, then **Connect**. Server selection is automatic.

**Release scope:** native WireGuard traffic connections only. OpenVPN, streaming/torrent-specific modes and manual server controls are not available. Earlier experimental preferences are reset to WireGuard/automatic selection; unsupported connection requests are rejected.

Omarchy is the supported baseline, not generic Linux. Its rolling package versions, DNS configuration, interfaces and monitor layouts still vary, so prerequisite checks remain necessary. Plugins run unsandboxed inside the existing shell with your user permissions; review the repository before installing.

## Install and set up

```bash
omarchy plugin add https://github.com/27mfp/miguel.cyberghost.git --enable
```

Open the bar icon and complete setup:

1. **Dependencies:** WireGuard tools, Python requests and a working `resolvconf` provider. The panel offers `openresolv` only when no provider is found. Do not replace an existing DNS integration blindly.
2. **Account:** link your CyberGhost account. Native registration sends the password over stdin, uses verified HTTPS, and stores device credentials in private `~/.cyberghost/native.ini`, not the account password.
3. **Helper:** install the fixed root-owned connection helper in the visible terminal. Authorization is required; it is never silently installed.

Alternatively, run `bash install.sh` from the checkout for guided setup. The vendor CLI and OpenVPN compatibility launcher are **not required installation steps** for this release.

Native registration does not overwrite the vendor's `~/.cyberghost/config.ini`. Private legacy device credentials can be read from that file only when `native.ini` is absent. An invalid native file fails closed. Back up private credentials before changing any vendor configuration.

## Daily use

- Left-click the icon to open or close the panel.
- Select a country, then **Connect**. Selecting a country alone never reconnects.
- **Disconnect** stops only this plugin's native WireGuard tunnel.
- Middle/right-click retains the quick connection toggle.
- The eye button masks connection details, including tooltip and location-mismatch information.
- Escape closes dropdowns first, then the panel. Controls support Tab/Enter.
- **Advanced settings** contains the protection disclaimer and optional passwordless authorization—not extra VPN modes.

Automatic selection can use live vendor inventory if already available, otherwise bounded native fallback candidates. It does not measure the fastest latency or throughput. Provider changes can make particular countries or endpoints unavailable.

## Security and network limits

- Native HTTPS verifies certificates and hostnames; WireGuard configuration fields are validated.
- Native routing covers IPv4 and IPv6. DNS setup must succeed; there is no DNS-less retry.
- Activation failures/timeouts attempt cleanup. Cleanup failures can still require manual recovery.
- **This is not a kill switch.** Traffic is not blocked after disconnection. Tunnel/handshake status is diagnostic, not proof of anonymity or leak protection.
- Public-IP lookup contacts `ipwho.is`. Privacy mode masks displayed values, not that request.
- Only the fixed `/usr/local/bin/cyberghost-runner` is invoked through Polkit. It accepts restricted lifecycle requests, not registration or arbitrary configuration paths.
- Helper installation verifies a staged snapshot. Commands, HTTP responses and execution time are bounded.
- A VPN started separately through the vendor CLI is not managed by the native-only release. Disconnect such a session before upgrading from an experimental version.

### Optional passwordless authorization

Normal authorization is the default:

```bash
bash install-helper.sh
```

An explicit opt-in is available under Advanced settings or with:

```bash
bash install-helper.sh --with-polkit-rule
```

This permits processes running as `wheel` members to invoke the fixed helper without another prompt. It is not required. Updating the helper preserves an already-installed rule; it does not revoke authorization.

## Update and remove

```bash
omarchy plugin update miguel.cyberghost
bash ~/.config/omarchy/plugins/miguel.cyberghost/install-helper.sh
```

Version 1.6.2 requires helper capability 8. The panel detects incompatible helpers and offers an update.

Disconnect before removing the plugin. See [installer reference](INSTALLER.md) for helper/rule removal. Preserve `~/.cyberghost/config.ini` if another client uses it. `fresh-install.sh` is a destructive development reset, not an upgrade.

## Development and release checks

Use a real user-owned checkout, not packaged Omarchy source or a symlinked plugin. Work inside the existing shell; never launch a second Quickshell instance for the plugin.

```bash
pytest -q
ruff check .
ruff format --check .
python3 scripts/check_qml.py
bash scripts/test-qml.sh
omarchy plugin validate "$PWD"
```

See [release gates](docs/release-checklist.md), [architecture](docs/architecture.md), [testing](docs/testing.md), and [real-shell visual checks](docs/visual-testing.md). Experimental vendor code and diagnostic scripts retained in the repository are not supported release features.

### IPC

```bash
omarchy-shell shell summon miguel.cyberghost '{}'
omarchy-shell shell hide miguel.cyberghost
omarchy-shell miguel.cyberghost connect PT
omarchy-shell miguel.cyberghost disconnect
omarchy-shell miguel.cyberghost refresh
```

`connect` requests a connection; it is not a toggle. If the plugin cannot open, validate the checkout and inspect the existing shell's log. `active: false` in the plugin list describes full-bar selection on the tested Omarchy version, not widget health.
