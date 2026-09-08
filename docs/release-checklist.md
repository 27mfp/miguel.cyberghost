# 1.6.2 candidate — native WireGuard release gates

Scope agreed with the owner: ship native WireGuard traffic connections with country selection and automatic servers. Hide unsupported modes, rather than presenting experimental connections as stable. Omarchy is the supported baseline, but rolling versions, resolver configuration, interfaces and monitor arrangements can differ.

## Release boundaries

- Unsupported protocol/mode/manual-server controls are absent from the panel and manifest settings.
- Saved experimental preferences normalize to WireGuard, traffic and automatic selection.
- IPC rejects unsupported requests; the runner rejects vendor-dependent connection modes before backend dispatch.
- Status and disconnect manage the native tunnel only, not a separately started vendor VPN.
- Guided installation does not offer the vendor CLI or OpenVPN compatibility launcher.
- Optional existing vendor inventory can still assist native endpoint selection; fallback candidates remain available.
- Helper capability 8 requires an explicit helper update before using this candidate.

## Evidence and remaining gates

- Earlier native WireGuard live tests passed IPv4/IPv6 tunnel routing, uncached DNS, HTTPS egress and disconnect cleanup with helper 1.6.0.
- The polished native-only UI passed real-shell synthetic-service tests: country selection, hidden vendor controls, privacy, actual clipboard copy/restoration, settings disclosure, simulated connection, account password clearing and Escape. Nine captures were produced; normal, expanded and narrow layouts were visually reviewed. This does not replace backend or full small-screen/compositor testing.
- 116 Python tests pass on Python 3.9 and 3.12; 28 substantive Qt tests pass. These cover preference migration, absent vendor controls, rejected unsupported requests and native-only disconnect behavior. Ruff, ShellCheck and manifest validation pass; QML lint reports 0 project diagnostics and 58 known host metadata warnings.
- [x] Live native WireGuard connect/disconnect with installed helper 1.6.2: IPv4/IPv6 routes selected `cyberghost` table 51820; DNS servers were 10.0.0.243/10.0.0.242 with `~.`; an uncached query used the tunnel and IPv4 HTTPS egress reported PT. Disconnect removed the interface and VPN policy rules, restored both route lookups and uncached DNS to Wi-Fi, and preserved IPv6 settings (0/0) and reverse-path filtering (2).
- [ ] Recheck final native connection without configured vendor inventory.
- [ ] Verify native activation failure/timeout recovery and residual routes/DNS.
- [ ] Verify concurrent multi-monitor requests and owner re-election/hotplug.
- [ ] Clean install, upgrade, disable/re-enable and removal in a disposable environment.
- [ ] Complete the selected Grok independent security review. Previous attempts failed due Pi runtime/dependency errors; no completed independent audit is claimed.
- [ ] Review final diff, sync the installed checkout/helper, run final gates and inspect remote CI before tagging or advertising stability.

## Deferred vendor investigation (not a release gate for native-only scope)

CLI 1.4.1 returned zero even when OpenVPN failed. The experimental helper verification caught this. A read-only sudo lookup confirmed that nested sudo bypassed the Arch compatibility wrapper. With explicit owner approval, a narrowly scoped root-owned `/usr/local/bin/openvpn` launcher was installed without modifying sudoers, packaged OpenVPN or TLS verification.

OpenVPN then exposed a missing `~/.cyberghost/openvpn/auth` file. Vendor code writes the existing device token/secret into this file; those values were restored privately with mode 0600 without overwriting any file or creating/deleting a device.

A subsequent OpenVPN UDP connection succeeded: IPv4 routed through `tun0`, HTTPS egress reported Portugal, and an uncached DNS lookup reported `tun0`. The tunnel had no per-link DNS server/domain recorded by `resolvectl`, so provider-specific DNS setup is not claimed.

Vendor disconnect removed `tun0`, restored Wi-Fi IPv4/DNS and reverse-path filtering, but left both global/default IPv6-disable settings at 1. The owner authorized restoration to their saved values of 0; Wi-Fi IPv6 routing was verified afterward. **Automatic vendor IPv6 cleanup remains unresolved.** TCP, streaming and torrent connections are not certified.

The compatibility launcher remains installed on the development machine, but native WireGuard does not require it. Retained vendor code/scripts are experimental developer material, not supported release modes. No kill switch or comprehensive leak protection is claimed.
