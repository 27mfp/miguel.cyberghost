# Security policy

CyberGhost VPN for Omarchy handles VPN credentials and creates a
NetworkManager connection on your behalf. Please report security issues
privately.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** for this repository:
Security → Advisories → *Report a vulnerability*

Do not open a public issue for a suspected vulnerability, and do not paste real
credentials, device tokens, session JWTs or `~/.cyberghost/*.ini` contents into
an issue, chat or log attachment. Redact usernames, tokens, public IPs and
server names before sharing diagnostics.

Include, when you can:

- affected version (`manifest.json` / the release tag) and Omarchy/Qt version;
- the smallest reproduction, with mocked or redacted account data;
- which boundary is affected: QML/IPC, the Python runner, NetworkManager, or
  the installer/cleanup scripts;
- expected and observed behaviour, and whether a privileged file was involved.

Reports are acknowledged as soon as possible. This is a volunteer project with
no bug-bounty programme and no guaranteed response time.

## Supported versions

Only the latest release line receives fixes (currently 1.7.x). Pre-1.7 root
helpers are deprecated; see `INSTALLER.md` for their removal window.

## Security model and known limits

- Since 1.7.0 the tunnel is an **in-memory NetworkManager WireGuard profile**
  created as the desktop user. Nothing is installed or executed as root, and
  NetworkManager's Polkit policy authorizes the change.
- Account credentials live in `~/.cyberghost/native.ini` (mode 0600). The
  account password is used for registration and is never persisted. The
  vendor CLI's `config.ini` is only read.
- The WireGuard private key reaches NetworkManager over stdin, never argv.
- IPC is limited to the `miguel.cyberghost` bar widget and only the elected
  first widget on a monitor answers.
- **There is no kill switch and no leak-protection claim.** A NetworkManager
  restart ends the tunnel rather than silently restoring it. DNS and routing
  behaviour depend on the host's NetworkManager/resolved configuration.
- The legacy cleanup script only removes files it can positively recognize;
  customized Polkit rules and historical WireGuard configs are preserved.

## Out of scope

Vulnerabilities in CyberGhost's service or official CLI, Omarchy/Quickshell
itself, and the general behaviour of the host's DNS or firewall should be
reported to their respective projects. Missing features such as a kill switch
are product limitations, not security vulnerabilities.
