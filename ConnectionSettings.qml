import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Countries.js" as Countries
import "Translations.js" as Translations

// Native WireGuard only. Vendor-dependent controls stay out of the release UI.
Column {
  id: root
  required property var service
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  readonly property string uiLanguage: typeof Commons.I18n !== "undefined" ? Commons.I18n.language : "en"
  property bool advanced: false
  property bool detailsExpanded: false
  property bool accountExpanded: false
  property Component connectionDetails: null
  property Component accountSection: null
  readonly property var primaryFocusTarget: countryPicker
  readonly property bool popupOpen: countryPicker.popupOpen
  spacing: Style.spacing.panelGap

  function closePopups() {
    countryPicker.close()
  }
  onVisibleChanged: if (!visible)
    closePopups()

  function selectCountry(code) {
    service.setCountry(code)
  }

  // The destination is a preference until the user explicitly connects.
  // Treat it as a separate, quiet card from the observed tunnel above.
  Column {
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      objectName: "locationHeader"
      text: Translations.t(root.service.connected ? "destination.next" : "destination.default", root.uiLanguage)
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Rectangle {
      width: parent.width
      implicitHeight: destinationContent.implicitHeight + Style.space(20)
      height: implicitHeight
      radius: Style.cornerRadius
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)

      Column {
        id: destinationContent
        x: Style.space(10)
        y: Style.space(10)
        width: parent.width - Style.space(20)
        spacing: Style.space(8)

        SearchableDropdown {
          id: countryPicker
          objectName: "countryPicker"
          width: parent.width
          Accessible.name: Translations.t("destination.accessible", root.uiLanguage)
          placeholderText: Translations.t("destination.search", root.uiLanguage)
          popupMinHeight: 0
          options: Countries.dropdownOptions()
          value: root.service.country
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !root.service.busy
          onChanged: function (value) { root.selectCountry(value) }
        }

        // Selecting a destination never reconnects automatically.
        Button {
          objectName: "switchCountryButton"
          visible: root.service.switchAvailable
          width: parent.width
          iconText: ""
          text: Translations.t("destination.switchTo", root.uiLanguage, root.service.countryName)
          focusable: true
          bordered: true
          enabled: !root.service.busy
          foreground: root.foreground
          fontFamily: root.fontFamily
          Accessible.name: text
          tooltipText: Translations.t("destination.switchTooltip", root.uiLanguage, [root.service.countryName, root.service.activeCountryName])
          onClicked: root.service.connectTo(root.service.country)
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSeparator {
      width: parent.width
      foreground: root.foreground
    }

    Button {
      objectName: "detailsToggle"
      width: parent.width
      text: Translations.t("destination.details", root.uiLanguage)
      iconText: root.detailsExpanded ? "\uf106" : "\uf107"
      fontSize: Style.font.bodySmall
      foreground: root.foreground
      fontFamily: root.fontFamily
      focusable: true
      selected: root.detailsExpanded
      Accessible.name: Translations.t(root.detailsExpanded ? "destination.hideDetails" : "destination.showDetails", root.uiLanguage)
      onClicked: root.detailsExpanded = !root.detailsExpanded
    }

    // No clipboard process, stats tree or account controls are constructed
    // until someone asks for the details. They are discarded on collapse.
    Loader {
      width: parent.width
      active: root.detailsExpanded && root.connectionDetails !== null
      visible: active
      sourceComponent: root.connectionDetails
    }

    Button {
      objectName: "accountToggle"
      width: parent.width
      visible: root.service.readyCreds
      // Identity and logout controls are available in the expanded section.
      // Keep the closed row compact, even for long account addresses.
      text: root.service.hideDetails ? Translations.t("destination.accountHidden", root.uiLanguage) : Translations.t("destination.account", root.uiLanguage)
      iconText: root.accountExpanded ? "\uf106" : "\uf107"
      fontSize: Style.font.bodySmall
      foreground: root.foreground
      fontFamily: root.fontFamily
      focusable: true
      selected: root.accountExpanded
      Accessible.name: Translations.t(root.accountExpanded ? "destination.hideAccount" : "destination.showAccount", root.uiLanguage)
      onClicked: root.accountExpanded = !root.accountExpanded
    }

    Loader {
      width: parent.width
      active: root.accountExpanded && root.service.readyCreds && root.accountSection !== null
      visible: active
      sourceComponent: root.accountSection
    }

    Button {
      objectName: "advancedToggle"
      width: parent.width
      text: Translations.t("destination.settings", root.uiLanguage)
      iconText: root.advanced ? "\uf106" : "\uf107"
      fontSize: Style.font.bodySmall
      fontFamily: root.fontFamily
      focusable: true
      selected: root.advanced
      foreground: root.foreground
      Accessible.name: Translations.t(root.advanced ? "destination.hideSettings" : "destination.showSettings", root.uiLanguage)
      onClicked: root.advanced = !root.advanced
    }

    Column {
      visible: root.advanced
      width: parent.width
      spacing: Style.space(10)

      Text {
        width: parent.width
        text: Translations.t("destination.killSwitch", root.uiLanguage)
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

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
        text: Translations.t("destination.removeLegacy", root.uiLanguage)
        focusable: true
        enabled: !root.service.busy
        foreground: root.foreground
        tooltipText: Translations.t("destination.removeLegacyTooltip", root.uiLanguage)
        onClicked: root.service.openLegacyCleanup()
      }
    }
  }
}
