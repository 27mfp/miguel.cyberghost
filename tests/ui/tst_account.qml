import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  name: "AccountSection"
  visible: true
  when: windowShown
  width: 420
  height: 300

  QtObject {
    id: account
    property bool setupDone: true
    property bool readyCreds: true
    property bool hideDetails: false
    property bool connected: false
    property bool busy: false
    property string accountName: "user@example.com"
    property string accountSource: "native"
    property string serverList: "live"
    property bool syncingServers: false
    property string syncProgress: ""
    property int logoutCalls: 0
    property string setupCardState: "ready"
    property bool readyNm: true
    property bool readyNetwork: true
    property bool readyRequests: true
    property bool regBusy: false
    property bool depsBusy: false
    property string setupMsg: ""
    property int linkCalls: 0
    function registerAccount(username, password) { linkCalls++ }
    function recheck() {}
    function installDeps() {}
    function disconnect() {}
    function logout() {
      logoutCalls++
    }
  }

  Component {
    id: factory
    Plugin.AccountSection {
      width: 380
      service: account
    }
  }

  function init() {
    account.hideDetails = false
    account.connected = false
    account.accountSource = "native"
    account.serverList = "live"
    account.logoutCalls = 0
    account.linkCalls = 0
    account.busy = false
    account.regBusy = false
    account.setupMsg = ""
  }

  function test_logoutNeedsASecondDeliberateClick() {
    var section = createTemporaryObject(factory, this)
    var button = findChild(section, "logoutButton")
    verify(button.visible)
    compare(button.text, "Log out")
    button.clicked()
    compare(account.logoutCalls, 0)
    compare(button.text, "Confirm log out")
    button.clicked()
    compare(account.logoutCalls, 1)
    compare(button.text, "Log out")
  }

  function test_connectedLogoutSaysItDisconnects() {
    account.connected = true
    var section = createTemporaryObject(factory, this)
    var button = findChild(section, "logoutButton")
    button.clicked()
    compare(button.text, "Disconnect & log out")
  }

  function test_armedConfirmationExpires() {
    var section = createTemporaryObject(factory, this)
    var button = findChild(section, "logoutButton")
    button.clicked()
    verify(section.armed)
    tryCompare(section, "armed", false, 6000)
    button.clicked()
    compare(account.logoutCalls, 0)
  }

  function test_vendorCliAccountIsShownButNotDeleted() {
    // The vendor CLI config carries no plugin session, so no live list.
    account.accountSource = "legacy"
    account.serverList = "probe"
    var section = createTemporaryObject(factory, this)
    verify(!findChild(section, "logoutButton").visible)
    compare(findChild(section, "accountSourceText").text, "CyberGhost CLI config")
  }

  function test_privacyModeMasksTheAccountName() {
    var section = createTemporaryObject(factory, this)
    compare(findChild(section, "accountName").text, "user@example.com")
    account.hideDetails = true
    compare(findChild(section, "accountName").text, "Hidden")
  }

  function test_serverListStateIsShownWithoutPrompting() {
    var section = createTemporaryObject(factory, this)
    var caption = findChild(section, "accountSourceText")
    compare(caption.text, "This device · live servers")
    account.syncingServers = true
    account.syncProgress = "12/94"
    compare(caption.text, "This device · syncing servers 12/94")
    account.syncingServers = false
    account.serverList = "probe"
    compare(caption.text, "This device")
    verify(findChild(section, "accountRelinkHint").visible)
    verify(findChild(section, "accountRelink").visible)
    account.serverList = "live"
  }

  function test_relinkIsExplicitKeepsCredentialsAndClearsPassword() {
    account.serverList = "probe"
    var section = createTemporaryObject(factory, this, {showHeading: false, width: 280})
    var hint = findChild(section, "accountRelinkHint")
    compare(hint.wrapMode, Text.WordWrap)
    verify(hint.visible)
    verify(!section.relinking)
    compare(findChild(section, "accountPassword"), null)
    findChild(section, "accountRelink").clicked()
    tryVerify(function() { return findChild(section, "accountPassword") !== null })
    var username = findChild(section, "accountUsername")
    var password = findChild(section, "accountPassword")
    verify(username.visible && password.visible)
    username.text = "preview@example.invalid"
    password.text = "not-real"
    password.accepted()
    compare(account.linkCalls, 1)
    compare(account.logoutCalls, 0)
    verify(account.readyCreds)
    compare(password.text, "")
    password.text = "discard-draft"
    section.clearPassword()
    compare(password.text, "")
    findChild(section, "accountRelinkCancel").clicked()
    verify(!section.relinking)
    tryVerify(function() { return findChild(section, "accountPassword") === null })
  }

  function test_connectedRelinkExplainsDisconnectWithoutDoingIt() {
    account.serverList = "probe"
    account.connected = true
    var section = createTemporaryObject(factory, this)
    findChild(section, "accountRelink").clicked()
    tryVerify(function() { return findChild(section, "linkBlockedReason") !== null })
    var blocked = findChild(section, "linkBlockedReason")
    verify(blocked.visible)
    verify(blocked.text.indexOf("Disconnect") >= 0)
    verify(!findChild(section, "linkAccount").enabled)
    compare(account.linkCalls, 0)
    compare(account.logoutCalls, 0)
  }
}
