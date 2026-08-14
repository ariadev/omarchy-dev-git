import QtQuick
import Quickshell
import Quickshell.Io

// Data side of the git bar widget. Everything collection-related lives behind
// gitwork.py, which writes one JSON overview covering both providers; this
// file only runs that script on a schedule, watches the file it writes, and
// exposes normalized provider records to the panel.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string stateDir: stateHome + "/omarchy/git"
  readonly property string overviewPath: stateDir + "/overview.json"
  readonly property string scriptPath: home + "/.config/omarchy/plugins/dev.git/gitwork.py"

  property var overview: ({})
  property int dataRevision: 0
  property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 300)) || 300)
  property double lastRunMs: 0
  property bool running: false

  readonly property bool loading: updateProcess.running

  property var providers: computedProviders()

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function providerEnabled(id) {
    var providers = root.settings && root.settings.providers ? root.settings.providers : null
    if (!providers || !providers[id]) return true
    return providers[id].enabled !== false
  }

  // ------------------------------------------------------------- refresh

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runUpdate()
  }

  Process {
    id: updateProcess
    running: false
    onRunningChanged: root.running = running
    onExited: function(exitCode) {
      if (exitCode === 0) overviewFile.reload()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("git", text.trim())
    }
  }

  FileView {
    id: overviewFile
    path: root.overviewPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.overview = ({})
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      root.overview = parsed && typeof parsed === "object" ? parsed : ({})
    } catch (e) {
      console.warn("git", "Ignoring bad overview", root.overviewPath, e)
      root.overview = ({})
    }
    root.dataRevision++
  }

  // A fresh run on every panel open would hammer the providers (several API
  // calls each); gate behind a short quiet period so reopen-happy clicking
  // doesn't restart the collector every time.
  function runUpdate() {
    if (updateProcess.running) return
    var now = Date.now()
    if (now - root.lastRunMs < 15000) return
    root.lastRunMs = now
    updateProcess.command = ["python3", root.scriptPath, "--output", root.overviewPath]
    updateProcess.running = true
  }

  function refreshNow() { root.runUpdate() }
  function refreshOnOpen() { root.runUpdate() }

  // ------------------------------------------------------------ providers

  function providerHasData(p) {
    return (p.streak && p.streak.days && p.streak.days.length > 0)
      || (p.reviewRequests && p.reviewRequests.length > 0)
      || (p.assignedPrs && p.assignedPrs.length > 0)
      || (p.authoredPrs && p.authoredPrs.length > 0)
      || (p.assignedIssues && p.assignedIssues.length > 0)
      || (p.authoredIssues && p.authoredIssues.length > 0)
  }

  function displayProvider(record) {
    var id = String(record.id || "")
    return {
      providerId: String(record.id || id),
      providerName: String(record.name || id),
      username: String(record.username || ""),
      webUrl: String(record.webUrl || ""),
      host: String(record.host || ""),
      authHelpText: String(record.authHelpText || ""),
      ready: record.ready === true,
      mrTerm: String(record.mrTerm || (id === "github" ? "Pull requests" : "Merge requests")),
      streak: record.streak || ({}),
      reviewRequests: Array.isArray(record.reviewRequests) ? record.reviewRequests : [],
      assignedPrs: Array.isArray(record.assignedPrs) ? record.assignedPrs : [],
      authoredPrs: Array.isArray(record.authoredPrs) ? record.authoredPrs : [],
      assignedIssues: Array.isArray(record.assignedIssues) ? record.assignedIssues : [],
      authoredIssues: Array.isArray(record.authoredIssues) ? record.authoredIssues : []
    }
  }

  function computedProviders() {
    var rev = root.dataRevision
    var result = []
    var map = root.overview.providers || {}
    var ids = Object.keys(map).sort()
    for (var i = 0; i < ids.length; i++) {
      var record = map[ids[i]] || {}
      if (!root.providerEnabled(ids[i])) continue
      var display = displayProvider(record)
      if (display.ready || root.providerHasData(display)) result.push(display)
    }
    return result
  }
}
