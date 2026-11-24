pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Countries.js" as Countries
import "Translations.js" as Translations

// Presentation-only dashboard. The service, polling and IPC live in the bar
// widget; this tree is created when the popout opens for the first time.
Column {
  id: root
  required property var service
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool reduceMotion: Style.reduceMotion
  readonly property string uiLanguage: typeof Commons.I18n !== "undefined" ? Commons.I18n.language : "en"
  readonly property color accent: "#F4D45B"
  readonly property color subdued: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.70)
  readonly property bool transitional: service.connecting || service.disconnecting || service.resolvingAutomaticServer
  readonly property bool canToggle: service.setupDone && !service.busy && !service.statusUnknown && !service.statusProbeError
  readonly property bool switchTarget: service.connected && service.switchAvailable
  readonly property bool popupOpen: countryPicker.popupOpen
  readonly property var setupFocusTarget: setupCard.focusTarget
  property string openSection: ""
  signal toggleRequested()

  function t(key, values) {
    return Translations.t("redesign." + key, root.uiLanguage, values)
  }
  function closePopups() { countryPicker.close() }
  function clearPassword() {
    setupCard.clearPassword()
    const account = accountLoader.item as AccountSection
    if (account) account.clearPassword()
  }
  function copyIp() { footer.copyIp() }
  function goBack() {
    if (openSection !== "") { goTo(""); return true }
    return false
  }
  function goTo(section) {
    if (section === "account" && !service.readyCreds) return
    if (openSection === "account" && section !== "account") clearPassword()
    openSection = section
    countryPicker.close()
  }
  function toggleSection(section) { goTo(openSection === section ? "" : section) }

  spacing: Style.space(11)
  width: parent ? parent.width : Style.space(360)

  // The top bar has only two secondary destinations. Expose them directly:
  // no extra menu or second level of navigation for Account / Settings.
  Item {
    width: parent.width
    height: Style.space(30)

    PanelActionButton {
      id: backButton
      objectName: "vpnBack"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      visible: root.openSection !== ""
      iconText: ""
      focusable: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      tooltipText: root.t("menu.back")
      Accessible.role: Accessible.Button
      Accessible.name: tooltipText
      onClicked: root.goBack()
    }

    Text {
      anchors.left: backButton.visible ? backButton.right : parent.left
      anchors.leftMargin: backButton.visible ? Style.space(8) : 0
      anchors.right: headerActions.visible ? headerActions.left : parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: root.openSection === "" ? root.t("header.label").toUpperCase() : root.t("menu." + root.openSection)
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.openSection === "" ? Style.font.bodySmall : Style.font.subtitle
      font.weight: Font.DemiBold
      font.letterSpacing: root.openSection === "" ? 0.9 : 0
      elide: Text.ElideRight
    }

    Row {
      id: headerActions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.service.setupDone
      spacing: Style.space(4)

      PanelActionButton {
        objectName: "vpnAccountShortcut"
        iconText: ""
        focusable: true
        enabled: root.service.readyCreds
        bordered: root.openSection === "account"
        hasCursor: root.openSection === "account" || activeFocus
        foreground: root.foreground
        fontFamily: root.fontFamily
        tooltipText: root.t("menu.account")
        Accessible.role: Accessible.Button
        Accessible.name: tooltipText
        Accessible.description: root.openSection === "account" ? root.t("menu.back") : ""
        onClicked: root.toggleSection("account")
      }

      PanelActionButton {
        objectName: "vpnSettingsShortcut"
        iconText: ""
        focusable: true
        bordered: root.openSection === "settings"
        hasCursor: root.openSection === "settings" || activeFocus
        foreground: root.foreground
        fontFamily: root.fontFamily
        tooltipText: root.t("menu.settings")
        Accessible.role: Accessible.Button
        Accessible.name: tooltipText
        Accessible.description: root.openSection === "settings" ? root.t("menu.back") : ""
        onClicked: root.toggleSection("settings")
      }
    }
  }

  ConnectionStage {
    id: stage
    objectName: "vpnConnectionStage"
    visible: root.openSection === ""
    compact: true
    width: parent.width
    service: root.service
    foreground: root.foreground
    fontFamily: root.fontFamily
    language: root.uiLanguage
    disableAnimation: root.reduceMotion
  }

  // Reserve the strong alert surface for actionable problems only. The hero
  // already explains loading/success; a second notification repeats it.
  StatusNotice {
    width: parent.width
    visible: root.openSection === "" && message !== ""
    service: root.service
    foreground: root.foreground
    fontFamily: root.fontFamily
    showInformational: false
  }

  SetupCard {
    id: setupCard
    width: parent.width
    visible: root.openSection === "" && root.service.setupCardState !== "ready"
    service: root.service
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Column {
    width: parent.width
    visible: root.service.setupDone && root.openSection === ""
    spacing: Style.space(9)

    Row {
      width: parent.width
      spacing: Style.space(4)

      Text {
        objectName: "dashboardLocationLabel"
        text: root.t(root.service.connected ? "location.next" : "location.label").toUpperCase()
        textFormat: Text.PlainText
        color: root.subdued
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 0.8
      }
    }

    Item {
      width: parent.width
      height: Math.max(countryPicker.implicitHeight, selectedStar.implicitHeight)

      SearchableDropdown {
        id: countryPicker
        objectName: "dashboardCountryPicker"
        width: parent.width - selectedStar.width - Style.space(6)
        showLabel: false
        popupMinHeight: 0
        Accessible.name: Translations.t("destination.accessible", root.uiLanguage)
        placeholderText: Translations.t("destination.search", root.uiLanguage)
        options: Countries.dropdownOptions()
        value: root.service.country
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.service.busy
        onChanged: function(value) {
          root.service.setCountry(value)
          // The host writes its own value when choosing an option. Restore
          // the binding so shortcuts/external preference changes stay in sync.
          countryPicker.value = Qt.binding(function() { return root.service.country })
        }
      }

      PanelActionButton {
        id: selectedStar
        objectName: "quickFavoriteSelected"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        size: Math.max(Style.space(30), countryPicker.implicitHeight)
        iconText: quickDestinations.selectedFavorite ? "★" : "☆"
        enabled: !root.service.busy && quickDestinations.selectedCode !== ""
          && (quickDestinations.selectedFavorite || quickDestinations.favoriteCodes.length < 8)
        tooltipText: root.t(quickDestinations.selectedFavorite ? "favorites.remove" : "favorites.add", root.service.countryName)
        Accessible.role: Accessible.Button
        Accessible.name: tooltipText
        focusable: true
        bordered: quickDestinations.selectedFavorite
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: quickDestinations.toggle(quickDestinations.selectedCode)
      }
    }

    // One primary action for the next meaningful step. When a different
    // country is selected during an active session, switching outranks
    // disconnecting; disconnect remains an explicit, quieter action.
    Button {
      id: primaryAction
      objectName: "vpnPrimaryAction"
      width: parent.width
      height: Style.space(44)
      visible: !root.service.statusUnknown && !root.service.statusProbeError
      focusable: true
      bordered: root.service.connected && !root.switchTarget
      enabled: root.canToggle
      background: root.transitional || (root.service.connected && !root.switchTarget)
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : root.accent
      // The host replaces the fill on hover/focus/press. Use its matching
      // theme foreground rather than leaving the yellow-fill's dark label.
      foreground: root.transitional || (root.service.connected && !root.switchTarget)
        || activeFocus || hot ? root.foreground : "#141414"
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      text: root.service.disconnecting ? root.t("action.disconnecting")
        : root.service.connecting || root.service.resolvingAutomaticServer ? root.t("action.connecting")
        : root.switchTarget ? root.t("action.switchTo", root.service.countryName)
        : root.service.connected ? root.t("action.disconnect") : root.t("action.connectTo", root.service.countryName)
      iconText: root.transitional ? "" : root.switchTarget ? "" : root.service.connected ? "" : ""
      iconSpinning: root.transitional && !root.reduceMotion
      Accessible.name: text
      tooltipText: root.transitional ? text
        : root.switchTarget ? root.t("action.switchTo", root.service.countryName)
        : root.service.connected ? Translations.t("panel.disconnectVPN", root.uiLanguage) : root.t("action.connectTo", root.service.countryName)
      onClicked: {
        if (!root.canToggle) return
        if (root.switchTarget) root.service.connectTo(root.service.country)
        else root.toggleRequested()
      }
    }

    Button {
      objectName: "vpnDisconnectSecondary"
      width: parent.width
      visible: root.switchTarget
      focusable: true
      enabled: root.canToggle
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      foreground: root.foreground
      text: root.t("action.disconnect")
      iconText: ""
      Accessible.name: text
      onClicked: if (root.canToggle) root.service.disconnect()
    }

    QuickDestinations {
      id: quickDestinations
      objectName: "vpnQuickDestinations"
      width: parent.width
      service: root.service
      foreground: root.foreground
      fontFamily: root.fontFamily
      language: root.uiLanguage
    }

  }

  Item {
    width: parent.width
    height: Style.space(1)
    visible: root.service.setupDone && root.openSection === ""
    Rectangle {
      anchors.fill: parent
      color: root.foreground
      opacity: 0.12
    }
  }

  ConnectionSummary {
    id: footer
    width: parent.width
    visible: root.service.setupDone && root.openSection === ""
    compact: true
    showSelectedDestination: false
    service: root.service
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Button {
    objectName: "vpnOpenDetails"
    width: parent.width
    visible: root.service.setupDone && root.openSection === ""
    focusable: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    text: root.t("menu.details")
    iconText: ""
    tooltipText: root.t("menu.detailsHint")
    Accessible.name: tooltipText
    onClicked: root.goTo("details")
  }

  Text {
    visible: root.openSection === "details"
    width: parent.width
    text: root.service.statusObservedAt > 0 ? root.t("details.lastCheck", Qt.formatDateTime(new Date(root.service.statusObservedAt), "HH:mm:ss")) : root.t("details.notChecked")
    textFormat: Text.PlainText
    color: root.subdued
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // Load standalone components by URL: Qt 6.4 rejects sourceComponent for a
  // Component declared in this `ComponentBehavior: Bound` file. Required
  // properties are supplied at creation and reactive ones rebound on load.
  Loader {
    id: detailsLoader
    width: parent.width
    active: root.service.setupDone && root.openSection === "details"
    visible: active
    onLoaded: {
      const view = item as ConnectionDetails
      if (!view)
        return
      view.foreground = Qt.binding(function() { return root.foreground })
      view.fontFamily = Qt.binding(function() { return root.fontFamily })
      view.width = Qt.binding(function() { return detailsLoader.width })
    }
    function sync() {
      if (!active) {
        source = ""
        return
      }
      setSource(Qt.resolvedUrl("ConnectionDetails.qml"), {
        "service": root.service,
        "showHeading": false,
        "technicalOnly": false
      })
    }
    onActiveChanged: sync()
    Component.onCompleted: sync()
  }

  Loader {
    id: accountLoader
    width: parent.width
    active: root.service.setupDone && root.service.readyCreds && root.openSection === "account"
    visible: active
    onLoaded: {
      const view = item as AccountSection
      if (!view)
        return
      view.foreground = Qt.binding(function() { return root.foreground })
      view.fontFamily = Qt.binding(function() { return root.fontFamily })
      view.width = Qt.binding(function() { return accountLoader.width })
    }
    function sync() {
      if (!active) {
        source = ""
        return
      }
      setSource(Qt.resolvedUrl("AccountSection.qml"), {
        "service": root.service,
        "showHeading": false
      })
    }
    onActiveChanged: sync()
    Component.onCompleted: sync()
  }

  Column {
    visible: root.service.setupDone && root.openSection === "settings"
    width: parent.width
    spacing: Style.space(9)

    Button {
      objectName: "vpnPrivacySetting"
      width: parent.width
      focusable: true
      bordered: true
      selected: root.service.hideDetails
      text: root.t("settings.hideDetails")
      iconText: root.service.hideDetails ? "☑" : "☐"
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      Accessible.role: Accessible.CheckBox
      Accessible.name: text
      Accessible.checkable: true
      Accessible.checked: root.service.hideDetails
      onClicked: root.service.setHideDetails(!root.service.hideDetails)
    }

    Text {
      width: parent.width
      text: root.t("settings.privacyHint")
      textFormat: Text.PlainText
      color: root.subdued
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      text: Translations.t("destination.killSwitch", root.uiLanguage)
      textFormat: Text.PlainText
      color: root.subdued
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
      visible: root.service.legacyCleanupAvailable
      width: parent.width
      focusable: true
      enabled: !root.service.busy
      bordered: true
      text: Translations.t("destination.removeLegacy", root.uiLanguage)
      tooltipText: Translations.t("destination.removeLegacyTooltip", root.uiLanguage)
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.service.openLegacyCleanup()
    }
  }
}
