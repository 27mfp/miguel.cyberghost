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
    property bool readyWg: false
    property bool readyDns: true
    property bool readyRequests: false
    property bool readyCreds: false
    property bool helperInstalled: false
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
    property bool readyPolkit: false
    property bool polkitRuleDismissed: true
    property bool connected: false
    property int connectCalls: 0
    property int countryCalls: 0
    function setCountry(value) {
      country = value
      countryCalls++
    }
    function connectTo() {
      connectCalls++
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
    mockService.readyDns = true
    mockService.readyWg = false
    mockService.readyRequests = false
    mockService.readyCreds = false
    mockService.setupCardState = "first-run"
    mockService.setupMsg = ""
    mockService.country = "PT"
    mockService.countryCalls = 0
    mockService.connectCalls = 0
  }

  function test_setupRequiredActionsStayReachable() {
    var card = createTemporaryObject(setupFactory, this)
    verify(card !== null)
    tryVerify(function () {
      return card.implicitHeight > 0
    })
    verify(card.focusTarget !== null)
    compare(card.focusTarget.objectName, "installDependencies")
    mockService.readyWg = true
    mockService.readyRequests = true
    mockService.readyDns = false
    compare(card.focusTarget.objectName, "installDependencies")
    mockService.readyDns = true
    compare(card.focusTarget.objectName, "accountUsername")
    mockService.readyCreds = true
    compare(card.focusTarget.objectName, "installHelper")
    mockService.setupCardState = "ready"
    tryCompare(card, "implicitHeight", 0)
    mockService.setupCardState = "first-run"
    mockService.readyWg = false
    mockService.readyRequests = false
    mockService.readyCreds = false
  }

  function test_accountFormValidatesAndClearsPassword() {
    mockService.readyWg = true
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
    mouseClick(submit)
    compare(mockService.setupMsg, "Enter your CyberGhost username and password.")
    verify(user.activeFocus)
    user.text = "demo"
    password.text = "secret"
    mouseClick(submit)
    compare(mockService.setupMsg, "demo:secret")
    compare(password.text, "")
    mockService.readyWg = false
    mockService.readyRequests = false
  }

  function test_hiddenSettingsCloseTheirDropdowns() {
    var controls = createTemporaryObject(preferencesFactory, this)
    var picker = findChild(controls, "countryPicker")
    picker.open()
    compare(controls.popupOpen, true)
    controls.visible = false
    compare(controls.popupOpen, false)
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
}
