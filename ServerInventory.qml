import QtQuick
import Quickshell.Io
import "ServiceUtils.js" as Logic

// Optional, unprivileged request. Results only belong to the captured selection.
Item {
  id: root
  property string country: "PT"
  property string countryName: "Portugal"
  property string protocol: "wireguard"
  property string mode: "traffic"
  property bool cliAvailable: false
  property string runnerPath: ""
  readonly property bool loading: process.running
  property var options: Logic.serverOptions([], countryName)
  property string error: ""
  property string requestKey: ""
  property string output: ""
  property string errors: ""
  signal loaded(var options)

  function refresh() {
    options = Logic.serverOptions([], countryName)
    error = ""
    if (protocol !== "wireguard" || mode !== "traffic")
      return
    if (!cliAvailable) {
      error = "Exact servers need CLI setup. Automatic selection remains available."
      return
    }
    if (process.running)
      return
    requestKey = country + "|" + protocol + "|" + mode
    output = ""
    errors = ""
    process.command = ["/usr/bin/python3", runnerPath, "servers", "--country", country, "--server-type", mode]
    process.running = true
  }

  Process {
    id: process
    stdout: SplitParser {
      onRead: function (line) {
        root.output = Logic.appendBounded(root.output, line, 32768)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.errors = Logic.appendBounded(root.errors, line, 4096)
      }
    }
    onExited: function (exitCode) {
      if (!Logic.inventoryMatches(root.requestKey, root.country, root.protocol, root.mode) || !root.cliAvailable) {
        root.refresh()
        return
      }
      var rows = []
      try {
        rows = JSON.parse(root.output)
      } catch (e) {}
      root.options = Logic.serverOptions(rows, root.countryName)
      if (root.options.length === 1)
        root.error = Logic.cleanProcessError(root.errors, "No exact servers returned. Automatic selection remains available.")
      root.output = ""
      root.errors = ""
      root.loaded(root.options)
    }
  }
}
