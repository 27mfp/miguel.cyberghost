import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Translations.js" as Translations

// Shared recovery surface, including errors that occur before setup completes.
Rectangle {
  id: root
  required property var service
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool showInformational: true
  readonly property string uiLanguage: typeof Commons.I18n !== "undefined" ? Commons.I18n.language : "en"
  readonly property bool problem: service.lastError !== "" || service.statusProbeError !== "" || service.statusUnknown || service.tunnelStale || service.legacyTunnel
  readonly property bool needsStatusCheck: service.statusProbeError !== "" || service.statusUnknown || service.tunnelStale
  readonly property string message: {
    if (service.statusProbeError !== "")
      return Translations.message(service.statusProbeError, uiLanguage)
    if (service.statusUnknown)
      return Translations.t("notice.unknown", uiLanguage)
    if (service.lastError !== "")
      return Translations.message(service.lastError, uiLanguage)
    if (service.legacyTunnel)
      return Translations.t("notice.legacy", uiLanguage)
    if (service.tunnelStale)
      return Translations.t("notice.noTraffic", uiLanguage, Math.round(service.rxIdleSec / 60))
    if (!root.showInformational)
      return ""
    if (service.actionStatus !== "")
      return Translations.message(service.actionStatus, uiLanguage)
    return Translations.message(service.applyHint, uiLanguage)
  }
  objectName: "statusBanner"
  visible: message !== ""
  width: parent ? parent.width : 300
  implicitHeight: visible ? content.implicitHeight + Style.space(12) : 0
  height: implicitHeight
  radius: Style.cornerRadius > 0 ? Style.space(6) : 0
  readonly property color noticeColor: problem ? Commons.Color.urgent : Commons.Color.accent
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
      color: root.problem ? Commons.Color.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }
    Button {
      objectName: "statusRecheck"
      visible: root.needsStatusCheck
      text: Translations.t("notice.recheck", root.uiLanguage)
      iconText: ""
      focusable: true
      enabled: !root.service.busy
      foreground: root.foreground
      fontFamily: root.fontFamily
      Accessible.name: Translations.t("notice.recheckAccessible", root.uiLanguage)
      tooltipText: Translations.t("notice.recheckTooltip", root.uiLanguage)
      onClicked: root.service.recheck()
    }
    Button {
      objectName: "dismissNotice"
      visible: root.service.lastError !== "" && !root.service.statusUnknown && root.service.statusProbeError === ""
      text: Translations.t("notice.dismiss", root.uiLanguage)
      focusable: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      Accessible.name: Translations.t("notice.dismissAccessible", root.uiLanguage)
      tooltipText: Translations.t("notice.dismissTooltip", root.uiLanguage)
      onClicked: root.service.lastError = ""
    }
  }
}
