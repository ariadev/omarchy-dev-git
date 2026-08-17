import QtQuick
import Quickshell
import Quickshell.Io

// Data side of the git bar widget. Collection lives entirely in the
// collector at bin/gitwork, which writes one JSON overview covering every
// configured host; this file runs it on a schedule, watches the file it
// writes, and exposes the records grouped the way the panel presents them:
// one group per provider (GitHub, GitLab, Gitea), each holding one or more hosts.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property int schemaVersion: 3

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string stateDir: stateHome + "/omarchy/git"
  readonly property string overviewPath: stateDir + "/overview.json"
  // Resolved from this file's own location rather than a hardcoded plugin
  // path, so a renamed install directory or an `omarchy dev link` checkout
  // still finds its collector.
  readonly property string collectorPath: {
    var url = String(Qt.resolvedUrl("bin/gitwork"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  property var overview: ({})
  property int dataRevision: 0
  property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 300)) || 300)
  property double lastRunMs: 0

  // Surfaced verbatim in the panel: a missing `curl` or `jq` stops the
  // collector before it can report anything itself.
  property string collectorError: ""

  readonly property bool loading: updateProcess.running

  property var providers: computedProviders()
  property var groups: computedGroups()

  readonly property int pendingReviews: {
    var total = 0
    for (var i = 0; i < providers.length; i++)
      total += Number(providers[i].totals.reviewRequests || 0)
    return total
  }

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function providerEnabled(kind) {
    var configured = root.settings && root.settings.providers ? root.settings.providers : null
    if (!configured || !configured[kind]) return true
    return configured[kind].enabled !== false
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

    // Kept out of `collectorError` until the exit code says it matters:
    // curl can write transient chatter to stderr on a run that still
    // produces a usable overview.
    property string errorText: ""

    onRunningChanged: if (running) errorText = ""

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        updateProcess.errorText = text.trim()
        if (updateProcess.errorText !== "") console.warn("dev.git", updateProcess.errorText)
      }
    }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.collectorError = ""
        overviewFile.reload()
        return
      }
      // The stderr collector may still be draining; report once it has.
      Qt.callLater(function() {
        root.collectorError = updateProcess.errorText !== ""
          ? updateProcess.errorText
          : "Collector exited with code " + exitCode + "."
      })
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
      console.warn("dev.git", "Ignoring bad overview", root.overviewPath, e)
      root.overview = ({})
    }
    root.dataRevision++
  }

  // A fresh run on every panel open would hammer the providers; gate behind a
  // short quiet period so reopen-happy clicking doesn't restart the collector.
  function runUpdate() {
    if (updateProcess.running) return
    var now = Date.now()
    if (now - root.lastRunMs < 15000) return
    root.lastRunMs = now
    updateProcess.command = [root.collectorPath, "-output", root.overviewPath]
    updateProcess.running = true
  }

  function refreshNow() {
    // An explicit refresh is a user instruction, not a poll: skip the gate.
    root.lastRunMs = 0
    root.runUpdate()
  }

  function refreshOnOpen() { root.runUpdate() }

  // ------------------------------------------------------------ providers

  function normalizeItems(list) {
    if (!Array.isArray(list)) return []
    var rows = []
    for (var i = 0; i < list.length; i++) {
      var raw = list[i] || {}
      rows.push({
        number: Number(raw.number || 0),
        title: String(raw.title || ""),
        repository: String(raw.repository || ""),
        url: String(raw.url || ""),
        updatedAt: String(raw.updatedAt || ""),
        draft: raw.draft === true,
        author: String(raw.author || ""),
        review: String(raw.review || ""),
        comments: Number(raw.comments || 0)
      })
    }
    return rows
  }

  function normalizeCalendar(raw) {
    var cal = raw || {}
    var counts = Array.isArray(cal.counts) ? cal.counts : []
    return {
      supported: cal.supported === true && counts.length > 0,
      start: String(cal.start || ""),
      end: String(cal.end || ""),
      weeks: Number(cal.weeks || 0),
      counts: counts,
      levels: Array.isArray(cal.levels) ? cal.levels : [],
      monthStarts: Array.isArray(cal.monthStarts) ? cal.monthStarts : [],
      total: Number(cal.total || 0),
      current: Number(cal.current || 0),
      longest: Number(cal.longest || 0),
      today: Number(cal.today || 0),
      max: Number(cal.max || 0)
    }
  }

  function normalizeProvider(raw) {
    var record = raw || {}
    var kind = String(record.kind || "")
    return {
      key: String(record.key || kind),
      kind: kind,
      name: String(record.name || kind),
      host: String(record.host || ""),
      hostLabel: String(record.hostLabel || record.host || ""),
      ready: record.ready === true,
      stale: record.stale === true,
      staleAt: String(record.staleAt || ""),
      username: String(record.username || ""),
      displayName: String(record.displayName || ""),
      webUrl: String(record.webUrl || ""),
      userUrl: String(record.userUrl || ""),
      authHelpText: String(record.authHelpText || ""),
      error: String(record.error || ""),
      updatedAt: String(record.updatedAt || ""),
      mrTerm: String(record.mrTerm || (kind === "gitlab" ? "Merge requests" : "Pull requests")),
      mrTermShort: String(record.mrTermShort || (kind === "gitlab" ? "MRs" : "PRs")),
      calendar: normalizeCalendar(record.calendar),
      reviewRequests: normalizeItems(record.reviewRequests),
      assignedPrs: normalizeItems(record.assignedPrs),
      authoredPrs: normalizeItems(record.authoredPrs),
      assignedIssues: normalizeItems(record.assignedIssues),
      authoredIssues: normalizeItems(record.authoredIssues),
      totals: record.totals && typeof record.totals === "object" ? record.totals : ({})
    }
  }

  function computedProviders() {
    var rev = root.dataRevision  // reactive dependency
    if (Number(root.overview.schemaVersion || 0) !== root.schemaVersion) return []
    var raw = Array.isArray(root.overview.providers) ? root.overview.providers : []
    var result = []
    for (var i = 0; i < raw.length; i++) {
      var provider = normalizeProvider(raw[i])
      if (provider.kind === "" || !root.providerEnabled(provider.kind)) continue
      result.push(provider)
    }
    return result
  }

  // One group per provider, holding every host configured for it. The panel
  // shows groups as tabs (so a tab is always just "GitHub", "GitLab" or "Gitea") and
  // hosts as a switch inside the selected tab.
  function computedGroups() {
    var list = root.providers
    var order = []
    var byKind = ({})
    for (var i = 0; i < list.length; i++) {
      var provider = list[i]
      if (!byKind[provider.kind]) {
        byKind[provider.kind] = { kind: provider.kind, name: provider.name, hosts: [] }
        order.push(provider.kind)
      }
      byKind[provider.kind].hosts.push(provider)
    }
    var groups = []
    for (var j = 0; j < order.length; j++) groups.push(byKind[order[j]])
    return groups
  }

  // The host a group should open on: the first signed-in one, so a configured
  // but unauthenticated instance never greets the user with an error screen.
  function preferredHost(group) {
    if (!group || group.hosts.length === 0) return ""
    for (var i = 0; i < group.hosts.length; i++)
      if (group.hosts[i].ready) return group.hosts[i].host
    return group.hosts[0].host
  }
}
