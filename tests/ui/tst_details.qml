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
    property string activeServer: ""
    property int rxIdleSec: 0
    property bool legacyTunnel: false
    property real rxRate: -1
    property real txRate: -1
    property real rxBytes: -1
    property real txBytes: -1
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
    model.connected = false
    model.legacyTunnel = false
    model.rxRate = -1
    model.rxBytes = -1
    model.activeServer = ""
    model.endpoint = ""
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

  function test_transferRowsFollowTheTunnelLikeTheNetworkPanel() {
    var details = createTemporaryObject(factory, this)
    compare(findChild(details, "detailsHeader").text, "YOUR CONNECTION")
    compare(findChild(details, "receivingValue"), null)
    model.connected = true
    compare(findChild(details, "detailsHeader").text, "VPN CONNECTION")
    // No sample yet reads "--" instead of shifting the grid later.
    compare(findChild(details, "receivingValue").text, "--")
    model.rxRate = 505036.8
    model.rxBytes = 8.2 * 1024 * 1024 * 1024
    compare(findChild(details, "receivingValue").text, "493.2 KB/s")
    compare(findChild(details, "downloadedValue").text, "8.20 GB")
    model.legacyTunnel = true
    compare(findChild(details, "receivingValue"), null)
  }

  function test_clickingTheIpCopiesIt() {
    var details = createTemporaryObject(factory, this)
    mouseClick(findChild(details, "ipValue"))
    var process = findChild(details, "clipboardProcess")
    compare(process.command[1], "203.0.113.42")
    process.running = false
    process.exited(0)
    verify(details.ipCopied)
  }

  function test_ipAndLongValuesGetTheFullRowWidth() {
    var details = createTemporaryObject(factory, this)
    var ip = findChild(details, "ipValue")
    // The value spans everything after its label, so an address never elides.
    verify(ip.width > details.width * 0.6)
    verify(ip.implicitWidth <= ip.width)
    compare(findChild(details, "locationValue").text, "Lisbon, Portugal")
    compare(findChild(details, "providerValue").maximumLineCount, 2)
  }

  function test_serverShowsTheNameWhenKnownAndTheEndpointOtherwise() {
    var details = createTemporaryObject(factory, this)
    model.connected = true
    model.endpoint = "198.51.100.20:1337"
    compare(findChild(details, "serverValue").text, "198.51.100.20:1337")
    model.activeServer = "barcelona-s402-i05"
    compare(findChild(details, "serverValue").text, "barcelona-s402-i05")
    model.hideDetails = true
    compare(findChild(details, "serverValue").text, "Hidden")
  }
}
