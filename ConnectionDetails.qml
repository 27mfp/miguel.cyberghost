pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Countries.js" as Countries

Rectangle {
  id: root
  required property var service
  readonly property var cyberghost: service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.25)
  readonly property color urgent: Color.urgent
  readonly property color brandYellow: "#FFCE00"
  readonly property color successGreen: "#10B981"
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
        root.cyberghost.lastError = "Clipboard copy timed out."
      }
    }
  }

  Process {
    id: clipboardProcess
    onExited: function (exitCode) {
      copyTimeoutTimer.stop()
      if (exitCode !== 0) {
        root.ipCopied = false
        root.cyberghost.lastError = "Could not copy the public IP to the clipboard."
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

  function fmtHandshake(sec) {
    if (sec < 0)
      return ""
    if (sec < 90)
      return sec + "s"
    if (sec < 3600)
      return Math.round(sec / 60) + " min"
    return Math.round(sec / 3600 * 10) / 10 + " h"
  }

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
            color: root.cyberghost.connected ? root.successGreen : (root.cyberghost.connecting ? root.brandYellow : root.urgent)
            Behavior on color {
              ColorAnimation {
                duration: 180
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.cyberghost.connected ? "TUNNEL ACTIVE" : (root.cyberghost.connecting ? "CONNECTING…" : "VPN OFF")
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            color: root.cyberghost.connected ? root.successGreen : (root.cyberghost.connecting ? root.brandYellow : root.dim)
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            visible: root.cyberghost.connected && root.cyberghost.lastBackend !== ""
            text: root.cyberghost.lastBackend === "wireguard" ? "· WireGuard" : "· Vendor CLI"
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
          iconText: root.cyberghost.hideDetails ? "\uf070" : "\uf06e"
          text: ""
          bordered: false
          foreground: root.cyberghost.hideDetails ? root.urgent : root.dim
          focusable: true
          Accessible.name: root.cyberghost.hideDetails ? "Show connection details" : "Hide connection details"
          tooltipText: root.cyberghost.hideDetails ? "Reveal IP & connection details" : "Hide IP & connection details"
          onClicked: root.cyberghost.setHideDetails(!root.cyberghost.hideDetails)
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
          text: root.cyberghost.hideDetails ? "•••.•••.•••.•••" : (root.cyberghost.publicIp !== "" ? root.cyberghost.publicIp : (root.cyberghost.fetchingIp ? "Checking…" : "Unavailable"))
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
            if (root.cyberghost.hideDetails)
              return "Hidden"
            var parts = []
            if (root.cyberghost.publicCity)
              parts.push(root.cyberghost.publicCity)
            if (root.cyberghost.publicCountry)
              parts.push(Countries.countryName(root.cyberghost.publicCountry) + " " + Countries.countryFlag(root.cyberghost.publicCountry))
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
          text: root.cyberghost.hideDetails ? "Hidden" : (root.cyberghost.publicOrg !== "" ? root.cyberghost.publicOrg : "Unknown")
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
          visible: root.cyberghost.connected && (root.cyberghost.transferText !== "" || root.cyberghost.endpoint !== "")
          text: {
            if (root.cyberghost.hideDetails)
              return "Hidden"
            var parts = []
            if (root.cyberghost.transferText !== "")
              parts.push(root.cyberghost.transferText)
            if (root.cyberghost.handshakeAgeSec >= 0)
              parts.push("handshake " + root.fmtHandshake(root.cyberghost.handshakeAgeSec))
            if (root.cyberghost.endpoint !== "")
              parts.push(root.cyberghost.endpoint)
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
          enabled: !root.cyberghost.hideDetails && root.cyberghost.publicIp !== ""
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
        visible: !root.cyberghost.hideDetails && root.cyberghost.connected && root.cyberghost.publicCountry !== "" && root.cyberghost.publicCountry !== root.cyberghost.country
        width: parent.width
        textFormat: Text.PlainText
        text: visible ? "IP geolocation: " + Countries.countryName(root.cyberghost.publicCountry) + " · target: " + root.cyberghost.countryName + " (" + root.cyberghost.country + ")" : ""
        color: root.brandYellow
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
