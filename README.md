# CyberGhost VPN for Omarchy Shell

A native, lightweight status bar widget and popup panel for managing **CyberGhost VPN** on Omarchy / Arch Linux, built on Quickshell.

---

## ✨ Features

### Status Bar Widget
- 👻 Custom CyberGhost vector icon (brand yellow `#FFCE00` when connected).
- 🟢 Active indicator dot; pulsing dot during connect/disconnect handshakes.
- 📎 Informative tooltips: connection state, country, flag and public IP.
- 🖱️ **Middle-click** to toggle the VPN instantly; **left/right-click** opens the panel.

### Popup Panel
- ⚡ **One-click connect/disconnect** via header power switch or action button.
- 🔍 **Connection details card** — clean stacked view of:
  - **IP** — live public IP with click-to-copy.
  - **Location** — city + country resolved from GeoIP.
  - **Provider** — ISP/network organization.
  - Status badge (`PROTECTED & ENCRYPTED` / `PUBLIC IP EXPOSED`) and active protocol pill.
- 🌍 **Country switching:**
  - Quick-connect grid with 12 popular locations.
  - Searchable dropdown covering all 100+ CyberGhost countries.
- 🛡️ **Server modes:** ⚡ Traffic · 🔒 Torrent (P2P) · 🎬 Streaming.
- 🔒 **Protocols:** WireGuard · OpenVPN UDP · OpenVPN TCP.
- 🔔 Desktop notifications on connect, disconnect and errors.
- ℹ️ Error/status banner with human-readable messages.

## 🧠 How It Works

| Mode | Backend |
|---|---|
| WireGuard + Traffic | **Native**: generates WireGuard keys locally and negotiates them directly with CyberGhost's dialer API (`*.cg-dialup.net`) — no CLI needed. Falls back through multiple server instances automatically. |
| OpenVPN UDP/TCP, Torrent, Streaming | **Delegated** to the official `cyberghostvpn` CLI. |

The widget polls VPN status using the runner's JSON output and checks your public IP/GeoIP via ipinfo.io — throttled to at most one request per 20s while connected (plus a forced refresh when the panel opens or you disconnect), well within free API limits.

```
Panel.qml (UI) ──> Service.qml (state machine) ──> pkexec ──> cyberghost_runner.py (backend)
```

---

## 📦 Requirements

1. **WireGuard tools**:
   ```bash
   sudo pacman -S wireguard-tools
   ```
2. **Python requests** (used by the native key exchange):
   ```bash
   sudo pacman -S python-requests
   ```
3. **CyberGhost account config** (one-time setup, generates the device token):
   ```bash
   yay -S cyberghostvpn
   sudo cyberghostvpn --setup
   ```
   > Only needed for credential setup — WireGuard traffic mode does not use the CLI at runtime.

---

## 🚀 Installation

Install directly with the Omarchy plugin CLI:

```bash
omarchy plugin add https://github.com/27mfp/miguel.cyberghost.git --enable
```

Or clone manually:

```bash
git clone https://github.com/27mfp/miguel.cyberghost.git ~/.config/omarchy/plugins/miguel.cyberghost
omarchy restart shell
```

Then make sure it is included in your `~/.config/omarchy/shell.json` under `bar.layout.right`:

```json
{ "id": "miguel.cyberghost" }
```

---

## ⚙️ Settings

Configurable from the Omarchy plugin settings:

| Key | Type | Default | Description |
|---|---|---|---|
| `refreshIntervalSec` | int (5–60) | `8` | Status polling interval in seconds |
| `defaultCountry` | string | `PT` | Country code used on first connect (e.g. `PT`, `US`, `DE`) |
| `protocol` | string | `wireguard` | `wireguard`, `openvpn` (UDP) or `openvpn_tcp` |
| `serverType` | string | `traffic` | `traffic`, `torrent` or `streaming` |

---

## 🎮 IPC Commands

Control the plugin from scripts or keybindings via `qs ipc`:

```bash
qs ipc call miguel.cyberghost toggle      # open/close the panel
qs ipc call miguel.cyberghost connect     # connect to current/default country
qs ipc call miguel.cyberghost connect US  # connect to a specific country
qs ipc call miguel.cyberghost disconnect  # disconnect the VPN
qs ipc call miguel.cyberghost refresh     # force a status + IP refresh
```

Example Hyprland keybinding:

```ini
bind = SUPER, V, exec, qs ipc call miguel.cyberghost connect
```

---

## 🔐 Passwordless Connection via Polkit (Optional)

By default `pkexec` asks for your password on every connect/disconnect. To skip the prompt, copy the included Polkit rule (allows members of the `wheel` group to run this plugin's runner without a password):

```bash
sudo cp 50-cyberghost.rules /etc/polkit-1/rules.d/
```

---

## 🛠️ Development

The recommended workflow is to keep the repo anywhere (e.g. `~/Code/miguel.cyberghost`) and symlink it into the plugins directory, so edits take effect without re-copying files:

```bash
ln -s ~/Code/miguel.cyberghost ~/.config/omarchy/plugins/miguel.cyberghost
omarchy restart shell   # reload after changes
```

Run the backend standalone:

```bash
python3 cyberghost_runner.py status --json
sudo python3 cyberghost_runner.py connect --country PT --protocol wireguard --server-type traffic
python3 cyberghost_runner.py --help
```

---

## 🧯 Troubleshooting

| Symptom | Fix |
|---|---|
| "wireguard-tools not installed" banner | `sudo pacman -S wireguard-tools` |
| "Configuration file not found" | Run `sudo cyberghostvpn --setup`, or place credentials in `~/.cyberghost/config.ini` under `[device]` (`token`, `secret`) |
| Authentication failed on connect | Check your CyberGhost subscription / re-run setup |
| Connect works, but no internet | Try the DNS fallback path (runner retries automatically), or switch protocol to WireGuard if on OpenVPN |
| OpenVPN/Torrent/Streaming fails | Ensure the `cyberghostvpn` CLI is installed and logged in — those modes are delegated to it |
| IP shows "Unavailable" | ipinfo.io may be unreachable/rate-limited; hit **Refresh Status** |

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.
