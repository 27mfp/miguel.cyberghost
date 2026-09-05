import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  name: "ConnectionDetailsBehavior"
  visible: true
  when: windowShown
  QtObject {
    id: model
    property bool setupDone: true
    property bool hideDetails: false
    property string publicIp: "203.0.113.42"
    property bool fetchingIp: false
    property string publicCity: "Lisbon"
    property string publicCountry: "PT"
    property string publicOrg: "Example provider with a long organization name"
    property string lastError: ""
    property bool connected: false
    property string transferText: ""
    property string endpoint: ""
    property int handshakeAgeSec: -1
    function setHideDetails(value) {
      hideDetails = value
    }
  }
  Component {
    id: factory
    Plugin.ConnectionDetails {
      width: 300
      service: model
    }
  }
  function init() {
    model.hideDetails = false
    model.lastError = ""
  }
  function test_copyWaitsForProcessSuccess() {
    var details = createTemporaryObject(factory, this)
    details.copyIp()
    compare(details.ipCopied, false)
    var process = findChild(details, "clipboardProcess")
    verify(process !== null)
    process.running = false
    process.exited(0)
    compare(details.ipCopied, true)
  }
  function test_copyFailureNeverReportsSuccess() {
    var details = createTemporaryObject(factory, this)
    details.copyIp()
    var process = findChild(details, "clipboardProcess")
    verify(process !== null)
    process.running = false
    process.exited(1)
    compare(details.ipCopied, false)
    verify(model.lastError !== "")
  }
  function test_privacyMasksValuesAndBlocksCopy() {
    var details = createTemporaryObject(factory, this)
    model.hideDetails = true
    compare(findChild(details, "ipValue").text, "Hidden")
    compare(findChild(details, "providerValue").text, "Hidden")
    details.copyIp()
    compare(findChild(details, "clipboardProcess").running, false)
  }
}
