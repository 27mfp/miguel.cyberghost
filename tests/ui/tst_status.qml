import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  name: "StatusRecovery"
  visible: true
  when: windowShown
  QtObject {
    id: model
    property string lastError: ""
    property string statusProbeError: ""
    property bool statusUnknown: false
    property bool tunnelStale: false
    property bool legacyTunnel: false
    property string actionStatus: ""
    property string applyHint: ""
    property int rxIdleSec: 240
    property bool busy: false
    property bool setupDone: false
    property int rechecks: 0
    function recheck() { rechecks++ }
  }
  Component {
    id: factory
    Plugin.StatusNotice { width: 280; service: model }
  }
  function init() {
    model.lastError = ""
    model.statusProbeError = ""
    model.statusUnknown = false
    model.tunnelStale = false
    model.legacyTunnel = false
    model.actionStatus = ""
    model.applyHint = ""
    model.busy = false
    model.rechecks = 0
  }
  function test_readyHasNoNotice() {
    var notice = createTemporaryObject(factory, this)
    verify(!notice.visible)
    compare(notice.height, 0)
  }
  function test_unknownOffersReadOnlyRecovery() {
    model.statusUnknown = true
    var notice = createTemporaryObject(factory, this)
    verify(notice.visible)
    verify(notice.message.indexOf("could not be verified") >= 0)
    var button = findChild(notice, "statusRecheck")
    verify(button.visible && button.enabled)
    button.clicked()
    compare(model.rechecks, 1)
    model.busy = true
    verify(!button.enabled)
  }
  function test_errorsVisibleBeforeSetupAndWrap() {
    model.lastError = "A long setup-time backend failure that should remain visible and wrap on a narrow panel rather than hide behind incomplete setup."
    var notice = createTemporaryObject(factory, this)
    verify(notice.visible)
    compare(findChild(notice, "statusNoticeText").text, model.lastError)
    verify(notice.implicitHeight > 0)
  }
  function test_operationErrorCanBeDismissedWithoutStatusCheck() {
    model.lastError = "Could not copy the public IP. Check that wl-copy is installed."
    var notice = createTemporaryObject(factory, this)
    verify(!findChild(notice, "statusRecheck").visible)
    var dismiss = findChild(notice, "dismissNotice")
    verify(dismiss.visible)
    mouseClick(dismiss)
    compare(model.lastError, "")
    compare(model.rechecks, 0)
    verify(!notice.visible)
  }
  function test_unknownStatusTakesPriorityOverOperationError() {
    model.lastError = "Clipboard copy timed out."
    model.statusUnknown = true
    var notice = createTemporaryObject(factory, this)
    verify(notice.message.indexOf("could not be verified") >= 0)
    verify(!findChild(notice, "dismissNotice").visible)
    mouseClick(findChild(notice, "statusRecheck"))
    compare(model.rechecks, 1)
    compare(model.lastError, "Clipboard copy timed out.")
    model.statusProbeError = "VPN status check timed out; current state is unknown."
    compare(notice.message, model.statusProbeError)
  }
  function test_dismissalPreservesStaleTunnelWarning() {
    model.lastError = "Clipboard copy timed out."
    model.tunnelStale = true
    model.actionStatus = "Connected successfully"
    var notice = createTemporaryObject(factory, this)
    mouseClick(findChild(notice, "dismissNotice"))
    verify(notice.visible)
    verify(notice.message.indexOf("No traffic received") >= 0)
    verify(findChild(notice, "statusRecheck").visible)
    model.tunnelStale = false
    compare(notice.message, model.actionStatus)
  }
}
