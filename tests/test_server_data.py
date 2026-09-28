"""Real server names: the per-user cache and the paced background sync."""

import base64
import json
from unittest import mock

import pytest
from runner_support import load_runner

runner = load_runner()


def jwt(exp=4_000_000_000):
    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    return f"{part({})}.{part({'exp': exp})}.sig"


def response(status, body):
    item = mock.Mock(status_code=status)
    item._cyberghost_body = json.dumps(body).encode()
    return item


LOCATION = response(200, {"id": 7, "location": {"latitude": 38.7, "longitude": -9.1}})


def rows(*names):
    return [{"name": name, "full": "0", "totalusers": "1", "Max_Users": "50"} for name in names]


@pytest.fixture
def account(monkeypatch):
    session = {"token": "T", "secret": "S", "username": "", "path": "", "source": "native", "jwt": jwt(), "user_id": ""}
    monkeypatch.setattr(runner, "load_account", lambda *args: session)
    monkeypatch.setattr(runner.time, "sleep", lambda seconds: None)
    return session


def test_grouping_round_trips():
    names = ["lisbon-s405-i01", "lisbon-s405-i12", "lisbon-s406-i03"]
    grouped = runner.group_server_names(names)
    assert grouped == {"lisbon-s405": [1, 12], "lisbon-s406": [3]}
    assert sorted(runner.expand_server_names(grouped)) == names


@pytest.mark.parametrize(
    "grouped",
    [{"lisbon-s405 endpoint=evil": [1]}, {"../x-s1": [1]}, {"lisbon-s405": ["1"]}, {"lisbon-s405": [True]}, []],
)
def test_expansion_rejects_malformed_or_injected_entries(grouped):
    assert runner.expand_server_names(grouped) == []


def test_cache_distinguishes_unfetched_from_no_servers(isolated_home):
    assert runner.known_servers("PT") is None
    runner.remember_servers("PT", ["lisbon-s407-i09"])
    runner.remember_servers("GL", [])
    assert runner.known_servers("PT") == ["lisbon-s407-i09"]
    assert runner.known_servers("GL") == []
    path = isolated_home / ".cache" / "cyberghost" / "servers.json"
    assert (path.parent.stat().st_mode & 0o777) == 0o700


def test_cache_entries_do_not_expire(isolated_home):
    runner.remember_servers("PT", ["lisbon-s407-i09"])
    path = isolated_home / ".cache" / "cyberghost" / "servers.json"
    data = json.loads(path.read_text())
    data["countries"]["PT"]["updated"] = 0  # decades old: still probed before use
    path.write_text(json.dumps(data))
    assert runner.known_servers("PT") == ["lisbon-s407-i09"]


def test_corrupt_or_oversized_cache_is_ignored(isolated_home, monkeypatch):
    path = isolated_home / ".cache" / "cyberghost" / "servers.json"
    path.parent.mkdir(parents=True)
    path.write_text("{not json")
    assert runner.known_servers("PT") is None
    runner.remember_servers("PT", ["lisbon-s405-i01"])
    monkeypatch.setattr(runner, "MAX_SERVER_LIST_BYTES", 4)
    assert runner.known_servers("PT") is None


def test_probe_sample_spreads_across_racks_and_is_capped():
    names = [f"berlin-s{rack}-i{i:02d}" for rack in (451, 452, 453) for i in range(1, 60)]
    sample = runner.probe_sample(names, size=12)
    assert len(sample) == 12 and len(set(sample)) == 12
    racks = [name.split("-s")[1].split("-")[0] for name in sample]
    assert {racks.count(rack) for rack in set(racks)} == {4}


def test_nospy_servers_are_a_last_choice():
    assert runner.probe_sample(["nospybucharest-s408-i01", "bucharest-s492-i03"]) == ["bucharest-s492-i03"]
    assert runner.probe_sample(["nospybucharest-s408-i01"]) == ["nospybucharest-s408-i01"]
    live = [
        {"name": "NoSpyBucharest-S408-i01", "full": "0", "totalusers": "0", "Max_Users": "50"},
        {"name": "Bucharest-S492-i03", "full": "0", "totalusers": "40", "Max_Users": "50"},
    ]
    assert runner.parse_live_inventory(live) == ["bucharest-s492-i03", "nospybucharest-s408-i01"]


def test_fallback_probes_cached_names_before_guessing(isolated_home):
    runner.remember_servers("BA", ["travnik-s402-i10"])
    probed = []

    def probe(hosts, **kwargs):
        probed.append(list(hosts))
        return [host for host in hosts if host == "travnik-s402-i10.cg-dialup.net"]

    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "reachable_endpoints", side_effect=probe):
            _, candidates = runner.select_native_candidates("BA")
    assert candidates == ["travnik-s402-i10.cg-dialup.net"]
    assert probed == [["travnik-s402-i10.cg-dialup.net"]]


def test_country_without_wireguard_servers_fails_fast(isolated_home):
    runner.remember_servers("GL", [])
    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "reachable_endpoints", side_effect=AssertionError("must not guess")):
            with pytest.raises(RuntimeError, match="no WireGuard servers for GL"):
                runner.select_native_candidates("GL")


def test_display_names_without_the_rack_s_map_to_the_real_hostname():
    # Live response for Kenya: the API says "Nairobi-401-i01", DNS serves
    # nairobi-s401-i01.cg-dialup.net (same IP, nairobi-rack401 certificate).
    live = [{"name": "Nairobi-401-i01", "full": "0", "totalusers": "9", "Max_Users": "35"}]
    assert runner.parse_live_inventory(live) == ["nairobi-s401-i01"]
    # Only the rack form is rewritten; anything else still has to validate.
    assert runner.parse_live_inventory([{"name": "Nairobi-401", "full": "0"}]) == []
    assert runner.parse_live_inventory([{"name": "evil-401-i01 x", "full": "0"}]) == []


def test_unfetched_country_still_has_the_guessed_pool(isolated_home):
    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "reachable_endpoints", return_value=["lisbon-s401-i01.cg-dialup.net"]) as probe:
            _, candidates = runner.select_native_candidates("PT")
    assert candidates == ["lisbon-s401-i01.cg-dialup.net"]
    assert len(probe.call_args.args[0]) == len(runner.DIALUP_RACKS) * len(runner.DIALUP_INSTANCES)


# ---- background sync -------------------------------------------------------


def test_sync_fills_every_requested_country_at_a_steady_pace(account, monkeypatch):
    sleeps = []
    monkeypatch.setattr(runner.time, "sleep", sleeps.append)
    replies = [
        LOCATION,
        response(200, rows("Lisbon-S405-i01")),
        response(200, []),
        response(200, rows("Kiev-S401-i01")),
    ]
    with mock.patch.object(runner, "api_request", side_effect=replies):
        result = runner.sync_servers(["PT", "GL", "UA"])
    assert result == {"synced": 3, "remaining": 0, "stopped": ""}
    assert runner.known_servers("PT") == ["lisbon-s405-i01"]
    assert runner.known_servers("GL") == []  # an empty list is recorded as "no servers"
    assert runner.known_servers("UA") == ["kiev-s401-i01"]
    assert sleeps == [runner.SYNC_PACE_SECONDS] * 2


@pytest.mark.parametrize("status", [429, 401])
def test_sync_stops_at_rate_limits_and_resumes_later(account, status):
    replies = [LOCATION, response(200, rows("Lisbon-S405-i01")), response(status, {})]
    with mock.patch.object(runner, "api_request", side_effect=replies):
        first = runner.sync_servers(["PT", "UA", "IT"])
    assert first == {"synced": 1, "remaining": 2, "stopped": f"HTTP {status}"}
    replies = [LOCATION, response(200, rows("Kiev-S401-i01")), response(200, rows("Milano-S402-i01"))]
    with mock.patch.object(runner, "api_request", side_effect=replies) as call:
        second = runner.sync_servers(["PT", "UA", "IT"])
    assert second == {"synced": 2, "remaining": 0, "stopped": ""}
    assert "filter_country=PT" not in " ".join(c.args[1] for c in call.call_args_list)  # fresh: skipped


def test_sync_refreshes_only_stale_countries(account):
    runner.remember_servers("PT", ["lisbon-s405-i01"])
    with mock.patch.object(runner, "api_request", side_effect=AssertionError("nothing is stale")):
        assert runner.sync_servers(["PT"]) == {"synced": 0, "remaining": 0, "stopped": ""}
    later = runner.time.time() + runner.SYNC_REFRESH_SECONDS + 60
    replies = [LOCATION, response(200, rows("Lisbon-S406-i02"))]
    with mock.patch.object(runner, "api_request", side_effect=replies):
        assert runner.sync_servers(["PT"], now=later)["synced"] == 1
    assert runner.known_servers("PT") == ["lisbon-s406-i02"]


def test_sync_does_nothing_without_a_session(account):
    account["jwt"] = jwt(exp=1)
    with mock.patch.object(runner, "api_request", side_effect=AssertionError("expired token was sent")):
        assert runner.sync_servers(["PT"])["stopped"] == "no session"


def test_only_one_sync_runs_at_a_time(account, isolated_home):
    import fcntl
    import os

    lock_path = isolated_home / ".cache" / "cyberghost" / "sync.lock"
    lock_path.parent.mkdir(parents=True)
    holder = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(holder, fcntl.LOCK_EX)
    try:
        with mock.patch.object(runner, "api_request", side_effect=AssertionError("second sync ran")):
            assert runner.sync_servers(["PT"])["stopped"] == "already running"
    finally:
        os.close(holder)


def test_unreadable_rows_are_not_recorded_as_no_servers(account):
    replies = [LOCATION, response(200, [{"unexpected": "shape"}])]
    with mock.patch.object(runner, "api_request", side_effect=replies):
        runner.sync_servers(["PT"])
    assert runner.known_servers("PT") is None


def test_a_live_lookup_refreshes_the_cache(account):
    with mock.patch.object(runner, "api_request", side_effect=[LOCATION, response(200, rows("Travnik-S402-i10"))]):
        assert runner.live_server_inventory("BA", account) == ["travnik-s402-i10"]
    assert runner.known_servers("BA") == ["travnik-s402-i10"]
