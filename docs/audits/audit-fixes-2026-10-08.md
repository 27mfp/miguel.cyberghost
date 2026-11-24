# Audit fixes and verification

Date: 2026-10-08
POC: Miguel (project owner)
TL;DR: The nine code/documentation findings have fixes and offline regression coverage. Real VPN and machine-migration checks remain deferred to protect the current connection.

Baseline: v1.7.0 at 43c3476. These fixes are included in the 1.7.1 patch-release candidate. They have not been deployed to the installed plugin; publication is tracked through the release PR.

## Implemented

1. Cancellation now bypasses ordinary fallback handlers. Activation rollback handles cancellation explicitly, and the full connect operation cleans up cancellation after activation. Cancellation during lookup leaves an existing session untouched.
2. Malformed nested cache structure is treated as a miss instead of raising AttributeError.
3. Endpoint probes use killable Linux worker processes. Total deadlines include DNS; workers are killed and reaped on timeout, cancellation and partial startup failure.
4. Registration shares the lifecycle lock with connect, disconnect and logout. Pending registration completes before a waiting logout can remove its credentials.
5. Registration refuses active or unverifiable tunnel state before account API calls. The setup form also blocks connected/busy submission and clears the password on refusal.
6. Update instructions explain cached QML and the conditional `omarchy restart shell` recovery. No automatic shell restart was added.
7. Cache writers share a bounded, private lock. Failed writes remove temporary files. State lock files reject unsafe types, permissions and ownership; advisory lock paths remain persistent.
8. Developer reset invokes recognized cleanup before plugin teardown, aborting on unknown helpers/customized rules. Ambiguous historical WireGuard configuration and advisory lock files are preserved. Cleanup rechecks interface absence after authorization.
9. Native authentication and TLS failures recommend native account relinking and clock/CA/network checks instead of requiring the optional vendor CLI.

Additional registration safeguard: newly issued device credentials are published before the optional account-ID lookup. The UI permits 120 seconds for bounded lock/state/API work and describes timeout as an unknown outcome, rather than urging an immediate retry. A remote device can still be created without recoverable local credentials if the process/machine dies before receiving or saving the response; the message explains how to remove an unused device on the vendor website.

## Offline verification

- Full Python suite passes on Python 3.9, 3.12 and 3.14.
- Qt utility and UI suites pass.
- Ruff lint and format checks pass.
- Standalone and Omarchy manifest validation pass.
- Native QML lint: zero project diagnostics; existing host metadata warnings remain allowlisted.
- ShellCheck, shell syntax and git whitespace checks pass.
- Independent final source review found no confirmed blocker.

Regression tests cover cancellation in inventory/key exchange, cancellation after fake activation, schema errors, overlapping cache writers, temp cleanup, blocked probe process exit, abrupt worker exit, startup failure, account mutation locking, connected/unverified registration refusal, early credential publication and sandboxed strict cleanup.

Test homes and account paths are temporary. API and NetworkManager boundaries are mocked. Cleanup bodies run only against sandbox paths, never sudo. No real VPN connect/disconnect, account registration, network-stack restart, shell restart or privileged cleanup was performed.

## PR improvement pass

- Unknown status takes priority over operation errors. Stale-tunnel warnings take priority over progress text. Recheck is offered for unknown, failed or stale connection status; operation errors can be dismissed without a connection change.
- Account linking explains connected/busy restrictions inline and in its accessible description before submission.
- Failure to save optional account metadata does not turn already-published device credentials into a reported linking failure. Cancellation still propagates and saved credentials remain intact.
- Python 3.9/3.12/3.14: 233 tests passed on each. Qt: 76 UI and 13 utility cases passed. Ruff lint/format, native QML lint, manifest validation and whitespace checks passed.
- Added behavior coverage for mixed status/error states, dismissal preserving stale warnings, connected/busy linking explanations, cancellation after profile creation/key editing/activation/verification, and metadata lookup/save/cancellation after credential publication.

This pass used offline component tests and mocked backend boundaries. Existing synthetic screenshots describe the earlier candidate; no new real-shell captures or live VPN actions were performed. Remote CI must be rerun on the committed improvement revision before publication.

## Deferred live checks

- DHCP-mode DNS and real IPv4/IPv6 routing.
- Real connection, country switch, cancellation/timeout rollback and disconnect.
- Migration with an active 1.6.x helper tunnel.
- Disposable clean install, reset, removal and authorization failure.
- Real-shell update refresh and multi-monitor hotplug/owner election.
- Remote CI for the eventual committed revision.

Run connection-changing tests last in a disposable environment or maintenance window with an independent recovery channel. Offline passes do not certify live routing or compositor behavior.
