pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Translations.js" as Translations

// The quiet, visual centre of the VPN panel. State comes exclusively from the
// service's observed tunnel/status fields; a public IP is never proof of VPN.
// The connect/disconnect control belongs to the surrounding panel.
Item {
  id: root
  objectName: "vpnConnectionStage"

  required property var service
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property string language: "en"
  property bool disableAnimation: false
  property bool compact: false

  readonly property bool unverified: !!service.statusUnknown || !!service.statusProbeError
  readonly property bool awaitingFirstCheck: !unverified && !service.connected
    && !service.connecting && !service.disconnecting && !service.resolvingAutomaticServer
    && !service.legacyTunnel && ("rawStatusText" in service) && !service.rawStatusText

  readonly property string stateKind: {
    if (unverified) return "unknown"
    if (service.disconnecting) return "disconnecting"
    if (service.connecting || service.resolvingAutomaticServer) return "connecting"
    if (service.legacyTunnel) return "legacy"
    if (service.connected && service.tunnelStale) return "stale"
    if (service.connected) return "connected"
    if (service.setupDone === false) return "setup"
    if (awaitingFirstCheck) return "checking"
    return "disconnected"
  }

  readonly property bool connectedVerified: stateKind === "connected"
  readonly property bool inTransition: stateKind === "connecting" || stateKind === "disconnecting"
  readonly property bool needsAttention: stateKind === "unknown" || stateKind === "stale" || stateKind === "legacy"
  readonly property color brandYellow: "#FFCE00"
  readonly property color visualColor: connectedVerified ? brandYellow
    : needsAttention ? Commons.Color.urgent : foreground
  readonly property bool reducedMotion: Style.reduceMotion || disableAnimation

  readonly property string title: Translations.t("redesign.stage.state." + stateKind, language)

  readonly property string subtitle: {
    const detail = Translations.t("redesign.stage.subtitle." + stateKind, language)
    // This is the observed active tunnel's country, never the user's next
    // destination or the GeoIP estimate. Unknown/legacy states omit it.
    if (connectedVerified && service.activeCountryName)
      return Translations.t("redesign.stage.country", language) + ": " + service.activeCountryName + " · " + detail
    return detail
  }

  readonly property real orbitSize: compact
    ? Math.min(Style.space(76), Math.max(Style.space(62), width * 0.20))
    : Math.min(Style.space(104), Math.max(Style.space(84), width * 0.27))
  readonly property int verticalPadding: compact ? Style.space(6) : Style.space(10)
  width: parent ? parent.width : Style.space(380)
  implicitHeight: compact
    ? Math.max(Style.space(126), content.implicitHeight + verticalPadding * 2)
    : Math.min(Style.space(205), Math.max(Style.space(165), content.implicitHeight + verticalPadding * 2))
  height: implicitHeight
  Accessible.role: Accessible.Grouping
  Accessible.name: Translations.t("redesign.header.label", language) + ": " + title + ". " + subtitle

  Column {
    id: content
    anchors.centerIn: parent
    width: Math.max(0, parent.width - Style.space(12))
    spacing: Style.space(0)

    Item {
      id: orbit
      anchors.horizontalCenter: parent.horizontalCenter
      width: root.orbitSize
      height: width
      Accessible.ignored: true

      // Single restrained ring and a barely tinted centre; no card chrome.
      Rectangle {
        id: ring
        anchors.fill: parent
        radius: width / 2
        color: Qt.rgba(root.visualColor.r, root.visualColor.g, root.visualColor.b,
          root.connectedVerified ? 0.085 : 0.035)
        border.width: Style.space(1)
        border.color: Qt.rgba(root.visualColor.r, root.visualColor.g, root.visualColor.b,
          root.connectedVerified || root.needsAttention ? 0.34 : 0.19)

        Behavior on color {
          ColorAnimation { duration: root.reducedMotion ? 0 : Style.duration(200); easing.type: Easing.OutCubic }
        }
      }

      GhostIcon {
        id: ghost
        objectName: "stageGhost"
        anchors.centerIn: parent
        iconSize: orbit.width * 0.61
        color: root.connectedVerified ? root.brandYellow : root.foreground
        innerColor: Commons.Color.popups.background
        active: root.connectedVerified
        connecting: root.inTransition
        warning: false
        reducedMotion: root.reducedMotion

        Behavior on color {
          ColorAnimation { duration: root.reducedMotion ? 0 : Style.duration(200); easing.type: Easing.OutCubic }
        }
      }
    }

    Item { width: 1; height: root.compact ? Style.space(7) : Style.space(11) }

    Text {
      id: stateText
      objectName: "stageTitle"
      width: parent.width
      text: root.title
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Math.round(Math.min(Style.font.subtitle * (root.compact ? 1.32 : 1.5), Math.max(Style.font.subtitle, root.width * 0.07)))
      font.weight: Font.DemiBold
      elide: Text.ElideRight
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }

    Item { width: 1; height: Style.space(4) }

    Text {
      id: secondaryText
      objectName: "stageSubtitle"
      width: parent.width
      text: root.subtitle
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      color: root.foreground
      opacity: 0.67
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }
  }
}
