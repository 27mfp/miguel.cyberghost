import QtQuick
import QtTest
import "../.." as Plugin

// No real account, package manager or NetworkManager process is used here.
TestCase {
  id: testCase
  name: "FirstRunOnboarding"
  visible: true
  when: windowShown
  width: 380
  height: 760

  QtObject {
    id: vpn
    property string setupCardState: "first-run"
    property bool readyNm: false
    property bool readyNetwork: false
    property bool readyRequests: false
    property bool readyCreds: false
    property bool depsBusy: false
    property bool regBusy: false
    property bool busy: false
    property bool connected: false
    property string setupMsg: ""
    property int recheckCalls: 0
    property int installCalls: 0
    property int linkCalls: 0
    property int disconnectCalls: 0
    property string linkedUsername: ""
    property string linkedPassword: ""

    function recheck() { recheckCalls++ }
    function installDeps() { installCalls++ }
    function registerAccount(username, password) {
      linkCalls++
      linkedUsername = username
      linkedPassword = password
    }
    function disconnect() { disconnectCalls++ }
  }

  Component {
    id: cardFactory
    Plugin.SetupCard {
      width: 320
      service: vpn
    }
  }

  function init() {
    vpn.setupCardState = "first-run"
    vpn.readyNm = false
    vpn.readyNetwork = false
    vpn.readyRequests = false
    vpn.readyCreds = false
    vpn.depsBusy = false
    vpn.regBusy = false
    vpn.busy = false
    vpn.connected = false
    vpn.setupMsg = ""
    vpn.recheckCalls = 0
    vpn.installCalls = 0
    vpn.linkCalls = 0
    vpn.disconnectCalls = 0
    vpn.linkedUsername = ""
    vpn.linkedPassword = ""
  }

  function test_singleActiveStepAndCompletedSummary() {
    var card = createTemporaryObject(cardFactory, testCase)
    verify(card !== null)
    var progress = findChild(card, "setupStepProgress")
    var completed = findChild(card, "setupCompletedSummary")
    var next = findChild(card, "setupUpcomingStep")
    var network = findChild(card, "networkStep")
    var requests = findChild(card, "requestsStep")
    var account = findChild(card, "accountStep")

    compare(card.stepNumber, 1)
    compare(progress.text, "Step 1 of 3")
    verify(network.visible)
    verify(!requests.visible && !account.visible)
    verify(!completed.visible)
    verify(next.text.indexOf("Python requests") >= 0)
    compare(card.focusTarget.objectName, "recheckSetup")

    vpn.readyNm = true
    vpn.readyNetwork = true
    compare(card.stepNumber, 2)
    compare(progress.text, "Step 2 of 3")
    verify(!network.visible && requests.visible && !account.visible)
    verify(completed.visible)
    verify(completed.text.indexOf("NetworkManager") >= 0)
    verify(completed.text.indexOf("Python requests") < 0)
    verify(next.text.indexOf("CyberGhost account") >= 0)
    compare(card.focusTarget.objectName, "installDependencies")

    vpn.readyRequests = true
    compare(card.stepNumber, 3)
    compare(progress.text, "Step 3 of 3")
    verify(!network.visible && !requests.visible && account.visible)
    verify(completed.text.indexOf("NetworkManager") >= 0)
    verify(completed.text.indexOf("Python requests") >= 0)
    verify(!next.visible)
    compare(card.focusTarget.objectName, "accountUsername")

    vpn.readyCreds = true
    vpn.setupCardState = "ready"
    tryCompare(card, "implicitHeight", 0)
  }

  function test_missingNetworkExplainsCauseAndAllowsRecheck() {
    var card = createTemporaryObject(cardFactory, testCase)
    var detail = findChild(card, "networkRequirement")
    var recheck = findChild(card, "recheckSetup")
    verify(detail.visible)
    verify(detail.text.indexOf("NetworkManager") >= 0)
    verify(!findChild(card, "installDependencies").visible)
    verify(!findChild(card, "accountUsername").visible)

    recheck.clicked()
    compare(vpn.recheckCalls, 1)
    recheck.forceActiveFocus()
    keyClick(Qt.Key_Return)
    compare(vpn.recheckCalls, 2)

    vpn.readyNm = true
    verify(detail.text.indexOf("not allowed") >= 0)
    vpn.busy = true
    verify(!recheck.enabled)
  }

  function test_packagesActionAndErrorsStayAccessible() {
    vpn.readyNm = true
    vpn.readyNetwork = true
    var card = createTemporaryObject(cardFactory, testCase)
    var install = findChild(card, "installDependencies")
    var recheck = findChild(card, "recheckSetup")
    var message = findChild(card, "setupMessage")
    verify(install.visible && install.enabled)
    install.clicked()
    compare(vpn.installCalls, 1)
    vpn.setupMsg = "Could not open package terminal"
    verify(message.visible)
    verify(message.text.indexOf("Could not open") >= 0)
    verify(recheck.visible && recheck.enabled)

    vpn.depsBusy = true
    vpn.busy = true
    compare(install.text, "Installing…")
    verify(!install.enabled && !recheck.enabled)
    vpn.busy = false
    vpn.depsBusy = false
    verify(install.enabled)
  }

  function test_accountKeyboardAndPasswordProtection() {
    vpn.readyNm = true
    vpn.readyNetwork = true
    vpn.readyRequests = true
    var card = createTemporaryObject(cardFactory, testCase)
    var username = findChild(card, "accountUsername")
    var password = findChild(card, "accountPassword")
    var link = findChild(card, "linkAccount")
    verify(username.visible && password.visible && link.visible)
    compare(password.echoMode, TextInput.Password)
    verify(!link.enabled)

    username.forceActiveFocus()
    keyClick(Qt.Key_Return)
    verify(password.activeFocus)
    username.text = " demo@example.org "
    password.text = "placeholder-secret"
    verify(findChild(card, "accountUsernameLabel").visible)
    verify(findChild(card, "accountPasswordLabel").visible)
    compare(findChild(card, "accountUsernameLabel").text, "Username or email")
    compare(findChild(card, "accountPasswordLabel").text, "Password")
    verify(link.enabled)
    password.forceActiveFocus()
    keyClick(Qt.Key_Return)
    compare(vpn.linkCalls, 1)
    compare(vpn.linkedUsername, "demo@example.org")
    compare(vpn.linkedPassword, "placeholder-secret")
    compare(password.text, "")

    password.text = "must-clear-on-step-change"
    vpn.readyRequests = false
    verify(!password.visible)
    compare(password.text, "")
    vpn.readyRequests = true
    verify(password.visible)
    compare(password.text, "")
    password.text = "must-clear-on-close"
    card.visible = false
    compare(password.text, "")
  }

  function test_blockedAccountRetainsGuidanceAndDoesNotSubmit() {
    vpn.readyNm = true
    vpn.readyNetwork = true
    vpn.readyRequests = true
    var card = createTemporaryObject(cardFactory, testCase)
    var username = findChild(card, "accountUsername")
    var password = findChild(card, "accountPassword")
    var link = findChild(card, "linkAccount")
    var blocked = findChild(card, "linkBlockedReason")
    username.text = "demo"
    password.text = "private"
    vpn.connected = true
    verify(!link.enabled)
    verify(blocked.visible)
    verify(blocked.text.indexOf("Disconnect") >= 0)
    card.submit()
    compare(vpn.linkCalls, 0)
    compare(password.text, "")

    vpn.connected = false
    vpn.busy = true
    verify(blocked.visible)
    verify(blocked.text.indexOf("Wait") >= 0)
    vpn.regBusy = true
    verify(!blocked.visible)
    verify(!link.enabled)
    vpn.regBusy = false
    vpn.busy = false
    verify(!blocked.visible)
  }
}
