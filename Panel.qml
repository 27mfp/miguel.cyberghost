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

  // One-line text input styled with the panel's theme (no Controls dependency).
  component SetupField: Rectangle {
    id: fieldRoot
    property alias text: input.text
    property string placeholder: ""
    property bool passwordField: false
    signal accepted()

    height: Style.space(26)
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: Util.alpha(Color.popups.text, 0.06)
    border.width: 1
    border.color: input.activeFocus ? root.brandYellow : Util.alpha(Color.popups.text, 0.25)

    TextInput {
      id: input
      anchors.fill: parent
      anchors.margins: Style.space(6)
      verticalAlignment: TextInput.AlignVCenter
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      echoMode: fieldRoot.passwordField ? TextInput.Password : TextInput.Normal
      clip: true
      onAccepted: fieldRoot.accepted()
    }

    Text {
      visible: input.text === ""
      anchors.fill: parent
      anchors.margins: Style.space(6)
      verticalAlignment: Text.AlignVCenter
      text: fieldRoot.placeholder
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

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

  property bool ipCopied: false

  Timer {
    id: copyResetTimer
    interval: 2200
    repeat: false
    onTriggered: root.ipCopied = false
  }

  Process {
    id: clipboardProcess
  }

  function copyIp() {
    var ipToCopy = cyberghost.publicIp
    if (!ipToCopy) return
    clipboardProcess.command = ["wl-copy", ipToCopy]
    clipboardProcess.running = true
    root.ipCopied = true
    copyResetTimer.restart()
  }

  onOpenedChanged: {
    if (root.opened) {
      cyberghost.refresh()
      cyberghost.recheck()
      // Force a GeoIP lookup so the exposed/VPN IP is never stale.
      cyberghost.refreshIpInfo(true)
    }
  }

  function toggleRunning() {
    cyberghost.toggle()
  }

  function connectToCountry(code) {
    cyberghost.connectTo(code, cyberghost.protocol, cyberghost.serverType, cyberghost.streamingService)
  }

  // Changing mode/protocol never tears down a live tunnel; it is stored and
  // applied on the next explicit connect.
  function setServerType(type) {
    cyberghost.setServerType(type)
    if (cyberghost.connected) {
      var labels = { "traffic": "Traffic", "torrent": "Torrent", "streaming": "Streaming" }
      cyberghost.applyHint = "Server mode set to " + (labels[type] || type) + " — reconnect to apply."
    }
  }

  function setProtocol(proto) {
    cyberghost.setProtocol(proto)
    if (cyberghost.connected) {
      var names = { "wireguard": "WireGuard", "openvpn": "OpenVPN UDP", "openvpn_tcp": "OpenVPN TCP" }
      cyberghost.applyHint = "Protocol set to " + (names[proto] || proto) + " — reconnect to apply."
    }
  }

  function refresh() {
    cyberghost.refresh()
  }

  function fmtHandshake(sec) {
    if (sec < 0) return ""
    if (sec < 90) return sec + "s"
    if (sec < 3600) return Math.round(sec / 60) + " min"
    return Math.round(sec / 3600 * 10) / 10 + " h"
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
    function connect(countryCode: string): void {
      if (countryCode && typeof countryCode === "string" && countryCode.trim() !== "") {
        root.connectToCountry(countryCode.trim().toUpperCase())
      } else {
        root.toggleRunning()
      }
    }
    function disconnect(): void {
      cyberghost.disconnect()
    }
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
      if (!cyberghost.setupDone) return "CyberGhost VPN: setup incomplete — click for steps"
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
          warning: cyberghost.tunnelStale || !cyberghost.setupDone
        }
      }
    }

    onPressed: function(buttonCode) {
      // Until setup completes, every click just opens the wizard.
      if (!cyberghost.setupDone || buttonCode === Qt.LeftButton) {
        root.toggle()
        return
      }
      if (buttonCode === Qt.MiddleButton) {
        cyberghost.toggle()
      } else if (buttonCode === Qt.RightButton) {
        // Quick toggle without opening the panel (common VPN tray pattern)
        cyberghost.toggle()
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
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight + Style.space(12))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: countryDropdown.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Static layout — no scrolling. The panel height tracks the full
      // content and is capped to the viewport by fittedContentHeight, so
      // every control must stay visible without flicking.
      Item {
        id: scroll
        anchors.fill: parent
        clip: true

        Column {
          id: mainColumn
          x: Style.space(14)
          y: Style.space(8)
          width: scroll.width - Style.space(28)
          spacing: Style.space(8)

          // -------------------------------------------------------------
          // 1. HERO HEADER
          // -------------------------------------------------------------
          Item {
            id: header
            visible: cyberghost.setupDone
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "CyberGhost VPN"
              meta: {
                if (cyberghost.connecting) return "Connecting to " + cyberghost.countryName + "…"
                if (cyberghost.disconnecting) return "Disconnecting tunnel…"
                if (cyberghost.connected && cyberghost.tunnelStale) return "Connected · handshake stale ⚠"
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
            readonly property bool isError: cyberghost.lastError !== "" || cyberghost.tunnelStale
            visible: cyberghost.setupDone && (cyberghost.lastError !== "" || cyberghost.actionStatus !== "" || cyberghost.applyHint !== "" || cyberghost.tunnelStale)
            width: parent.width
            implicitHeight: bannerText.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: statusBanner.isError ? Util.alpha(Color.urgent, 0.15) : Util.alpha(Color.accent, 0.15)
            border.width: 1
            border.color: statusBanner.isError ? Util.alpha(Color.urgent, 0.35) : Util.alpha(Color.accent, 0.35)

            Text {
              id: bannerText
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: {
                if (cyberghost.lastError !== "") return cyberghost.lastError
                if (cyberghost.actionStatus !== "") return cyberghost.actionStatus
                if (cyberghost.tunnelStale) return "Handshake stale (" + Math.round(cyberghost.handshakeAgeSec / 60) + " min) — tunnel may be down. Reconnect recommended."
                return cyberghost.applyHint
              }
              color: statusBanner.isError ? Color.urgent : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              verticalAlignment: Text.AlignVCenter
            }
          }

          // -------------------------------------------------------------
          // 3. FIRST-RUN SETUP WIZARD (only while something is missing)
          // -------------------------------------------------------------
          Rectangle {
            id: setupCard
            visible: !cyberghost.setupDone
            width: parent.width
            implicitHeight: setupColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: Util.alpha(Color.urgent, 0.05)
            border.width: 1
            border.color: Util.alpha(Color.urgent, 0.3)

            Column {
              id: setupColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              Text {
                text: "FIRST-RUN SETUP"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: Color.urgent
              }

              // -- Dependency rows with one-click install --
              Repeater {
                model: [
                  { ok: cyberghost.readyWg, label: "WireGuard tools" },
                  { ok: cyberghost.readyRequests, label: "Python requests" }
                ]

                delegate: Item {
                  required property var modelData
                  width: setupColumn.width
                  implicitHeight: Math.max(setupDot.height, depLabel.implicitHeight)

                  Row {
                    spacing: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                      id: setupDot
                      width: Style.space(7)
                      height: width
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: modelData.ok ? root.successGreen : root.urgent
                    }

                    Text {
                      id: depLabel
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.label + (modelData.ok ? "" : "  ·  missing")
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: modelData.ok ? root.successGreen : root.foreground
                    }
                  }

                  Button {
                    visible: !modelData.ok
                    enabled: !cyberghost.busy && !cyberghost.regBusy
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: cyberghost.depsBusy ? "…" : "Install"
                    bordered: true
                    foreground: root.foreground
                    tooltipText: "Installs wireguard-tools and python-requests via pacman (asks for authorization)"
                    onClicked: cyberghost.installDeps()
                  }
                }
              }
              // (dependency install state lives in Service: depsBusy)

              // -- Account linking form --
              Item {
                width: parent.width
                implicitHeight: accRow.implicitHeight
                visible: !cyberghost.readyCreds

                Column {
                  id: accRow
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: "CyberGhost account" + (cyberghost.readyCreds ? "" : "  ·  not linked")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: cyberghost.readyCreds ? root.successGreen : root.foreground
                  }

                  SetupField {
                    id: regUser
                    width: parent.width
                    placeholder: "Account username or email"
                    enabled: !cyberghost.regBusy
                  }

                  SetupField {
                    id: regPass
                    width: parent.width
                    placeholder: "Account password"
                    passwordField: true
                    enabled: !cyberghost.regBusy
                    onAccepted: cyberghost.registerAccount(regUser.text, regPass.text)
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Button {
                      enabled: regUser.text !== "" && regPass.text !== "" && !cyberghost.regBusy
                      text: cyberghost.regBusy ? "Linking…" : "Link account"
                      bordered: true
                      foreground: root.brandYellow
                      onClicked: cyberghost.registerAccount(regUser.text, regPass.text)
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: cyberghost.regBusy || cyberghost.setupMsg !== ""
                      text: cyberghost.regBusy ? "Contacting CyberGhost…" : cyberghost.setupMsg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.dim
                      elide: Text.ElideRight
                      width: Math.max(10, parent.width - x - Style.space(2))
                    }
                  }
                }
              }

              // -- Optional passwordless connect --
              Item {
                width: parent.width
                implicitHeight: polkitLabel.implicitHeight

                Text {
                  id: polkitLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - polkitBtn.width - Style.space(10)
                  text: "Optional: connect without password prompts"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                  elide: Text.ElideRight
                }

                Button {
                  id: polkitBtn
                  enabled: !cyberghost.busy && !cyberghost.regBusy
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: cyberghost.polkitBusy ? "…" : "Enable"
                  bordered: true
                  foreground: root.foreground
                  tooltipText: "Installs the bundled Polkit rule (asks for authorization once)"
                  onClicked: cyberghost.installPolkitRule()
                }
              }
            }
          }

          // -------------------------------------------------------------
          // 4. LIVE CONNECTION & IP CARD (CLICK-TO-COPY & PADDED)
          // -------------------------------------------------------------
          Rectangle {
            id: infoCard
            visible: cyberghost.setupDone
            width: parent.width
            implicitHeight: infoColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: Util.alpha(Color.popups.text, cyberghost.connected ? 0.04 : 0.02)
            border.width: 1
            border.color: cyberghost.connected ? Util.alpha(root.brandYellow, 0.4) : Color.popups.border

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

                // Protocol pill
                Rectangle {
                  id: protoPill
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: protoText.implicitWidth + Style.space(14)
                  implicitHeight: protoText.implicitHeight + Style.space(6)
                  radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                  color: cyberghost.connected ? Util.alpha(root.successGreen, 0.15) : Util.alpha(Color.popups.text, 0.12)
                  border.width: 1
                  border.color: cyberghost.connected ? Util.alpha(root.successGreen, 0.4) : Util.alpha(Color.popups.text, 0.25)

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

              // Connection details: IP / Location / Provider (click to copy IP)
              Item {
                width: parent.width
                implicitHeight: detailGrid.implicitHeight

                Grid {
                  id: detailGrid
                  anchors.left: parent.left
                  anchors.right: parent.right
                  columns: 2
                  columnSpacing: Style.space(8)
                  rowSpacing: Style.space(5)

                  // Labels share the widest label's width so values align
                  Text {
                    width: lblProvider.implicitWidth
                    text: "IP:"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  Text {
                    text: cyberghost.publicIp !== "" ? cyberghost.publicIp : (cyberghost.fetchingIp ? "Checking…" : "Unavailable")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: root.foreground
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, detailGrid.width - lblProvider.implicitWidth - detailGrid.columnSpacing)
                  }

                  Text {
                    width: lblProvider.implicitWidth
                    text: "Location:"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  Text {
                    text: {
                      var parts = []
                      if (cyberghost.publicCity) parts.push(cyberghost.publicCity)
                      if (cyberghost.publicCountry) parts.push(Countries.countryName(cyberghost.publicCountry) + " " + Countries.countryFlag(cyberghost.publicCountry))
                      else if (cyberghost.countryName) parts.push(cyberghost.countryName + " " + cyberghost.countryFlag)
                      return parts.join(", ") || "Unknown"
                    }
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    elide: Text.ElideRight
                    width: detailGrid.width - lblProvider.implicitWidth - detailGrid.columnSpacing
                  }

                  Text {
                    id: lblProvider
                    text: "Provider:"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  Text {
                    text: cyberghost.publicOrg !== "" ? cyberghost.publicOrg : "Unknown"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    elide: Text.ElideRight
                    width: detailGrid.width - lblProvider.implicitWidth - detailGrid.columnSpacing
                  }

                  Text {
                    text: "Session:"
                    visible: sessionText.visible
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  Text {
                    id: sessionText
                    visible: cyberghost.connected && (cyberghost.transferText !== "" || cyberghost.endpoint !== "")
                    text: {
                      var parts = []
                      if (cyberghost.transferText !== "") parts.push(cyberghost.transferText)
                      if (cyberghost.handshakeAgeSec >= 0) parts.push("handshake " + root.fmtHandshake(cyberghost.handshakeAgeSec))
                      if (cyberghost.endpoint !== "") parts.push(cyberghost.endpoint)
                      return parts.join(" · ")
                    }
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    elide: Text.ElideRight
                    width: detailGrid.width - lblProvider.implicitWidth - detailGrid.columnSpacing
                  }
                }

                // Copy affordance / copied feedback (top-right corner)
                Item {
                  anchors.right: parent.right
                  anchors.top: parent.top
                  width: Math.max(copyGlyph.width, copiedLabel.implicitWidth)
                  height: Math.max(copyGlyph.height, copiedLabel.implicitHeight)

                  // Vector copy icon (two stacked sheets) — no icon-font dependency
                  Item {
                    id: copyGlyph
                    visible: !root.ipCopied
                    width: Style.space(10)
                    height: width
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                      x: parent.width * 0.3
                      y: 0
                      width: parent.width * 0.6
                      height: parent.height * 0.75
                      radius: 1
                      color: "transparent"
                      border.color: root.dim
                      border.width: 1
                    }

                    Rectangle {
                      x: 0
                      y: parent.height * 0.25
                      width: parent.width * 0.6
                      height: parent.height * 0.75
                      radius: 1
                      color: Color.popups.background
                      border.color: root.dim
                      border.width: 1
                    }
                  }

                  Text {
                    id: copiedLabel
                    visible: root.ipCopied
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✓ Copied!"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: root.successGreen
                  }
                }

                MouseArea {
                  id: ipMouseArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.copyIp()
                }

                PanelToolTip {
                  visible: ipMouseArea.containsMouse && cyberghost.publicIp !== ""
                  text: root.ipCopied ? "Copied to clipboard!" : "Click to copy public IP"
                  fontFamily: root.fontFamily
                }
              }

            }
          }

          Column {
            id: mainControls
            visible: cyberghost.setupDone
            width: parent.width
            spacing: Style.space(10)

          PanelSeparator {
            foreground: root.foreground
          }

          // -------------------------------------------------------------
          // 5. POPULAR LOCATIONS (2x6 UNIFORM GRID)
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
                enabled: !cyberghost.busy

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
          // 6. ALL LOCATIONS DROPDOWN
          // -------------------------------------------------------------
          PanelSectionHeader {
            text: "ALL LOCATIONS (100+)"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          SearchableDropdown {
            id: countryDropdown
            width: parent.width
            enabled: !cyberghost.busy
            label: "Search country"
            placeholderText: "Search 100+ countries…"
            value: cyberghost.country
            options: root.dropdownOptionsList
            foreground: root.foreground
            fontFamily: root.fontFamily
            // Selecting a country only updates the target; use quick-connect
            // tiles, the power switch or Connect to actually dial.
            onChanged: function(val) {
              cyberghost.setCountry(val)
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // -------------------------------------------------------------
          // 7. CONNECTION PREFERENCES (server mode + protocol)
          // -------------------------------------------------------------
          PanelSectionHeader {
            text: "CONNECTION PREFERENCES"
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
              enabled: !cyberghost.busy
              text: "⚡ Traffic"
              selected: cyberghost.serverType === "traffic"
              bordered: true
              foreground: root.foreground
              tooltipText: "Fastest standard routing for web browsing"
              onClicked: root.setServerType("traffic")
            }

            Button {
              width: modeRow.cellW
              enabled: !cyberghost.busy
              text: "🔒 Torrent"
              selected: cyberghost.serverType === "torrent"
              bordered: true
              foreground: root.foreground
              tooltipText: "Servers optimized for P2P and torrenting"
              onClicked: root.setServerType("torrent")
            }

            Button {
              width: modeRow.cellW
              enabled: !cyberghost.busy
              text: "🎬 Streaming"
              selected: cyberghost.serverType === "streaming"
              bordered: true
              foreground: root.foreground
              tooltipText: "Servers optimized for streaming media"
              onClicked: root.setServerType("streaming")
            }
          }

          // -------------------------------------------------------------
          // 8. PROTOCOL SELECTOR (applies on next connect)
          // -------------------------------------------------------------
          Row {
            id: protoRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellW: Math.floor((width - spacing * 2) / 3)

            Button {
              width: protoRow.cellW
              enabled: !cyberghost.busy
              text: "WireGuard"
              selected: cyberghost.protocol === "wireguard"
              bordered: true
              foreground: root.foreground
              tooltipText: "WireGuard protocol (Fastest and modern)"
              onClicked: root.setProtocol("wireguard")
            }

            Button {
              width: protoRow.cellW
              enabled: !cyberghost.busy
              text: "OpenVPN UDP"
              selected: cyberghost.protocol === "openvpn"
              bordered: true
              foreground: root.foreground
              tooltipText: "OpenVPN over UDP"
              onClicked: root.setProtocol("openvpn")
            }

            Button {
              width: protoRow.cellW
              enabled: !cyberghost.busy
              text: "OpenVPN TCP"
              selected: cyberghost.protocol === "openvpn_tcp"
              bordered: true
              foreground: root.foreground
              tooltipText: "OpenVPN over TCP"
              onClicked: root.setProtocol("openvpn_tcp")
            }
          }

          // -------------------------------------------------------------
          // 9. ACTIONS ROW
          // -------------------------------------------------------------
          Row {
            id: actionsRow
            width: parent.width
            spacing: Style.space(8)
            readonly property real cellW: Math.floor((width - spacing) / 2)

            Button {
              width: actionsRow.cellW
              enabled: !cyberghost.busy
              text: "󰑐 Refresh Status"
              bordered: true
              foreground: root.foreground
              tooltipText: "Check VPN status and reload IP information"
              onClicked: root.refresh()
            }

            Button {
              width: actionsRow.cellW
              enabled: !cyberghost.busy
              text: cyberghost.active ? "󰅖 Disconnect" : "󰄬 Connect"
              selected: cyberghost.active
              bordered: true
              foreground: cyberghost.active ? Color.urgent : root.brandYellow
              tooltipText: cyberghost.active ? "Stop VPN connection" : "Start VPN connection"
              onClicked: root.toggleRunning()
            }
          }

          } // end mainControls
        }
      }
    }
  }
}
