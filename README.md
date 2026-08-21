# CyberGhost VPN for Omarchy Shell

A native, lightweight, and responsive Quickshell status bar widget and panel for managing **CyberGhost VPN** on Omarchy / Arch Linux.

---

## ✨ Features

- 👻 **Status Bar Widget:**
  - Official CyberGhost vector icon in brand yellow (`#FFCE00`) when connected.
  - Active indicator dot and pulsing animation during connection handshakes.
  - Informative tooltips displaying active server, country, protocol, and external IP.
- ⚡ **One-Click Controls:**
  - Header toggle switch for instant connect/disconnect.
  - Middle-click shortcut directly on the bar icon.
- 📋 **Live IP & Network Diagnostics:**
  - Real-time external IP detection, GeoIP resolution (City, Country), and ISP organization.
  - **Click-to-Copy:** Click the IP address anytime to instantly copy it to your clipboard.
- 🔔 **Desktop Notifications:**
  - Native desktop notifications on connection success, disconnection, and error alerts.
- 🌍 **100+ Countries & Fast Switching:**
  - Quick-connect grid for popular locations (🇵🇹 Portugal, 🇪🇸 Spain, 🇬🇧 UK, 🇺🇸 USA, 🇩🇪 Germany, 🇫🇷 France, 🇳🇱 Netherlands, 🇨🇭 Switzerland, 🇮🇹 Italy, 🇧🇷 Brazil, 🇨🇦 Canada, 🇸🇪 Sweden).
  - Searchable dropdown with real-time filtering covering all 100+ CyberGhost server countries.
- 🛡️ **Server Modes:**
  - **⚡ Traffic:** Fastest standard routing for daily browsing.
  - **🔒 Torrent (P2P):** Specialized torrenting servers.
  - **🎬 Streaming:** Streaming-optimized server locations.
- 🔒 **Multi-Protocol Support:**
  - WireGuard (fastest, native key negotiation).
  - OpenVPN UDP.
  - OpenVPN TCP.

---

## 📦 Requirements

1. **WireGuard Tools** installed on Arch Linux / Omarchy:
   ```bash
   sudo pacman -S wireguard-tools
   ```
2. Configure your CyberGhost account (one-time setup to generate device token):
   ```bash
   yay -S cyberghostvpn
   sudo cyberghostvpn --setup
   ```

---

## 🚀 Installation

Install directly with the Omarchy plugin CLI:

```bash
omarchy plugin add https://github.com/27mfp/miguel.cyberghost.git --enable
```

Or clone manually to your user plugins directory:

```bash
mkdir -p ~/.config/omarchy/plugins/
git clone https://github.com/27mfp/miguel.cyberghost.git ~/.config/omarchy/plugins/miguel.cyberghost
```

And ensure it is included in your `~/.config/omarchy/shell.json` in `bar.layout.right`:

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

## 🔐 Passwordless Connection via Polkit (Optional)

To connect without entering your root password every time, copy the included Polkit rule to `/etc/polkit-1/rules.d/`:

```bash
sudo cp 50-cyberghost.rules /etc/polkit-1/rules.d/
```

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.
