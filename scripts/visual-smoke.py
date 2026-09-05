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

TARGET = "test.cyberghost-visual"


def run(tool, *args, data=None):
    binary = shutil.which(tool)
    if not binary:
        raise RuntimeError(f"Required tool missing: {tool}")
    result = subprocess.run(  # noqa: S603 - fixed local tools and test-fixture arguments, no shell
        [binary, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=True
    )
    return result.stdout


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


def activate(name):
    if ipc("focus", name) != "true":
        raise AssertionError(f"Cannot focus {name}")
    run("wtype", "-k", "Return")


def capture(directory, name):
    time.sleep(0.2)  # Let the host's frame/size transition settle before raster capture.
    state = snapshot()
    box = state["controls"]["vpnPanelViewport"]
    x, y = max(0, math.floor(box["x"] - 16)), max(0, math.floor(box["y"] - 16))
    geometry = f'{x},{y} {math.ceil(box["width"] + 32)}x{math.ceil(box["height"] + 32)}'
    run("grim", "-g", geometry, str(directory / f"{name}.png"))
    (directory / f"{name}.json").write_text(json.dumps(state, indent=2) + "\n")
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Manipulate the installed synthetic fixture in the live shell")
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
        run("omarchy-shell", "shell", "hide", TARGET)
        ipc("scenario", "disconnected")
        run("omarchy-shell", "shell", "summon", TARGET, "{}")
        wait_for(lambda state: state["opened"])
        if snapshot()["controls"]["advancedToggle"]["selected"]:
            activate("advancedToggle")
        ready = capture(directory, "01-ready")
        activate("countryPicker")
        wait_for(lambda state: state["controls"]["countryPicker"]["popupOpen"])
        run("wtype", "Spain")
        capture(directory, "02-filtered-country")
        run("wtype", "-k", "Down", "-k", "Return")
        wait_for(lambda state: state["country"] == "ES")
        assert not snapshot()["connected"], "Country selection connected without consent"
        activate("countryPicker")
        wait_for(lambda state: state["controls"]["countryPicker"]["popupOpen"])
        run("omarchy-shell", "shell", "hide", TARGET)
        run("omarchy-shell", "shell", "summon", TARGET, "{}")
        wait_for(lambda state: not state["controls"]["countryPicker"]["popupOpen"])
        activate("privacyToggle")
        wait_for(lambda state: state["controls"]["ipValue"]["text"] == "Hidden")
        capture(directory, "03-private")
        activate("privacyToggle")
        activate("copyIpButton")
        copied = True
        wait_for(lambda state: state["controls"]["copyIpButton"]["text"] == "Copied")
        assert run("wl-paste", "--no-newline").decode() == "203.0.113.42", "Clipboard did not receive the displayed IP"
        activate("advancedToggle")
        expanded = wait_for(lambda state: state["controls"]["advancedToggle"]["selected"])
        assert expanded["controls"]["connectButton"]["y"] == ready["controls"]["connectButton"]["y"], "Advanced moved the primary action"
        capture(directory, "04-advanced")
        activate("modePicker")
        run("wtype", "-k", "Down", "-k", "Return")
        wait_for(lambda state: state["mode"] == "torrent")
        activate("modePicker")
        run("wtype", "-k", "Down", "-k", "Return")
        wait_for(lambda state: state["mode"] == "streaming")
        activate("protocolPicker")
        wait_for(lambda state: state["controls"]["protocolPicker"]["popupOpen"])
        run("wtype", "-k", "Down", "-k", "Down", "-k", "Return")
        wait_for(lambda state: state["protocol"] == "openvpn_tcp")
        capture(directory, "05-streaming-tcp")
        activate("connectButton")  # Synthetic service only: no root helper exists in this fixture.
        wait_for(lambda state: state["connected"])
        capture(directory, "06-connected")
        activate("connectButton")
        wait_for(lambda state: not state["connected"])
        ipc("scenario", "narrow")
        capture(directory, "07-narrow")
        ipc("scenario", "stale")
        capture(directory, "08-stale")
        ipc("scenario", "setup")
        capture(directory, "09-setup")
        run("wtype", "-k", "Escape")
        wait_for(lambda state: not state["opened"])
        print(f"PASS: real-shell interactions and 9 synthetic-data captures. Review images in {directory}")
    finally:
        if copied:
            if clipboard is not None and mime:
                run("wl-copy", "--type", mime, data=clipboard)
            else:
                run("wl-copy", "--clear")
        run("omarchy-shell", "shell", "hide", TARGET)
        print(f"Artifacts: {directory}")


if __name__ == "__main__":
    main()
