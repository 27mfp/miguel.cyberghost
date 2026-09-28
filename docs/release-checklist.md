# 1.7.0 — NetworkManager release gates

Published listing: [CyberGhost VPN for Omarchy](https://plugins.omarchy.org/plugin.html?id=miguel.cyberghost)

Scope: replace the root helper with an unprivileged NetworkManager WireGuard connection, matching Omarchy's own network tooling. Release boundaries from 1.6.3 (WireGuard traffic mode, automatic server) are unchanged.

## Evidence

- [x] On Omarchy 4.0.4 (NetworkManager 1.58.1), the runner's own `nm_profile_args` → `nm_activate` → `status` → `disconnect` ran live as the desktop user with no password prompt. Routes used documentation prefixes and DNS was scoped to `~test.invalid`, so no user traffic was affected. Observed: `activated`; `connection.permissions user:<name>`; the key read back from NetworkManager matched and never appeared in argv; no file in `system-connections`; IPv4 and IPv6 routes on `cyberghost`; counters and endpoint reported; after disconnect, profile and interface verified absent.
- [x] With `omarchy dns` global mode active, per-connection DNS is overridden by NetworkManager global DNS. `resolvectl` showed no link with a DNS default route, so only public global resolvers are used, and those are reached through the tunnel.
- [x] X25519 matches the RFC 7748 vectors. Python suite 120 passed; Qt 44 UI and 11 utility cases passed. Mutation checks (key on argv or missing, no rollback, non-exclusive DNS, `ipv6.method disabled`, legacy tunnel ignored, persisted profile) each fail the suite.
- [x] `scripts/remove-legacy-helper.sh` recognizer tested against all five historical `50-cyberghost.rules` versions (all removed) and a customized rule (left alone).
- [x] Installed from the working tree into the running 4.0.4 shell: the plugin loads with no warnings, and the setup panel renders with host styling.
- [x] Server coverage without the vendor CLI: all 94 countries were probed by DNS, then one node per country by TLS on port 1337 with certificate verification (no credentials). The old fixed fallback reached 60 countries. With the rack pool and city fixes, 93 are reachable (92 TLS-verified in the scan, plus France via its other racks). Bosnia had no reachable guessed server. `probe --all` reproduces the scan.
- [x] Real server names superseded the guesses. `servers.json` was generated from CyberGhost's API (`/my/servers/filters/74`, WireGuard) on 2026-09-28: 7,475 servers in 94 countries, fetched with no 429s at a 5 s pace. On a fresh machine (no session, no CLI), each country was selected in its own process: 93/94 have a reachable real server, median 0.17 s and at most 1.23 s. Kenya is refused up front because CyberGhost lists no WireGuard servers there. Corrections the list revealed: Bosnia → Travnik (so Bosnia works after all), China → Shenzhen (previously guessed `hongkong`, i.e. Hong Kong), and many more racks than guessed (Romania s492, Germany s451–s472).
- [x] Real CyberGhost connect with a linked account (Spain, 2026-09-28, `omarchy dns` Google global mode). IPv4 and IPv6 route lookups selected `cyberghost` through policy table 51838 (`not fwmark 0xca7e`, `suppress_prefixlength 0`). HTTPS egress reported Barcelona, Spain (M247). IPv6 egress timed out inside the tunnel, so the ISP's IPv6 address was not exposed. Uncached DNS went to 8.8.8.8 over DoT through the tunnel, and no link held a DNS default route. The tunnel survived a shell restart and the panel reconciled from status.
- [x] Owner-tested country switching, disconnect, the formerly failing countries (Bosnia, China, Italy, Romania, Kenya), and logout. After disconnect: no `cyberghost` interface or NetworkManager profile, no tunnel policy rules for either family, routes and HTTPS egress back on Ethernet (Portugal/MEO), and no CyberGhost resolver link.
- [ ] DNS path in `omarchy dns DHCP` mode (VPN link `~.`), not exercised: this machine uses global Google DNS.
- [ ] Upgrade path on a machine with a live 1.6.x tunnel: legacy disconnect through the installed helper, then legacy cleanup.
- [ ] CI on the final commit.

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
- [x] Python regression suite: 126 tests pass locally, including subprocess exit deadlines and IPv6/selected-table cleanup checks.
- [x] Qt/QML behavior suite: 36 UI cases and 11 utility cases pass locally, including pending lookup cancellation, readiness changes, and late external-VPN detection.
- [x] Python compilation, JSON/standalone manifest validation, shell syntax, ShellCheck, QML formatting, Omarchy manifest validation, `git diff --check`, and QML lint pass locally. QML lint reports 0 project diagnostics; only known host metadata warnings remain.
- [ ] Rerun Ruff and CI on the updated commit before publishing.
- [x] No repository files are changed by the validation commands themselves; the final diff is limited to the remediation and regression/docs changes described above.
- [ ] Recheck final native connection without configured vendor inventory in a disposable authorized environment.
- [ ] Verify real activation failure/timeout recovery and residual routes/DNS in that environment.
- [ ] Verify concurrent multi-monitor requests, owner re-election and monitor hotplug in the running shell.
- [ ] Complete disposable clean-install, upgrade, disable/re-enable and removal evidence.
- [x] Review remote CI before tagging or advertising stability. GitHub Actions run `35439589048` passed on release-preparation commit `7cd3176`; the installed checkout/helper update remains an explicit post-update step.

## Deferred vendor investigation (not a release gate for native-only scope)

CLI 1.4.1 returned zero even when OpenVPN failed. The experimental helper verification caught this. A read-only sudo lookup confirmed that nested sudo bypassed the Arch compatibility wrapper. With explicit owner approval, a narrowly scoped root-owned `/usr/local/bin/openvpn` launcher was installed without modifying sudoers, packaged OpenVPN or TLS verification.

OpenVPN then exposed a missing `~/.cyberghost/openvpn/auth` file. Vendor code writes the existing device token/secret into this file; those values were restored privately with mode 0600 without overwriting any file or creating/deleting a device.

A subsequent OpenVPN UDP connection succeeded: IPv4 routed through `tun0`, HTTPS egress reported Portugal, and an uncached DNS lookup reported `tun0`. The tunnel had no per-link DNS server/domain recorded by `resolvectl`, so provider-specific DNS setup is not claimed.

Vendor disconnect removed `tun0`, restored Wi-Fi IPv4/DNS and reverse-path filtering, but left both global/default IPv6-disable settings at 1. The owner authorized restoration to their saved values of 0; Wi-Fi IPv6 routing was verified afterward. **Automatic vendor IPv6 cleanup remains unresolved.** TCP, streaming and torrent connections are not certified.

The compatibility launcher remains installed on the development machine, but native WireGuard does not require it. Retained vendor code/scripts are experimental developer material, not supported release modes. No kill switch or comprehensive leak protection is claimed.
