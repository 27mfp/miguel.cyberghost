import QtQuick
import qs.Commons
import qs.Ui
import "Countries.js" as Countries

// Native WireGuard only. Vendor-dependent controls stay out of the release UI.
Column {
  id: root
  required property var service
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool advanced: false
  property Component connectionDetails: null
  property Component accountSection: null
  readonly property var primaryFocusTarget: countryPicker
  readonly property bool popupOpen: countryPicker.popupOpen
  spacing: Style.space(10)

  function closePopups() {
    countryPicker.close()
  }
  onVisibleChanged: if (!visible)
    closePopups()

  function selectCountry(code) {
    service.setCountry(code)
  }

  PanelSectionHeader {
    text: "LOCATION"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  SearchableDropdown {
    id: countryPicker
    objectName: "countryPicker"
    width: parent.width
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

  // Picking another country never reconnects on its own; this makes the
  // switch one deliberate click. connect replaces the live session in place.
  Button {
    objectName: "switchCountryButton"
    visible: root.service.switchAvailable
    width: parent.width
    iconText: ""
    text: "Switch to " + root.service.countryName
    focusable: true
    bordered: true
    enabled: !root.service.busy
    foreground: "#FFCE00"
    fontFamily: root.fontFamily
    tooltipText: "Reconnect through " + root.service.countryName + " (currently " + root.service.activeCountryName + ")"
    onClicked: root.service.connectTo(root.service.country)
  }

  Loader {
    width: parent.width
    sourceComponent: root.connectionDetails
  }

  Loader {
    width: parent.width
    sourceComponent: root.accountSection
  }

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  Button {
    objectName: "advancedToggle"
    text: "Settings"
    iconText: root.advanced ? "\uf106" : "\uf107"
    fontSize: Style.font.caption
    fontFamily: root.fontFamily
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
      text: "A connected tunnel is not a kill switch. Traffic is not blocked when the VPN disconnects."
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // Releases before 1.7 installed a root helper and an optional Polkit
    // rule. NetworkManager now owns the tunnel, so offer to remove both.
    Text {
      visible: root.service.legacyCleanupAvailable && root.service.legacyStatus !== ""
      width: parent.width
      text: root.service.legacyStatus
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Button {
      objectName: "removeLegacyHelper"
      visible: root.service.legacyCleanupAvailable
      text: "Remove old root helper…"
      focusable: true
      enabled: !root.service.busy
      foreground: root.foreground
      tooltipText: "Connections no longer need it. Opens a terminal that removes the helper and its Polkit rule with sudo."
      onClicked: root.service.openLegacyCleanup()
    }
  }
}
