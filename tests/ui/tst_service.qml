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
    service.readyCli = true
    service.cliConfigured = true
    return service
  }

  function actionCommand(service) {
    for (var i = 0; i < service.children.length; i++) {
      var command = service.children[i].command
      if (command && command[0] === "/usr/bin/pkexec")
        return command
    }
    return []
  }

  function test_connectKeepsExactServerSelectedInUi() {
    var service = readyService({
      defaultCountry: "PT",
      serverSelection: "lisbon-s405-i19"
    })
    service.toggle()
    var command = actionCommand(service)
    verify(command.indexOf("--server") >= 0)
    compare(command[command.indexOf("--server") + 1], "lisbon-s405-i19")
  }

  function test_optionalInventoryDoesNotBlockDisconnect() {
    var service = readyService({
      defaultCountry: "PT"
    })
    service.connected = true
    service.refreshServers()
    compare(service.loadingServers, true)
    service.toggle()
    verify(actionCommand(service).indexOf("disconnect") >= 0)
  }

  function test_streamingRefreshKeepsInFlightOutputAndSelectedProfile() {
    var service = readyService({
      serverType: "streaming"
    })
    service.streamingService = "Netflix"
    service.refreshStreamingServices()
    var process = null
    for (var i = 0; i < service.children.length; i++) {
      var command = service.children[i].command
      if (command && command.indexOf("streaming-services") >= 0)
        process = service.children[i]
    }
    verify(process !== null)
    process.stdout.read('[{"value":"Prime","label":"Prime"},{"value":"Netflix","label":"Netflix"}]')
    service.refreshStreamingServices()
    process.running = false
    process.exited(0)
    compare(service.streamingOptions.length, 2)
    compare(service.streamingService, "Netflix")
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
    service.toggle()
    compare(actionCommand(service).length, 0)
    verify(service.lastError.indexOf("CLI account setup") >= 0)
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
    compare(service.serverSelection, "madrid-s10-i2")
    compare(service.hideDetails, true)
    compare(writes.length, 0)
  }
}
