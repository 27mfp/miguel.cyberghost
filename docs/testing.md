# Tests and verification

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
shellcheck install.sh install-helper.sh fresh-install.sh scripts/test-qml.sh
git diff --check
```

Qt tools default to `/usr/lib/qt6/bin`; override with `QT_BIN` if necessary. The scripts run `qmltestrunner`, **not another Quickshell process**.

### QML test boundaries

`tests/qml` executes real JavaScript functions under Qt. `tests/ui` instantiates the production setup, settings, inventory and service components. It uses explicit doubles under `tests/support/imports` for shell controls, theme tokens and process execution. Tests deliver process output/exit events; no helper, network or package installation runs.

These tests prove plugin bindings and orchestration, **not** Omarchy rendering, compositor focus or actual VPN routing. They are complemented by real installed-import linting and live shell smoke checks.

`qmltestrunner` cannot load this distribution's statically registered Quickshell plugin. Trying to use real shell controls directly in it fails with `quickshell-coreplugin not found`. That is why the doubles are explicit rather than pretending a standalone test runner is the shell.

### Native lint policy

Quickshell maps the shell root to `qs` at runtime. `scripts/check_qml.py` creates a temporary import mapping outside the plugin and analyzes all production QML against installed Omarchy imports.

The checker fails new/project diagnostics. It records a narrow allowlist of known host metadata limitations: exact dynamic `QObject` members used by Omarchy's style/bar/loader APIs and the missing `QProcess::ExitStatus` annotation. This is **not warning-free lint**. Full diagnostics are saved to a uniquely created temporary JSON file; missing imports, project-property errors and misspelled host members are not exempted. The exception policy has its own regression test.

CI runs Python 3.9/3.12 tests, Ruff, shell syntax/ShellCheck, QML parsing and Qt behavior tests. Native import linting requires the installed target shell and is a separate local gate—not a claim made by Ubuntu's test doubles.

## Local evidence for 1.6.0

- Python regression suite: 76 cases passing on both Python 3.9 and Python 3.12.
- Qt: 20 substantive test functions passing (plus Qt's suite initialization/cleanup entries).
- Native QML lint: zero project diagnostics; 60 explicitly recorded host metadata warnings on Omarchy 4.0.2 / Qt 6.11.2.
- Manifest validation, Ruff, shell syntax, ShellCheck and whitespace checks pass.
- Existing-shell summon/hide and direct plugin open/close passed repeatedly.
- Escape closed the live panel: compositor inspection showed one keyboard panel before Escape and zero afterwards.
- Setup screenshot inspected locally: the actual installed helper was correctly identified as needing an update.
- One existing-shell restart cleared a stale Qt filename cache after the entry-point rename. No second shell was started alongside it.

## Not verified by this run

The installed privileged helper was not replaced, account credentials were not changed, and no live connect/disconnect was performed. The installed helper is older than 1.6.0; update it explicitly before live connection validation.

Before publishing a release, also check with authorization:

1. Native connect/disconnect, failed DNS setup, and IPv4/IPv6/DNS routing on the real network.
2. Optional CLI authentication, exact-server selection and supported streaming/OpenVPN modes.
3. Actual keyboard dropdown interaction, small-screen ready-state layout and multiple-monitor behavior.
4. Disable/re-enable and removal on a disposable installation. These mutate persisted shell setup and were not run against the user's working installation.

The existing developer installation is a symlink to the source checkout. It was not silently replaced. Use a real user-owned checkout for a documentation-compliant clean installation, and do not ship symlinks in the plugin folder. Historical screenshots in the repository predate the simplified flow and are no longer presented as current UI in the README.
