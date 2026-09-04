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
  property var serverOptions: []
  property bool loadingServers: false
  property string serverError: ""
  property string serversOutput: ""
  property string serversError: ""
  property string serversProcessCountry: ""
  property string protocol: "wireguard"
  property string serverType: "traffic"
  property string streamingService: ""
  property var streamingOptions: []

  property string publicIp: ""
  property string publicCity: ""
  property string publicCountry: ""
  property string publicOrg: ""
  property bool fetchingIp: false

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

  // ---- Setup card dismissal ----
  // User-level opt-out for the optional Polkit rule card. When true, the
  // "OPTIONAL SETUP" card is hidden and the user can still connect/disconnect
  // normally (pkexec just keeps prompting for the password).
  property bool polkitRuleDismissed: !!setting("polkitRuleDismissed", false)
  function dismissPolkitPrompt() {
    polkitRuleDismissed = true
    persistSetting("polkitRuleDismissed", true)
  }
  function restorePolkitPrompt() {
    polkitRuleDismissed = false
    persistSetting("polkitRuleDismissed", false)
  }

  // ---- In-panel setup wizard state ----
  property bool regBusy: false
  property string setupMsg: ""
  property string depsError: ""
  property string polkitStatus: ""
  property string registerOutput: ""
  property string registerError: ""
  property string checkOutput: ""
  property string statusOutput: ""
  property string statusError: ""
  property string ipOutput: ""
  property string actionOutput: ""
  property string actionError: ""
  property string streamingServicesOutput: ""
  property string streamingServicesErrorOutput: ""
  property string streamingError: ""
  property string streamingProcessCountry: ""
  readonly property bool depsBusy: depsProcess.running
  readonly property bool polkitBusy: helperInstallerProcess.running
  readonly property bool streamingBusy: streamingServicesProcess.running

  property real lastIpFetchAt: 0

  readonly property int refreshIntervalSec: Math.max(5, Math.min(60, parseInt(setting("refreshIntervalSec", 8), 10) || 8))
  readonly property bool busy: statusProcess.running || actionProcess.running || depsProcess.running || helperInstallerProcess.running || streamingServicesProcess.running || serverProcess.running || regBusy || connecting || disconnecting

  // ---- Onboarding readiness (from runner `check --json`) ----
  property bool readyWg: false
  property bool readyRequests: false
  property bool readyCli: false
  property bool readyCreds: false
  property bool readyPolkit: false
  property bool helperInstalled: false
  property string helperVersion: ""
  property string pluginVersion: ""
  // The fixed root helper is mandatory: the UI must never execute mutable
  // plugin code through pkexec. The Polkit rule remains optional.
  readonly property bool setupDone: readyWg && readyRequests && readyCreds && helperInstalled

  // ---- Setup card state machine ----
  // The card has four states. The UI title, color, and visible rows all
  // derive from this single property; the card hides itself when state is
  // "ready".
  //
  //   first-run        — anything required is missing
  //   update-available — setup used to be done, but a new plugin version
  //                      shipped a fresh helper (or the bundled runner was
  //                      edited). The hero card still appears; only the
  //                      helper is stale.
  //   polkit-optional  — everything required is fine, only the optional
  //                      Polkit rule is missing and the user has not
  //                      dismissed the prompt.
  //   ready            — everything is fine. Card hidden.
  readonly property bool helperNeedsUpdate: helperInstalled && helperVersion !== "" && pluginVersion !== "" && helperVersion !== pluginVersion
  readonly property string setupCardState: {
    if (!readyWg || !readyRequests || !readyCreds || !helperInstalled)
      return "first-run"
    if (helperNeedsUpdate)
      return "update-available"
    if (!readyPolkit && !polkitRuleDismissed)
      return "polkit-optional"
    return "ready"
  }

  // ---- Helper Methods ----
  function setting(key, fallback) {
    if (settings && settings[key] !== undefined)
      return settings[key]
    return fallback
  }

  function persistSetting(key, value) {
    if (!settings)
      return
    try {
      settings[key] = value
    } catch (e) {
      // A failed write usually means the settings object is read-only or
      // full. lastError is the status banner, which stays visible after
      // setup is done; setupMsg only renders inside the first-run card.
      console.warn("CyberGhost: could not persist setting " + key + " — " + e)
      lastError = "Could not save setting '" + key + "'. Changes will not survive a restart."
    }
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

  function defaultServerOptions() {
    return [
      {
        value: "fastest",
        label: readyCli ? "⚡ Fastest in " + countryName : "⚡ Automatic server",
        description: readyCli ? "Choose the lowest-load server in " + countryName : "Use the automatic fallback for " + countryName
      }
    ]
  }

  function refreshServers() {
    serverOptions = defaultServerOptions()
    serverError = ""
    if (protocol !== "wireguard" || serverType !== "traffic")
      return
    if (!readyCli) {
      if (serverSelection !== "fastest")
        setServerSelection("fastest")
      serverError = "Install cyberghostvpn to choose an exact server. Fastest mode remains available."
      return
    }
    // The server inventory is a short-lived request. Do not cancel and
    // immediately restart it when the setup check finishes; that race can
    // deliver the cancelled process's empty output as a false error.
    if (serverProcess.running)
      return
    serversProcessCountry = country
    serversOutput = ""
    serversError = ""
    loadingServers = true
    serverProcess.command = ["/usr/bin/python3", root.runnerPath, "servers", "--country", country, "--server-type", serverType]
    serverProcess.running = true
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
    if (ipInfoProcess.running)
      return
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
    // Ask ipwho.is for the IPv4 address explicitly. Without the query param
    // the API returns whichever address it picks first, which is IPv6 on
    // most hosts today — and the user almost always wants to see the IPv4
    // (the one a typical service uses for geolocation, blocking, etc.).
    // If the host is IPv6-only, the request fails and the panel renders
    // "Unavailable" — the existing fallback path.
    ipInfoProcess.command = ["/usr/bin/curl", "--silent", "--show-error", "--fail-with-body", "--connect-timeout", "2", "--max-time", "4", "--max-filesize", "32768", "--proto", "=https", "https://ipwho.is/?type=ipv4"]
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

    if (targetCountry && !setCountry(targetCountry)) {
      actionStatus = ""
      sendNotification("CyberGhost VPN", lastError, "normal")
      return
    }
    if (targetProtocol)
      setProtocol(targetProtocol)
    if (targetServerType)
      setServerType(targetServerType)
    if (targetStreaming !== undefined)
      streamingService = targetStreaming
    if (targetServer !== undefined && targetServer !== "")
      setServerSelection(targetServer)

    if (serverType === "streaming" && !streamingService) {
      lastError = readyCli ? "Choose a streaming service before connecting." : "Install and set up the cyberghostvpn CLI for Streaming mode."
      actionStatus = ""
      sendNotification("CyberGhost VPN", lastError, "normal")
      return
    }

    lastError = ""
    applyHint = ""
    var serverLabel = serverSelection === "fastest" ? "fastest server" : serverSelection
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

  // ---- Setup wizard processes ----
  Process {
    id: depsProcess
    command: ["/usr/bin/pkexec", "/usr/bin/pacman", "-S", "--needed", "--noconfirm", "wireguard-tools", "python-requests"]
    stdout: SplitParser {
      onRead: function (line) {
        root.depsError = ServiceUtils.appendBounded(root.depsError, line, 4096)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.depsError = ServiceUtils.appendBounded(root.depsError, line, 4096)
      }
    }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.setupMsg = "Packages installed."
        root.sendNotification("CyberGhost VPN", "Dependencies installed.", "normal")
      } else {
        root.setupMsg = ServiceUtils.cleanProcessError(root.depsError, "Could not install dependencies. Check pacman and try again.")
      }
      root.depsError = ""
      root.recheck()
    }
  }

  Process {
    id: helperInstallerProcess
    environment: ({})
    onExited: function (exitCode) {
      // The installer is a long-running interactive script in a terminal; we
      // get the terminal's exit code (0 if the user closed it normally, even
      // if the install failed mid-way). Treat any 0 exit as "recheck now" so
      // the user does not have to remember to come back and click the
      // Recheck button. Non-zero exits still surface a manual message.
      if (exitCode === 0) {
        root.polkitStatus = "Installer closed. Rechecking setup…"
        root.setupMsg = "Rechecking setup after the helper installer closed…"
        // give the runner a beat to flush new state on disk before probing it
        recheck()
      } else {
        var message = "Installer exited with code " + exitCode + ". Run install-helper.sh from the plugin directory to retry."
        root.polkitStatus = message
        root.setupMsg = message
      }
      helperInstallerProcess.environment = ({})
    }
  }

  Process {
    id: registerProcess
    command: ["/usr/bin/python3", root.runnerPath, "register"]
    environment: ({})
    property string pendingCredentials: ""
    stdinEnabled: true
    onStarted: {
      write(pendingCredentials + "\n")
      pendingCredentials = ""
    }
    stdout: SplitParser {
      onRead: function (line) {
        root.registerOutput = ServiceUtils.appendBounded(root.registerOutput, line, 4096)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.registerError = ServiceUtils.appendBounded(root.registerError, line, 4096)
      }
    }
    onExited: function (exitCode) {
      root.regBusy = false
      var out = String(root.registerOutput || "")
      var err = String(root.registerError || "")
      registerProcess.pendingCredentials = ""
      registerProcess.environment = ({})
      if (exitCode === 0) {
        root.setupMsg = ""
        root.lastError = ""
        root.sendNotification("CyberGhost VPN", "Account linked — you're ready to connect.", "normal")
      } else {
        var cleanErr = ServiceUtils.cleanProcessError(err || out, "Could not link account.")
        root.setupMsg = cleanErr
      }
      root.registerOutput = ""
      root.registerError = ""
      root.recheck()
    }
  }

  // ---- Processes ----
  Process {
    id: checkProcess
    command: ["/usr/bin/python3", root.runnerPath, "check", "--json"]
    stdout: SplitParser {
      onRead: function (line) {
        root.checkOutput = ServiceUtils.appendBounded(root.checkOutput, line, 4096)
      }
    }
    onExited: function (exitCode) {
      var d = {}
      try {
        var text = String(root.checkOutput || "{}").substring(0, 4096)
        d = JSON.parse(text)
      } catch (e) {
        // An unavailable or older runner leaves the readiness flags false.
      }
      root.readyWg = !!d.wg_tools
      root.readyRequests = !!d.requests
      root.readyCli = !!d.cli
      root.readyCreds = !!d.credentials
      root.readyPolkit = !!d.helper_installed && !!d.polkit_rule_installed
      root.helperInstalled = !!d.helper_installed
      root.helperVersion = String(d.helper_version || "")
      root.pluginVersion = String(d.plugin_version || "")
      root.refreshServers()
      if (!root.readyPolkit && root.polkitStatus === "Passwordless connect enabled.")
        root.polkitStatus = ""
      root.checkOutput = ""
      root.refresh()
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
      if (parsed.length > 0)
        root.streamingService = String(parsed[0].value || "")
      if (exitCode !== 0 || parsed.length === 0) {
        var cliError = String(root.streamingServicesErrorOutput || "").trim()
        root.streamingError = cliError !== "" ? ServiceUtils.cleanProcessError(cliError, "Could not load streaming services.") : (root.readyCli ? "No streaming services are available for this country." : "Install and set up the cyberghostvpn CLI to load streaming services.")
      }
      root.streamingServicesOutput = ""
      root.streamingServicesErrorOutput = ""
    }
  }

  Process {
    id: serverProcess
    stdout: SplitParser {
      onRead: function (line) {
        root.serversOutput = ServiceUtils.appendBounded(root.serversOutput, line, 32768)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.serversError = ServiceUtils.appendBounded(root.serversError, line, 4096)
      }
    }
    onExited: function (exitCode) {
      root.loadingServers = false
      var requestedCountry = root.serversProcessCountry
      var out = String(root.serversOutput || "").substring(0, 32768).trim()
      var err = String(root.serversError || "").substring(0, 512).trim()
      root.serversOutput = ""
      root.serversError = ""
      if (requestedCountry !== root.country) {
        root.refreshServers()
        return
      }

      var parsed = []
      try {
        var raw = JSON.parse(out || "[]")
        if (Array.isArray(raw))
          parsed = raw
      } catch (e) {
        // Keep the automatic fallback when the optional CLI emits malformed output.
      }

      var options = root.defaultServerOptions()
      for (var i = 0; i < parsed.length && i < 64; i++) {
        var item = parsed[i] || {}
        var value = String(item.server || item.instance || "").toLowerCase()
        if (!ServiceUtils.isValidServerSelector(value))
          continue
        var city = String(item.city || root.countryName).substring(0, 48)
        var displayCity = city.replace(/</g, "[").replace(/>/g, "]")
        var load = parseInt(item.load, 10)
        var loadText = isNaN(load) ? "" : " · " + load + "% load"
        options.push({
          value: value,
          label: displayCity + " · " + value + loadText,
          description: "Manual server selection"
        })
      }
      root.serverOptions = options
      if (root.serverSelection !== "fastest") {
        var found = false
        for (var j = 1; j < options.length; j++) {
          if (options[j].value === root.serverSelection) {
            found = true
            break
          }
        }
        if (!found)
          root.setServerSelection("fastest")
      }
      if (options.length === 1 && (exitCode !== 0 || err !== "")) {
        root.serverError = err !== "" ? ServiceUtils.cleanProcessError(err, "Could not load the live server list.") : "Could not load the live server list. Fastest fallback is still available."
      }
    }
  }

  function recheck() {
    if (!checkProcess.running)
      checkProcess.running = true
  }

  function refreshStreamingServices() {
    if (serverType !== "streaming")
      return
    streamingOptions = []
    streamingService = ""
    streamingError = ""
    streamingServicesOutput = ""
    streamingServicesErrorOutput = ""
    if (streamingServicesProcess.running)
      return
    streamingProcessCountry = country
    streamingServicesProcess.command = ["/usr/bin/python3", root.runnerPath, "streaming-services", "--country", country]
    streamingServicesProcess.running = true
  }

  function installDeps() {
    if (depsProcess.running)
      return
    depsError = ""
    setupMsg = "Installing system packages (authorize in the dialog)…"
    depsProcess.running = true
  }

  function openHelperInstaller() {
    if (helperInstallerProcess.running)
      return
    polkitStatus = ""
    setupMsg = "A terminal installer was opened. Complete it there; setup will be rechecked when the terminal closes."
    helperInstallerProcess.environment = ({
        "CYBERGHOST_PLUGIN_DIR": root.installerPath.replace(/\/install-helper\.sh$/, "")
      })
    helperInstallerProcess.command = ["omarchy-launch-terminal", "bash", "-lc", "cd -- \"$CYBERGHOST_PLUGIN_DIR\" && bash ./install-helper.sh; rc=$?; printf '\\nInstaller exited with code %s. Press Enter to close.\\n' \"$rc\"; read -r"]
    helperInstallerProcess.running = true
  }

  function registerAccount(username, password) {
    if (regBusy || !username || !password)
      return
    if (username.length > 256 || password.length > 256) {
      setupMsg = "Username and password must be 256 characters or fewer."
      return
    }
    regBusy = true
    registerOutput = ""
    registerError = ""
    setupMsg = "Linking your CyberGhost account…"
    // Credentials travel once over stdin, never argv, environment or disk.
    registerProcess.environment = ({
        "CG_DEVICE_NAME": Quickshell.env("HOSTNAME") || "omarchy"
      })
    registerProcess.pendingCredentials = JSON.stringify({
      "username": username,
      "password": password
    })
    registerProcess.running = true
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
    command: ["/usr/bin/curl", "--silent", "--show-error", "--fail-with-body", "--connect-timeout", "2", "--max-time", "4", "--max-filesize", "32768", "--proto", "=https", "https://ipwho.is/?type=ipv4"]
    stdout: SplitParser {
      onRead: function (line) {
        root.ipOutput = ServiceUtils.appendBounded(root.ipOutput, line, 32768)
      }
    }
    onExited: function (exitCode) {
      root.fetchingIp = false
      var out = String(root.ipOutput || "").substring(0, 32768).trim()
      if (exitCode === 0 && out !== "") {
        root.parseIpInfo(out)
      }
      root.ipOutput = ""
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
      if (data && data.ip) {
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

  Component.onCompleted: {
    var defCountry = setting("defaultCountry", "PT")
    var savedServerSelection = setting("serverSelection", "fastest")
    if (!setCountry(defCountry)) {
      setCountry("PT")
      lastError = ""
    }
    var defProto = setting("protocol", "wireguard")
    setProtocol(defProto)
    var defType = setting("serverType", "traffic")
    setServerType(defType)
    // setCountry/setServerType intentionally reset the server when a user
    // changes target/mode; restore the persisted value only after startup.
    setServerSelection(savedServerSelection)
    setHideDetails(!!setting("hideDetails", false))

    checkProcess.running = true
  }
}
