import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  name: "ConnectionOrchestration"
  Component {
    id: factory
    Plugin.Service {}
  }

  function readyService(settings) {
    var service = createTemporaryObject(factory, this, {
      settings: settings
    })
    verify(service !== null)
    service.readyWg = true
    service.readyDns = true
    service.readyRequests = true
    service.readyCreds = true
    service.helperInstalled = true
    service.helperPresent = true
    service.readyCli = true
    service.cliConfigured = true
    return service
  }

  function actionProcess(service) {
    for (var i = 0; i < service.children.length; i++) {
      var command = service.children[i].command
      if (command && command[0] === "/usr/bin/pkexec")
        return service.children[i]
    }
    return null
  }

  function actionCommand(service) {
    var process = actionProcess(service)
    return process ? process.command : []
  }

  function statusProcess(service) {
    for (var i = 0; i < service.children.length; i++) {
      var command = service.children[i].command
      if (command && command.indexOf("status") >= 0)
        return service.children[i]
    }
    return null
  }

  function test_connectMigratesOldExactServerToAutomaticWireGuard() {
    var service = readyService({
      defaultCountry: "PT",
      serverSelection: "lisbon-s405-i19"
    })
    service.toggle()
    var command = actionCommand(service)
    verify(command.indexOf("--server") < 0)
    compare(command[command.indexOf("--protocol") + 1], "wireguard")
    compare(service.serverSelection, "fastest")
  }

  function test_staleStatusCannotOverwriteConnectResult() {
    var service = readyService({ defaultCountry: "PT" })
    service.refresh()
    var status = statusProcess(service)
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    status.stdout.read('{"connected":false,"backend":null}')
    status.running = false
    status.exited(0)
    var action = actionProcess(service)
    action.stdout.read('{"ok":true,"action":"connect","backend":"wireguard"}')
    action.running = false
    action.exited(0)
    compare(service.connected, true)
    verify(service.statusGeneration > 0)
  }

  function test_staleStatusErrorDoesNotEraseActionError() {
    var service = readyService({ defaultCountry: "PT" })
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    var status = statusProcess(service)
    status.running = false
    status.stderr.read("old status failure")
    status.exited(1)
    var action = actionProcess(service)
    action.stderr.read("not authorized")
    action.running = false
    action.exited(1)
    verify(service.lastError.length > 0)
  }

  function test_malformedStatusIsUnknownNotDisconnected() {
    var service = readyService({ defaultCountry: "PT" })
    service.connected = true
    service.parseStatus('{}')
    compare(service.connected, true)
    verify(service.statusUnknown)
    verify(service.statusProbeError.length > 0)
  }

  function test_nonzeroActionWithSuccessJsonDoesNotConnect() {
    var service = readyService({ defaultCountry: "PT" })
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    var action = actionProcess(service)
    action.stdout.read('{"ok":true,"action":"connect"}')
    action.running = false
    action.exited(1)
    compare(service.connected, false)
    verify(service.statusUnknown)
  }

  function test_timeoutLeavesOutcomeUnknown() {
    var service = readyService({ defaultCountry: "PT" })
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    var action = actionProcess(service)
    action.timedOut = true
    action.running = false
    action.exited(1)
    verify(service.statusUnknown)
    verify(service.lastError.indexOf("unknown") >= 0)
  }

  function test_optionalInventoryDoesNotBlockDisconnect() {
    var service = readyService({
      defaultCountry: "PT"
    })
    service.connected = true
    service.refreshServers()
    compare(service.loadingServers, false)
    service.toggle()
    verify(actionCommand(service).indexOf("disconnect") >= 0)
  }

  function test_oldStreamingSettingsDoNotStartVendorInventory() {
    var service = readyService({ serverType: "streaming", protocol: "openvpn" })
    service.refreshStreamingServices()
    compare(service.serverType, "traffic")
    compare(service.protocol, "wireguard")
    for (var i = 0; i < service.children.length; i++) {
      var command = service.children[i].command
      verify(!command || command.indexOf("streaming-services") < 0)
    }
  }

  function ipProcess(service) {
    for (var i = 0; i < service.children.length; i++) {
      var command = service.children[i].command
      if (command && command[0] === "/usr/bin/curl")
        return service.children[i]
    }
    return null
  }

  function test_ipLookupUsesIpv4AndRejectsApiErrors() {
    var service = readyService({})
    service.refreshIpInfo(true)
    verify(ipProcess(service).command.indexOf("--ipv4") >= 0)
    service.parseIpInfo('{"success":false,"ip":"203.0.113.9"}')
    compare(service.publicIp, "")
  }

  function test_oldIpResponseCannotDescribeANewTunnel() {
    var service = readyService({})
    service.refreshIpInfo(true)
    var process = ipProcess(service)
    process.stdout.read('{"success":true,"ip":"203.0.113.9"}')
    service.connected = true
    process.running = false
    process.exited(0)
    compare(service.publicIp, "")
    compare(process.running, true)
  }

  function test_unconfiguredCliCannotLaunchAdvancedConnection() {
    var service = readyService({
      protocol: "openvpn"
    })
    service.cliConfigured = false
    service.connectTo("PT", "openvpn", "traffic", "", "fastest")
    compare(actionCommand(service).length, 0)
    verify(service.lastError.indexOf("native WireGuard") >= 0)
    service.cliConfigured = true
    service.connectTo("PT", "wireguard", "torrent", "", "fastest")
    compare(actionCommand(service).length, 0)
  }

  function test_lateSettingsRestoreDoesNotWriteOrResetManualChoice() {
    var service = readyService({})
    var writes = []
    service.settingChanged.connect(function (key, value) {
      writes.push(key)
    })
    service.settings = {
      defaultCountry: "ES",
      serverSelection: "madrid-s10-i2",
      hideDetails: true
    }
    compare(service.country, "ES")
    compare(service.serverSelection, "fastest")
    compare(service.hideDetails, true)
    compare(writes.length, 0)
  }
}
