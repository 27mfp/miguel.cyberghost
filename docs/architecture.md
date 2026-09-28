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
| `BarWidget.qml` | Bar icon, service ownership, settings persistence, IPC and forwarding open/close/popout lifecycle to the nested panel. |
| `Panel.qml` | Popup composition, focus, Escape, status banner and the primary connect/disconnect action. |
| `SetupCard.qml` | Required setup steps, form validation and focus routing. |
| `ConnectionSettings.qml` | Country selection and progressively disclosed advanced controls. |
| `ConnectionDetails.qml` | Observed IP/session data in a Network-panel-style grid (live rates and totals while connected), masking and click-to-copy. |
| `AccountSection.qml` | Signed-in identity and two-step logout of the plugin's own login. |
| `Service.qml` | Connection state, status/action/streaming processes, settings restoration and notifications. |
| `SetupController.qml` | Independent dependency, account, legacy-cleanup and readiness processes. |
| `ServerInventory.qml` | Bounded optional inventory request with selection-key validation. |
| `ServiceUtils.js` | Pure normalization/readiness/inventory/result helpers, exercised directly in Qt tests. |
| `cyberghost_runner.py` | Unprivileged backend: validation, transport, credential handling, key generation and the NetworkManager tunnel lifecycle. |

## Privilege model (1.7.0)

The tunnel is a NetworkManager WireGuard connection that the runner creates **as the desktop user**. This is the model Omarchy's own network panel uses: NetworkManager's Polkit policy (`network-control`, `settings.modify.own`) authorizes the change. On Omarchy those are granted to the active session, and where a system requires `auth`, Omarchy's in-shell Polkit agent asks. Nothing is installed as root and no plugin code ever runs as root.

- **Profile:** `nmcli connection add save no ...` with a fixed per-user UUID, `connection.permissions user:<name>`, `autoconnect no`, and interface `cyberghost`. It is never written to `/etc/NetworkManager/system-connections`.
- **Secret handling:** the per-session X25519 private key is generated in Python (RFC 7748) and sent through `nmcli connection edit` on stdin, following Omarchy's rule that argv is world-readable. `save temporary` keeps it in memory.
- **Routing:** `allowed-ips=0.0.0.0/0;::/0` lets NetworkManager's WireGuard auto-default-route install the same fwmark and policy-table routing that `wg-quick` used. `ipv6.method link-local` is required for the `::/0` route to exist, so IPv6 cannot bypass the tunnel.
- **DNS:** VPN servers go on the tunnel link with the `~.` routing domain and a negative `dns-priority`, making it the exclusive resolver in systemd-resolved. If the user picked a provider with `omarchy dns`, NetworkManager's global DNS overrides per-connection DNS by design. No link then holds a DNS default route, and those public resolvers are reached through the tunnel.
- **Lifecycle:** connect removes any previous session of our profile, then runs add → key → `--wait` up → verify `activated` and the interface. Every failure rolls back with down and delete, followed by verification that the profile and interface are gone. Disconnect is the same removal. `nmcli` exit 10 (not found) makes it idempotent.
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
