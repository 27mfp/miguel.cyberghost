pragma Singleton
import QtQuick

QtObject {
  readonly property var font: ({
      family: "sans-serif",
      body: 16,
      caption: 13
    })
  function space(value) {
    return value
  }
}
