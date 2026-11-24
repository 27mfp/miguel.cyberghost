"""Onboarding: native account linking and readiness reporting."""

import configparser
import importlib.util
import json
import os
import socket
import sys

from .constants import (
    LEGACY_HELPER_PATH,
    LEGACY_POLKIT_RULE_PATH,
    PLUGIN_VERSION,
)
from .credentials import (
    cli_account_configured,
    load_account,
    validate_user_config_path,
    write_user_config,
)
from .networkmanager import _interface_state, nm_active_state, nm_available, nm_permission
from .server_data import account_user_id, session_usable
from .system import (
    lifecycle_lock,
    response_json,
    secure_system_file,
    system_binary,
    system_binary_available,
    user_polkit_marker_installed,
)
from .transport import api_request, build_device_payload, build_login_payload


def register(config_path=None):
    """Serialize account publication with connect, disconnect and logout."""
    try:
        with lifecycle_lock():
            return _register(config_path)
    finally:
        os.environ.pop("CG_USERNAME", None)
        os.environ.pop("CG_PASSWORD", None)


def _register(config_path=None):
    """Link a CyberGhost account natively — no cyberghostvpn CLI required.

    Credentials come from CG_USERNAME/CG_PASSWORD (used by the GUI so they
    never appear in argv) or from interactive prompts. The env vars are
    popped immediately so they never outlive this call — register() is the
    only path that should ever see them, and a child subprocess started
    later must not inherit them by accident.
    """
    import getpass

    # Pop the credentials from os.environ before any other code can read
    # them. A caller (the GUI's panel) sets them only for this call; if we
    # left them in os.environ, a later subprocess.Popen would inherit them
    # by default and an exception traceback captured for the panel could
    # echo them back. Clearing here keeps the secret in local variables.
    env_username = os.environ.pop("CG_USERNAME", "")
    env_password = os.environ.pop("CG_PASSWORD", "")
    try:
        target = validate_user_config_path(config_path)
        if os.path.basename(target) == "config.ini":
            raise RuntimeError(
                "Native registration cannot overwrite the vendor CLI config. Use ~/.cyberghost/native.ini."
            )
        # Fail closed if ownership/state cannot be verified. Account replacement
        # must never silently leave a tunnel authenticated by the previous login.
        state = nm_active_state()
        link = _interface_state(system_binary("ip"))
        if link is None:
            raise RuntimeError("Could not verify VPN state. Recheck setup before linking an account.")
        if state or link:
            raise RuntimeError("Disconnect the VPN before linking or refreshing your CyberGhost account.")
        username = env_username.strip()[:256]
        password = env_password[:256]
        if not username or not password:
            try:
                if not sys.stdin.isatty():
                    credentials_line = sys.stdin.readline(4096)
                    if credentials_line:
                        credentials = json.loads(credentials_line)
                        username = username or str(credentials.get("username", "")).strip()[:256]
                        password = password or str(credentials.get("password", ""))[:256]
            except (OSError, UnicodeError, json.JSONDecodeError, AttributeError):
                pass
        if not username or not password:
            username = username or input("CyberGhost username: ").strip()[:256]
            password = password or getpass.getpass("CyberGhost password: ")[:256]
        if not username or not password:
            raise RuntimeError("Username and password are required.")
        device_name = (os.environ.get("CG_DEVICE_NAME") or socket.gethostname() or "linux-app").strip()[
            :64
        ] or "linux-app"

        print("Authenticating ...")
        res = api_request("POST", "/my/account/jwt?language=en", build_login_payload(username, password))
        if res.status_code != 200:
            raise RuntimeError(
                f"Authentication failed (HTTP {res.status_code}). Check your CyberGhost account credentials."
            )
        jwt = response_json(res).get("jwt")
        if not jwt:
            raise RuntimeError("Authentication response did not contain a session token.")

        print(f"Registering device '{device_name}' ...")
        res = api_request("POST", "/my/devices", build_device_payload(device_name), jwt=jwt)
        if res.status_code != 201:
            detail = ""
            try:
                body = response_json(res)
                detail = str(body.get("errorMessage") or body.get("errorCode") or "")[:256]
            except (RuntimeError, TypeError, ValueError, UnicodeError):
                pass
            raise RuntimeError(f"Device registration failed (HTTP {res.status_code}). {detail}".strip())
        device = response_json(res)
        if not device.get("token"):
            raise RuntimeError("Device registration response missing token.")

        # Publish the device immediately. Optional account metadata must not
        # delay saving credentials for a device already created remotely.
        session = {"jwt": jwt}
        write_user_config(target, username, device_name, device, session=session)
        user_id = account_user_id(jwt)
        if user_id:
            session["user_id"] = user_id
            try:
                write_user_config(target, username, device_name, device, session=session)
            except (OSError, RuntimeError):
                # The first atomic write already stored usable credentials.
                # Optional metadata failure must not encourage another device registration.
                print("Optional account metadata could not be saved; device credentials are already stored.")
        print(f"Account linked. Device credentials stored in {target}")
    finally:
        # Defense in depth: drop the local copies and re-clear the env vars
        # in case any inner code path re-set them while we were running.
        username = ""
        password = ""
        env_username = ""
        env_password = ""
        os.environ.pop("CG_USERNAME", None)
        os.environ.pop("CG_PASSWORD", None)


def check():
    """Report onboarding readiness as JSON (fast, no heavy imports)."""
    result = {
        "nm": nm_available(),
        "nm_permission": nm_permission(),
        "requests": importlib.util.find_spec("requests") is not None,
        "cli": system_binary_available("cyberghostvpn"),
        "cli_configured": cli_account_configured(),
        "credentials": False,
        # Display only; privacy mode masks it in the panel.
        "account": "",
        "account_source": "",
        # "live": CyberGhost's own server list is used; "probe": fallback.
        "server_list": "",
        # Pre-1.7 installs placed a root helper and an optional Polkit rule.
        # They are no longer used and can be removed from the setup panel.
        "legacy_helper": secure_system_file(LEGACY_HELPER_PATH, executable=True),
        "legacy_polkit_rule": secure_system_file(LEGACY_POLKIT_RULE_PATH) or user_polkit_marker_installed(),
        "plugin_version": PLUGIN_VERSION,
    }
    try:
        account = load_account(None)
        result.update(credentials=True, account=account["username"], account_source=account["source"])
        result["server_list"] = "live" if session_usable(account["jwt"]) else "probe"
    except (OSError, RuntimeError, configparser.Error):
        pass
    print(json.dumps(result))
