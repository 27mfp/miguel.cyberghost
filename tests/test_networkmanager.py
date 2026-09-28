"""NetworkManager lifecycle tests. nmcli is replaced at its process boundary."""

import base64
import io
from contextlib import redirect_stdout
from unittest import mock

import pytest
from runner_support import SAMPLE_PRIV, SAMPLE_PUB, load_runner

runner = load_runner()
UUID = runner.connection_uuid()


def completed(code=0, stdout="", stderr=""):
    return runner.subprocess.CompletedProcess(["nmcli"], code, stdout, stderr)


class FakeNetworkManager:
    """Just enough nmcli behavior to exercise ordering, secrets and rollback."""

    def __init__(self, running=True, fail=None, activate_to="activated"):
        self.running = running
        self.fail = set(fail or ())
        self.activate_to = activate_to
        self.profile = False
        self.state = ""
        self.link = False
        self.calls = []
        self.inputs = []

    def nmcli(self, args, timeout=15, input_data=None):
        self.calls.append(list(args))
        if input_data is not None:
            self.inputs.append(input_data)
        if args[:3] == ["-t", "-f", "RUNNING"]:
            return completed(0, "running\n" if self.running else "stopped\n")
        if args[:5] == ["-t", "-f", "UUID,STATE", "connection", "show"]:
            return completed(0, f"{UUID}:{self.state}\n" if self.state else "other-uuid:activated\n")
        if args[:5] == ["-t", "-f", "UUID", "connection", "show"]:
            return completed(0, f"{UUID}\n" if self.profile else "other-uuid\n")
        if args[:2] == ["connection", "add"]:
            if "add" in self.fail:
                return completed(4, "", "Error: invalid peer")
            self.profile = True
            return completed(0, "added")
        if args[:2] == ["connection", "edit"]:
            return completed(1 if "edit" in self.fail else 0)
        if args[0] == "--wait" and args[2:4] == ["connection", "up"]:
            if "up" in self.fail:
                return completed(4, "", "Error: Connection activation failed")
            self.state = self.activate_to
            self.link = self.activate_to == "activated"
            return completed(0)
        if args[:2] == ["connection", "down"]:
            if "down" in self.fail:
                return completed(4, "", "Error: down failed")
            if not self.state:
                return completed(runner.NMCLI_NOT_FOUND, "", "not an active connection")
            self.state = ""
            self.link = "stuck_link" in self.fail
            return completed(0)
        if args[:2] == ["connection", "delete"]:
            if not self.profile:
                return completed(runner.NMCLI_NOT_FOUND, "", "unknown connection")
            self.profile = False
            return completed(0)
        if args[:2] == ["-g", "wireguard.peers"]:
            return completed(0, f"{SAMPLE_PUB} endpoint=198.51.100.20\\:1337 persistent-keepalive=25\n")
        raise AssertionError(f"unexpected nmcli call: {args}")

    def patches(self):
        return (
            mock.patch.object(runner, "nmcli", side_effect=self.nmcli),
            mock.patch.object(runner, "_interface_state", side_effect=lambda ip: self.link),
            mock.patch.object(runner, "system_binary", side_effect=lambda name: f"/usr/bin/{name}"),
        )


def with_nm(nm, fn, *args, **kwargs):
    first, second, third = nm.patches()
    with first, second, third:
        return fn(*args, **kwargs)


def profile_args(**overrides):
    values = {
        "peer_ip": "10.2.0.2",
        "server_key": SAMPLE_PUB,
        "server_host": "198.51.100.20",
        "server_port": 1337,
        "dns_servers": ["10.0.0.243", "2001:db8::53"],
    }
    values.update(overrides)
    return runner.nm_profile_args(**values)


# ---- Keys ---------------------------------------------------------------


def test_x25519_matches_rfc7748_vectors():
    h = bytes.fromhex
    nine = (9).to_bytes(32, "little")
    assert runner.x25519(
        h("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
        h("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"),
    ) == h("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
    alice = h("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    assert runner.x25519(alice, nine) == h("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    bob_public = h("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    assert runner.x25519(alice, bob_public) == h("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    assert runner.x25519(nine, nine) == h("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079")


def test_generated_keys_are_a_fresh_matching_pair():
    priv, pub = runner.generate_wireguard_keys()
    other_priv, _ = runner.generate_wireguard_keys()
    raw = base64.b64decode(priv)
    assert base64.b64decode(pub) == runner.x25519(raw, (9).to_bytes(32, "little"))
    assert raw[0] & 7 == 0 and raw[31] & 0xC0 == 0x40
    assert priv != other_priv


# ---- Profile ------------------------------------------------------------


def test_profile_is_in_memory_full_tunnel_with_exclusive_vpn_dns():
    args = profile_args()
    pairs = dict(zip(args[::2], args[1::2]))
    assert args[:4] == ["connection", "add", "save", "no"]
    assert pairs["connection.uuid"] == UUID
    assert pairs["connection.autoconnect"] == "no"
    assert pairs["ifname"] == runner.INTERFACE
    assert pairs["ipv4.addresses"] == "10.2.0.2/32"
    assert pairs["ipv6.method"] == "link-local"
    assert pairs["ipv4.dns"] == "10.0.0.243"
    assert pairs["ipv6.dns"] == "2001:db8::53"
    assert pairs["ipv4.dns-search"] == pairs["ipv6.dns-search"] == "~."
    assert int(pairs["ipv4.dns-priority"]) < 0
    assert "allowed-ips=0.0.0.0/0;::/0" in pairs["wireguard.peers"]
    assert "endpoint=198.51.100.20:1337" in pairs["wireguard.peers"]
    assert pairs["connection.permissions"] == f"user:{runner.invoking_user().pw_name}"
    assert not any("private-key" in arg for arg in args)


def test_profile_brackets_ipv6_endpoints():
    peers = dict(zip(*[iter(profile_args(server_host="2001:db8::20"))] * 2))["wireguard.peers"]
    assert "endpoint=[2001:db8::20]:1337" in peers


@pytest.mark.parametrize(
    "field,value",
    [
        ("server_key", SAMPLE_PUB + "\nendpoint=203.0.113.9:1"),
        ("server_host", "198.51.100.20 allowed-ips=0.0.0.0/0"),
        ("dns_servers", ["10.0.0.1\nipv4.dns 203.0.113.53"]),
        ("dns_servers", []),
        ("server_port", 70000),
        ("peer_ip", "10.2.0.2/8"),
    ],
)
def test_profile_rejects_injection_and_invalid_api_values(field, value):
    with pytest.raises((ValueError, RuntimeError)):
        profile_args(**{field: value})


def test_profile_refuses_ipv6_only_tunnel_address():
    with pytest.raises(RuntimeError, match="IPv4 tunnel"):
        profile_args(peer_ip="2001:db8::2")


def test_connection_uuid_is_stable_and_per_user():
    assert runner.connection_uuid() == UUID
    with mock.patch.object(runner.os, "getuid", return_value=4242):
        assert runner.connection_uuid() != UUID


# ---- Activation ---------------------------------------------------------


def test_activation_sends_the_key_only_on_stdin():
    nm = FakeNetworkManager()
    with_nm(nm, runner.nm_activate, profile_args(), SAMPLE_PRIV, "/usr/bin/ip", runner.time.monotonic() + 60)
    verbs = [call[1] if call[0] == "connection" else call[0] for call in nm.calls]
    assert verbs.index("add") < verbs.index("edit") < verbs.index("--wait")
    assert all(SAMPLE_PRIV not in " ".join(call) for call in nm.calls)
    assert nm.inputs == [f"set wireguard.private-key {SAMPLE_PRIV}\nsave temporary\nquit\n"]
    assert nm.state == "activated"


@pytest.mark.parametrize("failure", ["add", "edit", "up"])
def test_activation_failure_rolls_back_the_profile(failure):
    nm = FakeNetworkManager(fail={failure})
    with pytest.raises(RuntimeError):
        with_nm(nm, runner.nm_activate, profile_args(), SAMPLE_PRIV, "/usr/bin/ip", runner.time.monotonic() + 60)
    assert ["connection", "delete", "uuid", UUID] in nm.calls
    assert not nm.profile and not nm.link


def test_activation_that_never_reaches_activated_is_a_failure():
    nm = FakeNetworkManager(activate_to="activating")
    with pytest.raises(RuntimeError, match="not active"):
        with_nm(nm, runner.nm_activate, profile_args(), SAMPLE_PRIV, "/usr/bin/ip", runner.time.monotonic() + 60)
    assert not nm.profile


def test_failed_rollback_is_reported_with_the_original_error():
    nm = FakeNetworkManager(fail={"up", "stuck_link"})
    nm.state = ""
    with pytest.raises(RuntimeError, match="rollback incomplete: interface cyberghost is still present"):

        def activate_then_stick():
            nm.link = True
            return runner.nm_activate(profile_args(), SAMPLE_PRIV, "/usr/bin/ip", runner.time.monotonic() + 60)

        with_nm(nm, activate_then_stick)


def test_expired_budget_never_activates():
    nm = FakeNetworkManager()
    with pytest.raises(RuntimeError, match="timed out"):
        with_nm(nm, runner.nm_activate, profile_args(), SAMPLE_PRIV, "/usr/bin/ip", runner.time.monotonic())
    assert not any(call[0] == "--wait" for call in nm.calls)
    assert not nm.profile


# ---- connect / disconnect ----------------------------------------------


def native_connect(nm, addkey_overrides=None):
    addkey = {
        "status": "OK",
        "server_key": SAMPLE_PUB,
        "server_ip": "198.51.100.20",
        "server_port": 1337,
        "peer_ip": "10.2.0.2",
        "dns_servers": ["10.0.0.243"],
    }
    addkey.update(addkey_overrides or {})
    account = {
        "token": "token",
        "secret": "secret",
        "username": "",
        "path": "",
        "source": "native",
        "jwt": "",
        "user_id": "",
    }
    with mock.patch.object(runner, "load_account", return_value=account) as credentials:
        with mock.patch.object(
            runner, "exchange_wireguard_key", return_value=(addkey, "lisbon-s405-i19.cg-dialup.net")
        ) as exchange:
            with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                with redirect_stdout(io.StringIO()):
                    try:
                        return with_nm(nm, runner.connect, "PT", server="lisbon-s405-i19")
                    finally:
                        # Records whether CyberGhost was contacted before a refusal.
                        native_connect.seen = (credentials.called, exchange.called)


def test_connect_activates_a_networkmanager_profile():
    nm = FakeNetworkManager()
    result = native_connect(nm)
    assert result["backend"] == "networkmanager"
    assert result["country"] == "PT"
    assert nm.state == "activated"


def test_connect_replaces_our_previous_session_first():
    nm = FakeNetworkManager()
    nm.profile, nm.state, nm.link = True, "activated", True
    native_connect(nm)
    first_add = next(i for i, call in enumerate(nm.calls) if call[:2] == ["connection", "add"])
    assert ["connection", "down", "uuid", UUID] in nm.calls[:first_add]


def test_connect_refuses_as_root():
    with mock.patch.object(runner.os, "geteuid", return_value=0):
        with pytest.raises(RuntimeError, match="desktop user"):
            runner.connect("PT")


def test_connect_requires_networkmanager_before_contacting_cyberghost():
    nm = FakeNetworkManager(running=False)
    with pytest.raises(RuntimeError, match="NetworkManager is not running"):
        native_connect(nm)
    assert native_connect.seen == (False, False)


def test_connect_refuses_to_stack_on_a_legacy_tunnel():
    nm = FakeNetworkManager()
    nm.link = True
    with pytest.raises(runner.LegacyTunnelError):
        native_connect(nm)
    assert native_connect.seen == (False, False)
    assert not any(call[:2] == ["connection", "add"] for call in nm.calls)


def test_connect_rejects_explicit_empty_dns_before_creating_a_profile():
    nm = FakeNetworkManager()
    with pytest.raises(ValueError, match="DNS"):
        native_connect(nm, {"dns_servers": []})
    assert not any(call[:2] == ["connection", "add"] for call in nm.calls)


def test_disconnect_removes_only_our_profile():
    nm = FakeNetworkManager()
    nm.profile, nm.state, nm.link = True, "activated", True
    with redirect_stdout(io.StringIO()):
        assert with_nm(nm, runner.disconnect) == {"backend": "networkmanager", "connected": False}
    assert not nm.profile and not nm.link
    assert all(UUID in call for call in nm.calls if call[:2] in (["connection", "down"], ["connection", "delete"]))


def test_disconnect_is_idempotent_when_nothing_exists():
    nm = FakeNetworkManager()
    with redirect_stdout(io.StringIO()) as out:
        with_nm(nm, runner.disconnect)
    assert "No VPN connections found." in out.getvalue()


def test_disconnect_reports_residual_state():
    nm = FakeNetworkManager(fail={"stuck_link"})
    nm.profile, nm.state, nm.link = True, "activated", True
    with pytest.raises(RuntimeError, match="interface cyberghost is still present"):
        with_nm(nm, runner.disconnect)


def test_disconnect_hands_legacy_tunnels_back_to_the_ui():
    nm = FakeNetworkManager()
    nm.link = True
    with pytest.raises(runner.LegacyTunnelError) as error:
        with_nm(nm, runner.disconnect)
    assert error.value.code == "legacy_tunnel"
    assert not any(call[:2] == ["connection", "down"] for call in nm.calls)


# ---- status / readiness -------------------------------------------------


def status_json(nm, counters=None):
    buf = io.StringIO()
    with mock.patch.object(runner, "interface_counters", return_value=counters or {}):
        with redirect_stdout(buf):
            with_nm(nm, runner.status, True)
    return runner.json.loads(buf.getvalue())


def test_status_reports_networkmanager_session_details():
    nm = FakeNetworkManager()
    nm.profile, nm.state, nm.link = True, "activated", True
    data = status_json(nm, {"rx_bytes": 2048, "tx_bytes": 100})
    assert data["connected"] is True
    assert data["backend"] == "networkmanager"
    assert data["rx_bytes"] == 2048
    assert data["transfer"] == "2.00 KiB received, 100 B sent"
    assert data["endpoint"] == "198.51.100.20:1337"


def test_status_reports_activation_in_progress_as_not_connected():
    nm = FakeNetworkManager()
    nm.profile, nm.state, nm.link = True, "activating", True
    data = status_json(nm)
    assert data["connected"] is False
    assert data["state"] == "activating"


def test_status_identifies_a_legacy_tunnel():
    nm = FakeNetworkManager()
    nm.link = True
    data = status_json(nm)
    assert data == {"connected": True, "backend": "legacy", "state": "", "interface": "cyberghost"}


def test_status_disconnected():
    data = status_json(FakeNetworkManager())
    assert data == {"connected": False, "backend": None, "state": "", "interface": None}


def test_networkmanager_down_still_reveals_a_legacy_tunnel():
    # Pre-1.7 users may not run NetworkManager; their helper tunnel must stay
    # visible so the panel can offer the legacy disconnect.
    down = completed(8, "", "Error: NetworkManager is not running.")
    with mock.patch.object(runner, "nmcli", return_value=down):
        with mock.patch.object(runner, "system_binary", side_effect=lambda name: f"/usr/bin/{name}"):
            with mock.patch.object(runner, "_interface_state", return_value=True):
                buf = io.StringIO()
                with redirect_stdout(buf):
                    runner.status(True)
                assert runner.json.loads(buf.getvalue())["backend"] == "legacy"
                with pytest.raises(runner.LegacyTunnelError):
                    runner.disconnect()
            with mock.patch.object(runner, "_interface_state", return_value=False):
                buf = io.StringIO()
                with redirect_stdout(buf):
                    runner.status(True)
                    assert runner.disconnect() == {"backend": "networkmanager", "connected": False}
                assert '"connected": false' in buf.getvalue()


def test_missing_nmcli_is_not_a_crash():
    with mock.patch.object(runner, "nmcli", side_effect=FileNotFoundError("nmcli")):
        assert runner.nm_state_or_none() is None


def test_lifecycle_operations_are_serialized(isolated_home):
    import fcntl
    import os

    path = isolated_home / ".cache" / "cyberghost" / "lifecycle.lock"
    path.parent.mkdir(parents=True)
    holder = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(holder, fcntl.LOCK_EX)
    try:
        with pytest.raises(RuntimeError, match="still finishing"):
            with runner.lifecycle_lock(wait=0.3):
                raise AssertionError("ran while another operation held the lock")
    finally:
        os.close(holder)
    with runner.lifecycle_lock(wait=0.3):
        pass  # free again once the other operation ends


def test_cancel_becomes_a_normal_failure_so_rollback_runs():
    nm = FakeNetworkManager()

    def cancelled_up(args, timeout=15, input_data=None):
        if args[0] == "--wait":
            runner._cancel_on_sigterm(15, None)  # SIGTERM arrives during activation
        return nm.nmcli(args, timeout, input_data)

    with mock.patch.object(runner, "nmcli", side_effect=cancelled_up):
        with mock.patch.object(runner, "_interface_state", side_effect=lambda ip: nm.link):
            with pytest.raises(RuntimeError, match="cancelled"):
                runner.nm_activate(profile_args(), SAMPLE_PRIV, "/usr/bin/ip", runner.time.monotonic() + 60)
    assert not nm.profile  # rolled back, not left half-created


@pytest.mark.parametrize(
    "control,own,expected",
    [("yes", "yes", "yes"), ("auth", "yes", "auth"), ("yes", "no", "no"), ("yes", "", "")],
)
def test_permission_reports_the_least_permitted_action(control, own, expected):
    lines = [
        f"org.freedesktop.NetworkManager.network-control:{control}",
        "org.freedesktop.NetworkManager.wifi.scan:yes",
    ]
    if own:
        lines.append(f"org.freedesktop.NetworkManager.settings.modify.own:{own}")
    with mock.patch.object(runner, "nmcli", return_value=completed(0, "\n".join(lines))):
        assert runner.nm_permission() == expected


def test_byte_formatting():
    assert runner.format_bytes(0) == "0 B"
    assert runner.format_bytes(1536) == "1.50 KiB"
    assert runner.format_bytes(5 * 1024**3) == "5.00 GiB"
