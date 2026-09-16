# Changelog

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
