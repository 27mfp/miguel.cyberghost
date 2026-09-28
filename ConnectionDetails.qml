pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Countries.js" as Countries
import "ServiceUtils.js" as ServiceUtils

// Observed connection data, not a protection claim. Laid out like Omarchy's
// network panel: dimmed labels, right-aligned values, "--" placeholders so the
// grid never reflows when a sample arrives, and click-to-copy values.
Column {
  id: root
  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool ipCopied: false
  property bool copyTimedOut: false
  readonly property bool hidden: service.hideDetails
  readonly property bool tunnel: service.connected && !service.legacyTunnel
  visible: service.setupDone
  spacing: Style.space(8)
  height: visible ? implicitHeight : 0

  function copyIp() {
    if (hidden || !service.publicIp || clipboardProcess.running)
      return
    ipCopied = false
    copyTimedOut = false
    clipboardProcess.command = ["/usr/bin/wl-copy", service.publicIp]
    clipboardProcess.running = true
    copyTimeout.restart()
  }

  function masked(value, fallback) {
    return hidden ? "Hidden" : (value || fallback)
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
    implicitHeight: Math.max(sectionHeader.implicitHeight, privacy.implicitHeight)

    PanelSectionHeader {
      id: sectionHeader
      objectName: "detailsHeader"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      // The address the internet sees: the tunnel's exit, or your own ISP's.
      text: root.tunnel ? "VPN CONNECTION" : "YOUR CONNECTION"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    PanelActionButton {
      id: copyButton
      objectName: "copyIpButton"
      anchors.right: privacy.left
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      focusable: true
      enabled: !root.hidden && root.service.publicIp !== "" && !clipboardProcess.running
      iconText: root.ipCopied ? "" : ""
      tooltipText: root.ipCopied ? "Copied" : "Copy public IP (c)"
      Accessible.name: root.ipCopied ? "Public IP copied" : "Copy public IP"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.copyIp()
    }

    PanelActionButton {
      id: privacy
      objectName: "privacyToggle"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      focusable: true
      iconText: root.hidden ? "" : ""
      tooltipText: (root.hidden ? "Show connection details" : "Hide connection details") + " (h)"
      Accessible.name: root.hidden ? "Show connection details" : "Hide connection details"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: {
        root.ipCopied = false
        root.service.setHideDetails(!root.hidden)
      }
    }
  }

  // Long values (IP, place, provider, server) get full-width rows so the
  // address is never cut off; only the short transfer stats share a row.
  readonly property var rows: {
    var list = [{ label: "IP", text: masked(service.publicIp, service.fetchingIp ? "Checking…" : "Unavailable"), name: "ipValue", lines: 1 }, { label: "Location", text: masked([service.publicCity, service.publicCountry ? Countries.countryName(service.publicCountry) : ""].filter(function (value) {
            return !!value
          }).join(", "), "Unavailable"), name: "locationValue", lines: 1 }, { label: "Provider", text: masked(service.publicOrg, "Unavailable"), name: "providerValue", lines: 2 }]
    if (tunnel)
      list.push({ label: "Server", text: masked(service.activeServer || service.endpoint, "--"), name: "serverValue", lines: 1 })
    return list
  }

  readonly property var stats: tunnel ? [["Receiving", ServiceUtils.formatRate(service.rxRate), "receivingValue"], ["Sending", ServiceUtils.formatRate(service.txRate), "sendingValue"], ["Downloaded", ServiceUtils.formatBytes(service.rxBytes), "downloadedValue"], ["Uploaded", ServiceUtils.formatBytes(service.txBytes), "uploadedValue"]] : []

  Column {
    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: root.rows
      delegate: Item {
        id: row
        required property var modelData
        width: parent.width
        implicitHeight: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight)
        height: implicitHeight

        Text {
          id: rowLabel
          width: Style.space(72)
          text: row.modelData.label
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          id: rowValue
          readonly property bool copyable: row.modelData.name === "ipValue" && !root.hidden && root.service.publicIp !== ""
          objectName: row.modelData.name
          anchors.left: rowLabel.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          text: row.modelData.text
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignRight
          color: row.modelData.name === "ipValue" && root.ipCopied ? Color.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: row.modelData.lines > 1 ? Text.WordWrap : Text.NoWrap
          maximumLineCount: row.modelData.lines
          elide: Text.ElideRight

          MouseArea {
            anchors.fill: parent
            enabled: rowValue.copyable
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.copyIp()
          }
        }
      }
    }
  }

  // Short transfer values fit two per row, as in the network panel's grid.
  Grid {
    id: grid
    visible: root.tunnel
    width: parent.width
    height: visible ? implicitHeight : 0
    columns: 4
    columnSpacing: Style.space(14)
    rowSpacing: Style.space(6)
    readonly property real labelWidth: Style.space(72)
    readonly property real valueWidth: Math.max(1, (width - 3 * columnSpacing) / 2 - labelWidth)

    Repeater {
      model: root.stats.length * 2
      delegate: Text {
        required property int index
        readonly property var stat: root.stats[Math.floor(index / 2)]
        readonly property bool isLabel: index % 2 === 0
        objectName: isLabel ? "" : stat[2]
        width: isLabel ? grid.labelWidth : grid.valueWidth
        text: isLabel ? stat[0] : stat[1]
        textFormat: Text.PlainText
        horizontalAlignment: isLabel ? Text.AlignLeft : Text.AlignRight
        color: root.foreground
        opacity: isLabel ? 0.6 : 1
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }
  }
}
