"""Account state on disk: private native credentials and vendor-CLI compat.

The plugin only ever writes ``~/.cyberghost/native.ini``. The vendor CLI's
``config.ini`` is read for compatibility and never modified or deleted.
"""

import configparser
import os
import stat
import tempfile

from .constants import MAX_CONFIG_BYTES
from .system import invoking_user
from .validation import validate_api_credential, validate_config_text


def find_config_path(override_path=None):
    if override_path:
        return os.path.abspath(os.path.expanduser(override_path))

    env_override = os.environ.get("CYBERGHOST_CONFIG")
    if env_override:
        return os.path.abspath(os.path.expanduser(env_override))

    return user_config_path()


def user_config_path():
    return os.path.join(invoking_user().pw_dir, ".cyberghost", "native.ini")


def legacy_config_path():
    return os.path.join(invoking_user().pw_dir, ".cyberghost", "config.ini")


def validate_user_config_path(path):
    """Keep account state inside the invoking user's private CyberGhost directory."""
    expected = os.path.abspath(user_config_path())
    candidate = os.path.abspath(os.path.expanduser(path or expected))
    if os.path.commonpath((candidate, os.path.dirname(expected))) != os.path.dirname(expected):
        raise RuntimeError("Configuration path must stay inside ~/.cyberghost")
    if os.path.basename(candidate) not in ("native.ini", "config.ini"):
        raise RuntimeError("Configuration path must be ~/.cyberghost/native.ini or the legacy config.ini")
    config_dir = os.path.dirname(candidate)
    if os.path.lexists(config_dir) and os.path.islink(config_dir):
        raise RuntimeError("CyberGhost config directory must not be a symlink")
    return candidate


def load_account(config_path=None):
    """Read device credentials plus display metadata from the active config."""
    path = find_config_path(config_path)
    # Read-only compatibility: never rewrite the vendor CLI's credentials.
    # A present but invalid native file must fail closed, not fall back.
    if path == user_config_path() and not os.path.lexists(path):
        path = legacy_config_path()
    if not os.path.exists(path):
        raise RuntimeError(
            f"Configuration file not found: {path}. Please link your account or run 'cyberghostvpn --setup' first."
        )
    # O_NONBLOCK keeps a FIFO from stalling the runner inside open(); the
    # S_ISREG check below then rejects it.
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        if os.path.islink(path):
            raise RuntimeError(f"Configuration file must not be a symlink: {path}") from exc
        raise RuntimeError(f"Configuration file cannot be opened safely: {path}") from exc

    try:
        file_stat = os.fstat(fd)
        if not stat.S_ISREG(file_stat.st_mode):
            raise RuntimeError(f"Configuration file must be a regular file: {path}")
        if file_stat.st_size > MAX_CONFIG_BYTES:
            raise RuntimeError(f"Configuration file {path} exceeds maximum size limit (64KB).")
        if file_stat.st_mode & 0o077:
            raise RuntimeError(f"Configuration file must be private (mode 600): {path}")
        if file_stat.st_uid != os.getuid():
            raise RuntimeError("Configuration file must belong to the current user")

        with os.fdopen(fd, "r", encoding="utf-8", errors="strict") as config_file:
            fd = -1  # ownership transferred to the file object
            cfg = configparser.ConfigParser(interpolation=None)
            cfg.read_file(config_file)
    except (OSError, UnicodeError, configparser.Error) as e:
        raise RuntimeError(f"Failed to parse config file at {path}: {e}") from e
    finally:
        if fd != -1:
            os.close(fd)

    if not cfg.has_section("device") or not cfg.has_option("device", "token") or not cfg.has_option("device", "secret"):
        raise RuntimeError(f"Device credentials missing from {path}. Please run 'cyberghostvpn --setup'")

    token = validate_api_credential(cfg.get("device", "token").strip(), "device token")
    secret = validate_api_credential(cfg.get("device", "secret").strip(), "device secret")
    try:
        username = validate_config_text(cfg.get("account", "username", fallback=""), "username", 256)
    except RuntimeError:
        username = ""
    if os.path.abspath(path) == os.path.abspath(user_config_path()):
        source = "native"
    elif os.path.abspath(path) == os.path.abspath(legacy_config_path()):
        source = "legacy"
    else:
        source = "custom"
    jwt = cfg.get("session", "jwt", fallback="").strip()
    try:
        jwt = validate_api_credential(jwt, "session token") if jwt else ""
    except RuntimeError:
        jwt = ""
    user_id = cfg.get("session", "user_id", fallback="").strip()
    return {
        "token": token,
        "secret": secret,
        "username": username,
        "path": path,
        "source": source,
        "jwt": jwt,
        "user_id": user_id if user_id.isdigit() else "",
    }


def get_credentials(config_path=None):
    account = load_account(config_path)
    return account["token"], account["secret"]


def write_user_config(path, username, device_name, device, session=None):
    safe_username = validate_config_text(username, "username", 256)
    safe_device_name = validate_config_text(str(device.get("name") or device_name), "device name", 64)
    token = validate_api_credential(str(device.get("token") or ""), "device token")
    secret = validate_api_credential(str(device.get("tokenSecret") or device.get("secret") or ""), "device secret")
    cfg = configparser.ConfigParser(interpolation=None)
    # Keep only the account identifier and device credentials. The account
    # password is used for registration and is deliberately never persisted.
    cfg["account"] = {"username": safe_username}
    cfg["device"] = {
        "name": safe_device_name,
        "token": token,
        # The API returns the secret as `tokenSecret`; the CLI stores it as `secret`.
        "secret": secret,
    }
    # The login session token reads CyberGhost's live server list, which the
    # device token cannot. It expires on its own; the password is never kept.
    if session and session.get("jwt"):
        cfg["session"] = {"jwt": validate_api_credential(str(session["jwt"]), "session token")}
        user_id = str(session.get("user_id") or "")
        if user_id.isdigit() and len(user_id) <= 20:
            cfg["session"]["user_id"] = user_id
    target_dir = os.path.dirname(os.path.abspath(path))
    os.makedirs(target_dir, mode=0o700, exist_ok=True)
    os.chmod(target_dir, 0o700)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", dir=target_dir, delete=False, prefix=".config_ini_", encoding="utf-8"
        ) as tf:
            os.chmod(tf.name, 0o600)
            temp_name = tf.name
            cfg.write(tf)
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def cli_account_configured():
    """Local prerequisite check only; this does not prove vendor authentication."""
    path = legacy_config_path()
    fd = -1
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_CONFIG_BYTES or info.st_mode & 0o077:
            return False
        if info.st_uid != invoking_user().pw_uid:
            return False
        with os.fdopen(fd, encoding="utf-8") as stream:
            fd = -1  # ownership transferred to the file object
            config = configparser.ConfigParser(interpolation=None)
            config.read_string(stream.read(MAX_CONFIG_BYTES + 1))
        return all(config.get("account", key, fallback="").strip() for key in ("username", "password"))
    except (OSError, UnicodeError, configparser.Error):
        return False
    finally:
        if fd != -1:
            os.close(fd)
