pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Countries.js" as Countries

Panel {
  id: root
  moduleName: "miguel.cyberghost"
  ipcTarget: "miguel.cyberghost"
  manageIpc: false

  required property var cyberghost
  property var anchorItem: null
  property var hostWidget: null
  property real preferredContentWidth: 380
  property real maximumContentHeight: 0
  readonly property var barIdentity: hostWidget || root
  function switchPanel(direction) {
    return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(barIdentity, direction) : false
  }

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.25)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color brandYellow: "#FFCE00"
  readonly property bool reduceMotion: !!setting("reduceMotion", false)
  property var detailsItem: null

  // One uppercase status line under the title, as in Omarchy's own panels.
  readonly property string statusLine: {
    var vpn = root.cyberghost
    if (!vpn)
      return ""
    if (!vpn.setupDone && !vpn.connected)
      return "Finish setup to connect"
    if (vpn.actionKind === "logout")
      return "Logging out…"
    if (vpn.resolvingAutomaticServer || vpn.connecting)
      return "Connecting to " + vpn.countryName + "…"
    if (vpn.disconnecting)
      return "Disconnecting…"
    if (vpn.statusUnknown)
      return "Status unknown"
    if (vpn.legacyTunnel)
      return "Connected · previous helper"
    // GeoIP location is private data; only the chosen country shows when hidden.
    var where = vpn.activeCountryName || (!vpn.hideDetails && vpn.publicCountry ? Countries.countryName(vpn.publicCountry) : "")
    if (vpn.connected && vpn.tunnelStale)
      return "Connected · no traffic received"
    if (vpn.connected)
      return where ? "Connected · " + where : "Connected"
    return "Disconnected"
  }

  // Panel shortcuts, in the spirit of Tailscale's t/r/c keys. Letters only
  // reach here when no text field has focus; buttons still own Enter/Space.
  function handleShortcut(event) {
    if (!root.cyberghost || !root.cyberghost.setupDone)
      return false
    var key = event.text.toLowerCase()
    if (key === "t" || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.toggleRunning()
      return true
    }
    if (key === "c" && root.detailsItem) {
      root.detailsItem.copyIp()
      return true
    }
    if (key === "h") {
      root.cyberghost.setHideDetails(!root.cyberghost.hideDetails)
      return true
    }
    if (key === "r") {
      root.refresh()
      return true
    }
    return false
  }

  function cleanupTransientState() {
    // Idempotent cleanup is required for controller-driven closes, output
    // removal and popout switches; close() is not the only lifecycle path.
    if (preferences)
      preferences.closePopups()
    if (setupCard)
      setupCard.clearPassword()
  }

  onOpenedChanged: {
    if (root.opened && cyberghost) {
      // Recheck's completion handler refreshes status; avoiding a second
      // immediate poll keeps opening the panel cheap.
      cyberghost.recheck()
      cyberghost.refreshServers()
      // Force a GeoIP lookup so the exposed/VPN IP is never stale.
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

  function toggleRunning() {
    cyberghost.toggle()
  }

  function refresh() {
    cyberghost.recheck()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened && root.cyberghost !== null
    // After setup the viewport takes focus so the shortcuts work on open;
    // Tab still walks into the controls.
    focusTarget: !root.cyberghost || !root.cyberghost.setupDone ? setupCard.focusTarget : scroll
    // Keep the same sizing contract as the official Omarchy panels: the
    // KeyboardPanel owns the popup padding, while the content column fills
    // the available inner width without a second manual inset.
    contentWidth: panel.fittedContentWidth(Style.space(root.preferredContentWidth))
    contentHeight: panel.fittedContentHeight(root.maximumContentHeight > 0 ? Math.min(mainColumn.implicitHeight, Style.space(root.maximumContentHeight)) : mainColumn.implicitHeight)

    PanelKeyCatcher {
      anchors.fill: parent
      focus: false
      blocked: true
      onCloseRequested: root.close()

      Flickable {
        id: scroll
        objectName: "vpnPanelViewport"
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        QQC.ScrollBar.vertical: QQC.ScrollBar {
          policy: QQC.ScrollBar.AsNeeded
        }

        Connections {
          target: scroll.Window.window
          function onActiveFocusItemChanged() {
            var item = scroll.Window.window.activeFocusItem
            if (!item)
              return
            var ancestor = item
            while (ancestor && ancestor !== mainColumn)
              ancestor = ancestor.parent
            if (ancestor !== mainColumn)
              return
            var point = item.mapToItem(mainColumn, 0, 0)
            if (point.y < scroll.contentY)
              scroll.contentY = Math.max(0, point.y)
            else if (point.y + item.height > scroll.contentY + scroll.height)
              scroll.contentY = Math.min(Math.max(0, scroll.contentHeight - scroll.height), point.y + item.height - scroll.height)
          }
        }

        // KeyboardPanel is a window, so keep the Escape handler on this
        // descendant Item. This mirrors the official panels and avoids an
        // invalid Keys attachment while native buttons retain Tab/Enter.
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (preferences.popupOpen)
            return
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (root.handleShortcut(event)) {
            event.accepted = true
          }
        }

        Column {
          id: mainColumn
          objectName: "vpnPanelContent"
          width: scroll.width
          spacing: Style.space(8)

          // Observed status is separate from next-connection preferences. The
          // hero stays during setup so the card keeps the plugin's identity.
          Item {
            width: parent.width
            implicitHeight: visible ? hero.implicitHeight : 0
            height: implicitHeight
            clip: true

            PanelHero {
              id: hero
              width: parent.width
              title: "CyberGhost VPN"
              meta: root.statusLine
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.cyberghost.active ? 1.0 : 0.65

              iconComponent: Component {
                GhostIcon {
                  iconSize: Style.font.display
                  color: root.cyberghost.active ? root.brandYellow : root.dim
                  innerColor: Color.popups.background
                  active: root.cyberghost.active
                  connecting: root.cyberghost.connecting || root.cyberghost.disconnecting
                  reducedMotion: root.reduceMotion
                }
              }

              // The on/off switch lives in the hero, like Omarchy's Tailscale
              // panel. `active` is the optimistic desired state, so the knob
              // moves immediately while `busy` swallows repeated clicks.
              trailingControl: Component {
                ToggleSwitch {
                  id: vpnSwitch
                  objectName: "vpnToggle"
                  visible: root.cyberghost.setupDone || root.cyberghost.connected
                  checked: root.cyberghost.active
                  busy: root.cyberghost.busy
                  foreground: root.foreground
                  onToggled: root.toggleRunning()
                  Accessible.role: Accessible.CheckBox
                  Accessible.name: root.cyberghost.active ? "Disconnect VPN" : "Connect VPN"

                  PanelToolTip {
                    visible: vpnSwitch.containsMouse
                    text: (root.cyberghost.active ? "Disconnect" : "Connect to " + root.cyberghost.countryName) + " (t)"
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }

          // -------------------------------------------------------------
          // 2. ERROR / STATUS BANNER
          // -------------------------------------------------------------

          StatusNotice {
            width: parent.width
            service: root.cyberghost
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          SetupCard {
            id: setupCard
            width: parent.width
            service: root.cyberghost
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Destination first, then one explicit connection action.
          ConnectionSettings {
            id: preferences
            visible: root.cyberghost.setupDone
            width: parent.width
            service: root.cyberghost
            foreground: root.foreground
            fontFamily: root.fontFamily
            connectionDetails: Component {
              ConnectionDetails {
                id: details
                width: parent.width
                service: root.cyberghost
                foreground: root.foreground
                fontFamily: root.fontFamily
                Component.onCompleted: root.detailsItem = details
              }
            }
            accountSection: Component {
              AccountSection {
                width: parent.width
                service: root.cyberghost
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
            }
          }
        }
      }
    }
  }
}
