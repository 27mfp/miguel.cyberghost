pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The shell owns lifecycle and placement. All visual work starts on first
// open, while the NetworkManager service remains available in BarWidget.qml.
Panel {
  id: root
  moduleName: "miguel.cyberghost"
  ipcTarget: "miguel.cyberghost"
  manageIpc: false

  required property var cyberghost
  property var anchorItem: null
  property var hostWidget: null
  property real preferredContentWidth: 370
  property real maximumContentHeight: 620
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool reduceMotion: Style.reduceMotion || !!setting("reduceMotion", false)
  readonly property var visualContent: panel.loadedContent

  function switchPanel(direction) {
    return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(barIdentity, direction) : false
  }

  // These shortcuts fire only with focus on the panel viewport, never inside
  // search fields, tabs, account controls or the country dropdown.
  function handleShortcut(event) {
    if (!cyberghost || !cyberghost.setupDone)
      return false
    const key = (event.text || "").toLowerCase()
    if (key === "t" && !cyberghost.busy && !cyberghost.statusUnknown) {
      cyberghost.toggle()
      return true
    }
    if (key === "c" && visualContent && visualContent.dashboard) {
      visualContent.dashboard.copyIp()
      return true
    }
    if (key === "h") {
      cyberghost.setHideDetails(!cyberghost.hideDetails)
      return true
    }
    if (key === "r") {
      cyberghost.recheck()
      return true
    }
    return false
  }

  function cleanupTransientState() {
    const dashboard = visualContent && visualContent.dashboard
    if (!dashboard) return
    dashboard.closePopups()
    dashboard.clearPassword()
  }

  onOpenedChanged: {
    if (root.opened && cyberghost) {
      panel.ensureContent()
      cyberghost.recheck()
      cyberghost.refreshServers()
      cyberghost.refreshIpInfo(true)
    } else if (!root.opened) {
      cleanupTransientState()
    }
  }
  Component.onDestruction: cleanupTransientState()

  function close() {
    cleanupTransientState()
    root.controller.hide()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened && root.cyberghost !== null
    focusTarget: root.visualContent ? (!root.cyberghost || !root.cyberghost.setupDone ? root.visualContent.dashboard.setupFocusTarget : root.visualContent.scroll) : null
    contentWidth: panel.fittedContentWidth(Style.space(root.preferredContentWidth))
    contentHeight: panel.fittedContentHeight(Math.min(panel.loadedContentHeight, Style.space(root.maximumContentHeight)))

    content: PanelKeyCatcher {
      property alias dashboard: dash
      property alias scroll: viewport
      implicitHeight: dash.implicitHeight
      anchors.fill: parent
      focus: false
      blocked: true
      onCloseRequested: root.close()

      Flickable {
        id: viewport
        objectName: "vpnPanelViewport"
        anchors.fill: parent
        contentWidth: width
        contentHeight: dash.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        clip: true
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        Connections {
          target: viewport.Window.window
          function onActiveFocusItemChanged() {
            const window = viewport.Window.window
            if (!window || !window.activeFocusItem) return
            const item = window.activeFocusItem
            let ancestor = item
            while (ancestor && ancestor !== dash) ancestor = ancestor.parent
            if (ancestor !== dash) return
            const point = item.mapToItem(dash, 0, 0)
            if (point.y < viewport.contentY)
              viewport.contentY = Math.max(0, point.y)
            else if (point.y + item.height > viewport.contentY + viewport.height)
              viewport.contentY = Math.min(Math.max(0, viewport.contentHeight - viewport.height), point.y + item.height - viewport.height)
          }
        }

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (dash.popupOpen) return
          if (viewport.activeFocus && (event.modifiers & Qt.ControlModifier)
              && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
            const direction = (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1
            if (root.switchPanel(direction)) {
              event.accepted = true
              return
            }
          }
          if (event.key === Qt.Key_Escape) {
            if (!dash.goBack()) root.close()
            event.accepted = true
          } else if (viewport.activeFocus && root.handleShortcut(event)) {
            event.accepted = true
          }
        }

        VpnDashboard {
          id: dash
          objectName: "vpnPanelContent"
          width: viewport.width
          service: root.cyberghost
          foreground: root.foreground
          fontFamily: root.fontFamily
          reduceMotion: root.reduceMotion
          onToggleRequested: root.cyberghost.toggle()
        }
      }
    }
  }
}
