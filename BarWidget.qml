pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

Ui.BarWidget {
  id: root
  moduleName: "miguel.cyberghost"
  readonly property color brandYellow: "#FFCE00"
  readonly property color successGreen: "#10B981"
  readonly property bool reduceMotion: !!setting("reduceMotion", false)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing : false
  readonly property var actionService: cyberghost
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function open() {
    if (panelLoader.item)
      panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item)
      panelLoader.item.close()
  }
  function togglePanel() {
    if (opened)
      close()
    else
      open()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item)
      panelLoader.item.closeForPopoutSwitch()
  }
  function refresh() {
    cyberghost.recheck()
  }

  function injectPanel() {
    var panel = panelLoader.item
    if (!panel)
      return
    panel.bar = root.bar
    panel.settings = root.settings
    panel.anchorItem = button
    panel.hostWidget = root
    panel.cyberghost = cyberghost
  }
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Service {
    id: cyberghost
    settings: root.settings
    onSettingChanged: function (key, value) {
      var current = root.settings || {}
      var entry = { id: root.moduleName }
      for (var name in current)
        entry[name] = current[name]
      entry[key] = value
      var acknowledged = false
      try {
        if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
          acknowledged = root.bar.shell.updateEntryInline(root.moduleName, entry) === true
      } catch (e) {
        acknowledged = false
      }
      root.settings = entry
      if (!acknowledged)
        cyberghost.lastError = "Could not save preference changes to Omarchy shell settings."
    }
  }
  Loader {
    id: panelLoader
    active: true
    visible: false
    Component.onCompleted: setSource(Qt.resolvedUrl("Panel.qml"), {
      cyberghost: cyberghost,
      bar: root.bar,
      settings: root.settings,
      anchorItem: button,
      hostWidget: root
    })
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
  IpcHandler {
    // The bar owns a widget per output. Elect one handler, while every
    // visible widget keeps its own anchor and direct click interactions.
    enabled: root.bar && typeof root.bar.moduleWidgets === "function" && root.bar.moduleWidgets(root.moduleName)[0] === root
    target: root.moduleName
    function open(): void {
      root.open()
    }
    function close(): void {
      root.close()
    }
    function show(): void {
      root.open()
    }
    function hide(): void {
      root.close()
    }
    function toggle(): void {
      root.togglePanel()
    }
    function refresh(): void {
      root.broadcast("refresh")
    }
    function connect(countryCode: string): void {
      cyberghost.connectTo(countryCode || cyberghost.country)
    }
    function disconnect(): void {
      cyberghost.disconnect()
    }
  }
  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened
    Accessible.name: tooltipText
    tooltipText: {
      if (!cyberghost.setupDone)
        return "CyberGhost VPN: setup incomplete — click for steps"
      if (cyberghost.statusUnknown)
        return "CyberGhost VPN: status unavailable — click to reconcile"
      if (cyberghost.externalVpn)
        return "CyberGhost VPN: another VPN is active"
      if (cyberghost.connecting)
        return "CyberGhost VPN: Connecting to " + cyberghost.countryName + " (" + cyberghost.country + ")…"
      if (cyberghost.disconnecting)
        return "CyberGhost VPN: Disconnecting…"
      if (cyberghost.connected) {
        var ipPart = (!cyberghost.hideDetails && cyberghost.publicIp !== "") ? (" • " + cyberghost.publicIp) : ""
        return "CyberGhost VPN: Connected" + ipPart
      }
      return "CyberGhost VPN: Disconnected (Click to open)"
    }

    iconComponent: Component {
      Item {
        anchors.fill: parent

        GhostIcon {
          anchors.centerIn: parent
          iconSize: Style.font.icon
          color: cyberghost.active ? root.brandYellow : (root.bar ? root.bar.barForeground : Color.foreground)
          innerColor: Color.bar.background
          active: cyberghost.active
          connecting: cyberghost.connecting || cyberghost.disconnecting
          reducedMotion: root.reduceMotion
          warning: cyberghost.tunnelStale || cyberghost.statusUnknown || cyberghost.externalVpn || !cyberghost.setupDone
        }
      }
    }

    onPressed: function (buttonCode) {
      // Left-click always opens or closes the panel (even before setup, so
      // the user can reach the wizard). Middle and right click silently
      // toggle the VPN without showing the panel — the documented behaviour.
      if (buttonCode === Qt.LeftButton) {
        root.togglePanel()
        return
      }
      if (buttonCode === Qt.MiddleButton || buttonCode === Qt.RightButton) {
        var widgets = root.bar && typeof root.bar.moduleWidgets === "function" ? root.bar.moduleWidgets(root.moduleName) : [root]
        var owner = widgets.length > 0 && widgets[0] && widgets[0].actionService ? widgets[0].actionService : cyberghost
        owner.toggle()
      }
    }
  }

  // Active connected indicator dot (Green)
  Rectangle {
    visible: cyberghost.active && !cyberghost.connecting && !cyberghost.disconnecting
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    anchors.margins: Math.max(1, Math.round(Style.space(1)))
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.successGreen
    border.width: 1
    border.color: Qt.rgba(0, 0, 0, 0.4)
  }

  // Pulsing dot during connection / disconnection (Brand Yellow)
  Rectangle {
    visible: cyberghost.connecting || cyberghost.disconnecting
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    anchors.margins: Math.max(1, Math.round(Style.space(1)))
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.brandYellow

    SequentialAnimation on opacity {
      running: (cyberghost.connecting || cyberghost.disconnecting) && !root.reduceMotion
      loops: Animation.Infinite
      NumberAnimation {
        to: 0.25
        duration: 500
        easing.type: Easing.InOutSine
      }
      NumberAnimation {
        to: 1.0
        duration: 500
        easing.type: Easing.InOutSine
      }
    }
  }
}
