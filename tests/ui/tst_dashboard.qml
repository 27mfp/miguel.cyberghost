import QtQuick
import QtTest
import "../.." as Plugin

// All actions end at a synthetic service. No Process or VPN operation is started.
TestCase {
  id: testCase
  name: "VpnDashboardBehavior"
  visible: true
  when: windowShown
  width: 390
  height: 1100

  QtObject {
    id: vpn
    property bool setupDone: true
    property string setupCardState: "ready"
    property bool readyNm: true
    property bool readyNetwork: true
    property bool readyRequests: true
    property bool readyCreds: true
    property bool depsBusy: false
    property bool regBusy: false
    property bool busy: false
    property bool connected: false
    property bool connecting: false
    property bool disconnecting: false
    property bool resolvingAutomaticServer: false
    property bool statusUnknown: false
    property string statusProbeError: ""
    property bool tunnelStale: false
    property bool legacyTunnel: false
    property string rawStatusText: "{\"connected\":false}"
    property string country: "PT"
    property string countryName: "Portugal"
    property string activeCountryName: ""
    property bool switchAvailable: false
    property real statusObservedAt: 0
    property var favoriteCountries: []
    property var recentCountries: []
    property string publicIp: ""
    property bool fetchingIp: false
    property bool hideDetails: false
    property string publicCity: ""
    property string publicCountry: ""
    property string publicOrg: ""
    property string activeServer: ""
    property string endpoint: ""
    property real rxRate: -1
    property real txRate: -1
    property real rxBytes: 0
    property real txBytes: 0
    property real rxIdleSec: 0
    property string setupMsg: ""
    property string lastError: ""
    property string actionStatus: ""
    property string applyHint: ""
    property string accountSource: "native"
    property string accountName: "Example"
    property bool syncingServers: false
    property string serverList: ""
    property int syncProgress: 0
    property bool legacyCleanupAvailable: false
    property string legacyStatus: ""
    property int countryCalls: 0
    property int connectCalls: 0
    property int disconnectCalls: 0
    property int toggleCalls: 0
    property int refreshCalls: 0
    property int favoriteCalls: 0
    property string connectTarget: ""

    function setCountry(value) {
      countryCalls++
      country = value
      countryName = value === "ES" ? "Spain" : "Portugal"
    }
    function connectTo(value) {
      connectCalls++
      connectTarget = value
    }
    function disconnect() { disconnectCalls++ }
    function toggleFavorite(code) {
      favoriteCalls++
      const favorites = favoriteCountries.slice()
      const found = favorites.indexOf(code)
      if (found >= 0) favorites.splice(found, 1)
      else favorites.push(code)
      favoriteCountries = favorites
      return true
    }
    function setHideDetails(value) { hideDetails = value }
    function recheck() { refreshCalls++ }
    function openLegacyCleanup() {}
    function logout() {}
  }

  Component {
    id: dashboardFactory
    Plugin.VpnDashboard {
      width: 370
      service: vpn
      onToggleRequested: vpn.toggleCalls++
    }
  }

  Component {
    id: stageFactory
    Plugin.ConnectionStage {
      width: 370
      service: vpn
      language: "en"
    }
  }

  function init() {
    vpn.setupDone = true
    vpn.setupCardState = "ready"
    vpn.readyNetwork = true
    vpn.readyNm = true
    vpn.readyRequests = true
    vpn.readyCreds = true
    vpn.busy = false
    vpn.connected = false
    vpn.connecting = false
    vpn.disconnecting = false
    vpn.resolvingAutomaticServer = false
    vpn.statusUnknown = false
    vpn.statusProbeError = ""
    vpn.tunnelStale = false
    vpn.legacyTunnel = false
    vpn.rawStatusText = "{\"connected\":false}"
    vpn.country = "PT"
    vpn.countryName = "Portugal"
    vpn.activeCountryName = ""
    vpn.switchAvailable = false
    vpn.publicIp = ""
    vpn.lastError = ""
    vpn.actionStatus = ""
    vpn.setupMsg = ""
    vpn.countryCalls = 0
    vpn.connectCalls = 0
    vpn.disconnectCalls = 0
    vpn.toggleCalls = 0
    vpn.refreshCalls = 0
    vpn.connectTarget = ""
    vpn.favoriteCountries = []
    vpn.recentCountries = []
    vpn.favoriteCalls = 0
    vpn.hideDetails = false
  }

  // Repeater delegates do not have objectName; find them by their actual labels.
  function buttonNamed(node, label) {
    if (!node) return null
    if (node.text === label && typeof node.clicked === "function") return node
    const items = node.children || []
    for (let i = 0; i < items.length; i++) {
      const found = buttonNamed(items[i], label)
      if (found) return found
    }
    return null
  }

  function effectivelyVisible(item) {
    for (let current = item; current; current = current.parent) {
      if (!current.visible) return false
    }
    return true
  }

  function test_selectingCountryOnlyUpdatesPreference() {
    const dashboard = createTemporaryObject(dashboardFactory, this)
    verify(dashboard !== null)
    const picker = findChild(dashboard, "dashboardCountryPicker")
    const primary = findChild(dashboard, "vpnPrimaryAction")
    verify(picker !== null && primary !== null)
    compare(dashboard.openSection, "")
    compare(vpn.toggleCalls, 0)
    picker.changed("ES")
    compare(vpn.countryCalls, 1)
    compare(vpn.country, "ES")
    compare(vpn.connectCalls, 0)
    compare(vpn.toggleCalls, 0)
    verify(primary.text.indexOf("Spain") >= 0)
    mouseClick(primary)
    compare(vpn.toggleCalls, 1)
    compare(vpn.connectCalls, 0)
  }

  function test_countrySwitchBecomesPrimaryWithExplicitDisconnect() {
    vpn.connected = true
    vpn.activeCountryName = "Portugal"
    const dashboard = createTemporaryObject(dashboardFactory, this)
    const picker = findChild(dashboard, "dashboardCountryPicker")
    const primary = findChild(dashboard, "vpnPrimaryAction")
    const secondary = findChild(dashboard, "vpnDisconnectSecondary")
    verify(primary !== null && secondary !== null)
    verify(!secondary.visible)
    compare(primary.text, "Disconnect")
    picker.changed("ES")
    vpn.switchAvailable = true
    verify(secondary.visible)
    compare(vpn.connectCalls, 0)
    compare(vpn.toggleCalls, 0)
    verify(primary.text.indexOf("Spain") >= 0)
    primary.clicked()
    compare(vpn.connectCalls, 1)
    compare(vpn.connectTarget, "ES")
    compare(vpn.toggleCalls, 0)
    secondary.clicked()
    compare(vpn.disconnectCalls, 1)
  }

  function test_stageUsesObservedStateRatherThanPublicIp() {
    vpn.publicIp = "203.0.113.42"
    vpn.activeCountryName = "Portugal"
    const stage = createTemporaryObject(stageFactory, this)
    verify(stage !== null)
    compare(stage.stateKind, "disconnected")
    verify(!stage.connectedVerified)
    vpn.connected = true
    compare(stage.stateKind, "connected")
    verify(stage.connectedVerified)
    verify(stage.subtitle.indexOf("Portugal") >= 0)
    vpn.tunnelStale = true
    compare(stage.stateKind, "stale")
    verify(!stage.connectedVerified)
    vpn.statusUnknown = true
    compare(stage.stateKind, "unknown")
    verify(!stage.connectedVerified)
    vpn.statusUnknown = false
    vpn.tunnelStale = false
    vpn.connected = false
    vpn.legacyTunnel = true
    compare(stage.stateKind, "legacy")
  }

  function test_setupHidesConnectionActionsUntilReady() {
    vpn.setupDone = false
    vpn.setupCardState = "first-run"
    vpn.readyRequests = false
    vpn.readyCreds = false
    const dashboard = createTemporaryObject(dashboardFactory, this)
    const primary = findChild(dashboard, "vpnPrimaryAction")
    const picker = findChild(dashboard, "dashboardCountryPicker")
    const stage = findChild(dashboard, "vpnConnectionStage")
    verify(primary !== null && picker !== null && stage !== null)
    verify(!effectivelyVisible(primary))
    verify(!effectivelyVisible(picker))
    compare(stage.stateKind, "setup")
    vpn.readyRequests = true
    vpn.readyCreds = true
    vpn.setupDone = true
    vpn.setupCardState = "ready"
    verify(effectivelyVisible(primary))
    verify(effectivelyVisible(picker))
    verify(primary.enabled)
    compare(stage.stateKind, "disconnected")
    compare(vpn.toggleCalls, 0)
  }

  function test_disclosureMenusOpenIndividually() {
    const dashboard = createTemporaryObject(dashboardFactory, this)
    verify(dashboard !== null)
    const details = findChild(dashboard, "vpnOpenDetails")
    const back = findChild(dashboard, "vpnBack")
    const account = findChild(dashboard, "vpnAccountShortcut")
    const settings = findChild(dashboard, "vpnSettingsShortcut")
    verify(details !== null && back !== null && account !== null && settings !== null)
    compare(findChild(dashboard, "vpnMoreMenu"), null)
    verify(effectivelyVisible(account) && effectivelyVisible(settings))
    compare(account.Accessible.name, "Account")
    compare(settings.Accessible.name, "Settings")
    verify(!account.bordered && !settings.bordered)
    compare(dashboard.openSection, "")
    mouseClick(details)
    compare(dashboard.openSection, "details")
    tryVerify(function() { return findChild(dashboard, "copyIpButton") !== null })
    verify(back.visible)
    // Header actions remain available from the details subpage.
    settings.clicked()
    compare(dashboard.openSection, "settings")
    verify(settings.bordered && !account.bordered)
    tryVerify(function() { return findChild(dashboard, "copyIpButton") === null })
    settings.clicked()
    compare(dashboard.openSection, "")
    verify(!settings.bordered)
    vpn.readyCreds = false
    verify(!account.enabled)
    vpn.readyCreds = true
    verify(account.enabled)
    account.clicked()
    compare(dashboard.openSection, "account")
    verify(account.bordered && !settings.bordered)
    tryVerify(function() { return findChild(dashboard, "logoutButton") !== null })
    back.clicked()
    compare(dashboard.openSection, "")
  }

  function test_unknownStateHidesUnsafeActionAndOffersRecovery() {
    vpn.statusUnknown = true
    vpn.statusProbeError = "Unable to verify status"
    const dashboard = createTemporaryObject(dashboardFactory, this)
    const primary = findChild(dashboard, "vpnPrimaryAction")
    const recheck = findChild(dashboard, "statusRecheck")
    verify(primary !== null && recheck !== null)
    verify(!effectivelyVisible(primary))
    verify(effectivelyVisible(recheck))
    compare(vpn.connectCalls, 0)
    compare(vpn.toggleCalls, 0)
    recheck.clicked()
    compare(vpn.refreshCalls, 1)
  }

  function test_mobileWidthsKeepPrimaryControlsWithinPanel() {
    for (const width of [320, 375, 400]) {
      const dashboard = createTemporaryObject(dashboardFactory, this, {width: width})
      verify(dashboard !== null)
      const primary = findChild(dashboard, "vpnPrimaryAction")
      const picker = findChild(dashboard, "dashboardCountryPicker")
      const quick = findChild(dashboard, "vpnQuickDestinations")
      verify(primary !== null && picker !== null && quick !== null)
      compare(primary.width, width)
      const star = findChild(dashboard, "quickFavoriteSelected")
      verify(picker.width > width / 2)
      verify(picker.width + star.width <= width)
      compare(quick.width, width)
      verify(dashboard.implicitHeight > 0)
    }
  }

  function test_subpageBackRestoresDashboardWithoutConnecting() {
    const dashboard = createTemporaryObject(dashboardFactory, this)
    dashboard.goTo("details")
    compare(dashboard.openSection, "details")
    verify(dashboard.goBack())
    compare(dashboard.openSection, "")
    dashboard.toggleSection("settings")
    compare(dashboard.openSection, "settings")
    dashboard.toggleSection("settings")
    compare(dashboard.openSection, "")
    verify(!dashboard.goBack())
    compare(vpn.connectCalls, 0)
    compare(vpn.toggleCalls, 0)
  }

  function test_primaryLabelFollowsHostInteractionFill() {
    const dashboard = createTemporaryObject(dashboardFactory, this)
    const primary = findChild(dashboard, "vpnPrimaryAction")
    primary.forceActiveFocus()
    compare(primary.foreground, dashboard.foreground)
    findChild(dashboard, "vpnSettingsShortcut").forceActiveFocus()
    primary.hasCursor = true
    compare(primary.foreground, dashboard.foreground)
    primary.hasCursor = false
    compare(primary.foreground, "#141414")
    vpn.connected = true
    compare(primary.foreground, dashboard.foreground)
  }

  function test_pickerKeepsFollowingTheServiceAfterUserSelection() {
    const dashboard = createTemporaryObject(dashboardFactory, this)
    const picker = findChild(dashboard, "dashboardCountryPicker")
    // The real host assigns value before emitting changed, removing a plain binding.
    picker.value = "ES"
    picker.changed("ES")
    compare(picker.value, "ES")
    vpn.setCountry("PT")
    compare(picker.value, "PT")
    verify(findChild(dashboard, "vpnPrimaryAction").text.indexOf("Portugal") >= 0)
    compare(vpn.connectCalls, 0)
  }

  function test_favoritesStayOutsideThePrimaryFlow() {
    const dashboard = createTemporaryObject(dashboardFactory, this)
    const quick = findChild(dashboard, "vpnQuickDestinations")
    const star = findChild(dashboard, "quickFavoriteSelected")
    const primary = findChild(dashboard, "vpnPrimaryAction")
    verify(!quick.visible)
    star.clicked()
    compare(vpn.favoriteCalls, 1)
    verify(quick.visible)
    wait(0)
    verify(quick.mapToItem(dashboard, 0, 0).y >= primary.mapToItem(dashboard, 0, primary.height).y)
    verify(star.tooltipText.indexOf("Remove Portugal") >= 0)
    compare(vpn.connectCalls, 0)
    compare(vpn.toggleCalls, 0)
    star.clicked()
    verify(!quick.visible)
    vpn.favoriteCountries = ["ES", "FR", "DE", "GB", "US", "IT", "NL", "SE"]
    verify(!star.enabled)
  }

  function test_settingsPrivacyAndDetailsUtilities() {
    const dashboard = createTemporaryObject(dashboardFactory, this)
    dashboard.goTo("settings")
    const privacy = findChild(dashboard, "vpnPrivacySetting")
    verify(privacy.visible)
    privacy.clicked()
    verify(vpn.hideDetails && privacy.selected)
    privacy.clicked()
    verify(!vpn.hideDetails)
    dashboard.goTo("details")
    tryVerify(function() { return findChild(dashboard, "privacyToggle") !== null })
    verify(findChild(dashboard, "privacyToggle").visible)
    verify(findChild(dashboard, "copyIpButton").visible)
    verify(!findChild(dashboard, "detailsHeader").visible)
  }
}
