import QtQuick

// Only the real shell paints themed borders; fixture keeps this property
// available for components that attach host border specs.
Rectangle {
  property var borderSpec: null
}
