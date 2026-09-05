"""Backend transport regression tests."""

import os
import sys
import time
from unittest import mock

from runner_support import SAMPLE_PRIV, SAMPLE_PUB, load_runner

runner = load_runner()


def test_api_app_key_allows_safe_vendor_rotation_override():
    with mock.patch.dict(os.environ, {"CG_APP_KEY": "rotated-public-key"}, clear=False):
        assert runner.api_app_key() == "rotated-public-key"
    with mock.patch.dict(os.environ, {"CG_APP_KEY": "bad\nheader"}, clear=False):
        try:
            runner.api_app_key()
            raise AssertionError("Expected control characters to be rejected")
        except RuntimeError as exc:
            assert "application key" in str(exc)


def test_api_request_uses_direct_verified_session():
    response = mock.Mock()
    response.headers = {}
    response.iter_content.return_value = []
    response._cyberghost_body = b"{}"
    session = mock.Mock()
    session.request.return_value = response
    requests_stub = mock.Mock()
    requests_stub.Session.return_value = session
    with mock.patch.object(runner, "load_requests", return_value=requests_stub):
        assert runner.api_request("POST", "/test", payload={"ok": True}) is response

    assert session.trust_env is False
    session.request.assert_called_once()
    assert session.request.call_args.kwargs["verify"] is True
    assert session.request.call_args.kwargs["allow_redirects"] is False


def test_run_bounded_rejects_excessive_output():
    try:
        runner.run_bounded(
            [sys.executable, "-c", "print('x' * 256)"],
            timeout=5,
            max_output_bytes=64,
        )
        raise AssertionError("Expected output limit to terminate the command")
    except RuntimeError as exc:
        assert "output exceeded" in str(exc)


def test_native_api_runtime_errors_are_returned_without_traceback():
    requests_stub = mock.Mock()
    requests_stub.exceptions.RequestException = Exception
    with mock.patch.object(runner, "get_credentials", return_value=("TOK", "SEC")):
        with mock.patch.object(runner, "generate_wireguard_keys", return_value=(SAMPLE_PRIV, SAMPLE_PUB)):
            with mock.patch.object(runner, "get_servers_for_country", return_value=[]):
                with mock.patch.object(runner, "load_requests", return_value=requests_stub):
                    with mock.patch.object(
                        runner, "api_get", side_effect=RuntimeError("TLS certificate hostname mismatch")
                    ):
                        try:
                            runner.connect("PT", "traffic")
                            raise AssertionError("Expected the native API failure to be reported")
                        except RuntimeError as exc:
                            message = str(exc)
                            assert "TLS certificate hostname mismatch" in message
                            assert "Traceback" not in message


def test_dialup_tls_target_maps_hostname_and_preserves_request():
    addresses = [(runner.socket.AF_INET, runner.socket.SOCK_STREAM, 6, "", ("198.51.100.10", 1337))]
    with mock.patch.object(runner.socket, "getaddrinfo", return_value=addresses) as resolve:
        canonical, connect_host = runner.dialup_tls_target(
            "https://lisbon-s405-i19.cg-dialup.net:1337/addKey?pubkey=test"
        )

    assert canonical == "https://lisbon-rack405.nodes.gen4.ninja:1337/addKey?pubkey=test"
    assert connect_host == "198.51.100.10"
    resolve.assert_called_once_with("lisbon-s405-i19.cg-dialup.net", 1337, type=runner.socket.SOCK_STREAM)

    passthrough = "https://example.com/path"
    assert runner.dialup_tls_target(passthrough) == (passthrough, None)
    try:
        runner.dialup_tls_target("http://lisbon-s405-i19.cg-dialup.net:1337/addKey")
        raise AssertionError("Expected HTTPS-only endpoint validation")
    except RuntimeError as exc:
        assert "HTTPS" in str(exc)


def test_dialup_tls_target_reports_resolution_failure():
    with mock.patch.object(runner.socket, "getaddrinfo", side_effect=OSError("no DNS")):
        try:
            runner.dialup_tls_target("https://lisbon-s405-i19.cg-dialup.net:1337/addKey")
            raise AssertionError("Expected endpoint resolution failure")
        except RuntimeError as exc:
            assert "Could not resolve CyberGhost endpoint" in str(exc)


def test_dialup_tls_target_bounds_dns_resolution():
    def slow_resolution(*args, **kwargs):
        time.sleep(1)
        return []

    with mock.patch.object(runner.socket, "getaddrinfo", side_effect=slow_resolution):
        started = time.monotonic()
        try:
            runner.dialup_tls_target("https://lisbon-s405-i19.cg-dialup.net:1337/addKey", timeout=0.01)
            raise AssertionError("Expected DNS timeout")
        except RuntimeError as exc:
            assert "DNS timed out" in str(exc)
    assert time.monotonic() - started < 0.5


def test_mapped_https_get_uses_pinned_session_without_proxy():
    try:
        import requests
    except ImportError:
        # requests is installed in CI; the local setup wizard intentionally
        # supports running before this optional runtime dependency is present.
        return

    runner._reset_mapped_https_probe()
    try:
        response = object()
        session = requests.Session()
        with mock.patch.object(
            runner,
            "dialup_tls_target",
            return_value=("https://lisbon-rack405.nodes.gen4.ninja:1337/addKey", "198.51.100.10"),
        ):
            with mock.patch.object(requests, "Session", return_value=session):
                with mock.patch.object(session, "get", return_value=response) as get_mock:
                    assert (
                        runner.mapped_https_get(
                            requests,
                            "https://lisbon-s405-i19.cg-dialup.net:1337/addKey",
                            timeout=(1, 1),
                        )
                        is response
                    )

        assert session.trust_env is False
        get_mock.assert_called_once_with("https://lisbon-rack405.nodes.gen4.ninja:1337/addKey", timeout=(1, 1))
        # The probe is cached as successful after the first pinned call.
        assert runner._MAPPED_HTTPS_PROBE_OK is True
        # The adapter classes are cached so a second call does not re-import
        # the urllib3 internals (and so we do not pay the probe cost again).
        cached_classes = runner._MAPPED_ADAPTER_CLASSES
        assert cached_classes is not None
    finally:
        runner._reset_mapped_https_probe()


def test_mapped_https_probe_fails_closed_when_urllib3_drift_breaks_adapter():
    """When urllib3 moves the private symbols the adapter depends on, the probe must fail before any request is sent."""
    runner._reset_mapped_https_probe()
    try:
        with mock.patch.object(
            runner, "_build_mapped_adapter_classes", side_effect=AttributeError("simulated urllib3 drift")
        ):
            try:
                runner._ensure_mapped_https_probe()
            except RuntimeError as exc:
                assert "pinned CyberGhost TLS adapter" in str(exc)
                assert "Upgrade python-requests" in str(exc)
            else:
                raise AssertionError("Expected the probe to fail closed")

        # The failure is cached, so a second call raises the same way
        # without re-running the broken code path.
        with mock.patch.object(
            runner, "_build_mapped_adapter_classes", side_effect=AssertionError("probe should be cached")
        ):
            try:
                runner._ensure_mapped_https_probe()
            except RuntimeError as exc:
                assert "pinned CyberGhost TLS adapter" in str(exc)
    finally:
        runner._reset_mapped_https_probe()


def test_run_bounded_timeout_kills_child_and_does_not_block_on_stdin():
    try:
        runner.run_bounded(
            [sys.executable, "-c", "import time; time.sleep(10)"],
            timeout=0.1,
            input_data=b"x" * 32768,
        )
        raise AssertionError("Expected subprocess timeout")
    except runner.subprocess.TimeoutExpired:
        pass


def test_read_response_bounded_closes_and_limits_body():
    response = mock.Mock()
    response.headers = {}
    response.iter_content.return_value = [b"hello", b" world"]
    assert runner.read_response_bounded(response) == b"hello world"
    response.close.assert_called_once_with()

    oversized = mock.Mock()
    oversized.headers = {}
    oversized.iter_content.return_value = [b"12345", b"6"]
    try:
        runner.read_response_bounded(oversized, max_bytes=5)
        raise AssertionError("Expected response size failure")
    except RuntimeError as exc:
        assert "exceeds" in str(exc)
    oversized.close.assert_called_once_with()

    expired = mock.Mock()
    expired.headers = {}
    expired.iter_content.return_value = [b"late"]
    try:
        runner.read_response_bounded(expired, deadline=0)
        raise AssertionError("Expected HTTP deadline failure")
    except RuntimeError as exc:
        assert "timed out" in str(exc)
    expired.close.assert_called_once_with()
