pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Translations.js" as Translations

// Signed-in identity and logout. Only the plugin's own login (native.ini) can
// be logged out here; an account read from the vendor CLI's config.ini is
// shown but left to that CLI, since the plugin never deletes vendor files.
Column {
  id: root
  required property var service
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool showHeading: true
  property bool relinking: false
  readonly property bool needsRelink: pluginLogin && !service.syncingServers && service.serverList === "probe"
  readonly property string uiLanguage: typeof Commons.I18n !== "undefined" ? Commons.I18n.language : "en"
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property bool pluginLogin: service.accountSource === "native"
  // Two-step confirmation, disarmed automatically after a few seconds.
  property bool armed: false
  visible: service.setupDone && service.readyCreds
  height: visible ? implicitHeight : 0
  spacing: Style.space(8)

  function requestLogout() {
    if (!armed) {
      armed = true
      disarm.restart()
      return
    }
    armed = false
    disarm.stop()
    service.logout()
  }
  function clearPassword() {
    const form = relinkLoader.item as SetupCard
    if (form) form.clearPassword()
  }
  onVisibleChanged: {
    armed = false
    if (!visible) { relinking = false; clearPassword() }
  }

  Timer {
    id: disarm
    interval: 4000
    onTriggered: root.armed = false
  }

  PanelSeparator {
    visible: root.showHeading
    width: parent.width
    foreground: root.foreground
  }

  PanelSectionHeader {
    visible: root.showHeading
    text: Translations.t("account.heading", root.uiLanguage)
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(identity.implicitHeight, logoutButton.implicitHeight)

    Text {
      id: accountGlyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
      text: ""
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Column {
      id: identity
      anchors.left: accountGlyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: logoutButton.visible ? logoutButton.left : parent.right
      anchors.rightMargin: logoutButton.visible ? Style.space(8) : 0
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        objectName: "accountName"
        width: parent.width
        // An email address is personal; privacy mode masks it too.
        text: root.service.hideDetails ? Translations.t("account.hidden", root.uiLanguage) : (root.service.accountName || Translations.t("account.generic", root.uiLanguage))
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideMiddle
      }
      Text {
        objectName: "accountSourceText"
        width: parent.width
        // A live session reads CyberGhost's own server list; once it expires
        // connects still work by probing, and linking again refreshes it.
        // Wrap status independently; actionable relinking guidance lives below.
        text: (root.pluginLogin ? Translations.t("account.device", root.uiLanguage) : Translations.t("account.cli", root.uiLanguage)) + (root.service.syncingServers ? Translations.t("account.sync", root.uiLanguage, root.service.syncProgress) : (root.service.serverList === "live" ? Translations.t("account.live", root.uiLanguage) : ""))
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Button {
      id: logoutButton
      objectName: "logoutButton"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.pluginLogin
      text: root.armed ? (root.service.connected ? Translations.t("account.disconnectLogout", root.uiLanguage) : Translations.t("account.confirm", root.uiLanguage)) : Translations.t("account.logout", root.uiLanguage)
      iconText: ""
      fontSize: Style.font.caption
      horizontalPadding: Style.space(8)
      verticalPadding: Style.space(4)
      focusable: true
      bordered: root.armed
      enabled: !root.service.busy
      foreground: root.armed ? Commons.Color.urgent : root.foreground
      fontFamily: root.fontFamily
      tooltipText: root.armed ? Translations.t("account.confirmTooltip", root.uiLanguage) : Translations.t("account.logoutTooltip", root.uiLanguage)
      Accessible.name: text
      onClicked: root.requestLogout()
    }
  }

  Text {
    objectName: "accountRelinkHint"
    visible: root.needsRelink || root.relinking
    width: parent.width
    text: Translations.t("account.relinkHint", root.uiLanguage)
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  Button {
    objectName: "accountRelink"
    visible: root.needsRelink && !root.relinking
    width: parent.width
    text: Translations.t("account.relinkAction", root.uiLanguage)
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    bordered: true
    focusable: true
    Accessible.name: text
    onClicked: {
      root.relinking = true
    }
  }

  // Qt 6.4 cannot instantiate a Component declared in a
  // `ComponentBehavior: Bound` file through Loader.sourceComponent. Load the
  // standalone component by URL instead and rebind reactive properties after
  // creation; this also keeps the required `service` initialised at creation.
  Loader {
    id: relinkLoader
    width: parent.width
    visible: root.relinking
    onLoaded: {
      const form = item as SetupCard
      if (!form)
        return
      form.foreground = Qt.binding(function() { return root.foreground })
      form.fontFamily = Qt.binding(function() { return root.fontFamily })
      form.width = Qt.binding(function() { return relinkLoader.width })
      form.focusTarget.forceActiveFocus()
    }
  }

  function syncRelink() {
    if (!relinking) {
      relinkLoader.source = ""
      return
    }
    relinkLoader.setSource(Qt.resolvedUrl("SetupCard.qml"), {
      "service": root.service,
      "relinking": true
    })
  }
  onRelinkingChanged: syncRelink()
  Component.onCompleted: syncRelink()

  Button {
    objectName: "accountRelinkCancel"
    visible: root.relinking
    width: parent.width
    enabled: !root.service.regBusy
    text: Translations.t("account.cancelRelink", root.uiLanguage)
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    focusable: true
    Accessible.name: text
    onClicked: {
      root.clearPassword()
      root.relinking = false
    }
  }
}
