# Changelog

## 0.4.0 - 2026-09-25

- "Refresh now" works on a fresh install. Quickshell's `FileView` never arms its
  `watchChanges` watcher when the file's parent directory does not exist yet, so
  on a first run the service's refresh-request watcher and the panel's
  `store.json` / `refresh-status.json` watchers came up permanently dead: the
  button wrote a request nobody read, and the first fetch never appeared. The
  service now creates the state directory up front and seeds
  `refresh-request.json`, and both the service and the panel re-read only the
  views that have not loaded yet until each one lands.
- The plugin's hourly staleness check had never run: `staleTimer` was missing
  `running: true`, so repos were only ever refreshed on startup or by hand.
- A panel with nothing tracked now opens straight into the add-repository form
  instead of two empty category headers, on a fresh install and again after the
  last repo is removed. Removing every repo also closes the panel rather than
  leaving an empty shell on screen.
- A panel with no repos shows a short empty state explaining that a repository
  is needed, with a button to add one.
- The panel opens on the ALL tab with ANNUAL buckets, so a first run lands on
  the broadest view rather than a category that may be empty.
- The bar widget follows the metric last selected in the panel: it shows the
  download, star or release total for that metric, sums it across tracked repos
  when unpinned, and names the metric in its tooltip. Downloads keep using the
  store's precomputed rollup; stars and releases are summed on read, with the
  trend series aligned on calendar years so repos with different histories
  still compare bucket for bucket.

## 0.3.0 - 2026-09-22

- Monthly/weekly/annual charts: cumulative lines for release-cohort and
  star-cohort data now step at the same bucket boundaries as the events
  view, so a period's cumulative increase equals that period's plotted
  events (the old build anchored cohort totals one bucket late, e.g. a
  November download wave showed up as a December jump).
- Cohort-based charts no longer show a zero "current" bucket for a repo that
  is actually gaining downloads: real observed activity inside the
  in-progress month/week (from the daily series) is blended into the last
  slot, so creoson's September shows its real +422 instead of 0. The same
  rule makes the All/Mine/Others summary charts truthful — the aggregate is
  the sum of each repo's observed current-month activity (mine +422, others
  +784, all +1206) instead of a handful of release-cohort scraps (mine shown
  10, others inflated to a release's lifetime 10,899). Repos with no
  measurable activity keep their release estimate, and the in-progress year
  is left untouched since its release-lifetime total is the better
  year-to-date estimate.
- Hovering any compact `#.##k` number (repo rows, category headers, headline
  total, compare/remove rows) reveals the exact figure, e.g. `16.3k` stands
  for `16,308`.
- Panel header shows the installed version, e.g. `GITHUB REPO TRACKER (v0.3.0)`,
  read from the deployed plugin manifest.

## 0.2.1 - 2026-09-16

- Bar widget details panel no longer auto-opens on shell restart; it stays
  closed until the toolbar icon is clicked.
- Star-history fetch hardens its memory and request footprint: strict total
  page/event/byte budgets before scheduling, a bounded number of parallel
  requests in flight, and incremental aggregation that never retains the full
  history.

## 0.2.0 - 2026-09-15

- Chart tooltips now respect the selected period: weekly, monthly, and annual
  views label the delta "this week / this month / this year" instead of a
  misleading per-day rate (daily keeps the "+X/day" rate).
- Chart hover shows a vertical cursor line that tracks the mouse and snaps to
  the nearest data point; the tooltip appears when the line intersects a
  point, and the hovered dot enlarges.
- Tooltip readability: larger bold text, the delta value in full-contrast
  foreground with only the trend arrow colored, and a stronger chip border.

## 0.1.0 - 2026-09-15

- Add the GitHub download monitor service, bar widget, and details panel.
- Track observed download and star totals plus release history.
- Add repository grouping, charts, pinning, comparison, and local deployment.
