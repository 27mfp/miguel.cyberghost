"""Repository hygiene: screenshot names, preview sync and image references."""

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parents[1]
SCREENSHOTS = ROOT / "docs" / "screenshots"


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_preview_is_the_documented_connected_screenshot():
    # manifest.json does not name preview.png, but the marketplace uses the
    # repository-root image. scripts/sync-preview.py owns the link.
    assert _digest(ROOT / "preview.png") == _digest(SCREENSHOTS / "screenshot-connected.png")


def test_sync_preview_check_command_passes():
    result = subprocess.run(  # noqa: S603 - repository-owned read-only check
        [sys.executable, str(ROOT / "scripts/sync-preview.py"), "--check"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_screenshot_names_are_kebab_case():
    for path in SCREENSHOTS.glob("*.png"):
        assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*\.png", path.name), path.name


def test_readme_and_docs_image_references_exist():
    documents = [ROOT / "README.md", *sorted((ROOT / "docs").rglob("*.md"))]
    references = []
    for document in documents:
        text = document.read_text()
        for reference in re.findall(r'(?:src="|!\[[^\]]*\]\()((?:docs/)?[^")\s]+\.png)', text):
            references.append((document, reference))
    assert references, "expected at least one documented screenshot"
    for document, reference in references:
        assert (ROOT / reference).is_file(), f"{document}: missing image {reference}"


def test_manifest_version_is_the_unreleased_changelog_section():
    version = json.loads((ROOT / "manifest.json").read_text())["version"]
    changelog = (ROOT / "CHANGELOG.md").read_text()
    assert f"## {version}" in changelog
    assert (ROOT / "icon.png").is_file()
    assert (ROOT / "icon.svg").is_file()
