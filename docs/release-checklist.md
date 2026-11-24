# 1.7.2 — Omarchy 4.5 compatibility and dashboard redesign (unreleased)

Local verification: 2026-11-06, Omarchy 4.5.0-3 / Qt 6.12.0.

- [x] Manifest and runner agree at 1.7.2; changelog updated.
- [x] Python: 233 passed on the system interpreter.
- [x] Unpatched Qt: 76 UI and 13 utility entries passed, with no undefined-color warnings.
- [x] Native QML lint: zero project diagnostics; 53 existing, exact host metadata exceptions. No exception was broadened.
- [x] Ruff 0.16.9 lint/format, manifest validation, Omarchy validator, ShellCheck and whitespace checks passed.
- [x] Architecture/quality pass: backend package split, JS extractions, unified installer, mypy/shfmt/coverage gates, release workflow and governance files.
- [x] Integrated verification (2026-11-24, backend split + PR4 UI): 252 Python, 121 UI and 20 utility Qt tests passed; 0 project QML diagnostics and 93 exact host metadata warnings; Ruff, mypy, ShellCheck, shfmt, manifest, preview-sync and `git diff --check` passed.
- [x] Hosted Python 3.9/3.12/3.14 CI on PR head `4b686ef` (before the local popup-anchor follow-up).
- [x] Real Omarchy 4.5 shell preview: detected the popup at `(5,5)` because `as Panel` left its `bar` unset; `as Ui.Panel` restores late host injection, opening the card at `(1535,31)` beside the right-hand icon on a 1920x1080 top bar.
- [x] Rechecked the local follow-up with 233 Python, 76 UI and 13 utility Qt cases, native QML lint (0 project diagnostics, 52 known host metadata warnings), Ruff and manifest validation.
- [x] Elsewhen-inspired local UI preview: 233 Python, 85 UI and 13 Qt utility tests passed; native QML lint 0 project diagnostics and 62 explicit host metadata warnings; Ruff and manifest validation passed. New disclosure, clipboard/privacy, stale/unknown status, and pt-PT display cases covered by tests.
- [x] Installed preview on the live Omarchy 4.5 shell: visible under the right-hand bar icon, compact connection summary, separate destination, details/account/settings initially collapsed, and no CyberGhost QML runtime errors in the inspected log.
- [x] Second local UI redesign preview: `VpnDashboard` with a new central `ConnectionStage`, single explicit connect/disconnect button, a compact IP row, and one-at-a-time details/account/settings menu; state, country and focus contracts retained. Qt tests: 93 UI + 13 utility passed; Python: 233 passed; QML lint: 0 project diagnostics (79 exact host metadata exceptions); Ruff, manifest and Omarchy validator pass.
- [x] Runtime visual review confirmed the new panel below the right-hand bar icon and no CyberGhost runtime QML errors. Short-lived connection-state transitions are represented with neutral progress labels and an inactive action button.
- [x] ShellCheck and shfmt pass on the integration host; CI enforces both for every shell script.
- [x] Adaptive UX revision: synthetic tests cover the explicit country switch, disconnect as a secondary action, uncertain-status recovery, compact widths 320/375/400, subpage Back, strict favorite/recent codes, and step-by-step onboarding. Local checks: 233 Python, 114 UI, 13 Qt utility tests, 0 project QML diagnostics, Ruff and manifest validation passed.
- [x] Installed adaptive UX preview in Omarchy 4.5 and visually reviewed the disconnected screen on one 1920×1080 output; panel opens beneath the CyberGhost icon, fits within the output and displays Quick destinations and the new details navigation. No CyberGhost QML exceptions in the checked Quickshell log.
- [x] Reviewed and installed simplified navigation: direct Account and Settings icons in the header replace the overflow menu, with active-view indication, Back on subpages and Details on the main view. Post-adjustment checks: 114 UI, 13 Qt utility and 233 Python tests passed; manifest, Omarchy validator, Ruff and formatting checks passed; 0 project QML diagnostics (88 known host metadata warnings). On the live 1920x1080 Omarchy 4.5 shell the popup remained anchored below the bar icon, both header icons were visible, and no clipping or overlap appeared in the disconnected main view. Escape closed the panel, shell ping returned `ok`, and the checked Quickshell log showed no CyberGhost runtime errors. Real pointer-driven subpage traversal is covered by synthetic tests but was not automated on this desktop.
- [ ] Visually verify adaptive switch on a live active tunnel and multiple-monitor placements in an isolated setup; no live VPN connection was initiated by this revision.
- [ ] Verify actual VPN connected and stale states, longer translated text, bar orientation, multi-monitor behavior, and focus traversal on an isolated test setup before calling the UI migration fully complete.
- [ ] Hosted CI after the popup-anchor follow-up is published.
- [ ] Review and merge the compatibility PR before publishing a tag/release.
- [ ] Tag `v1.7.2` and confirm `.github/workflows/release.yml` publishes the zip and `SHA256SUMS` (tag, manifest and changelog are checked automatically).

The per-widget service still exists, while the visual `KeyboardPanel.content` now loads on first open. Shared services, native multi-monitor/lifecycle coverage and live VPN integration belong to the [follow-up plan](omarchy-4.5-plan.md). The popup-anchor and visual changes were previewed in the installed shell, without account linking, tunnel activation or disconnection.

Earlier sections below record historical releases and host versions, including the obsolete root-helper architecture. Their completed checks do not certify this release on Omarchy 4.5.

# 1.7.1 patch release

Date: 2026-10-10
POC: Miguel
TL;DR: Offline fixes and UI refinements; no live network certification is added.

- [x] Manifest and runner versions agree at 1.7.1; changelog updated.
- [x] Final Python 3.9/3.12/3.14: 233 passed on each; Qt: 76 UI and 13 utility cases passed. Ruff, ShellCheck, native QML lint (0 project diagnostics), manifest and whitespace validation passed.
- [x] Fifteen synthetic real-shell captures; recovery button invocation, busy controls, country switching, sampling notice and short-height keyboard focus visibility checked. Clipboard restored; fixture removed; no VPN action performed.
- [x] Refreshed README and marketplace preview images with labeled synthetic data.
- [x] PR CI on the release branch (lint-test on Python 3.9, 3.12 and 3.14).
- [ ] Live routing/DHCP DNS, connection recovery and legacy migration, deferred to a safe environment.

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
- [x] Real server names superseded the guesses. The per-user background sync ran live against the owner's account: all 94 countries and 7,485 servers were cached with no HTTP 429 at a 5 s pace, and exactly one sync process ran under the lock. With no session and no CLI, every country selects a reachable real server (Kenya: 10 in 0.31 s). Kenya was first misread as having no WireGuard servers, because the API names them `Nairobi-401-i01` without the rack `s`. DNS and TLS confirmed `nairobi-s401-i01.cg-dialup.net` (same IP, `nairobi-rack401` certificate), and names are now normalized. Corrections the list revealed: Bosnia → Travnik, China → Shenzhen (previously guessed `hongkong`, i.e. Hong Kong), and many more racks than guessed (Romania s492, Germany s451–s472).
- [x] Real CyberGhost connect with a linked account (Spain, 2026-09-28, `omarchy dns` Google global mode). IPv4 and IPv6 route lookups selected `cyberghost` through policy table 51838 (`not fwmark 0xca7e`, `suppress_prefixlength 0`). HTTPS egress reported Barcelona, Spain (M247). IPv6 egress timed out inside the tunnel, so the ISP's IPv6 address was not exposed. Uncached DNS went to 8.8.8.8 over DoT through the tunnel, and no link held a DNS default route. The tunnel survived a shell restart and the panel reconciled from status.
- [x] Owner-tested country switching, disconnect, the formerly failing countries (Bosnia, China, Italy, Romania; Kenya was tested before its fix), and logout. After disconnect: no `cyberghost` interface or NetworkManager profile, no tunnel policy rules for either family, routes and HTTPS egress back on Ethernet (Portugal/MEO), and no CyberGhost resolver link.
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
