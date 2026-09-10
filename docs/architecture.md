# Architecture and flow review — 1.6.0

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
| `ConnectionDetails.qml` | Observed IP/session data, masking and clipboard interaction. |
| `Service.qml` | Connection state, status/action/streaming processes, settings restoration and notifications. |
| `SetupController.qml` | Independent dependency, account, helper-install and readiness processes. |
| `ServerInventory.qml` | Bounded optional inventory request with selection-key validation. |
| `ServiceUtils.js` | Pure normalization/readiness/inventory/result helpers, exercised directly in Qt tests. |
| `cyberghost_runner.py` | Restricted privileged entry point, validation, transport, credential handling and tunnel lifecycle. |

The Python helper intentionally remains a **self-contained installed file**. Splitting it into imports from the mutable plugin directory would weaken the privilege boundary. Its tunnel activation is now a separately tested function; a future Python package split would need atomic, root-owned multi-file installation first.

The manifest declares only `bar-widget`; `BarWidget.qml` loads the nested `Panel.qml`. No extra panel kind or second Quickshell process is created. The host bar identity and anchor are forwarded, including `opened`, `closeForPopoutSwitch` and `popoutSwitchClosing`.

The host creates one widget (and service) per monitor. Only the first widget in `bar.moduleWidgets()` enables the plugin IPC handler, and direct middle/right-click actions route to that same first service; refresh broadcasts to the monitor widgets. The fixed root helper also serializes the global tunnel lifecycle with a persistent `/run/lock/cyberghost.lock`, so external helper invocations cannot mutate the shared config concurrently. Monitor hotplug/re-election remains a separate integration check.

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

There is no kill switch. No claim is made that default routes or a fresh handshake prove leak protection. DNS presence is checked during setup; actual DNS configuration must still succeed during activation.

The fixed helper is version/capability checked, while trusted helper presence remains available for disconnect recovery after an update mismatch. Optional authorization is explicit in both terminal and GUI installers; helper-only updates preserve an existing rule and explicit revocation verifies the rule bytes before removal.

Status and optional inventory work no longer block Disconnect. Status polls and action completions carry generations, stale results are discarded, action timeouts/cancellation report unknown state, and a failed probe is rendered separately from disconnected. Inventory results are validated against the captured country/protocol/mode before application. Selecting a country alone cannot reconnect. Backend live authentication, provider availability, DNS behavior and tunnel routing still require real-machine integration validation.

`active: false` in the local plugin-list output was initially misread as a widget failure. Inspection of Omarchy's `shell.qml` shows it denotes selection of a full-bar plugin. For this bar widget, validate enabled state and actual summon/hide behavior instead.
