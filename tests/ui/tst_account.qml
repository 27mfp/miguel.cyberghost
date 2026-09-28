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
    compare(caption.text, "This device · relink to refresh servers")
    account.serverList = "live"
  }
}
