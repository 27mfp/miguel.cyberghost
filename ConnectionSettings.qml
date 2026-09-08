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
  property Component primaryActions: null
  readonly property var primaryFocusTarget: actions.item ? actions.item["focusTarget"] : null
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
