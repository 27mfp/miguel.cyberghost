import QtQuick
import QtQuick.Controls as QQC

QQC.TextField {
  property color foreground: "white"
  property bool password: false
  echoMode: password ? TextInput.Password : TextInput.Normal
}
