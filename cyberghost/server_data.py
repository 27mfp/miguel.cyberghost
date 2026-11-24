"""Server inventory, per-user cache and login-session metadata."""

import base64
import binascii
import configparser
import fcntl
import json
import os
import random
import re
import stat
import sys
import tempfile
import time

from .constants import (
    CITY_MAP,
    LIVE_INVENTORY_BUDGET_SECONDS,
    MAX_INVENTORY_RESPONSE_BYTES,
    MAX_SERVER_LIST_BYTES,
    PROBE_SAMPLE_SIZE,
    SERVER_CACHE_RELATIVE_PATH,
    SYNC_BACKOFF_SECONDS,
    SYNC_LOCK_RELATIVE_PATH,
    SYNC_PACE_SECONDS,
    SYNC_REFRESH_SECONDS,
    SYNC_STATE_RELATIVE_PATH,
)
from .credentials import load_account
from .system import clean_command_error, invoking_user, response_json, user_file_lock
from .transport import api_request
from .validation import validate_country_code, validate_server_selector


def group_server_names(names):
    """{"lisbon-s405": [1, 2, ...]}: the compact form used on disk."""
    grouped = {}
    for name in names:
        prefix, _, instance = name.rpartition("-i")
        grouped.setdefault(prefix, []).append(int(instance))
    return {prefix: sorted(set(numbers)) for prefix, numbers in sorted(grouped.items())}


def expand_server_names(grouped, limit=20000):
    """Inverse of group_server_names; every name is strictly validated."""
    names = []
    if not isinstance(grouped, dict):
        return names
    for prefix, numbers in grouped.items():
        if not isinstance(prefix, str) or not isinstance(numbers, list):
            continue
        for number in numbers:
            if isinstance(number, bool) or not isinstance(number, int) or not 0 <= number < 10000:
                continue
            try:
                names.append(validate_server_selector(f"{prefix}-i{number:02d}"))
            except ValueError:
                continue
            if len(names) >= limit:
                return names
    return names


def _read_server_list(path):
    try:
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_SERVER_LIST_BYTES:
            return {}
        with open(path, encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, UnicodeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def server_cache_path():
    return os.path.join(invoking_user().pw_dir, SERVER_CACHE_RELATIVE_PATH)


def known_servers(country_code):
    """Real server names for a country from the user's cache.

    None means the country has not been fetched yet; an empty list means
    CyberGhost listed no WireGuard servers there. Entries never expire:
    names drift slowly and every connect probes them before use.
    """
    cc = validate_country_code(country_code)
    countries = _read_server_list(server_cache_path()).get("countries")
    if not isinstance(countries, dict):
        return None
    cached = countries.get(cc)
    if not isinstance(cached, dict) or not isinstance(cached.get("servers"), dict):
        return None
    return expand_server_names(cached["servers"])


def remember_servers(country_code, names):
    """Best-effort: keep the latest live list so later fallbacks stay current."""
    path = server_cache_path()
    temp_name = None
    try:
        directory = os.path.dirname(path)
        os.makedirs(directory, mode=0o700, exist_ok=True)
        with user_file_lock(path + ".lock"):
            data = _read_server_list(path)
            countries = data.get("countries") if isinstance(data.get("countries"), dict) else {}
            countries[validate_country_code(country_code)] = {
                "updated": int(time.time()),
                "servers": group_server_names(names),
            }
            with tempfile.NamedTemporaryFile(
                "w", dir=directory, delete=False, prefix=".servers_", encoding="utf-8"
            ) as tf:
                temp_name = tf.name
                json.dump({"countries": countries}, tf, separators=(",", ":"))
            os.replace(temp_name, path)
            temp_name = None
    except (OSError, ValueError, RuntimeError):
        pass
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def is_nospy(name):
    # NoSpy servers are a separately sold add-on; use them only as a last choice.
    return name.startswith("nospy")


def probe_sample(names, size=PROBE_SAMPLE_SIZE):
    """Spread a probe across cities and racks, randomly within each."""
    regular = [name for name in names if not is_nospy(name)]
    names = regular or names
    by_prefix = {}
    for name in names:
        by_prefix.setdefault(name.rpartition("-i")[0], []).append(name)
    queues = list(by_prefix.values())
    for queue in queues:
        random.shuffle(queue)
    random.shuffle(queues)
    sample = []
    while queues and len(sample) < size:
        for queue in list(queues):
            if queue:
                sample.append(queue.pop())
            if not queue:
                queues.remove(queue)
            if len(sample) >= size:
                break
    return sample


def jwt_expiry(jwt):
    """Return the token's `exp` (epoch seconds) without verifying it, or None."""
    try:
        payload = jwt.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        expiry = claims.get("exp") if isinstance(claims, dict) else None
        return int(expiry) if isinstance(expiry, (int, float)) and not isinstance(expiry, bool) else None
    except (IndexError, ValueError, TypeError, UnicodeError, binascii.Error):
        return None


def _session_fingerprint(jwt):
    import hashlib

    return hashlib.sha256(jwt.encode("utf-8")).hexdigest()[:32]


def reject_session(jwt):
    """Remember that CyberGhost refused this token (401), even without an exp."""
    path = _sync_state_path()
    try:
        state = _read_server_list(path)
        state["rejected_session"] = _session_fingerprint(jwt)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "w", dir=os.path.dirname(path), delete=False, prefix=".sync_", encoding="utf-8"
        ) as tf:
            json.dump(state, tf)
            temp_name = tf.name
        os.replace(temp_name, path)
    except OSError:
        pass


def session_usable(jwt, now=None):
    if not jwt:
        return False
    if _read_server_list(_sync_state_path()).get("rejected_session") == _session_fingerprint(jwt):
        return False
    expiry = jwt_expiry(jwt)
    return expiry is None or expiry > (now if now is not None else time.time()) + 60


def account_user_id(jwt):
    """Best-effort numeric account id, which CyberGhost's server filters accept."""
    try:
        res = api_request("GET", "/my/account?fields=(id)&language=en", jwt=jwt, budget=10)
        user_id = str(response_json(res).get("id", "")) if res.status_code == 200 else ""
    except (OSError, RuntimeError, ValueError):
        return ""
    return user_id if user_id.isdigit() else ""


def _number(value):
    """Accept JSON numbers or numeric strings; None for anything else."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    # Signed (coordinates: Lisbon is at -9.13) with up to a float repr's digits.
    if isinstance(value, str) and re.fullmatch(r"-?\d{1,9}(?:\.\d{1,20})?", value.strip()):
        return float(value)
    return None


def account_location(jwt):
    """User id plus CyberGhost's IP-based location, which its server filter requires."""
    return account_location_status(jwt)[1]


def account_location_status(jwt):
    """(HTTP status, location or None), so callers can react to 401/429."""
    res = api_request(
        "GET", "/my/account?fields=(id,location)&language=en", jwt=jwt, budget=LIVE_INVENTORY_BUDGET_SECONDS
    )
    if res.status_code == 401:
        reject_session(jwt)
    if res.status_code != 200:
        return res.status_code, None
    data = response_json(res)
    location = data.get("location") if isinstance(data.get("location"), dict) else {}
    latitude, longitude = _number(str(location.get("latitude", ""))), _number(str(location.get("longitude", "")))
    user_id = str(data.get("id", ""))
    if latitude is None or longitude is None or not user_id.isdigit():
        return res.status_code, None
    return res.status_code, (user_id, latitude, longitude)


def parse_live_inventory(data, max_items=8192):
    """Collect instance names and load from CyberGhost's server-filter response.

    The layout is not documented, so walk the JSON (bounded) and accept only
    values that pass the same strict selector validation as the addKey path.
    """
    found = {}
    stack = [(data, 0)]
    visited = 0
    while stack and visited < 4 * max_items:
        node, depth = stack.pop()
        visited += 1
        if depth > 6:
            continue
        if isinstance(node, list):
            stack.extend((item, depth + 1) for item in node[:max_items])
        elif isinstance(node, dict):
            name = None
            for key in ("instance", "real", "name", "displayName", "hostname"):
                value = node.get(key)
                if isinstance(value, str):
                    candidate = value.strip().lower()
                    if candidate.endswith(".cg-dialup.net"):
                        candidate = candidate[: -len(".cg-dialup.net")]
                    # Some display names drop the rack's "s" ("Nairobi-401-i01")
                    # while DNS keeps it (nairobi-s401-i01.cg-dialup.net).
                    candidate = re.sub(r"^([a-z0-9]+(?:-[a-z0-9]+)*?)-(\d+)-i(\d+)$", r"\1-s\2-i\3", candidate)
                    try:
                        name = validate_server_selector(candidate)
                        break
                    except ValueError:
                        continue
            # CyberGhost sends counts as strings ("17") and marks capacity with
            # full="1"; a full server would only reject the key exchange.
            if name and str(node.get("full", "0")).strip() != "1":
                users, capacity = _number(node.get("totalusers")), _number(node.get("Max_Users"))
                load = 100.0
                if users is not None and users >= 0 and capacity and capacity > 0:
                    load = max(0.0, min(100.0, 100.0 * users / capacity))
                found[name] = min(load, found.get(name, 100.0))
            stack.extend((value, depth + 1) for value in node.values() if isinstance(value, (list, dict)))
    return sorted(found, key=lambda host: (is_nospy(host), found[host], host))


def fetch_country_servers(country_code, jwt, where):
    """One filters/74 request. Returns (HTTP status, names or None).

    names is [] only when CyberGhost returned an empty list, which means the
    country has no WireGuard servers; any other unusable body is None.
    """
    cc = validate_country_code(country_code)
    user_id, latitude, longitude = where
    path = (
        f"/my/servers/filters/74?filter_protocol=wireguard&filter_country={cc}"
        f"&filter_user_id={user_id}&filter_user_latitude={latitude}&filter_user_longitude={longitude}"
    )
    res = api_request(
        "GET", path, jwt=jwt, budget=LIVE_INVENTORY_BUDGET_SECONDS, max_bytes=MAX_INVENTORY_RESPONSE_BYTES
    )
    if res.status_code != 200:
        return res.status_code, None
    try:
        data = json.loads(getattr(res, "_cyberghost_body", b"").decode("utf-8"))
    except (UnicodeError, ValueError):
        return res.status_code, None
    if not isinstance(data, list):
        return res.status_code, None
    names = parse_live_inventory(data)
    if data and not names:
        return res.status_code, None  # rows we could not read: not "no servers"
    return res.status_code, names


def live_server_inventory(country_code, session):
    """CyberGhost's own server list for a country, lowest load first, or None."""
    jwt = (session or {}).get("jwt", "")
    if not session_usable(jwt):
        return None
    cc = validate_country_code(country_code)
    try:
        # The filter rejects requests without the user's coordinates. They are
        # fetched per request: IP-based, so they move with the network.
        where = account_location(jwt)
        if where is None:
            sys.stderr.write("Live server list unavailable (no account location); probing servers instead.\n")
            return None
        status_code, names = fetch_country_servers(cc, jwt, where)
    except (OSError, RuntimeError, ValueError) as exc:
        sys.stderr.write(f"Live server list unavailable: {clean_command_error(exc)}\n")
        return None
    if status_code == 401:
        reject_session(jwt)
    if names is None:
        # 401: session expired; 429: rate limited. The fallback still connects.
        sys.stderr.write(f"Live server list unavailable (HTTP {status_code}); probing servers instead.\n")
        return None
    remember_servers(cc, names)
    return names or None


def _sync_state_path():
    return os.path.join(invoking_user().pw_dir, SYNC_STATE_RELATIVE_PATH)


def _sync_blocked_until():
    until = _read_server_list(_sync_state_path()).get("blocked_until")
    return until if isinstance(until, (int, float)) and not isinstance(until, bool) else 0


def _block_sync(seconds, now):
    """Remember a backoff so repeated panel opens cannot restart a limited sync."""
    path = _sync_state_path()
    try:
        state = _read_server_list(path)
        state["blocked_until"] = int(now + seconds)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "w", dir=os.path.dirname(path), delete=False, prefix=".sync_", encoding="utf-8"
        ) as tf:
            json.dump(state, tf)
            temp_name = tf.name
        os.replace(temp_name, path)
    except OSError:
        pass


def _session_still_current(jwt):
    """Stop syncing once the user logs out or links a different session."""
    try:
        return load_account(None)["jwt"] == jwt
    except (OSError, RuntimeError, configparser.Error):
        return False


def sync_servers(country_codes=None, pace=SYNC_PACE_SECONDS, refresh=SYNC_REFRESH_SECONDS, now=None):
    """Fill the user's cache from their own account, one country at a time.

    Paced to stay under CyberGhost's rate limit. A 429 or 401 stops the run and
    records a backoff, so reopening the panel cannot keep the account limited.
    Countries refreshed recently are skipped; a failed country is retried on a
    later run. The run also stops as soon as the login it started with is gone.
    """

    def result(synced=0, failed=0, remaining=None, stopped=""):
        return {"synced": synced, "failed": failed, "remaining": remaining, "stopped": stopped}

    try:
        account = load_account(None)
    except (OSError, RuntimeError, configparser.Error):
        return result(stopped="no account")
    jwt = account["jwt"]
    if not session_usable(jwt):
        return result(stopped="no session")
    clock = now if now is not None else time.time()
    if _sync_blocked_until() > clock:
        return result(stopped="backing off")
    lock_path = os.path.join(invoking_user().pw_dir, SYNC_LOCK_RELATIVE_PATH)
    os.makedirs(os.path.dirname(lock_path), mode=0o700, exist_ok=True)
    lock = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
    synced = failed = 0
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return result(stopped="already running")
        codes = country_codes or sorted(code for code in CITY_MAP if code != "UK")
        cached = _read_server_list(server_cache_path()).get("countries", {})
        todo = []
        for code in codes:
            entry = cached.get(code) if isinstance(cached, dict) else None
            updated = entry.get("updated") if isinstance(entry, dict) else None
            if not isinstance(updated, (int, float)) or clock - updated > refresh:
                todo.append(code)
        if not todo:
            return result(remaining=0)
        try:
            location_status, where = account_location_status(jwt)
        except (OSError, RuntimeError, ValueError) as exc:
            return result(remaining=len(todo), stopped=clean_command_error(exc))
        if location_status in (401, 429):
            _block_sync(SYNC_BACKOFF_SECONDS[location_status], time.time())
            return result(remaining=len(todo), stopped=f"HTTP {location_status}")
        if where is None:
            return result(remaining=len(todo), stopped="no location")
        for index, code in enumerate(todo):
            if not _session_still_current(jwt):
                return result(synced, failed, len(todo) - index, "logged out")
            try:
                status_code, names = fetch_country_servers(code, jwt, where)
            except (OSError, RuntimeError, ValueError):
                # A timeout or reset on one country must not end the run.
                status_code, names = None, None
            if status_code in (401, 429):
                if status_code == 401:
                    reject_session(jwt)
                _block_sync(SYNC_BACKOFF_SECONDS[status_code], time.time())
                return result(synced, failed, len(todo) - index, f"HTTP {status_code}")
            if names is None:
                failed += 1  # unreadable or failed: retried on a later run
            else:
                remember_servers(code, names)
                synced += 1
            # Progress counts attempts, so it always reaches the total.
            print(json.dumps({"progress": index + 1, "total": len(todo), "country": code}), flush=True)
            if index + 1 < len(todo):
                time.sleep(pace)
        return result(synced, failed, 0)
    except (OSError, RuntimeError, ValueError) as exc:
        return result(synced, failed, None, clean_command_error(exc))
    finally:
        os.close(lock)
