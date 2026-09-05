import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Countries.js" as Countries
import "ServiceUtils.js" as ServiceUtils

Item {
  id: root

  property var settings: null

  // ---- Public State ----
  property bool connected: false
  property bool connecting: false
  property bool disconnecting: false
  property int _desired: -1 // -1=none, 0=disconnected, 1=connected

  readonly property bool active: _desired === -1 ? (connected || connecting) : (_desired === 1)

  property string country: "PT"
  property string countryName: "Portugal"
  property string countryFlag: "🇵🇹"
  // `fastest` means the lowest-load live instance for the selected country.
  // A concrete value is an exact server name returned by the official CLI.
  property string serverSelection: "fastest"
  readonly property var serverOptions: inventory.options
  readonly property bool loadingServers: inventory.loading
  readonly property string serverError: inventory.error
  property string protocol: "wireguard"
  property string serverType: "traffic"
  property string streamingService: ""
  property var streamingOptions: []

  property string publicIp: ""
  property string publicCity: ""
  property string publicCountry: ""
  property string publicOrg: ""
  property bool fetchingIp: false
  property int networkGeneration: 0
  property int ipRequestGeneration: 0
  property bool ipRefreshPending: false
  onConnectedChanged: {
    networkGeneration++
    publicIp = ""
    publicCity = ""
    publicCountry = ""
    publicOrg = ""
    if (ipInfoProcess.running)
      ipRefreshPending = true
  }

  // Privacy mode: mask IP / location / provider / session in the UI.
  property bool hideDetails: false

  function setHideDetails(hidden) {
    hideDetails = !!hidden
    persistSetting("hideDetails", hideDetails)
  }

  // Live session details from `status --json`
  property string endpoint: ""
  property string transferText: ""
  property int handshakeAgeSec: -1
  readonly property bool tunnelStale: connected && handshakeAgeSec >= 180
  property bool staleNotified: false
  property string lastBackend: ""
  property int statusPollCount: 0

  property string actionStatus: ""
  property string lastError: ""
  property string applyHint: ""
  property string rawStatusText: ""

  // ---- In-panel setup wizard state ----
  property alias regBusy: setup.regBusy
  property alias setupMsg: setup.setupMsg
  property alias depsError: setup.depsError
  property alias polkitStatus: setup.polkitStatus
  property alias registerOutput: setup.registerOutput
  property alias registerError: setup.registerError
  property alias checkOutput: setup.checkOutput
  property string statusOutput: ""
  property string statusError: ""
  property string ipOutput: ""
  property string actionOutput: ""
  property string actionError: ""
  property string streamingServicesOutput: ""
  property string streamingServicesErrorOutput: ""
  property string streamingError: ""
  property string streamingProcessCountry: ""
  readonly property bool depsBusy: setup.depsBusy
  readonly property bool polkitBusy: setup.polkitBusy
  readonly property bool streamingBusy: streamingServicesProcess.running

  property real lastIpFetchAt: 0

  readonly property int refreshIntervalSec: Math.max(5, Math.min(60, parseInt(setting("refreshIntervalSec", 8), 10) || 8))
  readonly property bool busy: actionProcess.running || setup.busy || connecting || disconnecting

  // ---- Onboarding readiness (from runner `check --json`) ----
  property alias readyWg: setup.readyWg
  property alias readyDns: setup.readyDns
  property alias readyRequests: setup.readyRequests
  property alias readyCli: setup.readyCli
  property alias cliConfigured: setup.cliConfigured
  property alias readyCreds: setup.readyCreds
  property alias readyPolkit: setup.readyPolkit
  property alias helperInstalled: setup.helperInstalled
  property alias helperVersion: setup.helperVersion
  property alias pluginVersion: setup.pluginVersion
  // The fixed root helper is mandatory: the UI must never execute mutable
  // plugin code through pkexec. The Polkit rule remains optional.
  readonly property bool setupDone: readyWg && readyDns && readyRequests && readyCreds && helperInstalled

  readonly property string setupCardState: ServiceUtils.setupState(readyWg && readyDns, readyRequests, readyCreds, helperInstalled, helperVersion, pluginVersion)

  SetupController {
    id: setup
    runnerPath: root.runnerPath
    installerPath: root.installerPath
    onRegistered: root.lastError = ""
    onChecked: {
      root.refreshServers()
      if (root.serverType === "streaming")
        root.refreshStreamingServices()
      root.refresh()
    }
    onSendNotification: function (title, body, urgency) {
      root.sendNotification(title, body, urgency)
    }
  }

  // ---- Helper Methods ----
  function setting(key, fallback) {
    if (settings && settings[key] !== undefined)
      return settings[key]
    return fallback
  }

  signal settingChanged(string key, var value)
  function persistSetting(key, value) {
    if (settings && settings[key] === value)
      return
    settingChanged(key, value)
  }

  function setCountry(code) {
    var normalized = String(code || "").trim().toUpperCase()
    if (!/^[A-Z]{2}$/.test(normalized) || !Countries.isSupportedCountry(normalized)) {
      lastError = "Unsupported country code"
      return false
    }
    var c = Countries.countryByCode(normalized)
    country = c.code
    countryName = c.name
    countryFlag = c.flag
    persistSetting("defaultCountry", c.code)
    serverSelection = "fastest"
    persistSetting("serverSelection", serverSelection)
    refreshServers()
    if (serverType === "streaming") {
      streamingService = ""
      refreshStreamingServices()
    }
    return true
  }

  function setProtocol(p) {
    protocol = (p === "openvpn" || p === "openvpn_tcp") ? p : "wireguard"
    persistSetting("protocol", protocol)
    refreshServers()
  }

  function setServerType(t) {
    serverType = (t === "torrent" || t === "streaming") ? t : "traffic"
    persistSetting("serverType", serverType)
    serverSelection = "fastest"
    persistSetting("serverSelection", serverSelection)
    refreshServers()
    if (serverType === "streaming") {
      streamingService = ""
      refreshStreamingServices()
    }
  }

  function setStreamingService(service) {
    streamingService = String(service || "")
  }

  function setServerSelection(selection) {
    var value = String(selection || "fastest").trim().toLowerCase()
    if (!ServiceUtils.isValidServerSelector(value))
      value = "fastest"
    serverSelection = value
    persistSetting("serverSelection", value)
  }

  function refreshServers() {
    inventory.refresh()
  }

  ServerInventory {
    id: inventory
    country: root.country
    countryName: root.countryName
    protocol: root.protocol
    mode: root.serverType
    cliAvailable: root.readyCli && root.cliConfigured
    runnerPath: root.runnerPath
    onLoaded: function (options) {
      var found = options.some(function (item) {
        return item.value === root.serverSelection
      })
      if (!found)
        root.setServerSelection("fastest")
    }
  }

  function refresh() {
    if (!statusProcess.running) {
      statusOutput = ""
      statusError = ""
      statusPollCount += 1
      var shouldProbeCli = connected || lastBackend === "cyberghostvpn" || statusPollCount % 3 === 1
      statusProcess.command = ["/usr/bin/python3", root.runnerPath, "status", "--json"]
      if (!shouldProbeCli)
        statusProcess.command.push("--no-cli")
      statusProcess.running = true
    }
    // Only hit the GeoIP API while connected (and throttled); the panel
    // forces a fresh lookup when it opens so the exposed IP stays current.
    if (connected)
      refreshIpInfo(false)
  }

  function refreshIpInfo(force) {
    if (ipInfoProcess.running) {
      ipRefreshPending = ipRefreshPending || force
      return
    }
    if (!force && Date.now() - lastIpFetchAt < 20000)
      return
    lastIpFetchAt = Date.now()
    if (!connected) {
      publicIp = ""
      publicCity = ""
      publicCountry = ""
      publicOrg = ""
    }
    fetchingIp = true
    ipOutput = ""
    ipRequestGeneration = networkGeneration
    // Force the transport family: ipwho.is ignores the old type query on
    // some responses. IPv6-only hosts report Unavailable rather than a
    // mislabeled IPv4 result. Generation checks reject pre-tunnel replies.
    ipInfoProcess.command = ["/usr/bin/curl", "--ipv4", "--silent", "--show-error", "--fail-with-body", "--connect-timeout", "2", "--max-time", "4", "--max-filesize", "32768", "--proto", "=https", "https://ipwho.is/?type=ipv4"]
    ipInfoProcess.running = true
  }

  readonly property string runnerPath: String(Qt.resolvedUrl("cyberghost_runner.py")).replace(/^file:\/\//, "")
  readonly property string helperPath: "/usr/local/bin/cyberghost-runner"
  readonly property string polkitRulePath: "/etc/polkit-1/rules.d/50-cyberghost.rules"
  readonly property string installerPath: String(Qt.resolvedUrl("install-helper.sh")).replace(/^file:\/\//, "")

  function connectTo(targetCountry, targetProtocol, targetServerType, targetStreaming, targetServer) {
    if (actionProcess.running)
      return
    if (!helperInstalled) {
      lastError = "Install the root helper from FIRST-RUN SETUP before connecting."
      actionStatus = ""
      sendNotification("CyberGhost VPN", lastError, "normal")
      return
    }
    if (!setupDone) {
      // Scripts may hit the IPC endpoint before onboarding completes.
      lastError = ""
      actionStatus = ""
      sendNotification("CyberGhost VPN", "Finish the first-run setup first — open the widget.", "normal")
      return
    }

    if (targetCountry && String(targetCountry).trim().toUpperCase() !== country && !setCountry(targetCountry)) {
      actionStatus = ""
      sendNotification("CyberGhost VPN", lastError, "normal")
      return
    }
    if (targetProtocol && targetProtocol !== protocol)
      setProtocol(targetProtocol)
    if (targetServerType && targetServerType !== serverType)
      setServerType(targetServerType)
    if (targetStreaming !== undefined)
      streamingService = targetStreaming
    if (targetServer !== undefined && targetServer !== "")
      setServerSelection(targetServer)

    if ((protocol !== "wireguard" || serverType !== "traffic") && (!readyCli || !cliConfigured)) {
      lastError = "Advanced modes require CyberGhost CLI account setup. Run cyberghostvpn --setup in a terminal."
      actionStatus = ""
      sendNotification("CyberGhost VPN", lastError, "normal")
      return
    }

    if (serverType === "streaming" && !streamingService) {
      lastError = readyCli ? "Choose a streaming service before connecting." : "Install and set up the cyberghostvpn CLI for Streaming mode."
      actionStatus = ""
      sendNotification("CyberGhost VPN", lastError, "normal")
      return
    }

    lastError = ""
    applyHint = ""
    var serverLabel = serverSelection === "fastest" ? "automatic server" : serverSelection
    actionStatus = "Connecting to " + countryName + " (" + country + ", " + serverLabel + ")…"
    connecting = true
    disconnecting = false
    _desired = 1
    actionTimeoutTimer.restart()

    var execCmd = ["/usr/bin/pkexec", root.helperPath]
    var connectArgs = ["connect", "--country", country, "--protocol", protocol, "--server-type", serverType, "--json"]
    if (protocol === "wireguard" && serverType === "traffic" && serverSelection !== "fastest") {
      connectArgs = connectArgs.concat(["--server", serverSelection])
    }
    if (serverType === "streaming")
      connectArgs = connectArgs.concat(["--streaming-service", streamingService])
    root.actionOutput = ""
    root.actionError = ""
    actionProcess.command = execCmd.concat(connectArgs)
    actionProcess.running = true
  }

  function disconnect() {
    if (actionProcess.running)
      return
    if (!helperInstalled) {
      lastError = "Install the root helper before disconnecting this plugin's tunnel."
      actionStatus = ""
      sendNotification("CyberGhost VPN", lastError, "normal")
      return
    }

    lastError = ""
    applyHint = ""
    actionStatus = "Disconnecting CyberGhost VPN…"
    disconnecting = true
    connecting = false
    _desired = 0
    actionTimeoutTimer.restart()

    var execCmd = ["/usr/bin/pkexec", root.helperPath]
    root.actionOutput = ""
    root.actionError = ""
    actionProcess.command = execCmd.concat(["disconnect", "--json"])
    actionProcess.running = true
  }

  function toggle() {
    if (busy)
      return
    if (active) {
      disconnect()
    } else {
      connectTo(country, protocol, serverType, streamingService)
    }
  }

  Process {
    id: streamingServicesProcess
    stdout: SplitParser {
      onRead: function (line) {
        root.streamingServicesOutput = ServiceUtils.appendBounded(root.streamingServicesOutput, line, 16384)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.streamingServicesErrorOutput = ServiceUtils.appendBounded(root.streamingServicesErrorOutput, line, 4096)
      }
    }
    onExited: function (exitCode) {
      if (root.serverType !== "streaming" || root.streamingProcessCountry !== root.country) {
        root.streamingServicesOutput = ""
        root.streamingServicesErrorOutput = ""
        if (root.serverType === "streaming")
          root.refreshStreamingServices()
        return
      }
      var parsed = []
      try {
        var raw = JSON.parse(String(root.streamingServicesOutput || "[]").substring(0, 16384))
        if (Array.isArray(raw))
          parsed = raw
      } catch (e) {
        // Keep an empty list when the optional CLI emits malformed output.
      }
      root.streamingOptions = parsed
      if (!parsed.some(function (item) {
        return item && item.value === root.streamingService
      }))
        root.streamingService = parsed.length > 0 ? String(parsed[0].value || "") : ""
      if (exitCode !== 0 || parsed.length === 0) {
        var cliError = String(root.streamingServicesErrorOutput || "").trim()
        root.streamingError = cliError !== "" ? ServiceUtils.cleanProcessError(cliError, "Could not load streaming services.") : (root.readyCli ? "No streaming services are available for this country." : "Install and set up the cyberghostvpn CLI to load streaming services.")
      }
      root.streamingServicesOutput = ""
      root.streamingServicesErrorOutput = ""
    }
  }

  function recheck() {
    setup.recheck()
  }

  function refreshStreamingServices() {
    if (serverType !== "streaming" || streamingServicesProcess.running)
      return
    streamingOptions = []
    streamingError = ""
    streamingServicesOutput = ""
    streamingServicesErrorOutput = ""
    if (!readyCli || !cliConfigured) {
      streamingError = "Complete CyberGhost CLI setup, then recheck."
      return
    }
    streamingProcessCountry = country
    streamingServicesProcess.command = ["/usr/bin/python3", root.runnerPath, "streaming-services", "--country", country]
    streamingServicesProcess.running = true
  }

  function installDeps() {
    setup.installDeps()
  }
  function openHelperInstaller(withPolkit) {
    setup.openHelperInstaller(withPolkit)
  }
  function registerAccount(username, password) {
    setup.registerAccount(username, password)
  }

  Process {
    id: statusProcess
    command: ["/usr/bin/python3", root.runnerPath, "status", "--json"]
    stdout: SplitParser {
      onRead: function (line) {
        root.statusOutput = ServiceUtils.appendBounded(root.statusOutput, line, 4096)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.statusError = ServiceUtils.appendBounded(root.statusError, line, 4096)
      }
    }
    onExited: function (exitCode) {
      var out = String(root.statusOutput || "").substring(0, 4096).trim()
      if (exitCode === 0) {
        root.parseStatus(out)
      } else {
        var err = String(root.statusError || "").substring(0, 512).trim()
        if (err !== "")
          root.lastError = err.substring(0, 120)
      }
      root.statusOutput = ""
      root.statusError = ""
    }
  }

  Process {
    id: ipInfoProcess
    command: ["/usr/bin/curl", "--ipv4", "--silent", "--show-error", "--fail-with-body", "--connect-timeout", "2", "--max-time", "4", "--max-filesize", "32768", "--proto", "=https", "https://ipwho.is/?type=ipv4"]
    stdout: SplitParser {
      onRead: function (line) {
        root.ipOutput = ServiceUtils.appendBounded(root.ipOutput, line, 32768)
      }
    }
    onExited: function (exitCode) {
      root.fetchingIp = false
      var out = String(root.ipOutput || "").substring(0, 32768).trim()
      if (exitCode === 0 && out !== "" && root.ipRequestGeneration === root.networkGeneration) {
        root.parseIpInfo(out)
      }
      root.ipOutput = ""
      if (root.ipRefreshPending) {
        root.ipRefreshPending = false
        root.refreshIpInfo(true)
      }
    }
  }

  Process {
    id: notifyProcess
  }

  function sendNotification(title, message, urgency) {
    try {
      var safeTitle = String(title || "CyberGhost VPN").substring(0, 64)
      var safeMsg = String(message || "").substring(0, 160)
      notifyProcess.command = ["/usr/bin/notify-send", "-a", "CyberGhost VPN", "-u", urgency || "normal", safeTitle, safeMsg]
      notifyProcess.running = true
    } catch (e) {
      console.warn("CyberGhost: notification could not be queued")
    }
  }

  Process {
    id: actionProcess
    stdout: SplitParser {
      onRead: function (line) {
        root.actionOutput = ServiceUtils.appendBounded(root.actionOutput, line, 8192)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.actionError = ServiceUtils.appendBounded(root.actionError, line, 8192)
      }
    }
    onExited: function (exitCode) {
      actionTimeoutTimer.stop()
      var wasDisconnecting = root.disconnecting
      root.connecting = false
      root.disconnecting = false
      root._desired = -1

      var out = String(root.actionOutput || "").substring(0, 8192).trim()
      var err = String(root.actionError || "").substring(0, 8192).trim()
      var result = ServiceUtils.parseActionResult(out)
      var expectedAction = wasDisconnecting ? "disconnect" : "connect"

      if (result !== null) {
        if (result.action !== expectedAction) {
          root.lastError = "Helper returned an unexpected result."
          root.actionStatus = ""
          root.sendNotification("Connection Failed", root.lastError, "critical")
        } else if (result.ok && result.action === "disconnect") {
          root.connected = false
          root.actionStatus = ""
          root.lastError = ""
          root.sendNotification("CyberGhost VPN Disconnected", "VPN tunnel disconnected. Public IP exposed.", "normal")
          root.refreshIpInfo(true)
        } else if (result.ok) {
          root.connected = true
          root.actionStatus = ""
          root.lastError = ""
          root.applyHint = ""
          root.sendNotification("CyberGhost VPN Connected", "Protected & Encrypted • " + root.countryName + " " + root.countryFlag, "normal")
          // Clear any previously-fetched public IP so the bar tooltip and
          // details card never display the post-disconnect ISP IP after
          // reconnecting within the 20s GeoIP throttle window. The forced
          // refresh below repopulates it with the live tunnel egress IP.
          root.publicIp = ""
          root.publicCity = ""
          root.publicCountry = ""
          root.publicOrg = ""
          root.refreshIpInfo(true)
        } else {
          root.lastError = ServiceUtils.cleanProcessError(String(result.error || ""), "Operation failed")
          root.actionStatus = ""
          if (/not authorized|dismissed/i.test(root.lastError))
            root.lastError = "Authentication cancelled"
          else
            root.sendNotification("Connection Failed", root.lastError, "critical")
        }
      } else {
        // Compatibility fallback for a helper older than the structured JSON
        // protocol. The setup card reports the stale helper so it can be
        // replaced, but an in-flight old process still gets a useful result.
        var isEstablished = /VPN connection established|Wireguard connection found|connection established/i.test(out)
        if (exitCode === 0 && isEstablished) {
          root.connected = true
          root.actionStatus = ""
          root.lastError = ""
          root.applyHint = ""
          root.sendNotification("CyberGhost VPN Connected", "Protected & Encrypted • " + root.countryName + " " + root.countryFlag, "normal")
          // See the JSON-result success path above: clear the public IP so
          // the panel cannot display the post-disconnect ISP IP during the
          // 20s GeoIP throttle window after a reconnect.
          root.publicIp = ""
          root.publicCity = ""
          root.publicCountry = ""
          root.publicOrg = ""
          root.refreshIpInfo(true)
        } else if (exitCode === 0 && wasDisconnecting) {
          root.connected = false
          root.actionStatus = ""
          root.lastError = ""
          root.sendNotification("CyberGhost VPN Disconnected", "VPN tunnel disconnected. Public IP exposed.", "normal")
          root.refreshIpInfo(true)
        } else if (exitCode === 0) {
          root.actionStatus = ""
          root.lastError = ""
        } else {
          root.lastError = ServiceUtils.cleanProcessError(err || out, "Command failed (code " + exitCode + ")")
          if (/not authorized|dismissed/i.test(root.lastError))
            root.lastError = "Authentication cancelled"
          else
            root.sendNotification("Connection Failed", root.lastError, "critical")
          root.actionStatus = ""
        }
      }

      delayedRefreshTimer.restart()
      root.actionOutput = ""
      root.actionError = ""
    }
  }

  // ---- Output Parsers ----
  function parseStatus(output) {
    rawStatusText = output.substring(0, 2048).trim()
    var isConnected = false

    // Preferred: structured JSON from the runner's `status --json`.
    try {
      var data = JSON.parse(rawStatusText)
      isConnected = data && typeof data.connected === "boolean" ? data.connected : false
      lastBackend = data && typeof data.backend === "string" ? data.backend.substring(0, 32) : ""
      if (isConnected) {
        endpoint = String(data.endpoint || "").substring(0, 64).trim()
        transferText = String(data.transfer || "").substring(0, 64).trim()
        handshakeAgeSec = (typeof data.handshake_sec === "number" && data.handshake_sec >= 0) ? Math.min(data.handshake_sec, 8640000) : -1
      } else {
        endpoint = ""
        transferText = ""
        handshakeAgeSec = -1
      }
    } catch (e) {
      // Fallback: human-readable output (older runner or error text).
      var lower = rawStatusText.toLowerCase()
      isConnected = lower.indexOf("vpn connection found") !== -1 || lower.indexOf("wireguard connection found") !== -1 || lower.indexOf("connection established") !== -1 || lower.indexOf("interface: cyberghost") !== -1
      if (!isConnected) {
        endpoint = ""
        transferText = ""
        handshakeAgeSec = -1
        lastBackend = ""
      } else {
        lastBackend = lower.indexOf("wireguard") !== -1 || lower.indexOf("interface: cyberghost") !== -1 ? "wireguard" : "cyberghostvpn"
      }
    }

    var wasConnected = connected
    connected = isConnected

    if (isConnected && !wasConnected) {
      staleNotified = false
    }

    // Handshake watchdog: warn once when the tunnel looks dead.
    if (isConnected && handshakeAgeSec >= 0) {
      if (handshakeAgeSec > 180) {
        if (!staleNotified) {
          staleNotified = true
          sendNotification("CyberGhost VPN tunnel may be down", "No handshake for " + Math.round(handshakeAgeSec / 60) + " min. Reconnect recommended.", "critical")
        }
      } else {
        staleNotified = false
      }
    }

    if (isConnected) {
      lastError = ""
      actionStatus = ""
    }
  }

  function parseIpInfo(jsonStr) {
    if (!jsonStr || jsonStr.trim() === "")
      return
    try {
      var data = JSON.parse(jsonStr.substring(0, 4096))
      if (data && data.success !== false && data.ip) {
        var candidateIp = String(data.ip || "").substring(0, 45).trim()
        if (!/^[0-9A-Fa-f:.]+$/.test(candidateIp))
          return
        var candidateCountry = String(data.country_code || data.country || "").substring(0, 2).trim().toUpperCase()
        publicIp = candidateIp
        publicCity = String(data.city || "").substring(0, 64).trim()
        publicCountry = /^[A-Z]{2}$/.test(candidateCountry) ? candidateCountry : ""
        var connection = data.connection || {}
        publicOrg = String(data.org || connection.org || connection.isp || "").substring(0, 128).trim()

        // GeoIP describes the egress address, not the selected CyberGhost
        // server. Exit IPs are often registered in a neighbouring country;
        // never overwrite the user's next-connect target with that result.
      }
    } catch (e) {
      // ignore
    }
  }

  // ---- Timers ----
  Timer {
    id: actionTimeoutTimer
    // The backend's bounded actions finish within 120 seconds. Leave a small
    // margin for pkexec/terminal authorization without declaring a still-live
    // process failed.
    interval: 155000
    repeat: false
    onTriggered: {
      if (root.connecting || root.disconnecting) {
        root.lastError = ""
        root.actionStatus = "Still waiting for the VPN helper…"
        root.refresh()
      }
    }
  }

  Timer {
    id: delayedRefreshTimer
    interval: 800
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // Shell settings may arrive after Component.onCompleted. Restore without
  // calling user-action setters: loading preferences must not write defaults
  // over the saved file or reset an exact-server selection.
  function restoreSettings() {
    var saved = ServiceUtils.preferences(settings)
    var selected = Countries.countryByCode(saved.country)
    if (!selected || !Countries.isSupportedCountry(saved.country))
      selected = Countries.countryByCode("PT")
    country = selected.code
    countryName = selected.name
    countryFlag = selected.flag
    protocol = saved.protocol
    serverType = saved.serverType
    serverSelection = saved.serverSelection
    hideDetails = saved.hideDetails
  }
  onSettingsChanged: restoreSettings()
  Component.onCompleted: {
    restoreSettings()
    setup.recheck()
  }
}
