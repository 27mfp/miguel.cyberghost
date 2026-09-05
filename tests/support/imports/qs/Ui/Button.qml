import QtQuick
import QtQuick.Controls as QQC

// Shell boundary stand-in. Tests execute plugin bindings, not Omarchy painting.
QQC.Button {
  property bool focusable: true
  property bool bordered: false
  property bool selected: false
  property color foreground: "white"
  property string tooltipText: ""
}
