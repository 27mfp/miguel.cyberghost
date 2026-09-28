import QtQuick
import QtQuick.Controls as QQC

// Shell boundary stand-in for Omarchy's small icon action button.
QQC.Button {
  property string iconText: ""
  property string tooltipText: ""
  property color foreground: "white"
  property string fontFamily: ""
  property bool focusable: false
  text: iconText
}
