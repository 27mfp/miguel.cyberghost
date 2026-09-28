import QtQuick
import qs.Commons
import qs.Ui

// Required setup only. Optional preferences belong under Advanced.
// Mirrors Omarchy's network credential prompt: placeholders instead of field
// labels, host TextField password mode, and the panel's primary-button style.
Column {
  id: root
  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color brandYellow: "#FFCE00"
  readonly property bool needsNetwork: !service.readyNetwork
  readonly property bool needsPackages: !needsNetwork && !service.readyRequests
  readonly property bool needsAccount: !needsNetwork && !needsPackages && !service.readyCreds
  readonly property bool formFilled: username.text.trim() !== "" && password.text !== ""
  readonly property var focusTarget: needsPackages ? installDependencies : (needsAccount ? username : recheckSetup)
  visible: service.setupCardState !== "ready"
  height: visible ? implicitHeight : 0
  spacing: visible ? Style.space(10) : 0

  function clearPassword() {
    password.clear()
  }
  onVisibleChanged: if (!visible)
    clearPassword()

  function submit() {
    if (!username.text.trim() || !password.text) {
      service.setupMsg = "Enter your CyberGhost username and password."
      if (!username.text.trim())
        username.forceActiveFocus()
      else
        password.forceActiveFocus()
      return
    }
    service.registerAccount(username.text.trim(), password.text)
    password.clear()
  }

  // ---- Checklist -----------------------------------------------------------
  Item {
    visible: root.visible
    width: parent.width
    implicitHeight: Math.max(setupHeader.implicitHeight, recheckSetup.implicitHeight)

    PanelSectionHeader {
      id: setupHeader
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "SETUP"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    PanelActionButton {
      id: recheckSetup
      objectName: "recheckSetup"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      focusable: true
      enabled: !root.service.busy
      iconText: ""
      tooltipText: "Recheck setup"
      Accessible.name: "Recheck setup"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.service.recheck()
    }
  }

  StepRow {
    objectName: "networkStep"
    visible: root.visible
    foreground: root.foreground
    highlight: root.brandYellow
    fontFamily: root.fontFamily
    label: "NetworkManager"
    done: root.service.readyNetwork
    current: root.needsNetwork
    // Omarchy ships NetworkManager; the tunnel is one of its connections.
    detail: !root.service.readyNm ? "CyberGhost runs its tunnel through NetworkManager, Omarchy's network service, which is not running. Start it, then recheck." : "Your account is not allowed to manage network connections (NetworkManager Polkit policy)."
    detailObjectName: "networkRequirement"
  }

  StepRow {
    objectName: "requestsStep"
    visible: root.visible
    foreground: root.foreground
    highlight: root.brandYellow
    fontFamily: root.fontFamily
    label: "Python requests"
    done: root.service.readyRequests
    current: root.needsPackages
    detail: "Needed for the CyberGhost account API. Installs in a terminal."

    Button {
      id: installDependencies
      objectName: "installDependencies"
      visible: root.needsPackages
      text: root.service.depsBusy ? "Installing…" : "Install"
      focusable: true
      bordered: true
      enabled: !root.service.busy
      foreground: enabled ? root.brandYellow : root.dim
      fontFamily: root.fontFamily
      onClicked: root.service.installDeps()
    }
  }

  StepRow {
    objectName: "accountStep"
    visible: root.visible
    foreground: root.foreground
    highlight: root.brandYellow
    fontFamily: root.fontFamily
    label: "CyberGhost account"
    done: root.service.readyCreds
    current: root.needsAccount
  }

  // ---- Account form --------------------------------------------------------
  Column {
    visible: root.visible && root.needsAccount
    width: parent.width
    spacing: Style.space(8)
    topPadding: Style.space(2)

    TextField {
      id: username
      objectName: "accountUsername"
      width: parent.width
      enabled: !root.service.regBusy
      maximumLength: 256
      placeholderText: "Username or email"
      Accessible.name: "CyberGhost username or email"
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      selectByMouse: true
      onAccepted: password.forceActiveFocus()
    }

    TextField {
      id: password
      objectName: "accountPassword"
      width: parent.width
      enabled: !root.service.regBusy
      maximumLength: 256
      password: true
      placeholderText: "Password"
      Accessible.name: "CyberGhost password"
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      selectByMouse: true
      onAccepted: root.submit()
    }

    Button {
      objectName: "linkAccount"
      width: parent.width
      iconText: root.service.regBusy ? "" : ""
      iconSpinning: root.service.regBusy
      text: root.service.regBusy ? "Linking account…" : "Link account"
      focusable: true
      bordered: true
      enabled: !root.service.regBusy && root.formFilled
      // The host Button has no disabled styling; dim it until it can act.
      foreground: enabled || root.service.regBusy ? root.brandYellow : root.dim
      fontFamily: root.fontFamily
      tooltipText: "Register this device with your CyberGhost account"
      onClicked: root.submit()
    }

    Row {
      width: parent.width
      spacing: Style.space(6)
      Text {
        id: lockGlyph
        text: ""
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        width: parent.width - lockGlyph.width - parent.spacing
        text: "Your password goes to CyberGhost once and is never saved."
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // Progress text while something runs; an error once it has finished.
  Text {
    objectName: "setupMessage"
    visible: root.visible && root.service.setupMsg !== ""
    width: parent.width
    text: root.service.setupMsg
    textFormat: Text.PlainText
    color: root.service.busy ? root.dim : Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    Accessible.role: Accessible.AlertMessage
    Accessible.name: text
  }

  Button {
    visible: root.visible && root.service.connected
    width: parent.width
    iconText: ""
    text: "Disconnect existing tunnel"
    focusable: true
    bordered: true
    enabled: !root.service.busy
    foreground: Color.urgent
    fontFamily: root.fontFamily
    onClicked: root.service.disconnect()
  }

  // One checklist line: state glyph, label, an explanation for the current
  // step, and optional trailing actions declared as children.
  component StepRow: Item {
    id: step
    property string label: ""
    property string detail: ""
    property string detailObjectName: ""
    property bool done: false
    property bool current: false
    default property alias trailing: trailingSlot.data
    // Inline components cannot see the card's ids; styling is passed in.
    property color foreground: Color.foreground
    property color highlight: "#FFCE00"
    property string fontFamily: Style.font.family
    readonly property color dim: Qt.darker(foreground, 1.4)
    readonly property color tone: done ? dim : (current ? foreground : Qt.darker(foreground, 1.9))

    width: parent ? parent.width : 0
    implicitHeight: Math.max(stepLabel.implicitHeight, trailingSlot.implicitHeight) + (detailText.visible ? detailText.implicitHeight + Style.space(2) : 0)
    height: implicitHeight

    Text {
      id: stepGlyph
      width: Style.space(18)
      anchors.left: parent.left
      anchors.verticalCenter: stepLabel.verticalCenter
      // check for done, filled dot for the current step, open circle for later
      text: step.done ? "" : (step.current ? "" : "")
      textFormat: Text.PlainText
      color: step.done ? Color.accent : (step.current ? step.highlight : step.tone)
      font.family: step.fontFamily
      // The solid dot reads heavier than the check glyph; keep them balanced.
      font.pixelSize: step.current && !step.done ? Math.round(Style.font.caption * 0.7) : Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      id: stepLabel
      anchors.left: stepGlyph.right
      anchors.leftMargin: Style.space(6)
      anchors.right: trailingSlot.left
      anchors.rightMargin: trailingSlot.implicitWidth > 0 ? Style.space(8) : 0
      y: Math.max(0, (trailingSlot.implicitHeight - implicitHeight) / 2)
      text: step.label
      textFormat: Text.PlainText
      color: step.tone
      font.family: step.fontFamily
      font.pixelSize: Style.font.body
      font.bold: step.current && !step.done
      elide: Text.ElideRight
    }

    Row {
      id: trailingSlot
      anchors.right: parent.right
      anchors.top: parent.top
    }

    Text {
      id: detailText
      objectName: step.detailObjectName
      visible: step.current && !step.done && step.detail !== ""
      anchors.left: stepLabel.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      text: step.detail
      textFormat: Text.PlainText
      color: step.dim
      font.family: step.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
