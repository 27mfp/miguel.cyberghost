#!/usr/bin/env python3
"""Lint against installed Omarchy imports, keeping known host metadata gaps explicit."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# These are dynamic host APIs (Style.font, Color.*, injected bar / Loader.item),
# not plugin properties. Keep this narrow: a typo or a new diagnostic must fail.
HOST_MEMBERS = {
    "background",
    "barForeground",
    "body",
    "bodySmall",
    "caption",
    "close",
    "closeForPopoutSwitch",
    "display",
    "family",
    "fontFamily",
    "icon",
    "open",
    "opened",
    "popoutSwitchClosing",
    "shell",
    "switchPanelFrom",
    "text",
    "urgent",
}


def host_metadata_gap(diagnostic):
    message = diagnostic.get("message", "")
    if diagnostic.get("id") == "missing-property":
        return message in {f'Member "{member}" not found on type "QObject"' for member in HOST_MEMBERS}
    return diagnostic.get("id") == "signal-handler-parameters" and message == (
        "Type QProcess::ExitStatus of parameter exitStatus in signal called exited was not found, "
        "but is required to compile onExited. Did you add all imports and dependencies?"
    )


def main():
    shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
    if not (shell / "Ui/qmldir").is_file():
        sys.exit("Omarchy shell imports are required. Set OMARCHY_PATH to the installed Omarchy directory.")
    qtbin = Path(os.environ.get("QT_BIN", "/usr/lib/qt6/bin"))
    with tempfile.TemporaryDirectory(prefix="cyberghost-qml-") as directory:
        imports = Path(directory)
        # Quickshell maps its configuration root to qs at runtime. Standalone
        # qmllint needs that namespace explicitly; no links enter the plugin.
        (imports / "qs").symlink_to(shell, target_is_directory=True)
        report = imports / "report.json"
        result = subprocess.run(  # noqa: S603 - local Qt tool and repository-owned QML, never a shell
            [
                str(qtbin / "qmllint"),
                "--ignore-settings",
                "--json",
                str(report),
                "-I",
                str(imports),
                *map(str, sorted(ROOT.glob("*.qml"))),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if not report.exists():
            sys.exit(result.stderr or "qmllint did not produce diagnostics")
        files = json.loads(report.read_text())["files"]
        gaps = 0
        failures = []
        for file in files:
            for diagnostic in file["warnings"]:
                if diagnostic["type"] == "info":
                    continue
                if host_metadata_gap(diagnostic):
                    gaps += 1
                else:
                    failures.append(f"{Path(file['filename']).name}:{diagnostic['line']}: {diagnostic['message']}")
        # Keep full evidence available, including the acknowledged host warnings.
        with tempfile.NamedTemporaryFile("w", prefix="cyberghost-qml-lint-", suffix=".json", delete=False) as artifact:
            artifact.write(json.dumps(files, indent=2) + "\n")
            destination = artifact.name
        print(f"QML: {len(failures)} project diagnostics; {gaps} known host metadata warnings. Report: {destination}")
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
