"""Real server names: bundled snapshot, per-user cache and probe sampling."""

import json
import os
from unittest import mock

import pytest
from runner_support import ROOT, load_runner

runner = load_runner()


@pytest.fixture
def bundle(tmp_path, monkeypatch):
    path = tmp_path / "servers.json"

    def write(countries):
        path.write_text(json.dumps({"generated": "2026-09-28", "countries": countries}))

    monkeypatch.setattr(runner, "BUNDLED_SERVERS_PATH", str(path))
    write({})
    return write


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


def test_bundle_is_used_when_there_is_no_cache(bundle):
    bundle({"BA": {"travnik-s402": [10], "travnik-s403": [1]}})
    assert sorted(runner.known_servers("BA")) == ["travnik-s402-i10", "travnik-s403-i01"]
    assert runner.known_servers("PT") is None  # not in the snapshot: guessing is still allowed


def test_fresh_cache_beats_the_bundle_and_stale_cache_does_not(bundle):
    bundle({"PT": {"lisbon-s405": [1]}})
    runner.remember_servers("PT", ["lisbon-s407-i09"])
    assert runner.known_servers("PT") == ["lisbon-s407-i09"]
    later = runner.time.time() + runner.SERVER_CACHE_MAX_AGE_SECONDS + 60
    assert runner.known_servers("PT", now=later) == ["lisbon-s405-i01"]


def test_cache_lives_in_the_users_cache_dir(isolated_home):
    runner.remember_servers("UA", ["kiev-s401-i01"])
    path = isolated_home / ".cache" / "cyberghost" / "servers.json"
    assert json.loads(path.read_text())["countries"]["UA"]["servers"] == {"kiev-s401": [1]}
    assert (path.parent.stat().st_mode & 0o777) == 0o700


def test_corrupt_or_oversized_lists_are_ignored(bundle, tmp_path, monkeypatch):
    garbage = tmp_path / "garbage.json"
    garbage.write_text("{not json")
    monkeypatch.setattr(runner, "BUNDLED_SERVERS_PATH", str(garbage))
    assert not runner.known_servers("PT")
    monkeypatch.setattr(runner, "MAX_SERVER_LIST_BYTES", 4)
    bundle({"PT": {"lisbon-s405": [1]}})
    assert not runner.known_servers("PT")


def test_probe_sample_spreads_across_racks_and_is_capped():
    names = [f"berlin-s{rack}-i{i:02d}" for rack in (451, 452, 453) for i in range(1, 60)]
    sample = runner.probe_sample(names, size=12)
    assert len(sample) == 12 and len(set(sample)) == 12
    racks = [name.split("-s")[1].split("-")[0] for name in sample]
    assert {racks.count(rack) for rack in set(racks)} == {4}  # round-robin, 4 per rack


def test_fallback_probes_real_names_before_guessing(bundle):
    bundle({"BA": {"travnik-s402": [10]}})
    probed = []

    def probe(hosts, **kwargs):
        probed.append(list(hosts))
        return [host for host in hosts if host == "travnik-s402-i10.cg-dialup.net"]

    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "reachable_endpoints", side_effect=probe):
            _, candidates = runner.select_native_candidates("BA")
    assert candidates == ["travnik-s402-i10.cg-dialup.net"]
    assert probed == [["travnik-s402-i10.cg-dialup.net"]]  # the guessed pool was never needed


def test_guessed_pool_remains_the_last_resort(bundle):
    bundle({"PT": {"lisbon-s499": [1]}})  # known but unreachable
    calls = []

    def probe(hosts, **kwargs):
        calls.append(len(hosts))
        return ["lisbon-s401-i01.cg-dialup.net"] if len(calls) == 2 else []

    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "reachable_endpoints", side_effect=probe):
            _, candidates = runner.select_native_candidates("PT")
    assert calls[0] == 1 and calls[1] == len(runner.DIALUP_RACKS) * len(runner.DIALUP_INSTANCES)
    assert candidates == ["lisbon-s401-i01.cg-dialup.net"]


def test_a_live_lookup_refreshes_the_cache(bundle):
    import base64

    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    session = {"jwt": f"{part({})}.{part({'exp': 4_000_000_000})}.sig"}
    location = mock.Mock(
        status_code=200,
        _cyberghost_body=json.dumps({"id": 1, "location": {"latitude": 1.0, "longitude": 2.0}}).encode(),
    )
    rows = mock.Mock(status_code=200, _cyberghost_body=json.dumps([{"name": "Travnik-S402-i10", "full": "0"}]).encode())
    with mock.patch.object(runner, "api_request", side_effect=[location, rows]):
        assert runner.live_server_inventory("BA", session) == ["travnik-s402-i10"]
    assert runner.known_servers("BA") == ["travnik-s402-i10"]


def test_country_without_wireguard_servers_fails_fast(bundle):
    bundle({"KE": {}})
    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "reachable_endpoints", side_effect=AssertionError("must not guess")):
            with pytest.raises(RuntimeError, match="no WireGuard servers for KE"):
                runner.select_native_candidates("KE")


def test_nospy_servers_are_a_last_choice():
    names = ["nospybucharest-s408-i01", "bucharest-s492-i03"]
    assert runner.probe_sample(names) == ["bucharest-s492-i03"]
    assert runner.probe_sample(["nospybucharest-s408-i01"]) == ["nospybucharest-s408-i01"]
    rows = [
        {"name": "NoSpyBucharest-S408-i01", "full": "0", "totalusers": "0", "Max_Users": "50"},
        {"name": "Bucharest-S492-i03", "full": "0", "totalusers": "40", "Max_Users": "50"},
    ]
    assert runner.parse_live_inventory(rows) == ["bucharest-s492-i03", "nospybucharest-s408-i01"]


def test_last_resort_cities_match_the_real_list():
    data = json.load(open(os.path.join(ROOT, "servers.json"), encoding="utf-8"))["countries"]
    for code, grouped in data.items():
        if grouped:
            cities = {prefix.rsplit("-s", 1)[0] for prefix in grouped}
            assert runner.DIALUP_CITY_MAP[code] in cities, (code, sorted(cities))


def test_shipped_snapshot_is_valid_and_complete():
    path = os.path.join(ROOT, "servers.json")
    data = json.load(open(path, encoding="utf-8"))
    assert os.path.getsize(path) < runner.MAX_SERVER_LIST_BYTES
    countries = data["countries"]
    for code, grouped in countries.items():
        names = runner.expand_server_names(grouped)
        # Every stored name survives the strict selector validation.
        assert len(names) == sum(len(numbers) for numbers in grouped.values()), code
    missing = sorted(set(runner.CITY_MAP) - {"UK"} - set(countries))
    assert not missing, f"snapshot lacks {missing}; rerun scripts/update-servers.py"
