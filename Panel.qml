import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Countries.js" as Countries

Panel {
  id: root
  moduleName: "miguel.cyberghost"
  ipcTarget: "miguel.cyberghost"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color brandYellow: "#FFCE00"
  readonly property color successGreen: "#10B981"

  readonly property var popularList: Countries.popularCountries
  readonly property var dropdownOptionsList: Countries.dropdownOptions()

  onOpenedChanged: {
    if (root.opened) {
      cyberghost.refresh()
    }
  }

  function toggleRunning() {
    cyberghost.toggle()
  }

  function connectToCountry(code) {
    cyberghost.connectTo(code, cyberghost.protocol, cyberghost.serverType, cyberghost.streamingService)
  }

  function setServerType(type) {
    cyberghost.serverType = type
    if (cyberghost.connected) {
      cyberghost.connectTo(cyberghost.country, cyberghost.protocol, type, cyberghost.streamingService)
    }
  }

  function setProtocol(proto) {
    cyberghost.protocol = proto
    if (cyberghost.connected) {
      cyberghost.connectTo(cyberghost.country, proto, cyberghost.serverType, cyberghost.streamingService)
    }
  }

  function refresh() {
    cyberghost.refresh()
  }

  Service {
    id: cyberghost
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // -------------------------------------------------------------
  // BAR ICON BUTTON (MOUNTED IN THE STATUS BAR)
  // -------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened
    tooltipText: {
      if (cyberghost.connecting) return "CyberGhost VPN: Connecting to " + cyberghost.countryName + " (" + cyberghost.country + ")…"
      if (cyberghost.disconnecting) return "CyberGhost VPN: Disconnecting…"
      if (cyberghost.connected) {
        var ipPart = cyberghost.publicIp !== "" ? (" • " + cyberghost.publicIp) : ""
        return "CyberGhost VPN: Connected (" + cyberghost.countryName + " " + cyberghost.countryFlag + ")" + ipPart
      }
      return "CyberGhost VPN: Disconnected (Click to open)"
    }

    iconComponent: Component {
      Item {
        anchors.fill: parent

        GhostIcon {
          anchors.centerIn: parent
          iconSize: Style.font.icon
          color: cyberghost.active ? root.brandYellow : (root.bar ? root.bar.barForeground : Color.foreground)
          innerColor: Color.bar.background
          active: cyberghost.active
          connecting: cyberghost.connecting || cyberghost.disconnecting
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        cyberghost.toggle()
      } else if (buttonCode === Qt.LeftButton) {
        root.toggle()
      } else if (buttonCode === Qt.RightButton) {
        root.toggle()
      }
    }
  }

  // Active connected indicator dot (Green)
  Rectangle {
    id: activeDot
    visible: cyberghost.active && !cyberghost.connecting && !cyberghost.disconnecting
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    anchors.margins: Math.max(1, Math.round(Style.space(1)))
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.successGreen
    border.width: 1
    border.color: Qt.rgba(0, 0, 0, 0.4)
  }

  // Pulsing dot during connection / disconnection (Brand Yellow)
  Rectangle {
    id: connectingDot
    visible: cyberghost.connecting || cyberghost.disconnecting
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    anchors.margins: Math.max(1, Math.round(Style.space(1)))
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.brandYellow

    SequentialAnimation on opacity {
      running: cyberghost.connecting || cyberghost.disconnecting
      loops: Animation.Infinite
      NumberAnimation { to: 0.25; duration: 500; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutSine }
    }
  }

  // -------------------------------------------------------------
  // POPUP PANEL (ANCHORED UNDER THE BAR ICON)
  // -------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(385))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: countryDropdown.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        else if (text === " ") root.toggleRunning()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight + Style.space(16)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: mainColumn
          x: Style.space(14)
          y: Style.space(8)
          width: scroll.width - Style.space(28)
          spacing: Style.space(10)

          // -------------------------------------------------------------
          // 1. HERO HEADER
          // -------------------------------------------------------------
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "CyberGhost VPN"
              meta: {
                if (cyberghost.connecting) return "Connecting to " + cyberghost.countryName + "…"
                if (cyberghost.disconnecting) return "Disconnecting tunnel…"
                if (cyberghost.connected) {
                  return "Connected · " + cyberghost.countryName + " " + cyberghost.countryFlag
                }
                return "Disconnected · Traffic Unencrypted"
              }
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: cyberghost.active ? 1.0 : 0.65

              iconComponent: Component {
                GhostIcon {
                  iconSize: Style.font.display
                  color: cyberghost.active ? root.brandYellow : root.dim
                  innerColor: Color.popups.background
                  active: cyberghost.active
                  connecting: cyberghost.connecting || cyberghost.disconnecting
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: cyberghost.active
                  busy: cyberghost.busy
                  foreground: hero.foreground
                  accent: root.brandYellow
                  onToggled: root.toggleRunning()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: cyberghost.active ? "Disconnect VPN" : "Connect to CyberGhost"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // -------------------------------------------------------------
          // 2. ERROR / STATUS BANNER
          // -------------------------------------------------------------
          Rectangle {
            id: statusBanner
            visible: (cyberghost.actionStatus !== "" || cyberghost.lastError !== "")
            width: parent.width
            implicitHeight: bannerText.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: (cyberghost.lastError !== "")
              ? Qt.rgba(1.0, 0.2, 0.2, 0.15)
              : Qt.rgba(0.2, 0.6, 1.0, 0.15)
            border.width: 1
            border.color: (cyberghost.lastError !== "")
              ? Qt.rgba(1.0, 0.2, 0.2, 0.35)
              : Qt.rgba(0.2, 0.6, 1.0, 0.35)

            Text {
              id: bannerText
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: cyberghost.lastError !== "" ? cyberghost.lastError : cyberghost.actionStatus
              color: cyberghost.lastError !== "" ? Color.urgent : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              verticalAlignment: Text.AlignVCenter
            }
          }

          // -------------------------------------------------------------
          // 3. LIVE CONNECTION & IP CARD (PERFECTLY PADDED & BOUNDED)
          // -------------------------------------------------------------
          Rectangle {
            id: infoCard
            width: parent.width
            implicitHeight: infoColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: Util.alpha(Color.popups.text, cyberghost.connected ? 0.04 : 0.02)
            border.width: 1
            border.color: cyberghost.connected ? Qt.rgba(1.0, 0.81, 0.0, 0.4) : Color.popups.border

            Column {
              id: infoColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              // Status badge line + Protocol pill
              Item {
                width: parent.width
                implicitHeight: Math.max(statusBadgeRow.implicitHeight, protoPill.implicitHeight)

                Row {
                  id: statusBadgeRow
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Rectangle {
                    width: Style.space(8)
                    height: width
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: cyberghost.connected ? root.successGreen : (cyberghost.connecting ? root.brandYellow : root.urgent)
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: cyberghost.connected ? "PROTECTED & ENCRYPTED" : (cyberghost.connecting ? "CONNECTING SECURE TUNNEL…" : "PUBLIC IP EXPOSED")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: cyberghost.connected ? root.successGreen : (cyberghost.connecting ? root.brandYellow : root.dim)
                  }
                }

                // Protocol pill (Sized and positioned inside right margin)
                Rectangle {
                  id: protoPill
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: protoText.implicitWidth + Style.space(14)
                  implicitHeight: protoText.implicitHeight + Style.space(6)
                  radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                  color: cyberghost.connected ? Qt.rgba(0.1, 0.8, 0.4, 0.15) : Qt.rgba(0.5, 0.5, 0.5, 0.12)
                  border.width: 1
                  border.color: cyberghost.connected ? Qt.rgba(0.1, 0.8, 0.4, 0.4) : Qt.rgba(0.5, 0.5, 0.5, 0.25)

                  Text {
                    id: protoText
                    anchors.centerIn: parent
                    text: cyberghost.protocol === "wireguard" ? "WireGuard" : "OpenVPN"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: cyberghost.connected ? root.successGreen : root.dim
                  }
                }
              }

              // Divider
              Rectangle {
                width: parent.width
                height: 1
                color: Util.alpha(Color.popups.border, 0.35)
              }

              // IP details
              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  text: "IP Address:"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: cyberghost.publicIp !== "" ? cyberghost.publicIp : (cyberghost.fetchingIp ? "Checking IP…" : "146.70.59.132")
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  color: root.foreground
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // Location and ISP clean summary
              Text {
                width: parent.width
                text: {
                  var loc = []
                  if (cyberghost.publicCity) loc.push(cyberghost.publicCity)
                  if (cyberghost.publicCountry) loc.push(Countries.countryName(cyberghost.publicCountry) + " " + Countries.countryFlag(cyberghost.publicCountry))
                  else if (cyberghost.countryName) loc.push(cyberghost.countryName + " " + cyberghost.countryFlag)

                  var locStr = loc.join(", ")
                  if (cyberghost.publicOrg) {
                    return locStr !== "" ? (locStr + "  •  " + cyberghost.publicOrg) : cyberghost.publicOrg
                  }
                  return locStr || "Connected"
                }
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // -------------------------------------------------------------
          // 4. POPULAR LOCATIONS (2x6 UNIFORM GRID)
          // -------------------------------------------------------------
          PanelSectionHeader {
            text: "POPULAR LOCATIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Grid {
            id: popularGrid
            width: parent.width
            columns: 6
            spacing: Style.space(6)
            readonly property real cellW: Math.floor((width - spacing * 5) / 6)

            Repeater {
              model: root.popularList

              delegate: Button {
                required property var modelData
                required property int index
                width: popularGrid.cellW

                text: modelData.flag + " " + modelData.code
                selected: (cyberghost.country === modelData.code)
                bordered: true
                foreground: root.foreground
                tooltipText: modelData.name + " (" + modelData.code + ")"
                onClicked: root.connectToCountry(modelData.code)
              }
            }
          }

          // -------------------------------------------------------------
          // 5. ALL LOCATIONS DROPDOWN
          // -------------------------------------------------------------
          PanelSectionHeader {
            text: "ALL LOCATIONS (100+)"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          SearchableDropdown {
            id: countryDropdown
            width: parent.width
            label: "Search country"
            placeholderText: "Search 100+ countries…"
            value: cyberghost.country
            options: root.dropdownOptionsList
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(val) {
              root.connectToCountry(val)
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // -------------------------------------------------------------
          // 6. SERVER MODE SELECTOR
          // -------------------------------------------------------------
          PanelSectionHeader {
            text: "SERVER MODE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: modeRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellW: Math.floor((width - spacing * 2) / 3)

            Button {
              width: modeRow.cellW
              text: "⚡ Traffic"
              selected: cyberghost.serverType === "traffic"
              bordered: true
              foreground: root.foreground
              tooltipText: "Fastest standard routing for web browsing"
              onClicked: root.setServerType("traffic")
            }

            Button {
              width: modeRow.cellW
              text: "🔒 Torrent"
              selected: cyberghost.serverType === "torrent"
              bordered: true
              foreground: root.foreground
              tooltipText: "Servers optimized for P2P and torrenting"
              onClicked: root.setServerType("torrent")
            }

            Button {
              width: modeRow.cellW
              text: "🎬 Streaming"
              selected: cyberghost.serverType === "streaming"
              bordered: true
              foreground: root.foreground
              tooltipText: "Servers optimized for streaming media"
              onClicked: root.setServerType("streaming")
            }
          }

          // -------------------------------------------------------------
          // 7. PROTOCOL SELECTOR
          // -------------------------------------------------------------
          PanelSectionHeader {
            text: "PROTOCOL & CONTROLS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: protoRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellW: Math.floor((width - spacing * 2) / 3)

            Button {
              width: protoRow.cellW
              text: "WireGuard"
              selected: cyberghost.protocol === "wireguard"
              bordered: true
              foreground: root.foreground
              tooltipText: "WireGuard protocol (Fastest and modern)"
              onClicked: root.setProtocol("wireguard")
            }

            Button {
              width: protoRow.cellW
              text: "OpenVPN UDP"
              selected: cyberghost.protocol === "openvpn"
              bordered: true
              foreground: root.foreground
              tooltipText: "OpenVPN over UDP"
              onClicked: root.setProtocol("openvpn")
            }

            Button {
              width: protoRow.cellW
              text: "OpenVPN TCP"
              selected: cyberghost.protocol === "openvpn_tcp"
              bordered: true
              foreground: root.foreground
              tooltipText: "OpenVPN over TCP"
              onClicked: root.setProtocol("openvpn_tcp")
            }
          }

          // -------------------------------------------------------------
          // 8. ACTIONS ROW
          // -------------------------------------------------------------
          Row {
            id: actionsRow
            width: parent.width
            spacing: Style.space(8)
            readonly property real cellW: Math.floor((width - spacing) / 2)

            Button {
              width: actionsRow.cellW
              text: "󰑐 Refresh Status"
              bordered: true
              foreground: root.foreground
              tooltipText: "Check VPN status and reload IP information"
              onClicked: root.refresh()
            }

            Button {
              width: actionsRow.cellW
              text: cyberghost.active ? "󰅖 Disconnect" : "󰄬 Connect"
              selected: cyberghost.active
              bordered: true
              foreground: cyberghost.active ? Color.urgent : root.brandYellow
              tooltipText: cyberghost.active ? "Stop VPN connection" : "Start VPN connection"
              onClicked: root.toggleRunning()
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }
}
