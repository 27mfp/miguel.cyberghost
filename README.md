# CyberGhost VPN for Omarchy Shell

A native, lightweight status bar widget and popup panel for managing **CyberGhost VPN** on Omarchy / Arch Linux, built on Quickshell.

---

## ✨ Features

### Status Bar Widget
- 👻 Custom CyberGhost vector icon (brand yellow `#FFCE00` when connected).
- 🟢 Active indicator dot; pulsing dot during connect/disconnect handshakes.
- ⚠️ Warning badge if the tunnel's WireGuard handshake goes stale (>3 min) plus a desktop notification.
- 📎 Informative tooltips: connection state, country, flag and public IP.
- 🖱️ **Middle-click or right-click** toggles the VPN instantly; **left-click** opens the panel.

### Popup Panel
- ⚡ **One-click connect/disconnect** via header power switch or action button.
- 🔍 **Connection details card** — clean stacked view of:
  - **IP** — live public IP with click-to-copy.
  - **Location** — city + country resolved from GeoIP.
  - **Provider** — ISP/network organization.
  - **Session** — transfer totals, handshake freshness and VPN endpoint while connected.
  - Status badge (`PROTECTED & ENCRYPTED` / `PUBLIC IP EXPOSED`) and active protocol pill.
- 🌍 **Country switching:**
  - Quick-connect grid with 12 popular locations (instant connect).
  - Searchable dropdown covering all 100+ CyberGhost countries (selects a target; connect explicitly).
- 🛡️ **Server modes:** ⚡ Traffic · 🔒 Torrent (P2P) · 🎬 Streaming.
- 🔒 **Protocols:** WireGuard · OpenVPN UDP · OpenVPN TCP.
  - Changing mode or protocol while connected never tears down the live tunnel — it applies on the next connect.
- 🔔 Desktop notifications on connect, disconnect, errors and stale-handshake warnings.
- ℹ️ Error/status banner with human-readable messages.
- 💾 Last country / protocol / server mode are remembered across restarts.

## 🧠 How It Works

| Mode | Backend |
|---|---|
| WireGuard + Traffic | **Native**: generates WireGuard keys locally and negotiates them directly with CyberGhost's dialer API (`*.cg-dialup.net`) — no CLI needed. Falls back through multiple server instances automatically. The tunnel covers **IPv4 and IPv6** (`0.0.0.0/0, ::/0`), so there is no v6 leak. |
| OpenVPN UDP/TCP, Torrent, Streaming | **Delegated** to the official `cyberghostvpn` CLI. |

Security posture:
- Key-exchange requests use **strict TLS verification** — if the certificate chain fails, credentials are never sent.
- A **handshake watchdog** warns you (notification + bar badge) when the tunnel stops handshaking, instead of silently leaking traffic.
- The optional Polkit rule is **pinned to the plugin's install path**, so unrelated scripts cannot reuse it to run as root.

The widget polls VPN status using the runner's JSON output and checks your public IP/GeoIP via ipinfo.io — throttled to at most one request per 20s while connected (plus a forced refresh when the panel opens or you disconnect), well within free API limits.

```
Panel.qml (UI) ──> Service.qml (state machine) ──> pkexec ──> cyberghost_runner.py (backend)
```

---

## 📦 Requirements

1. **WireGuard tools**: `sudo pacman -S wireguard-tools`
2. **Python requests** (native key exchange + account registration): `sudo pacman -S python-requests`
3. A CyberGhost subscription — account linking happens **in the widget** (native API, no CLI).
4. *(Optional)* `cyberghostvpn` CLI — only needed at runtime for OpenVPN / torrent / streaming modes.
5. *(Optional)* Polkit rule for passwordless connect/disconnect.

> The widget runs without any of this and shows a **setup wizard in its panel** — install dependencies with one click (polkit dialog), link your CyberGhost account with a native API form, done. Nothing breaks if you install the plugin first and configure later.

---

## 🚀 Installation

**Quick start (2 commands):**

```bash
omarchy plugin add https://github.com/27mfp/miguel.cyberghost.git --enable
bash ~/.config/omarchy/plugins/miguel.cyberghost/install.sh
```

The first command installs and places the widget on your bar (Omarchy asks which section; it defaults to *right*). The second checks dependencies and offers to install what's missing — every step asks before changing anything, and it's safe to re-run. Or skip the script entirely: open the widget and follow the **FIRST-RUN SETUP** panel.

Or clone manually:

```bash
git clone https://github.com/27mfp/miguel.cyberghost.git ~/.config/omarchy/plugins/miguel.cyberghost
omarchy plugin enable miguel.cyberghost right
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

By default `pkexec` asks for your password on every connect/disconnect. To skip the prompt, copy the included Polkit rule (allows members of the `wheel` group to run **this plugin's runner, from its installed path**, without a password):

```bash
sudo cp 50-cyberghost.rules /etc/polkit-1/rules.d/
```

---

## 🧪 Development

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

Lint and tests (also enforced by CI):

```bash
ruff check .
pytest -q            # or: python3 tests/test_runner.py
```

---

## 🧯 Troubleshooting

| Symptom | Fix |
|---|---|
| "FIRST-RUN SETUP" checklist in panel | Run `bash ~/.config/omarchy/plugins/miguel.cyberghost/install.sh` or follow the hints next to each unchecked item |
| "Configuration file not found" | Run `sudo cyberghostvpn --setup`, or place credentials in `~/.cyberghost/config.ini` under `[device]` (`token`, `secret`) |
| Authentication failed on connect | Check your CyberGhost subscription / re-run setup |
| Connect works, but no internet | Try the DNS fallback path (runner retries automatically), or switch protocol to WireGuard if on OpenVPN |
| Account link fails in the wizard | Check username/password; the CLI is NOT required for this step — it talks to CyberGhost's API natively |
| OpenVPN/Torrent/Streaming fails | Ensure the `cyberghostvpn` CLI is installed and logged in — those modes are delegated to it |
| IP shows "Unavailable" | ipinfo.io may be unreachable/rate-limited; hit **Refresh Status** |

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.
