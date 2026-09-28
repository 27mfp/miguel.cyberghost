"""Server selection without the vendor CLI. The network probe is stubbed."""

import time
from unittest import mock

import pytest
from runner_support import load_runner

runner = load_runner()


@pytest.fixture(autouse=True)
def no_snapshot(monkeypatch):
    # These tests cover the live list and the guessed pool; the user's
    # server cache has its own tests in test_server_data.py.
    monkeypatch.setattr(runner, "known_servers", lambda *args, **kwargs: None)


def select(country, reachable, **kwargs):
    """Run candidate selection with a fake probe that answers `reachable`."""
    seen = {}

    def fake_probe(pool, **probe_kwargs):
        seen["pool"] = pool
        return [host for host in reachable if host in pool]

    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "reachable_endpoints", side_effect=fake_probe):
            try:
                result = runner.select_native_candidates(country, **kwargs)
            except RuntimeError:
                if reachable:
                    raise
                # Nothing answered: the pool that was probed is the result.
                result = None
    return result, seen.get("pool", [])


@pytest.mark.parametrize(
    "country,city",
    [("UA", "kiev"), ("IT", "milano"), ("IL", "jerusalem"), ("KZ", "astana"), ("MA", "rabat"), ("PT", "lisbon")],
)
def test_hostnames_use_the_verified_dialup_city(country, city):
    # These spellings were confirmed by DNS and certificate checks against the
    # live nodes; the CLI keeps its own display names (e.g. kyiv, milan).
    _, pool = select(country, [])
    assert pool and all(host.startswith(city + "-s") for host in pool)
    assert runner.CITY_MAP["UA"] == "kyiv" and runner.CITY_MAP["IT"] == "milan"


def test_pool_covers_racks_beyond_the_old_fixed_four():
    _, pool = select("RO", [])
    racks = {host.split("-s")[1].split("-")[0] for host in pool}
    # Romania is served from 408-418; the old fallback only tried 401/405-407.
    assert {"401", "402", "403", "404", "408", "418"} <= racks


def test_only_reachable_hosts_are_tried_in_probe_order():
    live = ["lisbon-s407-i02.cg-dialup.net", "lisbon-s401-i01.cg-dialup.net"]
    (country, candidates), _ = select("PT", live)
    assert country == "PT"
    assert candidates == live


def test_candidates_stay_capped():
    many = [f"newyork-s{rack}-i{idx}.cg-dialup.net" for rack in range(401, 421) for idx in ("01", "02", "03")]
    (_, candidates), _ = select("US", many)
    assert len(candidates) == runner.MAX_NATIVE_CANDIDATES


def test_no_reachable_server_fails_before_any_key_exchange():
    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "reachable_endpoints", return_value=[]):
            with pytest.raises(RuntimeError, match="No reachable CyberGhost servers found for BA"):
                runner.select_native_candidates("BA")


def test_explicit_or_cli_servers_skip_probing():
    with mock.patch.object(runner, "reachable_endpoints", side_effect=AssertionError("must not probe")):
        _, candidates = runner.select_native_candidates("PT", server="lisbon-s405-i19")
        assert candidates == ["lisbon-s405-i19.cg-dialup.net"]
        live = [{"city": "Lisbon", "instance": "lisbon-s405-i19", "server": "lisbon-s405-i19", "load": 12}]
        with mock.patch.object(runner, "get_servers_for_country", return_value=live):
            _, candidates = runner.select_native_candidates("PT")
        assert candidates == ["lisbon-s405-i19.cg-dialup.net"]


def fake_probe(latencies):
    """Hosts answer after their latency; None means unreachable after 0.3s."""

    def probe(host):
        delay = latencies[host]
        time.sleep(0.3 if delay is None else delay)
        return host, delay

    return probe


def test_probe_orders_by_latency_and_drops_dead_hosts():
    latencies = {"a": 0.15, "b": 0.05, "dead": None, "c": 0.1}
    with mock.patch.object(runner, "_probe_endpoint", side_effect=fake_probe(latencies)):
        assert runner.reachable_endpoints(list(latencies), budget=2, grace=None) == ["b", "c", "a"]


def test_probe_stops_after_the_grace_period_instead_of_waiting_for_slow_hosts():
    latencies = {"fast": 0.05, "slow": 1.5}
    with mock.patch.object(runner, "_probe_endpoint", side_effect=fake_probe(latencies)):
        started = time.monotonic()
        assert runner.reachable_endpoints(list(latencies), budget=3, grace=0.2) == ["fast"]
        assert time.monotonic() - started < 1.0


def test_probe_budget_is_a_hard_limit():
    with mock.patch.object(runner, "_probe_endpoint", side_effect=fake_probe({"stuck": 2.0})):
        started = time.monotonic()
        assert runner.reachable_endpoints(["stuck"], budget=0.3) == []
        assert time.monotonic() - started < 1.0
    assert runner.reachable_endpoints([]) == []


def test_probe_report_lists_reachable_hosts_per_country():
    with mock.patch.object(runner, "known_servers", return_value=["kiev-s401-i01", "kiev-s401-i02"]):
        with mock.patch.object(runner, "reachable_endpoints", return_value=["kiev-s401-i01.cg-dialup.net"]):
            report = runner.probe_servers(["UA"])
    assert report == {"UA": {"city": "kiev", "known": 2, "reachable": ["kiev-s401-i01"]}}


# ---- CyberGhost's live server list (session token) -------------------------


def make_jwt(exp):
    import base64
    import json

    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    return f"{part({'alg': 'HS256'})}.{part({'exp': exp})}.signature"


def api_response(status, body):
    import json

    item = mock.Mock(status_code=status)
    item._cyberghost_body = json.dumps(body).encode()
    return item


def test_session_expiry_is_read_locally():
    now = 1_800_000_000
    assert runner.session_usable(make_jwt(now + 3600), now=now)
    assert not runner.session_usable(make_jwt(now + 30), now=now)  # expiring within a minute
    assert runner.session_usable("opaque-token-without-claims", now=now)  # unknown: let the API decide
    assert not runner.session_usable("", now=now)


def test_live_inventory_parser_accepts_nested_layouts_and_sorts_by_load():
    data = {
        "cities": [
            {
                "city": "Lisbon",
                "instances": [
                    {"instance": "lisbon-s405-i19", "totalusers": 80, "Max_Users": 100},
                    {"instance": "lisbon-s402-i03.cg-dialup.net", "totalusers": 10, "Max_Users": 100},
                ],
            },
            {"city": "Porto", "real": "porto-s401-i01", "totalusers": 50, "Max_Users": 100},
        ]
    }
    assert runner.parse_live_inventory(data) == ["lisbon-s402-i03", "porto-s401-i01", "lisbon-s405-i19"]


@pytest.mark.parametrize(
    "value",
    ["lisbon-s405-i19 endpoint=evil", "../lisbon-s405-i19", "lisbon-s405-i19.evil.example", "", "x" * 300],
)
def test_live_inventory_parser_rejects_injected_names(value):
    assert runner.parse_live_inventory([{"instance": value, "totalusers": 1, "Max_Users": 10}]) == []


def test_live_inventory_is_preferred_when_the_session_is_valid():
    session = {"jwt": make_jwt(4_000_000_000), "user_id": "42"}
    body = [{"instance": "lisbon-s401-i02", "totalusers": 5, "Max_Users": 100}]
    location = api_response(200, {"id": 42, "location": {"latitude": 1.5, "longitude": 2.5}})
    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "api_request", side_effect=[location, api_response(200, body)]) as call:
            with mock.patch.object(runner, "reachable_endpoints", side_effect=AssertionError("must not probe")):
                _, candidates = runner.select_native_candidates("PT", session=session)
    assert candidates == ["lisbon-s401-i02.cg-dialup.net"]
    path = call.call_args.args[1]
    assert path.startswith("/my/servers/filters/74?filter_protocol=wireguard&filter_country=PT&filter_user_id=42&")
    assert call.call_args.kwargs["jwt"] == session["jwt"]


@pytest.mark.parametrize(
    "response",
    [api_response(401, {"error": "unauthorized"}), api_response(200, {"unexpected": True}), api_response(500, {})],
)
def test_unusable_live_inventory_falls_back_to_probing(response, capsys):
    session = {"jwt": make_jwt(4_000_000_000), "user_id": ""}
    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "api_request", return_value=response):
            with mock.patch.object(runner, "reachable_endpoints", return_value=["lisbon-s407-i01.cg-dialup.net"]):
                _, candidates = runner.select_native_candidates("PT", session=session)
    assert candidates == ["lisbon-s407-i01.cg-dialup.net"]
    assert session["jwt"] not in capsys.readouterr().err


def test_expired_session_never_calls_the_api():
    session = {"jwt": make_jwt(1), "user_id": "42"}
    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "api_request", side_effect=AssertionError("expired token was sent")):
            with mock.patch.object(runner, "reachable_endpoints", return_value=["lisbon-s407-i01.cg-dialup.net"]):
                _, candidates = runner.select_native_candidates("PT", session=session)
    assert candidates == ["lisbon-s407-i01.cg-dialup.net"]


def test_vendor_cli_inventory_still_wins():
    session = {"jwt": make_jwt(4_000_000_000)}
    live = [{"city": "Lisbon", "instance": "lisbon-s405-i19", "server": "lisbon-s405-i19", "load": 12}]
    with mock.patch.object(runner, "get_servers_for_country", return_value=live):
        with mock.patch.object(runner, "api_request", side_effect=AssertionError("CLI inventory wins")):
            _, candidates = runner.select_native_candidates("PT", session=session)
    assert candidates == ["lisbon-s405-i19.cg-dialup.net"]


# Shape observed from the live API (September 2026), values anonymized.
LIVE_ROWS = [
    {
        "id": "1",
        "name": "Lisbon-S405-i01",
        "displayName": "Lisbon-S405-i01",
        "ip": "198.51.100.1",
        "full": "0",
        "Max_Users": "48",
        "totalusers": "40",
        "countrycode": "PT",
        "city": "Lisbon",
    },
    {
        "id": "2",
        "name": "Lisbon-S406-i06",
        "displayName": "Lisbon-S406-i06",
        "ip": "198.51.100.2",
        "full": "0",
        "Max_Users": "48",
        "totalusers": "3",
        "countrycode": "PT",
        "city": "Lisbon",
    },
    {
        "id": "3",
        "name": "Lisbon-S407-i02",
        "displayName": "Lisbon-S407-i02",
        "ip": "198.51.100.3",
        "full": "1",
        "Max_Users": "48",
        "totalusers": "0",
        "countrycode": "PT",
        "city": "Lisbon",
    },
]


def test_real_response_shape_counts_are_strings_and_full_servers_are_skipped():
    assert runner.parse_live_inventory(LIVE_ROWS) == ["lisbon-s406-i06", "lisbon-s405-i01"]


def test_the_server_filter_gets_the_accounts_coordinates():
    session = {"jwt": make_jwt(4_000_000_000)}
    account = api_response(200, {"id": 42, "location": {"latitude": 38.7169, "longitude": -9.1399}})
    with mock.patch.object(runner, "api_request", side_effect=[account, api_response(200, LIVE_ROWS)]) as call:
        assert runner.live_server_inventory("PT", session) == ["lisbon-s406-i06", "lisbon-s405-i01"]
    path = call.call_args_list[1].args[1]
    # The API answers 404 "params are missing" without both coordinates.
    assert "filter_user_id=42&filter_user_latitude=38.7169&filter_user_longitude=-9.1399" in path
    assert call.call_args_list[1].kwargs["max_bytes"] >= 1024 * 1024  # large countries exceed 500 KB


def test_missing_coordinates_fall_back_without_querying_servers():
    session = {"jwt": make_jwt(4_000_000_000)}
    with mock.patch.object(runner, "api_request", side_effect=[api_response(200, {"id": 42, "location": {}})]) as call:
        assert runner.live_server_inventory("PT", session) is None
    assert call.call_count == 1


def test_rate_limited_api_falls_back_to_probing():
    session = {"jwt": make_jwt(4_000_000_000)}
    account = api_response(200, {"id": 42, "location": {"latitude": 1.5, "longitude": 2.5}})
    with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
        with mock.patch.object(runner, "api_request", side_effect=[account, api_response(429, {})]):
            with mock.patch.object(runner, "reachable_endpoints", return_value=["lisbon-s407-i01.cg-dialup.net"]):
                _, candidates = runner.select_native_candidates("PT", session=session)
    assert candidates == ["lisbon-s407-i01.cg-dialup.net"]


@pytest.mark.parametrize(
    "value,expected", [("17", 17.0), ("-9.1365919", -9.1365919), (38.5, 38.5), ("1e9", None), (True, None), ("", None)]
)
def test_numbers_from_the_api(value, expected):
    assert runner._number(value) == expected
