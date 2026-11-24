pragma Singleton
import QtQuick

QtObject {
  readonly property color foreground: "#eeeeee"
  readonly property color background: "#202020"
  readonly property color urgent: "#ff7777"
  readonly property color accent: "#7aa2f7"
  readonly property var popups: ({ background: "#202020", text: "#eeeeee", border: "#444444" })
}
