# Tests and verification

For the current 1.6.1 candidate, see the [release gates and live findings](release-checklist.md). Historical evidence below does not certify the newer candidate or optional CLI connections.

## What changed in the test strategy

The previous suite mixed real backend behavior tests with source-text assertions about labels, IDs and exact spacing. One test explicitly required retrying WireGuard **without DNS** after resolver failure. That was a passing test for the wrong security behavior.

This refactor:

- Keeps the transport, validation, authorization and JSON action tests.
- Replaces the DNS-less retry expectation with an observed failing regression, then changes activation to fail and attempt rollback.
- Adds timeout/spawn/output-limit cleanup tests, with subprocesses mocked at the external boundary.
- Replaces the source-text layout checklist with actual Qt component interaction tests: focus routing, required dependency/DNS steps, form submit/validation/password clearing, advanced disclosure and country selection without connection.
- Exercises the actual service with process-boundary doubles. This caught Connect silently resetting an exact server to automatic and streaming refresh destroying in-flight output/selected profiles. Both tests were observed failing before the fixes.
- Tests inventory callbacks for country changes, repeat refresh during a request and CLI failure with an automatic fallback.
- Tests pure readiness/settings normalization without mutation, invalid inventory rows, and stale request keys.
- Tests native credential separation, private permissions, legacy read compatibility, rejection of native symlinks/invalid state, and refusing a vendor path before network registration.
- Retains narrow static safety contracts for shell/privilege boundaries that should not be executed with sudo in a unit test. All production QML files are inspected so extracting a component does not evade that guard.

The old `tests/test_runner.py` is split into domain-focused files. `tests/runner_support.py` supplies fixtures; each test module has an independent runner instance. No test needs a paid account, live VPN or root authorization.

## Commands

```bash
pytest -q
ruff check .
ruff format --check .
bash scripts/test-qml.sh
python3 scripts/check_qml.py
omarchy plugin validate "$PWD"
shellcheck install.sh install-helper.sh fresh-install.sh scripts/test-qml.sh scripts/visual-preview.sh
git diff --check
```

Qt tools default to `/usr/lib/qt6/bin`; override with `QT_BIN` if necessary. The scripts run `qmltestrunner`, **not another Quickshell process**.

### QML test boundaries

`tests/qml` executes real JavaScript functions under Qt. `tests/ui` instantiates the production setup, settings, inventory and service components. It uses explicit doubles under `tests/support/imports` for shell controls, theme tokens and process execution. Tests deliver process output/exit events; no helper, network or package installation runs.

These tests prove plugin bindings and orchestration, **not** Omarchy rendering, compositor focus or actual VPN routing. They are complemented by real installed-import linting and the [real-shell visual smoke fixture](visual-testing.md). The latter uses real host controls, synthetic service data, keyboard interactions and rendered captures—not the component-test doubles.

`qmltestrunner` cannot load this distribution's statically registered Quickshell plugin. Trying to use real shell controls directly in it fails with `quickshell-coreplugin not found`. That is why the doubles are explicit rather than pretending a standalone test runner is the shell.

### Native lint policy

Quickshell maps the shell root to `qs` at runtime. `scripts/check_qml.py` creates a temporary import mapping outside the plugin and analyzes all production QML against installed Omarchy imports.

The checker fails new/project diagnostics. It records a narrow allowlist of known host metadata limitations: exact dynamic `QObject` members used by Omarchy's style/bar/loader APIs and the missing `QProcess::ExitStatus` annotation. This is **not warning-free lint**. Full diagnostics are saved to a uniquely created temporary JSON file; missing imports, project-property errors and misspelled host members are not exempted. The exception policy has its own regression test.

CI runs Python 3.9/3.12 tests, Ruff, shell syntax/ShellCheck, QML parsing and Qt behavior tests. Native import linting requires the installed target shell and is a separate local gate—not a claim made by Ubuntu's test doubles.

## Refactor baseline (1.6.0)

- Python regression suite: 76 cases passing on both Python 3.9 and Python 3.12.
- Qt: 20 substantive test functions passing (plus Qt's suite initialization/cleanup entries).
- Native QML lint: zero project diagnostics; 60 explicitly recorded host metadata warnings on Omarchy 4.0.2 / Qt 6.11.2.
- Manifest validation, Ruff, shell syntax, ShellCheck and whitespace checks pass.
- Existing-shell summon/hide and direct plugin open/close passed repeatedly.
- Escape closed the live panel: compositor inspection showed one keyboard panel before Escape and zero afterwards.
- Setup screenshot inspected locally: the actual installed helper was correctly identified as needing an update.
- One existing-shell restart cleared a stale Qt filename cache after the entry-point rename. No second shell was started alongside it.

## UI follow-up evidence

- Python: 76 cases passing; Qt: 27 substantive test functions, excluding suite initialization/cleanup.
- Regressions observed failing before their fixes: premature clipboard success, open dropdowns after hiding settings, old GeoIP responses crossing tunnel transitions, missing IPv4 transport selection, and retained unsubmitted passwords.
- Native import lint: zero project diagnostics and 62 recorded host metadata warnings on Omarchy 4.0.2 / Qt 6.11.2.
- Real-shell smoke: nine synthetic-data captures reviewed, with keyboard selection, privacy, real clipboard copy/restore, Advanced, simulated connect/disconnect, account-field clearing and Escape assertions passing. Setup fields now match the host theme.
- The live installed panel was inspected and its Connect button clicked. With explicit user authorization and helper 1.6.0, native WireGuard connected successfully.
- Connected route lookups for IPv4 and IPv6 selected `cyberghost` (table 51820). An IPv4 HTTPS egress lookup succeeded. `systemd-resolved` attached the VPN DNS servers and `~.` routing domain to the tunnel; an uncached DNS query used that link.
- With separate user authorization, Disconnect removed the interface. Both route lookups returned to Wi-Fi, and an uncached DNS query used Wi-Fi again. No passwordless rule was installed.
- These are bounded observations, **not a leak-proof or kill-switch claim**. IPv6 transport was not independently exercised with an HTTPS request.
- With eDP-1 and HEADLESS-69 active, CyberGhost emitted no duplicate IPC warning. Shell summon opened on the focused output in both cases; focus was restored afterward. Other host/plugin IPC warnings remain outside this change.
- The installed plugin is now a real user-owned checkout, not the old source symlink. QML edits required restarting the existing shell to invalidate its imported-type cache.

## Remaining integration limits

Before publishing a release, also check with authorization:

1. Real activation failure/timeout/DNS-failure recovery under controlled network conditions; unit tests cover these without damaging the working network.
2. Optional CLI authentication, exact-server availability and supported streaming/OpenVPN connections. The local CLI is installed but not configured; its account state was not changed. Fixture selections are not vendor integration evidence.
3. Monitor hotplug, owner re-election and constrained-height display behavior. Narrow fixture captures do not cover every screen size.
4. Production disable/re-enable and removal on a disposable installation. The synthetic preview uses the ordinary plugin lifecycle, but that does not establish complete production removal behavior.

Historical screenshots in the repository predate the simplified flow and are not presented as current UI in the README.
