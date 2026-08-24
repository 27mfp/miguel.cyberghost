import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color innerColor: Color.background
  property color badgeColor: Color.urgent
  property bool active: false
  property bool connecting: false
  property bool crossed: false
  property bool warning: false
  property bool reducedMotion: false

  width: Math.round(iconSize * 0.95)
  height: Math.round(iconSize)
  implicitWidth: width
  implicitHeight: height

  readonly property real w: width
  readonly property real h: height

  opacity: connecting ? 0.6 : (active ? 1.0 : 0.65)

  // Pulse while connecting/disconnecting (sole owner of `opacity` while running)
  SequentialAnimation on opacity {
    running: root.connecting && !root.reducedMotion
    loops: Animation.Infinite
    NumberAnimation { to: 0.35; duration: 650; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutSine }
  }

  Shape {
    id: ghostShape
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.w * 0.12
      startY: root.h * 0.45

      // Left side up into dome
      PathCubic {
        control1X: root.w * 0.12
        control1Y: root.h * 0.05
        control2X: root.w * 0.30
        control2Y: 0
        x: root.w * 0.50
        y: 0
      }

      // Dome over to right side
      PathCubic {
        control1X: root.w * 0.70
        control1Y: 0
        control2X: root.w * 0.88
        control2Y: root.h * 0.05
        x: root.w * 0.88
        y: root.h * 0.45
      }

      // Right side down
      PathLine {
        x: root.w * 0.88
        y: root.h * 0.80
      }

      // Scallop 3 (right)
      PathQuad {
        controlX: root.w * 0.75
        controlY: root.h * 1.0
        x: root.w * 0.63
        y: root.h * 0.84
      }

      // Scallop 2 (center)
      PathQuad {
        controlX: root.w * 0.50
        controlY: root.h * 1.0
        x: root.w * 0.37
        y: root.h * 0.84
      }

      // Scallop 1 (left)
      PathQuad {
        controlX: root.w * 0.25
        controlY: root.h * 1.0
        x: root.w * 0.12
        y: root.h * 0.80
      }

      // Left side back to start
      PathLine {
        x: root.w * 0.12
        y: root.h * 0.45
      }
    }
  }

  // Sunglasses / Visor - CyberGhost signature feature
  Item {
    id: glasses
    anchors.fill: parent

    // Left lens
    Rectangle {
      x: root.w * 0.22
      y: root.h * 0.32
      width: Math.max(3, root.w * 0.23)
      height: Math.max(2, root.h * 0.18)
      radius: height * 0.4
      color: root.innerColor
      rotation: 5
    }

    // Right lens
    Rectangle {
      x: root.w * 0.55
      y: root.h * 0.32
      width: Math.max(3, root.w * 0.23)
      height: Math.max(2, root.h * 0.18)
      radius: height * 0.4
      color: root.innerColor
      rotation: -5
    }

    // Bridge
    Rectangle {
      x: root.w * 0.42
      y: root.h * 0.34
      width: Math.max(2, root.w * 0.16)
      height: Math.max(1, root.h * 0.06)
      color: root.innerColor
    }

    // Cute smirk smile
    Rectangle {
      x: root.w * 0.42
      y: root.h * 0.60
      width: Math.max(2, root.w * 0.18)
      height: Math.max(1, root.h * 0.05)
      radius: height / 2
      color: root.innerColor
      rotation: 4
    }
  }

  // Crossed-out slash when disconnected/disabled
  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.25
    height: Math.max(2, parent.height * 0.12)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  // Warning badge
  BorderSurface {
    visible: root.warning
    width: Math.max(8, parent.width * 0.44)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.7)
      font.bold: true
    }
  }
}
