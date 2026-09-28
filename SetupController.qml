import QtQuick
import Quickshell
import Quickshell.Io
import "ServiceUtils.js" as ServiceUtils

// Account / package / legacy-cleanup setup has independent process lifetimes.
Item {
  id: root
  required property string runnerPath
  required property string legacyCleanupPath
  signal checked
  signal registered
  signal sendNotification(string title, string body, string urgency)
  readonly property bool depsBusy: depsProcess.running
  readonly property bool legacyCleanupBusy: legacyCleanupProcess.running
  readonly property bool busy: depsBusy || legacyCleanupBusy || regBusy
  property bool regBusy: false
  property string setupMsg: ""
  property string legacyStatus: ""
  property string registerOutput: ""
  property string registerError: ""
  property string checkOutput: ""
  property bool readyNm: false
  // NetworkManager Polkit result for network-control/settings.modify.own:
  // "yes", "auth" (the shell's Polkit agent asks) or "no".
  property string nmPermission: ""
  property bool readyRequests: false
  property bool readyCli: false
  property bool cliConfigured: false
  property bool readyCreds: false
  // Signed-in identity for the Account section; "native" is the plugin's own
  // login, "legacy" comes from the vendor CLI config the plugin never deletes.
  property string accountName: ""
  property string accountSource: ""
  property string serverList: ""
  // Background sync of every country's servers into the user's own cache,
  // while the login session is valid. The runner paces, locks and resumes.
  readonly property bool syncingServers: syncProcess.running
  property string syncProgress: ""
  property bool legacyHelper: false
  property bool legacyPolkitRule: false
  property string pluginVersion: ""
  function recheck() {
    if (!checkProcess.running)
      checkProcess.running = true
  }

  // Privileged steps use Omarchy's own convention: a visible, themed floating
  // terminal (as the network panel does for custom DNS and the bar does for
  // updates), so sudo prompts and output are never hidden from the user.
  readonly property string terminalLauncher: "omarchy-launch-floating-terminal-with-presentation"

  function installDeps() {
    if (depsProcess.running)
      return
    setupMsg = "Finish installing in the terminal; setup is rechecked when it closes."
    depsProcess.running = true
  }

  function openLegacyCleanup() {
    if (legacyCleanupProcess.running)
      return
    legacyStatus = "Finish the removal in the terminal; setup is rechecked when it closes."
    // The script path reaches bash through the environment, never through
    // the command string, so no quoting of the plugin directory is needed.
    legacyCleanupProcess.environment = ({
        "CYBERGHOST_LEGACY_CLEANUP": root.legacyCleanupPath
      })
    legacyCleanupProcess.running = true
  }

  function registerAccount(username, password) {
    if (regBusy || !username || !password)
      return
    if (username.length > 256 || password.length > 256) {
      setupMsg = "Username and password must be 256 characters or fewer."
      return
    }
    regBusy = true
    registerOutput = ""
    registerError = ""
    // The Link button shows progress; setupMsg is reserved for the outcome.
    setupMsg = ""
    // Credentials travel once over stdin, never argv, environment or disk.
    registerProcess.environment = ({
        "CG_DEVICE_NAME": Quickshell.env("HOSTNAME") || "omarchy"
      })
    registerProcess.pendingCredentials = JSON.stringify({
      "username": username,
      "password": password
    })
    registerProcess.running = true
    registerTimeoutTimer.restart()
  }

  Process {
    id: syncProcess
    objectName: "syncProcess"
    command: ["/usr/bin/python3", root.runnerPath, "sync-servers"]
    stdout: SplitParser {
      onRead: function (line) {
        try {
          var step = JSON.parse(String(line).substring(0, 256))
          if (typeof step.progress === "number" && typeof step.total === "number")
            root.syncProgress = step.progress + "/" + step.total
        } catch (e) {
          // The final summary line is not a progress step.
        }
      }
    }
    onExited: root.syncProgress = ""
  }

  // ---- Setup wizard processes ----
  Process {
    id: depsProcess
    objectName: "depsProcess"
    command: [root.terminalLauncher, "omarchy-pkg-add python-requests"]
    onExited: function (exitCode) {
      root.setupMsg = exitCode === 0 ? "" : "The package terminal could not be opened. Run: omarchy pkg add python-requests"
      root.recheck()
    }
  }

  Process {
    id: legacyCleanupProcess
    objectName: "legacyCleanupProcess"
    command: [root.terminalLauncher, "bash \"$CYBERGHOST_LEGACY_CLEANUP\""]
    onExited: function (exitCode) {
      root.legacyStatus = exitCode === 0 ? "" : "The cleanup terminal could not be opened. Run scripts/remove-legacy-helper.sh from the plugin directory."
      legacyCleanupProcess.environment = ({})
      root.recheck()
    }
  }

  Process {
    id: registerProcess
    property bool timedOut: false
    command: ["/usr/bin/python3", root.runnerPath, "register"]
    property string pendingCredentials: ""
    stdinEnabled: true
    onStarted: {
      write(pendingCredentials + "\n")
      pendingCredentials = ""
    }
    stdout: SplitParser {
      onRead: function (line) {
        root.registerOutput = ServiceUtils.appendBounded(root.registerOutput, line, 4096)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.registerError = ServiceUtils.appendBounded(root.registerError, line, 4096)
      }
    }
    onExited: function (exitCode) {
      registerTimeoutTimer.stop()
      var timedOut = registerProcess.timedOut
      registerProcess.timedOut = false
      root.regBusy = false
      var out = String(root.registerOutput || "")
      var err = String(root.registerError || "")
      registerProcess.pendingCredentials = ""
      registerProcess.environment = ({})
      if (timedOut) {
        root.setupMsg = "Account linking timed out. Check your network and try again."
      } else if (exitCode === 0) {
        root.setupMsg = ""
        root.registered()
        root.sendNotification("CyberGhost VPN", "Account linked. Setup will be rechecked.", "normal")
      } else {
        var cleanErr = ServiceUtils.cleanProcessError(err || out, "Could not link account.")
        root.setupMsg = cleanErr
      }
      root.registerOutput = ""
      root.registerError = ""
      root.recheck()
    }
  }

  // ---- Processes ----
  Process {
    id: checkProcess
    objectName: "checkProcess"
    command: ["/usr/bin/python3", root.runnerPath, "check", "--json"]
    stdout: SplitParser {
      onRead: function (line) {
        root.checkOutput = ServiceUtils.appendBounded(root.checkOutput, line, 4096)
      }
    }
    onExited: function (exitCode) {
      var d = {}
      try {
        var text = String(root.checkOutput || "{}").substring(0, 4096)
        if (exitCode === 0)
          d = JSON.parse(text)
      } catch (e) {
        // An unavailable or older runner leaves the readiness flags false.
      }
      root.readyNm = !!d.nm
      root.nmPermission = typeof d.nm_permission === "string" ? d.nm_permission.substring(0, 8) : ""
      root.readyRequests = !!d.requests
      root.readyCli = !!d.cli
      root.cliConfigured = !!d.cli_configured
      root.readyCreds = !!d.credentials
      root.accountName = typeof d.account === "string" ? d.account.substring(0, 256) : ""
      root.accountSource = typeof d.account_source === "string" ? d.account_source.substring(0, 16) : ""
      root.serverList = d.server_list === "live" || d.server_list === "probe" ? d.server_list : ""
      if (root.serverList === "live" && !syncProcess.running)
        syncProcess.running = true
      root.legacyHelper = !!d.legacy_helper
      root.legacyPolkitRule = !!d.legacy_polkit_rule
      root.pluginVersion = String(d.plugin_version || "")
      root.checkOutput = ""
      root.checked()
    }
  }

  Timer {
    id: registerTimeoutTimer
    interval: 45000
    repeat: false
    onTriggered: {
      if (registerProcess.running) {
        registerProcess.timedOut = true
        registerProcess.running = false
      }
    }
  }
}
