# Changelog

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
