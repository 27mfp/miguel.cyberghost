import QtQuick
import Quickshell.Io
import "." as Plugin
import "Countries.js" as Countries
import "ServiceUtils.js" as Logic

// Runs inside the existing shell with REAL Omarchy controls, never test stubs.
// Only this synthetic service replaces the network/account boundary.
Plugin.Panel {
  id: preview
  moduleName: "test.cyberghost-visual"
  ipcTarget: moduleName
  cyberghost: sample
  settings: ({
      reduceMotion: true
    })

  function descendants(object, output, seen) {
    if (!object || seen.indexOf(object) >= 0 || seen.length > 5000)
      return
    seen.push(object)
    if (object.objectName)
      output.push(object)
    if (object.contentItem)
      descendants(object.contentItem, output, seen)
    var children = object.data || object.children || []
    for (var i = 0; i < children.length; i++)
      descendants(children[i], output, seen)
  }
  function controls() {
    var found = []
    descendants(preview, found, [])
    return found
  }
  function find(name) {
    var found = controls()
    for (var i = 0; i < found.length; i++)
      if (found[i].objectName === name)
        return found[i]
    return null
  }
  function focusControl(object) {
    if (!object)
      return false
    if (object.activeFocusOnTab) {
      object.forceActiveFocus()
      return true
    }
    var children = object.children || []
    for (var i = 0; i < children.length; i++)
      if (focusControl(children[i]))
        return true
    return false
  }
  function snapshot() {
    var data = {
      opened: preview.opened,
      setupMsg: sample.setupMsg,
      country: sample.country,
      connected: sample.connected,
      hideDetails: sample.hideDetails,
      mode: sample.serverType,
      protocol: sample.protocol,
      controls: {}
    }
    var items = controls()
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (item.width === undefined)
        continue
      var point = typeof item.mapToGlobal === "function" ? item.mapToGlobal(0, 0) : {
        x: 0,
        y: 0
      }
      data.controls[item.objectName] = {
        visible: item.visible,
        width: item.width,
        height: item.height,
        x: point.x,
        y: point.y,
        text: item.text && (item.objectName === "accountPassword" || item.objectName === "accountUsername") ? "<redacted>" : (item.text || ""),
        selected: item.selected === true,
        popupOpen: item.popupOpen === true
      }
    }
    return JSON.stringify(data)
  }

  IpcHandler {
    target: "test.cyberghost-visual"
    function snapshot(): string {
      return preview.snapshot()
    }
    function focus(name: string): bool {
      return preview.focusControl(preview.find(name))
    }
    function scenario(name: string): void {
      if (name === "disconnected") {
        sample.setCountry("PT")
        sample.hideDetails = false
        sample.protocol = "wireguard"
        sample.serverType = "traffic"
        sample.setupMsg = ""
        sample.lastError = ""
      }
      sample.readyCli = name !== "missing-cli"
      sample.cliConfigured = sample.readyCli
      sample.tunnelStale = name === "stale"
      sample.connected = name === "connected" || name === "stale"
      preview.preferredContentWidth = name === "narrow" ? 280 : 380
      sample.setupCardState = name === "setup" ? "first-run" : "ready"
      sample.setupDone = name !== "setup"
      sample.readyCreds = name !== "setup"
    }
  }

  QtObject {
    id: sample
    property bool connected: false
    property bool connecting: false
    property bool disconnecting: false
    readonly property bool active: connected
    property bool busy: false
    property bool setupDone: true
    property string setupCardState: "ready"
    property bool readyWg: true
    property bool readyDns: true
    property bool readyRequests: true
    property bool readyCreds: true
    property bool helperInstalled: true
    property bool readyCli: true
    property bool cliConfigured: true
    property bool readyPolkit: false
    property bool regBusy: false
    property string setupMsg: ""
    property string lastError: ""
    property string actionStatus: ""
    property string applyHint: ""
    property bool tunnelStale: false
    property string lastBackend: "wireguard"
    property int handshakeAgeSec: 240
    property string country: "PT"
    property string countryName: "Portugal"
    property string countryFlag: "🇵🇹"
    property string protocol: "wireguard"
    property string serverType: "traffic"
    property string serverSelection: "fastest"
    property var serverOptions: Logic.serverOptions([
      {
        server: "lisbon-s405-i19",
        city: "Lisbon",
        load: 18
      }
    ], countryName)
    property bool loadingServers: false
    property string serverError: ""
    property bool streamingBusy: false
    property var streamingOptions: [
      {
        value: "Netflix",
        label: "Netflix"
      },
      {
        value: "Prime",
        label: "Prime"
      }
    ]
    property string streamingService: "Netflix"
    property string streamingError: ""
    property bool hideDetails: false
    property string publicIp: "203.0.113.42"
    property bool fetchingIp: false
    property string publicCity: "Lisbon"
    property string publicCountry: "PT"
    property string publicOrg: "Example Network — synthetic organization for wrapping checks"
    property string transferText: "↓ 12 MiB · ↑ 3 MiB"
    property string endpoint: "198.51.100.20:1337"
    function setCountry(code) {
      var c = Countries.countryByCode(code)
      country = c.code
      countryName = c.name
      countryFlag = c.flag
    }
    function setProtocol(value) {
      protocol = value
    }
    function setServerType(value) {
      serverType = value
    }
    function setServerSelection(value) {
      serverSelection = value
    }
    function setStreamingService(value) {
      streamingService = value
    }
    function setHideDetails(value) {
      hideDetails = value
    }
    function toggle() {
      lastBackend = protocol === "wireguard" ? "wireguard" : "cli"
      connected = !connected
    }
    function refreshServers() {
    }
    function refreshIpInfo(force) {
    }
    function recheck() {
    }
    function installDeps() {
      setupMsg = "Preview: package installation is not executed."
    }
    function openHelperInstaller(withPolkit) {
      lastError = "Preview: privileged installation is not executed."
    }
    function registerAccount(user, password) {
      setupMsg = "Preview: account credentials are not sent or stored."
    }
  }
}
