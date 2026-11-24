# Architecture and flow review

## References reviewed

- Installed Omarchy 4.0.2: `$OMARCHY_PATH/shell/README.md`, `plugins/README.md`, and `plugins/panels/clock/{BarWidget,Panel}.qml`. These are the runtime source of truth on the development machine.
- [Agent Usage's Panel.qml](https://github.com/robzolkos/omarchy-agent-usage/blob/master/Panel.qml): a real third-party QML panel example, fetched during review.
- [Agent Bar architecture](https://github.com/othavi0/omarchy-agent-bar/blob/master/docs/dev/architecture.md): separation of process ownership, immutable results and optional UI controls. It uses a different, multi-provider architecture; its Rust backend and separate service kind are not requirements for this plugin.
- User-provided Omarchy development/publishing guide: one bar-widget entry point, nested panel lifecycle forwarding, user-owned files and explicit dependency/privilege documentation.

An attempted upstream raw clock URL returned 404. We used the installed, working clock instead of treating an unavailable remote URL as evidence.

## Decisions

**Keep QML and Python.** A new frontend framework, daemon or Rust rewrite would add build/install complexity without fixing the account/setup conflict.

**Split by responsibility, not arbitrary line count:**

| File | Responsibility |
| --- | --- |
| `BarWidget.qml` | Bar icon, service ownership, settings persistence, IPC, and forwarding open/close/popout lifecycle to the nested panel. |
| `Panel.qml` | Host panel lifecycle: builds `KeyboardPanel.content` on first open, keeps the service/IPC alive while closed, holds focus and Escape/Ctrl+Tab, and forwards the primary action. |
| `VpnDashboard.qml` | Presentation-only dashboard: observed-state hero, context-aware primary action, destination picker, Quick destinations, IP utility row, and the Details/Account/Settings subviews with Back/Escape. |
| `ConnectionStage.qml` | Quiet central visual for connecting/connected/disconnecting/unknown/legacy/stale state; never infers VPN status from the public IP. |
| `ConnectionSummary.qml` | Compact read-only IP/transfer row with privacy masking, copy and failure feedback. |
| `QuickDestinations.qml` | Bounded favorites and recent verified NetworkManager destinations; choosing one only changes the next destination. |
| `StatusNotice.qml` | Shared status/error notice, shown during setup too, with **Recheck status** for connection-state problems and dismissal for operation errors. |
| `SetupCard.qml` | One-requirement-at-a-time onboarding, completed-step summary, form validation and focus routing. |
| `ConnectionSettings.qml` | Standalone country/advanced selector retained as a component-test surface; the dashboard owns the production destination picker. |
| `ConnectionDetails.qml` | Observed IP/session data in a Network-panel-style grid in the Details subview (live rates and totals while connected), masking and click-to-copy. |
| `AccountSection.qml` | Signed-in identity, relinking without logout, and two-step logout of the plugin's own login. |
| `Service.qml` | Connection state, status/action/streaming processes, settings restoration, favorites/recents, status observation time and notifications. |
| `SetupController.qml` | Independent dependency, account, legacy-cleanup, readiness and background-sync processes. |
| `ServerInventory.qml` | Bounded optional inventory request with selection-key validation. |
| `ServiceUtils.js` | Pure normalization/readiness/inventory/result/status-sampling/GeoIP/compatibility helpers, exercised directly in Qt tests. |
| `Translations.js` | Plugin-owned English and pt-PT strings; the caller supplies the live Omarchy language, and backend errors are never translated. |
| `CountryRecents.js` | Strict normalization/serialization of the favorite and recent country CSVs. |
| `cyberghost_runner.py` | Stable CLI entry point and compatibility facade; delegates to the internal `cyberghost` package. |

### Backend package (split in 1.8.0)

The former ~2,600-line `cyberghost_runner.py` monolith now lives in
`cyberghost/`, split along the domains the tests already exercise:

| Module | Responsibility |
| --- | --- |
| `constants.py` | Release constants, action set and the country → city tables (`CITY_MAP`, `DIALUP_CITY_MAP`). |
| `system.py` | Bounded subprocess I/O, private state files, the per-user lifecycle lock, cancellation and system-file recognizers. |
| `validation.py` | Strict validation of keys, IPs, ports, hosts, country codes, selectors, DNS and bounded config text. |
| `transport.py` | Pinned-TLS endpoint requests, the account JSON API and request payload builders. |
| `wireguard.py` | RFC 7748 X25519 key generation (no `wireguard-tools`). |
| `credentials.py` | Native/legacy config paths, credential loading and atomic profile writes. |
| `vendor.py` | Optional, read-only inventory through the official CLI. |
| `server_data.py` | Server cache, live inventory, JWT/session metadata and the paced background sync. |
| `server_selection.py` | Candidate ordering, killable reachability probes and key exchange. |
| `networkmanager.py` | `nmcli` lifecycle, connect/disconnect/logout, counters and `status`. |
| `setup.py` | Native account registration and the readiness payload for the setup card. |
| `cli.py` | `argparse` surface and the JSON action envelope. |

`cyberghost_runner.py` re-exports the historical module surface and forwards
attribute patches to the submodule that owns each name (`cyberghost/_compat.py`).
That keeps two contracts intact without weakening the split: `Service.qml`
still executes one stable CLI file, and the test suite can keep doing
`mock.patch.object(runner, "nm_active_state", …)` exactly as before.
`tests/test_module_facade.py` guards the behaviour. Import order is acyclic;
`logout` lives with the NetworkManager lifecycle, which is why the credentials
module does not import it back.

### Why the QML components stay at the plugin root

`Panel.qml` resolves `AccountSection`, `ConnectionSettings`, `ConnectionDetails`,
`StatusNotice`, `SetupCard`, `SetupController`, `ServerInventory` and
`GhostIcon` as sibling files. Moving them into `components/` would require a
directory import in every consumer, and the tests import the repository root as
a QML module (`import "../.." as Plugin`) to instantiate `Plugin.SetupCard` and
`Plugin.ConnectionSettings` directly. `scripts/visual-preview.sh` and the
visual fixture also copy root-level `*.qml` into a temporary plugin. Only
`manifest.json` entry points must remain at the root, but the test and fixture
tooling makes a subdirectory a breaking change for no runtime benefit, so the
components stay where they are.

### Country data

`Countries.js` (UI labels, flags and the quick-connect set) and the backend
`CITY_MAP`/`DIALUP_CITY_MAP` (CLI slugs) are one logical table in two runtimes.
`tests/test_contracts.py` now enforces the exact set relationship, with `UK`
as the only documented alias (`UK → GB` in the UI, a CLI alias in the backend).
Adding a country in one place fails the suite until the other side matches.

### Installers

`install.sh` is the single owner of guided setup, `--uninstall` and the
destructive `--fresh` reset; `--dry-run` plans every mode without changing
state. `fresh-install.sh` is a deprecated wrapper that delegates to
`install.sh --fresh` for existing documentation and bookmarks.

## Privilege model (1.7.0)

The tunnel is a NetworkManager WireGuard connection that the runner creates **as the desktop user**. This is the model Omarchy's own network panel uses: NetworkManager's Polkit policy (`network-control`, `settings.modify.own`) authorizes the change. On Omarchy those are granted to the active session, and where a system requires `auth`, Omarchy's in-shell Polkit agent asks. Nothing is installed as root and no plugin code ever runs as root.

- **Profile:** `nmcli connection add save no ...` with a fixed per-user UUID, `connection.permissions user:<name>`, `autoconnect no`, and interface `cyberghost`. It is never written to `/etc/NetworkManager/system-connections`.
- **Secret handling:** the per-session X25519 private key is generated in Python (RFC 7748) and sent through `nmcli connection edit` on stdin, following Omarchy's rule that argv is world-readable. `save temporary` keeps it in memory.
- **Routing:** `allowed-ips=0.0.0.0/0;::/0` lets NetworkManager's WireGuard auto-default-route install the same fwmark and policy-table routing that `wg-quick` used. `ipv6.method link-local` is required for the `::/0` route to exist, so IPv6 cannot bypass the tunnel.
- **DNS:** VPN servers go on the tunnel link with the `~.` routing domain and a negative `dns-priority`, making it the exclusive resolver in systemd-resolved. If the user picked a provider with `omarchy dns`, NetworkManager's global DNS overrides per-connection DNS by design. No link then holds a DNS default route, and those public resolvers are reached through the tunnel.
- **Lifecycle:** connect removes any previous session of our profile, then runs add → key → `--wait` up → verify `activated` and the interface. Every failure rolls back with down and delete, followed by verification that the profile and interface are gone. Disconnect is the same removal. `nmcli` exit 10 (not found) makes it idempotent.
- **Cancellation:** the panel's cancel sends SIGTERM, which raises `OperationCancelled` (a `BaseException`, so server fallback handlers cannot swallow it). Before the old session is replaced, cancel leaves it untouched; after that boundary, the new profile is removed again.
- **Probing:** endpoint DNS/TCP probes run in forked worker processes (at most 16 at a time) under a total deadline. Workers still running at the deadline are killed, so a blocked resolver cannot stall a connect. Server-cache writes are serialized with a private lock file.
- **Account linking:** `register` takes the lifecycle lock, refuses while our profile or interface is active (or when that cannot be verified), and stores device credentials before the optional account-id lookup.
- **Liveness:** handshake age requires `CAP_NET_ADMIN`, so status reports world-readable `/sys/class/net/cyberghost/statistics` counters. The UI warns when nothing has been received for three minutes. WireGuard rekeys every two minutes, so a live tunnel always receives.
- **Migration:** a `cyberghost` interface that isn't our active profile is a tunnel from the pre-1.7 root helper. Status reports `backend: "legacy"`. The UI shows it as connected and disconnects it through the already-installed helper (the only remaining `pkexec` call), and the runner refuses to stack a new connection on it. `scripts/remove-legacy-helper.sh` then removes the helper and its rules.

The manifest declares only `bar-widget`; `BarWidget.qml` loads the nested `Panel.qml`. No extra panel kind or second Quickshell process is created. The host bar identity and anchor are forwarded, including `opened`, `closeForPopoutSwitch` and `popoutSwitchClosing`.

The host creates one widget (and service) per monitor. Only the first widget in `bar.moduleWidgets()` enables the plugin IPC handler, and direct middle/right-click actions route to that same first service; refresh broadcasts to the monitor widgets. NetworkManager serializes activation of the single profile, and every action addresses it by its fixed UUID. Monitor hotplug/re-election remains a separate integration check.

`ConnectionSettings` accepts a primary-action Component between Country and Advanced, exposing that slot's `focusTarget` to the panel. Closing explicitly closes child popups and clears an unsubmitted setup password. GeoIP requests carry the tunnel-state generation so an old result cannot describe a new connection.

The development-only visual fixture is a separate temporary panel plugin with synthetic service data; it is not a second entry point in the production manifest.

## Before → after

- One ~1,770-line combined popup/bar → a small entry point and focused composition/components.
- Repeated country quick-connect tiles plus country selector → one destination selector and an explicit Connect action.
- Always-visible server, mode and protocol selectors → Advanced settings.
- Optional authorization prompt followed by a reminder after dismissal → optional action under Advanced, no repeated nag.
- Native registration overwriting CLI config → separate private native file; read-only legacy compatibility.
- CLI executable treated as ready → installed/configured checked separately; runtime inventory still provides the real success/failure signal.
- DNS failure retried without VPN DNS → connection fails with an actionable error and attempts rollback.
- Settings restored through action setters → pure restoration, including late shell injection, without writing defaults back or resetting exact servers.
- Status labeled by the next selected destination/protocol → observed backend/tunnel status, with next-connection settings separate.

## Safety and remaining limits

There is no kill switch. No claim is made that default routes or received traffic prove leak protection. An in-memory profile does not survive a NetworkManager restart, so a restart ends the tunnel instead of silently restoring it.

Status and optional inventory work no longer block Disconnect. Status polls and action completions carry generations, stale results are discarded, action timeouts/cancellation report unknown state, and a failed probe is rendered separately from disconnected. Inventory results are validated against the captured country/protocol/mode before application. Selecting a country alone cannot reconnect. Backend live authentication, provider availability, DNS behavior and tunnel routing still require real-machine integration validation.

`active: false` in the local plugin-list output was initially misread as a widget failure. Inspection of Omarchy's `shell.qml` shows it denotes selection of a full-bar plugin. For this bar widget, validate enabled state and actual summon/hide behavior instead.
