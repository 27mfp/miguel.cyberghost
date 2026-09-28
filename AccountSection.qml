import QtQuick
import qs.Commons
import qs.Ui

// Signed-in identity and logout. Only the plugin's own login (native.ini) can
// be logged out here; an account read from the vendor CLI's config.ini is
// shown but left to that CLI, since the plugin never deletes vendor files.
Column {
  id: root
  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property bool pluginLogin: service.accountSource === "native"
  // Two-step confirmation, disarmed automatically after a few seconds.
  property bool armed: false
  visible: service.setupDone && service.readyCreds
  height: visible ? implicitHeight : 0
  spacing: Style.space(8)

  function requestLogout() {
    if (!armed) {
      armed = true
      disarm.restart()
      return
    }
    armed = false
    disarm.stop()
    service.logout()
  }
  onVisibleChanged: armed = false

  Timer {
    id: disarm
    interval: 4000
    onTriggered: root.armed = false
  }

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  PanelSectionHeader {
    text: "ACCOUNT"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(identity.implicitHeight, logoutButton.implicitHeight)

    Text {
      id: accountGlyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
      text: ""
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Column {
      id: identity
      anchors.left: accountGlyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: logoutButton.visible ? logoutButton.left : parent.right
      anchors.rightMargin: logoutButton.visible ? Style.space(8) : 0
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        objectName: "accountName"
        width: parent.width
        // An email address is personal; privacy mode masks it too.
        text: root.service.hideDetails ? "Hidden" : (root.service.accountName || "CyberGhost account")
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideMiddle
      }
      Text {
        objectName: "accountSourceText"
        width: parent.width
        // A live session reads CyberGhost's own server list; once it expires
        // connects still work by probing, and linking again refreshes it.
        // Short enough to fit the panel's narrowest width without eliding.
        text: (root.pluginLogin ? "This device" : "CyberGhost CLI config") + (root.service.syncingServers ? " · syncing servers " + root.service.syncProgress : (root.service.serverList === "live" ? " · live servers" : (root.service.serverList === "probe" && root.pluginLogin ? " · relink to refresh servers" : "")))
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Button {
      id: logoutButton
      objectName: "logoutButton"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.pluginLogin
      text: root.armed ? (root.service.connected ? "Disconnect & log out" : "Confirm log out") : "Log out"
      iconText: ""
      fontSize: Style.font.caption
      horizontalPadding: Style.space(8)
      verticalPadding: Style.space(4)
      focusable: true
      bordered: root.armed
      enabled: !root.service.busy
      foreground: root.armed ? Color.urgent : root.foreground
      fontFamily: root.fontFamily
      tooltipText: root.armed ? "Click again to forget this device's CyberGhost login" : "Forget this device's CyberGhost login. You will need your password to link it again."
      Accessible.name: text
      onClicked: root.requestLogout()
    }
  }
}
