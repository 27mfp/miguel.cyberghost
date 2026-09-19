# Changelog

## 1.6.3

- Resolve automatic WireGuard endpoints from CyberGhost's live, unprivileged server inventory before entering the privileged helper, avoiding stale per-country rack and city names.
- Correct Ukraine's displayed `Kyiv` / endpoint `kiev` naming mismatch in the static fallback inventory.
- Treat an absent iproute2 policy table as verified-clean state so stale WireGuard configuration can be replaced safely.
- Add regression coverage for live endpoint handoff, Ukraine fallback names, and absent policy-route cleanup.

## 1.6.2

- Restrict release connections to native WireGuard traffic mode. Remove vendor-dependent controls from the panel and manifest, and migrate saved experimental selections to automatic WireGuard.
- Reject unsupported IPC/helper connection requests. Native status/disconnect no longer manage separately started vendor VPNs.
- Remove vendor CLI installation prompts. Target Omarchy while retaining prerequisite checks for differing versions and resolver/network setups.
- Require helper capability 8. Experimental vendor compatibility work below is retained for development, not advertised as a supported release feature.
- Fail closed on explicit empty/invalid API DNS, validate root-owned WireGuard directories/configs before lifecycle commands, and atomically write mode-0600 config files.
- Serialize native connect/disconnect with a persistent root lifecycle lock; verify interface, policy-route/rule and resolver cleanup and retain recovery config when cleanup is inconclusive.
- Keep trusted helper presence separate from exact-version readiness so existing tunnels remain disconnectable during helper updates; skip vendor CLI execution from the privileged helper.
- Reject stale QML status/action completions, distinguish unknown probe state from disconnected, cancel/timeout actions conservatively, and clean panels on every close path.
- Preserve Polkit rules during helper-only updates; scope optional passwordless authorization to the installing wheel user, add digest-checked explicit revocation, fail-closed installer confirmations, and staged `fresh-install.sh` replacement.
- Add a repository icon and refresh the native WireGuard marketplace preview and documentation screenshots.

### Earlier experimental 1.6.1 work

- Use the vendor's supported `--connection udp|tcp` option for OpenVPN.
- Reject CLI exit-zero results unless a subsequent vendor status probe observes an active connection. Attempt bounded cleanup on failures/timeouts and report cleanup failures.
- Do not report successful CLI disconnection when stop fails or its result cannot be verified. That experimental candidate used helper capability 7; the native-only candidate supersedes it.

- Add an optional terminal wrapper for vendor setup: Enter now means Yes at its two misleading `[Y/n]` confirmations, while explicit No and password input remain unchanged. Add confirmation-filter and real-PTY regression tests; correct CLI setup documentation.

- Keep Connect directly below Country when Advanced expands. Use compact native dropdowns for mode/protocol and shrink filtered search popups to their results.
- Simplify public connection details, wrap long providers, and report clipboard success only after the copy process succeeds.
- Close dropdowns when hiding the panel. Use themed setup fields and discard unsubmitted passwords on close.
- Reject GeoIP responses from earlier tunnel states and explicitly select IPv4 transport for the IPv4 lookup.
- Elect one IPC handler across monitor widgets instead of registering the same target on every output.
- Add real-shell synthetic-data visual smoke captures and keyboard/clipboard assertions; retain explicit limits on what mocked Qt tests establish. Verify native connect, VPN DNS and route selection, then disconnect cleanup with user authorization.

## 1.6.0

- Split the bar entry point, popup, setup UI, connection preferences/details, setup processes and inventory into focused components following the installed Omarchy clock lifecycle contract.
- Simplify daily use to country → Connect; place server/mode/protocol and optional passwordless authorization under Advanced settings. Remove duplicate quick-connect tiles, the second power button and recurring optional-setup reminders.
- Preserve exact-server selection when connecting, restore late-arriving shell settings without writing defaults, and persist user changes through the host's inline settings API.
- Separate native credentials from vendor CLI state, distinguish installed/configured CLI readiness, and identify incompatible helpers as updates. Keep private legacy credentials readable without rewriting them.
- Require VPN DNS setup; remove the unsafe DNS-less retry. Attempt rollback on activation errors, timeouts and bounded-output failures. Detect a missing resolvconf provider during onboarding.
- Keep background status/inventory work from blocking Disconnect. Reject stale inventory callbacks; preserve in-flight streaming output and selected service profiles on refresh.
- Use observed tunnel/backend state instead of labeling the connection with next-connect preferences. Mask geolocation mismatch details in privacy mode and remove blanket protection claims.
- Make passwordless installation explicit in GUI and terminal flows. Preserve vendor credentials during removal/developer reset.
- Replace brittle layout text checks with Qt behavior tests; organize backend tests by domain. Add real installed-import lint tooling with explicit host metadata limits, CI component tests and updated architecture/testing/install documentation.

**Upgrade:** run the bundled `install-helper.sh` explicitly after updating the plugin. No kill switch is provided; live VPN routing still needs integration validation.

## 1.5.4

- Native registration now uses private `~/.cyberghost/native.ini`, with read-only legacy credential compatibility, instead of overwriting vendor CLI configuration. Helper capability updated; reinstall the helper.
- Optional CLI modes check account configuration separately from executable availability. Server inventory errors retain the useful cause and filter duplicate/invalid entries.
- Passwordless Polkit installation is explicitly opt-in (`--with-polkit-rule`); the panel's Enable action passes that option. Helper-only updates preserve existing rules.
- Development docs use real plugin directories and hot reload; removal preserves vendor credentials. Security documentation distinguishes routing and handshake monitoring from leak protection.

- **Tidied the FIRST-RUN SETUP card.** Field labels sit above inputs with clear vertical hierarchy (`Style.space(8)` between fields vs `Style.space(4)` label margins). Status dots are vertically centered with text cap-height (`anchors.verticalCenterOffset: -Style.space(1)`) so they no longer sag below the text baseline. Buttons have comfortable vertical padding (`Style.space(4)`) and balanced horizontal padding, "Link account" dims gracefully when empty/disabled, and a subtle divider separates the Account and Helper steps when both are active. Both primary actions cleanly align to the right edge.

## 1.5.3

- **Fixed the FIRST-RUN SETUP / PLUGIN UPDATE card height.** Vertically anchoring the inner Column while the Rectangle's `implicitHeight` depended on that Column created a Qt Quick binding loop (~90 px of empty space). `anchors.fill` on the Column was worse: it collapses the card to 0 height. The card now sizes from content with `x`/`y`/`width` padding, matching the official Omarchy panel pattern. The IP card uses the same layout so Copy IP no longer sits above an empty bar.
- **Restored the Refresh control as a real Button** with an explicit 28 px width. The previous `Text` + `MouseArea` box fixed the gap next to Connect but dropped Tab focus, the focus ring, and the tooltip. Pinning `width`/`implicitWidth` keeps the icon box tight without abandoning Button.
- **Helper install row no longer nags when the helper is already installed.** First-run for a missing account or package no longer shows "Required: install the root helper".
- **Persistence failures show in the status banner** (`lastError`) instead of `setupMsg`, which is hidden once setup is done.
- **Keyboard focus lands on a visible control.** Polkit-optional focuses Enable; a finished setup focuses Connect; first-run still focuses the account field or Install helper.
- **Hardened `install-helper.sh` staging.** `mkdir -p` would reuse a pre-created `/tmp/cyberghost-install-root-$$` directory. The installer now refuses an existing path and creates the directory without `-p`.
- **`polkitRuleDismissed` is a real plugin setting** so dismissing the optional Polkit prompt survives a restart and can be undone from Omarchy plugin settings.
- **First-run panel no longer stays as tall as the hidden connected UI.** Hero, IP card, and connection controls reported their full `implicitHeight` while `visible` was false, so the wizard sat above a large empty region. Hidden sections now report 0 height. A one-line "account · linked" row remains when the helper is the only missing step.

## 1.5.2

- **Fixed the Refresh button's bounding box** — the actions row's Refresh icon button used to be a `Button { iconText: "..." }`, but the Button component's implicit width is much wider than the visible icon glyph (it includes default content padding even when `text: ""`). Anchoring the Connect button to the Refresh button's right edge then produced a ~130 px unexplained gap. Replaced the Refresh `Button` with a plain `Text` + `MouseArea` inside a fixed-size `Item` (24×28 px), so the anchor lands on the actual visible icon edge. Also added a `PanelToolTip` and `Accessible.name` to preserve the original affordances.

## 1.5.1

- **Fixed the unexplained gap in the actions row** — the bottom action row (Refresh icon + Connect button) was rendering with a large empty space between the Refresh icon and the Connect button. The Connect button was only about 60% of the row width instead of filling the remaining space. Root cause: the Connect button's `width: parent.width - refreshStatusButton.width - 8` arithmetic was producing an unexpectedly small value, likely because the Refresh button's implicit width was being measured larger than the visible icon (the Button component's padding or default sizing). Replaced the Row + width-arithmetic with an `Item` + explicit `anchors.left: refreshStatusButton.right; anchors.right: parent.right` so the Connect button stretches predictably from the right edge of Refresh to the right edge of the panel.

## 1.5.0

- **Fixed button order in the FIRST-RUN SETUP / PLUGIN UPDATE card** — the primary action ("Install helper" / "Update helper") is now on the **right** edge of the action row, and the secondary "Recheck" button is on the **left**. Previously the order was reversed. Right-aligning the primary action matches the convention used by the bottom Connect button and by every other primary action in the Omarchy shell.
- **Renamed "Open installer" → "Install helper"** for the FIRST-RUN state. The button's actual effect is to open a terminal that runs the installer; "Install helper" matches the user's intent more directly. The update-available state keeps "Update helper".
- **Added small "Mode" and "Protocol" labels** to the CONNECTION PREFERENCES section. The two 3-up button rows (Mode: Traffic/Torrent/Streaming, Protocol: WireGuard/OpenVPN UDP/TCP) were visually almost identical, so the user had to read every label to figure out which was which. Now each row is preceded by a dim, bold caption that names it. No other behaviour change.

## 1.4.9

- **Added bottom breathing room to the panel** — the Connect button was kissing the bottom edge of the panel with no padding. Added a `Style.space(16)` transparent spacer at the end of the main column so the last interactive element is followed by ~16 px of quiet space before the panel border.

## 1.4.8

- **GeoIP lookup now requests IPv4 explicitly** (`https://ipwho.is/?type=ipv4`). Without the query param, the API returns whichever address it picks first — which is IPv6 on most hosts today. The widget now shows the IPv4 (the address a typical service uses for geolocation / blocking), which is what users actually want to verify against the VPN. If the host is IPv6-only, the request fails and the panel renders the existing "Unavailable" fallback.
- **Fixed the IP card layout** — the section used absolute `y:` positioning for the Copy IP row, and the geo-mismatch note had no positioning at all (it overlapped the detail grid at y=0 when visible). Replaced with a proper `Column` with consistent `Style.space(8)` spacing. The Copy IP button now sits naturally under the Provider row, and the geo-mismatch note renders in the right place when the user is connected and the exit IP geolocates to a different country.
- **Added a regression test** asserting that the QML uses `?type=ipv4` and not the plain `https://ipwho.is/` URL, so this preference is locked in.

## 1.4.7

- **Mode buttons (Traffic / Torrent / Streaming) now show a ✓ + brand yellow when active** — same visual treatment as the country grid, so the active state is unmissable at a glance. Previously the `selected` prop only changed the background subtly.
- **Protocol buttons (WireGuard / OpenVPN UDP / OpenVPN TCP) match** — same `✓` + brand-yellow active treatment.
- **Removed redundant internal labels** from the Country and Server `SearchableDropdown` widgets. The "COUNTRY" and "SERVER SELECTION" section headers above each row already provide the label, and the dropdown's own `placeholderText` carries the helper text. Result: a slightly tighter, less shouty layout.
- **Switched the dropped label's `Accessible.name`** to the section name ("Country" / "Server") so screen readers still announce the field correctly even without a visible label.

## 1.4.6

- **Fixed the FIRST-RUN SETUP card layout** — the helper section used to put the message and the buttons side-by-side. With two bordered buttons on the right, the message was squeezed into a narrow column and wrapped into 6 ugly lines ("Required: install / the root helper (a / small, fixed Python / program that this / widget never / edits)."). Now the message gets the full width on top, and the action row sits right-aligned underneath, with no awkward word breaks.
- **Shortened the helper-install copy** — the headline is now "Required: install the root helper to enable connect and disconnect." The technical detail ("A small, fixed Python program at /usr/local/bin/cyberghost-runner that this widget never edits") is preserved in the hover tooltip and the `Accessible.description`, so curious / a11y users still get the context.
- **Tightened the helper action row** — the buttons are now caption-sized with reduced padding so they read as a secondary action row, not competing with the message. "Recheck" sits to the left of "Open installer" / "Update helper" in a right-to-left Row layout.

## 1.4.5

- **Custom `PowerButton` in the hero card** — replaced the generic `ToggleSwitch` with a circular power button using the ⏻ glyph. Active = brand yellow on a translucent yellow disc; inactive = dim glyph on a subtle outline. Smooth color/opacity transitions on toggle.
- **Slim inline notice for the optional Polkit rule** — the polkit-optional state no longer renders as a full bordered card. A single-line dismissable notice sits at the top of the panel with a key icon, copy ("Skip the password prompt on every connect (optional)."), an **Enable** button, and a × dismiss button.
- **IP card status row cleaned up** — the cramped 3-column grid (badge + protocol pill + hide button) is now a single row: dot + badge + protocol subtitle on the left, an icon-only hide/show button on the right. The protocol is a quiet subtitle, no longer a competing rectangle.
- **Country grid selected state is now obvious** — the active country tile shows a leading ✓ check mark and renders in brand yellow. Inactive tiles stay in `barForeground`.
- **Connect is the primary action** — the bottom actions row is now a single full-width Connect/Disconnect button (yellow when off, urgent red when on, with live Connecting…/Disconnecting… labels) with a small ghost icon-only Refresh button tucked to its right. No more "Refresh Status" eating half the row.
- **Cleaned dead code in the helper section** — the polkit / readyPolkit branches in `helperLabel` and the `skipBtn` are removed (the compact notice owns that case now). Simplified the `openInstallerBtn` visibility and the inner `Item.show` property.
- **Bug fix in `install-helper.sh`** — the original `$(sudo mktemp -d …)` captured sudo's fingerprint-reader auth prompt into the variable, corrupting the staging directory path. Replaced with a PID-based predictable path (`/tmp/cyberghost-install-root-$$`) created by an explicit `sudo mkdir`, which lets the auth prompt go to `/dev/tty` cleanly.

## 1.4.4

- **Setup card is now a four-state machine** (`first-run` / `update-available` / `polkit-optional` / `ready`). A version-bump no longer renders as "FIRST-RUN SETUP" in urgent red. Card title, color, and visible rows all derive from `cyberghost.setupCardState`.
- **Hero card no longer hidden by the optional Polkit rule.** Once the four required checks pass (WireGuard, Python requests, account, helper), the connect toggle, IP, and country picker appear immediately. The Polkit prompt lives in the setup card or — when dismissed — in a single clickable line in the status banner.
- **Setup card hides passing dependency rows.** "WireGuard tools" and "Python requests" only appear while one is actually missing. Once both are green, the card collapses that section.
- **Helper version numbers removed from the headline.** The drift case now reads "Root helper needs an update to match this plugin version." Version numbers live in the button's `tooltipText` and `Accessible.description` for curious / a11y users.
- **Co-located action buttons.** "Update helper / Open installer" and "Recheck" now sit next to each other so the natural fix → verify flow is one glance.
- **Auto-recheck after the installer terminal closes.** No more remembering to come back and click Recheck.
- **"Remind me later" for the optional Polkit rule.** Stored as a user setting (`polkitRuleDismissed`); a single click in the status banner re-enables the prompt.
- **Helper "Never installed" and "Update needed" are visually distinct.** Never-installed uses urgent red (the hero is blocked); update-needed uses accent (hero still works, only the helper is stale).
- **Left-click always opens the panel** (including before setup, so the wizard is reachable). Middle- and right-click silently toggle the VPN without showing the panel — matches the documented tray behaviour.
- **Added `barWidget.description`** so the plugin settings UI shows a one-line summary next to the display name.
- **Surfaced persistence failures**: if a setting cannot be written (read-only disk, full quota, etc.) the panel now shows a one-line message instead of silently forgetting the choice on restart.
- **Added `INSTALLER.md`** distinguishing `install.sh` (first-time setup), `install-helper.sh` (helper-only re-install after plugin updates), and `fresh-install.sh` (dev-only full reset).
- **Promoted `docs/screenshots/screenshot-connected.png` to `preview.png`** at the plugin root for the marketplace thumbnail.

## 1.4.3

- Hardened helper installation with pre-authentication snapshots and root-side SHA-256 verification to prevent checkout replacement races.
- Hardened the native connection lifecycle with bounded input, output, and total operation time.
- Added structured JSON results for helper connect/disconnect actions.
- Fixed persisted manual server selections being reset during startup.
- Improved streaming-service and server-inventory error reporting.
- Added root-helper version drift detection; rerun `install-helper.sh` after plugin updates.
- Added strict TLS endpoint pinning, safer privileged CLI environment handling, and rollback-aware disconnect cleanup.
- Added Python, shell, and QML validation to CI.

## 1.4.2

- Release notes for 1.4.2 were not captured at release time. See the git
  history between v1.3.0 and 1.4.3 for the changes shipped in this version.
