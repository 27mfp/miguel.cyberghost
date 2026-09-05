import QtQuick
import Quickshell
import Quickshell.Io
import "ServiceUtils.js" as ServiceUtils

// Account / package / helper setup has independent process lifetimes.
Item {
  id: root
  required property string runnerPath
  required property string installerPath
  signal checked
  signal registered
  signal sendNotification(string title, string body, string urgency)
  readonly property bool depsBusy: depsProcess.running
  readonly property bool polkitBusy: helperInstallerProcess.running
  readonly property bool busy: depsBusy || polkitBusy || regBusy
  property bool regBusy: false
  property string setupMsg: ""
  property string depsError: ""
  property string polkitStatus: ""
  property string registerOutput: ""
  property string registerError: ""
  property string checkOutput: ""
  property bool readyWg: false
  property bool readyDns: false
  property bool readyRequests: false
  property bool readyCli: false
  property bool cliConfigured: false
  property bool readyCreds: false
  property bool readyPolkit: false
  property bool helperInstalled: false
  property string helperVersion: ""
  property string pluginVersion: ""
  function recheck() {
    if (!checkProcess.running)
      checkProcess.running = true
  }
  function installDeps() {
    if (depsProcess.running)
      return
    depsError = ""
    setupMsg = "Installing system packages (authorize in the dialog)…"
    depsProcess.running = true
  }

  function openHelperInstaller(withPolkit) {
    if (helperInstallerProcess.running)
      return
    polkitStatus = ""
    setupMsg = "A terminal installer was opened. Complete it there; setup will be rechecked when the terminal closes."
    helperInstallerProcess.environment = ({
        "CYBERGHOST_PLUGIN_DIR": root.installerPath.replace(/\/install-helper\.sh$/, ""),
        "CYBERGHOST_HELPER_OPTION": withPolkit === true ? "--with-polkit-rule" : "--no-polkit-rule"
      })
    helperInstallerProcess.command = ["omarchy-launch-terminal", "bash", "-lc", "cd -- \"$CYBERGHOST_PLUGIN_DIR\" && bash ./install-helper.sh \"$CYBERGHOST_HELPER_OPTION\"; rc=$?; printf '\\nInstaller exited with code %s. Press Enter to close.\\n' \"$rc\"; read -r"]
    helperInstallerProcess.running = true
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
    setupMsg = "Linking your CyberGhost account…"
    // Credentials travel once over stdin, never argv, environment or disk.
    registerProcess.environment = ({
        "CG_DEVICE_NAME": Quickshell.env("HOSTNAME") || "omarchy"
      })
    registerProcess.pendingCredentials = JSON.stringify({
      "username": username,
      "password": password
    })
    registerProcess.running = true
  }

  // ---- Setup wizard processes ----
  Process {
    id: depsProcess
    command: ["/usr/bin/pkexec", "/usr/bin/pacman", "-S", "--needed", "--noconfirm", "wireguard-tools", "python-requests"].concat(root.readyDns ? [] : ["openresolv"])
    stdout: SplitParser {
      onRead: function (line) {
        root.depsError = ServiceUtils.appendBounded(root.depsError, line, 4096)
      }
    }
    stderr: SplitParser {
      onRead: function (line) {
        root.depsError = ServiceUtils.appendBounded(root.depsError, line, 4096)
      }
    }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.setupMsg = "Packages installed."
        root.sendNotification("CyberGhost VPN", "Dependencies installed.", "normal")
      } else {
        root.setupMsg = ServiceUtils.cleanProcessError(root.depsError, "Could not install dependencies. Check pacman and try again.")
      }
      root.depsError = ""
      root.recheck()
    }
  }

  Process {
    id: helperInstallerProcess
    onExited: function (exitCode) {
      // The installer is a long-running interactive script in a terminal; we
      // get the terminal's exit code (0 if the user closed it normally, even
      // if the install failed mid-way). Treat any 0 exit as "recheck now" so
      // the user does not have to remember to come back and click the
      // Recheck button. Non-zero exits still surface a manual message.
      if (exitCode === 0) {
        root.polkitStatus = "Installer closed. Rechecking setup…"
        root.setupMsg = "Rechecking setup after the helper installer closed…"
        // give the runner a beat to flush new state on disk before probing it
        root.recheck()
      } else {
        var message = "Installer exited with code " + exitCode + ". Run install-helper.sh from the plugin directory to retry."
        root.polkitStatus = message
        root.setupMsg = message
      }
      helperInstallerProcess.environment = ({})
    }
  }

  Process {
    id: registerProcess
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
      root.regBusy = false
      var out = String(root.registerOutput || "")
      var err = String(root.registerError || "")
      registerProcess.pendingCredentials = ""
      registerProcess.environment = ({})
      if (exitCode === 0) {
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
      root.readyWg = !!d.wg_tools
      root.readyDns = !!d.dns_tools
      root.readyRequests = !!d.requests
      root.readyCli = !!d.cli
      root.cliConfigured = !!d.cli_configured
      root.readyCreds = !!d.credentials
      root.readyPolkit = !!d.helper_installed && !!d.polkit_rule_installed
      root.helperInstalled = !!d.helper_installed
      root.helperVersion = String(d.helper_version || "")
      root.pluginVersion = String(d.plugin_version || "")
      if (!root.readyPolkit && root.polkitStatus === "Passwordless connect enabled.")
        root.polkitStatus = ""
      root.checkOutput = ""
      root.checked()
    }
  }
}
