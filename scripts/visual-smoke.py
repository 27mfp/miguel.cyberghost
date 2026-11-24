#!/usr/bin/env python3
"""Opt-in real-shell visual/keyboard smoke test. Requires the synthetic fixture.

No VPN, account or installer action is executed. The clipboard is restored.
"""

import argparse
import json
import math
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

TARGET = "test.cyberghost-release-172"


def run(tool, *args, data=None):
    binary = shutil.which(tool)
    if not binary:
        raise RuntimeError(f"Required tool missing: {tool}")
    # wl-copy forks a selection owner; inherited capture pipes can keep
    # communicate() waiting even after a successful clipboard restoration.
    output = subprocess.DEVNULL if tool == "wl-copy" else subprocess.PIPE
    result = subprocess.run(  # noqa: S603 - fixed local tools and test-fixture arguments, no shell
        [binary, *args], input=data, stdout=output, stderr=output, timeout=10, check=True
    )
    return result.stdout or b""


def ipc(*args):
    return run("omarchy-shell", TARGET, *args).decode().strip()


def snapshot():
    return json.loads(ipc("snapshot"))


def wait_for(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        value = snapshot()
        if predicate(value):
            return value
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for the fixture state")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def activate(name):
    if ipc("focus", name) != "true":
        raise AssertionError(f"Cannot focus {name}")
    run("wtype", "-k", "Return")


def shortcut(key):
    """Press a panel shortcut with the viewport (not a text field) focused."""
    if ipc("focus", "vpnPanelViewport") != "true":
        raise AssertionError("Cannot focus the panel viewport")
    run("wtype", key)


def capture(directory, name):
    time.sleep(0.2)  # Let the host's frame/size transition settle before raster capture.
    state = snapshot()
    box = state["controls"]["vpnPanelViewport"]
    x, y = max(0, math.floor(box["x"] - 16)), max(0, math.floor(box["y"] - 16))
    geometry = f"{x},{y} {math.ceil(box['width'] + 32)}x{math.ceil(box['height'] + 32)}"
    run("grim", "-g", geometry, str(directory / f"{name}.png"))
    (directory / f"{name}.json").write_text(json.dumps(state, indent=2) + "\n")
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run", action="store_true", help="Manipulate the installed synthetic fixture in the live shell"
    )
    args = parser.parse_args()
    if not args.run:
        parser.error("Pass --run after installing/enabling the visual fixture; see docs/visual-testing.md")
    directory = Path(tempfile.mkdtemp(prefix="cyberghost-visual-"))
    clipboard = None
    mime = None
    copied = False
    try:
        types = run("wl-paste", "--list-types").decode().splitlines()
        mime = next((item for item in types if "/" in item), None)
        if mime:
            clipboard = run("wl-paste", "--no-newline", "--type", mime)
    except subprocess.CalledProcessError:
        pass  # An empty clipboard is a valid starting state.
    try:
        run("omarchy-shell", "shell", "summon", TARGET, "{}")
        wait_for(lambda state: state["opened"])
        run("omarchy-shell", "shell", "hide", TARGET)
        ipc("scenario", "disconnected")
        run("omarchy-shell", "shell", "summon", TARGET, "{}")
        wait_for(lambda state: state["opened"])
        ready = capture(directory, "01-ready")
        require(ready["controls"]["vpnPanelViewport"]["height"] > 0, "Preview viewport is empty")
        require(
            not ready["controls"].get("statusBanner", {}).get("visible", False),
            "Ready preview contains an unexpected status banner",
        )
        activate("dashboardCountryPicker")
        wait_for(lambda state: state["controls"]["dashboardCountryPicker"]["popupOpen"])
        run("wtype", "Spain")
        capture(directory, "02-filtered-country")
        run("wtype", "-k", "Down", "-k", "Return")
        wait_for(lambda state: state["country"] == "ES")
        require(not snapshot()["connected"], "Country selection connected without consent")
        activate("dashboardCountryPicker")
        wait_for(lambda state: state["controls"]["dashboardCountryPicker"]["popupOpen"])
        run("omarchy-shell", "shell", "hide", TARGET)
        run("omarchy-shell", "shell", "summon", TARGET, "{}")
        wait_for(lambda state: not state["controls"]["dashboardCountryPicker"]["popupOpen"])
        activate("summaryCompactPrivacy")
        wait_for(lambda state: state["controls"]["summaryCompactIp"]["text"] == "Hidden")
        capture(directory, "03-private")
        activate("summaryCompactPrivacy")
        copied = True
        activate("summaryCompactCopy")
        wait_for(lambda state: state["controls"]["summaryCompactCopy"]["tooltipText"] == "Copied")
        require(
            run("wl-paste", "--no-newline").decode() == "203.0.113.42", "Clipboard did not receive the displayed IP"
        )
        activate("vpnSettingsShortcut")
        expanded = wait_for(lambda state: state["controls"]["vpnPrivacySetting"]["visible"])
        activate("vpnPrivacySetting")
        wait_for(lambda state: state["hideDetails"])
        activate("vpnPrivacySetting")
        wait_for(lambda state: not state["hideDetails"])
        capture(directory, "04-settings")
        for name in ("modePicker", "protocolPicker", "streamingPicker", "serverPicker"):
            require(name not in expanded["controls"], "Unsupported vendor control is exposed: " + name)
        require(expanded["protocol"] == "wireguard" and expanded["mode"] == "traffic", "Wrong release mode")
        activate("vpnBack")
        capture(directory, "05-wireguard-only")
        require(ipc("focus", "vpnPrimaryAction") == "true", "Cannot focus primary action")
        capture(directory, "16-primary-focused")
        activate("vpnOpenDetails")
        details = capture(directory, "17-details")
        require(details["controls"]["privacyToggle"]["visible"], "Details privacy control is hidden")
        require(details["controls"]["copyIpButton"]["visible"], "Details copy control is hidden")
        activate("vpnAccountShortcut")
        capture(directory, "18-account")
        activate("vpnBack")
        shortcut("t")  # Synthetic service only: no NetworkManager profile is created.
        connected = wait_for(lambda state: state["connected"])
        require(
            connected["controls"]["vpnPrimaryAction"]["text"] == "Disconnect",
            "Primary action did not follow the connection",
        )
        require(connected.get("activeCountry") == connected["country"], "Synthetic active country is stale")
        require(
            connected["controls"]["dashboardLocationLabel"]["text"] == "NEXT LOCATION",
            "Connected location label missing",
        )
        capture(directory, "06-connected")
        shortcut("t")
        wait_for(lambda state: not state["connected"])
        ipc("scenario", "narrow")
        narrow = capture(directory, "07-narrow")
        require(
            narrow["controls"]["dashboardCountryPicker"]["value"] == narrow["country"],
            "Country picker stopped following the service after user selection",
        )
        ipc("scenario", "stale")
        capture(directory, "08-stale")
        for index, scenario in enumerate(("connecting", "unknown", "error", "switch", "sampling"), 9):
            ipc("scenario", scenario)
            state = capture(directory, f"{index:02d}-{scenario}")
            if scenario in ("unknown", "error"):
                require(state["controls"]["statusBanner"]["visible"], "Recovery notice is missing")
                if scenario == "unknown":
                    require(state["controls"]["statusRecheck"]["visible"], "Recheck action is missing")
                    previous = state["recheckCalls"]
                    activate("statusRecheck")
                    wait_for(lambda value, previous=previous: value["recheckCalls"] > previous)
                else:
                    activate("dismissNotice")
                    wait_for(lambda value: not value["controls"]["statusBanner"]["visible"])
            if scenario == "connecting":
                require(not state["controls"]["vpnPrimaryAction"]["enabled"], "Connecting action is not busy")
                require(not state["controls"]["dashboardCountryPicker"]["enabled"], "Busy location remains editable")
            if scenario == "switch":
                require(
                    state["controls"]["dashboardLocationLabel"]["text"] == "NEXT LOCATION", "Next location is ambiguous"
                )
                activate("vpnPrimaryAction")
                wait_for(lambda value: value["activeCountry"] == "ES")
            if scenario == "sampling":
                activate("vpnOpenDetails")
                detail = capture(directory, "19-sampling-details")
                require(detail["controls"]["trafficSampling"]["visible"], "Sampling explanation missing")
        ipc("scenario", "short-setup")
        short = capture(directory, "14-short-setup")
        viewport = short["controls"]["vpnPanelViewport"]
        require(viewport["contentHeight"] > viewport["height"], "Short setup did not constrain height")
        require(ipc("focus", "accountUsername") == "true", "Cannot focus short setup username")
        run("wtype", "short@example.invalid", "-k", "Tab", "short-password", "-k", "Tab")
        focused = snapshot()
        viewport = focused["controls"]["vpnPanelViewport"]
        button = focused["controls"]["linkAccount"]
        require(
            button["y"] >= viewport["y"] and button["y"] + button["height"] <= viewport["y"] + viewport["height"] + 1,
            "Focused short-panel action is offscreen",
        )
        ipc("scenario", "setup")
        capture(directory, "15-setup")
        require(ipc("focus", "accountUsername") == "true", "Cannot focus account username")
        run("wtype", "preview@example.invalid", "-k", "Return", "not-a-real-password", "-k", "Return")
        wait_for(lambda state: state["setupMsg"].startswith("Preview:"))
        require(snapshot()["controls"]["accountPassword"]["text"] == "", "Submitted password was retained")
        require(ipc("focus", "accountPassword") == "true", "Cannot focus account password")
        run("wtype", "discard-this-draft", "-k", "Escape")
        wait_for(lambda state: not state["opened"])
        require(snapshot()["controls"]["accountPassword"]["text"] == "", "Closing retained an unsubmitted password")
    finally:
        if copied:
            if clipboard is not None and mime:
                run("wl-copy", "--type", mime, data=clipboard)
            else:
                run("wl-copy", "--clear")
        run("omarchy-shell", "shell", "hide", TARGET)
        print(f"Artifacts: {directory}")
    count = len(list(directory.glob("*.png")))
    print(f"PASS: real-shell interactions, clipboard restoration and {count} captures. Review images in {directory}")


if __name__ == "__main__":
    main()
