import QtQuick
import QtQuick.Controls as QQC
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

  // Labeled text input styled with the panel's theme (no Controls dependency).
  component SetupField: Rectangle {
    id: fieldRoot
    property alias text: input.text
    property string label: ""
    property string placeholder: ""
    property bool passwordField: false
    signal accepted

    implicitHeight: (fieldLabel.visible ? fieldLabel.implicitHeight + Style.space(4) : 0) + Style.space(30)
    height: implicitHeight
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: Util.alpha(Color.popups.text, 0.06)
    border.width: 1
    border.color: input.activeFocus ? root.brandYellow : Util.alpha(Color.popups.text, 0.25)

    Text {
      id: fieldLabel
      visible: fieldRoot.label !== ""
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      text: fieldRoot.label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    TextInput {
      id: input
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.top: fieldLabel.visible ? fieldLabel.bottom : parent.top
      anchors.topMargin: fieldLabel.visible ? Style.space(4) : 0
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      verticalAlignment: TextInput.AlignVCenter
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      echoMode: fieldRoot.passwordField ? TextInput.Password : TextInput.Normal
      clip: true
      activeFocusOnTab: true
      Accessible.name: fieldRoot.label || fieldRoot.placeholder
      onAccepted: fieldRoot.accepted()
    }

    Text {
      visible: input.text === ""
      textFormat: Text.PlainText
      anchors.left: input.left
      anchors.right: input.right
      anchors.top: input.top
      anchors.bottom: input.bottom
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
  readonly property color dim: Qt.darker(foreground, 1.25)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color brandYellow: "#FFCE00"
  readonly property color successGreen: "#10B981"
  readonly property bool reduceMotion: !!setting("reduceMotion", false)

  readonly property var popularList: Countries.popularCountries
  readonly property var dropdownOptionsList: Countries.dropdownOptions()

  property bool ipCopied: false

  Timer {
    id: copyResetTimer
    interval: 2200
    repeat: false
    onTriggered: root.ipCopied = false
  }

  Timer {
    id: copyTimeoutTimer
    interval: 3000
    repeat: false
    onTriggered: {
      if (clipboardProcess.running) {
        clipboardProcess.running = false
        root.ipCopied = false
        cyberghost.lastError = "Clipboard copy timed out."
      }
    }
  }

  Timer {
    id: applyHintTimer
    interval: 10000
    repeat: false
    onTriggered: cyberghost.applyHint = ""
  }

  Process {
    id: clipboardProcess
    onExited: function (exitCode) {
      copyTimeoutTimer.stop()
      if (exitCode !== 0) {
        root.ipCopied = false
        cyberghost.lastError = "Could not copy the public IP to the clipboard."
      }
    }
  }

  function copyIp() {
    if (cyberghost.hideDetails)
      return
    var ipToCopy = cyberghost.publicIp
    if (!ipToCopy || clipboardProcess.running)
      return
    clipboardProcess.command = ["/usr/bin/wl-copy", ipToCopy]
    clipboardProcess.running = true
    copyTimeoutTimer.restart()
    root.ipCopied = true
    copyResetTimer.restart()
  }

  onOpenedChanged: {
    if (root.opened) {
      // Recheck's completion handler refreshes status; avoiding a second
      // immediate poll keeps opening the panel cheap.
      cyberghost.recheck()
      cyberghost.refreshServers()
      // Force a GeoIP lookup so the exposed/VPN IP is never stale.
      cyberghost.refreshIpInfo(true)
    }
  }

  function toggleRunning() {
    cyberghost.toggle()
  }

  function connectToCountry(code, serverChoice) {
    cyberghost.connectTo(code, cyberghost.protocol, cyberghost.serverType, cyberghost.streamingService, serverChoice)
  }

  // Changing mode/protocol never tears down a live tunnel; it is stored and
  // applied on the next explicit connect.
  function setServerType(type) {
    cyberghost.setServerType(type)
    if (cyberghost.connected) {
      var labels = {
        "traffic": "Traffic",
        "torrent": "Torrent",
        "streaming": "Streaming"
      }
      cyberghost.applyHint = "Server mode set to " + (labels[type] || type) + " — reconnect to apply."
      applyHintTimer.restart()
    }
  }

  function setProtocol(proto) {
    cyberghost.setProtocol(proto)
    if (cyberghost.connected) {
      var names = {
        "wireguard": "WireGuard",
        "openvpn": "OpenVPN UDP",
        "openvpn_tcp": "OpenVPN TCP"
      }
      cyberghost.applyHint = "Protocol set to " + (names[proto] || proto) + " — reconnect to apply."
      applyHintTimer.restart()
    }
  }

  function refresh() {
    cyberghost.refresh()
  }

  function submitAccountForm() {
    var username = regUser.text
    var password = regPass.text
    if (username.length > 256 || password.length > 256) {
      cyberghost.setupMsg = "Username and password must be 256 characters or fewer."
      return
    }
    cyberghost.registerAccount(username, password)
    regPass.text = ""
  }

  function firstMissingDependencyTarget() {
    for (var i = 0; i < dependencyRepeater.count; i++) {
      var item = dependencyRepeater.itemAt(i)
      if (item && item.keyboardTarget && item.keyboardTarget.visible)
        return item.keyboardTarget
    }
    return polkitBtn
  }

  function fmtHandshake(sec) {
    if (sec < 0)
      return ""
    if (sec < 90)
      return sec + "s"
    if (sec < 3600)
      return Math.round(sec / 60) + " min"
    return Math.round(sec / 3600 * 10) / 10 + " h"
  }

  Service {
    id: cyberghost
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void {
      root.open()
    }
    function close(): void {
      root.close()
    }
    function show(): void {
      root.open()
    }
    function hide(): void {
      root.close()
    }
    function toggle(): void {
      root.toggle()
    }
    function refresh(): void {
      root.refresh()
    }
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
    Accessible.name: tooltipText
    tooltipText: {
      if (!cyberghost.setupDone)
        return "CyberGhost VPN: setup incomplete — click for steps"
      if (cyberghost.connecting)
        return "CyberGhost VPN: Connecting to " + cyberghost.countryName + " (" + cyberghost.country + ")…"
      if (cyberghost.disconnecting)
        return "CyberGhost VPN: Disconnecting…"
      if (cyberghost.connected) {
        var ipPart = (!cyberghost.hideDetails && cyberghost.publicIp !== "") ? (" • " + cyberghost.publicIp) : ""
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
          reducedMotion: root.reduceMotion
          warning: cyberghost.tunnelStale || !cyberghost.setupDone
        }
      }
    }

    onPressed: function (buttonCode) {
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
    visible: cyberghost.connecting || cyberghost.disconnecting
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    anchors.margins: Math.max(1, Math.round(Style.space(1)))
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.brandYellow

    SequentialAnimation on opacity {
      running: (cyberghost.connecting || cyberghost.disconnecting) && !root.reduceMotion
      loops: Animation.Infinite
      NumberAnimation {
        to: 0.25
        duration: 500
        easing.type: Easing.InOutSine
      }
      NumberAnimation {
        to: 1.0
        duration: 500
        easing.type: Easing.InOutSine
      }
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
    focusTarget: cyberghost.setupDone ? (cyberghost.readyPolkit ? refreshStatusButton : polkitBtn) : (!cyberghost.readyCreds ? regUser : ((!cyberghost.readyWg || !cyberghost.readyRequests) && dependencyRepeater.count > 0 ? root.firstMissingDependencyTarget() : polkitBtn))
    // Keep the same sizing contract as the official Omarchy panels: the
    // KeyboardPanel owns the popup padding, while the content column fills
    // the available inner width without a second manual inset.
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      anchors.fill: parent
      focus: false
      blocked: true
      onCloseRequested: root.close()

      Flickable {
        id: scroll
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
          if (countryDropdown.popupOpen || serverDropdown.popupOpen || streamingDropdown.popupOpen)
            return
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          }
        }

        Column {
          id: mainColumn
          width: scroll.width
          spacing: Style.space(8)

          // -------------------------------------------------------------
          // 1. HERO HEADER
          // -------------------------------------------------------------
          Item {
            visible: cyberghost.setupDone
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "CyberGhost VPN"
              meta: {
                if (cyberghost.connecting)
                  return "Connecting to " + cyberghost.countryName + "…"
                if (cyberghost.disconnecting)
                  return "Disconnecting tunnel…"
                if (cyberghost.connected && cyberghost.tunnelStale)
                  return "Connected · handshake stale ⚠"
                if (cyberghost.connected) {
                  return "Connected · " + cyberghost.countryName + " " + cyberghost.countryFlag
                }
                return "Disconnected · Unencrypted"
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
                  reducedMotion: root.reduceMotion
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: cyberghost.active
                  busy: cyberghost.busy
                  foreground: hero.foreground
                  accent: root.brandYellow
                  activeFocusOnTab: true
                  Accessible.name: cyberghost.active ? "Disconnect VPN" : "Connect to CyberGhost"
                  Keys.onReturnPressed: if (!cyberghost.busy)
                    root.toggleRunning()
                  Keys.onEnterPressed: if (!cyberghost.busy)
                    root.toggleRunning()
                  Keys.onSpacePressed: if (!cyberghost.busy)
                    root.toggleRunning()
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
              textFormat: Text.PlainText
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: {
                if (cyberghost.lastError !== "")
                  return cyberghost.lastError
                if (cyberghost.actionStatus !== "")
                  return cyberghost.actionStatus
                if (cyberghost.tunnelStale)
                  return "Handshake stale (" + Math.round(cyberghost.handshakeAgeSec / 60) + " min) — tunnel may be down. Reconnect recommended."
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
            visible: !cyberghost.setupDone || !cyberghost.readyPolkit
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
                text: cyberghost.setupDone ? "OPTIONAL SETUP" : "FIRST-RUN SETUP"
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: Color.urgent
              }

              Text {
                visible: cyberghost.setupMsg !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: cyberghost.setupMsg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
                wrapMode: Text.WordWrap
              }

              // -- Dependency rows with one-click install --
              Repeater {
                id: dependencyRepeater
                model: [
                  {
                    ok: cyberghost.readyWg,
                    label: "WireGuard tools"
                  },
                  {
                    ok: cyberghost.readyRequests,
                    label: "Python requests"
                  }
                ]

                delegate: Item {
                  required property var modelData
                  readonly property Item keyboardTarget: dependencyButton
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
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.label + (modelData.ok ? "" : "  ·  missing")
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: modelData.ok ? root.successGreen : root.foreground
                    }
                  }

                  Button {
                    id: dependencyButton
                    visible: !modelData.ok
                    enabled: !cyberghost.busy && !cyberghost.regBusy
                    focusable: true
                    Accessible.name: "Install " + modelData.label
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
                    textFormat: Text.PlainText
                    text: "CyberGhost account" + (cyberghost.readyCreds ? "" : "  ·  not linked")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: cyberghost.readyCreds ? root.successGreen : root.foreground
                  }

                  SetupField {
                    id: regUser
                    width: parent.width
                    label: "CyberGhost username or email"
                    placeholder: "name@example.com"
                    enabled: !cyberghost.regBusy
                  }

                  SetupField {
                    id: regPass
                    width: parent.width
                    label: "CyberGhost password"
                    placeholder: "Enter your password"
                    passwordField: true
                    enabled: !cyberghost.regBusy
                    onAccepted: root.submitAccountForm()
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Button {
                      focusable: true
                      Accessible.name: cyberghost.regBusy ? "Linking CyberGhost account" : "Link CyberGhost account"
                      enabled: regUser.text !== "" && regPass.text !== "" && !cyberghost.regBusy
                      text: cyberghost.regBusy ? "Linking…" : "Link account"
                      bordered: true
                      foreground: root.brandYellow
                      onClicked: root.submitAccountForm()
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      visible: cyberghost.regBusy
                      text: "Contacting CyberGhost…"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.dim
                      wrapMode: Text.WordWrap
                      width: Math.max(10, parent.width - x - Style.space(2))
                    }
                  }
                }
              }

              // -- Required root helper; optional passwordless rule --
              Item {
                width: parent.width
                implicitHeight: polkitLabel.implicitHeight

                Text {
                  id: polkitLabel
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - (polkitBtn.visible ? polkitBtn.width + Style.space(10) : 0)
                  text: cyberghost.readyCreds && cyberghost.polkitStatus !== "" ? cyberghost.polkitStatus : (cyberghost.readyPolkit ? "Passwordless connect enabled" : (cyberghost.helperInstalled ? "Optional: enable passwordless connect" : (cyberghost.helperVersion !== "" && cyberghost.pluginVersion !== "" && cyberghost.helperVersion !== cyberghost.pluginVersion ? "Required: update root helper (installed v" + cyberghost.helperVersion + ", current v" + cyberghost.pluginVersion + ")" : "Required: install the root helper")))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: cyberghost.readyCreds && cyberghost.polkitStatus !== "" && !cyberghost.readyPolkit ? root.urgent : (cyberghost.readyPolkit ? root.successGreen : root.foreground)
                  wrapMode: Text.WordWrap
                }

                Button {
                  id: polkitBtn
                  visible: !cyberghost.readyPolkit
                  enabled: !cyberghost.busy && !cyberghost.regBusy
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  focusable: true
                  Accessible.name: "Open the secure helper installer in a terminal"
                  text: cyberghost.polkitBusy ? "…" : "Open installer"
                  bordered: true
                  foreground: root.foreground
                  tooltipText: "Open a terminal and run the sudo installer, then recheck setup"
                  onClicked: cyberghost.openHelperInstaller()
                }
              }

              Button {
                visible: true
                enabled: !cyberghost.busy && !cyberghost.regBusy
                focusable: true
                Accessible.name: "Recheck CyberGhost setup"
                text: "Recheck setup"
                bordered: true
                foreground: root.foreground
                tooltipText: "Check dependencies, account, helper and optional Polkit setup again"
                onClicked: cyberghost.recheck()
              }
            }
          }

          // -------------------------------------------------------------
          // 4. LIVE CONNECTION & IP CARD (CLICK-TO-COPY)
          // -------------------------------------------------------------
          Rectangle {
            visible: cyberghost.setupDone
            width: parent.width
            implicitHeight: infoColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: Util.alpha(Color.popups.text, cyberghost.connected ? 0.04 : 0.02)
            border.width: 1
            // The outer KeyboardPanel already provides the strong surface
            // boundary. Keep this status surface quiet unless the VPN is
            // connected, following the official panels' separator-first UI.
            border.color: cyberghost.connected ? Util.alpha(root.brandYellow, 0.4) : Util.alpha(root.foreground, 0.18)

            Column {
              id: infoColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              // Status badge line + Protocol pill + privacy toggle
              Item {
                width: parent.width
                implicitHeight: statusBadgeGrid.implicitHeight

                Grid {
                  id: statusBadgeGrid
                  width: parent.width
                  columns: width < Style.space(300) ? 1 : 3
                  columnSpacing: Style.space(8)
                  rowSpacing: Style.space(6)
                  readonly property real cellW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

                  Row {
                    id: statusBadgeRow
                    width: statusBadgeGrid.cellW
                    spacing: Style.space(6)

                    Rectangle {
                      width: Style.space(8)
                      height: width
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: cyberghost.connected ? root.successGreen : (cyberghost.connecting ? root.brandYellow : root.urgent)
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      width: statusBadgeRow.width - Style.space(14)
                      // Keep the badge short enough for the three-column layout;
                      // the hero and detail card carry the full connection context.
                      text: cyberghost.connected ? "PROTECTED" : (cyberghost.connecting ? "CONNECTING…" : "IP EXPOSED")
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      wrapMode: Text.WordWrap
                      color: cyberghost.connected ? root.successGreen : (cyberghost.connecting ? root.brandYellow : root.dim)
                    }
                  }

                  // Protocol pill
                  Rectangle {
                    width: statusBadgeGrid.cellW
                    implicitWidth: protoText.implicitWidth + Style.space(14)
                    implicitHeight: protoText.implicitHeight + Style.space(6)
                    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                    color: cyberghost.connected ? Util.alpha(root.successGreen, 0.15) : Util.alpha(Color.popups.text, 0.12)
                    border.width: 1
                    border.color: cyberghost.connected ? Util.alpha(root.successGreen, 0.4) : Util.alpha(Color.popups.text, 0.25)

                    Text {
                      id: protoText
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: cyberghost.protocol === "wireguard" ? "WireGuard" : "OpenVPN"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      color: cyberghost.connected ? root.successGreen : root.dim
                    }
                  }

                  // Privacy toggle — masks IP / location / provider / session
                  Button {
                    width: statusBadgeGrid.cellW
                    iconText: cyberghost.hideDetails ? "\uf070" : "\uf06e"
                    text: cyberghost.hideDetails ? "Show" : "Hide"
                    bordered: true
                    foreground: root.foreground
                    focusable: true
                    Accessible.name: cyberghost.hideDetails ? "Show connection details" : "Hide connection details"
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(2)
                    iconSize: Style.font.caption
                    fontSize: Style.font.caption
                    tooltipText: cyberghost.hideDetails ? "Reveal IP & connection details" : "Hide IP & connection details"
                    onClicked: cyberghost.setHideDetails(!cyberghost.hideDetails)
                  }
                }
              }

              // Divider
              PanelSeparator {
                foreground: root.foreground
              }

              // Connection details: IP / Location / Provider (click to copy IP)
              Item {
                width: parent.width
                implicitHeight: detailGrid.implicitHeight + copyRow.implicitHeight + geoMismatchText.implicitHeight + Style.space(12)

                Grid {
                  id: detailGrid
                  anchors.left: parent.left
                  anchors.right: parent.right
                  columns: 2
                  columnSpacing: Style.space(8)
                  rowSpacing: Style.space(5)

                  // Labels share the widest label's width so values align
                  Text {
                    textFormat: Text.PlainText
                    width: lblProvider.implicitWidth
                    text: "IP:"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: cyberghost.hideDetails ? "•••.•••.•••.•••" : (cyberghost.publicIp !== "" ? cyberghost.publicIp : (cyberghost.fetchingIp ? "Checking…" : "Unavailable"))
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: root.foreground
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, detailGrid.width - lblProvider.implicitWidth - detailGrid.columnSpacing)
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: lblProvider.implicitWidth
                    text: "Location:"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: {
                      if (cyberghost.hideDetails)
                        return "Hidden"
                      var parts = []
                      if (cyberghost.publicCity)
                        parts.push(cyberghost.publicCity)
                      if (cyberghost.publicCountry)
                        parts.push(Countries.countryName(cyberghost.publicCountry) + " " + Countries.countryFlag(cyberghost.publicCountry))
                      else if (cyberghost.countryName)
                        parts.push(cyberghost.countryName + " " + cyberghost.countryFlag)
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
                    textFormat: Text.PlainText
                    text: "Provider:"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: cyberghost.hideDetails ? "Hidden" : (cyberghost.publicOrg !== "" ? cyberghost.publicOrg : "Unknown")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    elide: Text.ElideRight
                    width: detailGrid.width - lblProvider.implicitWidth - detailGrid.columnSpacing
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Session:"
                    visible: sessionText.visible
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  Text {
                    id: sessionText
                    textFormat: Text.PlainText
                    visible: cyberghost.connected && (cyberghost.transferText !== "" || cyberghost.endpoint !== "")
                    text: {
                      if (cyberghost.hideDetails)
                        return "Hidden"
                      var parts = []
                      if (cyberghost.transferText !== "")
                        parts.push(cyberghost.transferText)
                      if (cyberghost.handshakeAgeSec >= 0)
                        parts.push("handshake " + root.fmtHandshake(cyberghost.handshakeAgeSec))
                      if (cyberghost.endpoint !== "")
                        parts.push(cyberghost.endpoint)
                      return parts.join(" · ")
                    }
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    elide: Text.ElideRight
                    width: detailGrid.width - lblProvider.implicitWidth - detailGrid.columnSpacing
                  }
                }

                Row {
                  id: copyRow
                  width: parent.width
                  y: detailGrid.implicitHeight + Style.space(6)
                  spacing: Style.space(8)

                  Button {
                    focusable: true
                    enabled: !cyberghost.hideDetails && cyberghost.publicIp !== ""
                    iconText: "\uf0c5"
                    text: root.ipCopied ? "Copied" : "Copy IP"
                    bordered: true
                    foreground: root.foreground
                    Accessible.name: root.ipCopied ? "Public IP copied" : "Copy public IP"
                    tooltipText: "Copy the public IP to the clipboard"
                    onClicked: root.copyIp()
                  }

                  Text {
                    visible: root.ipCopied
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "Public IP copied"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: root.successGreen
                  }
                }

                Text {
                  id: geoMismatchText
                  visible: cyberghost.connected && cyberghost.publicCountry !== "" && cyberghost.publicCountry !== cyberghost.country
                  width: parent.width
                  textFormat: Text.PlainText
                  text: visible ? "IP geolocation: " + Countries.countryName(cyberghost.publicCountry) + " · target: " + cyberghost.countryName + " (" + cyberghost.country + ")" : ""
                  color: root.brandYellow
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
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
            // 5. POPULAR LOCATIONS (COMPACT UNIFORM GRID)
            // -------------------------------------------------------------
            PanelSectionHeader {
              text: "POPULAR LOCATIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Grid {
              id: popularGrid
              width: parent.width
              // Four short code tiles fit comfortably at the official 380px
              // panel width, matching the horizontal choice rows used by the
              // network and power panels. Fall back to three on narrow layouts.
              columns: width < Style.space(300) ? 3 : 4
              columnSpacing: Style.space(6)
              rowSpacing: Style.space(6)
              readonly property real cellW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

              Repeater {
                model: root.popularList

                delegate: Button {
                  required property var modelData
                  required property int index
                  width: popularGrid.cellW
                  enabled: !cyberghost.busy
                  focusable: true
                  Accessible.name: "Connect to " + modelData.name

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
            // 6. COUNTRY SELECTION (the long list stays inside the popup)
            // -------------------------------------------------------------
            PanelSectionHeader {
              text: "COUNTRY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SearchableDropdown {
              id: countryDropdown
              width: parent.width
              enabled: !cyberghost.busy
              label: "Search country"
              placeholderText: "Search 90+ countries…"
              Accessible.name: "Search country"
              value: cyberghost.country
              options: root.dropdownOptionsList
              foreground: root.foreground
              fontFamily: root.fontFamily
              // Selecting a country only updates the target; use quick-connect
              // tiles, the power switch or Connect to actually dial.
              onChanged: function (val) {
                cyberghost.setCountry(val)
              }
            }

            // -------------------------------------------------------------
            // 7. SERVER SELECTION (fastest by live load or exact instance)
            // -------------------------------------------------------------
            Item {
              visible: cyberghost.protocol === "wireguard" && cyberghost.serverType === "traffic"
              width: parent.width
              implicitHeight: serverSelectionColumn.implicitHeight

              Column {
                id: serverSelectionColumn
                width: parent.width
                spacing: Style.space(5)

                PanelSectionHeader {
                  text: "SERVER SELECTION"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                SearchableDropdown {
                  id: serverDropdown
                  width: parent.width
                  enabled: !cyberghost.busy
                  label: "Server"
                  placeholderText: "Fastest in this country or choose manually…"
                  Accessible.name: "Choose VPN server"
                  value: cyberghost.serverSelection
                  options: cyberghost.serverOptions
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onChanged: function (val) {
                    cyberghost.setServerSelection(val)
                  }
                }

                Text {
                  visible: cyberghost.loadingServers || cyberghost.serverError !== ""
                  textFormat: Text.PlainText
                  text: cyberghost.loadingServers ? "Loading live server list…" : cyberghost.serverError
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width
                }
              }
            }

            PanelSeparator {
              foreground: root.foreground
            }

            // -------------------------------------------------------------
            // 8. CONNECTION PREFERENCES (server mode + protocol)
            // -------------------------------------------------------------
            PanelSectionHeader {
              text: "CONNECTION PREFERENCES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Grid {
              id: modeRow
              width: parent.width
              columns: width < Style.space(300) ? 1 : 3
              columnSpacing: Style.space(6)
              rowSpacing: Style.space(6)
              readonly property real cellW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

              Button {
                width: modeRow.cellW
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: "Use Traffic servers"
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
                focusable: true
                Accessible.name: "Use Torrent servers"
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
                focusable: true
                Accessible.name: "Use Streaming servers"
                text: "🎬 Streaming"
                selected: cyberghost.serverType === "streaming"
                bordered: true
                foreground: root.foreground
                tooltipText: "Servers optimized for streaming media"
                onClicked: root.setServerType("streaming")
              }
            }

            Item {
              visible: cyberghost.serverType === "streaming"
              width: parent.width
              implicitHeight: streamingColumn.implicitHeight

              Column {
                id: streamingColumn
                width: parent.width
                spacing: Style.space(5)

                SearchableDropdown {
                  id: streamingDropdown
                  width: parent.width
                  label: "Streaming service"
                  Accessible.name: "Choose streaming service"
                  placeholderText: "Choose a service for this country…"
                  emptyText: "No streaming services"
                  options: cyberghost.streamingOptions
                  value: cyberghost.streamingService
                  enabled: !cyberghost.busy && cyberghost.streamingOptions.length > 0
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onChanged: function (val) {
                    cyberghost.setStreamingService(val)
                  }
                }

                Text {
                  visible: cyberghost.streamingBusy || cyberghost.streamingError !== ""
                  textFormat: Text.PlainText
                  text: cyberghost.streamingBusy ? "Loading streaming services…" : cyberghost.streamingError
                  color: cyberghost.streamingError !== "" ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width
                }
              }
            }

            // -------------------------------------------------------------
            // 9. PROTOCOL SELECTOR (applies on next connect)
            // -------------------------------------------------------------
            Grid {
              id: protoRow
              width: parent.width
              columns: width < Style.space(300) ? 1 : 3
              columnSpacing: Style.space(6)
              rowSpacing: Style.space(6)
              readonly property real cellW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

              Button {
                width: protoRow.cellW
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: "Use WireGuard protocol"
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
                focusable: true
                Accessible.name: "Use OpenVPN UDP protocol"
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
                focusable: true
                Accessible.name: "Use OpenVPN TCP protocol"
                text: "OpenVPN TCP"
                selected: cyberghost.protocol === "openvpn_tcp"
                bordered: true
                foreground: root.foreground
                tooltipText: "OpenVPN over TCP"
                onClicked: root.setProtocol("openvpn_tcp")
              }
            }

            // -------------------------------------------------------------
            // 10. ACTIONS ROW
            // -------------------------------------------------------------
            Grid {
              id: actionsRow
              width: parent.width
              columns: width < Style.space(300) ? 1 : 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)
              readonly property real cellW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

              Button {
                id: refreshStatusButton
                width: actionsRow.cellW
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: "Refresh VPN status"
                iconText: "\uf021"
                text: "Refresh Status"
                bordered: true
                foreground: root.foreground
                tooltipText: "Check VPN status and reload IP information"
                onClicked: root.refresh()
              }

              Button {
                width: actionsRow.cellW
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: cyberghost.active ? "Disconnect VPN" : "Connect VPN"
                iconText: cyberghost.active ? "\uf00d" : "\uf00c"
                text: cyberghost.active ? "Disconnect" : "Connect"
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
