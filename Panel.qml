import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Details panel for the download monitor. Three interacting modes:
//   list    - per-category headers with totals up top, repo rows with
//             trend-colored sparklines and bold totals below, footer actions.
//   sel     - compare arming: rows get checkboxes, tap toggles selection.
//   compare - normalized overlay chart of selected repos + legend.
//   add     - add owner/repo: writes the config JSON; the service caches it.
// Reads store.json (written by Service.qml) via a live FileView, so rows,
// totals, sparklines, and colors all update the moment a cache refresh lands.
Panel {
  id: root
  moduleName: "davidhbigelow.ghrepotracker"
  manageIpc: false

  // Text on the dialog card must pair with the CARD background
  // (Color.popups.background), not the bar's adaptive barForeground: when the
  // bar runs transparent over a light wallpaper, barForeground flips dark for
  // bar readability and would render the dialog's text invisible on the card.
  readonly property color panelForeground: Color.popups.text

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property var paths: Model.pathsFor(home)

  property var store: null
  property var config: Model.parseConfig("")
  property string mode: "list"
  property var selection: []
  property var pendingAdds: []
  property var removeSel: []

  // Live refresh progress from the service (refresh-status.json). Rows whose
  // repo is still pending swap their sparkline for a spinner; the chart dims
  // behind a "Refreshing Data" overlay until the cycle drains.
  property var refreshPending: []
  readonly property bool refreshing: root.refreshPending.length > 0
  readonly property int refreshTotal: Model.allEntries(root.config).length
  readonly property int refreshDone: Math.max(0, Math.min(root.refreshTotal,
    root.refreshTotal - root.refreshPending.length))

  // What the rollup, tabs, rows, sparklines and main chart show.
  //   dl      - download counts (default)
  //   stars   - stargazer count (repos without releases still have data)
  //   releases- version/release count
  property string metric: "dl"

  readonly property var metrics: [
    { id: "dl", tip: "Downloads" },
    { id: "stars", tip: "Stars" },
    { id: "releases", tip: "Releases" }
  ]

  // Single-repo pin: tapping a row in list mode pins it so the top chart
  // shows that repo's data only (same period/history navigation applies).
  property string pinned: ""
  readonly property string pinnedName: {
    if (!root.pinned) return ""
    var e = Model.findEntry(root.store, root.pinned)
    return (e && e.name) ? e.name : Model.repoName(root.pinned)
  }

  function metricLabel(m) {
    for (var i = 0; i < root.metrics.length; i++) if (root.metrics[i].id === m) return root.metrics[i].tip
    return m
  }

  property string addUrl: ""
  property string addOwner: ""
  property string addRepo: ""
  property string addCategory: "mine"
  property string addError: ""

  // Theme trend colors for the chart (green = success, red = warning), read
  // from the resolved per-theme colors.toml that Color consumes.
  property color colorSuccess: Color.accent
  property color colorWarning: Color.urgent

  // ALL / MINE / OTHERS tab + timeline period grouping. Each period has a
  // fixed retained windows (30 days / 8 ISO weeks / 12 months / all years).
  property string group: "others"
  property string period: "annual"
  property bool cumulative: false

  // Repo rows visible before a section's list starts scrolling: 3 per section
  // when ALL is selected (two stacked sections), 6 for a single MY/OTHERS view.
  readonly property int sectionRowLimit: root.group === "all" ? 3 : 6

  readonly property var periods: ["daily", "weekly", "monthly", "annual"]
  readonly property var periodUnits: { "daily": "d", "weekly": "w", "monthly": "mo" }
  readonly property var periodWindows: Model.PERIOD_WINDOWS

  readonly property real allTotal: root.chartTotal()
  readonly property string allTrend: root.metric === "dl"
    ? Model.trendFromTotals(root.chartPoints.map(function(point) { return point.v }))
    : "up" // stars/releases are cumulative: they can only ever grow
  readonly property string updatedText: "updated " + root.relativeTime(root.store ? root.store.updated : "")
  readonly property string trackedSummary: {
    var n = root.store ? (root.store.count || 0) : 0
    return n + (n === 1 ? " repo" : " repos") + " · " + root.updatedText.replace("updated ", "")
  }

  // Matching retained timeline for the top chart. In list mode it
  // follows the tab; once repos are selected (compare arming) it follows the
  // selection so the graph previews exactly what Compare will overlay.
  readonly property var chartTimelineData: root.chartTimeline()
  readonly property var chartDomain: Model.periodDomain(root.period, root.chartTimelineData.steps)
  readonly property var chartPoints: {
    var tl = root.chartTimelineData
    var points = []
    for (var i = 0; i < tl.steps.length; i++) points.push({ t: tl.steps[i], v: tl.totals[i] })
    return points
  }
  readonly property string chartStartLabel: {
    return Model.formatDateShort(root.chartDomain.start, root.period)
  }
  readonly property string chartEndLabel: {
    return Model.formatDateShort(root.chartDomain.end, "daily")
  }
  readonly property string windowText: {
    if (root.period === "annual") return "all time"
    return "last " + root.periodWindows[root.period] + (root.periodUnits[root.period] || "")
  }
  readonly property string historySummary: {
    var count = root.chartPoints.length
    if (root.chartTimelineData.source === "star-cohort") {
      var starMode = root.cumulative ? "cumulative star acquisitions" : "by starred date"
      return "Stars " + starMode + " · " + root.windowText + " · unstars unavailable"
    }
    if (root.chartTimelineData.source === "cohort") {
      var cohortMode = root.cumulative ? "cumulative release cohorts" : "by release date"
      return root.metricLabel(root.metric) + " " + cohortMode + " · " + root.windowText + " · " + count + " cohorts"
    }
    var buckets = count + "/" + root.chartDomain.slots + " observed buckets"
    var observedMode = root.cumulative ? "cumulative" : "change"
    return root.metricLabel(root.metric) + " " + observedMode + " · " + root.windowText + " · " + buckets
  }

  function open() {
    ensureDirs()
    storeFile.reload()
    configFile.reload()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    root.opened ? root.close() : root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ------------------------------------------------------------------ data

  FileView {
    id: storeFile
    path: root.paths.storePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.store = Model.parseStore(text())
      root.updatePending()
    }
    onLoadFailed: {
      root.store = null
      root.updatePending()
    }
  }

  FileView {
    id: configFile
    path: root.paths.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.config = Model.parseConfig(text())
      root.updatePending()
    }
    onLoadFailed: root.config = Model.parseConfig("")
  }

  FileView {
    id: themeFile
    path: root.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readThemeColors(text())
    onLoadFailed: root.readThemeColors("")
  }

  FileView {
    id: refreshStatusFile
    path: root.paths.refreshStatusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.refreshPending = Model.parseRefreshStatus(text()).pending
    onLoadFailed: root.refreshPending = []
  }

  // Pull the current theme's green/red so chart trend colors stay in tune when
  // the user switches themes. Falls back to accent/urgent when unset.
  function readThemeColors(raw) {
    function grab(name) {
      var m = String(raw || "").match(new RegExp("^\\s*" + name + "\\s*=\\s*[\"'](#\\w{3,8})[\"']", "m"))
      return m ? m[1] : ""
    }
    var g = grab("green") || grab("bright_green")
    var r = grab("red") || grab("bright_red")
    root.colorSuccess = g !== "" ? g : Color.accent
    root.colorWarning = r !== "" ? r : Color.urgent
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.paths.cacheDir, root.paths.configPath.substring(0, root.paths.configPath.lastIndexOf("/"))]
  }

  Process {
    id: rmProc
  }

  function ensureDirs() {
    mkdirProc.running = true
  }

  // Repos in the config that the service hasn't cached yet show as pending so
  // an add is visible immediately ("fetching…") instead of appearing silently.
  function updatePending() {
    var present = {}
    if (root.store) {
      var mine = root.store.categories && root.store.categories.mine || []
      var others = root.store.categories && root.store.categories.others || []
      for (var i = 0; i < mine.length; i++) present[mine[i].repo] = true
      for (var j = 0; j < others.length; j++) present[others[j].repo] = true
    }
    var pending = []
    var entries = Model.allEntries(root.config)
    for (var k = 0; k < entries.length; k++) {
      if (!present[entries[k].repo]) pending.push({ repo: entries[k].repo, category: entries[k].category })
    }
    root.pendingAdds = pending
  }

  // Project a raw store entry onto the active metric. Rows, tabs, category
  // totals, sparklines, the main chart and compare all consume the result, so
  // switching the metric icon re-skins the whole panel in one place.
  function metricEntry(e, source) {
    var base = {
      repo: e.repo,
      name: e.name,
      category: e.category,
      history: e.history || { days: [], weeks: [], months: [], years: [] },
      cohorts: e.cohorts || { days: [], weeks: [], months: [], years: [] },
      starCohorts: e.starCohorts || { days: [], weeks: [], months: [], years: [] },
      starCohortsUpdatedAt: e.starCohortsUpdatedAt || "",
      lastUpdated: e.lastUpdated || "",
      error: e.error || "",
      pending: e.pending === true
    }
    var selected = source === "cohort" || source === "star-cohort"
      ? (source === "star-cohort"
          ? Model.starCohortTimeline([base], root.period)
          : Model.cohortTimeline([base], root.metric, root.period))
      : (source === "observed"
          ? Model.timelineInDomain(Model.historyTimeline([base], root.metric, root.period), root.period)
          : Model.selectedTimeline([base], root.metric, root.period))
    var timeline = Model.displayTimeline(selected, root.cumulative)
    base.total = root.metric === "stars" ? (e.stars || 0)
      : (root.metric === "releases" ? (e.releaseCount || 0) : (e.total || 0))
    base.totals = timeline.totals
    base.values = timeline.totals
    base.weeks = timeline.buckets
    base.steps = timeline.steps
    base.dayTotals = timeline.totals
    base.trend = Model.trendFromTotals(timeline.totals)
    base.timelineSource = timeline.source
    base.hasData = e.hasData === true || timeline.totals.length > 0
    base.completeHistory = false
    return base
  }

  function listFor(category) {
    var arr = []
    var cats = root.store ? (root.store.categories && root.store.categories[category] || []) : []
    for (var i = 0; i < cats.length; i++) arr.push(root.metricEntry(cats[i]))
    for (var j = 0; j < root.pendingAdds.length; j++) {
      if (root.pendingAdds[j].category === category) {
        arr.push(root.metricEntry({
          repo: root.pendingAdds[j].repo,
          name: Model.repoName(root.pendingAdds[j].repo) + "…",
          category: category,
          total: 0,
          trend: "flat",
          values: [],
          hasData: false,
          pending: true
        }))
      }
    }
    return arr
  }

  // Sum of the active metric across a whole group ("all" | "mine" | "others").
  function metricTotal(g) {
    var sum = 0
    var cats = g === "all" ? ["mine", "others"] : [g]
    for (var c = 0; c < cats.length; c++) {
      var list = root.listFor(cats[c])
      for (var i = 0; i < list.length; i++) sum += list[i].total || 0
    }
    return sum
  }

  // Summaries use the same selected metric and persisted period as the chart.
  function categorySeries(category) {
    return Model.displayTimeline(
      Model.selectedTimeline(root.listFor(category), root.metric, root.period),
      root.cumulative)
  }

  function selectedEntries() {
    var out = []
    for (var i = 0; i < root.selection.length; i++) {
      var e = Model.findEntry(root.store, root.selection[i])
      if (e) out.push(root.metricEntry(e))
    }
    return out
  }

  function chartTotal() {
    if (!root.store) return 0
    if (root.mode === "list" && root.pinned) {
      var pinnedEntry = Model.findEntry(root.store, root.pinned)
      return pinnedEntry ? root.metricEntry(pinnedEntry).total : 0
    }
    if (root.mode !== "list" && root.selection.length) {
      var selected = root.selectedEntries()
      var sum = 0
      for (var i = 0; i < selected.length; i++) sum += selected[i].total || 0
      return sum
    }
    return root.metricTotal(root.group)
  }

  // Select the persisted collection matching the active period, then aggregate
  // the pinned repo, selection, or active group over its common observed range.
  function chartTimeline() {
    var entries = []
    if (root.mode === "list" && root.pinned) {
      var pe = Model.findEntry(root.store, root.pinned)
      if (pe) entries = [root.metricEntry(pe)]
    } else if (root.mode !== "list" && root.selection.length) {
      entries = root.selectedEntries()
    } else {
      entries = root.group === "all" ? root.listFor("mine").concat(root.listFor("others")) : root.listFor(root.group)
    }
    var t0 = Date.now()
    var tl = Model.selectedTimeline(entries, root.metric, root.period)
    var out = Model.displayTimeline(tl, root.cumulative)
    var ms = Date.now() - t0
    console.log("[ghrepotracker] chart " + root.group + "/" + root.metric + "/" + root.period + (root.cumulative ? "/cum" : "/evt")
      + " n=" + out.steps.length
      + " src=" + out.source
      + " pts=" + JSON.stringify(out.steps.slice(0, 14).map(function(t, i) { return new Date(t).toISOString().slice(0, 10) + ":" + out.totals[i] }))
      + " " + ms + "ms")
    return out
  }

  function categoryTotal(category) {
    var list = root.listFor(category)
    var sum = 0
    for (var i = 0; i < list.length; i++) sum += list[i].total || 0
    return sum
  }

  function categoryTrend(category) {
    return Model.trendFromTotals(root.categorySeries(category).totals)
  }

  function categoryDeltaText(category) {
    var series = root.categorySeries(category)
    var totals = series.totals || []
    var dates = series.steps || []
    var n = totals.length
    if (series.source === "cohort") return n + " release-date cohorts"
    if (series.source === "star-cohort") return n + " starred-date acquisition cohorts"
    if (n < 2 || dates.length < 2) return n === 1 ? "baseline captured for " + root.period : "waiting for " + root.period + " history"
    var delta = totals[n - 1] - totals[n - 2]
    var elapsed = dates[n - 1] - dates[n - 2]
    var days = Math.max(1, Math.round(elapsed / 86400000))
    if (!isFinite(days)) return "waiting for " + root.period + " history"
    if (delta === 0) return "no change over " + days + "d"
    return Model.formatDelta(delta) + " over " + days + "d · " + Model.formatRate(delta / days) + "/day"
  }

  function tabText(g) {
    return g.toUpperCase() + " · " + Model.formatNumber(root.metricTotal(g))
  }

  function categorySubtext(category) {
    var count = root.listFor(category).length
    var delta = root.categoryDeltaText(category)
    return count + (count === 1 ? " repo" : " repos") + (delta ? " · " + delta : "")
  }

  function relativeTime(iso) {
    if (!iso) return "never"
    var mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000)
    if (mins < 1) return "just now"
    if (mins < 60) return mins + "m ago"
    var hrs = Math.floor(mins / 60)
    if (hrs < 24) return hrs + "h ago"
    return Math.floor(hrs / 24) + "d ago"
  }

  // ------------------------------------------------------------------ selection

  function isSelected(repo) {
    return root.selection.indexOf(repo) >= 0
  }

  // In remove mode the rows are checked from the remove list instead.
  function isChecked(repo) {
    if (root.mode === "rem") return root.removeSel.indexOf(repo) >= 0
    if (root.mode === "sel") return root.isSelected(repo)
    if (root.mode === "list") return root.pinned === repo
    return false
  }

  function isPinned(repo) {
    return root.pinned === repo
  }

  // Tapping a row in list mode pins/unpins it: only that repo's data drives
  // the top chart while the period/history buttons keep working on it.
  function pinRepo(repo) {
    root.pinned = root.pinned === repo ? "" : repo
  }

  function toggleSelect(repo) {
    var idx = root.selection.indexOf(repo)
    var next = root.selection.slice()
    if (idx >= 0) next.splice(idx, 1)
    else next.push(repo)
    root.selection = next
  }

  function rowClicked(repo) {
    if (root.mode === "sel") root.toggleSelect(repo)
    else if (root.mode === "rem") root.toggleRemove(repo)
    else if (root.mode === "list") root.pinRepo(repo)
  }

  function enterSelect() {
    root.pinned = ""
    root.mode = "sel"
  }

  function cancelSelect() {
    root.mode = "list"
    root.selection = []
  }

  function beginCompare() {
    if (root.selection.length < 2) return
    root.mode = "compare"
  }

  function exitCompare() {
    root.mode = "list"
    root.selection = []
  }

  // ------------------------------------------------------------ remove flow

  function beginRemove() {
    root.removeSel = []
    root.mode = "rem"
  }

  function cancelRemove() {
    root.removeSel = []
    root.mode = "list"
  }

  function toggleRemove(repo) {
    var idx = root.removeSel.indexOf(repo)
    var next = root.removeSel.slice()
    if (idx >= 0) next.splice(idx, 1)
    else next.push(repo)
    root.removeSel = next
  }

  function confirmRemoval() {
    if (root.removeSel.length) root.mode = "confirmRemove"
  }

  function cancelConfirm() {
    root.mode = "rem"
  }

  function removeEntry(repo) {
    return Model.findEntry(root.store, repo) ||
      { repo: repo, name: Model.repoName(repo) + "…", total: 0 }
  }

  // Remove the checked repos from the config, clear the cache files, and let
  // the service rebuild the store (buildStore only mirrors config entries).
  function doRemove() {
    var keep = {}
    for (var i = 0; i < root.removeSel.length; i++) keep[root.removeSel[i]] = true
    var mine = []
    for (var m = 0; m < root.config.categories.mine.length; m++) {
      if (!keep[root.config.categories.mine[m]]) mine.push(root.config.categories.mine[m])
    }
    var others = []
    for (var o = 0; o < root.config.categories.others.length; o++) {
      if (!keep[root.config.categories.others[o]]) others.push(root.config.categories.others[o])
    }
    root.config.categories.mine = mine
    root.config.categories.others = others

    var nextSel = []
    for (var s = 0; s < root.selection.length; s++) {
      if (!keep[root.selection[s]]) nextSel.push(root.selection[s])
    }
    root.selection = nextSel

    var paths = []
    for (var repo in keep) paths.push(Model.cacheFilePath(root.paths, repo))
    if (paths.length) {
      rmProc.command = ["rm", "-f"].concat(paths)
      rmProc.running = true
    }
    writeConfig()
    root.removeSel = []
    root.mode = "list"
  }

  function colorForIndex(i) {
    var colors = [Color.accent, Color.urgent, Color.foreground, Color.muted]
    return colors[i % colors.length]
  }

  function compareSource() {
    var entries = []
    for (var i = 0; i < root.selection.length; i++) {
      var entry = Model.findEntry(root.store, root.selection[i])
      if (entry) entries.push(entry)
    }
    return Model.selectedTimeline(entries, root.metric, root.period).source
  }

  function compareSeries() {
    var out = []
    var entries = []
    var rawEntries = []
    var selection = root.selection
    for (var i = 0; i < selection.length; i++) {
      var raw = Model.findEntry(root.store, selection[i])
      if (raw) rawEntries.push(raw)
    }
    var source = Model.selectedTimeline(rawEntries, root.metric, root.period).source
    for (var i = 0; i < rawEntries.length; i++) {
      var entry = root.metricEntry(rawEntries[i], source)
      if (entry && entry.hasData) { entries.push(entry) }
    }
    if (entries.length === 0) return out

    // Observed changes compare only dates known for every selected repo. Cohort
    // slots are fixed and already contain truthful zero-volume periods.
    if (source === "observed") {
      var maps = []
      var common = []
      for (var m = 0; m < entries.length; m++) {
        var map = {}
        var dates = entries[m].weeks || []
        var rates = entries[m].values || []
        var offset = Math.max(0, dates.length - rates.length)
        for (var r = 0; r < rates.length && r + offset < dates.length; r++) map[dates[r + offset]] = rates[r]
        maps.push(map)
        if (m === 0) for (var date in map) common.push(date)
      }
      common = common.filter(function(date) {
        for (var x = 1; x < maps.length; x++) if (!(date in maps[x])) return false
        return true
      })
      common.sort()
      for (var q = 0; q < entries.length; q++) {
        var observed = []
        for (var z = 0; z < common.length; z++) observed.push(maps[q][common[z]])
        out.push({ name: entries[q].name, repo: entries[q].repo, color: root.colorForIndex(q), values: observed, total: entries[q].total })
      }
      return out
    }

    var maxLen = 0
    for (var j = 0; j < entries.length; j++) {
      if (entries[j].values && entries[j].values.length > maxLen) maxLen = entries[j].values.length
    }
    for (var k = 0; k < entries.length; k++) {
      var values = entries[k].values || []
      var aligned = []
      var pad = maxLen - values.length
      for (var p = 0; p < pad; p++) aligned.push(0)
      for (var v = 0; v < values.length; v++) aligned.push(values[v])
      out.push({ name: entries[k].name, repo: entries[k].repo, color: root.colorForIndex(out.length), values: aligned, total: entries[k].total })
    }
    return out
  }

  // ------------------------------------------------------------------ add / refresh

  function beginAdd() {
    root.addError = ""
    root.addUrl = ""
    root.addOwner = ""
    root.addRepo = ""
    root.addCategory = "mine"
    root.mode = "add"
    Qt.callLater(function() {
      urlField.forceActiveFocus()
    })
  }

  function cancelAdd() {
    root.addError = ""
    root.mode = "list"
  }

  function requestAdd() {
    var check = Model.sanitizeRepo(root.addOwner + "/" + root.addRepo)
    if (!check.valid) {
      root.addError = check.error || "Invalid repository"
      return
    }
    var exists = Model.categoryOf(root.config, check.repo)
    if (exists) {
      root.addError = "Already tracked in " + exists
      return
    }
    root.config.categories[root.addCategory].push(check.repo)
    writeConfig()
    root.addError = ""
    root.addUrl = ""
    root.addOwner = ""
    root.addRepo = ""
    root.updatePending()
    root.mode = "list"
  }

  function writeConfig() {
    var wv = Qt.createQmlObject(
      'import QtQuick; import Quickshell.Io; FileView { atomicWrites: true; printErrors: false; watchChanges: false }',
      root, "panelConfigWriter")
    wv.path = root.paths.configPath
    wv.setText(Model.configText(root.config))
    wv.saved.connect(function(view) { return function() { view.destroy() } }(wv))
    wv.saveFailed.connect(function(view) { return function() { view.destroy() } }(wv))
  }

  function requestRefresh() {
    var wv = Qt.createQmlObject(
      'import QtQuick; import Quickshell.Io; FileView { atomicWrites: true; printErrors: false; watchChanges: false }',
      root, "panelRefreshWriter")
    wv.path = root.paths.refreshRequestPath
    wv.setText(JSON.stringify({ requested: new Date().toISOString() }) + "\n")
    wv.saved.connect(function(view) { return function() { view.destroy() } }(wv))
    wv.saveFailed.connect(function(view) { return function() { view.destroy() } }(wv))
  }

  // ------------------------------------------------------------------ keys

  function handleReturn() {
    if (root.mode === "sel" && root.selection.length >= 2) root.beginCompare()
    else if (root.mode === "rem" && root.removeSel.length) root.confirmRemoval()
    else if (root.mode === "list") root.enterSelect()
  }

  function handleEscape() {
    if (root.mode === "confirmRemove") {
      root.mode = "rem"
    } else if (root.mode === "add" || root.mode === "sel" || root.mode === "rem" || root.mode === "compare") {
      if (root.mode === "rem") root.removeSel = []
      root.mode = "list"
      root.selection = []
      root.addError = ""
    } else {
      root.close()
    }
  }

  // ------------------------------------------------------------------ view

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.mode === "add"
      onReturnRequested: root.handleReturn()
      onCloseRequested: root.handleEscape()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: bodyScroll
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: body.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: body
          width: bodyScroll.width
          spacing: Style.spacing.md

        // ---- title band (stocks-style upper summary) -----------------------
        Item {
          width: parent.width
          height: Math.max(titleLeft.implicitHeight, titleRight.implicitHeight)

          Column {
            id: titleLeft
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "GITHUB REPO TRACKER"
              color: Qt.darker(root.panelForeground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            Text {
              textFormat: Text.PlainText
              text: root.trackedSummary
              color: root.panelForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          Row {
            id: titleRight
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: root.metrics

              Button {
                required property var modelData
                width: Style.space(30)
                height: Style.space(30)
                tooltipText: modelData.tip
                selected: root.metric === modelData.id
                foreground: root.panelForeground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: root.metric = modelData.id

                MetricIcon {
                  anchors.centerIn: parent
                  size: Style.space(16)
                  metric: modelData.id
                  color: parent.selected
                    ? Style.selectedStateColor(parent.foreground, parent.accent)
                    : parent.foreground
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.allTrend === "up" ? "▲" : (root.allTrend === "down" ? "▼" : "—")
              color: root.allTrend === "up" ? root.colorSuccess : (root.allTrend === "down" ? root.colorWarning : Color.muted)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              id: allTotal
              textFormat: Text.PlainText
              text: Model.formatNumber(root.allTotal)
              color: root.panelForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
          }
        }

        // ---- totals timeline + ALL/MINE/OTHERS tabs -------------------------
        Item {
          visible: root.mode === "list" || root.mode === "sel" || root.mode === "rem" || root.mode === "compare"
          width: parent.width
          height: chartBlock.implicitHeight

          Column {
            id: chartBlock
            width: parent.width
            spacing: Style.space(6)

            Item {
              visible: root.mode !== "compare"
              width: parent.width
              height: visible ? Style.space(110) : 0

              TotalsChart {
                id: totalsChart
                anchors.fill: parent
                opacity: root.refreshing ? 0.3 : 1.0
                Behavior on opacity { NumberAnimation { duration: 250 } }
                busy: root.refreshing
                points: root.chartPoints
                domainStart: root.chartDomain.start
                domainEnd: root.chartDomain.end
                slotCount: root.chartDomain.slots
                startLabel: root.chartStartLabel
                endLabel: root.chartEndLabel
                successColor: root.colorSuccess
                warningColor: root.colorWarning
                forceSuccess: root.metric === "stars" ||
                  (root.metric === "releases" && root.chartTimelineData.source === "observed") ||
                  ((root.chartTimelineData.source === "cohort" || root.chartTimelineData.source === "star-cohort") && root.cumulative)
                cohortVolumes: (root.chartTimelineData.source === "cohort" || root.chartTimelineData.source === "star-cohort") && !root.cumulative
              }

              Text {
                anchors.centerIn: parent
                visible: root.refreshing
                textFormat: Text.PlainText
                text: root.refreshTotal > 0
                  ? "Refreshing Data (" + root.refreshDone + "/" + root.refreshTotal + ")"
                  : "Refreshing Data"
                color: root.panelForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              // Pinned repo chip: name with an inline warning-colored close
              // glyph. The whole chip is one click target — tap the name or
              // the ✕ to drop the pin and return to the group chart.
              Item {
                visible: root.mode === "list" && root.pinned !== ""
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.top: parent.top
                anchors.topMargin: Style.space(2)
                width: pinRow.implicitWidth
                height: pinRow.implicitHeight
                opacity: chipMouse.containsMouse ? 1.0 : 0.8

                Row {
                  id: pinRow
                  spacing: Style.space(6)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, Style.space(240))
                    textFormat: Text.PlainText
                    text: root.pinnedName
                    color: root.panelForeground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "✕"
                    color: root.colorWarning
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pinned = ""
                }
              }
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)

              Repeater {
                model: root.periods

                Button {
                  required property string modelData
                  text: modelData.toUpperCase()
                  selected: root.period === modelData
                  foreground: root.panelForeground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  onClicked: {
                    root.period = modelData
                  }
                }
              }

              Button {
                width: Style.space(30)
                height: Style.space(30)
                tooltipText: root.cumulative ? "Show events" : "Show cumulative values"
                selected: root.cumulative
                foreground: root.panelForeground
                accent: Color.accent
                fontFamily: Style.font.family
                  onClicked: root.cumulative = !root.cumulative

                ControlIcon {
                  anchors.centerIn: parent
                  kind: root.cumulative ? "events" : "cumulative"
                  size: Style.space(16)
                  color: parent.selected
                    ? Style.selectedStateColor(parent.foreground, parent.accent)
                    : parent.foreground
                }
              }
            }
          }
        }

        Item {
          visible: root.mode === "list" || root.mode === "sel" || root.mode === "rem"
          width: parent.width
          height: tabsRow.implicitHeight

          Row {
            id: tabsRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.spacing.sm

            Button {
              text: root.tabText("all")
              selected: root.group === "all"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.group = "all"
            }
            Button {
              text: root.tabText("mine")
              selected: root.group === "mine"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.group = "mine"
            }
            Button {
              text: root.tabText("others")
              selected: root.group === "others"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.group = "others"
            }
          }
        }

        // ---- add repo form ------------------------------------------------
        Item {
          visible: root.mode === "add"
          width: parent.width
          height: addColumn.implicitHeight

          Column {
            id: addColumn
            width: parent.width
            spacing: Style.spacing.md

            TextField {
              id: urlField
              width: parent.width
              placeholderText: "https://github.com/owner/repo"
              foreground: root.panelForeground
              text: root.addUrl
              onTextChanged: {
                root.addUrl = text
                var parsed = Model.parseGithubUrl(text)
                if (parsed) {
                  root.addOwner = parsed.owner
                  root.addRepo = parsed.repo
                }
              }
              Keys.onReturnPressed: root.requestAdd()
              Keys.onEnterPressed: root.requestAdd()
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              TextField {
                id: ownerField
                width: (parent.width - parent.spacing) / 2
                placeholderText: "owner"
                foreground: root.panelForeground
                text: root.addOwner
                onTextChanged: root.addOwner = text
                Keys.onReturnPressed: root.requestAdd()
                Keys.onEnterPressed: root.requestAdd()
              }

              TextField {
                id: repoField
                width: (parent.width - parent.spacing) / 2
                placeholderText: "repo"
                foreground: root.panelForeground
                text: root.addRepo
                onTextChanged: root.addRepo = text
                Keys.onReturnPressed: root.requestAdd()
                Keys.onEnterPressed: root.requestAdd()
              }
            }

            Row {
              spacing: Style.spacing.sm

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Repo Classification:"
                color: root.panelForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Button {
                text: "Mine"
                selected: root.addCategory === "mine"
                foreground: root.panelForeground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: root.addCategory = "mine"
              }
              Button {
                text: "Others"
                selected: root.addCategory === "others"
                foreground: root.panelForeground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: root.addCategory = "others"
              }
            }

            Text {
              visible: root.addError !== ""
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.addError
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // ---- compare view ---------------------------------------------------
        Item {
          visible: root.mode === "compare"
          width: parent.width
          height: compareColumn.implicitHeight

          Column {
            id: compareColumn
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: root.compareSource() === "cohort"
                ? "COMPARE · NORMALIZED CURRENT LIFETIME " + root.metricLabel(root.metric).toUpperCase() + " BY RELEASE DATE"
                : (root.compareSource() === "star-cohort"
                    ? "COMPARE · NORMALIZED STAR ACQUISITIONS BY STARRED DATE"
                    : "COMPARE · NORMALIZED " + root.metricLabel(root.metric).toUpperCase() + " CHANGE")
              color: Qt.darker(root.panelForeground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            CompareChart {
              id: chart
              width: parent.width
              series: root.compareSeries()
            }

            Repeater {
              model: root.compareSeries()
              delegate: Row {
                required property var modelData
                width: parent ? parent.width : 0
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(18)
                  height: Style.space(3)
                  anchors.verticalCenter: parent.verticalCenter
                  radius: Style.space(1.5)
                  color: modelData.color
                }

                Text {
                  width: Style.space(170)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData.name
                  color: root.panelForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Sparkline {
                  width: Style.space(90)
                  height: Style.space(20)
                  anchors.verticalCenter: parent.verticalCenter
                  values: modelData.values.slice(-6)
                  lineColor: modelData.color
                }

                Text {
                  width: Style.space(56)
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: Model.formatNumber(modelData.total)
                  color: root.panelForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }
            }

            Button {
              text: "Back to list"
              anchors.horizontalCenter: parent.horizontalCenter
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.exitCompare()
            }
          }
        }

        // ---- confirm remove ------------------------------------------------
        Item {
          visible: root.mode === "confirmRemove"
          width: parent.width
          height: confirmColumn.implicitHeight

          Column {
            id: confirmColumn
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: "REMOVE REPOSITORIES"
              color: Qt.darker(root.panelForeground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Remove " + root.removeSel.length +
                (root.removeSel.length === 1 ? " repo" : " repos") +
                " from tracking? Their cached history will be deleted."
              color: root.panelForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.removeSel

              Row {
                required property string modelData
                width: parent ? parent.width : 0
                spacing: Style.space(10)

                Text {
                  width: Style.space(14)
                  text: "✖"
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width - Style.space(14) - Style.space(56) - Style.space(20)
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.removeEntry(modelData).name
                  color: root.panelForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: Style.space(56)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: Model.formatNumber(root.removeEntry(modelData).total)
                  color: root.panelForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.spacing.md

              Button {
                text: "Remove"
                foreground: root.panelForeground
                accent: Color.urgent
                fontFamily: Style.font.family
                onClicked: root.doRemove()
              }
              Button {
                text: "Back"
                foreground: root.panelForeground
                accent: Color.accent
                fontFamily: Style.font.family
                onClicked: root.cancelConfirm()
              }
            }
          }
        }

        // ---- category lists -------------------------------------------------
        Item {
          visible: root.mode === "list" || root.mode === "sel" || root.mode === "rem"
          width: parent.width
          height: visible ? categoryLists.implicitHeight : 0

          Column {
            id: categoryLists
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.group === "all" ? ["mine", "others"] : [root.group]

              Column {
                required property string modelData
                width: parent.width
                spacing: Style.space(4)

                CategoryHeader {
                  width: parent.width
                  label: modelData === "mine" ? "MINE" : "OTHERS"
                  count: root.listFor(modelData).length
                  subText: root.categorySubtext(modelData)
                  totalText: Model.formatNumber(root.categoryTotal(modelData))
                  trend: root.categoryTrend(modelData)
                  foreground: root.panelForeground
                  accent: root.colorSuccess
                  urgent: root.colorWarning
                  muted: Color.muted
                }

                Flickable {
                  id: sectionScroll
                  width: parent.width
                  clip: true
                  contentWidth: width
                  contentHeight: rowsList.implicitHeight
                  boundsBehavior: Flickable.StopAtBounds
                  interactive: contentHeight > height
                  height: Math.min(rowsList.implicitHeight,
                    root.sectionRowLimit * Style.space(40)
                      + Math.max(0, root.sectionRowLimit - 1) * Style.space(4))

                  Column {
                    id: rowsList
                    width: sectionScroll.width
                    spacing: Style.space(4)

                    Repeater {
                      model: root.listFor(modelData)

                      RepoRow {
                        required property var modelData
                        width: parent.width
                        entry: modelData
                        checkable: root.mode === "sel" || root.mode === "rem"
                        checked: root.isChecked(modelData.repo)
                        pinned: root.mode === "list" && root.isPinned(modelData.repo)
                        refreshing: root.refreshPending.indexOf(modelData.repo) >= 0
                        foreground: root.panelForeground
                        accent: root.colorSuccess
                        urgent: root.colorWarning
                        muted: Color.muted
                        onClicked: root.rowClicked(modelData.repo)
                      }
                    }
                  }
                }

                Rectangle {
                  width: parent.width
                  height: Style.spacing.hairline
                  color: root.panelForeground
                  opacity: 0.12
                }
              }
            }
          }
        }

        // ---- footer ----------------------------------------------------------
        Item {
          visible: root.mode !== "confirmRemove"
          width: parent.width
          height: Math.max(footerLeft.implicitHeight, footerRight.implicitHeight)

          Row {
            id: footerLeft
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            Button {
              visible: root.mode === "rem"
              text: "Remove (" + root.removeSel.length + ")"
              enabled: root.removeSel.length > 0
              selected: true
              foreground: root.panelForeground
              accent: Color.urgent
              fontFamily: Style.font.family
              onClicked: root.confirmRemoval()
            }

            Button {
              visible: root.mode === "rem"
              text: "Cancel"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.cancelRemove()
            }

            Button {
              visible: root.mode === "sel"
              text: "Compare (" + root.selection.length + ")"
              enabled: root.selection.length >= 2
              selected: root.mode === "sel"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.beginCompare()
            }

            Button {
              visible: root.mode === "sel"
              text: "Cancel"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.cancelSelect()
            }

            Button {
              visible: root.mode === "list"
              width: Style.space(30)
              height: Style.space(30)
              tooltipText: "Compare repositories"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.enterSelect()

              ControlIcon {
                anchors.centerIn: parent
                kind: "compare"
                size: Style.space(16)
                color: parent.foreground
              }
            }

            Button {
              visible: root.mode === "list"
              width: Style.space(30)
              height: Style.space(30)
              tooltipText: "Remove repositories"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.beginRemove()

              ControlIcon {
                anchors.centerIn: parent
                kind: "delete"
                size: Style.space(16)
                color: parent.foreground
              }
            }

            Button {
              visible: root.mode === "list"
              width: Style.space(30)
              height: Style.space(30)
              tooltipText: "Add repository"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.beginAdd()

              ControlIcon {
                anchors.centerIn: parent
                kind: "add"
                size: Style.space(16)
                color: parent.foreground
              }
            }
          }

          Button {
            visible: root.mode === "list"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(30)
            height: Style.space(30)
            tooltipText: "Buy me a coffee"
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: Style.font.family
            onClicked: Qt.openUrlExternally("https://www.buymeacoffee.com/davidhbigelow")

            ControlIcon {
              anchors.centerIn: parent
              kind: "mug"
              size: Style.space(16)
              color: parent.foreground
            }
          }

          Row {
            id: footerRight
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            Text {
              visible: root.mode === "list"
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.updatedText
              color: Qt.darker(root.panelForeground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Button {
              visible: root.mode === "add"
              text: "Cancel"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.cancelAdd()
            }

            Button {
              visible: root.mode === "add"
              text: "OK"
              selected: true
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.requestAdd()
            }

            Button {
              visible: root.mode === "list"
              width: Style.space(30)
              height: Style.space(30)
              tooltipText: "Refresh now"
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: Style.font.family
              onClicked: root.requestRefresh()

              ControlIcon {
                anchors.centerIn: parent
                kind: "refresh"
                spinning: root.refreshing
                size: Style.space(16)
                color: parent.foreground
              }
            }
          }
        }
      }
    }
  }
}
}
