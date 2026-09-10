import QtQuick
import qs.Commons
import qs.Ui

// Required setup only. Optional preferences belong under Advanced.
Column {
  id: root
  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property bool needsPackages: !service.readyWg || !service.readyDns || !service.readyRequests
  readonly property bool needsAccount: !service.readyCreds
  readonly property var focusTarget: needsPackages ? installDependencies : (needsAccount ? username : installHelper)
  visible: service.setupCardState !== "ready"
  height: visible ? implicitHeight : 0
  spacing: visible ? Style.space(12) : 0

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

  Text {
    visible: root.visible
    width: parent.width
    text: root.service.setupCardState === "update-available" ? "Update connection helper" : "Set up CyberGhost"
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
    wrapMode: Text.WordWrap
  }

  Text {
    visible: root.visible && root.service.setupMsg !== ""
    width: parent.width
    text: root.service.setupMsg
    textFormat: Text.PlainText
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    Accessible.role: Accessible.AlertMessage
    Accessible.name: text
  }

  Column {
    visible: root.visible && root.needsPackages
    width: parent.width
    spacing: Style.space(6)
    Text {
      width: parent.width
      text: "Install WireGuard tools, Python requests and a VPN DNS provider (resolvconf)."
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
    Button {
      id: installDependencies
      objectName: "installDependencies"
      text: "Install dependencies"
      focusable: true
      bordered: true
      enabled: !root.service.busy
      foreground: root.foreground
      onClicked: root.service.installDeps()
    }
  }

  Column {
    visible: root.visible && !root.needsPackages && root.needsAccount
    width: parent.width
    spacing: Style.space(8)
    Text {
      width: parent.width
      text: "Link your CyberGhost account. The plugin does not save your password."
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
    Text {
      text: "Username or email"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    TextField {
      id: username
      objectName: "accountUsername"
      width: parent.width
      enabled: !root.service.regBusy
      maximumLength: 256
      placeholderText: "name@example.com"
      Accessible.name: "CyberGhost username or email"
      color: root.foreground
      font.family: root.fontFamily
      selectByMouse: true
      onAccepted: password.forceActiveFocus()
    }
    Text {
      text: "Password"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    TextField {
      id: password
      objectName: "accountPassword"
      width: parent.width
      enabled: !root.service.regBusy
      maximumLength: 256
      echoMode: TextInput.Password
      Accessible.name: "CyberGhost password"
      color: root.foreground
      font.family: root.fontFamily
      selectByMouse: true
      onAccepted: root.submit()
    }
    Button {
      objectName: "linkAccount"
      text: root.service.regBusy ? "Linking…" : "Link account"
      focusable: true
      bordered: true
      enabled: !root.service.regBusy
      foreground: root.foreground
      onClicked: root.submit()
    }
  }

  Column {
    visible: root.visible && !root.needsPackages && !root.needsAccount
    width: parent.width
    spacing: Style.space(8)
    Text {
      width: parent.width
      text: root.service.setupCardState === "update-available" ? "Update the helper to match this plugin. A terminal will ask for authorization." : "Install the connection helper. A terminal will ask for authorization; passwordless access is optional."
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
    Button {
      id: installHelper
      objectName: "installHelper"
      text: root.service.setupCardState === "update-available" ? "Update helper" : "Install helper"
      focusable: true
      bordered: true
      enabled: !root.service.busy
      foreground: root.foreground
      onClicked: root.service.openHelperInstaller(false)
    }
  }

  Text {
    visible: root.visible && root.service.connected && !root.service.helperPresent
    width: parent.width
    text: "A VPN tunnel is still reported active, but the fixed helper is missing. Reinstall the helper to recover it."
    textFormat: Text.PlainText
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Button {
    visible: root.visible && root.service.connected && root.service.helperPresent
    text: "Disconnect existing tunnel"
    focusable: true
    bordered: true
    enabled: !root.service.busy
    foreground: root.foreground
    onClicked: root.service.disconnect()
  }

  Button {
    visible: root.visible
    text: "Recheck setup"
    focusable: true
    enabled: !root.service.busy
    foreground: root.foreground
    onClicked: root.service.recheck()
  }
}
