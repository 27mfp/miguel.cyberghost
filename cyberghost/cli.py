"""Command-line entry point: argument parsing and JSON action envelopes."""

import argparse
import configparser
import contextlib
import io
import json
import signal
import sys

from .constants import ACTIONS, CITY_MAP
from .credentials import load_account
from .networkmanager import connect, disconnect, logout, status
from .server_data import sync_servers
from .server_selection import probe_servers
from .setup import check, register
from .system import OperationCancelled, _cancel_on_sigterm, clean_command_error, lifecycle_lock
from .validation import validate_request
from .vendor import get_servers_for_country, get_streaming_services


def main():
    parser = argparse.ArgumentParser(description="CyberGhost WireGuard Controller")
    parser.add_argument(
        "action",
        choices=[
            "sync-servers",
            "connect",
            "disconnect",
            "logout",
            "status",
            "check",
            "register",
            "servers",
            "streaming-services",
            "probe",
        ],
        help="Action to perform",
    )
    parser.add_argument("--country", "-c", default="PT", help="Country code (e.g. PT, ES, US, DE)")
    parser.add_argument("--server-type", "-t", default="traffic", choices=["traffic", "streaming", "torrent"])
    parser.add_argument("--protocol", default="wireguard", choices=["wireguard", "openvpn", "openvpn_tcp"])
    parser.add_argument("--city", help="Optional city name")
    parser.add_argument("--server", help="Exact CyberGhost server instance from the live inventory")
    parser.add_argument("--streaming-service", help="Streaming profile name reported by cyberghostvpn")
    parser.add_argument("--config", help="Explicit path to ~/.cyberghost/native.ini")
    parser.add_argument("--json", action="store_true", help="Output status or action result as JSON")
    parser.add_argument("--all", action="store_true", help="probe: check every supported country")

    args = None
    try:
        args = parser.parse_args()
        args = validate_request(args)
        if args.action in ACTIONS:

            def run_action():
                # A cancel (SIGTERM) becomes a normal failure: run_bounded kills
                # the running nmcli group and nm_activate rolls the profile back.
                signal.signal(signal.SIGTERM, _cancel_on_sigterm)
                with lifecycle_lock():
                    return perform_action()

            def perform_action():
                if args.action == "connect":
                    return connect(args.country, args.server_type, args.city, args.config, args.server)
                if args.action == "logout":
                    return logout()
                return disconnect()

            if args.json:
                with contextlib.redirect_stdout(io.StringIO()):
                    action_result = run_action()
                result = {"ok": True, "action": args.action}
                if isinstance(action_result, dict):
                    result.update(action_result)
                print(json.dumps(result))
            else:
                run_action()
        elif args.action == "status":
            status(args.json)
        elif args.action == "check":
            check()
        elif args.action == "register":
            register(args.config)
        elif args.action == "servers":
            print(json.dumps(get_servers_for_country(args.country, args.server_type)))
        elif args.action == "streaming-services":
            print(json.dumps(get_streaming_services(args.country)))
        elif args.action == "sync-servers":
            print(json.dumps(sync_servers()))
        elif args.action == "probe":
            codes = sorted(code for code in CITY_MAP if code != "UK") if args.all else [args.country]
            try:
                session = load_account(args.config)
            except (OSError, RuntimeError, configparser.Error):
                session = None
            report = probe_servers(codes, session)
            if args.json:
                print(json.dumps(report))
            else:
                for code, entry in report.items():
                    hosts = entry["reachable"]
                    state = f"{len(hosts)} reachable, fastest {hosts[0]}" if hosts else "NO REACHABLE SERVERS"
                    if entry.get("no_wireguard"):
                        state = "no WireGuard servers listed by CyberGhost"
                    else:
                        state += f" ({entry['known']} known)" if entry.get("known") else " (guessed pool)"
                    if "live" in entry:
                        live = entry["live"]
                        state += f" | live API: {len(live)} servers" + (f", lowest load {live[0]}" if live else "")
                    print(f"{code}  {entry['city'] or '-':<14} {state}")
    except (OperationCancelled, Exception) as e:
        if args is not None and args.json and args.action in ACTIONS:
            print(
                json.dumps(
                    {
                        "ok": False,
                        "action": args.action,
                        "error": clean_command_error(e),
                        "code": getattr(e, "code", ""),
                    }
                )
            )
        else:
            sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)
