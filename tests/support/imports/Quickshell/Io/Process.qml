import QtQuick

// Process boundary double: tests deliver output and exit signals explicitly.
Item {
  property var command: []
  property bool running: false
  property QtObject stdout: null
  property QtObject stderr: null
  property var environment: ({})
  property bool stdinEnabled: false
  signal started
  signal exited(int exitCode)
  function write(value) {
  }
  function startDetached() {
  }
  function closeWriteChannel() {
  }
}
