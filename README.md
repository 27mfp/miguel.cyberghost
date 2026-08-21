# CyberGhost VPN for Omarchy Shell

A native, lightweight, and responsive Quickshell status bar widget and panel for managing **CyberGhost VPN** on Omarchy / Arch Linux.

---

## ✨ Features

- 👻 **Status Bar Widget:**
  - Custom vector CyberGhost icon (scales crisply with any theme and DPI).
  - Status indicators: connected dot, pulsing animation during connection handshakes.
  - Informative tooltips displaying active server, country, protocol, and external IP.
- ⚡ **One-Click Controls:**
  - Header toggle switch for instant connect/disconnect.
  - Middle-click shortcut directly on the bar icon.
- 🌍 **100+ Countries & Fast Switching:**
  - Quick-connect buttons for popular locations (🇵🇹 Portugal, 🇪🇸 Spain, 🇬🇧 UK, 🇺🇸 USA, 🇩🇪 Germany, 🇳🇱 Netherlands, 🇨🇭 Switzerland, 🇫🇷 France, 🇮🇹 Italy, 🇧🇷 Brazil, 🇨🇦 Canada, 🇸🇪 Sweden).
  - Searchable dropdown with real-time filtering covering all 100+ CyberGhost server countries.
- 🛡️ **Server Modes:**
  - **⚡ Traffic:** Fastest standard routing for daily browsing.
  - **🔒 Torrent (P2P):** Specialized torrenting servers.
  - **🎬 Streaming:** Streaming-optimized server locations.
- 🔒 **Multi-Protocol Support:**
  - WireGuard (fastest, modern default).
  - OpenVPN UDP.
  - OpenVPN TCP.
- 🌐 **Real-Time Network Diagnostics:**
  - Live external IP detection, GeoIP resolution, and ISP information.
- ⌨️ **Full Keyboard Navigation:**
  - Standard Omarchy shortcuts: <kbd>Space</kbd> to toggle, <kbd>R</kbd> to refresh status, <kbd>Esc</kbd> to close.

---

## 📦 Requirements

1. **CyberGhost VPN CLI** installed on Arch Linux / Omarchy:
   ```bash
   yay -S cyberghostvpn
   # or paru -S cyberghostvpn
   ```
2. Configure your CyberGhost account:
   ```bash
   sudo cyberghostvpn --setup
   ```
3. *(Optional but recommended)* WireGuard tools:
   ```bash
   sudo pacman -S wireguard-tools
   ```

---

## 🚀 Installation

Install directly with the Omarchy plugin CLI:

```bash
omarchy plugin add https://github.com/<username>/<repo-name>.git --enable
```

Or clone manually to your user plugins directory:

```bash
mkdir -p ~/.config/omarchy/plugins/
cp -r miguel.cyberghost ~/.config/omarchy/plugins/
```

And add to your `~/.config/omarchy/shell.json` in `bar.layout.right`:

```json
{
  "id": "miguel.cyberghost"
}
```

Then refresh the shell:
```bash
omarchy restart shell
```

---

## 🔐 Security & Privileges

The plugin uses `pkexec /usr/bin/cyberghostvpn` when initiating or terminating connections, integrating seamlessly with Omarchy's native Polkit Agent (`omarchy.polkit`) for visual authentication dialogs.

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.
