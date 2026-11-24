pragma Singleton
import QtQuick

QtObject {
  readonly property int cornerRadius: 6
  readonly property bool reduceMotion: false
  // Match the Omarchy 4.5 panel spacing token used by inline cards.
  readonly property var spacing: ({ panelGap: 14 })
  readonly property var font: ({
      family: "sans-serif",
      body: 16,
      bodySmall: 14,
      subtitle: 16,
      caption: 13,
      icon: 16,
      display: 28
    })
  function space(value) {
    return value
  }
  function duration(ms) { return ms }
}
