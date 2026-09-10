# CyberGhost VPN for Omarchy

<p align="center"><img src="icon.svg" alt="CyberGhost VPN" width="128" height="128"></p>

A native WireGuard VPN plugin for the Omarchy bar. Choose a country and connect with one click.

[Open the CyberGhost plugin in the Omarchy plugin directory](https://plugins.omarchy.org/plugin.html?id=miguel.cyberghost)

## Preview

<p align="center">
  <img src="docs/screenshots/screenshot-disconnected.png" alt="CyberGhost VPN disconnected with connection details hidden" width="360">
  <img src="docs/screenshots/screenshot_connected.png" alt="CyberGhost VPN connected to Portugal with WireGuard active" width="360">
</p>

## Install

```bash
omarchy plugin add https://github.com/27mfp/miguel.cyberghost.git --enable
```

Open the ghost icon and complete the setup steps:

1. Install the required dependencies: WireGuard tools, Python requests, and a working `resolvconf` provider.
2. Link your CyberGhost account. Native credentials are stored in `~/.cyberghost/native.ini`.
3. Install the fixed root helper in the visible terminal when prompted.

You can also run `bash install.sh` from a checkout for guided setup. The vendor CLI is not required.

## Use

- Select a country, then click **Connect**.
- Click **Disconnect** to stop this plugin's WireGuard tunnel.
- Selecting a country alone never reconnects.
- Left-click opens the panel; middle- and right-click toggle the VPN.

Server selection is automatic. The plugin may use existing vendor inventory to choose an endpoint, with native fallback candidates when inventory is unavailable.

## Scope and limits

- Supported mode: native WireGuard traffic connections only.
- OpenVPN, streaming, torrent, and manual-server controls are not supported.
- This is not a kill switch and does not claim leak protection or anonymity.
- DNS setup must succeed before a tunnel is activated.
- A separate vendor VPN session is not managed by this plugin.
- Public-IP lookup uses `ipwho.is`; privacy mode only masks the displayed values.

The plugin preserves the vendor's `~/.cyberghost/config.ini`. Disconnect before removing or upgrading from an experimental vendor-based version.

## Update and remove

```bash
omarchy plugin update miguel.cyberghost
bash ~/.config/omarchy/plugins/miguel.cyberghost/install-helper.sh
```

The helper must be updated after a plugin version or capability change. Disconnect before removal. See [installer reference](INSTALLER.md) for helper, Polkit, and reset details.

## Development

```bash
pytest -q
ruff check .
ruff format --check .
bash scripts/test-qml.sh
```

Read the [release checklist](docs/release-checklist.md), [architecture](docs/architecture.md), and [testing guide](docs/testing.md) for additional details. The repository contains experimental vendor compatibility code, but it is not part of the supported release.
