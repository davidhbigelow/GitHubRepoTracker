import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless service half of the download monitor. Watches the config file,
// keeps one cached JSON file per repo under ~/.local/state/omarchy/ghrepotracker/,
// refreshes stale repos from api.github.com, and mirrors everything into a
// single store.json the widgets watch for live updates.
//
// GitHub API notes:
//   - release and repository metadata use unauthenticated curl requests.
//     Historical star acquisitions use the authenticated gh token indirectly
//     through fetch_star_cohorts.py on each repository refresh.
//   - asset `download_count` is cumulative-forever, so we can only record its
//     value when polled. Daily observations build accurate history over time;
//     GitHub cannot backfill prior download-event dates. Release-asset totals
//     under-count packages served via
//     npm/crates/pypi or GitHub's auto-generated source archives.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property var paths: Model.pathsFor(home)

  property var config: Model.parseConfig("")
  property var cacheDocs: ({})
  property var cacheViews: ({})
  // "loading" until a cache FileView settles (+ "ready" / "failed"), so planFetches
  // never races ahead of the on-disk state and re-fetches what we already have.
  property var viewState: ({})

  // FileViews still waiting for their watchChanges watcher to arm, keyed by name.
  // Also the config we last acted on, so armPoll can re-read a still-missing
  // config once a second without re-logging or re-syncing every time.
  property var unarmed: ({})
  property string configStamp: ""

  property var queue: []
  property var current: null
  property var infoTask: null
  property var starTask: null
  property string starStdout: ""
  property string starStderr: ""
  property int defaultRefreshHours: 24
  property bool fetching: false

  // Live fetch progress for the panel: repos still outstanding this cycle.
  // Written (debounced) to refresh-status.json; the panel spins rows that are
  // pending and dims the chart until the list drains.
  property bool statusActive: false
  property var statusPending: []

  readonly property int refreshHours: {
    var v = Number(root.config && root.config.refreshHours)
    return isFinite(v) && v > 0 ? v : root.defaultRefreshHours
  }

  function log(msg) {
    console.log("[ghrepotracker] " + msg)
  }

  // ------------------------------------------------------------- armed watches

  // Quickshell's FileView only arms its watchChanges watcher when the file it is
  // pointed at can be resolved, and it never arms one afterwards. A view whose
  // *parent directory* does not exist yet comes up permanently dead -- in
  // particular refresh-request.json, which lives in the state dir mkdir has not
  // created at the time this service is constructed. On a first run that leaves
  // the service ignoring the panel's "Refresh now" button for the rest of the
  // session. Re-reading a missing view does arm the watch, so keep reloading the
  // unarmed ones until each lands and then stop -- a fully synced service pays
  // nothing for this. (The config view is registered too: it resolves fine when
  // the settings dir exists, and this keeps it working if it ever does not.)
  function disarm(key) {
    delete root.unarmed[key]
  }

  Timer {
    id: armPoll
    running: true
    interval: 1000
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var keys = Object.keys(root.unarmed)
      for (var i = 0; i < keys.length; i++) {
        var view = root.unarmed[keys[i]]
        if (view) view.reload()
      }
    }
  }

  // ------------------------------------------------------------- config watch

  FileView {
    id: configFile
    path: root.paths.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.disarm("config"); root.onConfigLoaded(text()) }
    onLoadFailed: root.onConfigLoaded("")
  }

  // Manual "refresh now" poke written by the panel's Refresh button.
  FileView {
    id: refreshRequestFile
    path: root.paths.refreshRequestPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.disarm("refreshRequest")
      var request = null
      try { request = JSON.parse(refreshRequestFile.text() || "{}") } catch (e) { request = null }
      if (request && request.requested) {
        // Consume the request so restarting the shell does not repeat a full
        // API scan and burn the unauthenticated hourly quota.
        root.writeJson(root.paths.refreshRequestPath, {}, null)
        root.log("refresh requested")
        root.refreshAllNow()
      }
    }
    onLoadFailed: { /* ignored */ }
  }

  function onConfigLoaded(raw) {
    var next = Model.parseConfig(raw)
    var stamp = next.categories.mine.join(",") + "|" + next.categories.others.join(",")
      + "|" + next.refreshHours
    // armPoll re-reads a still-missing config every second. Only act on a real
    // change so an absent file stays quiet and does not re-run resync forever.
    if (stamp === root.configStamp) return
    root.configStamp = stamp
    root.config = next
    root.log("config: " + next.categories.mine.length +
      " mine, " + next.categories.others.length + " others")
    root.resync()
  }

  // ------------------------------------------------------------- setup

  Process {
    id: mkdirProc
    // Seed refresh-request.json alongside the directory: it is the panel's only
    // way to poke this service, and nothing else creates it before the user's
    // first manual refresh, so without this its watcher never arms on a first
    // run and "Refresh now" is dead for the whole session.
    command: ["sh", "-c",
      "mkdir -p '" + root.paths.cacheDir + "' && { [ -e '"
      + root.paths.refreshRequestPath + "' ] || printf '{}\\n' > '"
      + root.paths.refreshRequestPath + "'; }"]
    onExited: function(code) {
      if (code !== 0) root.log("failed to create cache dir")
      configFile.reload()
      // Both mirrors are panel-facing, and the first scheduled write can land
      // before the directory exists. Emit them now that it does, so the panel's
      // own watchers arm instead of polling forever for a file never written.
      root.scheduleStoreWrite()
      root.scheduleStatusWrite()
    }
  }

  Component.onCompleted: {
    root.unarmed = { config: configFile, refreshRequest: refreshRequestFile }
    mkdirProc.running = true
  }

  // ------------------------------------------------------------- cache views

  // One reactive FileView per tracked repo: existing files seed
  // root.cacheDocs and hand-edits propagate.
  function ensureCacheViews() {
    var entries = Model.allEntries(root.config)
    for (var i = 0; i < entries.length; i++) {
      var repo = entries[i].repo
      if (root.cacheViews[repo]) continue
      var tag = Model.safeSlug(repo)
      var safeRepo = JSON.stringify(repo)
      root.viewState[repo] = "loading"
      // FileView exposes `loaded`/`loadFailed` as C++ *signals*, but `loaded`
      // also shadows a readonly bool property with the same name, so a
      // runtime `.connect()` on it breaks. Wire handlers inline instead: the
      // created component runs in this file's context, so `root` resolves.
      var fv = Qt.createQmlObject(
        'import QtQuick; import Quickshell.Io; FileView {\n' +
        '  watchChanges: true\n' +
        '  printErrors: false\n' +
        '  onLoaded: root.onCacheReady(this, ' + safeRepo + ')\n' +
        '  onLoadFailed: root.onCacheFailed(this, ' + safeRepo + ')\n' +
        '}', root, "cacheView_" + tag)
      fv.path = Model.cacheFilePath(root.paths, repo)
      root.cacheViews[repo] = fv
    }
    // Give async loads a beat to land before deciding what needs fetching.
    queueTimer.restart()
  }

  function onCacheReady(view, name) {
    root.viewState[name] = "ready"
    var oldVersion = 0
    try { oldVersion = JSON.parse(view.text() || "{}").schemaVersion || 0 } catch (e) { oldVersion = 0 }
    var doc = Model.parseCache(view.text())
    if (doc && doc.repo === name) {
      root.cacheDocs[name] = Model.hydrate(doc)
      if (oldVersion !== Model.SCHEMA_VERSION)
        root.writeJson(Model.cacheFilePath(root.paths, name), doc, null)
      root.planFetches()
      root.scheduleStoreWrite()
    }
  }

  function onCacheFailed(view, name) {
    root.viewState[name] = "failed"
    root.planFetches()
  }

  function resync() {
    root.pruneCacheViews()
    root.ensureCacheViews()
  }

  // Drop FileViews and cached docs for repos that left the config (removed via
  // the panel). Their cache JSON files are deleted by the panel; the store is
  // rebuilt without them right here: the destroyed views can no longer fire
  // loadFailed for their deleted files, so without this write nothing else
  // would schedule one and the removed repo would linger in the store until
  // an unrelated fetch happened to land.
  function pruneCacheViews() {
    var keep = {}
    var entries = Model.allEntries(root.config)
    for (var i = 0; i < entries.length; i++) keep[entries[i].repo] = true
    var doomed = []
    for (var repo in root.cacheViews) {
      if (!keep[repo]) doomed.push(repo)
    }
    var dropped = 0
    for (var j = 0; j < doomed.length; j++) {
      var fv = root.cacheViews[doomed[j]]
      if (fv && (typeof fv.destroy === "function")) fv.destroy()
      delete root.cacheViews[doomed[j]]
      delete root.cacheDocs[doomed[j]]
      delete root.viewState[doomed[j]]
      root.log("dropped removed repo " + doomed[j])
      dropped++
    }
    if (dropped > 0) root.scheduleStoreWrite()
  }

  function queuedFor(repo) {
    if (root.current && root.current.repo === repo) return true
    if (root.infoTask && root.infoTask.repo === repo) return true
    if (root.starTask && root.starTask.repo === repo) return true
    for (var i = 0; i < root.queue.length; i++) {
      if (root.queue[i].repo === repo) return true
    }
    return false
  }

  function planFetches() {
    var entries = Model.allEntries(root.config)
    var planned = 0
    for (var i = 0; i < entries.length; i++) {
      var repo = entries[i].repo
      // Wait until the cache view has told us what's on disk before deciding.
      if (root.viewState[repo] === "loading") continue
      if (root.queuedFor(repo)) continue
      var doc = root.cacheDocs[repo]
      if (!doc) {
        root.enqueue({ repo: repo, category: entries[i].category, doc: Model.emptyCache(repo, entries[i].category) })
        planned++
      } else if (Model.isStale(doc, root.refreshHours)) {
        root.enqueue({ repo: repo, category: entries[i].category, doc: doc })
        planned++
      }
    }
    if (planned) root.log("queued " + planned + " repo fetch(es)")
    root.scheduleStoreWrite()
  }

  function refreshAllNow() {
    var entries = Model.allEntries(root.config)
    for (var i = 0; i < entries.length; i++) {
      var repo = entries[i].repo
      var doc = root.cacheDocs[repo]
      if (doc && !root.queuedFor(repo)) root.enqueue({ repo: repo, category: entries[i].category, doc: doc })
    }
    queueTimer.restart()
    if (entries.length) root.log("refresh-all queued")
  }

  function enqueue(task) {
    root.queue.push(task)
    if (root.statusPending.indexOf(task.repo) < 0) root.statusPending.push(task.repo)
    root.statusActive = true
    root.scheduleStatusWrite()
    queueTimer.restart()
  }

  // ------------------------------------------------------------- fetch loop

  Timer {
    id: queueTimer
    interval: 700 // spacing between repos keeps the GitHub API happy
    onTriggered: root.pump()
  }

  function pump() {
    if (root.fetching || root.queue.length === 0) {
      // Drain: nothing queued, nothing in flight (releases, metadata, and
      // star-cohort helpers all done) — close out the refresh cycle.
      if (root.statusActive && !root.fetching && root.queue.length === 0
        && !root.infoTask && !root.starTask) {
        root.statusActive = false
        root.statusPending = []
        root.scheduleStatusWrite()
      }
      return
    }
    var task = root.queue.shift()
    root.current = task
    root.fetching = true
    if (!task.page) task.page = 1
    if (!task.releases) task.releases = []
    root.startFetch(task)
  }

  function startFetch(task) {
    fetchProc.command = Model.fetchCommand(Model.githubUrl(task.repo, task.page))
    fetchProc.running = true
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onPageReceived(text)
    }
    onExited: function(code) {
      // Stream finished and consumed the task normally; otherwise report.
      if (code !== 0 && root.current) root.finishTask(root.current, "HTTP error " + code)
    }
  }

  // Repo metadata (stars, created_at): one extra request per refresh, after the
  // releases finish. Failure just keeps whatever stars/created we already had.
  Process {
    id: infoProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onInfoReceived(text)
    }
    onExited: function(code) {
      if (code !== 0 && root.infoTask) {
        var st = root.infoTask
        root.infoTask = null
        root.finishObservation(st, null, "metadata HTTP error " + code)
      }
    }
  }

  Process {
    id: starProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.starStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.starStderr = text
    }
    onExited: function(code) {
      Qt.callLater(function() { root.onStarCohortsExited(code) })
    }
  }

  function onPageReceived(raw) {
    var task = root.current
    if (!task) return
    var text = String(raw || "").trim()
    if (!text) { root.finishTask(task, "empty response"); return }
    var batch = null
    try { batch = JSON.parse(text) } catch (e) { root.finishTask(task, "bad JSON"); return }
    if (!Array.isArray(batch)) { root.finishTask(task, "unexpected API response"); return }
    task.releases = task.releases.concat(batch)
    if (batch && batch.length >= 100) {
      task.page++
      root.startFetch(task)
    } else {
      root.finishTask(task, "")
    }
  }

  function finishTask(task, err) {
    root.current = null
    if (err) {
      root.fetching = false
      var failed = Model.recordFailure(root.cacheDocs[task.repo] || task.doc, err)
      root.log("failed " + task.repo + ": " + err + " (keeping cached data)")
      root.cacheAndStore(failed, task.repo)
      return
    }
    var sum = Model.sumReleases(task.releases || [])
    var doc = Model.migrateCache(task.doc)
    doc.category = task.category
    doc.cohorts = sum.cohorts
    root.fetchInfo(task.repo, doc, sum)
  }

  // After the releases land, fetch the repo's stars/created date, then cache.
  function fetchInfo(repo, doc, sum) {
    root.infoTask = { repo: repo, doc: doc, sum: sum }
    infoProc.command = Model.fetchCommand(Model.repoInfoUrl(repo))
    infoProc.running = true
  }

  function onInfoReceived(raw) {
    var st = root.infoTask
    if (!st) return
    root.infoTask = null
    var info = Model.parseRepoInfo(raw || "")
    if (!info) {
      root.finishObservation(st, null, "invalid metadata response")
      return
    }
    root.fetchStarCohorts(st, info)
  }

  function helperPath() {
    var resolved = String(Qt.resolvedUrl("fetch_star_cohorts.py"))
    if (resolved.indexOf("file:///") !== 0 || resolved.indexOf("\0") >= 0) return ""
    try { return decodeURIComponent(resolved.substring(7)) } catch (e) { return "" }
  }

  function fetchStarCohorts(st, info) {
    var helper = root.helperPath()
    if (!helper) {
      root.finishObservation(st, info, "historical stars unavailable: invalid helper path")
      return
    }
    root.starTask = { repo: st.repo, doc: st.doc, sum: st.sum, info: info }
    root.starStdout = ""
    root.starStderr = ""
    starProc.command = ["python3", helper, st.repo]
    starProc.running = true
  }

  function onStarCohortsExited(code) {
    var st = root.starTask
    if (!st) return
    root.starTask = null
    var parsed = code === 0 ? Model.parseStarCohorts(root.starStdout) : null
    if (parsed) {
      st.doc.starCohorts = parsed.starCohorts
      st.doc.starCohortsUpdatedAt = parsed.collectedAt
      root.finishObservation(st, st.info, "")
      return
    }
    var detail = String(root.starStderr || "").trim().split("\n")[0]
    if (!detail) detail = code === 0 ? "invalid helper response" : "helper exited " + code
    if (detail.length > 240) detail = detail.substring(0, 240)
    root.finishObservation(st, st.info, "historical stars unavailable: " + detail)
  }

  function finishObservation(st, info, metadataError) {
    var knownStars = st.doc.current ? st.doc.current.stars : 0
    if (info && info.created) st.doc.created = info.created
    st.doc = Model.recordObservation(st.doc, {
      downloads: st.sum.total,
      stars: info ? info.stars : knownStars,
      releases: st.sum.releaseCount,
      assets: st.sum.assetCount
    }, Model.nowIso(), metadataError)
    root.cacheAndStore(st.doc, st.repo)
  }

  function cacheAndStore(doc, repo) {
    root.fetching = false
    root.cacheDocs[repo] = doc
    var doneIdx = root.statusPending.indexOf(repo)
    if (doneIdx >= 0) {
      root.statusPending.splice(doneIdx, 1)
      root.scheduleStatusWrite()
    }
    root.log("cached " + repo + " total=" + doc.current.downloads +
      " releases=" + doc.current.releases + " stars=" + doc.current.stars)
    root.writeJson(Model.cacheFilePath(root.paths, repo), doc, function() {
      root.scheduleStoreWrite()
      queueTimer.restart()
    })
  }

  // ------------------------------------------------------------- writes

  // One throwaway FileView per file (setting a shared writer's path around is
  // racy), atomic so a crash never leaves a half-written JSON blob.
  function writeJson(path, obj, cb) {
    var wv = Qt.createQmlObject(
      'import QtQuick; import Quickshell.Io; FileView { atomicWrites: true; printErrors: false; watchChanges: false }',
      root, "writer_" + Model.safeSlug(path))
    wv.path = path
    wv.setText(JSON.stringify(obj, null, 2) + "\n")
    wv.saved.connect(function(view, done) {
      return function() { view.destroy(); if (done) done() }
    }(wv, cb))
    wv.saveFailed.connect(function(view, done) {
      return function() { view.destroy(); if (done) done() }
    }(wv, cb))
  }

  // ------------------------------------------------------------- store mirror

  function scheduleStoreWrite() {
    if (storeTimer.running) return
    storeTimer.restart()
  }

  Timer {
    id: storeTimer
    interval: 120
    onTriggered: {
      var store = Model.buildStore(root.config, root.cacheDocs)
      root.writeJson(root.paths.storePath, store, null)
    }
  }

  // ------------------------------------------------------------- refresh status

  function scheduleStatusWrite() {
    if (statusTimer.running) return
    statusTimer.restart()
  }

  function writeStatus() {
    root.writeJson(root.paths.refreshStatusPath, {
      active: root.statusActive,
      pending: root.statusPending,
      updatedAt: Model.nowIso()
    }, null)
  }

  Timer {
    id: statusTimer
    interval: 150
    onTriggered: root.writeStatus()
  }

  // ------------------------------------------------------------- daily cadence

  Timer {
    id: staleTimer
    // Check hourly so a repo is refreshed shortly after its configured age,
    // rather than waiting another full refresh interval.
    running: true
    interval: 60 * 60 * 1000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.planFetches()
  }
}
