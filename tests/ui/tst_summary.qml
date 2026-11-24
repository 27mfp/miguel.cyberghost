import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "ConnectionSummaryBehavior"
  visible: true
  when: windowShown
  width: 330
  height: 400

  QtObject {
    id: vpn
    property bool connected: false
    property bool connecting: false
    property bool disconnecting: false
    property bool resolvingAutomaticServer: false
    property bool statusUnknown: false
    property string statusProbeError: ""
    property bool tunnelStale: false
    property bool legacyTunnel: false
    property bool setupDone: true
    property string rawStatusText: "{\"connected\":false}"
    property string activeCountryName: ""
    property string countryName: "Spain"
    property string publicIp: ""
    property bool fetchingIp: false
    property bool hideDetails: false
    property int privacyActions: 0

    function setHideDetails(value) {
      privacyActions++
      hideDetails = !!value
    }
  }

  Component {
    id: factory
    Plugin.ConnectionSummary {
      width: 280
      service: vpn
    }
  }

  function init() {
    vpn.connected = false
    vpn.connecting = false
    vpn.disconnecting = false
    vpn.resolvingAutomaticServer = false
    vpn.statusUnknown = false
    vpn.statusProbeError = ""
    vpn.tunnelStale = false
    vpn.legacyTunnel = false
    vpn.setupDone = true
    vpn.rawStatusText = "{\"connected\":false}"
    vpn.activeCountryName = ""
    vpn.countryName = "Spain"
    vpn.publicIp = ""
    vpn.fetchingIp = false
    vpn.hideDetails = false
    vpn.privacyActions = 0
  }

  function test_statusNeverInferredFromPublicIpOrSelection() {
    vpn.publicIp = "203.0.113.42"
    vpn.activeCountryName = "Portugal"
    var summary = createTemporaryObject(factory, this)
    compare(summary.stateKind, "disconnected")
    compare(summary.activeName, "None")
    compare(summary.selectedName, "Spain")
    compare(summary.ipText, "203.0.113.42")

    vpn.connected = true
    compare(summary.stateKind, "connected")
    compare(summary.activeName, "Portugal")
    compare(summary.selectedName, "Spain")
    vpn.tunnelStale = true
    compare(summary.stateKind, "stale")
    verify(summary.stateDetail.indexOf("traffic") >= 0)
    vpn.statusUnknown = true
    compare(summary.stateKind, "unknown")
    compare(summary.activeLabel, "Last known")
    compare(summary.ipText, "Unverified")
    verify(!findChild(summary, "summaryCopyIp").visible)

    vpn.statusUnknown = false
    vpn.tunnelStale = false
    vpn.legacyTunnel = true
    compare(summary.stateKind, "legacy")
    vpn.legacyTunnel = false
    vpn.disconnecting = true
    compare(summary.stateKind, "disconnecting")
    vpn.disconnecting = false
    vpn.connecting = true
    compare(summary.stateKind, "connecting")
  }

  function test_initialStatusAndSetupAreNotReportedAsDisconnected() {
    vpn.rawStatusText = ""
    var summary = createTemporaryObject(factory, this)
    compare(summary.stateKind, "checking")
    vpn.setupDone = false
    compare(summary.stateKind, "setup")
    vpn.statusProbeError = "Timed out"
    compare(summary.stateKind, "unknown")
  }

  function test_privacyMasksIpAndBlocksCopy() {
    vpn.connected = true
    vpn.publicIp = "198.51.100.24"
    var summary = createTemporaryObject(factory, this)
    var copyButton = findChild(summary, "summaryCopyIp")
    var privacyButton = findChild(summary, "summaryPrivacyToggle")
    var process = findChild(summary, "summaryClipboardProcess")
    verify(copyButton.visible && copyButton.enabled)
    copyButton.clicked()
    compare(process.command[1], vpn.publicIp)
    verify(process.running)
    verify(copyButton.visible && !copyButton.enabled)
    verify(!summary.ipCopied)
    process.running = false
    process.exited(0)
    verify(summary.ipCopied)

    verify(privacyButton.visible && privacyButton.enabled)
    privacyButton.clicked()
    compare(vpn.privacyActions, 1)
    verify(vpn.hideDetails)
    compare(summary.ipText, "Hidden")
    verify(!copyButton.visible)
    summary.copyIp()
    verify(!process.running)

    privacyButton.clicked()
    verify(!vpn.hideDetails)
    compare(summary.ipText, vpn.publicIp)
    verify(copyButton.visible)
    verify(!summary.ipCopied)
  }

  function test_copyFailureTimeoutAndPrivacyDuringCopy() {
    vpn.connected = true
    vpn.publicIp = "203.0.113.9"
    var summary = createTemporaryObject(factory, this)
    var process = findChild(summary, "summaryClipboardProcess")
    var timeout = findChild(summary, "summaryCopyTimeout")
    verify(process !== null && timeout !== null)

    summary.copyIp()
    process.running = false
    process.exited(1)
    verify(!summary.ipCopied)
    verify(summary.copyError.indexOf("Could not copy") >= 0)

    summary.copyIp()
    timeout.triggered()
    verify(summary.copyTimedOut)
    verify(!process.running)
    verify(!summary.ipCopied)
    verify(summary.copyError.indexOf("timed out") >= 0)
    process.exited(0)
    verify(!summary.ipCopied)

    summary.copyIp()
    verify(process.running)
    vpn.hideDetails = true
    verify(!process.running)
    process.exited(0)
    verify(!summary.ipCopied)
    verify(!summary.canCopyIp)
  }

  function test_compactWidthAndOptionalIp() {
    var summary = createTemporaryObject(factory, this)
    summary.width = 210
    verify(summary.height > 0)
    verify(summary.implicitHeight > 0)
    summary.showPublicIp = false
    verify(!findChild(summary, "summaryCopyIp").visible)
    var previousHeight = summary.height
    summary.showSelectedDestination = false
    tryVerify(function() { return summary.height < previousHeight })
    verify(summary.height < 200)
  }

  function test_compactCopyFailureRemainsVisible() {
    vpn.connected = true
    vpn.publicIp = "203.0.113.88"
    const summary = createTemporaryObject(factory, this)
    summary.compact = true
    const beforeHeight = summary.implicitHeight
    const process = findChild(summary, "summaryClipboardProcess")
    const error = findChild(summary, "compactCopyError")
    verify(error !== null && !error.visible)
    summary.copyIp()
    process.running = false
    process.exited(1)
    verify(summary.copyError !== "")
    tryVerify(function() { return error.visible && summary.implicitHeight > beforeHeight })
    vpn.hideDetails = true
    tryVerify(function() { return !error.visible })
  }

  function test_portugueseLabelsAndPrivacyTooltip() {
    vpn.connected = true
    vpn.publicIp = "203.0.113.16"
    var summary = createTemporaryObject(factory, this)
    summary.language = "pt-PT"
    compare(summary.stateText, "Ligado")
    compare(summary.activeLabel, "País ativo")
    compare(findChild(summary, "summaryPrivacyToggle").tooltipText, "Ocultar detalhes da ligação")
    vpn.hideDetails = true
    compare(summary.ipText, "Oculto")
    compare(findChild(summary, "summaryPrivacyToggle").tooltipText, "Mostrar detalhes da ligação")
  }
}
