import QtQuick

// Shell boundary stand-in. Tests execute plugin bindings, not Omarchy painting.
Item {
  id: root
  property string text: ""
  property string iconText: ""
  property real horizontalPadding: 8
  property real verticalPadding: 4
  property real fontSize: 14
  property real iconSize: 16
  property bool leftAlign: false
  property bool focusable: true
  property bool bordered: false
  property bool selected: false
  property bool hasCursor: false
  property bool active: false
  property color foreground: "white"
  property color accent: "yellow"
  property color background: "transparent"
  property string tooltipText: ""
  property string fontFamily: ""
  property bool iconSpinning: false
  readonly property bool hot: mouse.containsMouse || hasCursor

  signal clicked()
  signal rightClicked()
  signal hovered(bool isHovered)

  activeFocusOnTab: focusable
  implicitWidth: Math.max(85, (text.length + (iconText ? 3 : 0)) * fontSize * 0.62 + horizontalPadding * 2)
  implicitHeight: 26 + verticalPadding * 2
  Keys.onReturnPressed: if (focusable) root.clicked()
  Keys.onEnterPressed: if (focusable) root.clicked()
  Keys.onSpacePressed: if (focusable) root.clicked()

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabled
    onClicked: root.clicked()
  }
}
