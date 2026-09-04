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

  // Power button: a circular, semantic power control for the hero card.
  // Uses the ⏻ glyph (U+23FB) so it reads as "power" at a glance regardless
  // of the bar's icon font. Active = brand yellow on a translucent yellow
  // disc; inactive = dim glyph on a subtle outline.
  component PowerButton: Item {
    id: powerRoot
    property bool checked: false
    property bool busy: false
    property color accent: "#FFCE00"
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    // Expose the inner hover state so external PanelToolTip can attach.
    property alias containsMouse: hover.containsMouse
    signal toggled

    implicitWidth: Style.space(36)
    implicitHeight: Style.space(36)
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Keys.onReturnPressed: if (!powerRoot.busy)
      powerRoot.toggled()
    Keys.onEnterPressed: if (!powerRoot.busy)
      powerRoot.toggled()
    Keys.onSpacePressed: if (!powerRoot.busy)
      powerRoot.toggled()

    Rectangle {
      id: powerDisc
      anchors.fill: parent
      radius: Math.min(width, height) / 2
      color: powerRoot.checked
        ? Util.alpha(powerRoot.accent, 0.18)
        : (hover.containsMouse || powerRoot.activeFocus ? Util.alpha(powerRoot.foreground, 0.08) : "transparent")
      border.width: 1
      border.color: powerRoot.activeFocus
        ? powerRoot.accent
        : (powerRoot.checked
          ? Util.alpha(powerRoot.accent, 0.55)
          : Util.alpha(powerRoot.foreground, 0.22))

      Behavior on color  { ColorAnimation { duration: 120 } }
      Behavior on border.color { ColorAnimation { duration: 120 } }

      Text {
        anchors.centerIn: parent
        text: "\u23FB"   // ⏻ power symbol
        textFormat: Text.PlainText
        color: powerRoot.checked ? powerRoot.accent : powerRoot.foreground
        opacity: powerRoot.busy ? 0.5 : (powerRoot.checked ? 1.0 : 0.78)
        font.family: powerRoot.fontFamily
        font.pixelSize: Math.round(powerRoot.height * 0.5)
        font.bold: true

        Behavior on color    { ColorAnimation { duration: 120 } }
        Behavior on opacity  { NumberAnimation { duration: 120 } }
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: powerRoot.busy ? Qt.ForbiddenCursor : Qt.PointingHandCursor
        enabled: !powerRoot.busy
        onClicked: powerRoot.toggled()
      }
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
    return openInstallerBtn
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
      // Left-click always opens or closes the panel (even before setup, so
      // the user can reach the wizard). Middle and right click silently
      // toggle the VPN without showing the panel — the documented behaviour.
      if (buttonCode === Qt.LeftButton) {
        root.toggle()
        return
      }
      if (buttonCode === Qt.MiddleButton || buttonCode === Qt.RightButton) {
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
    focusTarget: {
      if (!cyberghost.setupDone) {
        if (!cyberghost.readyCreds)
          return regUser
        if ((!cyberghost.readyWg || !cyberghost.readyRequests) && dependencyRepeater.count > 0)
          return root.firstMissingDependencyTarget()
        return openInstallerBtn
      }
      if (cyberghost.setupCardState === "update-available")
        return openInstallerBtn
      if (cyberghost.setupCardState === "polkit-optional")
        return enablePolkitBtn
      return connectBtn
    }
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
          // The hero is the user's main control surface (connect toggle, IP,
          // country). It appears as soon as the four REQUIRED checks pass
          // (WireGuard, Python requests, account link, root helper). The
          // optional Polkit rule is surfaced as a non-blocking line in the
          // setup card and in the status banner — it never hides the hero.
          Item {
            visible: cyberghost.setupDone
            width: parent.width
            implicitHeight: visible ? hero.implicitHeight : 0
            height: implicitHeight
            clip: true

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
                PowerButton {
                  id: powerSwitch
                  checked: cyberghost.active
                  busy: cyberghost.connecting || cyberghost.disconnecting
                  accent: root.brandYellow
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  Accessible.name: cyberghost.active ? "Disconnect VPN" : "Connect to CyberGhost"
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
            // The banner also carries a soft, dismissable "Re-enable Polkit
            // prompt?" line when the user has previously dismissed the
            // optional Polkit rule. It is not an error and does not block
            // any action; click the link to re-show the setup card.
            readonly property bool showPolkitReminder: cyberghost.setupDone && cyberghost.polkitRuleDismissed && !cyberghost.readyPolkit
            visible: cyberghost.setupDone && (cyberghost.lastError !== "" || cyberghost.actionStatus !== "" || cyberghost.applyHint !== "" || cyberghost.tunnelStale || showPolkitReminder)
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
                if (cyberghost.lastError !== "")
                  return cyberghost.lastError
                if (cyberghost.actionStatus !== "")
                  return cyberghost.actionStatus
                if (cyberghost.tunnelStale)
                  return "Handshake stale (" + Math.round(cyberghost.handshakeAgeSec / 60) + " min) — tunnel may be down. Reconnect recommended."
                if (statusBanner.showPolkitReminder)
                  return "Passwordless connect is off and the prompt is hidden. Tap to re-enable it."
                return cyberghost.applyHint
              }
              color: statusBanner.isError ? Color.urgent : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              verticalAlignment: Text.AlignVCenter
              MouseArea {
                anchors.fill: parent
                visible: statusBanner.showPolkitReminder && !statusBanner.isError
                cursorShape: Qt.PointingHandCursor
                onClicked: cyberghost.restorePolkitPrompt()
              }
            }
          }

          // -------------------------------------------------------------
          // 3. SETUP WIZARD CARD / INLINE NOTICE
          // -------------------------------------------------------------
          // Visible only when setupCardState is one of:
          //   - "first-run"        (any required item missing)  → full card
          //   - "update-available" (helper version drift)        → full card
          //   - "polkit-optional"  (only the optional Polkit rule
          //                         is missing)                 → slim inline notice
          // Hidden when state is "ready".
          //
          // The polkit-optional case gets a borderless single-line notice
          // instead of a bordered card because a soft, dismissable suggestion
          // does not deserve the same visual weight as a real blocker.
          Item {
            id: setupCard
            readonly property bool isFirstRun: cyberghost.setupCardState === "first-run"
            readonly property bool isUpdate: cyberghost.setupCardState === "update-available"
            readonly property bool isPolkitOptional: cyberghost.setupCardState === "polkit-optional"
            readonly property color accent: isFirstRun ? Color.urgent : Color.accent
            visible: cyberghost.setupCardState !== "ready"
            width: parent.width
            // Hidden Column siblings still contribute implicitHeight in this
            // Qt build, so every optional block reports 0 when it is not shown.
            implicitHeight: visible ? (notice.visible ? notice.implicitHeight : (fullCard.visible ? fullCard.implicitHeight : 0)) : 0
            height: implicitHeight
            clip: true

            // -- Compact inline notice (polkit-optional only) --
            Rectangle {
              id: notice
              visible: setupCard.isPolkitOptional
              anchors.left: parent.left
              anchors.right: parent.right
              implicitHeight: visible ? noticeRow.implicitHeight + Style.space(10) : 0
              height: implicitHeight
              clip: true
              radius: Style.cornerRadius > 0 ? Style.space(6) : 0
              color: Util.alpha(setupCard.accent, 0.06)
              border.width: 1
              border.color: Util.alpha(setupCard.accent, 0.28)

              Row {
                id: noticeRow
                x: Style.space(10)
                y: Style.space(5)
                width: parent.width - Style.space(16)
                spacing: Style.space(8)

                // Subtle key icon as visual anchor
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "\uf084"  // Font Awesome key
                  color: setupCard.accent
                  opacity: 0.85
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(10, parent.width - keyIconText.width - enablePolkitBtn.width - dismissPolkitBtn.width - Style.space(8) * 4)
                  text: cyberghost.polkitStatus !== "" && cyberghost.polkitStatus.indexOf("Installer closed") === -1
                    ? cyberghost.polkitStatus
                    : (cyberghost.readyPolkit
                       ? "Passwordless connect enabled."
                       : "Skip the password prompt on every connect (optional).")
                  color: cyberghost.readyPolkit ? root.successGreen : root.foreground
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                // Placeholder to keep the layout math readable; not rendered
                Item {
                  id: keyIconText
                  visible: false
                  width: Style.space(14)
                }

                Button {
                  id: enablePolkitBtn
                  anchors.verticalCenter: parent.verticalCenter
                  focusable: true
                  visible: !cyberghost.readyPolkit
                  enabled: !cyberghost.busy
                  text: "Enable"
                  bordered: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(2)
                  Accessible.name: "Install the optional Polkit rule for passwordless connect"
                  tooltipText: "Install the Polkit rule so connect/disconnect does not prompt for your password each time"
                  onClicked: cyberghost.openHelperInstaller()
                }

                Button {
                  id: dismissPolkitBtn
                  anchors.verticalCenter: parent.verticalCenter
                  focusable: true
                  visible: !cyberghost.readyPolkit
                  enabled: !cyberghost.busy
                  text: "\u00D7"  // ×
                  bordered: false
                  foreground: root.dim
                  fontSize: Style.font.body
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(0)
                  Accessible.name: "Dismiss the Polkit prompt for this session"
                  tooltipText: "Hide this prompt. You can re-enable Polkit later from the widget (the status banner reminds you)."
                  onClicked: cyberghost.dismissPolkitPrompt()
                }
              }
            }

            // -- Full bordered card (first-run / update-available) --
            // Size the Rectangle from the Column's content. Do not use
            // anchors.fill on the Column (that collapses the card to 0
            // height) and do not vertically anchor the Column (that loops
            // with implicitHeight and leaves a large empty gap).
            Rectangle {
              id: fullCard
              visible: setupCard.isFirstRun || setupCard.isUpdate
              anchors.left: parent.left
              anchors.right: parent.right
              implicitHeight: visible ? setupColumn.implicitHeight + Style.space(24) : 0
              height: implicitHeight
              clip: true
              radius: Style.cornerRadius > 0 ? Style.space(6) : 0
              color: Util.alpha(setupCard.accent, 0.05)
              border.width: 1
              border.color: Util.alpha(setupCard.accent, 0.3)

              Column {
                id: setupColumn
                x: Style.space(12)
                y: Style.space(12)
                width: parent.width - Style.space(24)
                spacing: Style.space(8)

              // Title — three states, three tones. We never use urgent red
              // for a routine version-bump or a dismissed-optional prompt.
              Text {
                text: setupCard.isFirstRun ? "FIRST-RUN SETUP" : (setupCard.isUpdate ? "PLUGIN UPDATE AVAILABLE" : "OPTIONAL SETUP")
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: setupCard.accent
              }

              // Transient status line (installer closed, packages installed…)
              Text {
                visible: cyberghost.setupMsg !== ""
                width: parent.width
                height: visible ? implicitHeight : 0
                textFormat: Text.PlainText
                text: cyberghost.setupMsg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
                wrapMode: Text.WordWrap
              }

              // -- Dependency rows with one-click install --
              // Only shown when something is still missing. Once both deps
              // are green we collapse to a one-line summary, freeing vertical
              // space for the actual blocker (helper, account, polkit).
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: setupCard.isFirstRun && (!cyberghost.readyWg || !cyberghost.readyRequests)
                height: visible ? implicitHeight : 0
                clip: true

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
              }

              Row {
                id: accountLinkedRow
                width: parent.width
                spacing: Style.space(6)
                visible: setupCard.isFirstRun && cyberghost.readyCreds
                height: visible ? implicitHeight : 0

                Text {
                  textFormat: Text.PlainText
                  text: "CyberGhost account  ·  linked"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.successGreen
                }

                Text {
                  textFormat: Text.PlainText
                  text: "\u2713"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: root.successGreen
                }
              }

              // -- Account linking form --
              Item {
                width: parent.width
                visible: setupCard.isFirstRun && !cyberghost.readyCreds
                implicitHeight: visible ? accRow.implicitHeight : 0
                height: implicitHeight
                clip: true

                Column {
                  id: accRow
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: "CyberGhost account  ·  not linked"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
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

              // -- Helper section --
              // Three sub-states:
              //   - update-available: helper installed but version drift. The
              //     version numbers live in the button's tooltipText (for
              //     curious / a11y users), not in the headline.
              //   - first-run, helper not yet installed: "Required: install
              //     the root helper" (the helper is what makes the connect
              //     button actually do anything).
              //   - polkit-optional: helper is fine, only the optional
              //     passwordless rule is missing.
              // The compact notice above owns the polkit-optional case;
              // this section is only shown for first-run / update-available,
              // which is already enforced by the parent `fullCard.visible`.
              //
              // Layout: the message gets the full width on top, and the
              // action row sits right-aligned underneath. Stacking vertically
              // fixes the ugly narrow-column word-wrap that side-by-side
              // layouts produce when the message is long.
              Column {
                id: helperRow
                width: parent.width
                spacing: Style.space(8)
                visible: setupCard.isUpdate || !cyberghost.helperInstalled
                height: visible ? implicitHeight : 0
                clip: true

                // Single source of truth for the helper-section copy.
                // Version numbers live in `tooltipText` / `Accessible.description`
                // so the headline stays readable.
                Text {
                  id: helperLabel
                  textFormat: Text.PlainText
                  width: parent.width
                  text: {
                    if (cyberghost.polkitStatus !== "" && cyberghost.polkitStatus.indexOf("Installer closed") === -1)
                      return cyberghost.polkitStatus
                    if (setupCard.isUpdate)
                      return "Root helper needs an update to match this plugin version."
                    return "Required: install the root helper to enable connect and disconnect."
                  }
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: setupCard.isFirstRun && !cyberghost.helperInstalled ? root.urgent : root.foreground
                  wrapMode: Text.WordWrap
                  Accessible.description: setupCard.isUpdate && cyberghost.helperVersion !== "" && cyberghost.pluginVersion !== ""
                    ? ("Helper installed: v" + cyberghost.helperVersion + ". Plugin bundled: v" + cyberghost.pluginVersion + ".")
                    : "A small, fixed Python program installed at /usr/local/bin/cyberghost-runner. This widget never edits the helper; only the bundled copy is read."
                  // Tooltip on hover keeps the technical detail available
                  // without bloating the visible label. `ToolTip` lives in
                  // QtQuick.Controls (imported as `QQC`), not QtQuick, so we
                  // must qualify the attached property explicitly when used
                  // on a `Text` (which has no built-in ToolTip).
                  QQC.ToolTip.visible: ma.containsMouse
                  QQC.ToolTip.delay: 500
                  QQC.ToolTip.text: "A small, fixed Python program installed at /usr/local/bin/cyberghost-runner. This widget never edits the helper; only the bundled copy is read."
                  MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                  }
                }

                // Action row, right-aligned. The "Install" / "Update helper"
                // button is the primary action (right edge, where the eye
                // lands for the "next" action); "Recheck" is the secondary,
                // smaller, and sits to its left.
                Row {
                  id: helperButtons
                  width: parent.width
                  spacing: Style.space(6)
                  layoutDirection: Qt.RightToLeft

                  Button {
                    id: openInstallerBtn
                    focusable: true
                    Accessible.name: setupCard.isUpdate ? "Update the root helper in a terminal" : "Install the root helper in a terminal"
                    enabled: !cyberghost.busy && !cyberghost.regBusy
                    text: cyberghost.polkitBusy ? "…" : (setupCard.isUpdate ? "Update helper" : "Install helper")
                    bordered: true
                    foreground: setupCard.isUpdate ? Color.accent : root.foreground
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(10)
                    verticalPadding: Style.space(2)
                    tooltipText: setupCard.isUpdate && cyberghost.helperVersion !== "" && cyberghost.pluginVersion !== ""
                      ? ("Replaces /usr/local/bin/cyberghost-runner (currently v" + cyberghost.helperVersion + ") with the v" + cyberghost.pluginVersion + " bundled in this plugin. Opens a sudo terminal.")
                      : "Open a terminal and run the sudo installer, then recheck setup"
                    onClicked: cyberghost.openHelperInstaller()
                  }

                  Button {
                    id: recheckBtn
                    focusable: true
                    Accessible.name: "Recheck CyberGhost setup"
                    enabled: !cyberghost.busy && !cyberghost.regBusy
                    text: "Recheck"
                    bordered: true
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(2)
                    tooltipText: "Check dependencies, account, helper and optional Polkit setup again"
                    onClicked: cyberghost.recheck()
                  }
                }
              }

              // -- Dismissed-state footer --
              // When the user has explicitly dismissed the Polkit prompt, we
              // do not show the card at all (state is "ready"). If the helper
              // is later re-detected as drift, the card returns with state
              // "update-available" — no manual re-enable required.
            }
          }
          }

          // -------------------------------------------------------------
          // 4. LIVE CONNECTION & IP CARD (CLICK-TO-COPY)
          // -------------------------------------------------------------
          Rectangle {
            visible: cyberghost.setupDone
            width: parent.width
            // Size from content with equal 10px padding on every side. Hidden
            // first-run siblings must report 0 height or the panel stays as
            // tall as the full connected layout.
            implicitHeight: visible ? infoColumn.implicitHeight + Style.space(20) : 0
            height: implicitHeight
            clip: true
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: Util.alpha(Color.popups.text, cyberghost.connected ? 0.04 : 0.02)
            border.width: 1
            // The outer KeyboardPanel already provides the strong surface
            // boundary. Keep this status surface quiet unless the VPN is
            // connected, following the official panels' separator-first UI.
            border.color: cyberghost.connected ? Util.alpha(root.brandYellow, 0.4) : Util.alpha(root.foreground, 0.18)

            Column {
              id: infoColumn
              x: Style.space(10)
              y: Style.space(10)
              width: parent.width - Style.space(20)
              spacing: Style.space(8)

              // Status header: badge + protocol subtitle on the left,
              // privacy toggle (icon only) on the right. The protocol used to
              // be a separate pill competing for space; it's now a quiet
              // subtitle so the badge stays the visual anchor.
              Item {
                width: parent.width
                implicitHeight: statusRow.implicitHeight

                Row {
                  id: statusRow
                  width: parent.width
                  spacing: Style.space(8)

                  // Left cluster: dot + badge + protocol subtitle
                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(10, parent.width - hideDetailsBtn.width - Style.space(8))
                    spacing: Style.space(6)

                    Rectangle {
                      id: statusDot
                      width: Style.space(8)
                      height: width
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: cyberghost.connected ? root.successGreen : (cyberghost.connecting ? root.brandYellow : root.urgent)
                      Behavior on color { ColorAnimation { duration: 180 } }
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: cyberghost.connected ? "PROTECTED" : (cyberghost.connecting ? "CONNECTING…" : "IP EXPOSED")
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      color: cyberghost.connected ? root.successGreen : (cyberghost.connecting ? root.brandYellow : root.dim)
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      visible: cyberghost.protocol !== ""
                      text: "·  " + (cyberghost.protocol === "wireguard" ? "WireGuard" : (cyberghost.protocol === "openvpn" ? "OpenVPN UDP" : "OpenVPN TCP"))
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.dim
                    }
                  }

                  // Right: icon-only privacy toggle
                  Button {
                    id: hideDetailsBtn
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(28)
                    implicitWidth: Style.space(28)
                    horizontalPadding: 0
                    iconText: cyberghost.hideDetails ? "\uf070" : "\uf06e"
                    text: ""
                    bordered: false
                    foreground: cyberghost.hideDetails ? root.urgent : root.dim
                    focusable: true
                    Accessible.name: cyberghost.hideDetails ? "Show connection details" : "Hide connection details"
                    tooltipText: cyberghost.hideDetails ? "Reveal IP & connection details" : "Hide IP & connection details"
                    onClicked: cyberghost.setHideDetails(!cyberghost.hideDetails)
                  }
                }
              }

              // Divider
              PanelSeparator {
                foreground: root.foreground
              }

              // Connection details: IP / Location / Provider + Copy IP button +
              // optional geo-mismatch note. The previous implementation used
              // absolute `y:` positioning for the copy row and the
              // geoMismatchText had no positioning at all (it overlapped the
              // detail grid at y=0 when visible). Replaced with a proper
              // Column so spacing is consistent and the geo-mismatch note
              // renders in the right place when shown.
              Column {
                width: parent.width
                spacing: Style.space(8)

                Grid {
                  id: detailGrid
                  width: parent.width
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

          Item {
            visible: cyberghost.setupDone
            width: parent.width
            implicitHeight: visible ? mainControls.implicitHeight : 0
            height: implicitHeight
            clip: true

            Column {
              id: mainControls
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

                  // Show a leading check mark on the currently selected
                  // country so the active state is unmissable at a glance.
                  text: (cyberghost.country === modelData.code ? "\u2713 " : "") + modelData.flag + "  " + modelData.code
                  selected: (cyberghost.country === modelData.code)
                  bordered: true
                  foreground: (cyberghost.country === modelData.code) ? root.brandYellow : root.foreground
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
              // The "COUNTRY" section header already labels the row, so the
              // internal `label` would be redundant. The dropdown's own
              // placeholder carries the helper text instead.
              label: ""
              placeholderText: "Search 90+ countries…"
              Accessible.name: "Country"
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
                  // The "SERVER SELECTION" section header already labels the row.
                  label: ""
                  placeholderText: "Fastest in this country or choose manually…"
                  Accessible.name: "Server"
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

            // Small inline labels disambiguate the two similar 3-up rows
            // that follow. Without them, "Traffic / Torrent / Streaming"
            // and "WireGuard / OpenVPN UDP / OpenVPN TCP" look almost
            // identical at a glance and the user has to read every label.
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Mode"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.dim
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
                // Leading check mark + brand yellow on the active mode, matching
                // the country grid so the visual language stays consistent.
                text: (cyberghost.serverType === "traffic" ? "\u2713  " : "") + "⚡  Traffic"
                selected: cyberghost.serverType === "traffic"
                bordered: true
                foreground: (cyberghost.serverType === "traffic") ? root.brandYellow : root.foreground
                tooltipText: "Fastest standard routing for web browsing"
                onClicked: root.setServerType("traffic")
              }

              Button {
                width: modeRow.cellW
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: "Use Torrent servers"
                text: (cyberghost.serverType === "torrent" ? "\u2713  " : "") + "🔒  Torrent"
                selected: cyberghost.serverType === "torrent"
                bordered: true
                foreground: (cyberghost.serverType === "torrent") ? root.brandYellow : root.foreground
                tooltipText: "Servers optimized for P2P and torrenting"
                onClicked: root.setServerType("torrent")
              }

              Button {
                width: modeRow.cellW
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: "Use Streaming servers"
                text: (cyberghost.serverType === "streaming" ? "\u2713  " : "") + "🎬  Streaming"
                selected: cyberghost.serverType === "streaming"
                bordered: true
                foreground: (cyberghost.serverType === "streaming") ? root.brandYellow : root.foreground
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
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Protocol"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.dim
            }

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
                // Same active treatment as the mode row: leading ✓ + brand yellow.
                text: (cyberghost.protocol === "wireguard" ? "\u2713  " : "") + "WireGuard"
                selected: cyberghost.protocol === "wireguard"
                bordered: true
                foreground: (cyberghost.protocol === "wireguard") ? root.brandYellow : root.foreground
                tooltipText: "WireGuard protocol (Fastest and modern)"
                onClicked: root.setProtocol("wireguard")
              }

              Button {
                width: protoRow.cellW
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: "Use OpenVPN UDP protocol"
                text: (cyberghost.protocol === "openvpn" ? "\u2713  " : "") + "OpenVPN UDP"
                selected: cyberghost.protocol === "openvpn"
                bordered: true
                foreground: (cyberghost.protocol === "openvpn") ? root.brandYellow : root.foreground
                tooltipText: "OpenVPN over UDP"
                onClicked: root.setProtocol("openvpn")
              }

              Button {
                width: protoRow.cellW
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: "Use OpenVPN TCP protocol"
                text: (cyberghost.protocol === "openvpn_tcp" ? "\u2713  " : "") + "OpenVPN TCP"
                selected: cyberghost.protocol === "openvpn_tcp"
                bordered: true
                foreground: (cyberghost.protocol === "openvpn_tcp") ? root.brandYellow : root.foreground
                tooltipText: "OpenVPN over TCP"
                onClicked: root.setProtocol("openvpn_tcp")
              }
            }

            // -------------------------------------------------------------
            // 10. PRIMARY ACTION + REFRESH
            // -------------------------------------------------------------
            // Connect is the primary action (fills the available width minus
            // the small ghost Refresh button on its left). Anchored layout.
            //
            // The Button's implicit width includes content padding even when
            // `text` is empty, so we pin `width`/`implicitWidth` to the icon
            // box. Without that, anchoring Connect to Refresh's right edge
            // leaves a large unexplained gap. Keeping a real Button preserves
            // Tab focus, the focus ring, and the tooltip.
            Item {
              id: actionsRow
              width: parent.width
              implicitHeight: Math.max(refreshStatusButton.height, connectBtn.implicitHeight)

              Button {
                id: refreshStatusButton
                width: Style.space(28)
                implicitWidth: Style.space(28)
                implicitHeight: Style.space(28)
                horizontalPadding: 0
                verticalPadding: 0
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                enabled: !cyberghost.busy
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
                anchors.left: refreshStatusButton.right
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                enabled: !cyberghost.busy
                focusable: true
                Accessible.name: cyberghost.active ? "Disconnect VPN" : "Connect VPN"
                iconText: cyberghost.active ? "\uf00d" : "\uf00c"
                text: cyberghost.connecting ? "Connecting…" : (cyberghost.disconnecting ? "Disconnecting…" : (cyberghost.active ? "Disconnect" : "Connect"))
                selected: cyberghost.active
                bordered: true
                foreground: cyberghost.active ? Color.urgent : root.brandYellow
                tooltipText: cyberghost.active ? "Stop VPN connection" : "Start VPN connection"
                onClicked: root.toggleRunning()
              }
            }
            } // end mainControls
          } // end mainControls wrapper

          // Bottom breathing room: keep the Connect button from kissing the
          // bottom edge of the panel. Hidden during first-run so the wizard
          // card is not followed by a tall empty region.
          Item {
            width: parent.width
            visible: cyberghost.setupDone
            implicitHeight: visible ? Style.space(16) : 0
            height: implicitHeight
          }
        }
      }
    }
  }
}
