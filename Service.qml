import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Countries.js" as Countries

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
  property real connectedSince: 0

  property string actionStatus: ""
  property string lastError: ""
  property string applyHint: ""
  property string rawStatusText: ""

  // ---- In-panel setup wizard state ----
  property bool regBusy: false
  property string setupMsg: ""
  property string depsError: ""
  property string polkitError: ""
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
  property string streamingError: ""
  property string streamingProcessCountry: ""
  readonly property bool depsBusy: depsProcess.running
  readonly property bool polkitBusy: helperInstallerProcess.running
  readonly property bool streamingBusy: streamingServicesProcess.running

  property real lastIpFetchAt: 0

  readonly property int refreshIntervalSec: Math.max(5, Math.min(60, parseInt(setting("refreshIntervalSec", 8), 10) || 8))
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
  readonly property bool busy: statusProcess.running || actionProcess.running || depsProcess.running || helperInstallerProcess.running || streamingServicesProcess.running || serverProcess.running || regBusy || connecting || disconnecting

  // ---- Onboarding readiness (from runner `check --json`) ----
  property bool readyWg: false
  property bool readyRequests: false
  property bool readyCli: false
  property bool readyCreds: false
  property bool readyPolkit: false
  property bool helperInstalled: false
  // The fixed root helper is mandatory: the UI must never execute mutable
  // plugin code through pkexec. The Polkit rule remains optional.
  readonly property bool setupDone: readyWg && readyRequests && readyCreds && helperInstalled

  // ---- Helper Methods ----
  function setting(key, fallback) {
    if (settings && settings[key] !== undefined) return settings[key]
    return fallback
  }

  function persistSetting(key, value) {
    if (!settings) return
    try { settings[key] = value } catch (e) {}
  }

  function setCountry(code) {
    if (!code) return
    var c = Countries.countryByCode(code)
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
    if (value !== "fastest" && !/^[a-z0-9]+(?:-[a-z0-9]+)*-s\d+-i\d+$/.test(value)) value = "fastest"
    serverSelection = value
    persistSetting("serverSelection", value)
  }

  function defaultServerOptions() {
    return [{
      value: "fastest",
      label: readyCli ? "⚡ Fastest in " + countryName : "⚡ Automatic server",
      description: readyCli
        ? "Choose the lowest-load server in " + countryName
        : "Use the automatic fallback for " + countryName
    }]
  }

  function refreshServers() {
    serverOptions = defaultServerOptions()
    serverError = ""
    if (protocol !== "wireguard" || serverType !== "traffic") return
    if (!readyCli) {
      if (serverSelection !== "fastest") setServerSelection("fastest")
      serverError = "Install cyberghostvpn to choose an exact server. Fastest mode remains available."
      return
    }
    // The server inventory is a short-lived request. Do not cancel and
    // immediately restart it when the setup check finishes; that race can
    // deliver the cancelled process's empty output as a false error.
    if (serverProcess.running) return
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
      statusProcess.command = ["/usr/bin/python3", root.runnerPath, "status", "--json"]
      statusProcess.running = true
    }
    // Only hit the GeoIP API while connected (and throttled); the panel
    // forces a fresh lookup when it opens so the exposed IP stays current.
    if (connected) refreshIpInfo(false)
  }

  function refreshIpInfo(force) {
    if (ipInfoProcess.running) return
    if (!force && Date.now() - lastIpFetchAt < 20000) return
    lastIpFetchAt = Date.now()
    fetchingIp = true
    ipOutput = ""
    ipInfoProcess.command = ["/usr/bin/curl", "--silent", "--show-error", "--fail-with-body", "--connect-timeout", "2", "--max-time", "4", "--max-filesize", "32768", "--proto", "=https", "https://ipwho.is/"]
    ipInfoProcess.running = true
  }

  readonly property string runnerPath: String(Qt.resolvedUrl("cyberghost_runner.py")).replace(/^file:\/\//, "")
  readonly property string rulePath: String(Qt.resolvedUrl("50-cyberghost.rules")).replace(/^file:\/\//, "")
  readonly property string helperPath: "/usr/local/bin/cyberghost-runner"
  readonly property string polkitRulePath: "/etc/polkit-1/rules.d/50-cyberghost.rules"
  readonly property string installerPath: String(Qt.resolvedUrl("install-helper.sh")).replace(/^file:\/\//, "")

  function connectTo(targetCountry, targetProtocol, targetServerType, targetStreaming, targetServer) {
    if (actionProcess.running) return
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

    if (targetCountry) setCountry(targetCountry)
    if (targetProtocol) setProtocol(targetProtocol)
    if (targetServerType) setServerType(targetServerType)
    if (targetStreaming !== undefined) streamingService = targetStreaming
    if (targetServer !== undefined && targetServer !== "") setServerSelection(targetServer)

    if (serverType === "streaming" && !streamingService) {
      lastError = readyCli
        ? "Choose a streaming service before connecting."
        : "Install and set up the cyberghostvpn CLI for Streaming mode."
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

    var execCmd = ["pkexec", root.helperPath]
    var connectArgs = [
      "connect",
      "--country",
      country,
      "--protocol",
      protocol,
      "--server-type",
      serverType
    ]
    if (protocol === "wireguard" && serverType === "traffic" && serverSelection !== "fastest") {
      connectArgs = connectArgs.concat(["--server", serverSelection])
    }
    if (serverType === "streaming") connectArgs = connectArgs.concat(["--streaming-service", streamingService])
    root.actionOutput = ""
    root.actionError = ""
    actionProcess.command = execCmd.concat(connectArgs)
    actionProcess.running = true
  }

  function disconnect() {
    if (actionProcess.running) return
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

    var execCmd = ["pkexec", root.helperPath]
    root.actionOutput = ""
    root.actionError = ""
    actionProcess.command = execCmd.concat(["disconnect"])
    actionProcess.running = true
  }

  function toggle() {
    if (busy) return
    if (active) {
      disconnect()
    } else {
      connectTo(country, protocol, serverType, streamingService)
    }
  }

  // ---- Setup wizard processes ----
  Process {
    id: depsProcess
    command: ["pkexec", "/usr/bin/pacman", "-S", "--needed", "--noconfirm", "wireguard-tools", "python-requests"]
    stdout: SplitParser { onRead: function(line) { root.depsError = root.appendBounded(root.depsError, line, 4096) } }
    stderr: SplitParser { onRead: function(line) { root.depsError = root.appendBounded(root.depsError, line, 4096) } }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.setupMsg = "Packages installed."
        root.sendNotification("CyberGhost VPN", "Dependencies installed.", "normal")
      } else {
        root.setupMsg = root.cleanProcessError(root.depsError, "Could not install dependencies. Check pacman and try again.")
      }
      root.depsError = ""
      root.recheck()
    }
  }

  Process {
    id: helperInstallerProcess
    environment: ({})
    onExited: function(exitCode) {
      var message = exitCode === 0
        ? "Installer opened in a terminal. Complete it, then recheck setup."
        : "Could not open the terminal installer. Run install-helper.sh from the plugin directory."
      root.polkitStatus = message
      root.setupMsg = message
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
    stdout: SplitParser { onRead: function(line) { root.registerOutput = root.appendBounded(root.registerOutput, line, 4096) } }
    stderr: SplitParser { onRead: function(line) { root.registerError = root.appendBounded(root.registerError, line, 4096) } }
    onExited: function(exitCode) {
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
        var cleanErr = (err || out).replace(/^Error:\s*/m, "").trim().substring(0, 120)
        root.setupMsg = cleanErr !== "" ? cleanErr : "Could not link account."
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
    stdout: SplitParser { onRead: function(line) { root.checkOutput = root.appendBounded(root.checkOutput, line, 4096) } }
    onExited: function(exitCode) {
      var d = {}
      try {
        var text = String(root.checkOutput || "{}").substring(0, 4096)
        d = JSON.parse(text)
      } catch (e) {}
      root.readyWg = !!d.wg_tools
      root.readyRequests = !!d.requests
      root.readyCli = !!d.cli
      root.readyCreds = !!d.credentials
      root.readyPolkit = !!d.helper_installed && !!d.polkit_rule_installed
      root.helperInstalled = !!d.helper_installed
      root.refreshServers()
      if (!root.readyPolkit && root.polkitStatus === "Passwordless connect enabled.") root.polkitStatus = ""
      root.checkOutput = ""
      root.refresh()
    }
  }

  Process {
    id: streamingServicesProcess
    stdout: SplitParser { onRead: function(line) { root.streamingServicesOutput = root.appendBounded(root.streamingServicesOutput, line, 16384) } }
    stderr: SplitParser { onRead: function(line) { root.streamingServicesOutput = root.appendBounded(root.streamingServicesOutput, line, 16384) } }
    onExited: function(exitCode) {
      if (root.serverType !== "streaming" || root.streamingProcessCountry !== root.country) {
        root.streamingServicesOutput = ""
        if (root.serverType === "streaming") root.refreshStreamingServices()
        return
      }
      var parsed = []
      try {
        var raw = JSON.parse(String(root.streamingServicesOutput || "[]").substring(0, 16384))
        if (Array.isArray(raw)) parsed = raw
      } catch (e) {}
      root.streamingOptions = parsed
      if (parsed.length > 0) root.streamingService = String(parsed[0].value || "")
      if (exitCode !== 0 || parsed.length === 0) {
        root.streamingError = root.readyCli
          ? "No streaming services are available for this country."
          : "Install and set up the cyberghostvpn CLI to load streaming services."
      }
      root.streamingServicesOutput = ""
    }
  }

  Process {
    id: serverProcess
    stdout: SplitParser { onRead: function(line) { root.serversOutput = root.appendBounded(root.serversOutput, line, 32768) } }
    stderr: SplitParser { onRead: function(line) { root.serversError = root.appendBounded(root.serversError, line, 4096) } }
    onExited: function(exitCode) {
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
        if (Array.isArray(raw)) parsed = raw
      } catch (e) {}

      var options = root.defaultServerOptions()
      for (var i = 0; i < parsed.length && i < 64; i++) {
        var item = parsed[i] || {}
        var value = String(item.server || item.instance || "").toLowerCase()
        if (!/^[a-z0-9]+(?:-[a-z0-9]+)*-s\d+-i\d+$/.test(value)) continue
        var city = String(item.city || root.countryName).substring(0, 48)
        var load = parseInt(item.load, 10)
        var loadText = isNaN(load) ? "" : " · " + load + "% load"
        options.push({
          value: value,
          label: city + " · " + value + loadText,
          description: "Manual server selection"
        })
      }
      root.serverOptions = options
      if (root.serverSelection !== "fastest") {
        var found = false
        for (var j = 1; j < options.length; j++) {
          if (options[j].value === root.serverSelection) { found = true; break }
        }
        if (!found) root.setServerSelection("fastest")
      }
      if (options.length === 1 && (exitCode !== 0 || err !== "")) {
        root.serverError = "Could not load the live server list. Fastest fallback is still available."
      }
    }
  }

  function recheck() {
    if (!checkProcess.running) checkProcess.running = true
  }

  function refreshStreamingServices() {
    if (serverType !== "streaming") return
    streamingOptions = []
    streamingService = ""
    streamingError = ""
    streamingServicesOutput = ""
    if (streamingServicesProcess.running) return
    streamingProcessCountry = country
    streamingServicesProcess.command = ["/usr/bin/python3", root.runnerPath, "streaming-services", "--country", country]
    streamingServicesProcess.running = true
  }

  function installDeps() {
    if (depsProcess.running) return
    depsError = ""
    setupMsg = "Installing system packages (authorize in the dialog)…"
    depsProcess.running = true
  }

  function openHelperInstaller() {
    if (helperInstallerProcess.running) return
    polkitError = ""
    polkitStatus = ""
    setupMsg = "A terminal installer was opened. Complete it there, then use Recheck setup."
    helperInstallerProcess.environment = ({"CYBERGHOST_PLUGIN_DIR": root.installerPath.replace(/\/install-helper\.sh$/, "")})
    helperInstallerProcess.command = [
      "omarchy-launch-terminal",
      "bash",
      "-lc",
      "cd -- \"$CYBERGHOST_PLUGIN_DIR\" && bash ./install-helper.sh; rc=$?; printf '\\nInstaller exited with code %s. Press Enter to close.\\n' \"$rc\"; read -r"
    ]
    helperInstallerProcess.running = true
  }

  function registerAccount(username, password) {
    if (regBusy || !username || !password) return
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
    registerProcess.pendingCredentials = JSON.stringify({"username": username, "password": password})
    registerProcess.running = true
  }

  Process {
    id: statusProcess
    command: ["/usr/bin/python3", root.runnerPath, "status", "--json"]
    stdout: SplitParser { onRead: function(line) { root.statusOutput = root.appendBounded(root.statusOutput, line, 4096) } }
    stderr: SplitParser { onRead: function(line) { root.statusError = root.appendBounded(root.statusError, line, 4096) } }
    onExited: function(exitCode) {
      var out = String(root.statusOutput || "").substring(0, 4096).trim()
      if (exitCode === 0) {
        root.parseStatus(out)
      } else {
        var err = String(root.statusError || "").substring(0, 512).trim()
        if (err !== "") root.lastError = err.substring(0, 120)
      }
      root.statusOutput = ""
      root.statusError = ""
    }
  }

  Process {
    id: ipInfoProcess
    command: ["/usr/bin/curl", "--silent", "--show-error", "--fail-with-body", "--connect-timeout", "2", "--max-time", "4", "--max-filesize", "32768", "--proto", "=https", "https://ipwho.is/"]
    stdout: SplitParser { onRead: function(line) { root.ipOutput = root.appendBounded(root.ipOutput, line, 32768) } }
    onExited: function(exitCode) {
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
      notifyProcess.command = ["notify-send", "-a", "CyberGhost VPN", "-u", urgency || "normal", safeTitle, safeMsg]
      notifyProcess.running = true
    } catch (e) {}
  }

  Process {
    id: actionProcess
    stdout: SplitParser { onRead: function(line) { root.actionOutput = root.appendBounded(root.actionOutput, line, 8192) } }
    stderr: SplitParser { onRead: function(line) { root.actionError = root.appendBounded(root.actionError, line, 8192) } }
    onExited: function(exitCode) {
      actionTimeoutTimer.stop()
      var wasDisconnecting = root.disconnecting
      root.connecting = false
      root.disconnecting = false
      root._desired = -1

      var out = String(root.actionOutput || "").substring(0, 8192).trim()
      var err = String(root.actionError || "").substring(0, 8192).trim()

      var isEstablished = /VPN connection established|Wireguard connection found|connection established/i.test(out)
      var hasError = /error|failed|exception|cannot connect|invalid/i.test(out) || /error|failed|exception/i.test(err)

      if (exitCode === 0) {
        if (isEstablished) {
          root.connected = true
          root.actionStatus = ""
          root.lastError = ""
          root.sendNotification("CyberGhost VPN Connected", "Protected & Encrypted • " + root.countryName + " " + root.countryFlag, "normal")
        } else if (out.indexOf("No VPN connection") !== -1 || out.indexOf("Terminated") !== -1 || out.indexOf("terminated") !== -1 || wasDisconnecting) {
          root.connected = false
          root.actionStatus = ""
          root.lastError = ""
          root.sendNotification("CyberGhost VPN Disconnected", "VPN tunnel disconnected. Public IP exposed.", "normal")
          // Re-check the public IP right away so the panel shows the real exposed address.
          root.refreshIpInfo(true)
        } else if (hasError) {
          root.lastError = extractCleanError(out || err)
          root.actionStatus = ""
          root.sendNotification("Connection Failed", root.lastError, "critical")
        } else {
          root.actionStatus = ""
          root.lastError = ""
        }
      } else {
        if (err.indexOf("Not authorized") !== -1 || err.indexOf("dismissed") !== -1 || out.indexOf("Not authorized") !== -1) {
          root.lastError = "Authentication cancelled"
        } else {
          root.lastError = extractCleanError(err || out || ("Command failed (code " + exitCode + ")"))
          root.sendNotification("Connection Failed", root.lastError, "critical")
        }
        root.actionStatus = ""
      }

      delayedRefreshTimer.restart()
      root.actionOutput = ""
      root.actionError = ""
    }
  }

  function appendBounded(existing, line, maxChars) {
    var current = String(existing || "")
    if (current.indexOf("[output truncated]") !== -1) return current
    var addition = String(line || "")
    var combined = current === "" ? addition : current + "\n" + addition
    if (combined.length <= maxChars) return combined
    return combined.substring(0, maxChars) + "\n[output truncated]"
  }

  function cleanProcessError(text, fallback) {
    var clean = String(text || "").replace(/^Error:\s*/m, "").trim()
    return clean !== "" ? clean.substring(0, 160) : fallback
  }

  function extractCleanError(text) {
    if (!text) return "Operation failed"
    var safeText = String(text).substring(0, 1024)
    var lines = safeText.split("\n")
    var sawTraceback = safeText.indexOf("Traceback (most recent call last):") !== -1 || safeText.indexOf("File \\") !== -1
    for (var i = lines.length - 1; i >= 0; i--) {
      var l = lines[i].trim()
      if (l === "Traceback (most recent call last):" || l.indexOf("During handling of the above exception") === 0 || l.indexOf("The above exception was the direct cause") === 0) {
        sawTraceback = true
        continue
      }
      if (l.indexOf("File \"") === 0 || l.indexOf("[Previous line repeated") === 0 || l === "^") {
        sawTraceback = true
        continue
      }
      if (l.indexOf("Error:") === 0) l = l.substring(6).trim()
      if (sawTraceback && !/error|exception|failed|cannot|certificate|hostname|network|timeout/i.test(l)) continue
      if (l.length > 0 && (/error|exception|failed|cannot|certificate|hostname|network|timeout/i.test(l) || i === lines.length - 1)) {
        return l.substring(0, 120)
      }
    }
    if (sawTraceback) return "Unable to connect to CyberGhost. Check your network and account setup."
    return safeText.substring(0, 120)
  }

  // ---- Output Parsers ----
  function parseStatus(output) {
    rawStatusText = output.substring(0, 2048).trim()
    var isConnected = false

    // Preferred: structured JSON from the runner's `status --json`.
    try {
      var data = JSON.parse(rawStatusText)
      isConnected = !!data.connected
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
      isConnected = lower.indexOf("vpn connection found") !== -1 ||
                    lower.indexOf("wireguard connection found") !== -1 ||
                    lower.indexOf("connection established") !== -1 ||
                    lower.indexOf("interface: cyberghost") !== -1
      if (!isConnected) {
        endpoint = ""
        transferText = ""
        handshakeAgeSec = -1
      }
    }

    var wasConnected = connected
    connected = isConnected

    if (isConnected && !wasConnected) {
      connectedSince = Date.now()
      staleNotified = false
    }

    // Handshake watchdog: warn once when the tunnel looks dead.
    if (isConnected && handshakeAgeSec >= 0) {
      if (handshakeAgeSec > 180) {
        if (!staleNotified) {
          staleNotified = true
          sendNotification(
            "CyberGhost VPN tunnel may be down",
            "No handshake for " + Math.round(handshakeAgeSec / 60) + " min. Reconnect recommended.",
            "critical"
          )
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
    if (!jsonStr || jsonStr.trim() === "") return
    try {
      var data = JSON.parse(jsonStr.substring(0, 4096))
      if (data && data.ip) {
        var candidateIp = String(data.ip || "").substring(0, 45).trim()
        if (!/^[0-9A-Fa-f:.]+$/.test(candidateIp)) return
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
    // Generous timeout: the cyberghostvpn CLI path (OpenVPN/torrent/streaming)
    // and a pkexec password prompt can legitimately take a while.
    interval: 150000
    repeat: false
    onTriggered: {
      if (root.connecting || root.disconnecting) {
        root.connecting = false
        root.disconnecting = false
        root._desired = -1
        root.lastError = "Connection timed out. Check your network or try WireGuard."
        root.actionStatus = ""
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
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    var defCountry = setting("defaultCountry", "PT")
    setCountry(defCountry)
    var defProto = setting("protocol", "wireguard")
    setProtocol(defProto)
    var defType = setting("serverType", "traffic")
    setServerType(defType)
    setServerSelection(setting("serverSelection", "fastest"))
    setHideDetails(!!setting("hideDetails", false))

    checkProcess.running = true
  }
}
