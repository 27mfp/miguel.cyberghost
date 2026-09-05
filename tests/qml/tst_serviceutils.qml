import QtQuick
import QtTest
import "../../Countries.js" as Countries
import "../../ServiceUtils.js" as ServiceUtils

TestCase {
  name: "ServiceUtils"

  function test_preferencesRestoreWithoutMutatingSavedSettings() {
    var saved = {
      defaultCountry: "ES",
      serverSelection: "madrid-s10-i2",
      protocol: "openvpn_tcp",
      serverType: "torrent",
      hideDetails: true
    }
    var before = JSON.stringify(saved)
    var restored = ServiceUtils.preferences(saved)
    compare(restored.protocol, "openvpn_tcp")
    compare(restored.serverSelection, "madrid-s10-i2")
    compare(restored.hideDetails, true)
    compare(JSON.stringify(saved), before)
    var invalid = ServiceUtils.preferences({
      protocol: "shell",
      serverType: "other",
      serverSelection: "--bad"
    })
    compare(invalid.protocol, "wireguard")
    compare(invalid.serverType, "traffic")
    compare(invalid.serverSelection, "fastest")
  }

  function test_setupReadiness() {
    compare(ServiceUtils.setupState(false, true, true, false, "", "1.5.4"), "first-run")
    // An incompatible helper is present, but cannot be used to connect.
    compare(ServiceUtils.setupState(true, true, true, false, "1.5.3", "1.5.4"), "update-available")
    compare(ServiceUtils.setupState(true, true, true, true, "1.5.4", "1.5.4"), "ready")
  }

  function test_staleInventoryCannotReplaceCurrentSelection() {
    verify(ServiceUtils.inventoryMatches("PT|wireguard|traffic", "PT", "wireguard", "traffic"))
    verify(!ServiceUtils.inventoryMatches("PT|wireguard|traffic", "ES", "wireguard", "traffic"))
    verify(!ServiceUtils.inventoryMatches("PT|wireguard|traffic", "PT", "wireguard", "torrent"))
    verify(!ServiceUtils.inventoryMatches("PT|wireguard|traffic", "PT", "openvpn", "traffic"))
  }

  function test_inventoryValidation() {
    var options = ServiceUtils.serverOptions([
      {
        server: "lisbon-s405-i19",
        city: "Lisbon",
        load: 18
      },
      {
        server: "lisbon-s405-i19",
        city: "Duplicate",
        load: 18
      },
      {
        server: "lisbon-s405-i20",
        load: 101
      },
      {
        server: "fastest",
        load: 5
      },
      {
        server: "bad",
        load: 5
      }
    ], "Portugal")
    compare(options.length, 2)
    compare(options[0].value, "fastest")
    compare(options[1].value, "lisbon-s405-i19")
  }

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
