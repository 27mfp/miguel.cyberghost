"""Audit regressions. No live account, DNS, privileged cleanup or VPN operations."""

import os
import subprocess
import sys
import threading
import time
from unittest import mock

import pytest
from runner_support import ROOT, load_runner

runner = load_runner()


@pytest.mark.parametrize("boundary", ["account_location", "fetch_country_servers"])
def test_inventory_cancellation_propagates(boundary):
    with (
        mock.patch.object(runner, "session_usable", return_value=True),
        mock.patch.object(runner, "account_location", return_value=("7", 1, 2)),
        mock.patch.object(runner, boundary, side_effect=runner.OperationCancelled("cancelled")),
        mock.patch.object(runner, "remember_servers") as remember,
    ):
        with pytest.raises(runner.OperationCancelled):
            runner.live_server_inventory("PT", {"jwt": "test"})
    remember.assert_not_called()


def test_key_exchange_cancellation_never_tries_another_server():
    with mock.patch.object(runner, "api_get", side_effect=runner.OperationCancelled("cancelled")) as request:
        with pytest.raises(runner.OperationCancelled):
            runner.exchange_wireguard_key(
                ["lisbon-s401-i01.cg-dialup.net", "lisbon-s401-i02.cg-dialup.net"],
                "mock",
                "mock",
                "mock",
                "PT",
                time.monotonic() + 10,
            )
    assert request.call_count == 1


def test_status_fallback_does_not_swallow_cancellation():
    with mock.patch.object(runner, "nm_active_state", side_effect=runner.OperationCancelled("cancelled")):
        with pytest.raises(runner.OperationCancelled):
            runner.nm_state_or_none()


@pytest.mark.parametrize("countries", [None, [], "invalid", 12, True])
def test_malformed_cache_schema_is_a_miss(countries):
    with mock.patch.object(runner, "_read_server_list", return_value={"countries": countries}):
        assert runner.known_servers("PT") is None


def test_cache_replace_failure_removes_temporary_file(isolated_home):
    with mock.patch.object(runner.os, "replace", side_effect=OSError("disk error")):
        runner.remember_servers("PT", ["lisbon-s401-i01"])
    directory = isolated_home / ".cache" / "cyberghost"
    assert not list(directory.glob(".servers_*"))


def test_concurrent_cache_writers_preserve_both_countries(isolated_home):
    first_read = threading.Event()
    release_first = threading.Event()
    reads = []
    errors = []
    original_read = runner._read_server_list

    def paused_read(path):
        data = original_read(path)
        reads.append(path)
        if len(reads) == 1:
            first_read.set()
            assert release_first.wait(3)
        return data

    def write(cc, names):
        try:
            runner.remember_servers(cc, names)
        except BaseException as exc:
            errors.append(exc)

    with mock.patch.object(runner, "_read_server_list", side_effect=paused_read):
        first = threading.Thread(target=write, args=("PT", ["lisbon-s401-i01"]))
        second = threading.Thread(target=write, args=("ES", ["barcelona-s401-i01"]))
        first.start()
        try:
            assert first_read.wait(3)
            second.start()
            time.sleep(0.05)
            assert len(reads) == 1  # second writer cannot read before taking the lock
        finally:
            release_first.set()
            first.join(4)
            if second.ident is not None:
                second.join(4)
    assert not errors and not first.is_alive() and not second.is_alive()
    assert runner.known_servers("PT") == ["lisbon-s401-i01"]
    assert runner.known_servers("ES") == ["barcelona-s401-i01"]


def test_probe_deadline_bounds_process_exit_and_reaps_workers():
    source = (
        "import importlib.util,multiprocessing,sys,time\n"
        "spec=importlib.util.spec_from_file_location('r',sys.argv[1])\n"
        "r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)\n"
        "r._probe_endpoint=lambda host: (time.sleep(30) or (host,None))\n"
        "assert r.reachable_endpoints(['mock'],budget=0.03)==[]\n"
        "assert not multiprocessing.active_children()\n"
    )
    started = time.monotonic()
    subprocess.run(  # noqa: S603
        [sys.executable, "-c", source, str(ROOT / "cyberghost_runner.py")],
        check=True,
        timeout=3,
    )
    assert time.monotonic() - started < 3


def test_probe_cancellation_reaps_workers():
    with mock.patch.object(
        runner.multiprocessing.connection, "wait", side_effect=runner.OperationCancelled("cancelled")
    ):
        with mock.patch.object(runner, "_probe_endpoint", side_effect=lambda host: time.sleep(30)):
            with pytest.raises(runner.OperationCancelled):
                runner.reachable_endpoints(["mock"], budget=1)
    assert not runner.multiprocessing.active_children()


@pytest.mark.parametrize("state,link", [("activated", True), ("activating", False), ("", True), ("", None)])
def test_registration_refuses_active_or_unverified_tunnel_before_api(state, link, tmp_path):
    with (
        mock.patch.object(runner, "user_config_path", return_value=str(tmp_path / "native.ini")),
        mock.patch.object(runner, "nm_active_state", return_value=state),
        mock.patch.object(runner, "system_binary", return_value="/mock/ip"),
        mock.patch.object(runner, "_interface_state", return_value=link),
        mock.patch.object(runner, "api_request") as request,
        mock.patch.dict(os.environ, {"CG_USERNAME": "test", "CG_PASSWORD": "secret"}),
    ):
        with pytest.raises(RuntimeError, match="VPN"):
            runner.register()
        assert "CG_PASSWORD" not in os.environ
    request.assert_not_called()
    assert not (tmp_path / "native.ini").exists()


def test_registration_holds_lifecycle_lock_until_publication(isolated_home):
    entered = threading.Event()
    release = threading.Event()
    finished_logout = threading.Event()
    errors = []
    native = isolated_home / "native.ini"

    def register(config_path=None):
        entered.set()
        assert release.wait(3)
        native.write_text("mock credentials")

    def run_register():
        try:
            runner.register()
        except BaseException as exc:
            errors.append(exc)

    def run_logout():
        try:
            with runner.lifecycle_lock():
                native.unlink()
                finished_logout.set()
        except BaseException as exc:
            errors.append(exc)

    with mock.patch.object(runner, "_register", side_effect=register):
        first = threading.Thread(target=run_register)
        second = threading.Thread(target=run_logout)
        first.start()
        try:
            assert entered.wait(3)
            second.start()
            assert not finished_logout.wait(0.05)
        finally:
            release.set()
            first.join(4)
            if second.ident is not None:
                second.join(4)
    assert not errors and finished_logout.is_set()
    assert not first.is_alive() and not second.is_alive() and not native.exists()


@pytest.mark.parametrize("status", [401, 403])
def test_authentication_error_recommends_native_linking(status):
    response = mock.Mock(status_code=status)
    with mock.patch.object(runner, "api_get", return_value=response):
        with pytest.raises(RuntimeError, match="Link account") as error:
            runner.exchange_wireguard_key(
                ["lisbon-s401-i01.cg-dialup.net"], "mock", "mock", "mock", "PT", time.monotonic() + 10
            )
    assert "cyberghostvpn --setup" not in str(error.value)


def test_reset_cleanup_precedes_plugin_removal():
    source = (ROOT / "fresh-install.sh").read_text()
    assert source.index('bash "$SOURCE_DIR/scripts/remove-legacy-helper.sh" --yes --strict') < source.index(
        'omarchy plugin disable "$PLUGIN_ID"'
    )
    assert "/usr/bin/sudo /usr/bin/rm -f" not in source


@pytest.mark.parametrize("custom", ["helper", "rule"])
def test_cleanup_strict_preflight_preserves_unknown_files(tmp_path, custom):
    source = (ROOT / "scripts/remove-legacy-helper.sh").read_text()
    body = source.split("<<'ROOT'\n", 1)[1].split("\nROOT", 1)[0]
    # Execute only the root cleanup body against sandbox paths, never sudo.
    # Map root ownership to the current test UID and force interface absence.
    body = body.replace("== 0 ]]", f"== {os.getuid()} ]]")
    body = body.replace("/usr/bin/ip link show cyberghost", "/usr/bin/false")
    helper, rule, config, lock = [tmp_path / name for name in ("helper", "rule", "config", "lock")]
    helper.write_text('PLUGIN_VERSION = "1.6.3"\n# cyberghost\n')
    rule.write_text(f'lookup("program") === "{helper}"')
    config.write_text("custom configuration")
    lock.write_text("lock")
    (helper if custom == "helper" else rule).write_text("customized file")
    before = {path: path.read_bytes() for path in (helper, rule, config, lock)}
    result = subprocess.run(  # noqa: S603
        ["/usr/bin/bash", "-s", "--", str(helper), str(rule), str(config), str(lock), "1"],
        input=body,
        text=True,
        capture_output=True,
        timeout=5,
    )
    assert result.returncode != 0
    assert {path: path.read_bytes() for path in before} == before


def test_cleanup_preserves_ambiguous_config_and_advisory_lock(tmp_path):
    source = (ROOT / "scripts/remove-legacy-helper.sh").read_text()
    body = source.split("<<'ROOT'\n", 1)[1].split("\nROOT", 1)[0]
    body = body.replace("== 0 ]]", f"== {os.getuid()} ]]")
    body = body.replace("/usr/bin/ip link show cyberghost", "/usr/bin/false")
    helper, rule, config, lock = [tmp_path / name for name in ("helper", "rule", "config", "lock")]
    helper.write_text('PLUGIN_VERSION = "1.6.3"\n# cyberghost\n')
    rule.write_text(f'lookup("program") === "{helper}"')
    config.write_text("custom configuration")
    lock.write_text("lock")
    subprocess.run(  # noqa: S603
        ["/usr/bin/bash", "-s", "--", str(helper), str(rule), str(config), str(lock), "1"],
        input=body,
        text=True,
        capture_output=True,
        check=True,
        timeout=5,
    )
    assert not helper.exists() and not rule.exists()
    assert config.read_text() == "custom configuration"
    assert lock.read_text() == "lock"


def test_cancel_after_activation_rolls_back_and_before_activation_preserves_session():
    def cancel(*args):
        args[-1]["started"] = True
        raise runner.OperationCancelled("cancelled after activation")

    with (
        mock.patch.object(runner, "_connect", side_effect=cancel),
        mock.patch.object(runner, "system_binary", return_value="/mock/ip"),
        mock.patch.object(runner, "nm_remove_profile", return_value=[]) as remove,
    ):
        with pytest.raises(runner.OperationCancelled):
            runner.connect()
    remove.assert_called_once_with("/mock/ip")
    with (
        mock.patch.object(runner, "_connect", side_effect=runner.OperationCancelled("cancelled during lookup")),
        mock.patch.object(runner, "nm_remove_profile") as remove,
    ):
        with pytest.raises(runner.OperationCancelled):
            runner.connect()
    remove.assert_not_called()


def test_multiple_probe_workers_with_abrupt_exit_do_not_stall():
    def probe(host):
        if host == "exit":
            os._exit(1)
        time.sleep(30)
        return host, None

    with mock.patch.object(runner, "_probe_endpoint", side_effect=probe):
        started = time.monotonic()
        assert runner.reachable_endpoints(["exit", "stuck", "also-stuck"], budget=0.05) == []
        assert time.monotonic() - started < 1
    assert not runner.multiprocessing.active_children()


def test_probe_startup_failure_reaps_already_started_workers():
    context = runner.multiprocessing.get_context("fork")
    original_start = context.Process.start
    starts = []

    def start(process):
        starts.append(process)
        if len(starts) == 2:
            raise OSError("worker unavailable")
        return original_start(process)

    with (
        mock.patch.object(context.Process, "start", new=start),
        mock.patch.object(runner, "_probe_endpoint", side_effect=lambda host: time.sleep(30)),
    ):
        with pytest.raises(OSError, match="unavailable"):
            runner.reachable_endpoints(["first", "second"], budget=1)
    assert not runner.multiprocessing.active_children()


@pytest.mark.parametrize("kind", ["symlink", "public", "fifo"])
def test_state_lock_rejects_unsafe_files(tmp_path, kind):
    path = tmp_path / "state.lock"
    if kind == "symlink":
        target = tmp_path / "target"
        target.write_text("preserve")
        path.symlink_to(target)
    elif kind == "fifo":
        os.mkfifo(path, 0o600)
    else:
        path.write_text("")
        path.chmod(0o644)
    with pytest.raises((OSError, RuntimeError)):
        with runner.user_file_lock(str(path), wait=0.01):
            raise AssertionError("unsafe lock accepted")
    if kind == "symlink":
        assert target.read_text() == "preserve"


def test_state_lock_releases_after_cancellation(tmp_path):
    path = str(tmp_path / "state.lock")
    with pytest.raises(runner.OperationCancelled):
        with runner.user_file_lock(path):
            raise runner.OperationCancelled("cancelled")
    with runner.user_file_lock(path, wait=0.01):
        pass


def test_upgrade_docs_explain_runtime_reload():
    source = (ROOT / "README.md").read_text()
    assert "omarchy restart shell" in source
    assert "Updates need no extra step" not in source
