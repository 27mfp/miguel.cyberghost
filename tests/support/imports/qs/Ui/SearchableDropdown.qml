import QtQuick

Item {
  property string label: ""
  property string placeholderText: ""
  property string value: ""
  property var options: []
  property bool popupOpen: false
  property color foreground: "white"
  property string fontFamily: "sans-serif"
  signal changed(string value)
  implicitHeight: 56
}
