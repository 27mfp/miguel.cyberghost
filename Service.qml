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
  property string protocol: "wireguard"
  property string serverType: "traffic"
  property string streamingService: ""

  property string publicIp: ""
  property string publicCity: ""
  property string publicCountry: ""
  property string publicOrg: ""
  property bool fetchingIp: false

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
  readonly property bool depsBusy: depsProcess.running
  readonly property bool polkitBusy: polkitProcess.running

  property real lastIpFetchAt: 0

  readonly property int refreshIntervalSec: Math.max(5, Math.min(60, parseInt(setting("refreshIntervalSec", 8), 10) || 8))
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
  readonly property bool busy: statusProcess.running || actionProcess.running || connecting || disconnecting

  // ---- Onboarding readiness (from runner `check --json`) ----
  property bool readyWg: false
  property bool readyRequests: false
  property bool readyCli: false
  property bool readyCreds: false
  readonly property bool setupDone: readyWg && readyRequests && readyCreds

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
  }

  function setProtocol(p) {
    protocol = (p === "openvpn" || p === "openvpn_tcp") ? p : "wireguard"
    persistSetting("protocol", protocol)
  }

  function setServerType(t) {
    serverType = (t === "torrent" || t === "streaming") ? t : "traffic"
    persistSetting("serverType", serverType)
  }

  function refresh() {
    if (!statusProcess.running) {
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
    ipInfoProcess.command = ["curl", "-s", "--max-time", "4", "https://ipinfo.io/json"]
    ipInfoProcess.running = true
  }

  readonly property string runnerPath: String(Qt.resolvedUrl("cyberghost_runner.py")).replace(/^file:\/\//, "")
  readonly property string userConfigPath: (Quickshell.env("HOME") || "/root") + "/.cyberghost/config.ini"

  function connectTo(targetCountry, targetProtocol, targetServerType, targetStreaming) {
    if (actionProcess.running) return

    if (targetCountry) setCountry(targetCountry)
    if (targetProtocol) setProtocol(targetProtocol)
    if (targetServerType) setServerType(targetServerType)
    if (targetStreaming !== undefined) streamingService = targetStreaming

    lastError = ""
    applyHint = ""
    actionStatus = "Connecting to " + countryName + " (" + country + ")…"
    connecting = true
    disconnecting = false
    _desired = 1
    actionTimeoutTimer.restart()

    actionProcess.command = [
      "pkexec",
      "/usr/bin/python3",
      root.runnerPath,
      "connect",
      "--country",
      country,
      "--protocol",
      protocol,
      "--server-type",
      serverType,
      "--config",
      root.userConfigPath
    ]
    actionProcess.running = true
  }

  function disconnect() {
    if (actionProcess.running) return

    lastError = ""
    applyHint = ""
    actionStatus = "Disconnecting CyberGhost VPN…"
    disconnecting = true
    connecting = false
    _desired = 0
    actionTimeoutTimer.restart()

    actionProcess.command = [
      "pkexec",
      "/usr/bin/python3",
      root.runnerPath,
      "disconnect"
    ]
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
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.setupMsg = "Packages installed."
        root.sendNotification("CyberGhost VPN", "Dependencies installed.", "normal")
      } else {
        root.setupMsg = ""
      }
      root.recheck()
    }
  }

  Process {
    id: polkitProcess
    command: ["pkexec", "/usr/bin/cp", root.runnerPath.replace("/cyberghost_runner.py", "/50-cyberghost.rules"), "/etc/polkit-1/rules.d/"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: polkitErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.setupMsg = "Passwordless connect enabled."
        root.sendNotification("CyberGhost VPN", "Polkit rule installed — connects no longer ask for a password.", "normal")
      } else {
        var err = String(polkitErr.text || "").trim()
        root.setupMsg = err.indexOf("Not authorized") !== -1 || err.indexOf("dismissed") !== -1 ? "Polkit install cancelled." : ""
      }
    }
  }

  Process {
    id: registerProcess
    command: ["/usr/bin/python3", root.runnerPath, "register", "--config", root.userConfigPath]
    environment: ({})
    stdout: StdioCollector { id: regOut; waitForEnd: true }
    stderr: StdioCollector { id: regErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.regBusy = false
      if (exitCode === 0) {
        root.setupMsg = ""
        root.lastError = ""
        root.sendNotification("CyberGhost VPN", "Account linked — you're ready to connect.", "normal")
      } else {
        var err = String(regErr.text || regOut.text || "").replace(/^Error:\s*/m, "").trim()
        root.setupMsg = err !== "" ? err : "Could not link account."
      }
      root.recheck()
    }
  }

  // ---- Processes ----
  Process {
    id: checkProcess
    command: ["/usr/bin/python3", root.runnerPath, "check", "--json"]
    stdout: StdioCollector {
      id: checkOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var d = {}
      try { d = JSON.parse(String(checkOut.text || "{}")) } catch (e) {}
      root.readyWg = !!d.wg_tools
      root.readyRequests = !!d.requests
      root.readyCli = !!d.cli
      root.readyCreds = !!d.credentials
      root.refresh()
    }
  }

  function recheck() {
    if (!checkProcess.running) checkProcess.running = true
  }

  function installDeps() {
    if (depsProcess.running) return
    setupMsg = "Installing system packages (authorize in the dialog)…"
    depsProcess.running = true
  }

  function installPolkitRule() {
    if (polkitProcess.running) return
    setupMsg = "Installing Polkit rule (authorize in the dialog)…"
    polkitProcess.running = true
  }

  function registerAccount(username, password) {
    if (regBusy || !username || !password) return
    regBusy = true
    setupMsg = "Linking your CyberGhost account…"
    // Credentials travel via environment variables — never via argv,
    // so they are invisible to other processes' `ps` listings.
    registerProcess.environment = ({
      "CG_USERNAME": username,
      "CG_PASSWORD": password,
      "CG_DEVICE_NAME": Quickshell.env("HOSTNAME") || "omarchy"
    })
    registerProcess.running = true
  }

  Process {
    id: statusProcess
    command: ["/usr/bin/python3", root.runnerPath, "status"]
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: statusErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var out = String(statusOut.text || "").trim()
      if (exitCode === 0) {
        root.parseStatus(out)
      } else {
        var err = String(statusErr.text || "").trim()
        if (err !== "") root.lastError = err
      }
    }
  }

  Process {
    id: ipInfoProcess
    command: ["curl", "-s", "--max-time", "4", "https://ipinfo.io/json"]
    stdout: StdioCollector {
      id: ipOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.fetchingIp = false
      var out = String(ipOut.text || "").trim()
      if (exitCode === 0 && out !== "") {
        root.parseIpInfo(out)
      }
    }
  }

  Process {
    id: notifyProcess
  }

  function sendNotification(title, message, urgency) {
    try {
      notifyProcess.command = ["notify-send", "-a", "CyberGhost VPN", "-u", urgency || "normal", title, message]
      notifyProcess.running = true
    } catch (e) {}
  }

  Process {
    id: actionProcess
    stdout: StdioCollector {
      id: actionOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      actionTimeoutTimer.stop()
      var wasDisconnecting = root.disconnecting
      root.connecting = false
      root.disconnecting = false
      root._desired = -1

      var out = String(actionOut.text || "").trim()
      var err = String(actionErr.text || "").trim()

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
    }
  }

  function extractCleanError(text) {
    if (!text) return "Operation failed"
    var lines = text.split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var l = lines[i].trim()
      if (l.length > 0 && (/error|exception|failed|cannot/i.test(l) || i === lines.length - 1)) {
        return l
      }
    }
    return text.substring(0, 120)
  }

  // ---- Output Parsers ----
  function parseStatus(output) {
    rawStatusText = output.trim()
    var isConnected = false

    // Preferred: structured JSON from the runner's `status --json`.
    try {
      var data = JSON.parse(rawStatusText)
      isConnected = !!data.connected
      if (isConnected) {
        endpoint = String(data.endpoint || "")
        transferText = String(data.transfer || "")
        handshakeAgeSec = (typeof data.handshake_sec === "number" && data.handshake_sec >= 0) ? data.handshake_sec : -1
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
      var data = JSON.parse(jsonStr)
      if (data && data.ip) {
        publicIp = String(data.ip || "")
        publicCity = String(data.city || "")
        publicCountry = String(data.country || "")
        publicOrg = String(data.org || "")

        if (connected && publicCountry && country !== publicCountry) {
          setCountry(publicCountry)
        }
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

    checkProcess.running = true
  }
}
