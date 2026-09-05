import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Countries.js" as Countries

// Observed connection data, not another status card or a protection claim.
Column {
  id: root
  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool ipCopied: false
  property bool copyTimedOut: false
  readonly property color muted: Qt.darker(foreground, 1.25)
  visible: service.setupDone
  spacing: Style.space(8)
  height: visible ? implicitHeight : 0

  function copyIp() {
    if (service.hideDetails || !service.publicIp || clipboardProcess.running)
      return
    ipCopied = false
    copyTimedOut = false
    clipboardProcess.command = ["/usr/bin/wl-copy", service.publicIp]
    clipboardProcess.running = true
    copyTimeout.restart()
  }

  Process {
    id: clipboardProcess
    objectName: "clipboardProcess"
    onExited: function (exitCode) {
      copyTimeout.stop()
      if (root.copyTimedOut)
        return
      root.ipCopied = exitCode === 0 && !root.service.hideDetails
      if (exitCode !== 0)
        root.service.lastError = "Could not copy the public IP. Check that wl-copy is installed."
      if (root.ipCopied)
        copyReset.restart()
    }
  }
  Timer {
    id: copyReset
    interval: 2200
    onTriggered: root.ipCopied = false
  }
  Timer {
    id: copyTimeout
    interval: 3000
    onTriggered: {
      root.copyTimedOut = true
      root.ipCopied = false
      clipboardProcess.running = false
      root.service.lastError = "Clipboard copy timed out."
    }
  }

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  Item {
    width: parent.width
    implicitHeight: Style.space(28)
    Text {
      anchors.left: parent.left
      anchors.right: privacy.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Public connection"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      elide: Text.ElideRight
    }
    Button {
      id: privacy
      objectName: "privacyToggle"
      anchors.right: parent.right
      width: Style.space(28)
      implicitWidth: Style.space(28)
      implicitHeight: Style.space(28)
      horizontalPadding: 0
      verticalPadding: 0
      iconSize: Style.font.caption
      iconText: root.service.hideDetails ? "\uf070" : "\uf06e"
      focusable: true
      foreground: root.foreground
      Accessible.name: root.service.hideDetails ? "Show connection details" : "Hide connection details"
      tooltipText: Accessible.name
      onClicked: {
        root.ipCopied = false
        root.service.setHideDetails(!root.service.hideDetails)
      }
    }
  }

  Grid {
    id: dataGrid
    width: parent.width
    columns: 2
    columnSpacing: Style.space(10)
    rowSpacing: Style.space(6)
    readonly property real labelWidth: Style.space(56)
    readonly property real valueWidth: Math.max(1, width - labelWidth - columnSpacing)

    Text {
      width: dataGrid.labelWidth
      text: "IP"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      objectName: "ipValue"
      width: dataGrid.valueWidth
      text: root.service.hideDetails ? "Hidden" : (root.service.publicIp || (root.service.fetchingIp ? "Checking…" : "Unavailable"))
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
    }
    Text {
      width: dataGrid.labelWidth
      text: "Location"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      objectName: "locationValue"
      width: dataGrid.valueWidth
      text: root.service.hideDetails ? "Hidden" : ([root.service.publicCity, root.service.publicCountry ? Countries.countryName(root.service.publicCountry) : ""].filter(function (value) {
          return !!value
        }).join(", ") || "Unavailable")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
    }
    Text {
      width: dataGrid.labelWidth
      text: "Provider"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      objectName: "providerValue"
      width: dataGrid.valueWidth
      text: root.service.hideDetails ? "Hidden" : (root.service.publicOrg || "Unavailable")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
    }
    Text {
      visible: session.visible
      width: dataGrid.labelWidth
      text: "Session"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      id: session
      visible: root.service.connected
      width: dataGrid.valueWidth
      text: root.service.hideDetails ? "Hidden" : ([root.service.transferText, root.service.endpoint].filter(function (value) {
          return !!value
        }).join(" · ") || "Tunnel active")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
    }
  }

  Button {
    objectName: "copyIpButton"
    text: root.ipCopied ? "Copied" : "Copy IP"
    iconText: "\uf0c5"
    fontSize: Style.font.caption
    verticalPadding: Style.space(4)
    focusable: true
    enabled: !root.service.hideDetails && root.service.publicIp !== "" && !clipboardProcess.running
    foreground: root.foreground
    Accessible.name: root.ipCopied ? "Public IP copied" : "Copy public IP"
    onClicked: root.copyIp()
  }
}
