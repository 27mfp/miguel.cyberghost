pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "miguel.cyberghost"
  ipcTarget: "miguel.cyberghost"
  manageIpc: false

  required property var cyberghost
  property var anchorItem: null
  property var hostWidget: null
  property real preferredContentWidth: 380
  readonly property var barIdentity: hostWidget || root
  function switchPanel(direction) {
    return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(barIdentity, direction) : false
  }

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.25)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color brandYellow: "#FFCE00"
  readonly property bool reduceMotion: !!setting("reduceMotion", false)

  onOpenedChanged: {
    if (root.opened && cyberghost) {
      // Recheck's completion handler refreshes status; avoiding a second
      // immediate poll keeps opening the panel cheap.
      cyberghost.recheck()
      cyberghost.refreshServers()
      // Force a GeoIP lookup so the exposed/VPN IP is never stale.
      cyberghost.refreshIpInfo(true)
    }
  }

  function close() {
    preferences.closePopups()
    setupCard.clearPassword()
    root.controller.hide()
  }

  function toggleRunning() {
    cyberghost.toggle()
  }

  function refresh() {
    cyberghost.recheck()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened && root.cyberghost !== null
    focusTarget: !root.cyberghost || !root.cyberghost.setupDone ? setupCard.focusTarget : preferences.primaryFocusTarget
    // Keep the same sizing contract as the official Omarchy panels: the
    // KeyboardPanel owns the popup padding, while the content column fills
    // the available inner width without a second manual inset.
    contentWidth: panel.fittedContentWidth(Style.space(root.preferredContentWidth))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      anchors.fill: parent
      focus: false
      blocked: true
      onCloseRequested: root.close()

      Flickable {
        id: scroll
        objectName: "vpnPanelViewport"
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        QQC.ScrollBar.vertical: QQC.ScrollBar {
          policy: QQC.ScrollBar.AsNeeded
        }

        // KeyboardPanel is a window, so keep the Escape handler on this
        // descendant Item. This mirrors the official panels and avoids an
        // invalid Keys attachment while native buttons retain Tab/Enter.
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (preferences.popupOpen)
            return
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          }
        }

        Column {
          id: mainColumn
          objectName: "vpnPanelContent"
          width: scroll.width
          spacing: Style.space(8)

          // Observed status is separate from next-connection preferences.
          Item {
            visible: root.cyberghost.setupDone
            width: parent.width
            implicitHeight: visible ? hero.implicitHeight : 0
            height: implicitHeight
            clip: true

            PanelHero {
              id: hero
              width: parent.width
              title: "CyberGhost VPN"
              meta: {
                if (root.cyberghost.connecting)
                  return "Connecting to " + root.cyberghost.countryName + "…"
                if (root.cyberghost.disconnecting)
                  return "Disconnecting tunnel…"
                if (root.cyberghost.connected && root.cyberghost.tunnelStale)
                  return "Connected · handshake stale ⚠"
                if (root.cyberghost.connected) {
                  return root.cyberghost.lastBackend === "wireguard" ? "WireGuard tunnel active" : "VPN connection active"
                }
                return "VPN disconnected"
              }
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.cyberghost.active ? 1.0 : 0.65

              iconComponent: Component {
                GhostIcon {
                  iconSize: Style.font.display
                  color: root.cyberghost.active ? root.brandYellow : root.dim
                  innerColor: Color.popups.background
                  active: root.cyberghost.active
                  connecting: root.cyberghost.connecting || root.cyberghost.disconnecting
                  reducedMotion: root.reduceMotion
                }
              }
            }
          }

          // -------------------------------------------------------------
          // 2. ERROR / STATUS BANNER
          // -------------------------------------------------------------
          Rectangle {
            id: statusBanner
            readonly property bool isError: root.cyberghost.lastError !== "" || root.cyberghost.tunnelStale
            visible: root.cyberghost.setupDone && (root.cyberghost.lastError !== "" || root.cyberghost.actionStatus !== "" || root.cyberghost.applyHint !== "" || root.cyberghost.tunnelStale)
            width: parent.width
            implicitHeight: visible ? bannerText.implicitHeight + Style.space(12) : 0
            height: implicitHeight
            clip: true
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: statusBanner.isError ? Util.alpha(Color.urgent, 0.15) : Util.alpha(Color.accent, 0.15)
            border.width: 1
            border.color: statusBanner.isError ? Util.alpha(Color.urgent, 0.35) : Util.alpha(Color.accent, 0.35)

            Text {
              id: bannerText
              textFormat: Text.PlainText
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: {
                if (root.cyberghost.lastError !== "")
                  return root.cyberghost.lastError
                if (root.cyberghost.actionStatus !== "")
                  return root.cyberghost.actionStatus
                if (root.cyberghost.tunnelStale)
                  return "Handshake stale (" + Math.round(root.cyberghost.handshakeAgeSec / 60) + " min) — tunnel may be down. Reconnect recommended."
                return root.cyberghost.applyHint
              }
              color: statusBanner.isError ? Color.urgent : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              verticalAlignment: Text.AlignVCenter
            }
          }

          SetupCard {
            id: setupCard
            width: parent.width
            service: root.cyberghost
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Destination first, then one explicit connection action.
          ConnectionSettings {
            id: preferences
            visible: root.cyberghost.setupDone
            width: parent.width
            service: root.cyberghost
            foreground: root.foreground
            fontFamily: root.fontFamily
            primaryActions: Component {
              Item {
                id: actionsRow
                readonly property var focusTarget: connectBtn
                visible: root.cyberghost.setupDone
                width: parent.width
                implicitHeight: Math.max(refreshStatusButton.height, connectBtn.implicitHeight)

                Button {
                  id: refreshStatusButton
                  width: Style.space(28)
                  implicitWidth: Style.space(28)
                  implicitHeight: Style.space(28)
                  horizontalPadding: 0
                  verticalPadding: 0
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  enabled: !root.cyberghost.busy
                  focusable: true
                  bordered: false
                  text: ""
                  iconText: "\uf021"
                  foreground: root.dim
                  Accessible.name: "Refresh VPN status"
                  tooltipText: "Refresh VPN status"
                  onClicked: root.refresh()
                }

                Button {
                  id: connectBtn
                  objectName: "connectButton"
                  anchors.left: parent.left
                  anchors.right: refreshStatusButton.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  enabled: !root.cyberghost.busy
                  focusable: true
                  Accessible.name: root.cyberghost.active ? "Disconnect VPN" : "Connect VPN"
                  iconText: "\uf011"
                  text: root.cyberghost.connecting ? "Connecting…" : (root.cyberghost.disconnecting ? "Disconnecting…" : (root.cyberghost.active ? "Disconnect" : "Connect"))
                  selected: root.cyberghost.active
                  bordered: true
                  foreground: root.cyberghost.active ? Color.urgent : root.brandYellow
                  tooltipText: root.cyberghost.active ? "Stop VPN connection" : "Start VPN connection"
                  onClicked: root.toggleRunning()
                }
              }
            }
            connectionDetails: Component {
              ConnectionDetails {
                width: parent.width
                service: root.cyberghost
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
            }
          }
        }
      }
    }
  }
}
