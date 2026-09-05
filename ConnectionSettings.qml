import QtQuick
import qs.Commons
import qs.Ui
import "Countries.js" as Countries

// Destination first; optional tuning is disclosed without changing the live tunnel.
Column {
  id: root
  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool advanced: false
  property Component primaryActions: null
  // The injected Component's dynamic contract is a focusTarget item.
  readonly property var primaryFocusTarget: actions.item ? actions.item["focusTarget"] : null
  function closePopups() {
    countryPicker.close()
    serverPicker.close()
    modePicker.close()
    protocolPicker.close()
    streamingPicker.close()
  }
  onVisibleChanged: if (!visible)
    closePopups()
  onAdvancedChanged: if (!advanced) {
    serverPicker.close()
    modePicker.close()
    protocolPicker.close()
    streamingPicker.close()
  }
  readonly property bool popupOpen: countryPicker.popupOpen || serverPicker.popupOpen || modePicker.popupOpen || protocolPicker.popupOpen || streamingPicker.popupOpen
  spacing: Style.space(10)

  function selectCountry(code) {
    service.setCountry(code)
  }

  SearchableDropdown {
    id: countryPicker
    objectName: "countryPicker"
    width: parent.width
    label: "Country"
    Accessible.name: "VPN destination country"
    placeholderText: "Search countries…"
    popupMinHeight: 0
    options: Countries.dropdownOptions()
    value: root.service.country
    foreground: root.foreground
    fontFamily: root.fontFamily
    enabled: !root.service.busy
    onChanged: function (value) {
      root.selectCountry(value)
    }
  }

  Loader {
    id: actions
    width: parent.width
    sourceComponent: root.primaryActions
  }

  Button {
    objectName: "advancedToggle"
    text: "Advanced settings"
    iconText: root.advanced ? "\uf106" : "\uf107"
    fontSize: Style.font.caption
    horizontalPadding: Style.space(4)
    verticalPadding: Style.space(4)
    focusable: true
    selected: root.advanced
    foreground: root.foreground
    Accessible.name: text
    onClicked: root.advanced = !root.advanced
  }

  Column {
    visible: root.advanced
    width: parent.width
    spacing: Style.space(10)

    Text {
      width: parent.width
      text: root.service.connected ? "Changes apply to your next connection." : "WireGuard with automatic server selection is the default."
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    SearchableDropdown {
      id: serverPicker
      objectName: "serverPicker"
      popupMinHeight: 0
      width: parent.width
      visible: root.service.readyCli && root.service.cliConfigured && root.service.protocol === "wireguard" && root.service.serverType === "traffic"
      label: "Server"
      Accessible.name: "VPN server"
      value: root.service.serverSelection
      options: root.service.serverOptions
      enabled: !root.service.busy && !root.service.loadingServers
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function (value) {
        root.service.setServerSelection(value)
      }
    }

    Text {
      visible: serverPicker.visible && (root.service.loadingServers || root.service.serverError !== "")
      width: parent.width
      text: root.service.loadingServers ? "Loading servers…" : root.service.serverError
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      visible: !root.service.readyCli || !root.service.cliConfigured
      width: parent.width
      text: !root.service.readyCli ? "OpenVPN, torrent, streaming and exact servers need the optional cyberghostvpn CLI. Install it from a trusted source, then run cyberghostvpn --setup in a terminal." : "Complete the optional CLI setup with cyberghostvpn --setup in a terminal, then recheck. Native WireGuard remains available."
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Button {
      visible: !root.service.readyCli || !root.service.cliConfigured
      text: "Recheck CLI setup"
      focusable: true
      enabled: !root.service.busy
      foreground: root.foreground
      onClicked: root.service.recheck()
    }

    Dropdown {
      id: modePicker
      objectName: "modePicker"
      width: parent.width
      label: "Mode"
      Accessible.name: "VPN server mode"
      value: root.service.serverType
      options: [
        {
          value: "traffic",
          label: "Traffic"
        },
        {
          value: "torrent",
          label: "Torrent"
        },
        {
          value: "streaming",
          label: "Streaming"
        }
      ]
      enabled: !root.service.busy
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function (value) {
        root.service.setServerType(value)
      }
    }

    SearchableDropdown {
      id: streamingPicker
      objectName: "streamingPicker"
      popupMinHeight: 0
      width: parent.width
      visible: root.service.serverType === "streaming"
      label: "Streaming service"
      Accessible.name: "Streaming service"
      value: root.service.streamingService
      options: root.service.streamingOptions
      enabled: !root.service.busy && !root.service.streamingBusy
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function (value) {
        root.service.setStreamingService(value)
      }
    }

    Text {
      visible: streamingPicker.visible && (root.service.streamingBusy || root.service.streamingError !== "")
      width: parent.width
      text: root.service.streamingBusy ? "Loading streaming services…" : root.service.streamingError
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Dropdown {
      id: protocolPicker
      objectName: "protocolPicker"
      width: parent.width
      label: "Protocol"
      Accessible.name: "VPN protocol"
      value: root.service.protocol
      options: [
        {
          value: "wireguard",
          label: "WireGuard"
        },
        {
          value: "openvpn",
          label: "OpenVPN UDP"
        },
        {
          value: "openvpn_tcp",
          label: "OpenVPN TCP"
        }
      ]
      enabled: !root.service.busy
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function (value) {
        root.service.setProtocol(value)
      }
    }

    Text {
      width: parent.width
      text: "A connected tunnel is not a kill switch. Traffic is not blocked when the VPN disconnects."
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Button {
      visible: !root.service.readyPolkit
      text: "Enable passwordless connections…"
      focusable: true
      enabled: !root.service.busy
      foreground: root.foreground
      tooltipText: "Allows processes running as wheel members to use the fixed VPN helper without another prompt"
      onClicked: root.service.openHelperInstaller(true)
    }
  }
}
