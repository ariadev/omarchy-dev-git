import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Git dashboard. One tab per provider (GitHub, GitLab, Gitea) with a host switch
// inside it, a full-year contribution graph, a grid of open-work counts, and
// the queues of what is actually waiting on you.
Panel {
  id: root
  moduleName: "dev.git"
  ipcTarget: "dev.git"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Octicons from the Nerd Font the bar already draws with.
  readonly property string glyphRequest: ""   // pull/merge request
  readonly property string glyphIssue: ""     // issue
  readonly property string glyphComment: ""   // comment
  readonly property string glyphApproved: "󰄬" // check
  readonly property string glyphStreak: "󰈸"   // flame
  readonly property string glyphRefresh: "󰑐"  // refresh

  // ---------------------------------------------------------------- selection

  readonly property var groups: data.groups

  // Which provider tab is showing, and which host inside each tab. Host choice
  // is remembered per provider so flipping between tabs never resets it.
  property string selectedKind: ""
  property var hostMemory: ({})
  property int hostRevision: 0

  readonly property int groupIndex: {
    for (var i = 0; i < groups.length; i++)
      if (groups[i].kind === selectedKind) return i
    return 0
  }
  readonly property var group: groups.length > 0 ? groups[clamp(groupIndex, 0, groups.length - 1)] : null

  readonly property var provider: {
    var rev = root.hostRevision  // reactive dependency
    var g = root.group
    if (!g || g.hosts.length === 0) return null
    var remembered = root.hostMemory[g.kind]
    for (var i = 0; i < g.hosts.length; i++)
      if (g.hosts[i].key === remembered) return g.hosts[i]
    var preferred = data.preferredHost(g)
    for (var j = 0; j < g.hosts.length; j++)
      if (g.hosts[j].host === preferred) return g.hosts[j]
    return g.hosts[0]
  }

  readonly property int hostIndex: {
    var g = root.group
    var p = root.provider
    if (!g || !p) return 0
    for (var i = 0; i < g.hosts.length; i++)
      if (g.hosts[i].key === p.key) return i
    return 0
  }

  function selectKind(kind) {
    if (kind === "" || kind === root.selectedKind) return
    root.selectedKind = kind
  }

  function stepGroup(delta) {
    if (groups.length < 2) return
    var next = ((groupIndex + delta) % groups.length + groups.length) % groups.length
    root.selectKind(groups[next].kind)
  }

  function selectHost(key) {
    var g = root.group
    if (!g || key === "") return
    var memory = root.hostMemory
    memory[g.kind] = key
    root.hostMemory = memory
    root.hostRevision++
    root.selectedRowIndex = 0
    if (panelFlick) panelFlick.contentY = 0
  }

  function stepHost(delta) {
    var g = root.group
    if (!g || g.hosts.length < 2) return
    var next = ((hostIndex + delta) % g.hosts.length + g.hosts.length) % g.hosts.length
    root.selectHost(g.hosts[next].key)
  }

  function jumpHost(index) {
    var g = root.group
    if (!g || index < 0 || index >= g.hosts.length) return
    root.selectHost(g.hosts[index].key)
  }

  // ---------------------------------------------------------------- cursor

  property bool cursorActive: false
  property int selectedRowIndex: 0

  // Every rendered list flattens into one cursor model, so j/k walks the whole
  // panel top to bottom regardless of how many sections happen to be present.
  readonly property var sections: buildSections(provider)
  readonly property var focusRows: {
    var rows = []
    for (var i = 0; i < sections.length; i++)
      for (var j = 0; j < sections[i].items.length; j++)
        rows.push(sections[i].items[j])
    return rows
  }

  // Row delegates register themselves so the cursor can scroll to a row that
  // is currently off-screen without guessing at layout geometry.
  property var rowItems: ({})
  function registerRow(index, item) { root.rowItems[index] = item }
  function unregisterRow(index, item) { if (root.rowItems[index] === item) delete root.rowItems[index] }

  function sectionOffset(sectionIndex) {
    var offset = 0
    for (var i = 0; i < sectionIndex && i < sections.length; i++) offset += sections[i].items.length
    return offset
  }

  function buildSections(p) {
    if (!p || !p.ready) return []
    var out = []
    function add(key, title, items, total, glyph, urgent) {
      if (!items || items.length === 0) return
      out.push({
        key: key,
        title: title,
        items: items,
        total: Math.max(Number(total || 0), items.length),
        glyph: glyph,
        urgent: urgent === true
      })
    }
    var term = p.mrTermShort.toUpperCase()
    add("review", "AWAITING YOUR REVIEW", p.reviewRequests,
        p.totals.reviewRequests, root.glyphRequest, true)
    add("assigned", "ASSIGNED " + term, p.assignedPrs,
        p.totals.assignedPrs, root.glyphRequest, false)
    add("mine", "YOUR OPEN " + term, p.authoredPrs,
        p.totals.authoredPrs, root.glyphRequest, false)
    add("issues", "ASSIGNED ISSUES", p.assignedIssues,
        p.totals.assignedIssues, root.glyphIssue, false)
    return out
  }

  // Vertical focus zones, top to bottom: the provider tabs, the host switch,
  // then the work rows. Up/Down (or j/k) walks between them and Left/Right
  // (or h/l) moves inside whichever zone holds the cursor, so the panel reads
  // the same way it looks.
  property string focusZone: "provider"

  readonly property bool hostZoneAvailable: !!root.group && root.group.hosts.length > 1

  function zoneOrder() {
    var zones = ["provider"]
    if (root.hostZoneAvailable) zones.push("host")
    if (root.focusRows.length > 0) zones.push("rows")
    return zones
  }

  function enterZone(zone) {
    root.focusZone = zone
    root.cursorActive = zone === "rows"
    if (zone === "rows") root.scrollToSelected()
    else if (panelFlick && zone === "provider") panelFlick.contentY = 0
  }

  function moveZone(dy) {
    var zones = root.zoneOrder()
    var at = zones.indexOf(root.focusZone)
    if (at < 0) at = 0

    if (root.focusZone === "rows" && zones[at] === "rows") {
      // Inside the rows the cursor scrolls first and only leaves the zone
      // when it is already parked on the top row.
      if (dy > 0 || (root.cursorActive && root.selectedRowIndex > 0)) {
        root.moveRows(dy)
        return
      }
    }

    var next = root.clamp(at + dy, 0, zones.length - 1)
    if (zones[next] === root.focusZone) {
      if (root.focusZone === "rows") root.moveRows(dy)
      return
    }
    root.enterZone(zones[next])
  }

  function moveWithinZone(dx) {
    if (root.focusZone === "host") root.stepHost(dx)
    else root.stepGroup(dx)
  }

  function activateZone() {
    if (root.focusZone === "rows") root.activateRow()
    // In the tab and host zones the selection *is* the action; Enter opens the
    // host's own page, which is the only thing left to do there.
    else if (root.provider) root.openUrl(root.provider.userUrl || root.provider.webUrl)
  }

  // A refresh or a host switch can dissolve the zone the cursor sits in.
  onFocusZoneChanged: root.cursorActive = root.focusZone === "rows"
  onHostZoneAvailableChanged: if (!root.hostZoneAvailable && root.focusZone === "host") root.enterZone("provider")

  function moveRows(dy) {
    var n = root.focusRows.length
    if (n === 0) { root.cursorActive = false; return }
    // The first j/k after opening reveals the cursor where it already sits
    // rather than skipping the top row.
    var next = root.cursorActive ? root.selectedRowIndex + dy : root.selectedRowIndex
    root.cursorActive = true
    root.selectedRowIndex = root.clamp(next, 0, n - 1)
    root.scrollToSelected()
  }

  function jumpRows(index) {
    var n = root.focusRows.length
    if (n === 0) return
    root.focusZone = "rows"
    root.cursorActive = true
    root.selectedRowIndex = root.clamp(index, 0, n - 1)
    root.scrollToSelected()
  }

  function activateRow() {
    var rows = root.focusRows
    if (rows.length === 0 || !root.cursorActive) return
    var idx = root.clamp(root.selectedRowIndex, 0, rows.length - 1)
    root.openUrl(rows[idx].url)
  }

  function scrollToSelected() {
    if (!panelFlick || root.focusRows.length === 0) return
    var row = root.rowItems[root.clamp(root.selectedRowIndex, 0, root.focusRows.length - 1)]
    if (!row) return
    var pos = row.mapToItem(panelFlick.contentItem, 0, 0)
    var pad = Style.space(8)
    if (pos.y - pad < panelFlick.contentY)
      panelFlick.contentY = Math.max(0, pos.y - pad)
    else if (pos.y + row.height + pad > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = pos.y + row.height + pad - panelFlick.height
  }

  // ---------------------------------------------------------------- helpers

  // A 1px border that lands exactly on the scrolling area's clip boundary is
  // swallowed on fractional display scales: the clip is a device-pixel scissor
  // rect, and at 1.25x it rounds inward and eats the leftmost column. That is
  // why bordered rows and stat boxes lost their left edge — the ones at x > 0
  // were never affected. Inset the scrolling content so no border ever sits on
  // the boundary.
  readonly property int clipInset: Math.max(1, Style.space(2))

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Countdowns and "updated" read this instead of Date.now() so the panel
  // keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  function timeAgo(iso, now) {
    if (!iso) return ""
    var ms = new Date(iso).getTime()
    if (!isFinite(ms)) return ""
    var seconds = Math.floor(Math.max(0, now - ms) / 1000)
    if (seconds < 60) return "just now"
    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h"
    var days = Math.floor(hours / 24)
    if (days < 30) return days + "d"
    var months = Math.floor(days / 30)
    if (months < 12) return months + "mo"
    return Math.floor(months / 12) + "y"
  }

  function plural(n, one, many) { return n + " " + (n === 1 ? one : many) }

  function groupDigits(n) {
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }

  function heroMeta(p) {
    if (data.loading) return "REFRESHING…"
    if (!p) return ""
    // A stale record is real data the last run could not refresh; date it from
    // when it was actually collected, not from the failed attempt.
    var ago = root.timeAgo(p.stale ? p.staleAt : p.updatedAt, root.nowMs)
    var when = ago === "" || ago === "just now" ? "JUST NOW" : ago.toUpperCase() + " AGO"
    return (p.stale ? "STALE · FROM " : "UPDATED ") + when
  }

  function heroIdentity(p) {
    if (!p) return ""
    if (!p.ready) return p.hostLabel
    var text = "@" + p.username
    if (p.displayName !== "" && p.displayName !== p.username) text = p.displayName + " · " + text
    return text
  }

  function openUrl(url) {
    if (!url || !root.bar) return
    root.bar.run("omarchy launch browser " + Util.shellQuote(url))
    root.close()
  }

  function refreshNow() { data.refreshNow() }

  // Every category maps to a pre-filtered queue page, so a box click lands on
  // the whole list rather than just its top item.
  function categoryUrl(category) {
    var p = root.provider
    if (!p) return ""
    var origin = root.originOf(p.webUrl) || "https://" + p.host
    if (p.kind === "github") {
      var prs = origin + "/pulls?q=" + encodeURIComponent("is:open is:pr ")
      var issues = origin + "/issues?q=" + encodeURIComponent("is:open is:issue ")
      if (category === "review") return prs + encodeURIComponent("review-requested:@me")
      if (category === "assigned") return prs + encodeURIComponent("assignee:@me")
      if (category === "assignedIssues") return issues + encodeURIComponent("assignee:@me")
      if (category === "authoredIssues") return issues + encodeURIComponent("author:@me")
      return prs + encodeURIComponent("author:@me")
    }
    // Gitea's dashboard takes the whole queue in one `type`, and uses the same
    // two pages for issues and pulls that its API search does.
    if (p.kind === "gitea") {
      var giteaPrs = origin + "/pulls?state=open&type="
      var giteaIssues = origin + "/issues?state=open&type="
      if (category === "review") return giteaPrs + "review_requested"
      if (category === "assigned") return giteaPrs + "assigned"
      if (category === "assignedIssues") return giteaIssues + "assigned"
      if (category === "authoredIssues") return giteaIssues + "created_by"
      return giteaPrs + "created_by"
    }
    var user = encodeURIComponent(p.username)
    var mrQueue = origin + "/dashboard/merge_requests?state=opened"
    var issueQueue = origin + "/dashboard/issues?state=opened"
    if (category === "review") return mrQueue + "&reviewer_username=" + user
    if (category === "assigned") return mrQueue + "&assignee_username=" + user
    if (category === "assignedIssues") return issueQueue + "&assignee_username=" + user
    if (category === "authoredIssues") return issueQueue + "&author_username=" + user
    return mrQueue + "&author_username=" + user
  }

  function originOf(url) {
    var match = String(url || "").match(/^(https?:\/\/[^/]+)/)
    return match ? match[1] : ""
  }

  // A white provider mark belongs on a dark panel and a dark one on a light
  // panel; the other order makes the logo disappear into the surface.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * root.colorChannelLuminance(color.r)
      + 0.7152 * root.colorChannelLuminance(color.g)
      + 0.0722 * root.colorChannelLuminance(color.b)
  }

  function iconCandidates(kind, surfaceColor) {
    if (!kind) return []
    var candidates = []
    if (root.colorLuminance(surfaceColor || Color.background) < 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + kind + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + kind + ".svg"))
    return candidates
  }

  // ---------------------------------------------------------------- lifecycle

  onGroupIndexChanged: {
    selectedRowIndex = 0
    if (panelFlick) panelFlick.contentY = 0
  }

  onOpenedChanged: if (opened) {
    focusZone = "provider"
    cursorActive = false
    selectedRowIndex = 0
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    data.refreshOnOpen()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: data
    settings: root.settings
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.stepGroup(1); return "ok" }
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment a provider is found.
  visible: groups.length > 0 || data.collectorError !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰘬"  // source branch
    tooltipText: {
      if (data.collectorError !== "") return "dev.git: collector failed"
      if (data.pendingReviews > 0) return root.plural(data.pendingReviews, "review", "reviews") + " waiting on you"
      return "Git dashboard"
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshNow()
      else if (buttonCode === Qt.MiddleButton) root.stepGroup(1)
      else root.toggle()
    }
  }

  // Unread-style dot: work waiting on your review is the one thing worth
  // pulling the eye to the bar for.
  Rectangle {
    visible: data.pendingReviews > 0
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: Style.space(4)
    anchors.topMargin: Style.space(4)
    width: Style.space(5)
    height: width
    radius: width / 2
    color: root.urgent
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveWithinZone(dx)
        if (dy !== 0) root.moveZone(dy)
      }
      onActivateRequested: root.activateZone()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (t === "[" || t === "H") root.stepHost(-1)
        else if (t === "]" || t === "L") root.stepHost(1)
        // 1-9 jumps straight to a host, which beats stepping through a long
        // list of self-managed instances one at a time.
        else if (t >= "1" && t <= "9") root.jumpHost(t.charCodeAt(0) - 49)
        else if (t === "g") root.jumpRows(0)
        else if (t === "G") root.jumpRows(root.focusRows.length - 1)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          x: root.clipInset
          width: panelFlick.width - root.clipInset * 2
          bottomPadding: root.clipInset
          spacing: Style.space(12)

          // ---------- Provider tabs ----------
          Row {
            id: providerTabs
            visible: root.groups.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.groups.length > 0
              ? (width - spacing * (root.groups.length - 1)) / root.groups.length
              : 0

            Repeater {
              model: root.groups

              Button {
                required property var modelData
                required property int index

                width: providerTabs.cellWidth
                // Just the provider name: which host is in play is the host
                // switch's job, not the tab's.
                text: modelData.name
                selected: index === root.groupIndex
                hasCursor: root.focusZone === "provider" && index === root.groupIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.selectKind(modelData.kind)
              }
            }
          }

          // ---------- Hero: mark · provider · identity ----------
          Item {
            visible: !!root.provider
            width: parent.width
            implicitHeight: Math.max(heroMark.height, heroLabels.implicitHeight, refreshButton.height)

            Item {
              id: heroMark
              property var candidates: root.iconCandidates(root.provider ? root.provider.kind : "", root.surface)
              property string candidatesKey: candidates.join("\n")
              property int candidateIndex: 0
              onCandidatesKeyChanged: candidateIndex = 0

              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.font.display
              height: Style.font.display

              Image {
                id: heroMarkImage
                anchors.fill: parent
                source: heroMark.candidateIndex < heroMark.candidates.length
                  ? heroMark.candidates[heroMark.candidateIndex] : ""
                sourceSize.width: Style.font.display * 2
                sourceSize.height: Style.font.display * 2
                fillMode: Image.PreserveAspectFit
                onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                  Qt.callLater(function() { heroMark.candidateIndex++ })
              }

              Text {
                anchors.centerIn: parent
                visible: heroMarkImage.status !== Image.Ready
                text: button.text
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroMark.right
              anchors.leftMargin: Style.space(14)
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.provider ? root.provider.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              // Plain text, no pill: the signed-in account is context, not a
              // control, and a border here reads as something clickable.
              Text {
                width: parent.width
                text: root.heroIdentity(root.provider)
                visible: text !== ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.heroMeta(root.provider)
                visible: text !== ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.glyphRefresh
              tooltipText: "Refresh now  ·  r"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !data.loading
              onClicked: root.refreshNow()

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 1100
                loops: Animation.Infinite
                running: data.loading
                alwaysRunToEnd: true
              }
            }

            MouseArea {
              anchors.left: heroMark.left
              anchors.right: heroLabels.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openUrl(root.provider
                ? (root.provider.userUrl || root.provider.webUrl) : "")
            }
          }

          // ---------- Host switch ----------
          Column {
            id: hostSection
            visible: !!root.group && root.group.hosts.length > 1
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: hostHeader.implicitHeight

              PanelSectionHeader {
                id: hostHeader
                anchors.left: parent.left
                text: "HOST"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              // The switch is keyboard-first; say so, or nobody finds it.
              Text {
                anchors.right: parent.right
                anchors.baseline: hostHeader.baseline
                text: "← →"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // A Flow, not a Row: self-managed hostnames are long and wrapping
            // beats truncating them into ambiguity.
            Flow {
              width: parent.width
              spacing: Style.spacing.md

              Repeater {
                model: root.group ? root.group.hosts : []

                Button {
                  required property var modelData
                  required property int index

                  // Just the hostname. A tick and an index ahead of it cost
                  // more width than they carry: signed-in state already reads
                  // from the dimmed foreground, and the row is navigated with
                  // the arrows, not by number.
                  text: modelData.hostLabel
                  // Only the hosts that need something from you get a
                  // tooltip; a signed-in host has nothing to explain.
                  tooltipText: modelData.ready ? "" : modelData.authHelpText
                  selected: index === root.hostIndex
                  hasCursor: root.focusZone === "host" && index === root.hostIndex
                  bordered: true
                  foreground: modelData.ready ? root.foreground : root.dim
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  verticalPadding: Style.spacing.xs
                  onClicked: root.selectHost(modelData.key)
                }
              }
            }
          }

          // ---------- Collector could not run ----------
          BorderSurface {
            visible: data.collectorError !== ""
            width: parent.width
            implicitHeight: collectorText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: collectorText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: data.collectorError
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Nothing configured ----------
          Text {
            visible: root.groups.length === 0 && data.collectorError === ""
            width: parent.width
            topPadding: Style.space(24)
            text: "No git providers found.\nSign in with `gh auth login` or `glab auth login`."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Not signed in ----------
          BorderSurface {
            visible: !!root.provider && root.provider.authHelpText !== ""
            width: parent.width
            implicitHeight: authText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: authText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? root.provider.authHelpText : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Activity ----------
          PanelSeparator {
            visible: activitySection.visible
            foreground: root.foreground
          }

          Column {
            id: activitySection
            visible: !!root.provider && root.provider.calendar.supported
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: activityHeader.implicitHeight

              PanelSectionHeader {
                id: activityHeader
                anchors.left: parent.left
                text: "ACTIVITY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                anchors.right: parent.right
                anchors.baseline: activityHeader.baseline
                text: root.provider
                  ? root.groupDigits(root.provider.calendar.total) + " in the last year"
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            YearGraph {
              id: yearGraph
              width: parent.width
              calendar: root.provider ? root.provider.calendar : null
              signature: root.provider ? root.provider.key : ""
            }

            // Streak on the left, intensity key on the right — the graph's
            // own footer, kept out of YearGraph so the canvas owns nothing
            // but the grid.
            Item {
              width: parent.width
              implicitHeight: Math.max(streakText.implicitHeight, legendRow.implicitHeight)

              Text {
                id: streakText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - legendRow.width - Style.space(12)
                text: {
                  var cal = root.provider ? root.provider.calendar : null
                  if (!cal) return ""
                  var parts = []
                  parts.push(cal.current > 0
                    ? root.glyphStreak + " " + root.plural(cal.current, "day streak", "day streak")
                    : "No active streak")
                  if (cal.longest > 0) parts.push("longest " + root.plural(cal.longest, "day", "days"))
                  parts.push("today " + cal.today)
                  return parts.join("  ·  ")
                }
                color: root.provider && root.provider.calendar.current > 0 ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Row {
                id: legendRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  rightPadding: Style.space(3)
                  text: "Less"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: 5

                  Rectangle {
                    required property int index
                    anchors.verticalCenter: parent.verticalCenter
                    width: yearGraph.cell
                    height: yearGraph.cell
                    radius: yearGraph.cell >= 6 ? 2 : 1
                    color: yearGraph.levelColor(index)
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(3)
                  text: "More"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---------- Open work ----------
          PanelSeparator {
            visible: workSection.visible
            foreground: root.foreground
          }

          Column {
            id: workSection
            visible: !!root.provider && root.provider.ready
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "OPEN WORK"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Grid {
              width: parent.width
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)

              readonly property real cellWidth: (width - columnSpacing) / 2

              StatBox {
                width: parent.cellWidth
                value: root.provider ? Number(root.provider.totals.reviewRequests || 0) : 0
                label: "AWAITING REVIEW"
                glyph: root.glyphRequest
                urgent: value > 0
                onActivated: root.openUrl(root.categoryUrl("review"))
              }

              StatBox {
                width: parent.cellWidth
                value: root.provider ? Number(root.provider.totals.assignedPrs || 0) : 0
                label: root.provider ? "ASSIGNED " + root.provider.mrTermShort.toUpperCase() : ""
                glyph: root.glyphRequest
                onActivated: root.openUrl(root.categoryUrl("assigned"))
              }

              StatBox {
                width: parent.cellWidth
                value: root.provider ? Number(root.provider.totals.assignedIssues || 0) : 0
                label: "ASSIGNED ISSUES"
                glyph: root.glyphIssue
                onActivated: root.openUrl(root.categoryUrl("assignedIssues"))
              }

              StatBox {
                width: parent.cellWidth
                value: root.provider ? Number(root.provider.totals.authoredIssues || 0) : 0
                label: "AUTHORED ISSUES"
                glyph: root.glyphIssue
                onActivated: root.openUrl(root.categoryUrl("authoredIssues"))
              }
            }
          }

          // ---------- Queues ----------
          Repeater {
            model: root.sections

            Column {
              id: section
              required property var modelData
              required property int index

              readonly property int offset: root.sectionOffset(index)

              width: column.width
              spacing: Style.space(8)

              PanelSeparator { foreground: root.foreground }

              Item {
                width: parent.width
                implicitHeight: sectionHeader.implicitHeight

                PanelSectionHeader {
                  id: sectionHeader
                  anchors.left: parent.left
                  text: section.modelData.title
                  foreground: section.modelData.urgent && section.modelData.total > 0
                    ? root.urgent : root.foreground
                  fontFamily: root.fontFamily
                }

                // Only shown when the server has more than we fetched, so the
                // panel never quietly pretends a long queue is short.
                Text {
                  anchors.right: parent.right
                  anchors.baseline: sectionHeader.baseline
                  visible: section.modelData.total > section.modelData.items.length
                  text: "showing " + section.modelData.items.length + " of " + section.modelData.total
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Repeater {
                model: section.modelData.items

                WorkRow {
                  required property var modelData
                  required property int index

                  width: section.width
                  item: modelData
                  glyph: section.modelData.glyph
                  emphasis: section.modelData.urgent
                  flatIndex: section.offset + index
                }
              }
            }
          }

          // ---------- Quiet ----------
          Text {
            visible: !!root.provider && root.provider.ready && root.focusRows.length === 0
            width: parent.width
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)
            text: "Nothing open right now. Take the win."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- components

  // A full trailing year of contributions, drawn as one canvas rather than
  // ~370 QML items: the grid is static between refreshes and a scene graph
  // node per day is pure overhead.
  component YearGraph: Item {
    id: graph

    property var calendar: null
    // Identity of the record being drawn. Two hosts produce grids of the same
    // shape, so the canvas needs something that actually differs between them
    // to know a host switch changed the data.
    property string signature: ""

    readonly property var counts: calendar ? calendar.counts : []
    readonly property var levels: calendar ? calendar.levels : []
    readonly property int weeks: calendar ? calendar.weeks : 0
    readonly property int labelWidth: Style.space(24)
    readonly property int pitch: weeks > 0
      ? Math.max(3, Math.floor((width - labelWidth) / weeks)) : 0
    readonly property int gap: pitch >= 7 ? Math.max(1, Style.space(2)) : 1
    readonly property int cell: Math.max(2, pitch - gap)
    readonly property int monthLabelHeight: Math.round(Style.font.caption * 1.4)

    property int hoverIndex: -1

    implicitHeight: monthLabelHeight + pitch * 7

    function levelColor(level) {
      if (level <= 0) return root.alpha(root.foreground, 0.10)
      return root.alpha(root.accent, [0, 0.28, 0.50, 0.74, 1.0][Math.min(4, level)])
    }

    function dateAt(index) {
      if (!calendar || calendar.start === "") return null
      var start = new Date(calendar.start + "T00:00:00")
      if (isNaN(start.getTime())) return null
      start.setDate(start.getDate() + index)
      return start
    }

    function tooltipFor(index) {
      if (index < 0 || index >= counts.length) return ""
      var date = dateAt(index)
      var count = Number(counts[index] || 0)
      var label = count === 0 ? "No contributions" : root.plural(count, "contribution", "contributions")
      if (!date) return label
      var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
      return label + " on " + months[date.getMonth()] + " " + date.getDate() + ", " + date.getFullYear()
    }

    // Month ruler. The collector already worked out which week column opens
    // each month, so this is a straight placement.
    Item {
      id: monthRuler
      anchors.left: parent.left
      anchors.leftMargin: graph.labelWidth
      anchors.top: parent.top
      width: graph.weeks * graph.pitch
      height: graph.monthLabelHeight

      Repeater {
        model: graph.calendar ? graph.calendar.monthStarts : []

        Text {
          required property var modelData
          required property int index

          visible: Number(modelData) > 0
          x: index * graph.pitch
          text: visible
            ? ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][Number(modelData)]
            : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Mon / Wed / Fri only, matching the density both providers settled on.
    Repeater {
      model: [{ row: 1, label: "Mon" }, { row: 3, label: "Wed" }, { row: 5, label: "Fri" }]

      Text {
        required property var modelData

        x: 0
        y: graph.monthLabelHeight + modelData.row * graph.pitch
          + (graph.cell - implicitHeight) / 2
        text: modelData.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Canvas {
      id: grid
      x: graph.labelWidth
      y: graph.monthLabelHeight
      width: graph.weeks * graph.pitch
      height: graph.pitch * 7
      renderStrategy: Canvas.Cooperative

      // One key for every input the painting depends on, so a theme change or
      // a data refresh repaints and nothing else does.
      readonly property string paintKey: [
        graph.signature, graph.counts.length, graph.levels.length,
        graph.calendar ? graph.calendar.end : "",
        graph.calendar ? graph.calendar.total : 0,
        graph.calendar ? graph.calendar.max : 0,
        graph.pitch, graph.cell,
        String(root.accent), String(root.foreground)
      ].join(":")

      onPaintKeyChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var levels = graph.levels
        var total = graph.counts.length
        var radius = graph.cell >= 6 ? 2 : 1
        for (var i = 0; i < total; i++) {
          var col = Math.floor(i / 7)
          var row = i % 7
          ctx.fillStyle = graph.levelColor(Number(levels[i] || 0))
          ctx.beginPath()
          ctx.roundedRect(col * graph.pitch, row * graph.pitch, graph.cell, graph.cell, radius, radius)
          ctx.fill()
        }
        // Today sits last in the series; ring it so "did I ship today" is
        // answerable at a glance.
        if (total > 0) {
          var last = total - 1
          ctx.strokeStyle = root.foreground
          ctx.lineWidth = 1
          ctx.beginPath()
          ctx.roundedRect(Math.floor(last / 7) * graph.pitch + 0.5, (last % 7) * graph.pitch + 0.5,
                          graph.cell - 1, graph.cell - 1, radius, radius)
          ctx.stroke()
        }
      }

      MouseArea {
        id: gridHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton

        onPositionChanged: function(mouse) {
          if (graph.pitch <= 0) { graph.hoverIndex = -1; return }
          var col = Math.floor(mouse.x / graph.pitch)
          var row = Math.floor(mouse.y / graph.pitch)
          var index = col * 7 + row
          graph.hoverIndex = (row >= 0 && row < 7 && index >= 0 && index < graph.counts.length) ? index : -1
        }
        onExited: graph.hoverIndex = -1
      }

      PanelToolTip {
        visible: gridHover.containsMouse && graph.hoverIndex >= 0
        text: graph.tooltipFor(graph.hoverIndex)
        fontFamily: root.fontFamily
        delay: 120
      }
    }

  }

  // One count in the open-work grid; clicking opens the matching queue page.
  component StatBox: CursorSurface {
    id: statBox

    property int value: 0
    property string label: ""
    property string glyph: ""
    property bool urgent: false
    signal activated()

    foreground: root.foreground
    hasCursor: boxHover.containsMouse
    bordered: true
    implicitHeight: Math.max(Style.space(48),
      boxValue.implicitHeight + boxLabel.implicitHeight + Style.spacing.md * 2)

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(9)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: statBox.glyph
        visible: text !== ""
        color: statBox.urgent ? root.urgent : root.alpha(root.foreground, 0.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
      }

      Column {
        width: parent.width - parent.spacing - Style.font.iconLarge
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          id: boxValue
          width: parent.width
          text: String(statBox.value)
          color: statBox.urgent ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          id: boxLabel
          width: parent.width
          text: statBox.label
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: boxHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: statBox.activated()
    }
  }

  // One queue row: state glyph, title, and a meta line that says where it
  // lives and how stale it is. Clicking opens it.
  component WorkRow: CursorSurface {
    id: workRow

    property var item: null
    property string glyph: ""
    property bool emphasis: false
    property int flatIndex: -1

    readonly property string title: item ? item.title : ""
    readonly property string repository: item ? item.repository : ""
    readonly property string url: item ? item.url : ""
    readonly property bool draft: item ? item.draft === true : false
    readonly property bool approved: item ? item.review === "approved" : false
    readonly property bool changesRequested: item ? item.review === "changes_requested" : false
    readonly property int comments: item ? item.comments : 0
    // The collector only fills this in when somebody else opened the row, so
    // your own queues stay uncluttered.
    readonly property string author: item && item.author ? item.author : ""

    readonly property color glyphColor: {
      if (workRow.draft) return root.alpha(root.foreground, 0.35)
      if (workRow.changesRequested) return root.urgent
      if (workRow.approved) return root.accent
      if (workRow.emphasis) return root.urgent
      return root.alpha(root.foreground, 0.60)
    }

    foreground: root.foreground
    hasCursor: root.cursorActive && root.selectedRowIndex === workRow.flatIndex
    implicitHeight: Math.max(Style.space(46),
      rowTitle.implicitHeight + rowMeta.implicitHeight + Style.spacing.md * 2)

    Component.onCompleted: root.registerRow(workRow.flatIndex, workRow)
    Component.onDestruction: root.unregisterRow(workRow.flatIndex, workRow)

    // Line one is the glyph, an optional DRAFT tag, the title, and the age;
    // line two is where it lives and how much conversation it carries. The
    // body is one Column so both lines share a single elide budget.
    Column {
      id: rowBody

      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: rowAge.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Row {
        id: titleRow
        width: parent.width
        spacing: Style.space(8)

        Text {
          id: rowGlyph
          anchors.verticalCenter: parent.verticalCenter
          text: workRow.approved ? root.glyphApproved : workRow.glyph
          color: workRow.glyphColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          id: draftTag
          visible: workRow.draft
          anchors.verticalCenter: parent.verticalCenter
          text: "DRAFT"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 0.8
        }

        Text {
          id: rowTitle
          anchors.verticalCenter: parent.verticalCenter
          width: titleRow.width - rowGlyph.width - titleRow.spacing
            - (draftTag.visible ? draftTag.width + titleRow.spacing : 0)
          text: workRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      Row {
        id: metaRow
        width: parent.width
        spacing: Style.space(8)

        // Indent the meta line under the title rather than under the glyph.
        Item {
          width: rowGlyph.width
          height: 1
        }

        Text {
          id: rowMeta
          width: Math.min(implicitWidth,
            metaRow.width - rowGlyph.width - metaRow.spacing
              - (rowComments.visible ? rowComments.width + metaRow.spacing : 0))
          text: workRow.repository
            + (workRow.item && workRow.item.number > 0 ? "  #" + workRow.item.number : "")
            + (workRow.author !== "" ? "  ·  @" + workRow.author : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideLeft
        }

        Text {
          id: rowComments
          visible: workRow.comments > 0
          text: root.glyphComment + " " + workRow.comments
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Text {
      id: rowAge
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.top: rowBody.top
      text: root.timeAgo(workRow.item ? workRow.item.updatedAt : "", root.nowMs)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }


    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openUrl(workRow.url)
      onEntered: {
        root.focusZone = "rows"
        root.cursorActive = true
        root.selectedRowIndex = workRow.flatIndex
      }
    }
  }
}
