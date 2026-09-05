import QtQuick
import QtQuick.Controls as QQC

// Shell boundary stand-in. Tests execute plugin bindings, not Omarchy painting.
QQC.Button {
  property string iconText: ""
  horizontalPadding: 8
  verticalPadding: 4
  property real fontSize: 14
  property real iconSize: 16
  property bool leftAlign: false
  property bool focusable: true
  property bool bordered: false
  property bool selected: false
  property color foreground: "white"
  property string tooltipText: ""
}
