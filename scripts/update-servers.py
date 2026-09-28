#!/usr/bin/env python3
"""Regenerate servers.json from CyberGhost's own server list.

Maintainer tool. It uses the session token saved by the panel's Link account
(~/.cyberghost/native.ini), which lasts about a day, and the same endpoint as
the official CLI (/my/servers/filters/74). Requests are paced and back off on
HTTP 429 so the account is never hammered. The output holds only public
server names, never credentials:

    python3 scripts/update-servers.py            # all countries, ~8 minutes
    python3 scripts/update-servers.py PT UA      # selected countries (merged)
"""

import datetime
import importlib.util
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(ROOT, "servers.json")
PACE_SECONDS = 5
BACKOFF_SECONDS = 60
MAX_RETRIES = 5


def load_runner():
    spec = importlib.util.spec_from_file_location("cyberghost_runner", os.path.join(ROOT, "cyberghost_runner.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fetch(runner, jwt, where, country):
    user_id, latitude, longitude = where
    path = (
        f"/my/servers/filters/74?filter_protocol=wireguard&filter_country={country}"
        f"&filter_user_id={user_id}&filter_user_latitude={latitude}&filter_user_longitude={longitude}"
    )
    for attempt in range(MAX_RETRIES):
        res = runner.api_request("GET", path, jwt=jwt, budget=30, max_bytes=runner.MAX_INVENTORY_RESPONSE_BYTES)
        if res.status_code == 200:
            data = json.loads(res._cyberghost_body.decode("utf-8"))
            # Load order is irrelevant for a snapshot; keep a stable sort.
            return sorted(runner.parse_live_inventory(data))
        if res.status_code == 429:
            wait = BACKOFF_SECONDS * (attempt + 1)
            print(f"  {country}: rate limited, waiting {wait}s", flush=True)
            time.sleep(wait)
            continue
        if res.status_code == 401:
            sys.exit("Session expired: link your account again in the panel, then rerun.")
        print(f"  {country}: HTTP {res.status_code}, skipped", flush=True)
        return None
    print(f"  {country}: still rate limited after {MAX_RETRIES} attempts, skipped", flush=True)
    return None


def main():
    runner = load_runner()
    account = runner.load_account()
    jwt = account.get("jwt", "")
    if not runner.session_usable(jwt):
        sys.exit("No valid session: link your account in the panel (Log out, then Link account), then rerun.")
    where = runner.account_location(jwt)
    if where is None:
        sys.exit("Could not read the account location that CyberGhost's server filter requires.")

    wanted = [code.upper() for code in sys.argv[1:]] or sorted(code for code in runner.CITY_MAP if code != "UK")
    snapshot = {"countries": {}}
    if os.path.exists(OUTPUT):
        with open(OUTPUT, encoding="utf-8") as existing:
            snapshot = json.load(existing)

    for index, country in enumerate(wanted):
        names = fetch(runner, jwt, where, runner.validate_country_code(country))
        if names is not None:
            snapshot["countries"][country] = runner.group_server_names(names)
            print(f"{index + 1:>3}/{len(wanted)} {country}: {len(names)} servers", flush=True)
            # Write after every country so an interruption keeps progress.
            snapshot["generated"] = datetime.date.today().isoformat()
            snapshot["source"] = "CyberGhost API /v2/my/servers/filters/74 (protocol wireguard)"
            temp = OUTPUT + ".tmp"
            with open(temp, "w", encoding="utf-8") as out:
                json.dump(snapshot, out, separators=(",", ":"), sort_keys=True)
                out.write("\n")
            os.replace(temp, OUTPUT)
        if index + 1 < len(wanted):
            time.sleep(PACE_SECONDS)


if __name__ == "__main__":
    main()
