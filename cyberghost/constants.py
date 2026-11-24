"""Release constants and the CyberGhost country/city tables.

These tables are also represented in ``Countries.js`` for the QML selector;
``tests/test_contracts.py`` enforces that both sides stay in sync. Changing a
country here without updating the frontend (or vice versa) fails the suite.
"""

import os
import uuid

INTERFACE = "cyberghost"
NM_CONNECTION_NAME = "CyberGhost VPN"
# Fixed namespace for the per-user profile UUID (see connection_uuid()).
NM_UUID_NAMESPACE = uuid.UUID("0b5c3f7e-9a61-4d2e-8f3b-6c1d2a7e4b90")
NM_DNS_PRIORITY = -50
NM_REQUIRED_PERMISSIONS = ("network-control", "settings.modify.own")
NMCLI_NOT_FOUND = 10
# Pre-1.7 releases installed these; they are detected only to offer removal.
LEGACY_HELPER_PATH = "/usr/local/bin/cyberghost-runner"
LEGACY_POLKIT_RULE_PATH = "/etc/polkit-1/rules.d/50-cyberghost.rules"
LEGACY_POLKIT_MARKER_RELATIVE_PATH = os.path.join(".local", "state", "cyberghost", "polkit-rule-installed")
LEGACY_POLKIT_MARKER_CONTENT = "cyberghost-polkit-rule-v1"
PLUGIN_VERSION = "1.8.0"
MAX_CONFIG_BYTES = 64 * 1024
MAX_HTTP_RESPONSE_BYTES = 64 * 1024
MAX_SUBPROCESS_INPUT_BYTES = 64 * 1024
MAX_SUBPROCESS_OUTPUT_BYTES = 64 * 1024
NATIVE_CONNECT_BUDGET_SECONDS = 120
ACCOUNT_API_BUDGET_SECONDS = 30
MAX_NATIVE_CANDIDATES = 12
ACTIONS = {"connect", "disconnect", "logout"}

# CyberGhost account/device API — endpoints and the app key below are the same
# ones embedded in the official cyberghostvpn CLI (verified against its 1.4.1 build).
API_BASE = "https://v2-api.cyberghostvpn.com/v2"
DEFAULT_API_KEY = "QzgDsDNUXlgF9jehkTHHtBJwwI4RyInkZQDRJfLyz"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36"
)

# Country Code -> Primary CyberGhost city slug.
# Mirrors the country list in Countries.js — keep both in sync
# (tests/test_validation.py enforces coverage). A wrong/unknown slug fails
# cleanly with a connection error, it can never connect somewhere else.
CITY_MAP = {
    "AD": "andorra",
    "AE": "dubai",
    "AL": "tirana",
    "AM": "yerevan",
    "AR": "buenosaires",
    "AT": "vienna",
    "AU": "sydney",
    "BA": "sarajevo",
    "BD": "dhaka",
    "BE": "brussels",
    "BG": "sofia",
    "BO": "lapaz",
    "BR": "saopaulo",
    "BS": "nassau",
    "BY": "minsk",
    "CA": "montreal",
    "CH": "zurich",
    "CL": "santiago",
    "CN": "hongkong",
    "CO": "bogota",
    "CR": "sanjose",
    "CY": "nicosia",
    "CZ": "prague",
    "DE": "frankfurt",
    "DK": "copenhagen",
    "DO": "santodomingo",
    "DZ": "algiers",
    "EC": "quito",
    "EE": "tallinn",
    "EG": "cairo",
    "ES": "madrid",
    "FI": "helsinki",
    "FR": "paris",
    "GB": "london",
    "UK": "london",  # legacy alias
    "GE": "tbilisi",
    "GL": "nuuk",
    "GR": "athens",
    "GT": "guatemalacity",
    "HK": "hongkong",
    "HR": "zagreb",
    "HU": "budapest",
    "ID": "jakarta",
    "IE": "dublin",
    "IL": "telaviv",
    "IM": "douglas",
    "IN": "mumbai",
    "IR": "tehran",
    "IS": "reykjavik",
    "IT": "milan",
    "JP": "tokyo",
    "KE": "nairobi",
    "KH": "phnompenh",
    "KR": "seoul",
    "KZ": "almaty",
    "LA": "vientiane",
    "LI": "vaduz",
    "LK": "colombo",
    "LT": "vilnius",
    "LU": "luxembourg",
    "LV": "riga",
    "MA": "casablanca",
    "MC": "monaco",
    "MD": "chisinau",
    "ME": "podgorica",
    "MK": "skopje",
    "MT": "valletta",
    "MX": "mexicocity",
    "MY": "kualalumpur",
    "NG": "lagos",
    "NL": "amsterdam",
    "NO": "oslo",
    "NZ": "auckland",
    "PA": "panamacity",
    "PH": "manila",
    "PK": "karachi",
    "PL": "warsaw",
    "PT": "lisbon",
    "QA": "doha",
    "RO": "bucharest",
    "RS": "belgrade",
    "SA": "riyadh",
    "SE": "stockholm",
    "SG": "singapore",
    "SI": "ljubljana",
    "SK": "bratislava",
    "TH": "bangkok",
    "TR": "istanbul",
    "TW": "taipei",
    "UA": "kyiv",
    "US": "newyork",
    "UY": "montevideo",
    "VE": "caracas",
    "VN": "hanoi",
    "ZA": "johannesburg",
}

# The vendor's city spelling and its dialup hostname prefix are not always the
# same. Keep CITY_MAP suitable for CLI inventory queries, and override only the
# endpoint prefix where the live DNS differs. Verified by resolving and
# TLS-checking the nodes (see `probe`): Ukraine serves kiev-*, Italy milano-*
# (also rome-*), Israel jerusalem-*, Kazakhstan astana-* and Morocco rabat-*.
DIALUP_CITY_MAP = {
    **CITY_MAP,
    "UA": "kiev",
    "IT": "milano",
    "IL": "jerusalem",
    "KZ": "astana",
    "MA": "rabat",
    # From CyberGhost's own server list: Bosnia is served from Travnik
    # and China from Shenzhen (the old "hongkong" guess landed in Hong Kong).
    "BA": "travnik",
    "CN": "shenzhen",
}

# Without the vendor CLI there is no live inventory. Rather than trusting a
# few fixed racks (dead racks stall connect; many countries use others), probe
# this pool and try only hosts that answer, fastest first. Racks seen live
# range from 401 to 418.
DIALUP_RACKS = tuple(range(401, 421))
DIALUP_INSTANCES = ("01", "02", "03")
ENDPOINT_PROBE_BUDGET_SECONDS = 4.0
ENDPOINT_PROBE_TIMEOUT_SECONDS = 2.5
ENDPOINT_PROBE_GRACE_SECONDS = 1.0
LIVE_INVENTORY_BUDGET_SECONDS = 6
# Real server names live in a per-user cache built from the user's own
# account: connects refresh their country, and a paced background sync fills
# every country while the login session (about a day) is valid. Nothing is
# bundled or shared between users.
SERVER_CACHE_RELATIVE_PATH = os.path.join(".cache", "cyberghost", "servers.json")
SYNC_LOCK_RELATIVE_PATH = os.path.join(".cache", "cyberghost", "sync.lock")
SYNC_PACE_SECONDS = 5
SYNC_REFRESH_SECONDS = 7 * 86400
SYNC_STATE_RELATIVE_PATH = os.path.join(".cache", "cyberghost", "sync-state.json")
LIFECYCLE_LOCK_RELATIVE_PATH = os.path.join(".cache", "cyberghost", "lifecycle.lock")
LIFECYCLE_LOCK_WAIT_SECONDS = 30
# After a rate limit or rejected session, wait before any automatic restart.
SYNC_BACKOFF_SECONDS = {429: 15 * 60, 401: 60 * 60}
MAX_SERVER_LIST_BYTES = 2 * 1024 * 1024
# Probing every known server of a large country would be slow and noisy.
PROBE_SAMPLE_SIZE = 48
# About 500 bytes per server; the largest countries list a few thousand.
MAX_INVENTORY_RESPONSE_BYTES = 4 * 1024 * 1024

_HANDSHAKE_UNITS = {"second": 1, "minute": 60, "hour": 3600, "day": 86400}
