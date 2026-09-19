# 1.6.3 — native WireGuard release gates

Published listing: [CyberGhost VPN for Omarchy](https://plugins.omarchy.org/plugin.html?id=miguel.cyberghost)

Scope agreed with the owner: ship native WireGuard traffic connections with country selection and automatic servers. Hide unsupported modes, rather than presenting experimental connections as stable. Omarchy is the supported baseline, but rolling versions, resolver configuration, interfaces and monitor arrangements can differ.

## Release boundaries

- Unsupported protocol/mode/manual-server controls are absent from the panel and manifest settings.
- Saved experimental preferences normalize to WireGuard, traffic and automatic selection.
- IPC rejects unsupported requests; the runner rejects vendor-dependent connection modes before backend dispatch.
- Status and disconnect manage the native tunnel only, not a separately started vendor VPN.
- Guided installation does not offer the vendor CLI or OpenVPN compatibility launcher.
- A configured vendor CLI supplies live endpoint inventory through an unprivileged lookup; validated fallback candidates remain available when inventory is unavailable.
- Helper capability 8 requires an explicit helper update after installing this release.

## Evidence and remaining gates

- Three focused read-only audits covered backend security/lifecycle, QML runtime behavior, and installer/release safety. Their P0/P1 findings were implemented in the working tree and regression coverage was updated.
- The native-only UI remains limited to WireGuard traffic with automatic server selection. Vendor inventory and OpenVPN/streaming/torrent controls are not exposed; a separately active vendor VPN is reported and cannot be silently managed by this plugin.
- The backend now rejects explicit empty/invalid DNS, validates trusted WireGuard paths before `wg-quick`, uses a persistent root lifecycle lock, verifies interface/routes/rules/resolver cleanup, preserves recovery config on incomplete teardown, and skips optional vendor CLI execution in the root helper.
- Helper-only updates preserve Polkit authorization. Explicit revocation verifies the plugin rule bytes; confirmation EOF fails closed; fresh reset stages and validates its replacement before teardown and preserves vendor `config.ini`.
- [x] Python regression suite: 123 tests pass locally.
- [x] Qt/QML behavior suite: 33 cases pass locally; live inventory handoff, stale status/action, malformed probes, timeout, recovery and cleanup paths have regression coverage.
- [x] Ruff, formatting, Python compilation, JSON/standalone manifest validation, shell syntax, QML formatting, Omarchy manifest validation and `git diff --check` pass locally. QML lint reports 0 project diagnostics; only known host metadata warnings remain. ShellCheck passes in CI and via the disposable Docker check used here.
- [x] No repository files are changed by the validation commands themselves; the final diff is limited to the remediation and regression/docs changes described above.
- [ ] Recheck final native connection without configured vendor inventory in a disposable authorized environment.
- [ ] Verify real activation failure/timeout recovery and residual routes/DNS in that environment.
- [ ] Verify concurrent multi-monitor requests, owner re-election and monitor hotplug in the running shell.
- [ ] Complete disposable clean-install, upgrade, disable/re-enable and removal evidence.
- [x] Review remote CI and synchronize any installed checkout/helper before tagging or advertising stability. GitHub Actions run `34488189656` passed on commit `238b4e8`; the installed checkout and helper were verified against the published remediation.

## Deferred vendor investigation (not a release gate for native-only scope)

CLI 1.4.1 returned zero even when OpenVPN failed. The experimental helper verification caught this. A read-only sudo lookup confirmed that nested sudo bypassed the Arch compatibility wrapper. With explicit owner approval, a narrowly scoped root-owned `/usr/local/bin/openvpn` launcher was installed without modifying sudoers, packaged OpenVPN or TLS verification.

OpenVPN then exposed a missing `~/.cyberghost/openvpn/auth` file. Vendor code writes the existing device token/secret into this file; those values were restored privately with mode 0600 without overwriting any file or creating/deleting a device.

A subsequent OpenVPN UDP connection succeeded: IPv4 routed through `tun0`, HTTPS egress reported Portugal, and an uncached DNS lookup reported `tun0`. The tunnel had no per-link DNS server/domain recorded by `resolvectl`, so provider-specific DNS setup is not claimed.

Vendor disconnect removed `tun0`, restored Wi-Fi IPv4/DNS and reverse-path filtering, but left both global/default IPv6-disable settings at 1. The owner authorized restoration to their saved values of 0; Wi-Fi IPv6 routing was verified afterward. **Automatic vendor IPv6 cleanup remains unresolved.** TCP, streaming and torrent connections are not certified.

The compatibility launcher remains installed on the development machine, but native WireGuard does not require it. Retained vendor code/scripts are experimental developer material, not supported release modes. No kill switch or comprehensive leak protection is claimed.
