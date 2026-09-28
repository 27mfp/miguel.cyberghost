import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  name: "PluginFlow"
  when: windowShown
  visible: true
  width: 420
  height: 800

  QtObject {
    id: mockService
    property string setupCardState: "first-run"
    property bool readyNm: true
    property bool readyNetwork: true
    property bool readyRequests: false
    property bool readyCreds: false
    property bool busy: false
    property bool regBusy: false
    property string setupMsg: ""
    property string country: "PT"
    property string countryName: "Portugal"
    property string protocol: "wireguard"
    property string serverType: "traffic"
    property string serverSelection: "fastest"
    property var serverOptions: []
    property bool loadingServers: false
    property string serverError: ""
    property bool readyCli: false
    property bool cliConfigured: false
    property bool streamingBusy: false
    property var streamingOptions: []
    property string streamingService: ""
    property string streamingError: ""
    property bool switchAvailable: false
    property string activeCountryName: "Portugal"
    property string lastConnectTarget: ""
    property bool legacyCleanupAvailable: false
    property string legacyStatus: ""
    property int legacyCleanupCalls: 0
    property bool connected: false
    property int connectCalls: 0
    property int countryCalls: 0
    function setCountry(value) {
      country = value
      countryCalls++
    }
    function connectTo(target) {
      connectCalls++
      lastConnectTarget = target || ""
    }
    function setProtocol(value) {
      protocol = value
    }
    function setServerType(value) {
      serverType = value
    }
    function setServerSelection(value) {
      serverSelection = value
    }
    function setStreamingService(value) {
      streamingService = value
    }
    function openLegacyCleanup() {
      legacyCleanupCalls++
    }
    function registerAccount(user, password) {
      setupMsg = user + ":" + password
    }
  }

  Component {
    id: setupFactory
    Plugin.SetupCard {
      width: 380
      service: mockService
    }
  }
  Component {
    id: preferencesFactory
    Plugin.ConnectionSettings {
      width: 380
      service: mockService
    }
  }

  function init() {
    mockService.readyNm = true
    mockService.readyNetwork = true
    mockService.readyRequests = false
    mockService.readyCreds = false
    mockService.setupCardState = "first-run"
    mockService.setupMsg = ""
    mockService.country = "PT"
    mockService.countryCalls = 0
    mockService.legacyCleanupAvailable = false
    mockService.switchAvailable = false
    mockService.legacyCleanupCalls = 0
    mockService.connectCalls = 0
  }

  function test_setupRequiredActionsStayReachable() {
    var card = createTemporaryObject(setupFactory, this)
    verify(card !== null)
    tryVerify(function () {
      return card.implicitHeight > 0
    })
    compare(card.focusTarget.objectName, "installDependencies")
    mockService.readyRequests = true
    compare(card.focusTarget.objectName, "accountUsername")
    mockService.readyCreds = true
    compare(card.focusTarget.objectName, "recheckSetup")
    mockService.readyCreds = false
    // NetworkManager is Omarchy's own service: it is explained, never installed.
    mockService.readyNetwork = false
    mockService.readyNm = false
    verify(findChild(card, "networkRequirement").visible)
    verify(!findChild(card, "installDependencies").visible)
    verify(findChild(card, "networkRequirement").text.indexOf("NetworkManager") >= 0)
    mockService.readyNm = true
    verify(findChild(card, "networkRequirement").text.indexOf("not allowed") >= 0)
    mockService.readyNetwork = true
    mockService.readyCreds = true
    mockService.setupCardState = "ready"
    tryCompare(card, "implicitHeight", 0)
    mockService.setupCardState = "first-run"
    mockService.readyRequests = false
    mockService.readyCreds = false
  }

  function test_legacyHelperRemovalIsOfferedOnlyWhenPresent() {
    var controls = createTemporaryObject(preferencesFactory, this)
    controls.advanced = true
    var button = findChild(controls, "removeLegacyHelper")
    verify(button !== null)
    verify(!button.visible)
    mockService.legacyCleanupAvailable = true
    verify(button.visible)
    button.clicked()
    compare(mockService.legacyCleanupCalls, 1)
  }

  function test_accountFormValidatesAndClearsPassword() {
    mockService.readyRequests = true
    mockService.readyCreds = false
    mockService.setupMsg = ""
    var card = createTemporaryObject(setupFactory, this)
    verify(card !== null)
    var user = findChild(card, "accountUsername")
    var password = findChild(card, "accountPassword")
    var submit = findChild(card, "linkAccount")
    verify(password !== null)
    verify(submit !== null)
    // Like Omarchy's network prompt, the action waits for complete input.
    verify(!submit.enabled)
    compare(password.echoMode, TextInput.Password)
    password.forceActiveFocus()
    keyClick(Qt.Key_Return)
    compare(mockService.setupMsg, "Enter your CyberGhost username and password.")
    verify(user.activeFocus)
    user.text = "demo"
    verify(!submit.enabled)
    password.text = "secret"
    verify(submit.enabled)
    mouseClick(submit)
    compare(mockService.setupMsg, "demo:secret")
    compare(password.text, "")
    mockService.readyRequests = false
  }

  function test_checklistMarksProgressAndOnlyShowsCurrentActions() {
    mockService.readyRequests = false
    var card = createTemporaryObject(setupFactory, this)
    var install = findChild(card, "installDependencies")
    verify(install.visible)
    verify(!findChild(card, "accountUsername").visible)
    compare(findChild(card, "networkStep").done, true)
    compare(findChild(card, "requestsStep").current, true)
    compare(findChild(card, "accountStep").current, false)
    mockService.readyRequests = true
    verify(!install.visible)
    compare(findChild(card, "accountStep").current, true)
    compare(card.focusTarget.objectName, "accountUsername")
    mockService.readyRequests = false
  }

  function test_setupMessageIsNeutralWhileBusyAndUrgentAfter() {
    mockService.readyRequests = true
    var card = createTemporaryObject(setupFactory, this)
    var message = findChild(card, "setupMessage")
    mockService.setupMsg = "Finish installing in the terminal."
    mockService.busy = true
    verify(message.visible)
    verify(!Qt.colorEqual(message.color, "#ff7777"))
    mockService.busy = false
    mockService.setupMsg = "Authentication failed"
    verify(Qt.colorEqual(message.color, "#ff7777"))
    mockService.setupMsg = ""
    mockService.readyRequests = false
  }

  function test_hidingSetupClearsUnsubmittedPassword() {
    var setup = createTemporaryObject(setupFactory, this)
    var password = findChild(setup, "accountPassword")
    password.text = "never-save-this"
    setup.visible = false
    compare(password.text, "")
  }

  function test_hiddenSettingsCloseTheirDropdowns() {
    var controls = createTemporaryObject(preferencesFactory, this)
    var picker = findChild(controls, "countryPicker")
    picker.open()
    compare(controls.popupOpen, true)
    controls.visible = false
    compare(controls.popupOpen, false)
  }

  function test_vendorControlsAreAbsentEvenWhenCliIsReady() {
    var controls = createTemporaryObject(preferencesFactory, this)
    controls.advanced = true
    var names = ["modePicker", "protocolPicker", "streamingPicker", "serverPicker"]
    for (var i = 0; i < names.length; i++)
      compare(findChild(controls, names[i]), null)
  }

  function test_advancedCollapsedAndCountrySelectionDoesNotConnect() {
    var controls = createTemporaryObject(preferencesFactory, this)
    verify(controls !== null)
    compare(controls.advanced, false)
    var heightBefore = controls.implicitHeight
    controls.advanced = true
    tryVerify(function () {
      return controls.implicitHeight > heightBefore
    })
    var picker = findChild(controls, "countryPicker")
    verify(picker !== null)
    picker.changed("ES")
    compare(mockService.country, "ES")
    compare(mockService.connectCalls, 0)
    compare(mockService.countryCalls, 1)
  }

  function test_switchCountryIsExplicit() {
    var controls = createTemporaryObject(preferencesFactory, this)
    var button = findChild(controls, "switchCountryButton")
    verify(!button.visible)
    mockService.country = "ES"
    mockService.countryName = "Spain"
    mockService.switchAvailable = true
    verify(button.visible)
    compare(button.text, "Switch to Spain")
    compare(mockService.connectCalls, 0)
    button.clicked()
    compare(mockService.connectCalls, 1)
    compare(mockService.lastConnectTarget, "ES")
    mockService.countryName = "Portugal"
  }
}
