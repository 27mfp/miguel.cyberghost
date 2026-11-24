import QtQuick
import QtQuick.Controls as QQC

// Shell boundary stand-in for Omarchy's small icon action button. Mirror the
// host control's keyboard activation (Ui/PanelActionButton.qml): relying on
// QQC.Button's style-dependent Return handling made the onboarding test pass on
// one Qt build and fail on another.
QQC.Button {
  id: root
  property string iconText: ""
  property string tooltipText: ""
  property color foreground: "white"
  property string fontFamily: ""
  property bool focusable: false
  property bool bordered: false
  property bool hasCursor: false
  property real size: 23
  implicitWidth: size
  implicitHeight: size
  activeFocusOnTab: focusable
  Keys.onReturnPressed: if (focusable) root.clicked()
  Keys.onEnterPressed: if (focusable) root.clicked()
  Keys.onSpacePressed: if (focusable) root.clicked()
  text: iconText
}
