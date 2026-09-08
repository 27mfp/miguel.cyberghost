# Real-shell visual checks

The Qt component tests are **behavior tests, not visual tests**. Their explicit shell-control doubles cannot establish Omarchy styling, popup geometry, focus routing or clipboard integration.

The opt-in fixture loads the production `Panel.qml` and its components inside the **existing Omarchy shell**, with real `qs.Ui` controls and theme tokens. Only the service is synthetic. It uses documentation-only IP addresses and cannot connect a VPN, register an account or install software.

## Run

Requires Omarchy, `wtype`, `grim`, `wl-copy`, `wl-paste` and Python 3.9+. This temporarily installs a separate panel plugin and manipulates desktop focus. Do not type real credentials into the preview.

```bash
bash scripts/visual-preview.sh --install
# Wait for plugin discovery, then:
omarchy plugin enable test.cyberghost-visual
python3 scripts/visual-smoke.py --run
# Inspect the PNGs and JSON snapshots in the printed /tmp directory.
bash scripts/visual-preview.sh --remove
```

The fixture has no bar entry. Removal uses Omarchy's normal removal command, which may retain a backup. Existing CyberGhost credentials, configuration and authorization rules are not changed. Clipboard contents are held in memory and restored using their original selected MIME type; alternate representations are not preserved. Do not change the clipboard concurrently with the test.

If you edit imported QML after loading the fixture, a rescan may still use cached types. Restart the **existing** service with `omarchy restart shell`, then rerun. Do not start a second Quickshell process. Remove the fixture when finished; `keepLoaded` is necessary so its inspection IPC survives hide/reopen tests.

## Automated assertions

- Search and select Spain through actual keyboard input without connecting.
- Hide/reopen with a dropdown open; confirm the popup is closed.
- Toggle privacy and verify displayed values are masked.
- Copy the synthetic public IP through the real `wl-copy` process, verify clipboard contents and restore the previous clipboard.
- Expand Settings without moving Connect below its controls.
- Verify vendor-dependent mode, protocol, streaming and server controls are absent.
- Exercise Connect/Disconnect against the synthetic service.
- Submit synthetic account fields and verify the password is cleared; close with an unsubmitted password and verify it is discarded.
- Escape closes the panel.

The script saves nine rendered captures: ready, filtered country, private details, Advanced, WireGuard-only controls, connected, narrow (280 logical units before host scaling), stale handshake and account setup. Snapshots mask entered account values. The test fails on missing controls or unsuccessful interactions; it does not silently skip unavailable IPC.

## Human visual review

Inspect the captures for clipped labels, overflowing controls, excessive blank space, popup height, focus treatment and correct theme styling. In this review, the captures exposed the setup fields' platform-default appearance; using Omarchy's TextField corrected it. The filtered-country capture also confirms the popup shrinks to one result rather than retaining a large empty list.

These are **visual smoke captures, not pixel-golden regression tests**. Theme, font, Qt version and display scale affect rendering. There is no automated screenshot-diff pass claim, and the fixture does not validate real authentication, DNS, routes or server availability. A narrow panel is not a complete small-screen/compositor test.

See [testing evidence and remaining integration limits](testing.md) for the separate live VPN checks.
