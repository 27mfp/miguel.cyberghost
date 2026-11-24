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
    compare(restored.protocol, "wireguard")
    compare(restored.serverType, "traffic")
    compare(restored.serverSelection, "fastest")
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
    // NetworkManager (network), python-requests and linked credentials are
    // the only prerequisites; there is no helper to install or update.
    compare(ServiceUtils.setupState(false, true, true), "first-run")
    compare(ServiceUtils.setupState(true, false, true), "first-run")
    compare(ServiceUtils.setupState(true, true, false), "first-run")
    compare(ServiceUtils.setupState(true, true, true), "ready")
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
    verify(Countries.isSupportedCountry(" pt "))
    verify(!Countries.isSupportedCountry("XX"))
  }

  function test_countryTableShapeAndDropdown() {
    compare(Countries.allCountries.length, 94)
    var seen = {}
    for (var i = 0; i < Countries.allCountries.length; i++) {
      var country = Countries.allCountries[i]
      verify(/^[A-Z]{2}$/.test(country.code))
      verify(!seen[country.code])
      verify(country.name.length > 0)
      verify(country.flag.length > 0)
      seen[country.code] = true
    }
    compare(Countries.popularCountries.length, 8)
    for (var j = 0; j < Countries.popularCountries.length; j++)
      verify(Countries.popularCountries[j].code.length === 2)
    var options = Countries.dropdownOptions()
    compare(options.length, 94)
    compare(options[0].label.indexOf(options[0].value) !== -1, true)
    compare(Countries.countryName("PT"), "Portugal")
    compare(Countries.countryFlag("PT"), "🇵🇹")
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

  function test_transferFormattingMatchesOmarchyNetworkPanel() {
    compare(ServiceUtils.formatBytes(-1), "--")
    compare(ServiceUtils.formatBytes(0), "0 B")
    compare(ServiceUtils.formatBytes(1536), "1.5 KB")
    compare(ServiceUtils.formatBytes(282.4 * 1024 * 1024), "282.4 MB")
    compare(ServiceUtils.formatBytes(8.2 * 1024 * 1024 * 1024), "8.20 GB")
    compare(ServiceUtils.formatRate(-1), "--")
    compare(ServiceUtils.formatRate(505036.8), "493.2 KB/s")
  }

  function test_barTooltipMatchesConnectionState() {
    compare(ServiceUtils.barTooltip({}), "CyberGhost VPN: setup incomplete — click for steps")
    compare(ServiceUtils.barTooltip({ setupDone: true, statusUnknown: true }), "CyberGhost VPN: status unavailable — click to reconcile")
    compare(ServiceUtils.barTooltip({ setupDone: true, legacyTunnel: true }), "CyberGhost VPN: previous helper tunnel active — click to disconnect")
    compare(ServiceUtils.barTooltip({
      setupDone: true,
      connecting: true,
      country: "ES",
      countryName: "Spain"
    }), "CyberGhost VPN: Connecting to Spain (ES)…")
    compare(ServiceUtils.barTooltip({ setupDone: true, disconnecting: true }), "CyberGhost VPN: Disconnecting…")
    compare(ServiceUtils.barTooltip({
      setupDone: true,
      connected: true,
      publicIp: "198.51.100.7"
    }), "CyberGhost VPN: Connected • 198.51.100.7")
    compare(ServiceUtils.barTooltip({
      setupDone: true,
      connected: true,
      hideDetails: true,
      publicIp: "198.51.100.7"
    }), "CyberGhost VPN: Connected")
    compare(ServiceUtils.barTooltip({ setupDone: true }), "CyberGhost VPN: Disconnected (Click to open)")
  }

  function test_actionResultAcceptsLogout() {
    compare(ServiceUtils.parseActionResult('{"ok":true,"action":"logout"}').action, "logout")
    compare(ServiceUtils.parseActionResult('{"ok":true,"action":"register"}'), null)
  }

  function test_statusSampleNeedsTwoSamplesForARate() {
    var first = ServiceUtils.statusSample({
      connected: true,
      rx_bytes: 1000,
      tx_bytes: 500,
      endpoint: "198.51.100.10:1337",
      transfer: "1000 B received, 500 B sent"
    }, {}, 1000)
    compare(first.rxRate, -1)
    compare(first.txRate, -1)
    compare(first.counterSampleAt, 1000)
    compare(first.rxBytes, 1000)
    compare(first.txBytes, 500)
    compare(first.endpoint, "198.51.100.10:1337")
    compare(first.rxIdleSec, 0)

    var second = ServiceUtils.statusSample({
      connected: true,
      rx_bytes: 1400,
      tx_bytes: 600
    }, first, 3000)
    compare(second.rxRate, 200)
    compare(second.txRate, 50)
    compare(second.counterSampleAt, 3000)
    // New traffic means the idle watchdog restarts.
    compare(second.rxChangedAt, 3000)
  }

  function test_statusSampleCountsIdleSecondsWithoutTraffic() {
    var first = ServiceUtils.statusSample({
      connected: true,
      rx_bytes: 1000,
      tx_bytes: 500
    }, {}, 1000)
    var second = ServiceUtils.statusSample({
      connected: true,
      rx_bytes: 1000,
      tx_bytes: 500
    }, first, 4000)
    compare(second.rxChangedAt, 1000)
    compare(second.rxIdleSec, 3)
  }

  function test_statusSampleResetsOnCounterResetOrMissingData() {
    var reset = ServiceUtils.statusSample({
      connected: true,
      rx_bytes: 10,
      tx_bytes: 5
    }, {
      rxBytes: 1000,
      txBytes: 500,
      rxRate: 10,
      txRate: 5,
      counterSampleAt: 1000,
      sampleRx: 1000,
      sampleTx: 500
    }, 2000)
    compare(reset.rxRate, -1)
    compare(reset.txRate, -1)
    compare(reset.counterSampleAt, 2000)

    var missing = ServiceUtils.statusSample({
      connected: true
    }, {}, 2000)
    compare(missing.rxBytes, -1)
    compare(missing.counterSampleAt, 0)
    compare(missing.rxIdleSec, 0)

    var legacy = ServiceUtils.statusSample({
      connected: true,
      backend: "legacy",
      rx_bytes: 10
    }, {}, 2000)
    compare(legacy.rxBytes, -1)
  }

  function test_ipInfoValidatesAndNormalizesTheResponse() {
    var info = ServiceUtils.ipInfo('{"success":true,"ip":"198.51.100.7","city":"Lisbon","country_code":"pt","connection":{"isp":"Example"}}')
    compare(info.ip, "198.51.100.7")
    compare(info.city, "Lisbon")
    compare(info.country, "PT")
    compare(info.org, "Example")
    compare(ServiceUtils.ipInfo('{"ip":"not an ip"}'), null)
    compare(ServiceUtils.ipInfo('{"success":false,"ip":"198.51.100.7"}'), null)
    compare(ServiceUtils.ipInfo("not json"), null)
    compare(ServiceUtils.ipInfo(""), null)
  }

  function test_connectResultOnlyAcceptsValidatedServers() {
    var result = ServiceUtils.connectResult({
      country: "ES",
      server: "madrid-s402-i05.cg-dialup.net"
    }, "PT")
    compare(result.country, "ES")
    compare(result.server, "madrid-s402-i05")
    var fallback = ServiceUtils.connectResult({
      country: "not-a-code",
      server: "fastest"
    }, "PT")
    compare(fallback.country, "PT")
    compare(fallback.server, "")
    var invalid = ServiceUtils.connectResult({
      country: "ES",
      server: "madrid-s402-i05.evil.example"
    }, "PT")
    compare(invalid.server, "")
  }
}
