# GitHub Repo Tracker

<img width="385" height="450" alt="preview" src="https://github.com/user-attachments/assets/25c061f7-18b0-4032-bbf6-6676c2d26968" />


## DONATE / SUPPORT
<a href="https://www.buymeacoffee.com/davidhbigelow" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" style="height: 60px !important;width: 217px !important;" ></a>


An [Omarchy](https://omarchy.org) bar widget that tracks GitHub repositories:
release-asset downloads, stars, and release counts, with trend charts and a
normalized compare view.

## What it does

- Bar widget with a trend icon and aggregate total; click to open the details panel
- Track your own repos and third-party repos in separate **mine** / **others** groups
- Switch between **downloads**, **stars**, and **releases** metrics
- Daily / weekly / monthly / annual charts, with a cumulative toggle
- Click a repo row to pin its chart; select multiple repos to compare them
- Add or remove repos from the panel; refresh on demand with live progress

## Requirements

- Omarchy 4.0.0 or later
- `curl` and Python 3
- GitHub CLI (`gh`) authenticated with `gh auth login` (used for historical
  star data)
- Network access to `https://api.github.com`

## Install

```bash
omarchy plugin add https://github.com/davidhbigelow/GitHubRepoTracker.git --enable
```

## Update

```bash
omarchy plugin update ghrepo.tracker
```

## Remove

```bash
omarchy plugin remove ghrepo.tracker
```

## Configuration

Repositories are managed from the panel (add button, or trash to remove), or
by editing the settings file directly:

```text
~/.config/omarchy/settings/ghrepotracker.json
```

```json
{
  "categories": {
    "mine": ["owner/repository"],
    "others": []
  },
  "refreshHours": 24
}
```

`refreshHours` controls how often cached data is refreshed from the GitHub API.

## Notes

Omarchy plugins run unsandboxed inside `omarchy-shell` — review the source
before enabling. Report bugs through the repository issue tracker.

## License

MIT, Copyright (c) 2026 David Bigelow. See [LICENSE](LICENSE).
