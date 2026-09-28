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
    service.readyNm = true
    service.nmPermission = "yes"
    service.readyRequests = true
    service.readyCreds = true
    service.readyCli = false
    service.cliConfigured = false
    return service
  }

  function named(item, name) {
    for (var i = 0; i < item.children.length; i++) {
      var child = item.children[i]
      if (child.objectName === name)
        return child
      var nested = named(child, name)
      if (nested)
        return nested
    }
    return null
  }

  function actionProcess(service) {
    return named(service, "actionProcess")
  }

  function actionCommand(service) {
    var process = actionProcess(service)
    return process && process.command ? process.command : []
  }

  function statusProcess(service) {
    return named(service, "statusProcess")
  }

  function inventoryProcess(service) {
    for (var i = 0; i < service.children.length; i++) {
      var child = service.children[i]
      for (var j = 0; child.children && j < child.children.length; j++) {
        var command = child.children[j].command
        if (command && command.indexOf("servers") >= 0)
          return child.children[j]
      }
    }
    return null
  }

  function test_connectAndDisconnectRunUnprivileged() {
    var service = readyService({ defaultCountry: "PT" })
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    var command = actionCommand(service)
    compare(command[0], "/usr/bin/python3")
    compare(command[1], service.runnerPath)
    compare(command[2], "connect")
    verify(command.indexOf("--json") >= 0)
    var action = actionProcess(service)
    action.stdout.read('{"ok":true,"action":"connect","backend":"networkmanager"}')
    action.running = false
    action.exited(0)
    compare(service.connected, true)

    service.disconnect()
    compare(actionCommand(service).join(" "), "/usr/bin/python3 " + service.runnerPath + " disconnect --json")
  }

  function test_setupNeedsNetworkManagerPermission() {
    var service = readyService({})
    verify(service.setupDone)
    service.nmPermission = "auth"
    verify(service.setupDone)
    service.nmPermission = "no"
    verify(!service.setupDone)
    service.nmPermission = "yes"
    service.readyNm = false
    verify(!service.setupDone)
  }

  function test_privilegedSetupUsesOmarchyFloatingTerminal() {
    var service = readyService({})
    service.installDeps()
    compare(named(service, "depsProcess").command.join(" "), "omarchy-launch-floating-terminal-with-presentation omarchy-pkg-add python-requests")
    service.openLegacyCleanup()
    var cleanup = named(service, "legacyCleanupProcess")
    compare(cleanup.command[1], 'bash "$CYBERGHOST_LEGACY_CLEANUP"')
    compare(cleanup.environment.CYBERGHOST_LEGACY_CLEANUP, service.legacyCleanupPath)
    verify(/\/scripts\/remove-legacy-helper\.sh$/.test(service.legacyCleanupPath))
    cleanup.exited(0)
    compare(Object.keys(cleanup.environment).length, 0)
  }

  function test_checkResultDrivesReadinessAndLegacyCleanup() {
    var service = createTemporaryObject(factory, this, {})
    var check = named(service, "checkProcess")
    service.checkOutput = JSON.stringify({ nm: true, nm_permission: "yes", requests: true, credentials: true, legacy_helper: true, legacy_polkit_rule: false, plugin_version: "1.7.0" })
    check.exited(0)
    verify(service.setupDone)
    verify(service.legacyCleanupAvailable)
    service.parseStatus('{"connected":true,"backend":"legacy","state":"","interface":"cyberghost"}')
    verify(!service.legacyCleanupAvailable)
  }

  function test_legacyTunnelDisconnectsThroughTheInstalledHelper() {
    var service = readyService({})
    service.parseStatus('{"connected":true,"backend":"legacy","state":"","interface":"cyberghost"}')
    verify(service.legacyTunnel)
    verify(service.connected)
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    compare(actionCommand(service).length, 0)
    verify(service.lastError.indexOf("previous CyberGhost root helper") >= 0)

    service.legacyHelper = false
    service.disconnect()
    compare(actionCommand(service).length, 0)
    verify(service.lastError.indexOf("wg-quick down") >= 0)

    service.legacyHelper = true
    service.disconnect()
    compare(actionCommand(service).join(" "), "/usr/bin/pkexec /usr/local/bin/cyberghost-runner disconnect --json")
  }

  function test_runnerLegacyCodeSwitchesToLegacyState() {
    var service = readyService({})
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    var action = actionProcess(service)
    action.stdout.read('{"ok":false,"action":"connect","error":"old tunnel","code":"legacy_tunnel"}')
    action.running = false
    action.exited(1)
    verify(service.legacyTunnel)
    verify(!service.statusUnknown)
    verify(service.lastError.indexOf("previous CyberGhost root helper") >= 0)
  }

  function test_receiveCounterDrivesStaleWarning() {
    var service = readyService({})
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated","rx_bytes":100,"tx_bytes":50}')
    verify(!service.tunnelStale)
    service.rxChangedAt = Date.now() - 200000
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated","rx_bytes":100,"tx_bytes":90}')
    verify(service.tunnelStale)
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated","rx_bytes":400,"tx_bytes":90}')
    verify(!service.tunnelStale)
  }

  function test_liveInventoryServerIsPassedToConnect() {
    var service = readyService({ defaultCountry: "EG" })
    service.readyCli = true
    service.cliConfigured = true
    service.connectTo("EG", "wireguard", "traffic", "", "fastest")
    compare(actionCommand(service).length, 0)
    verify(service.resolvingAutomaticServer)

    var inventory = inventoryProcess(service)
    verify(inventory !== null)
    inventory.stdout.read('[{"server":"cairo-s12-i07","city":"Cairo","load":14}]')
    inventory.running = false
    inventory.exited(0)

    var command = actionCommand(service)
    compare(command[command.indexOf("--server") + 1], "cairo-s12-i07")
    compare(service.serverSelection, "fastest")
  }

  function test_disconnectDuringInventoryDoesNotReconnect() {
    var service = readyService({ defaultCountry: "EG" })
    service.readyCli = true
    service.cliConfigured = true
    service.connectTo("EG", "wireguard", "traffic", "", "fastest")
    var inventory = inventoryProcess(service)
    verify(service.resolvingAutomaticServer)

    service.disconnect()
    compare(service.resolvingAutomaticServer, false)
    var action = actionProcess(service)
    verify(action.command.indexOf("disconnect") >= 0)
    action.stdout.read('{"ok":true,"action":"disconnect","backend":"wireguard"}')
    action.running = false
    action.exited(0)

    inventory.stdout.read('[{"server":"cairo-s12-i07","city":"Cairo","load":14}]')
    inventory.running = false
    inventory.exited(0)
    verify(action.command.indexOf("connect") < 0)
    compare(service.connected, false)
  }

  function test_cliLossDuringInventoryFallsBackWithoutStayingBusy() {
    var service = readyService({ defaultCountry: "EG" })
    service.readyCli = true
    service.cliConfigured = true
    service.connectTo("EG", "wireguard", "traffic", "", "fastest")
    var inventory = inventoryProcess(service)
    verify(service.resolvingAutomaticServer)

    service.readyCli = false
    compare(service.resolvingAutomaticServer, false)
    var action = actionProcess(service)
    verify(action.command.indexOf("connect") >= 0)
    verify(action.command.indexOf("--server") < 0)

    inventory.running = false
    inventory.exited(1)
    compare(action.command.filter(function (value) { return value === "connect" }).length, 1)
  }

  function test_inventoryCannotConnectAfterLegacyTunnelAppears() {
    var service = readyService({ defaultCountry: "EG" })
    service.readyCli = true
    service.cliConfigured = true
    service.connectTo("EG", "wireguard", "traffic", "", "fastest")
    var inventory = inventoryProcess(service)
    service.legacyTunnel = true

    inventory.stdout.read('[{"server":"cairo-s12-i07","city":"Cairo","load":14}]')
    inventory.running = false
    inventory.exited(0)
    compare(actionCommand(service).length, 0)
    verify(service.lastError.indexOf("previous CyberGhost root helper") >= 0)
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

  function test_logoutRunsUnprivilegedAndRechecksSetup() {
    var service = readyService({ defaultCountry: "PT" })
    service.connected = true
    service.logout()
    compare(actionCommand(service).join(" "), "/usr/bin/python3 " + service.runnerPath + " logout --json")
    verify(service.disconnecting)
    var action = actionProcess(service)
    action.stdout.read('{"ok":true,"action":"logout","logged_out":true,"disconnected":true,"connected":false,"remaining_source":""}')
    action.running = false
    action.exited(0)
    compare(service.connected, false)
    compare(service.lastError, "")
    verify(named(service, "checkProcess").running)
  }

  function test_logoutRefusesWhileALegacyTunnelIsUp() {
    var service = readyService({})
    service.legacyTunnel = true
    service.logout()
    compare(actionCommand(service).length, 0)
    verify(service.lastError.indexOf("previous CyberGhost root helper") >= 0)
  }

  function test_activeCountryDrivesTheSwitchAction() {
    var service = readyService({ defaultCountry: "PT" })
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    var action = actionProcess(service)
    action.stdout.read('{"ok":true,"action":"connect","backend":"networkmanager","country":"PT","server":"lisbon-s405-i01.cg-dialup.net"}')
    action.running = false
    action.exited(0)
    compare(service.activeCountry, "PT")
    compare(service.activeServer, "lisbon-s405-i01")
    verify(!service.switchAvailable)
    service.setCountry("ES")
    verify(service.switchAvailable)
    service.parseStatus('{"connected":false,"backend":null,"state":"","interface":null}')
    compare(service.activeCountry, "")
    compare(service.activeServer, "")
    verify(!service.switchAvailable)
  }

  function test_transferRatesNeedTwoSamplesOfOneSession() {
    var service = readyService({})
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated","rx_bytes":1000,"tx_bytes":500}')
    compare(service.rxRate, -1)
    service.counterSampleAt = Date.now() - 2000
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated","rx_bytes":5000,"tx_bytes":1500}')
    verify(service.rxRate > 1500 && service.rxRate <= 2000)
    verify(service.txRate > 375 && service.txRate <= 500)
    // A counter going backwards is a new interface, not negative traffic.
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated","rx_bytes":10,"tx_bytes":10}')
    compare(service.rxRate, -1)
    compare(service.rxBytes, 10)
  }

  function test_liveSessionStartsTheBackgroundServerSync() {
    var service = createTemporaryObject(factory, this, {})
    var check = named(service, "checkProcess")
    var sync = named(service, "syncProcess")
    service.checkOutput = JSON.stringify({ nm: true, nm_permission: "yes", requests: true, credentials: true, server_list: "probe" })
    check.exited(0)
    verify(!sync.running)
    service.checkOutput = JSON.stringify({ nm: true, nm_permission: "yes", requests: true, credentials: true, server_list: "live" })
    check.exited(0)
    verify(sync.running)
    compare(sync.command[2], "sync-servers")
    sync.stdout.read('{"progress": 12, "total": 94, "country": "CZ"}')
    compare(service.syncProgress, "12/94")
    sync.stdout.read('{"synced": 94, "remaining": 0, "stopped": ""}')
    compare(service.syncProgress, "12/94")
    sync.running = false
    sync.exited(0)
    compare(service.syncProgress, "")
  }

  function test_connectAndLogoutStopTheServerSync() {
    var service = readyService({ defaultCountry: "PT" })
    var sync = named(service, "syncProcess")
    sync.running = true
    service.connectTo("PT", "wireguard", "traffic", "", "fastest")
    verify(!sync.running)
    var action = actionProcess(service)
    action.stdout.read('{"ok":true,"action":"connect","backend":"networkmanager","country":"PT"}')
    action.running = false
    action.exited(0)
    sync.running = true
    service.logout()
    verify(!sync.running)
  }
}
