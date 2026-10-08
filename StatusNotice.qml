import QtQuick
import qs.Commons
import qs.Ui

// Shared recovery surface, including errors that occur before setup completes.
Rectangle {
  id: root
  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property bool problem: service.lastError !== "" || service.statusProbeError !== "" || service.statusUnknown || service.tunnelStale
  readonly property string message: {
    if (service.lastError !== "")
      return service.lastError
    if (service.statusProbeError !== "")
      return service.statusProbeError
    if (service.statusUnknown)
      return "VPN status could not be verified. Recheck before changing the connection."
    if (service.legacyTunnel)
      return "This tunnel uses the previous helper. Disconnect once before removing it in Settings."
    if (service.actionStatus !== "")
      return service.actionStatus
    if (service.tunnelStale)
      return "No traffic received for " + Math.round(service.rxIdleSec / 60) + " min. The tunnel may be down."
    return service.applyHint
  }
  objectName: "statusBanner"
  visible: message !== ""
  width: parent ? parent.width : 300
  implicitHeight: visible ? content.implicitHeight + Style.space(12) : 0
  height: implicitHeight
  radius: Style.cornerRadius > 0 ? Style.space(6) : 0
  readonly property color noticeColor: problem ? Color.urgent : Color.accent
  color: Qt.rgba(noticeColor.r, noticeColor.g, noticeColor.b, 0.12)
  border.width: 1
  border.color: Qt.rgba(noticeColor.r, noticeColor.g, noticeColor.b, 0.3)

  Column {
    id: content
    x: Style.space(6)
    y: Style.space(6)
    width: parent.width - Style.space(12)
    spacing: Style.space(6)

    Text {
      objectName: "statusNoticeText"
      width: parent.width
      text: root.message
      textFormat: Text.PlainText
      color: root.problem ? Color.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }
    Button {
      objectName: "statusRecheck"
      visible: root.problem
      text: "Recheck status"
      iconText: ""
      focusable: true
      enabled: !root.service.busy
      foreground: root.foreground
      fontFamily: root.fontFamily
      Accessible.name: "Recheck VPN status"
      tooltipText: "Refresh setup and connection status without connecting (r)"
      onClicked: root.service.recheck()
    }
  }
}
