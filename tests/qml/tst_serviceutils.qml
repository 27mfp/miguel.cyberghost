import QtQuick
import QtTest
import "../../Countries.js" as Countries
import "../../ServiceUtils.js" as ServiceUtils

TestCase {
  name: "ServiceUtils"

  function test_appendBounded() {
    compare(ServiceUtils.appendBounded("", "hello", 10), "hello")
    var bounded = ServiceUtils.appendBounded("12345", "67890", 7)
    verify(bounded.indexOf("[output truncated]") !== -1)
    compare(ServiceUtils.appendBounded(bounded, "ignored", 7), bounded)
  }

  function test_countryCompatibility() {
    verify(Countries.isSupportedCountry("UK"))
    compare(Countries.countryByCode("UK").code, "GB")
  }

  function test_serverSelectorValidation() {
    verify(ServiceUtils.isValidServerSelector("fastest"))
    verify(ServiceUtils.isValidServerSelector("lisbon-s405-i19"))
    verify(!ServiceUtils.isValidServerSelector("lisbon-s405"))
    verify(!ServiceUtils.isValidServerSelector("lisbon-s405-i19.cg-dialup.net"))
  }

  function test_parseActionResult() {
    var result = ServiceUtils.parseActionResult("progress\n{\"ok\":true,\"action\":\"connect\",\"backend\":\"wireguard\"}")
    verify(result !== null)
    compare(result.ok, true)
    compare(result.action, "connect")
    compare(ServiceUtils.parseActionResult("not json"), null)
    compare(ServiceUtils.parseActionResult('{"ok":true,"action":"status"}'), null)
  }

  function test_cleanProcessError() {
    compare(ServiceUtils.cleanProcessError("Traceback (most recent call last):\n  File \\\"runner.py\\\"\nError: failed", "fallback"), "failed")
    compare(ServiceUtils.cleanProcessError("", "fallback"), "fallback")
  }
}
