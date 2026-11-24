pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Translations.js" as Translations

// A compact, read-only view of the observed tunnel and the next destination.
// The IP is informational: a public IP alone never establishes VPN status.
Rectangle {
  id: root

  required property var service
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  // Optional override for standalone consumers; empty follows Omarchy.
  property string language: ""
  property bool showPublicIp: true
  property bool showSelectedDestination: true
  property bool compact: false
  property bool ipCopied: false
  property bool copyTimedOut: false
  property string copyError: ""

  // The standalone component test's host double has no I18n singleton.
  // Missing catalogue entries keep their English text until translations land.
  function tr(key, english, values) {
    let locale = root.language
    if (!locale) {
      try { locale = Commons.I18n.language } catch (e) { }
    }
    let translated = Translations.t(key, locale, values)
    if (translated !== key) return translated
    let fallback = String(english)
    if (values !== undefined && values !== null) {
      let args = Array.isArray(values) ? values : [values]
      for (let i = 0; i < args.length; i++)
        fallback = fallback.replace("%" + (i + 1), String(args[i]))
    }
    return fallback
  }

  readonly property bool uncertain: !!service.statusUnknown || !!service.statusProbeError
  readonly property bool checking: !uncertain && !service.connected && !service.connecting
    && !service.disconnecting && !service.resolvingAutomaticServer && !service.legacyTunnel
    && ("rawStatusText" in service) && !service.rawStatusText
  readonly property string stateKind: {
    if (uncertain) return "unknown"
    if (service.disconnecting) return "disconnecting"
    if (service.connecting || service.resolvingAutomaticServer) return "connecting"
    if (service.legacyTunnel) return "legacy"
    if (service.connected && service.tunnelStale) return "stale"
    if (service.connected) return "connected"
    if (service.setupDone === false) return "setup"
    if (checking) return "checking"
    return "disconnected"
  }
  readonly property string stateText: {
    switch (stateKind) {
    case "unknown": return tr("summary.state.unknown", "Status unknown")
    case "disconnecting": return tr("summary.state.disconnecting", "Disconnecting…")
    case "connecting": return tr("summary.state.connecting", "Connecting…")
    case "legacy": return tr("summary.state.legacy", "Previous helper tunnel")
    case "stale": return tr("summary.state.stale", "Connected · traffic idle")
    case "connected": return tr("summary.state.connected", "Connected")
    case "checking": return tr("summary.state.checking", "Checking connection…")
    case "setup": return tr("summary.state.setup", "Setup required")
    default: return tr("summary.state.disconnected", "Disconnected")
    }
  }
  readonly property string stateDetail: {
    switch (stateKind) {
    case "unknown": return tr("summary.detail.unknown", "Current tunnel state is unverified")
    case "disconnecting": return tr("summary.detail.disconnecting", "Waiting for the disconnect result")
    case "connecting": return tr("summary.detail.connecting", "Waiting for the connection result")
    case "legacy": return tr("summary.detail.legacy", "Managed by the previous CyberGhost helper")
    case "stale": return tr("summary.detail.stale", "No recent incoming traffic; tunnel may be down")
    case "connected": return tr("summary.detail.connected", "Tunnel reported by NetworkManager")
    case "checking": return tr("summary.detail.checking", "Waiting for the first status check")
    case "setup": return tr("summary.detail.setup", "Finish setup to use the VPN")
    default: return tr("summary.detail.disconnected", "No CyberGhost tunnel reported")
    }
  }
  readonly property bool warning: stateKind === "unknown" || stateKind === "legacy" || stateKind === "stale"
  readonly property color statusColor: warning ? Commons.Color.urgent
    : stateKind === "connected" ? Commons.Color.accent : root.foreground
  readonly property string activeLabel: uncertain ? tr("summary.lastKnown", "Last known") : tr("summary.activeCountry", "Active country")
  readonly property string activeName: {
    if (service.connected || service.legacyTunnel || uncertain)
      return service.activeCountryName || tr("summary.notConfirmed", "Not confirmed")
    return tr("summary.none", "None")
  }
  readonly property string selectedName: service.countryName || tr("summary.notSelected", "Not selected")
  readonly property bool privateIp: !!service.hideDetails
  readonly property string publicIp: String(service.publicIp || "")
  readonly property string ipText: privateIp ? tr("summary.hidden", "Hidden")
    : uncertain ? tr("summary.unverified", "Unverified")
    : publicIp ? publicIp
    : service.fetchingIp ? tr("summary.checkingIp", "Checking…") : tr("summary.unavailable", "Unavailable")
  readonly property bool copyEligible: showPublicIp && !privateIp && !uncertain
    && !service.connecting && !service.disconnecting
    && !service.resolvingAutomaticServer && publicIp !== ""
  readonly property bool canCopyIp: copyEligible && !clipboardProcess.running
  readonly property bool canTogglePrivacy: typeof service.setHideDetails === "function"

  function copyIp() {
    if (!canCopyIp) return
    ipCopied = false
    copyTimedOut = false
    copyError = ""
    copyReset.stop()
    clipboardProcess.command = ["/usr/bin/wl-copy", publicIp]
    clipboardProcess.running = true
    copyTimeout.restart()
  }

  function togglePrivacy() {
    if (canTogglePrivacy) service.setHideDetails(!privateIp)
  }

  onPrivateIpChanged: {
    ipCopied = false
    if (privateIp) {
      copyError = ""
      if (clipboardProcess.running) {
        copyTimedOut = true
        clipboardProcess.running = false
        copyTimeout.stop()
      }
    }
  }
  onPublicIpChanged: {
    ipCopied = false
    if (clipboardProcess.running) {
      copyTimedOut = true
      clipboardProcess.running = false
      copyTimeout.stop()
    }
  }

  Process {
    id: clipboardProcess
    objectName: "summaryClipboardProcess"
    onExited: function(exitCode) {
      copyTimeout.stop()
      if (root.copyTimedOut) return
      root.ipCopied = exitCode === 0 && !root.privateIp
      if (exitCode !== 0) root.copyError = root.tr("summary.copyFailed", "Could not copy the public IP. Check that wl-copy is installed.")
      if (root.ipCopied) copyReset.restart()
    }
  }

  Timer {
    id: copyReset
    interval: 2200
    onTriggered: root.ipCopied = false
  }

  Timer {
    id: copyTimeout
    objectName: "summaryCopyTimeout"
    interval: 3000
    onTriggered: {
      root.copyTimedOut = true
      root.ipCopied = false
      clipboardProcess.running = false
      root.copyError = root.tr("summary.copyTimeout", "Copying the public IP timed out.")
    }
  }

  readonly property int inset: Style.space(12)
  width: parent ? parent.width : Style.space(320)
  implicitHeight: compact
    ? compactRow.implicitHeight + Style.space(8) + (copyError !== "" ? compactError.implicitHeight + Style.space(6) : 0)
    : contents.implicitHeight + inset * 2
  height: implicitHeight
  radius: compact ? 0 : Style.space(8)
  color: compact ? "transparent" : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.045)
  border.width: compact ? 0 : Style.space(1)
  border.color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  Accessible.role: Accessible.Grouping
  Accessible.name: tr("summary.accessibility", "VPN connection summary: %1", [stateText])

  Column {
    id: contents
    visible: !root.compact
    x: root.inset
    y: root.inset
    width: Math.max(0, root.width - root.inset * 2)
    spacing: Style.space(8)

    Item {
      width: parent.width
      implicitHeight: Math.max(statusLine.implicitHeight, privacyButton.visible ? privacyButton.implicitHeight : 0)
      height: implicitHeight

      Row {
        id: statusLine
        width: parent.width - (privacyButton.visible ? privacyButton.width + Style.space(6) : 0)
        spacing: Style.space(8)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(8)
          height: width
          radius: width / 2
          color: root.statusColor
        }

        Column {
          width: Math.max(0, parent.width - Style.space(16))
          spacing: Style.space(2)

          Text {
            objectName: "summaryState"
            width: parent.width
            text: root.stateText
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            Accessible.role: Accessible.StaticText
            Accessible.name: text
          }

          Text {
            objectName: "summaryDetail"
            width: parent.width
            text: root.stateDetail
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
          }
        }
      }

      PanelActionButton {
        id: privacyButton
        objectName: "summaryPrivacyToggle"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.canTogglePrivacy
        enabled: root.canTogglePrivacy
        focusable: true
        iconText: root.privateIp ? "" : ""
        tooltipText: root.privateIp ? root.tr("summary.show", "Show connection details") : root.tr("summary.hide", "Hide connection details")
        Accessible.name: tooltipText
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.togglePrivacy()
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(1)
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
    }

    SummaryRow {
      width: parent.width
      label: root.activeLabel
      value: root.activeName
    }

    SummaryRow {
      visible: root.showSelectedDestination
      width: parent.width
      label: root.tr("summary.selected", "Selected")
      value: root.selectedName
    }

    Item {
      visible: root.showPublicIp
      width: parent.width
      implicitHeight: Math.max(ipRow.implicitHeight, copyButton.visible ? copyButton.implicitHeight : 0)
      height: visible ? implicitHeight : 0

      SummaryRow {
        id: ipRow
        width: parent.width - (copyButton.visible ? copyButton.width + Style.space(4) : 0)
        label: root.tr("summary.publicIp", "Public IP")
        value: root.ipText
        Accessible.name: root.tr("summary.publicIp", "Public IP") + ": " + root.ipText
      }

      PanelActionButton {
        id: copyButton
        objectName: "summaryCopyIp"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.copyEligible
        enabled: root.canCopyIp
        focusable: true
        iconText: root.ipCopied ? "" : ""
        tooltipText: root.ipCopied ? root.tr("summary.copied", "Copied") : root.tr("summary.copy", "Copy public IP")
        Accessible.name: root.ipCopied ? root.tr("summary.copiedAccessible", "Public IP copied") : root.tr("summary.copy", "Copy public IP")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.copyIp()
      }
    }

    Text {
      visible: root.copyError !== ""
      width: parent.width
      text: root.copyError
      textFormat: Text.PlainText
      color: Commons.Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }
  }

  Item {
    id: compactRow
    visible: root.compact
    anchors.left: parent.left
    anchors.right: parent.right
    y: Style.space(4)
    implicitHeight: Math.max(compactLabel.implicitHeight, compactValue.implicitHeight, compactPrivacy.implicitHeight, compactCopy.implicitHeight)

    Text {
      id: compactLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.tr("summary.publicIp", "Public IP").toUpperCase()
      color: root.foreground
      opacity: 0.64
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.weight: Font.DemiBold
      textFormat: Text.PlainText
    }

    PanelActionButton {
      id: compactPrivacy
      objectName: "summaryCompactPrivacy"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.canTogglePrivacy
      focusable: true
      iconText: root.privateIp ? "" : ""
      tooltipText: root.privateIp ? root.tr("summary.show", "Show connection details") : root.tr("summary.hide", "Hide connection details")
      Accessible.name: tooltipText
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.togglePrivacy()
    }

    PanelActionButton {
      id: compactCopy
      objectName: "summaryCompactCopy"
      anchors.right: compactPrivacy.visible ? compactPrivacy.left : parent.right
      anchors.rightMargin: compactPrivacy.visible ? Style.space(2) : 0
      anchors.verticalCenter: parent.verticalCenter
      visible: root.copyEligible
      enabled: root.canCopyIp
      focusable: true
      iconText: root.ipCopied ? "" : ""
      tooltipText: root.ipCopied ? root.tr("summary.copied", "Copied") : root.tr("summary.copy", "Copy public IP")
      Accessible.name: tooltipText
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.copyIp()
    }

    Text {
      id: compactValue
      objectName: "summaryCompactIp"
      anchors.right: compactCopy.visible ? compactCopy.left : (compactPrivacy.visible ? compactPrivacy.left : parent.right)
      anchors.rightMargin: Style.space(5)
      anchors.left: compactLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: root.ipText
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideMiddle
    }
  }

  Text {
    id: compactError
    objectName: "compactCopyError"
    visible: root.compact && root.copyError !== ""
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: compactRow.bottom
    anchors.topMargin: Style.space(4)
    text: root.copyError
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Commons.Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }

  component SummaryRow: Item {
    id: line
    required property string label
    required property string value

    implicitHeight: Math.max(name.implicitHeight, valueText.implicitHeight)
    height: implicitHeight
    Accessible.role: Accessible.StaticText
    Accessible.name: label + ": " + value

    Text {
      id: name
      width: Math.min(Style.space(104), Math.max(Style.space(65), line.width * 0.34))
      text: line.label
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      id: valueText
      objectName: "summaryRowValue"
      anchors.left: name.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      text: line.value
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignRight
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
