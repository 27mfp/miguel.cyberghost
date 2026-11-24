"""Optional read-only inventory through the official CyberGhost CLI.

Every function returns an empty result when the CLI is absent or unusable;
native connection does not depend on the vendor binary.
"""

import re
import subprocess
import sys

from .constants import CITY_MAP
from .system import clean_command_error, run_bounded, system_binary
from .validation import validate_country_code, validate_server_selector, validate_streaming_service


def get_servers_for_country(country_code, server_type="traffic"):
    """
    Query the real server instances for a country if cyberghostvpn is present.

    The CLI returns only an aggregate ``Instance 50`` row when called with a
    country alone. Asking for the mapped city returns the actual selectable
    names (for example ``lisbon-s405-i19``) and their current load. Treating
    the aggregate value as a hostname was the reason the native path skipped
    the best servers and fell back to stale static candidates.

    Returns [] when the CLI is unavailable or output cannot be parsed.
    """
    cc = validate_country_code(country_code)
    st = "traffic" if server_type not in ("torrent", "streaming") else server_type
    try:
        cmd = [system_binary("cyberghostvpn"), f"--{st}", "--country-code", cc]
        city_slug = CITY_MAP.get(cc)
        if city_slug:
            cmd += ["--city", city_slug]
        res = run_bounded(
            cmd,
            timeout=5,
            max_output_bytes=16 * 1024,
        )

        if res.returncode != 0:
            detail = clean_command_error(res.stderr or res.stdout, f"cyberghostvpn exited with code {res.returncode}")
            raise RuntimeError(detail)

        servers = []
        seen = set()
        for line in (res.stdout or "").splitlines()[:256]:
            match = re.match(r"\|\s*(\d+)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(\d+)%\s*\|\s*$", line)
            if not match:
                continue
            city = match.group(2).strip()[:64]
            instance = match.group(3).strip()[:128]
            try:
                server = validate_server_selector(instance)
            except ValueError:
                continue
            load = int(match.group(4))
            if load > 100 or server in seen:
                continue
            seen.add(server)
            servers.append({"city": city, "instance": server, "server": server, "load": load})
        if not servers:
            raise RuntimeError(
                "No selectable servers returned by CyberGhost CLI. Automatic selection remains available."
            )
        servers.sort(key=lambda item: (item["load"], item["server"]))
        return servers
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as exc:
        message = clean_command_error(exc, "server inventory unavailable")
        sys.stderr.write(f"Server inventory unavailable for {cc}: {message}\n")
        return []


def get_streaming_services(country_code):
    """Return streaming profiles reported by the official CLI for a country."""
    cc = validate_country_code(country_code)
    try:
        res = run_bounded(
            [system_binary("cyberghostvpn"), "--streaming", "--country-code", cc],
            timeout=8,
            max_output_bytes=32 * 1024,
        )
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as exc:
        message = clean_command_error(exc, "streaming service discovery unavailable")
        sys.stderr.write(f"Streaming service discovery unavailable for {cc}: {message}\n")
        return []

    services = []
    if res.returncode != 0:
        message = clean_command_error(res.stderr or res.stdout, f"cyberghostvpn exited with code {res.returncode}")
        sys.stderr.write(f"Streaming service discovery unavailable for {cc}: {message}\n")
        return services
    for line in (res.stdout or "").splitlines()[:256]:
        match = re.match(r"\|\s*\d+\s*\|\s*(.*?)\s*\|\s*([A-Z]{2})\s*\|", line)
        if not match:
            continue
        name = match.group(1).strip()
        service_country = match.group(2)
        if not name or service_country != cc:
            continue
        try:
            safe_name = validate_streaming_service(name)
        except ValueError:
            continue
        # SearchableDropdown renders labels through the shell's shared Text
        # component; keep display text inert even if a third-party CLI emits
        # angle brackets while preserving the exact argv value.
        display_name = safe_name.replace("<", "[").replace(">", "]")
        services.append({"value": safe_name, "label": display_name})
    return services
