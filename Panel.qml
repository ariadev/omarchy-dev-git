import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Git dashboard: per-provider activity streaks, a boxed grid of open
// work counts, and click-to-open queues of what is waiting on you.
Panel {
  id: root
  moduleName: "dev.git"
  ipcTarget: "dev.git"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: data.providers
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false
  property int selectedRowIndex: 0
  // The two lists flatten into one cursor model so j/k walks them together.
  readonly property var focusRows: providerRows(provider)

  // Countdowns and "updated" read this instead of Date.now() so the panel
  // keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() { data.refreshNow() }

  // ---------------------------------------------------------------- helpers

  function shortMrTerm(p) {
    return p && p.providerId === "github" ? "PRs" : "MRs"
  }

  function timeAgo(iso, now) {
    if (!iso) return ""
    var ms = new Date(iso).getTime()
    if (!isFinite(ms)) return ""
    var diff = Math.max(0, now - ms)
    var seconds = Math.floor(diff / 1000)
    if (seconds < 60) return seconds + "s ago"
    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return minutes + "m ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  function itemTitle(item) { return item ? String(item.title || "") : "" }
  function itemRepo(item) {
    return item ? String((item.repository && item.repository.nameWithOwner) || (item.project && item.project.fullPath) || "") : ""
  }
  function itemUrl(item) { return item ? String(item.url || item.webUrl || "") : "" }
  function itemNumber(item) {
    if (!item) return ""
    if (item.number !== undefined) return "#" + item.number
    if (item.iid !== undefined) return "!" + item.iid
    return ""
  }

  function rowMeta(item) {
    var parts = []
    var num = root.itemNumber(item)
    if (num !== "") parts.push(num)
    var repo = root.itemRepo(item)
    if (repo !== "") parts.push(repo)
    var ago = root.timeAgo(root.itemUpdatedAt(item), root.nowMs)
    if (ago !== "") parts.push(ago)
    return parts.join(" · ")
  }

  function itemUpdatedAt(item) { return item ? String(item.updatedAt || "") : "" }

  // ---------------------------------------------------------------- streak

  readonly property var streakDays: provider ? (provider.streak.days || []) : []

  function dayLevel(count) {
    if (count <= 0) return 0
    if (count <= 2) return 1
    if (count <= 5) return 2
    return 3
  }

  function dayColor(level) {
    if (level <= 0) return root.track
    if (level === 1) return root.alpha(root.foreground, 0.35)
    if (level === 2) return root.alpha(root.foreground, 0.60)
    return root.foreground
  }

  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayTooltip(day) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : root.dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var count = Number(day.count || 0)
    return label + " · " + count + (count === 1 ? " contribution" : " contributions")
  }

  function streakSummary(p) {
    var s = p ? (p.streak || null) : null
    if (!s) return ""
    var parts = []
    if (Number(s.current) > 0) parts.push(Number(s.current) + "d current")
    if (Number(s.longest) > 0) parts.push("longest " + Number(s.longest) + "d")
    if (Number(s.total) > 0) parts.push(Number(s.total) + " contributions")
    return parts.join(" · ")
  }

  // ---------------------------------------------------------------- content

  function heroMeta(p) {
    if (!p) return ""
    if (data.loading) return "REFRESHING…"
    var ago = root.timeAgo(p.updatedAt, root.nowMs)
    return ago === "" ? "UPDATED JUST NOW" : "UPDATED " + ago.toUpperCase()
  }

  readonly property bool hasWork: {
    var p = root.provider
    if (!p) return false
    return (p.reviewRequests && p.reviewRequests.length > 0)
      || (p.assignedPrs && p.assignedPrs.length > 0)
      || (p.authoredPrs && p.authoredPrs.length > 0)
      || (p.assignedIssues && p.assignedIssues.length > 0)
      || (p.authoredIssues && p.authoredIssues.length > 0)
  }

  // Every category maps to a pre-filtered queue page, so a box click lands on
  // the whole list, not just the top item.
  function categoryUrl(category) {
    var p = root.provider
    if (!p) return ""
    var user = p.username
    if (p.providerId === "github") {
      if (category === "review") return "https://github.com/pulls?q=is%3Aopen%20review-requested%3A%40me"
      if (category === "assigned") return "https://github.com/pulls?q=is%3Aopen%20assignee%3A%40me"
      if (category === "assignedIssues") return "https://github.com/issues?q=is%3Aopen%20assignee%3A%40me"
      if (category === "authoredIssues") return "https://github.com/issues?q=is%3Aopen%20author%3A%40me"
      return "https://github.com/dashboard/pulls"
    }
    var origin = root.originOf(p.webUrl)
    var mrQueue = origin + "/dashboard/merge_requests"
    var issueQueue = origin + "/dashboard/issues"
    if (category === "review") return mrQueue + "?reviewer_username=" + user + "&state=opened"
    if (category === "assigned") return mrQueue + "?assignee_username=" + user + "&state=opened"
    if (category === "assignedIssues") return issueQueue + "?assignee_username=" + user + "&state=opened"
    if (category === "authoredIssues") return issueQueue + "?author_username=" + user + "&state=opened"
    return mrQueue + "?author_username=" + user + "&state=opened"
  }

  function originOf(url) {
    var match = String(url || "").match(/^(https?:\/\/[^/]+)/)
    return match ? match[1] : ""
  }

  function openUrl(url) {
    if (!url || !root.bar) return
    root.bar.run("omarchy launch browser " + Util.shellQuote(url))
  }

  // ---------------------------------------------------------------- cursor

  function providerRows(p) {
    if (!p) return []
    var rows = []
    var reviews = p.reviewRequests || []
    var mine = p.authoredPrs || []
    for (var i = 0; i < reviews.length; i++) rows.push({ kind: "review", item: reviews[i] })
    for (var j = 0; j < mine.length; j++) rows.push({ kind: "mine", item: mine[j] })
    return rows
  }

  function rowIndexFor(kind, item) {
    var rows = root.focusRows
    for (var i = 0; i < rows.length; i++)
      if (rows[i].kind === kind && rows[i].item === item) return i
    return -1
  }

  function selectRowFor(kind, item) {
    var index = root.rowIndexFor(kind, item)
    if (index < 0) return
    root.selectedRowIndex = index
    root.cursorActive = true
  }

  function moveRows(dy) {
    var n = root.focusRows.length
    if (n === 0) { root.cursorActive = false; return }
    root.cursorActive = true
    root.selectedRowIndex = root.clamp(root.selectedRowIndex + dy, 0, n - 1)
    root.scrollToSelected()
  }

  function activateRow() {
    var rows = root.focusRows
    if (rows.length === 0) return
    var idx = root.clamp(root.selectedRowIndex, 0, rows.length - 1)
    root.openUrl(root.itemUrl(rows[idx].item))
  }

  function findRowItem(kind, item) {
    for (var i = 0; i < reviewRepeater.count; i++) {
      var row = reviewRepeater.itemAt(i)
      if (row && row.item === item) return row
    }
    for (var j = 0; j < mineRepeater.count; j++) {
      var mine = mineRepeater.itemAt(j)
      if (mine && mine.item === item) return mine
    }
    return null
  }

  function scrollToSelected() {
    if (!panelFlick) return
    var rows = root.focusRows
    if (rows.length === 0) return
    var idx = root.clamp(root.selectedRowIndex, 0, rows.length - 1)
    var row = root.findRowItem(rows[idx].kind, rows[idx].item)
    if (!row) return
    var pos = row.mapToItem(panelFlick.contentItem, 0, 0)
    var top = panelFlick.contentY
    var bottom = top + panelFlick.height
    var pad = Style.space(8)
    if (pos.y < top) panelFlick.contentY = Math.max(0, pos.y - pad)
    else if (pos.y + row.height > bottom) panelFlick.contentY = pos.y + row.height - panelFlick.height + pad
  }

  // A fresh scan on every open would hammer the providers; Main gates it
  // behind a quiet period, so reopening the panel only refreshes if enough
  // time has passed.
  onProviderIndexChanged: {
    selectedRowIndex = 0
    if (panelFlick) panelFlick.contentY = 0
  }
  onOpenedChanged: if (opened) {
    cursorActive = false
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
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰘬"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshNow()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0) root.moveRows(dy)
      }
      onActivateRequested: root.activateRow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

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
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: provider mark · name · username ----------
          Item {
            visible: !!root.provider
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: root.provider ? root.provider.providerName : ""
              detail: {
                var p = root.provider
                if (!p) return ""
                var text = "@" + p.username
                if (p.host && p.host !== "gitlab.com") text += " · " + p.host
                return text
              }
              meta: root.heroMeta(root.provider)
              foreground: root.foreground
              fontFamily: root.fontFamily

              iconComponent: Component {
                Item {
                  id: heroMark
                  property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                  property string candidatesKey: candidates.join("\n")
                  property int candidateIndex: 0
                  onCandidatesKeyChanged: candidateIndex = 0

                  width: Style.font.display
                  height: Style.font.display

                  Image {
                    id: heroMarkImage
                    anchors.fill: parent
                    source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
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
              }
            }

            MouseArea {
              anchors.fill: hero
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openUrl(root.provider ? root.provider.webUrl : "")
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No git providers found.\nSign in with `gh auth login` or `glab auth login`."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          Row {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.providers.length > 0
              ? (width - spacing * (root.providers.length - 1)) / root.providers.length
              : 0

            Repeater {
              model: root.providers

              Button {
                required property var modelData
                required property int index

                width: providerSwitch.cellWidth
                text: modelData.providerName
                selected: index === root.providerIndex
                hasCursor: root.cursorActive && index === root.providerIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          // ---------- Not signed in ----------
          BorderSurface {
            visible: !!root.provider && !root.provider.ready && String(root.provider.authHelpText || "") !== ""
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
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Activity streak ----------
          PanelSeparator {
            visible: streakSection.visible
            foreground: root.foreground
          }

          Column {
            id: streakSection
            visible: root.streakDays.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "ACTIVITY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: streakStrip
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.streakDays

                DayCell {
                  required property var modelData
                  required property int index

                  day: modelData
                  level: root.dayLevel(Number(modelData.count || 0))
                  today: String(modelData.date || "") === root.todayDate()
                }
              }
            }

            Text {
              id: streakSummaryText
              visible: text !== ""
              width: parent.width
              text: root.streakSummary(root.provider)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Work grid ----------
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

            Row {
              width: parent.width
              spacing: Style.space(8)

              StatBox {
                width: (parent.width - parent.spacing) / 2
                value: String(root.provider.reviewRequests.length)
                label: "AWAITING REVIEW"
                tooltipText: "Open " + root.shortMrTerm(root.provider) + " that need your review"
                urgent: root.provider.reviewRequests.length > 0
                onActivated: root.openUrl(root.categoryUrl("review"))
              }

              StatBox {
                width: (parent.width - parent.spacing) / 2
                value: String(root.provider.assignedPrs.length)
                label: "ASSIGNED " + root.shortMrTerm(root.provider).toUpperCase()
                tooltipText: "Open " + root.shortMrTerm(root.provider) + " assigned to you"
                onActivated: root.openUrl(root.categoryUrl("assigned"))
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              StatBox {
                width: (parent.width - parent.spacing) / 2
                value: String(root.provider.assignedIssues.length)
                label: "ASSIGNED ISSUES"
                tooltipText: "Open issues assigned to you"
                onActivated: root.openUrl(root.categoryUrl("assignedIssues"))
              }

              StatBox {
                width: (parent.width - parent.spacing) / 2
                value: String(root.provider.authoredIssues.length)
                label: "AUTHORED ISSUES"
                tooltipText: "Open issues you opened"
                onActivated: root.openUrl(root.categoryUrl("authoredIssues"))
              }
            }
          }

          // ---------- Waiting on your review ----------
          PanelSeparator {
            visible: reviewSection.visible
            foreground: root.foreground
          }

          Column {
            id: reviewSection
            visible: !!root.provider && root.provider.reviewRequests.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "AWAITING REVIEW"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              id: reviewRepeater
              model: root.provider ? (root.provider.reviewRequests || []) : []

              WorkRow {
                required property var modelData
                required property int index

                width: reviewSection.width
                item: modelData
                kind: "review"
                hasCursor: root.cursorActive && root.rowIndexFor("review", modelData) === root.selectedRowIndex
                onClicked: root.openUrl(root.itemUrl(modelData))
              }
            }
          }

          // ---------- Your open MRs ----------
          PanelSeparator {
            visible: mineSection.visible
            foreground: root.foreground
          }

          Column {
            id: mineSection
            visible: !!root.provider && root.provider.authoredPrs.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "MY OPEN " + (root.provider ? root.provider.mrTerm.toUpperCase() : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              id: mineRepeater
              model: root.provider ? (root.provider.authoredPrs || []) : []

              WorkRow {
                required property var modelData
                required property int index

                width: mineSection.width
                item: modelData
                kind: "mine"
                hasCursor: root.cursorActive && root.rowIndexFor("mine", modelData) === root.selectedRowIndex
                onClicked: root.openUrl(root.itemUrl(modelData))
              }
            }
          }

          // ---------- Quiet / empty ----------
          Text {
            visible: !!root.provider && root.provider.ready && !root.hasWork
            width: parent.width
            topPadding: Style.space(4)
            text: "Nothing open right now. Take the win."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          // ---------- Footer hint ----------
          Text {
            visible: !!root.provider
            width: parent.width
            topPadding: Style.space(2)
            text: "J/K ROWS · H/L PROVIDER · ENTER OPEN · R REFRESH · TAB SWITCH"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // White-mark twin for light surfaces, same convention as the agents plugin.
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

  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (root.colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment a provider is found.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // One commit-ish cell in the streak strip.
  component DayCell: Item {
    id: dayCell
    property var day: null
    property int level: 0
    property bool today: false

    readonly property int cellSize: Style.space(18)
    width: cellSize
    height: cellSize

    Rectangle {
      anchors.fill: parent
      radius: Math.max(2, Style.space(2))
      color: root.dayColor(dayCell.level)
      border.width: dayCell.today ? 1 : 0
      border.color: root.foreground
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayCell.day)
      fontFamily: root.fontFamily
    }
  }

  // One count in the 2x2 grid; click opens the matching queue page.
  component StatBox: BorderSurface {
    id: statBox
    property string value: ""
    property string label: ""
    property string tooltipText: ""
    property bool urgent: false
    property bool hovered: false
    signal activated()

    color: hovered ? root.hoverFill : root.alpha(root.foreground, 0.05)
    borderSpec: hovered
      ? Border.controlSpec("hover-cursor", root.foreground, Color.accent)
      : Border.flat(root.alpha(root.foreground, 0.12), 1)
    radius: Style.cornerRadius
    implicitHeight: Math.max(Style.space(46), boxValue.implicitHeight + boxLabel.implicitHeight + Style.spacing.md * 2)

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Text {
        id: boxValue
        width: parent.width
        text: statBox.value
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

    MouseArea {
      id: boxHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: statBox.hovered = true
      onExited: statBox.hovered = false
      onClicked: statBox.activated()
    }

    PanelToolTip {
      visible: boxHover.containsMouse
      text: statBox.tooltipText
      fontFamily: root.fontFamily
    }
  }

  // One PR/MR row; click opens it in the browser.
  component WorkRow: Item {
    id: workRow
    property var item: null
    property string kind: ""
    property bool hasCursor: false
    signal clicked()

    implicitHeight: Math.max(titleText.implicitHeight + metaText.implicitHeight + Style.spacing.md * 2, Style.space(46))

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: workRow.hasCursor ? root.track : "transparent"
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Text {
        id: titleText
        width: parent.width
        text: root.itemTitle(workRow.item)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        id: metaText
        width: parent.width
        text: root.rowMeta(workRow.item)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: workRow.clicked()
      onEntered: root.selectRowFor(workRow.kind, workRow.item)
    }

    PanelToolTip {
      visible: rowHover.containsMouse
      text: root.itemUrl(workRow.item)
      fontFamily: root.fontFamily
    }
  }
}
