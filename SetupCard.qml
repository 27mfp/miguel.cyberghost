import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Translations.js" as Translations

// Required setup only. Optional preferences belong under Advanced.
// Host TextField password mode with persistent labels for credential fields.
Column {
  id: root
  required property var service
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool relinking: false
  readonly property string uiLanguage: typeof Commons.I18n !== "undefined" ? Commons.I18n.language : "en"
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color brandYellow: "#FFCE00"
  readonly property bool needsNetwork: !service.readyNetwork
  readonly property bool needsPackages: !needsNetwork && !service.readyRequests
  readonly property bool needsAccount: !needsNetwork && !needsPackages && (!service.readyCreds || relinking)
  readonly property int stepNumber: needsNetwork ? 1 : needsPackages ? 2 : 3
  readonly property int completedSteps: (service.readyNetwork ? 1 : 0) + (service.readyNetwork && service.readyRequests ? 1 : 0)
  readonly property string stepProgress: {
    const value = Translations.t("setup.stepProgress", uiLanguage, stepNumber)
    if (value !== "setup.stepProgress") return value
    const pt = String(uiLanguage).toLowerCase().startsWith("pt")
    return (pt ? "Passo " : "Step ") + stepNumber + (pt ? " de 3" : " of 3")
  }
  readonly property string completedSummary: {
    const steps = []
    if (service.readyNetwork) steps.push(Translations.t("setup.network", uiLanguage))
    if (service.readyNetwork && service.readyRequests) steps.push(Translations.t("setup.requests", uiLanguage))
    return steps.map(function(label) { return "✓ " + label }).join("   ·   ")
  }
  readonly property string upcomingLabel: needsNetwork ? Translations.t("setup.requests", uiLanguage)
    : needsPackages ? Translations.t("setup.account", uiLanguage) : ""
  readonly property bool formFilled: username.text.trim() !== "" && passwordField.text !== ""
  readonly property string linkBlockedReason: service.regBusy ? "" : (service.connected ? "Disconnect the VPN before linking an account." : (service.busy ? "Wait for the current operation to finish before linking an account." : ""))
  readonly property string linkBlockedText: service.regBusy ? "" : (service.connected ? Translations.t("setup.blockedConnected", uiLanguage) : (service.busy ? Translations.t("setup.blockedBusy", uiLanguage) : ""))
  readonly property var focusTarget: needsPackages ? installDependencies : (needsAccount ? username : recheckSetup)
  visible: relinking || service.setupCardState !== "ready"
  height: visible ? implicitHeight : 0
  spacing: visible ? Style.space(10) : 0

  function clearPassword() {
    passwordField.clear()
  }
  onNeedsAccountChanged: if (!needsAccount && passwordField)
    clearPassword()
  onVisibleChanged: if (!visible)
    clearPassword()

  function submit() {
    if (service.connected || service.busy) {
      service.setupMsg = linkBlockedReason || "Account linking is already in progress."
      passwordField.clear()
      return
    }
    if (!username.text.trim() || !passwordField.text) {
      service.setupMsg = "Enter your CyberGhost username and password."
      if (!username.text.trim())
        username.forceActiveFocus()
      else
        passwordField.forceActiveFocus()
      return
    }
    service.registerAccount(username.text.trim(), passwordField.text)
    passwordField.clear()
  }

  // A single actionable step, with completed requirements condensed above it.
  Item {
    visible: root.visible && !root.relinking
    width: parent.width
    implicitHeight: Math.max(heading.implicitHeight, recheckSetup.implicitHeight)

    Column {
      id: heading
      anchors.left: parent.left
      anchors.right: recheckSetup.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      PanelSectionHeader {
        width: parent.width
        text: Translations.t("setup.heading", root.uiLanguage)
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        objectName: "setupStepProgress"
        width: parent.width
        text: root.stepProgress
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
        Accessible.role: Accessible.StaticText
        Accessible.name: text
      }
    }

    PanelActionButton {
      id: recheckSetup
      objectName: "recheckSetup"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      focusable: true
      enabled: !root.service.busy
      iconText: ""
      tooltipText: Translations.t("setup.recheck", root.uiLanguage)
      Accessible.name: Translations.t("setup.recheck", root.uiLanguage)
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.service.recheck()
    }
  }

  Text {
    objectName: "setupCompletedSummary"
    visible: root.visible && !root.relinking && root.completedSteps > 0
    width: parent.width
    text: root.completedSummary
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }

  StepRow {
    objectName: "networkStep"
    visible: root.visible && root.needsNetwork
    foreground: root.foreground
    highlight: root.brandYellow
    fontFamily: root.fontFamily
    label: Translations.t("setup.network", root.uiLanguage)
    done: root.service.readyNetwork
    current: root.needsNetwork
    // Omarchy ships NetworkManager; the tunnel is one of its connections.
    detail: !root.service.readyNm ? Translations.t("setup.networkStopped", root.uiLanguage) : Translations.t("setup.networkDenied", root.uiLanguage)
    detailObjectName: "networkRequirement"
  }

  StepRow {
    objectName: "requestsStep"
    visible: root.visible && root.needsPackages
    foreground: root.foreground
    highlight: root.brandYellow
    fontFamily: root.fontFamily
    label: Translations.t("setup.requests", root.uiLanguage)
    done: root.service.readyRequests
    current: root.needsPackages
    detail: Translations.t("setup.requestsDetail", root.uiLanguage)
  }

  Button {
    id: installDependencies
    objectName: "installDependencies"
    visible: root.visible && root.needsPackages
    width: parent.width
    text: root.service.depsBusy ? Translations.t("setup.installing", root.uiLanguage) : Translations.t("setup.install", root.uiLanguage)
    focusable: true
    bordered: true
    enabled: !root.service.busy
    foreground: enabled ? root.brandYellow : root.dim
    fontFamily: root.fontFamily
    onClicked: root.service.installDeps()
  }

  StepRow {
    objectName: "accountStep"
    visible: root.visible && root.needsAccount && !root.relinking
    foreground: root.foreground
    highlight: root.brandYellow
    fontFamily: root.fontFamily
    label: Translations.t("setup.account", root.uiLanguage)
    done: root.service.readyCreds
    current: root.needsAccount
  }

  Text {
    objectName: "setupUpcomingStep"
    visible: root.visible && root.upcomingLabel !== ""
    width: parent.width
    text: "→  " + root.upcomingLabel
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }

  // ---- Account form --------------------------------------------------------
  Column {
    visible: root.visible && root.needsAccount
    width: parent.width
    spacing: Style.space(8)
    topPadding: Style.space(2)

    Text {
      objectName: "accountUsernameLabel"
      width: parent.width
      text: Translations.t("setup.username", root.uiLanguage)
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    TextField {
      id: username
      objectName: "accountUsername"
      width: parent.width
      enabled: !root.service.regBusy
      maximumLength: 256
      placeholderText: Translations.t("setup.username", root.uiLanguage)
      Accessible.name: Translations.t("setup.usernameAccessible", root.uiLanguage)
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      selectByMouse: true
      onAccepted: passwordField.forceActiveFocus()
    }

    Text {
      objectName: "accountPasswordLabel"
      width: parent.width
      text: Translations.t("setup.password", root.uiLanguage)
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    TextField {
      id: passwordField
      objectName: "accountPassword"
      width: parent.width
      enabled: !root.service.regBusy
      maximumLength: 256
      password: true
      placeholderText: Translations.t("setup.password", root.uiLanguage)
      Accessible.name: Translations.t("setup.passwordAccessible", root.uiLanguage)
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      selectByMouse: true
      onAccepted: root.submit()
    }

    Button {
      objectName: "linkAccount"
      width: parent.width
      iconText: root.service.regBusy ? "" : ""
      iconSpinning: root.service.regBusy
      text: root.service.regBusy ? Translations.t("setup.linking", root.uiLanguage) : Translations.t("setup.link", root.uiLanguage)
      focusable: true
      bordered: true
      enabled: !root.service.regBusy && !root.service.connected && !root.service.busy && root.formFilled
      // The host Button has no disabled styling; dim it until it can act.
      foreground: enabled || root.service.regBusy ? root.brandYellow : root.dim
      fontFamily: root.fontFamily
      tooltipText: root.linkBlockedText || Translations.t("setup.linkTooltip", root.uiLanguage)
      Accessible.description: tooltipText
      onClicked: root.submit()
    }

    Text {
      objectName: "linkBlockedReason"
      visible: root.linkBlockedReason !== ""
      width: parent.width
      text: root.linkBlockedText
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }

    Row {
      width: parent.width
      spacing: Style.space(6)
      Text {
        id: lockGlyph
        text: ""
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        width: parent.width - lockGlyph.width - parent.spacing
        text: Translations.t("setup.privacy", root.uiLanguage)
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // Progress text while something runs; an error once it has finished.
  Text {
    objectName: "setupMessage"
    visible: root.visible && root.service.setupMsg !== ""
    width: parent.width
    text: Translations.message(root.service.setupMsg, root.uiLanguage)
    textFormat: Text.PlainText
    color: root.service.busy ? root.dim : Commons.Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    Accessible.role: Accessible.AlertMessage
    Accessible.name: text
  }

  Button {
    visible: root.visible && root.service.connected
    width: parent.width
    iconText: ""
    text: Translations.t("setup.disconnectTunnel", root.uiLanguage)
    focusable: true
    bordered: true
    enabled: !root.service.busy
    foreground: Commons.Color.urgent
    fontFamily: root.fontFamily
    onClicked: root.service.disconnect()
  }

  // Only the current requirement is expanded; completed and next steps are
  // already described by the compact summary and upcoming hint above.
  component StepRow: Column {
    id: step
    property string label: ""
    property string detail: ""
    property string detailObjectName: ""
    property bool done: false
    property bool current: false
    // Inline components cannot see the card's ids; styling is passed in.
    property color foreground: Commons.Color.foreground
    property color highlight: "#FFCE00"
    property string fontFamily: Style.font.family
    readonly property color dim: Qt.darker(foreground, 1.4)

    width: parent ? parent.width : 0
    spacing: Style.space(5)

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: Style.space(16)
        text: ""
        textFormat: Text.PlainText
        color: step.highlight
        font.family: step.fontFamily
        font.pixelSize: Math.round(Style.font.caption * 0.7)
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: Math.max(0, parent.width - Style.space(24))
        text: step.label
        textFormat: Text.PlainText
        color: step.foreground
        font.family: step.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
    }

    Text {
      id: detailText
      objectName: step.detailObjectName
      visible: step.current && !step.done && step.detail !== ""
      width: Math.max(0, parent.width - Style.space(24))
      x: Style.space(24)
      text: step.detail
      textFormat: Text.PlainText
      color: step.dim
      font.family: step.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
