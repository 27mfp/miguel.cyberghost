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
  // Handshake age needs CAP_NET_ADMIN, so liveness uses the world-readable
  // receive counter: WireGuard rekeys at least every two minutes.
  property real rxBytes: -1
  property real rxChangedAt: 0
  property int rxIdleSec: 0
  // Transfer totals and per-second rates between polls, like Omarchy's
  // network panel. -1 means no sample yet ("--" in the UI).
  property real txBytes: -1
  property real rxRate: -1
  property real txRate: -1
  property real counterSampleAt: 0
  property real sampleRx: -1
  property real sampleTx: -1
  // Country of the live tunnel, as opposed to `country` (the next connection).
  property string activeCountry: ""
  // Server name from the connect result (e.g. "barcelona-s402-i05"); after a
  // shell restart only NetworkManager's endpoint address is known.
  property string activeServer: ""
  readonly property string activeCountryName: activeCountry !== "" ? Countries.countryName(activeCountry) : ""
  readonly property bool switchAvailable: connected && !legacyTunnel && activeCountry !== "" && activeCountry !== country
  readonly property bool tunnelStale: connected && !legacyTunnel && rxIdleSec >= 180
  property bool staleNotified: false
  property string lastBackend: ""
  property int statusGeneration: 0
  property bool statusRefreshPending: false
  property bool statusUnknown: false
  // A tunnel created by the pre-1.7 root helper. It can only be removed by
  // that installed helper, so it keeps its own disconnect path.
  property bool legacyTunnel: false

  property string actionStatus: ""
  property string lastError: ""
  property string statusProbeError: ""
  property string applyHint: ""
  property string actionKind: ""
  property bool resolvingAutomaticServer: false
  onReadyCliChanged: {
    if (resolvingAutomaticServer && !readyCli) {
      resolvingAutomaticServer = false
      startNativeConnect("")
    }
  }
  onCliConfiguredChanged: {
    if (resolvingAutomaticServer && !cliConfigured) {
      resolvingAutomaticServer = false
      startNativeConnect("")
    }
  }
  property int actionGeneration: 0
  property bool actionTerminating: false
  property string rawStatusText: ""

  // ---- In-panel setup wizard state ----
  property alias regBusy: setup.regBusy
  property alias setupMsg: setup.setupMsg
  property alias legacyStatus: setup.legacyStatus
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
  readonly property bool legacyCleanupBusy: setup.legacyCleanupBusy
  readonly property bool streamingBusy: streamingServicesProcess.running

  property real lastIpFetchAt: 0

  readonly property int refreshIntervalSec: Math.max(5, Math.min(60, parseInt(setting("refreshIntervalSec", 8), 10) || 8))
  readonly property bool busy: actionProcess.running || actionTerminating || setup.busy || resolvingAutomaticServer || connecting || disconnecting

  // ---- Onboarding readiness (from runner `check --json`) ----
  property alias readyNm: setup.readyNm
  property alias nmPermission: setup.nmPermission
  property alias readyRequests: setup.readyRequests
  property alias readyCli: setup.readyCli
  property alias cliConfigured: setup.cliConfigured
  property alias readyCreds: setup.readyCreds
  property alias accountName: setup.accountName
  property alias accountSource: setup.accountSource
  property alias serverList: setup.serverList
  readonly property bool syncingServers: setup.syncingServers
  readonly property string syncProgress: setup.syncProgress
  property alias legacyHelper: setup.legacyHelper
  property alias legacyPolkitRule: setup.legacyPolkitRule
  property alias pluginVersion: setup.pluginVersion
  // NetworkManager owns the tunnel and Polkit authorizes it, exactly like
  // Omarchy's own network panel. "auth" means the shell's Polkit agent asks.
  readonly property bool readyNetwork: readyNm && nmPermission !== "no"
  readonly property bool setupDone: readyNetwork && readyRequests && readyCreds
  readonly property bool legacyCleanupAvailable: (legacyHelper || legacyPolkitRule) && !legacyTunnel

  readonly property string setupCardState: ServiceUtils.setupState(readyNetwork, readyRequests, readyCreds)

  SetupController {
    id: setup
    runnerPath: root.runnerPath
    legacyCleanupPath: root.legacyCleanupPath
    syncAllowed: !actionProcess.running && !root.actionTerminating
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
    protocol = "wireguard"
    persistSetting("protocol", protocol)
    refreshServers()
  }

  function setServerType(t) {
    serverType = "traffic"
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
    // Inventory lookup is unprivileged. The selected, strictly validated host
    // is then passed to the connect action, avoiding stale per-country maps.
    cliAvailable: root.readyCli && root.cliConfigured
    runnerPath: root.runnerPath
    onLoaded: function (options) {
      var found = options.some(function (item) {
        return item.value === root.serverSelection
      })
      if (!found)
        root.setServerSelection("fastest")
      if (root.resolvingAutomaticServer) {
        root.resolvingAutomaticServer = false
        var liveServer = options.length > 1 ? String(options[1].value || "") : ""
        root.startNativeConnect(liveServer)
      }
    }
  }

  function refresh() {
    if (statusProcess.running) {
      statusRefreshPending = true
    } else {
      statusRefreshPending = false
      statusOutput = ""
      statusError = ""
      statusProcess.requestGeneration = statusGeneration
      statusProcess.running = true
      statusTimeoutTimer.restart()
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
  // Pre-1.7 root helper; used only to disconnect a tunnel it created.
  readonly property string legacyHelperPath: "/usr/local/bin/cyberghost-runner"
  readonly property string legacyCleanupPath: String(Qt.resolvedUrl("scripts/remove-legacy-helper.sh")).replace(/^file:\/\//, "")

  function connectTo(targetCountry, targetProtocol, targetServerType, targetStreaming, targetServer) {
    if ((targetProtocol && targetProtocol !== "wireguard") || (targetServerType && targetServerType !== "traffic") || targetStreaming || (targetServer && targetServer !== "fastest")) {
      lastError = "This release supports native WireGuard with automatic server selection only."
      actionStatus = ""
      return
    }
    if (actionProcess.running || actionTerminating || resolvingAutomaticServer)
      return
    if (legacyTunnel) {
      lastError = root.legacyTunnelMessage
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

    if (protocol !== "wireguard" || serverType !== "traffic" || serverSelection !== "fastest") {
      lastError = "This release supports native WireGuard with automatic server selection only."
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
    statusProbeError = ""
    applyHint = ""

    // Resolve the lowest-load live server before connecting, avoiding brittle
    // hard-coded rack/city names for every country.
    if (readyCli && cliConfigured) {
      resolvingAutomaticServer = true
      actionStatus = "Finding a live server in " + countryName + "…"
      inventory.refresh()
      return
    }
    startNativeConnect("")
  }

  function startNativeConnect(liveServer) {
    if (actionProcess.running || actionTerminating)
      return
    // State can change while the unprivileged inventory lookup is running.
    if (legacyTunnel || !setupDone) {
      lastError = legacyTunnel ? root.legacyTunnelMessage : "Complete first-run setup before connecting."
      actionStatus = ""
      return
    }
    var resolvedServer = String(liveServer || "").trim().toLowerCase()
    if (resolvedServer !== "" && !ServiceUtils.isValidServerSelector(resolvedServer)) {
      lastError = "CyberGhost returned an invalid server name."
      actionStatus = ""
      return
    }

    statusGeneration++
    statusRefreshPending = true
    var serverLabel = resolvedServer !== "" ? resolvedServer : "automatic server"
    actionStatus = "Connecting to " + countryName + " (" + country + ", " + serverLabel + ")…"
    connecting = true
    disconnecting = false
    _desired = 1
    actionTimeoutTimer.restart()

    pendingCountry = country
    setup.stopServerSync()
    var connectArgs = ["/usr/bin/python3", root.runnerPath, "connect", "--country", country, "--protocol", protocol, "--server-type", serverType, "--json"]
    if (resolvedServer !== "")
      connectArgs = connectArgs.concat(["--server", resolvedServer])
    root.actionOutput = ""
    root.actionError = ""
    actionKind = "connect"
    actionGeneration++
    actionProcess.requestGeneration = actionGeneration
    actionProcess.requestKind = actionKind
    actionProcess.command = connectArgs
    actionProcess.running = true
  }

  function cancelAction() {
    if (!actionProcess.running || actionKind === "")
      return
    root.statusUnknown = true
    root.statusGeneration++
    root.statusRefreshPending = true
    root.lastError = "VPN operation cancelled; the outcome is unknown. Reconciliation is in progress."
    root.actionStatus = ""
    root.connecting = false
    root.disconnecting = false
    root._desired = -1
    // Invalidate the completion before terminating the runner process;
    // a late child result must not announce a success for the cancelled epoch.
    root.actionGeneration++
    root.actionKind = ""
    root.actionTerminating = true
    actionProcess.timedOut = false
    actionProcess.running = false
    delayedRefreshTimer.restart()
  }

  function disconnect() {
    // A late inventory result must not turn this disconnect into a connect.
    if (resolvingAutomaticServer) {
      resolvingAutomaticServer = false
      actionStatus = ""
    }
    if (actionProcess.running || actionTerminating) {
      if (actionProcess.running && connecting)
        cancelAction()
      return
    }
    if (legacyTunnel && !legacyHelper) {
      lastError = "A tunnel from the previous root helper is active, but that helper is missing. Run: sudo wg-quick down cyberghost"
      actionStatus = ""
      sendNotification("CyberGhost VPN", lastError, "normal")
      return
    }

    lastError = ""
    statusProbeError = ""
    statusGeneration++
    statusRefreshPending = true
    applyHint = ""
    actionStatus = "Disconnecting CyberGhost VPN…"
    disconnecting = true
    connecting = false
    _desired = 0
    actionKind = "disconnect"
    actionGeneration++
    actionProcess.requestGeneration = actionGeneration
    actionProcess.requestKind = actionKind
    actionTimeoutTimer.restart()

    root.actionOutput = ""
    root.actionError = ""
    // Only the old root helper can remove its own tunnel; everything else is
    // an unprivileged NetworkManager deactivation.
    actionProcess.command = legacyTunnel ? ["/usr/bin/pkexec", root.legacyHelperPath, "disconnect", "--json"] : ["/usr/bin/python3", root.runnerPath, "disconnect", "--json"]
    actionProcess.running = true
  }

  property string pendingCountry: ""

  function logout() {
    if (actionProcess.running || actionTerminating || resolvingAutomaticServer)
      return
    if (legacyTunnel) {
      lastError = root.legacyTunnelMessage
      return
    }
    lastError = ""
    statusProbeError = ""
    statusGeneration++
    statusRefreshPending = true
    setup.stopServerSync()
    actionStatus = connected ? "Disconnecting and logging out…" : "Logging out…"
    disconnecting = connected
    _desired = connected ? 0 : _desired
    actionKind = "logout"
    actionGeneration++
    actionProcess.requestGeneration = actionGeneration
    actionProcess.requestKind = actionKind
    actionTimeoutTimer.restart()
    root.actionOutput = ""
    root.actionError = ""
    actionProcess.command = ["/usr/bin/python3", root.runnerPath, "logout", "--json"]
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
  function openLegacyCleanup() {
    setup.openLegacyCleanup()
  }
  function registerAccount(username, password) {
    setup.registerAccount(username, password)
  }

  Process {
    id: statusProcess
    objectName: "statusProcess"
    property int requestGeneration: -1
    property bool timedOut: false
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
      statusTimeoutTimer.stop()
      var requestGeneration = statusProcess.requestGeneration
      var timedOut = statusProcess.timedOut
      statusProcess.timedOut = false
      var current = requestGeneration === root.statusGeneration
      var out = String(root.statusOutput || "").substring(0, 4096).trim()
      if (current) {
        if (exitCode === 0 && !timedOut) {
          root.parseStatus(out)
        } else {
          root.statusUnknown = true
          var err = String(root.statusError || "").substring(0, 512).trim()
          root.statusProbeError = timedOut ? "VPN status check timed out; current state is unknown." : (err !== "" ? err.substring(0, 120) : "VPN status check failed; current state is unknown.")
        }
      }
      root.statusOutput = ""
      root.statusError = ""
      if (root.statusRefreshPending) {
        root.statusRefreshPending = false
        root.refresh()
      }
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
      notifyProcess.command = ["/usr/bin/notify-send", "-a", "CyberGhost VPN", "-u", urgency || "normal", "--", safeTitle, safeMsg]
      notifyProcess.running = true
    } catch (e) {
      console.warn("CyberGhost: notification could not be queued")
    }
  }

  Process {
    id: actionProcess
    objectName: "actionProcess"
    property int requestGeneration: -1
    property string requestKind: ""
    property bool timedOut: false
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
      var requestGeneration = actionProcess.requestGeneration
      var expectedAction = actionProcess.requestKind
      var timedOut = actionProcess.timedOut
      actionProcess.timedOut = false
      var current = requestGeneration === root.actionGeneration && expectedAction === root.actionKind
      root.actionTerminating = false

      var out = String(root.actionOutput || "").substring(0, 8192).trim()
      var err = String(root.actionError || "").substring(0, 8192).trim()
      var result = ServiceUtils.parseActionResult(out)
      if (!current) {
        // A late completion from an operation that was superseded or timed out
        // cannot be trusted to describe the current tunnel.
        root.actionOutput = ""
        root.actionError = ""
        return
      }

      root.connecting = false
      root.disconnecting = false
      root._desired = -1
      root.actionKind = ""

      if (timedOut) {
        root.statusUnknown = true
        root.actionStatus = ""
        root.lastError = "VPN operation timed out; the outcome is unknown. Reconciliation is in progress."
        root.sendNotification("Connection status unknown", root.lastError, "critical")
      } else if (result !== null && result.action === expectedAction) {
        if (exitCode === 0 && result.ok && result.action === "logout") {
          if (result.disconnected === true)
            root.connected = false
          root.activeCountry = root.connected ? root.activeCountry : ""
          root.statusUnknown = false
          root.actionStatus = ""
          root.lastError = ""
          // The vendor CLI config may still provide an account; say so.
          root.sendNotification("CyberGhost VPN", result.remaining_source === "legacy" ? "Logged out. The CyberGhost CLI account is still available." : "Logged out of CyberGhost.", "normal")
          setup.recheck()
        } else if (exitCode === 0 && result.ok && result.action === "disconnect") {
          root.connected = false
          root.activeCountry = ""
          root.legacyTunnel = false
          root.statusUnknown = false
          root.statusProbeError = ""
          root.actionStatus = ""
          root.lastError = ""
          root.sendNotification("CyberGhost VPN Disconnected", "VPN tunnel disconnected. Public IP exposed.", "normal")
          root.refreshIpInfo(true)
        } else if (exitCode === 0 && result.ok && result.action === "connect") {
          root.connected = true
          root.activeCountry = typeof result.country === "string" && /^[A-Z]{2}$/.test(result.country) ? result.country : root.pendingCountry
          var server = typeof result.server === "string" ? result.server.replace(/\.cg-dialup\.net$/, "").toLowerCase() : ""
          root.activeServer = ServiceUtils.isValidServerSelector(server) && server !== "fastest" ? server : ""
          root.legacyTunnel = false
          root.statusUnknown = false
          root.statusProbeError = ""
          root.actionStatus = ""
          root.lastError = ""
          root.applyHint = ""
          root.sendNotification("CyberGhost VPN Connected", "Traffic now goes through " + root.countryName + ".", "normal")
          // Clear any previously-fetched public IP so the bar tooltip and
          // details card never display the post-disconnect ISP IP after
          // reconnecting within the 20s GeoIP throttle window. The forced
          // refresh below repopulates it with the live tunnel egress IP.
          root.publicIp = ""
          root.publicCity = ""
          root.publicCountry = ""
          root.publicOrg = ""
          root.refreshIpInfo(true)
        } else if (result.code === "legacy_tunnel") {
          root.legacyTunnel = true
          root.lastError = root.legacyTunnelMessage
          root.actionStatus = ""
        } else {
          root.statusUnknown = true
          root.lastError = ServiceUtils.cleanProcessError(String(result.error || ""), "Operation failed")
          root.actionStatus = ""
          if (/not authorized|dismissed/i.test(root.lastError))
            root.lastError = "Authorization cancelled"
          root.sendNotification("Connection Failed", root.lastError, "critical")
        }
      } else {
        root.statusUnknown = true
        root.lastError = ServiceUtils.cleanProcessError(err || out, "Command failed (code " + exitCode + ")")
        if (/not authorized|dismissed/i.test(root.lastError))
          root.lastError = "Authorization cancelled"
        root.sendNotification("Connection Failed", root.lastError, "critical")
        root.actionStatus = ""
      }

      actionProcess.requestKind = ""
      delayedRefreshTimer.restart()
      root.actionOutput = ""
      root.actionError = ""
    }
  }

  // ---- Output Parsers ----
  readonly property string legacyTunnelMessage: "A tunnel from the previous CyberGhost root helper is active. Disconnect it first."

  function parseStatus(output) {
    rawStatusText = output.substring(0, 2048).trim()
    var data = null
    try {
      data = JSON.parse(rawStatusText)
    } catch (e) {
      data = null
    }
    if (!data || typeof data.connected !== "boolean") {
      statusUnknown = true
      statusProbeError = rawStatusText === "" ? "VPN status response was empty; current state is unknown." : "VPN status response was invalid; current state is unknown."
      return
    }
    lastBackend = typeof data.backend === "string" ? data.backend.substring(0, 32) : ""
    legacyTunnel = data.connected && lastBackend === "legacy"
    var isConnected = data.connected
    if (isConnected && !legacyTunnel) {
      endpoint = String(data.endpoint || "").substring(0, 64).trim()
      transferText = String(data.transfer || "").substring(0, 64).trim()
      var rx = typeof data.rx_bytes === "number" && data.rx_bytes >= 0 ? data.rx_bytes : -1
      var tx = typeof data.tx_bytes === "number" && data.tx_bytes >= 0 ? data.tx_bytes : -1
      var now = Date.now()
      var elapsed = (now - counterSampleAt) / 1000
      if (rx < 0 || tx < 0 || rx < sampleRx || tx < sampleTx) {
        // Missing counters or a reset (new interface): restart sampling.
        rxRate = -1
        txRate = -1
        counterSampleAt = rx >= 0 && tx >= 0 ? now : 0
        sampleRx = rx
        sampleTx = tx
      } else if (counterSampleAt === 0 || elapsed >= 1) {
        // Rates need two samples of the same session at least 1s apart.
        if (counterSampleAt > 0) {
          rxRate = (rx - sampleRx) / elapsed
          txRate = (tx - sampleTx) / elapsed
        }
        counterSampleAt = now
        sampleRx = rx
        sampleTx = tx
      }
      txBytes = tx
      if (rx < 0 || rx !== rxBytes || rxChangedAt === 0) {
        rxBytes = rx
        rxChangedAt = now
      }
      rxIdleSec = rx < 0 ? 0 : Math.floor((now - rxChangedAt) / 1000)
    } else {
      endpoint = ""
      transferText = ""
      rxBytes = -1
      rxChangedAt = 0
      rxIdleSec = 0
      txBytes = -1
      rxRate = -1
      txRate = -1
      counterSampleAt = 0
      sampleRx = -1
      sampleTx = -1
      if (!isConnected || legacyTunnel) {
        activeCountry = legacyTunnel ? activeCountry : ""
        activeServer = ""
      }
    }

    var wasConnected = connected
    statusUnknown = false
    statusProbeError = ""
    connected = isConnected

    if (isConnected && !wasConnected)
      staleNotified = false

    // Liveness watchdog: warn once when nothing has been received for a while.
    if (tunnelStale) {
      if (!staleNotified) {
        staleNotified = true
        sendNotification("CyberGhost VPN tunnel may be down", "Nothing received for " + Math.round(rxIdleSec / 60) + " min. Reconnect recommended.", "critical")
      }
    } else {
      staleNotified = false
    }

    if (isConnected)
      actionStatus = ""
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
    // The backend is bounded to 120 seconds. A Polkit dialog can still remain
    // open, so terminate the runner after a small margin and explicitly report
    // an unknown outcome; the next status poll reconciles with NetworkManager.
    interval: 155000
    repeat: false
    onTriggered: {
      if (root.actionKind === "")
        return
      root.statusUnknown = true
      root.statusGeneration++
      root.statusRefreshPending = true
      root.lastError = "VPN operation timed out; the outcome is unknown. Reconciliation is in progress."
      root.actionStatus = ""
      root.connecting = false
      root.disconnecting = false
      root._desired = -1
      if (actionProcess.running) {
        actionProcess.timedOut = true
        root.actionGeneration++
        root.actionKind = ""
        root.actionTerminating = true
        actionProcess.running = false
      } else {
        actionProcess.requestKind = ""
        root.actionKind = ""
      }
      delayedRefreshTimer.restart()
    }
  }

  Timer {
    id: statusTimeoutTimer
    interval: 20000
    repeat: false
    onTriggered: {
      if (statusProcess.running) {
        statusProcess.timedOut = true
        statusProcess.running = false
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
