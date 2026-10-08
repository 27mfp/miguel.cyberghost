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
}
