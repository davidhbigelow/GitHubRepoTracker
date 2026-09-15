// Pure JS model for the GitHub download monitor. No Qt/QML types are
// referenced: QML callers pass in paths and colors explicitly.

// ---- paths ----------------------------------------------------------------

function pathsFor(home) {
  return {
    cacheDir: home + "/.local/state/omarchy/ghrepotracker/",
    configPath: home + "/.config/omarchy/settings/ghrepotracker.json",
    storePath: home + "/.local/state/omarchy/ghrepotracker/store.json",
    refreshRequestPath: home + "/.local/state/omarchy/ghrepotracker/refresh-request.json",
    refreshStatusPath: home + "/.local/state/omarchy/ghrepotracker/refresh-status.json"
  }
}

function safeSlug(repo) {
  return String(repo || "").replace(/[^A-Za-z0-9._-]/g, "_")
}

function cacheFilePath(paths, repo) {
  var slug = safeSlug(repo).split("/").join("__")
  return paths.cacheDir + slug + ".json"
}

// ---- config ----------------------------------------------------------------

function parseConfig(raw) {
  var doc = { categories: { mine: [], others: [] }, refreshHours: 24 }
  try {
    var parsed = JSON.parse(raw || "{}")
    var cat = parsed.categories || {}
    doc.categories.mine = Array.isArray(cat.mine) ? cat.mine.slice() : []
    doc.categories.others = Array.isArray(cat.others) ? cat.others.slice() : []
    var refreshHours = Number(parsed.refreshHours)
    if (isFinite(refreshHours) && refreshHours > 0) doc.refreshHours = refreshHours
  } catch (e) {
    // keep default doc
  }
  return doc
}

function configText(config) {
  return JSON.stringify(
    { categories: config.categories, refreshHours: Number(config.refreshHours) || 24 },
    null,
    2) + "\n"
}

// Service fetch progress written to refresh-status.json and watched live by
// the panel: { active, pending: [repo, ...], updatedAt }.
function parseRefreshStatus(raw) {
  try {
    var doc = JSON.parse(String(raw || ""))
    if (doc && typeof doc.active === "boolean" && Array.isArray(doc.pending)) {
      return {
        active: doc.active,
        pending: doc.pending.filter(function(repo) { return typeof repo === "string" })
      }
    }
  } catch (e) {
    // fall through to the idle default
  }
  return { active: false, pending: [] }
}

function allEntries(config) {
  var out = []
  var mine = config.categories.mine || []
  var others = config.categories.others || []
  for (var i = 0; i < mine.length; i++) out.push({ repo: mine[i], category: "mine" })
  for (var j = 0; j < others.length; j++) out.push({ repo: others[j], category: "others" })
  return out
}

function categoryOf(config, repo) {
  var mine = config.categories.mine || []
  var others = config.categories.others || []
  for (var i = 0; i < mine.length; i++) if (mine[i] === repo) return "mine"
  for (var j = 0; j < others.length; j++) if (others[j] === repo) return "others"
  return null
}

// Validate an "owner/repo" input. Returns { valid, repo, name, error }.
function sanitizeRepo(input) {
  var raw = String(input || "").trim()
  var parts = raw.split("/")
  if (parts.length < 2) return { valid: false, error: "Expected owner/repo" }
  var owner = parts[0].trim()
  var name = parts.slice(1).join("/").trim()
  if (!owner || !name) return { valid: false, error: "Expected owner/repo" }
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/.test(owner)) return { valid: false, error: "Invalid owner name" }
  if (!/^[A-Za-z0-9_.-]+$/.test(name)) return { valid: false, error: "Invalid repo name" }
  return { valid: true, repo: owner + "/" + name, name: name.split("/").pop() }
}

// Extract owner/repo from a pasted GitHub URL. Accepts https/http links,
// scheme-less "github.com/owner/repo", SSH form "git@github.com:owner/repo",
// and strips trailing ".git" or deeper paths. Returns { owner, repo } or null.
function parseGithubUrl(input) {
  var m = String(input || "").match(/github\.com[\/:]([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)/i)
  if (!m) return null
  return { owner: m[1], repo: m[2].replace(/\.git$/i, "") }
}

// ---- github ----------------------------------------------------------------

function githubUrl(repo, page) {
  // repo is "owner/name". The slash is a real path separator here, so the
  // segments are encoded individually (encodeURIComponent would turn the
  // slash into %2F and GitHub answers 404 for the encoded path).
  var parts = String(repo || "").split("/")
  var owner = encodeURIComponent(parts[0] || "")
  var name = encodeURIComponent((parts[1] || "NO_REPO"))
  return "https://api.github.com/repos/" + owner + "/" + name +
    "/releases?per_page=100&page=" + (page || 1)
}

// Repo metadata (stars, creation date) for the stars/releases metrics.
function repoInfoUrl(repo) {
  var parts = String(repo || "").split("/")
  var owner = encodeURIComponent(parts[0] || "")
  var name = encodeURIComponent((parts[1] || "NO_REPO"))
  return "https://api.github.com/repos/" + owner + "/" + name
}

function parseRepoInfo(raw) {
  try {
    var p = JSON.parse(String(raw || ""))
    if (!p || typeof p !== "object") return null
    return {
      stars: Number(p.stargazers_count) || 0,
      created: p.created_at ? String(p.created_at).replace("Z", "+00:00") : ""
    }
  } catch (e) {
    return null
  }
}

function fetchCommand(url) {
  var cmd = ["curl", "-fsS", "--max-time", "20", "--max-filesize", "8388608",
    "-H", "Accept: application/vnd.github+json",
    "-H", "X-GitHub-Api-Version: 2022-11-28",
    "-H", "User-Agent: ghrepotracker-omarchy-plugin"]
  cmd.push(url)
  return cmd
}

function sumReleases(releases) {
  var total = 0
  var assetCount = 0
  for (var i = 0; i < releases.length; i++) {
    var r = releases[i]
    var assets = r.assets || []
    assetCount += assets.length
    var dl = 0
    for (var j = 0; j < assets.length; j++) dl += Number(assets[j].download_count) || 0
    total += dl
  }
  return {
    total: total,
    releaseCount: releases.length,
    assetCount: assetCount,
    cohorts: releaseCohorts(releases)
  }
}

// ---- cache docs ------------------------------------------------------------

var SCHEMA_VERSION = 3
var HISTORY_LIMITS = { days: 30, weeks: 8, months: 12, years: 0 }

function dayKey(date) {
  function two(n) { return n < 10 ? "0" + n : "" + n }
  return date.getUTCFullYear() + "-" + two(date.getUTCMonth() + 1) + "-" + two(date.getUTCDate())
}

function emptyCache(repo, category) {
  return {
    schemaVersion: SCHEMA_VERSION,
    repo: repo,
    category: category,
    added: nowIso(),
    created: "",
    current: { downloads: 0, stars: 0, releases: 0, assets: 0, observedAt: "" },
    status: { lastAttemptAt: "", lastSuccessAt: "", error: "" },
    history: emptyCollections(),
    cohorts: emptyCollections(),
    starCohorts: emptyCollections(),
    starCohortsUpdatedAt: ""
  }
}

function emptyCollections() {
  return { days: [], weeks: [], months: [], years: [] }
}

function bucketFor(at, collection) {
  var d = new Date(at)
  if (!isFinite(d.getTime())) return ""
  if (collection === "days") return dayKey(d)
  if (collection === "weeks") return weekStartISO(d)
  if (collection === "months") return d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1)
  return String(d.getUTCFullYear())
}

function cleanObservation(sample, collection) {
  var at = sample && (sample.observedAt || sample.at)
  var bucket = sample && sample.bucket || bucketFor(at, collection)
  if (!bucket || !isFinite(Date.parse(at || ""))) return null
  var out = { bucket: bucket, observedAt: new Date(Date.parse(at)).toISOString() }
  var fields = ["downloads", "stars", "releases", "assets"]
  for (var i = 0; i < fields.length; i++) {
    var value = sample[fields[i]]
    if (value !== undefined && value !== null && isFinite(Number(value))) out[fields[i]] = Number(value)
  }
  return out
}

function upsertBucket(collection, sample, name) {
  var byBucket = {}
  var source = collection || []
  for (var i = 0; i < source.length; i++) {
    var old = cleanObservation(source[i], name)
    if (old) byBucket[old.bucket] = old
  }
  var next = cleanObservation(sample, name)
  if (next) {
    var prior = byBucket[next.bucket]
    if (prior) {
      for (var field in prior) if (next[field] === undefined) next[field] = prior[field]
    }
    byBucket[next.bucket] = next
  }
  var keys = []
  for (var key in byBucket) keys.push(key)
  keys.sort()
  var limit = HISTORY_LIMITS[name] || 0
  if (limit && keys.length > limit) keys = keys.slice(keys.length - limit)
  var out = []
  for (var k = 0; k < keys.length; k++) out.push(byBucket[keys[k]])
  return out
}

function cleanCohort(sample, collection) {
  var bucket = sample && sample.bucket
  if (!bucket) return null
  var releases = Number(sample.releases)
  if (!isFinite(releases) || releases <= 0) return null
  return {
    bucket: String(bucket),
    downloads: Math.max(0, Number(sample.downloads) || 0),
    releases: releases,
    assets: Math.max(0, Number(sample.assets) || 0)
  }
}

function normalizeCohorts(cohorts) {
  var out = emptyCollections()
  var names = ["days", "weeks", "months", "years"]
  for (var n = 0; n < names.length; n++) {
    var name = names[n]
    var byBucket = {}
    var source = cohorts && cohorts[name] || []
    for (var i = 0; i < source.length; i++) {
      var item = cleanCohort(source[i], name)
      if (item) byBucket[item.bucket] = item
    }
    var keys = []
    for (var key in byBucket) keys.push(key)
    keys.sort()
    for (var k = 0; k < keys.length; k++) out[name].push(byBucket[keys[k]])
  }
  return out
}

function cleanStarCohort(sample, collection) {
  var stars = Number(sample && sample.stars)
  if (!sample || !sample.bucket || !isFinite(stars) || stars <= 0 || Math.floor(stars) !== stars) return null
  var bucket = String(sample.bucket)
  var suffix = collection === "months" ? "-01" : collection === "years" ? "-01-01" : ""
  var expected = bucketFor(bucket + suffix, collection)
  if (!expected || expected !== bucket) return null
  if (collection === "weeks" && weekStartISO(new Date(bucket)) !== bucket) return null
  return { bucket: bucket, stars: stars }
}

function normalizeStarCohorts(cohorts) {
  var out = emptyCollections()
  var names = ["days", "weeks", "months", "years"]
  for (var n = 0; n < names.length; n++) {
    var byBucket = {}
    var source = cohorts && cohorts[names[n]] || []
    for (var i = 0; i < source.length; i++) {
      var item = cleanStarCohort(source[i], names[n])
      if (item) byBucket[item.bucket] = item
    }
    var keys = []
    for (var key in byBucket) keys.push(key)
    keys.sort()
    for (var k = 0; k < keys.length; k++) out[names[n]].push(byBucket[keys[k]])
  }
  return out
}

function parseStarCohorts(raw) {
  var parsed
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!parsed || typeof parsed !== "object" || !isFinite(Date.parse(parsed.collectedAt || ""))) return null
  var count = Number(parsed.acquisitionCount)
  if (!isFinite(count) || count < 0 || Math.floor(count) !== count || !parsed.starCohorts) return null
  var names = ["days", "weeks", "months", "years"]
  for (var n = 0; n < names.length; n++) {
    if (!Array.isArray(parsed.starCohorts[names[n]])) return null
    var seen = {}
    for (var i = 0; i < parsed.starCohorts[names[n]].length; i++) {
      var item = cleanStarCohort(parsed.starCohorts[names[n]][i], names[n])
      if (!item || seen[item.bucket]) return null
      seen[item.bucket] = true
    }
  }
  var cohorts = normalizeStarCohorts(parsed.starCohorts)
  var annualCount = 0
  for (var y = 0; y < cohorts.years.length; y++) annualCount += cohorts.years[y].stars
  if (annualCount !== count) return null
  return {
    collectedAt: new Date(Date.parse(parsed.collectedAt)).toISOString(),
    acquisitionCount: count,
    starCohorts: cohorts
  }
}

// Current lifetime release-asset downloads grouped by each release's
// publication bucket. These are release cohorts, not download-event history.
function releaseCohorts(releases, at) {
  var out = emptyCollections()
  var names = ["days", "weeks", "months", "years"]
  var maps = { days: {}, weeks: {}, months: {}, years: {} }
  var now = at || Date.now()
  for (var i = 0; i < (releases || []).length; i++) {
    var release = releases[i]
    var published = release.published_at || release.published
    var ms = Date.parse(published || "")
    if (!isFinite(ms) || ms > new Date(now).getTime()) continue
    var assets = release.assets || []
    var downloads = release.downloads !== undefined ? Number(release.downloads) || 0 : 0
    for (var a = 0; a < assets.length; a++) downloads += Number(assets[a].download_count) || 0
    for (var n = 0; n < names.length; n++) {
      var name = names[n]
      var period = name === "days" ? "daily" : name === "weeks" ? "weekly" : name === "months" ? "monthly" : "annual"
      var domain = periodDomain(period, [ms], now)
      var bucket = bucketFor(published, name)
      var bucketAt = Date.parse(bucket + (name === "months" ? "-01" : name === "years" ? "-01-01" : ""))
      if (period !== "annual" && (bucketAt < domain.start || bucketAt > domain.end)) continue
      if (!maps[name][bucket]) maps[name][bucket] = { bucket: bucket, downloads: 0, releases: 0, assets: 0 }
      maps[name][bucket].downloads += downloads
      maps[name][bucket].releases++
      maps[name][bucket].assets += assets.length
    }
  }
  for (var c = 0; c < names.length; c++) {
    var collection = names[c]
    var keys = []
    for (var key in maps[collection]) keys.push(key)
    keys.sort()
    for (var k = 0; k < keys.length; k++) out[collection].push(maps[collection][keys[k]])
  }
  return out
}

function addHistoricalSample(doc, sample) {
  var names = ["days", "weeks", "months", "years"]
  for (var i = 0; i < names.length; i++) {
    var name = names[i]
    var projected = {}
    for (var field in sample) projected[field] = sample[field]
    projected.bucket = bucketFor(sample.observedAt, name)
    doc.history[name] = upsertBucket(doc.history[name], projected, name)
  }
}

// Convert the concrete pre-v2 cache shape without assigning release dates to
// download counts. Missing metrics on old snapshots remain unknown.
function migrateCache(legacy) {
  if (!legacy || typeof legacy !== "object") return null
  if ((legacy.schemaVersion === 2 || legacy.schemaVersion === SCHEMA_VERSION) && legacy.current && legacy.history) {
    var normalized = emptyCache(legacy.repo || "", legacy.category || "others")
    normalized.added = legacy.added || normalized.added
    normalized.created = legacy.created || ""
    normalized.current = {
      downloads: Number(legacy.current.downloads) || 0,
      stars: Number(legacy.current.stars) || 0,
      releases: Number(legacy.current.releases) || 0,
      assets: Number(legacy.current.assets) || 0,
      observedAt: legacy.current.observedAt || ""
    }
    normalized.status = {
      lastAttemptAt: legacy.status && legacy.status.lastAttemptAt || "",
      lastSuccessAt: legacy.status && legacy.status.lastSuccessAt || "",
      error: legacy.status && legacy.status.error || ""
    }
    var names = ["days", "weeks", "months", "years"]
    for (var n = 0; n < names.length; n++) normalized.history[names[n]] = upsertBucket(legacy.history[names[n]], null, names[n])
    normalized.cohorts = normalizeCohorts(legacy.cohorts)
    normalized.starCohorts = normalizeStarCohorts(legacy.starCohorts)
    normalized.starCohortsUpdatedAt = isFinite(Date.parse(legacy.starCohortsUpdatedAt || ""))
      ? new Date(Date.parse(legacy.starCohortsUpdatedAt)).toISOString() : ""
    return normalized
  }

  var doc = emptyCache(legacy.repo || "", legacy.category || "others")
  doc.added = legacy.added || doc.added
  doc.created = legacy.created || ""
  var downloads = normalizeObservations(legacy.snapshots || [], legacy.lastUpdated)
  for (var i = 0; i < downloads.length; i++) addHistoricalSample(doc, {
    observedAt: downloads[i].at,
    downloads: Number(downloads[i].total) || 0
  })
  var stars = normalizeObservations(legacy.starSnapshots || [], legacy.lastUpdated)
  for (var j = 0; j < stars.length; j++) addHistoricalSample(doc, {
    observedAt: stars[j].at,
    stars: Number(stars[j].total) || 0
  })
  var at = legacy.lastUpdated || ""
  doc.current = {
    downloads: Number(legacy.total) || 0,
    stars: Number(legacy.stars) || 0,
    releases: Number(legacy.releases) || 0,
    assets: Number(legacy.assets) || 0,
    observedAt: at
  }
  doc.status = { lastAttemptAt: at, lastSuccessAt: at, error: legacy.error || "" }
  if (legacy.releaseMeta) doc.cohorts = releaseCohorts(legacy.releaseMeta)
  if (isFinite(Date.parse(at))) addHistoricalSample(doc, {
    observedAt: at,
    downloads: doc.current.downloads,
    stars: doc.current.stars,
    releases: doc.current.releases,
    assets: doc.current.assets
  })
  return doc
}

function recordObservation(doc, values, at, error) {
  doc = migrateCache(doc) || emptyCache("", "others")
  var observedAt = at || nowIso()
  doc.current = {
    downloads: Number(values.downloads) || 0,
    stars: Number(values.stars) || 0,
    releases: Number(values.releases) || 0,
    assets: Number(values.assets) || 0,
    observedAt: observedAt
  }
  doc.status = { lastAttemptAt: observedAt, lastSuccessAt: observedAt, error: error || "" }
  addHistoricalSample(doc, {
    observedAt: observedAt,
    downloads: doc.current.downloads,
    stars: doc.current.stars,
    releases: doc.current.releases,
    assets: doc.current.assets
  })
  return doc
}

function recordFailure(doc, error, at) {
  doc = migrateCache(doc) || emptyCache("", "others")
  doc.status.lastAttemptAt = at || nowIso()
  doc.status.error = error || "request failed"
  return doc
}

// Convert legacy weekly samples and current timestamped samples into sorted,
// one-per-UTC-day observations. The most recent legacy sample uses lastUpdated
// because its old Monday key described a bucket, not its actual fetch time.
function normalizeObservations(samples, fallbackAt) {
  var source = samples || []
  var byDay = {}
  var order = []
  for (var i = 0; i < source.length; i++) {
    var rawAt = source[i].at || ((i === source.length - 1 && fallbackAt) ? fallbackAt : source[i].week)
    var ms = Date.parse(rawAt || "")
    if (!isFinite(ms)) continue
    var at = new Date(ms).toISOString()
    var key = dayKey(new Date(ms))
    if (!(key in byDay)) order.push(key)
    byDay[key] = { at: at, total: Number(source[i].total) || 0 }
  }
  order.sort()
  var out = []
  for (var j = 0; j < order.length; j++) out.push(byDay[order[j]])
  return out
}

function appendObservation(samples, total, at, fallbackAt) {
  var observations = normalizeObservations(samples, fallbackAt)
  var sample = { at: at, total: Number(total) || 0 }
  var key = dayKey(new Date(at))
  var last = observations[observations.length - 1]
  if (last && dayKey(new Date(last.at)) === key) observations[observations.length - 1] = sample
  else observations.push(sample)
  if (observations.length > 730) observations = observations.slice(observations.length - 730)
  return observations
}

// Append (or update today's) observed cumulative download total.
function appendSnapshot(doc, total) {
  var at = nowIso()
  doc.snapshots = appendObservation(doc.snapshots, total, at, doc.lastUpdated)
  doc.total = Number(total) || 0
  doc.lastUpdated = at
  doc.error = ""
  return doc
}

// One observed stargazer count per UTC day, taken after the download sample.
function appendStarSnapshot(doc, stars) {
  var at = nowIso()
  doc.starSnapshots = appendObservation(doc.starSnapshots, stars, at, doc.lastUpdated)
  doc.stars = Number(stars) || 0
  return doc
}

function parseCache(raw) {
  try { return migrateCache(JSON.parse(raw || "{}")) } catch (e) { return null }
}

function parseStore(raw) {
  try { return JSON.parse(raw || "{}") } catch (e) { return null }
}

function isStale(doc, staleHours) {
  doc = migrateCache(doc)
  if (!doc || !doc.current || !doc.current.observedAt) return true
  var age = Date.now() - new Date(doc.current.observedAt).getTime()
  return age > (staleHours || 7 * 24) * 3600 * 1000
}

function starCohortsStale(doc, staleDays, at) {
  doc = migrateCache(doc)
  if (!doc || !doc.starCohortsUpdatedAt) return true
  var now = at ? new Date(at).getTime() : Date.now()
  var updated = new Date(doc.starCohortsUpdatedAt).getTime()
  if (!isFinite(now) || !isFinite(updated)) return true
  return now - updated > (staleDays || 7) * 86400000
}

function nowIso() {
  return new Date().toISOString()
}

// ---- time series -----------------------------------------------------------

// ISO date (YYYY-MM-DD, UTC) for the Monday of the week containing `date`.
function weekStartISO(date) {
  function two(n) { return n < 10 ? "0" + n : "" + n }
  var d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()))
  var day = (d.getUTCDay() + 6) % 7 // Monday = 0
  d.setUTCDate(d.getUTCDate() - day)
  return d.getUTCFullYear() + "-" + two(d.getUTCMonth() + 1) + "-" + two(d.getUTCDate())
}

// Build a weekly cumulative series from release metadata (publish + per-release
// asset downloads). Returns { weeks, totals (cumulative), values (velocity) }.
// The final sample floats at the *current* week so carried-forward totals don't
// stop at the last release and so chart tails run to "now". With `count`
// truthy each release weighs 1 (a version-count series instead of downloads).
function hydrateSeries(meta, count) {
  var items = []
  for (var i = 0; i < (meta || []).length; i++) {
    var t = Date.parse(meta[i].published)
    var d = count ? 1 : (Number(meta[i].downloads) || 0)
    if (!isFinite(t) || d <= 0) continue
    items.push({ t: t, d: d })
  }
  items.sort(function(a, b) { return a.t - b.t })
  var deltas = {}
  var order = []
  for (var k = 0; k < items.length; k++) {
    var w = weekStartISO(new Date(items[k].t))
    if (!(w in deltas)) { deltas[w] = 0; order.push(w) }
    deltas[w] += items[k].d
  }
  order.sort()
  var totals = []
  var values = []
  var run = 0
  for (var j = 0; j < order.length; j++) {
    run += deltas[order[j]]
    totals.push(run)
    values.push(deltas[order[j]])
  }
  if (order.length) {
    var now = weekStartISO(new Date())
    if (order[order.length - 1] < now) {
      order.push(now)
      totals.push(run)
      values.push(0)
    }
  }
  return { weeks: order, totals: totals, values: values }
}

// Discard the old release-date reconstruction. Those fields assigned current
// lifetime asset counts to publication dates and are not historical samples.
function hydrate(doc) {
  if (!doc) return doc
  delete doc.weeks
  delete doc.totals
  delete doc.values
  return doc
}

function startOfDay(ms) {
  var d = new Date(ms)
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())
}

function addDays(ms, n) {
  return ms + n * 86400000
}

function monthStartAbs(abs) {
  return Date.UTC(Math.floor(abs / 12), abs % 12, 1)
}

function monthAbsOf(ms) {
  var d = new Date(ms)
  return d.getUTCFullYear() * 12 + d.getUTCMonth()
}

// Convert stored API observations to a UTC-day-aligned cumulative series.
// `values` are average changes per elapsed day between real observations.
function observedSeries(samples, fallbackAt, currentTotal) {
  var observations = normalizeObservations(samples, fallbackAt)
  var fallbackMs = Date.parse(fallbackAt || "")
  if (isFinite(fallbackMs) && currentTotal !== undefined && currentTotal !== null) {
    var current = { at: new Date(fallbackMs).toISOString(), total: Number(currentTotal) || 0 }
    var currentDay = dayKey(new Date(fallbackMs))
    var final = observations[observations.length - 1]
    if (final && dayKey(new Date(final.at)) === currentDay) observations[observations.length - 1] = current
    else observations.push(current)
  }
  var steps = []
  var totals = []
  var weeks = []
  var values = []
  for (var i = 0; i < observations.length; i++) {
    var ms = Date.parse(observations[i].at)
    var day = startOfDay(ms)
    steps.push(day)
    weeks.push(dayKey(new Date(day)))
    totals.push(Number(observations[i].total) || 0)
    if (i > 0) {
      var elapsed = Math.max(1, (day - steps[i - 1]) / 86400000)
      values.push((totals[i] - totals[i - 1]) / elapsed)
    }
  }
  return { steps: steps, weeks: weeks, totals: totals, values: values }
}

// Build release-count chronology from publication timestamps. Unlike asset
// downloads and stars, release dates are real historical events from GitHub.
function buildDaily(meta, currentTotal, count) {
  var items = []
  for (var i = 0; i < (meta || []).length; i++) {
    var t = Date.parse(meta[i].published)
    var d = count ? 1 : (Number(meta[i].downloads) || 0)
    if (!isFinite(t) || d <= 0) continue
    items.push({ t: t, d: d })
  }
  items.sort(function(a, b) { return a.t - b.t })

  var pts = []
  var run = 0
  for (var k = 0; k < items.length; k++) {
    run += items[k].d
    pts.push({ t: items[k].t, cum: run })
  }
  var anchor = Math.max(run, Number(currentTotal) || 0)
  if (!pts.length) {
    if (anchor > 0) {
      var dayOnly = startOfDay(Date.now())
      return { steps: [dayOnly], totals: [anchor] }
    }
    return { steps: [], totals: [] }
  }
  pts.push({ t: Date.now(), cum: anchor })

  var s = startOfDay(pts[0].t)
  var e = startOfDay(Date.now())
  var steps = []
  for (var ms = s; ms <= e; ms = addDays(ms, 1)) steps.push(ms)

  var anchorIdx = pts.length - 1
  var lastRel = pts[anchorIdx - 1]
  var frac = 0
  var span = pts[anchorIdx].t - lastRel.t
  if (span <= 0) span = 1
  else frac = (anchor - lastRel.cum) / span

  var totals = []
  var pi = 0
  for (var j = 0; j < steps.length; j++) {
    var dayEnd = addDays(steps[j], 1)
    var v
    if (dayEnd < pts[0].t) {
      v = 0
    } else if (dayEnd >= lastRel.t) {
      var tEnd = Math.min(dayEnd, pts[anchorIdx].t)
      v = lastRel.cum + (tEnd - lastRel.t) * frac
    } else {
      while (pi + 1 < anchorIdx && pts[pi + 1].t < dayEnd) pi++
      v = pts[pi].cum
    }
    totals.push(Math.round(v))
  }
  return { steps: steps, totals: totals }
}

// Combine observed series only from the latest first-observation date. Before
// that common date, at least one repository is unknown and must not count as 0.
function combineDaily(list) {
  var map = {}
  var order = []
  var commonStart = -Infinity
  var i, k
  for (i = 0; i < list.length; i++) {
    var st = list[i].steps || []
    if (!st.length) continue
    if (list[i].completeHistory !== true) commonStart = Math.max(commonStart, st[0])
    for (k = 0; k < st.length; k++) {
      if (!(st[k] in map)) { map[st[k]] = 0; order.push(st[k]) }
    }
  }
  order.sort(function(a, b) { return a - b })
  order = order.filter(function(t) { return t >= commonStart })
  for (i = 0; i < list.length; i++) {
    var st2 = list[i].steps || []
    var tl = list[i].totals || []
    var run = 0
    var wi = 0
    for (var o = 0; o < order.length; o++) {
      while (wi < st2.length && st2[wi] <= order[o]) { run = tl[wi] || 0; wi++ }
      map[order[o]] += run
    }
  }
  var outT = []
  for (var j = 0; j < order.length; j++) outT.push(map[order[j]])
  return { steps: order, totals: outT }
}

// Default windows for the timeline periods (in whole buckets), today-anchored.
var PERIOD_WINDOWS = { daily: 30, weekly: 8, monthly: 12, annual: 0 }

// Daily view is capped to 30 real observation days. Older observations remain
// available in weekly/monthly/annual buckets.
var DAILY_MAX = 30

// Select real observations in the requested window. Weekly/monthly/annual
// views keep the last observation in each calendar bucket at its actual date;
// no zero baselines, carry-forward endpoints, or interpolated points are made.
function timelinePoints(daily, period, shift) {
  var steps = daily && daily.steps || []
  var totals = daily && daily.totals || []
  if (!steps.length) return []
  var today = startOfDay(Date.now())
  var count = period === "daily"
    ? Math.min(PERIOD_WINDOWS.daily + (shift || 0), DAILY_MAX)
    : (PERIOD_WINDOWS[period] || 0) + (shift || 0)
  var cutoff = -Infinity
  if (period === "daily") cutoff = addDays(today, -(count - 1))
  else if (period === "weekly") cutoff = addDays(today, -(count * 7 - 1))
  else if (period === "monthly") cutoff = monthStartAbs(monthAbsOf(today) - count + 1)

  var points = []
  for (var i = 0; i < steps.length; i++) {
    var t = Number(steps[i])
    if (!isFinite(t) || t < cutoff || t > addDays(today, 1)) continue
    points.push({ t: t, v: Number(totals[i]) || 0 })
  }
  points.sort(function(a, b) { return a.t - b.t })
  if (period === "daily") return points

  var buckets = {}
  var keys = []
  for (var p = 0; p < points.length; p++) {
    var d = new Date(points[p].t)
    var key
    if (period === "weekly") key = weekStartISO(d)
    else if (period === "monthly") key = d.getUTCFullYear() + "-" + (d.getUTCMonth() + 1)
    else key = String(d.getUTCFullYear())
    if (!(key in buckets)) keys.push(key)
    buckets[key] = points[p]
  }
  keys.sort()
  var out = []
  for (var k = 0; k < keys.length; k++) out.push(buckets[keys[k]])
  return out
}

function collectionForPeriod(period) {
  if (period === "daily") return "days"
  if (period === "monthly") return "months"
  if (period === "annual") return "years"
  return "weeks"
}

// Fixed UTC bucket domain for presentation. Unknown buckets remain visual
// slots only; they are never persisted or converted to zero-valued samples.
function periodDomain(period, observedSteps, at) {
  var now = new Date(at || Date.now())
  var today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
  if (period === "daily") {
    return { start: today - 29 * 86400000, end: today, slots: 30 }
  }
  if (period === "weekly") {
    var monday = Date.parse(weekStartISO(new Date(today)))
    return { start: monday - 7 * 7 * 86400000, end: today, slots: 8 }
  }
  if (period === "monthly") {
    return { start: Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 11, 1), end: today, slots: 12 }
  }
  var endYear = now.getUTCFullYear()
  var startYear = endYear
  var steps = observedSteps || []
  if (steps.length) {
    var first = new Date(steps[0])
    if (isFinite(first.getTime())) startYear = Math.min(startYear, first.getUTCFullYear())
  }
  return {
    start: Date.UTC(startYear, 0, 1),
    end: today,
    slots: endYear - startYear + 1
  }
}

function metricField(metric) {
  if (metric === "stars") return "stars"
  if (metric === "releases") return "releases"
  if (metric === "assets") return "assets"
  return "downloads"
}

// Combine one matching persisted bucket collection. A repository contributes
// only from its first known sample; unknown earlier values are never
// zero-filled. The bucket set is the union across repos, so totals for a year
// where a newer repo has no sample still show the repos that do have one.
function historyTimeline(entries, metric, period) {
  var collection = collectionForPeriod(period)
  var field = metricField(metric)
  var series = []
  var allKeys = {}
  for (var i = 0; i < (entries || []).length; i++) {
    var samples = entries[i].history && entries[i].history[collection] || []
    var points = []
    for (var j = 0; j < samples.length; j++) {
      if (samples[j][field] === undefined || !isFinite(Number(samples[j][field]))) continue
      points.push({ bucket: samples[j].bucket, at: samples[j].observedAt, value: Number(samples[j][field]) })
      allKeys[samples[j].bucket] = true
    }
    if (points.length) series.push(points)
  }
  var keys = []
  for (var key in allKeys) keys.push(key)
  keys.sort()
  var totals = []
  var steps = []
  for (var k = 0; k < keys.length; k++) {
    var total = 0
    var latestAt = ""
    for (var s = 0; s < series.length; s++) {
      var running = null
      for (var p = 0; p < series[s].length && series[s][p].bucket <= keys[k]; p++) {
        running = series[s][p].value
        if (series[s][p].bucket === keys[k] && series[s][p].at > latestAt) latestAt = series[s][p].at
      }
      if (running !== null) total += running
    }
    var ts = Date.parse(latestAt || keys[k])
    if (!isFinite(ts)) ts = Date.parse(keys[k] + (collection === "months" ? "-01" : collection === "years" ? "-01-01" : ""))
    if (isFinite(ts)) { steps.push(ts); totals.push(total) }
  }
  return { steps: steps, totals: totals, buckets: keys, boundedBuckets: true }
}

function bucketedCohortTimeline(entries, property, field, period, at, sourceName) {
  var collection = collectionForPeriod(period)
  var oldest = []
  var totalsByBucket = {}
  for (var i = 0; i < (entries || []).length; i++) {
    var groups = entries[i][property]
    var samples = groups && groups[collection] || []
    for (var j = 0; j < samples.length; j++) {
      var value = Number(samples[j][field])
      if (!samples[j].bucket || !isFinite(value)) continue
      totalsByBucket[samples[j].bucket] = (totalsByBucket[samples[j].bucket] || 0) + value
      var sampleAt = Date.parse(samples[j].bucket + (collection === "months" ? "-01" : collection === "years" ? "-01-01" : ""))
      if (isFinite(sampleAt)) oldest.push(sampleAt)
    }
  }
  oldest.sort(function(a, b) { return a - b })
  var domain = periodDomain(period, oldest, at)
  var steps = []
  var buckets = []
  var totals = []
  for (var slot = 0; slot < domain.slots; slot++) {
    var step
    if (period === "daily") step = domain.start + slot * 86400000
    else if (period === "weekly") step = domain.start + slot * 7 * 86400000
    else {
      var start = new Date(domain.start)
      step = period === "monthly"
        ? Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + slot, 1)
        : Date.UTC(start.getUTCFullYear() + slot, 0, 1)
    }
    var bucket = bucketFor(new Date(step).toISOString(), collection)
    steps.push(slot === domain.slots - 1 ? domain.end : step)
    buckets.push(bucket)
    totals.push(totalsByBucket[bucket] || 0)
  }
  return { steps: steps, totals: totals, buckets: buckets, boundedBuckets: true, source: sourceName }
}

function cohortTimeline(entries, metric, period, at) {
  return bucketedCohortTimeline(entries, "cohorts", metricField(metric), period, at, "cohort")
}

function starCohortTimeline(entries, period, at) {
  return bucketedCohortTimeline(entries, "starCohorts", "stars", period, at, "star-cohort")
}

function haveStarCohorts(entries) {
  if (!entries || !entries.length) return false
  for (var i = 0; i < entries.length; i++) {
    if (!entries[i].starCohortsUpdatedAt) return false
  }
  return true
}

function timelineInDomain(timeline, period, at) {
  if (period === "annual") return timeline
  var domain = periodDomain(period, timeline.steps, at)
  var out = { steps: [], totals: [], buckets: [], boundedBuckets: true, source: "observed" }
  for (var i = 0; i < timeline.steps.length; i++) {
    var collection = collectionForPeriod(period)
    var bucketAt = Date.parse(timeline.buckets[i] + (collection === "months" ? "-01" : collection === "years" ? "-01-01" : ""))
    if (!isFinite(bucketAt) || bucketAt < domain.start || bucketAt > domain.end) continue
    out.steps.push(timeline.steps[i])
    out.totals.push(timeline.totals[i])
    out.buckets.push(timeline.buckets[i])
  }
  return out
}

function selectedTimeline(entries, metric, period, at) {
  var observed = timelineInDomain(historyTimeline(entries, metric, period), period, at)
  observed.source = "observed"
  if (observed.steps.length >= 2) return observed
  if (metric === "stars" && haveStarCohorts(entries)) return starCohortTimeline(entries, period, at)
  if (metric === "stars") return observed
  return cohortTimeline(entries, metric, period, at)
}

function bucketStartEpoch(bucket) {
  if (!bucket) return NaN
  if (/^\d{4}$/.test(bucket)) return Date.UTC(Number(bucket), 0, 1)
  if (/^\d{4}-\d{2}$/.test(bucket)) return Date.UTC(Number(bucket.slice(0, 4)), Number(bucket.slice(5, 7)) - 1, 1)
  return Date.parse(bucket)
}

// Cohorts are per-period volumes; observed GitHub counters are cumulative.
// Transform either source without changing the persisted records.
function displayTimeline(timeline, cumulative) {
  var source = timeline || { steps: [], totals: [], buckets: [], source: "observed" }
  var out = {
    steps: (source.steps || []).slice(),
    totals: [],
    buckets: (source.buckets || []).slice(),
    boundedBuckets: source.boundedBuckets === true,
    source: source.source || "observed",
    cumulative: cumulative === true
  }
  var values = source.totals || []
  if (out.source === "cohort" || out.source === "star-cohort") {
    if (values.length) {
      if (out.cumulative) {
        // A bucket's cumulative total is the value as of the END of that
        // bucket (start of the next one, or "now" for the last). Anchor each
        // point there, and open with the carry-forward total at the period
        // start so the running line starts at the previous period's level.
        var nSteps = [bucketStartEpoch(out.buckets[0])]
        var nTotals = [0]
        var running = 0
        for (var i = 0; i < values.length; i++) {
          running += Number(values[i]) || 0
          var at = i < values.length - 1 ? bucketStartEpoch(out.buckets[i + 1]) : out.steps[out.steps.length - 1]
          nSteps.push(at)
          nTotals.push(running)
        }
        out.steps = nSteps
        out.totals = nTotals
      } else {
        var plain = 0
        for (var k = 0; k < values.length; k++) {
          plain += Number(values[k]) || 0
          out.totals.push(Number(values[k]) || 0)
        }
      }
    }
    return out
  }
  for (var j = 0; j < values.length; j++) {
    if (out.cumulative) out.totals.push(Number(values[j]) || 0)
    else out.totals.push(j === 0 ? 0 : (Number(values[j]) || 0) - (Number(values[j - 1]) || 0))
  }
  return out
}

function aggregateHistory(entries) {
  var history = { days: [], weeks: [], months: [], years: [] }
  var periods = { days: "daily", weeks: "weekly", months: "monthly", years: "annual" }
  var fields = ["downloads", "stars", "releases", "assets"]
  for (var name in periods) {
    var byBucket = {}
    for (var f = 0; f < fields.length; f++) {
      var metric = fields[f] === "downloads" ? "dl" : fields[f]
      var timeline = historyTimeline(entries, metric, periods[name])
      for (var i = 0; i < timeline.steps.length; i++) {
        var bucket = timeline.buckets[i]
        if (!byBucket[bucket]) byBucket[bucket] = { bucket: bucket, observedAt: new Date(timeline.steps[i]).toISOString() }
        byBucket[bucket][fields[f]] = timeline.totals[i]
      }
    }
    var keys = []
    for (var key in byBucket) keys.push(key)
    keys.sort()
    for (var k = 0; k < keys.length; k++) history[name].push(byBucket[keys[k]])
  }
  return history
}

// Direction of a cumulative series. Visuals that plot totals must use the
// whole displayed growth, not velocity momentum or only the final interval.
function trendFromTotals(t) {
  if (!t || t.length < 2) return "flat"
  var first = Number(t[0]) || 0
  var last = Number(t[t.length - 1]) || 0
  if (last > first) return "up"
  if (last < first) return "down"
  return "flat"
}

// Combine cumulative series over their common observed range. Values before a
// repository's first observation are unknown, not zero.
function combine(list) {
  var keys = {}
  var commonStart = ""
  var i, k
  for (i = 0; i < list.length; i++) {
    var weeks = list[i].weeks || []
    if (!weeks.length) continue
    if (list[i].completeHistory !== true && (!commonStart || weeks[0] > commonStart)) commonStart = weeks[0]
    for (k = 0; k < weeks.length; k++) keys[weeks[k]] = 0
  }
  var order = []
  for (var wk in keys) if (!commonStart || wk >= commonStart) order.push(wk)
  order.sort()
  for (i = 0; i < list.length; i++) {
    var wks = list[i].weeks || []
    var tls = list[i].totals || []
    var run = 0
    var wi = 0
    for (var o = 0; o < order.length; o++) {
      while (wi < wks.length && wks[wi] <= order[o]) { run = tls[wi] || 0; wi++ }
      keys[order[o]] += run
    }
  }
  var outT = []
  var outV = []
  for (var j = 0; j < order.length; j++) {
    outT.push(keys[order[j]])
    if (j > 0) outV.push(keys[order[j]] - keys[order[j - 1]])
  }
  return { weeks: order, totals: outT, values: outV }
}

function entryFor(doc, config, repo) {
  doc = migrateCache(doc)
  var current = doc.current
  var base = { history: doc.history, cohorts: doc.cohorts, starCohorts: doc.starCohorts,
    starCohortsUpdatedAt: doc.starCohortsUpdatedAt }
  var observed = historyTimeline([base], "dl", "weekly")
  var rel = historyTimeline([base], "releases", "weekly")
  var stars = historyTimeline([base], "stars", "weekly")
  var daily = historyTimeline([base], "dl", "daily")
  var relDaily = historyTimeline([base], "releases", "daily")
  var starDaily = historyTimeline([base], "stars", "daily")
  return {
    repo: repo || doc.repo,
    name: repoName(repo || doc.repo),
    category: categoryOf(config, repo || doc.repo) || doc.category || "others",
    total: current.downloads,
    trend: trendFromTotals(observed.totals),
    values: deltasOf(observed.totals),
    totals: observed.totals,
    weeks: observed.buckets,
    steps: daily.steps,
    dayTotals: daily.totals,
    history: doc.history,
    cohorts: doc.cohorts,
    starCohorts: doc.starCohorts,
    starCohortsUpdatedAt: doc.starCohortsUpdatedAt,
    // Other metrics: stars history and version-release count (releases weigh 1).
    stars: current.stars,
    created: doc.created || "",
    releaseCount: current.releases,
    releaseTrend: trendFromTotals(rel.totals),
    releaseValues: deltasOf(rel.totals),
    releaseTotals: rel.totals,
    releaseWeeks: rel.buckets,
    releaseSteps: relDaily.steps,
    releaseDayTotals: relDaily.totals,
    starTrend: trendFromTotals(stars.totals),
    starValues: deltasOf(stars.totals),
    starTotals: stars.totals,
    starWeeks: stars.buckets,
    starSteps: starDaily.steps,
    starDayTotals: starDaily.totals,
    lastUpdated: current.observedAt || "",
    hasData: current.observedAt !== "" || observed.totals.length > 0,
    error: doc.status.error || ""
  }
}

function keysOf(samples) {
  var out = []
  for (var i = 0; i < (samples || []).length; i++) out.push(samples[i].bucket)
  return out
}

function deltasOf(totals) {
  var out = []
  for (var i = 1; i < (totals || []).length; i++) out.push(totals[i] - totals[i - 1])
  return out
}

function repoName(repo) {
  var parts = String(repo || "").split("/")
  return parts.length >= 2 ? parts[parts.length - 1] : String(repo || "")
}

// ---- aggregate store -------------------------------------------------------

function buildStore(config, cacheDocs) {
  var entries = []
  var catTotal = { mine: 0, others: 0 }
  var grandTotal = 0
  var updated = ""

  var list = allEntries(config)
  for (var i = 0; i < list.length; i++) {
    var doc = cacheDocs[list[i].repo]
    if (!doc) continue
    var entry = entryFor(doc, config, list[i].repo)
    entries.push(entry)
    catTotal[entry.category] = (catTotal[entry.category] || 0) + entry.total
    grandTotal += entry.total
    if (!updated || entry.lastUpdated > updated) updated = entry.lastUpdated
  }

  // Combined weekly totals across all tracked repos (week-key aligned).
  var combined = combine(entries.map(function(en) {
    return { weeks: en.weeks, totals: en.totals }
  }))
  var allTotals = combined.totals
  var allValues = combined.values
  var allWeeks = combined.weeks
  var aggregateTrend = trendFromTotals(allTotals)

  return {
    schemaVersion: SCHEMA_VERSION,
    updated: updated,
    categories: {
      mine: entries.filter(function(en) { return en.category === "mine" }),
      others: entries.filter(function(en) { return en.category === "others" })
    },
    totals: { mine: catTotal.mine || 0, others: catTotal.others || 0, all: grandTotal },
    allValues: allValues,
    allTrend: aggregateTrend,
    allTotals: allTotals,
    allWeeks: allWeeks,
    history: aggregateHistory(entries),
    cohorts: aggregateCohorts(entries),
    starCohorts: aggregateStarCohorts(entries),
    count: entries.length
  }
}

function aggregateCohorts(entries) {
  var out = emptyCollections()
  var names = ["days", "weeks", "months", "years"]
  for (var n = 0; n < names.length; n++) {
    var byBucket = {}
    for (var i = 0; i < (entries || []).length; i++) {
      var samples = entries[i].cohorts && entries[i].cohorts[names[n]] || []
      for (var j = 0; j < samples.length; j++) {
        var item = samples[j]
        if (!byBucket[item.bucket]) byBucket[item.bucket] = { bucket: item.bucket, downloads: 0, releases: 0, assets: 0 }
        byBucket[item.bucket].downloads += Number(item.downloads) || 0
        byBucket[item.bucket].releases += Number(item.releases) || 0
        byBucket[item.bucket].assets += Number(item.assets) || 0
      }
    }
    var keys = []
    for (var key in byBucket) keys.push(key)
    keys.sort()
    for (var k = 0; k < keys.length; k++) out[names[n]].push(byBucket[keys[k]])
  }
  return out
}

function aggregateStarCohorts(entries) {
  var out = emptyCollections()
  var names = ["days", "weeks", "months", "years"]
  for (var n = 0; n < names.length; n++) {
    var byBucket = {}
    for (var i = 0; i < (entries || []).length; i++) {
      var samples = entries[i].starCohorts && entries[i].starCohorts[names[n]] || []
      for (var j = 0; j < samples.length; j++) {
        byBucket[samples[j].bucket] = (byBucket[samples[j].bucket] || 0) + (Number(samples[j].stars) || 0)
      }
    }
    var keys = []
    for (var key in byBucket) keys.push(key)
    keys.sort()
    for (var k = 0; k < keys.length; k++) out[names[n]].push({ bucket: keys[k], stars: byBucket[keys[k]] })
  }
  return out
}

function findEntry(store, repo) {
  var list = (store.categories && store.categories.mine || []).concat(store.categories && store.categories.others || [])
  for (var i = 0; i < list.length; i++) if (list[i].repo === repo) return list[i]
  return null
}

function aggregateFor(store, pinned) {
  if (!store) return { total: 0, values: [], totals: [], trend: "flat", label: "—", count: 0 }
  if (pinned) {
    var en = findEntry(store, pinned)
    if (en) return { total: en.total, values: en.values, totals: en.totals || [], trend: trendFromTotals(en.totals), label: en.name, count: 1 }
  }
  return {
    total: (store.totals && store.totals.all) || 0,
    values: store.allValues || [],
    totals: store.allTotals || [],
    trend: trendFromTotals(store.allTotals),
    label: "all tracked",
    count: store.count || 0
  }
}

// ---- formatting ------------------------------------------------------------

function trimDecimals(x) {
  return String(Number(x).toFixed(2)).replace(/\.?0+$/, "")
}

// 0-999 as-is, then #.##k and #.##M (trailing zeros trimmed).
function formatNumber(n) {
  var v = Number(n) || 0
  if (v < 1000) return String(Math.round(v))
  if (v < 1000000) return trimDecimals(v / 1000) + "k"
  return trimDecimals(v / 1000000) + "M"
}

function formatDelta(n) {
  var v = Number(n) || 0
  var sign = v > 0 ? "+" : (v < 0 ? "−" : "")
  return sign + formatNumber(Math.abs(v))
}

function formatRate(n) {
  var v = Number(n) || 0
  var sign = v > 0 ? "+" : (v < 0 ? "−" : "")
  var abs = Math.abs(v)
  return sign + (abs < 100 ? trimDecimals(abs) : formatNumber(abs))
}

// Compact unicode sparkline built from raw values (bar widget text form).
function miniSpark(values, width) {
  if (!values || !values.length) return "○"
  if (values.length === 1) return "●"
  var n = Math.max(2, Math.min(width || 9, values.length))
  var slice = values.slice(values.length - n)
  var min = Infinity, max = -Infinity
  for (var i = 0; i < slice.length; i++) {
    if (slice[i] < min) min = slice[i]
    if (slice[i] > max) max = slice[i]
  }
  var range = max - min
  var chars = "▁▂▃▄▅▆▇█"
  var out = ""
  for (var k = 0; k < slice.length; k++) {
    var level = range > 0 ? (slice[k] - min) / range : 0.5
    out += chars.charAt(Math.max(0, Math.min(7, Math.round(level * 7))))
  }
  return out
}

// ---- period grouping -------------------------------------------------------

// Resample a weekly cumulative series into (at most) one point per period
// bucket, taking the running total at the end of each bucket. Returns a list
// of { t: epochMs, v: cumulativeTotal }.
function periodPoints(weeks, totals, period) {
  if (!weeks || weeks.length < 2) return []
  var buckets = {}
  var order = []
  for (var i = 0; i < weeks.length; i++) {
    var ts = Date.parse(weeks[i])
    if (!isFinite(ts)) continue
    var key = bucketKey(ts, period)
    if (!(key in buckets)) { buckets[key] = { t: ts, v: totals[i] }; order.push(key) }
    else { buckets[key].t = ts; buckets[key].v = totals[i] }
  }
  order.sort()
  var out = []
  for (var k = 0; k < order.length; k++) out.push(buckets[order[k]])
  return out
}

function pad2(n) { return n < 10 ? "0" + n : "" + n }

function bucketKey(ts, period) {
  var d = new Date(ts)
  switch (period) {
    case "daily": return d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1) + "-" + pad2(d.getUTCDate())
    case "monthly": return d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1)
    case "quarterly": return d.getUTCFullYear() + "-Q" + (Math.floor(d.getUTCMonth() / 3) + 1)
    case "annual": return String(d.getUTCFullYear())
    default: return weekStartISO(d)
  }
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Human date label for chart axes, e.g. "Feb 2017". Pass period "daily" to
// also include the day of month.
function formatDateShort(ts, period) {
  var d = new Date(ts)
  if (isNaN(d.getTime())) return ""
  var out = MONTHS[d.getUTCMonth()] + " " + d.getUTCFullYear()
  if (period === "daily") out = pad2(d.getUTCDate()) + " " + out
  return out
}
