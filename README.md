# GitHub Download Monitor

An Omarchy 4 bar widget that tracks cumulative GitHub release-asset downloads,
stars, and releases. It keeps daily observations, groups repositories into
"mine" and "others", and provides trend charts and normalized comparisons.

## Requirements

- Omarchy 4.0.0 or later with Quattro shell-plugin support
- `curl`
- Python 3
- GitHub CLI (`gh`) authenticated with `gh auth login` for historical stars
- Network access to `https://api.github.com`

Release and repository metadata use GitHub's unauthenticated API allowance.
Historical star acquisitions use the authenticated `gh` token and refresh with
each repository refresh. The token is obtained by the helper through captured
`gh auth token` output; it is never put in process arguments, environment
variables, configuration, or cache files.

GitHub's privacy-safe star-history endpoint returns 30 weekly aggregate records
per page and no identities. A full history refresh is based on repository age,
not star count: even repositories dating to GitHub's earliest years need only
roughly 33 requests. At most four pages are fetched concurrently after page 1
discovers the final page.

## Install

From GitHub, once the repository is published:

```bash
omarchy plugin add https://github.com/davidhbigelow/gitdlmon.git --enable
```

For local development, deploy this checkout with:

```bash
./scripts/deploy-local
```

The deployment script validates the source and copies only runtime plugin files
to `~/.config/omarchy/plugins/davidhbigelow.gitdlmon`.

## Usage

Click the bar widget to open the details panel. Add repositories as
`owner/repository`, switch between downloads, stars, and releases, select a row
to pin its chart, or select multiple rows to compare them. The refresh control
requests an immediate update.

Configuration is stored at:

```text
~/.config/omarchy/settings/gitdlmon.json
```

Example:

```json
{
  "categories": {
    "mine": ["owner/repository"],
    "others": []
  },
  "refreshHours": 24
}
```

The plugin writes observations and aggregate state under
`~/.local/state/omarchy/gitdlmon/`. GitHub repository and release metadata are
requested from GitHub's API. No telemetry is collected. Authentication remains
in memory only while the star acquisition helper calls GitHub.

## Persisted Schema

Each repository cache and the generated `store.json` has `schemaVersion: 3`.
Repository caches contain compact current and status records plus observed
cumulative counters grouped into fixed calendar buckets:

The machine-readable cache contract is
[`schemas/repository-cache.schema.json`](schemas/repository-cache.schema.json).

```json
{
  "schemaVersion": 3,
  "repo": "owner/repository",
  "current": {
    "downloads": 120,
    "stars": 12,
    "releases": 4,
    "assets": 9,
    "observedAt": "2026-09-14T12:00:00.000Z"
  },
  "status": {
    "lastAttemptAt": "2026-09-14T12:00:00.000Z",
    "lastSuccessAt": "2026-09-14T12:00:00.000Z",
    "error": ""
  },
  "history": {
    "days": [],
    "weeks": [],
    "months": [],
    "years": []
  },
  "cohorts": {
    "days": [],
    "weeks": [],
    "months": [],
    "years": [
      { "bucket": "2026", "downloads": 120, "releases": 4, "assets": 9 }
    ]
  },
  "starCohorts": {
    "days": [],
    "weeks": [],
    "months": [],
    "years": [{ "bucket": "2026", "stars": 12 }]
  },
  "starCohortsUpdatedAt": "2026-09-14T12:00:00.000Z"
}
```

`days` retains 30 UTC-day buckets, `weeks` retains 8 ISO/Monday buckets,
`months` retains 12 calendar-month buckets, and `years` is unbounded. A refresh
upserts one coherent observation into the current bucket of every collection.
The counters are values actually observed from GitHub; the plugin does not
invent historical download events. Schema-v2 and legacy caches are migrated in place,
retaining their snapshots and current counters while dropping bulky
`releaseMeta` data. The aggregate store mirrors per-repository histories and
includes an aggregate `history` projection using the same collections.

When legacy `releaseMeta` is available, migration may seed `cohorts` from its
release publication dates and current lifetime totals; it is never converted
to period download activity.

`cohorts` is separate from observed history. It stores current lifetime
release-asset downloads, release counts, and asset counts grouped by each
release's `published_at` period. It does **not** claim those downloads occurred
in that day, week, month, or year. Only non-empty release buckets are persisted;
charts add zero-volume slots to show the fixed last 30 calendar days, last 8 ISO
weeks, last 12 calendar months, and every year from the oldest known release to
the current year. Downloads and releases use this release-date view while the
selected observed period has fewer than two points, then switch to the observed
trend.

`starCohorts` is distinct from release cohorts and observed counter history. It
contains only positive acquisition counts expanded from GitHub's privacy-safe
weekly history; individual users and logins are neither requested nor persisted.
Stars use observed history once the selected period has at least two real
observations, otherwise
they use the fixed 30-day, 8-ISO-week, 12-month, or all-year acquisition view
when every displayed repository has cohort data. Raw values mean acquisitions
by starred date; `CUM` means cumulative star acquisitions. These are not net
historical star counts because GitHub does not expose unstar events. Top totals
always remain the current `stargazers_count`.

The panel's `CUM` control switches cohort charts between per-period volume and
a running sum. For observed counters it switches between period-over-period
change and GitHub's cumulative total.

## Validate

Development checks require Python 3 and Node.js.

```bash
./tests/run
omarchy plugin validate .
```

The manifest and source have been structurally validated on Omarchy `4.0.3-1`.
This does not constitute a security certification or establish compatibility
with every future Omarchy release.

## Update And Remove

```bash
omarchy plugin update davidhbigelow.gitdlmon --yes
omarchy plugin remove davidhbigelow.gitdlmon --yes
```

Removal deliberately retains settings and historical observations. Remove
them explicitly if no longer wanted:

```bash
rm -rf ~/.local/state/omarchy/gitdlmon
rm -f ~/.config/omarchy/settings/gitdlmon.json
```

## Security And Support

Omarchy plugins execute unsandboxed inside `omarchy-shell`. Review source before
enabling it. Report bugs through the repository issue tracker and report
security issues through GitHub's private security-advisory feature.

## License

MIT, Copyright (c) 2026 David Bigelow. See [LICENSE](LICENSE).
