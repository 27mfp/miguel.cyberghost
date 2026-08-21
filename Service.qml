import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Countries.js" as Countries

Item {
  id: root

  property var settings: ({})

  // ---- State Properties ----
  property bool installed: true
  property bool connected: false
  property bool connecting: false
  property bool disconnecting: false
  property int _desired: -1 // Optimistic state: -1 (real), 1 (connecting/on), 0 (disconnecting/off)
  readonly property bool active: _desired === -1 ? (connected || connecting) : (_desired === 1)

  property string country: "PT"
  property string countryName: "Portugal"
  property string countryFlag: "🇵🇹"
  property string protocol: "wireguard"
  property string serverType: "traffic"
  property string streamingService: ""

  // Public IP & Geo details
  property string publicIp: ""
  property string publicCity: ""
  property string publicCountry: ""
  property string publicOrg: ""
  property bool fetchingIp: false

  // Status & Error Messages
  property string lastError: ""
  property string actionStatus: ""
  property string rawStatusText: ""

  readonly property int refreshIntervalSec: Math.max(5, Math.min(60, parseInt(setting("refreshIntervalSec", 8), 10) || 8))
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
  readonly property bool busy: whichProcess.running || statusProcess.running || actionProcess.running || connecting || disconnecting

  // ---- Helper Methods ----
  function setting(name, fallback) {
    var val = settings ? settings[name] : undefined
    return val === undefined || val === null ? fallback : val
  }

  function setCountry(code) {
    var c = Countries.countryByCode(code)
    country = c.code
    countryName = c.name
    countryFlag = c.flag
  }

  function setProtocol(p) {
    protocol = (p === "openvpn" || p === "openvpn_tcp") ? p : "wireguard"
  }

  function setServerType(t) {
    serverType = (t === "torrent" || t === "streaming") ? t : "traffic"
  }

  function refresh() {
    if (!statusProcess.running) {
      statusProcess.command = ["/usr/bin/python3", root.runnerPath, "status"]
      statusProcess.running = true
    }
    refreshIpInfo()
  }

  function refreshIpInfo() {
    if (!ipInfoProcess.running) {
      fetchingIp = true
      ipInfoProcess.command = ["curl", "-s", "--max-time", "4", "https://ipinfo.io/json"]
      ipInfoProcess.running = true
    }
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
    if (active) {
      disconnect()
    } else {
      connectTo(country, protocol, serverType, streamingService)
    }
  }

  // ---- Processes ----
  Process {
    id: whichProcess
    command: ["which", "cyberghostvpn"]
    onExited: function(exitCode) {
      root.installed = (exitCode === 0)
      if (root.installed) {
        root.refresh()
      } else {
        root.lastError = "cyberghostvpn CLI is not installed."
      }
    }
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
      root.connecting = false
      root.disconnecting = false
      root._desired = -1

      var out = String(actionOut.text || "").trim()
      var err = String(actionErr.text || "").trim()
      console.warn("CyberGhost action exitCode: " + exitCode + " | STDOUT: " + out + " | STDERR: " + err)

      var isEstablished = /VPN connection established|Wireguard connection found|Initialization Sequence Completed|connection established/i.test(out)
      var hasError = /error|failed|exception|cannot connect|invalid/i.test(out) || /error|failed|exception/i.test(err)

      if (exitCode === 0) {
        if (isEstablished) {
          root.connected = true
          root.actionStatus = ""
          root.lastError = ""
        } else if (out.indexOf("No VPN connection") !== -1 || out.indexOf("Terminating") !== -1 || root.disconnecting) {
          root.connected = false
          root.actionStatus = ""
          root.lastError = ""
        } else if (hasError) {
          root.lastError = extractCleanError(out || err)
          root.actionStatus = ""
        } else {
          // Normal progress output without error
          root.actionStatus = ""
          root.lastError = ""
        }
      } else {
        if (err.indexOf("Not authorized") !== -1 || err.indexOf("dismissed") !== -1 || out.indexOf("Not authorized") !== -1) {
          root.lastError = "Authentication cancelled"
        } else {
          root.lastError = extractCleanError(err || out || ("Command failed (code " + exitCode + ")"))
        }
        root.actionStatus = ""
      }

      // Check status immediately
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
    var lower = rawStatusText.toLowerCase()

    if (lower.indexOf("vpn connection found") !== -1 ||
        lower.indexOf("wireguard connection found") !== -1 ||
        lower.indexOf("openvpn connection found") !== -1 ||
        lower.indexOf("connection established") !== -1 ||
        lower.indexOf("interface: cyberghost") !== -1) {
      connected = true
      lastError = ""
      actionStatus = ""
    } else {
      connected = false
    }

    var countryMatch = rawStatusText.match(/country[:\s]+([A-Z]{2})/i)
    if (countryMatch && countryMatch[1]) {
      setCountry(countryMatch[1])
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
    interval: 30000 // 30s timeout
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
    interval: 1000
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

    whichProcess.running = true
  }
}
