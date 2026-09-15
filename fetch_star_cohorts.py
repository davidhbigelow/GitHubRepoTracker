#!/usr/bin/env python3
"""Fetch GitHub's privacy-safe star history and emit aggregate cohorts."""

from __future__ import annotations

import concurrent.futures
import datetime as dt
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


API_ROOT = "https://api.github.com"
API_VERSION = "2026-03-10"
USER_AGENT = "gitdlmon-omarchy-plugin"
REPO_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9_.-]+$")


class FetchError(Exception):
    pass


def parse_last_page(link_header: str | None) -> int:
    """Return the last page advertised by an RFC 8288 Link header."""
    for part in (link_header or "").split(","):
        if 'rel="last"' not in part:
            continue
        match = re.search(r"<([^>]+)>", part)
        if not match:
            continue
        query = urllib.parse.parse_qs(urllib.parse.urlparse(match.group(1)).query)
        try:
            page = int(query.get("page", ["1"])[0])
        except (TypeError, ValueError):
            continue
        if page > 0:
            return page
    return 1


def aggregate_history(records: list[object], now: dt.datetime) -> dict[str, object]:
    """Validate and aggregate Sunday-based GitHub star-history records."""
    if now.tzinfo is None:
        now = now.replace(tzinfo=dt.timezone.utc)
    now = now.astimezone(dt.timezone.utc)
    today = now.date()
    week_start = today - dt.timedelta(days=today.weekday())
    month_index = now.year * 12 + now.month - 1
    maps: dict[str, dict[str, int]] = {
        "days": {}, "weeks": {}, "months": {}, "years": {}
    }
    count = 0

    weeks: dict[int, tuple[int, tuple[int, ...]]] = {}
    for record in records:
        if not isinstance(record, dict):
            raise FetchError("GitHub returned an invalid star history record")
        epoch = record.get("week")
        total = record.get("total")
        days = record.get("days")
        if (not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0 or
                not isinstance(total, int) or isinstance(total, bool) or total < 0 or
                not isinstance(days, list) or len(days) != 7 or
                any(not isinstance(value, int) or isinstance(value, bool) or value < 0 for value in days)):
            raise FetchError("GitHub returned an invalid star history record")
        if sum(days) != total:
            raise FetchError("GitHub star history total does not match its daily counts")
        try:
            sunday = dt.datetime.fromtimestamp(epoch, dt.timezone.utc)
        except (OverflowError, OSError, ValueError) as error:
            raise FetchError("GitHub returned an invalid star history week") from error
        if sunday.weekday() != 6 or any((sunday.hour, sunday.minute, sunday.second, sunday.microsecond)):
            raise FetchError("GitHub star history week is not Sunday 00:00 UTC")
        if sunday.date() > today:
            raise FetchError("GitHub returned a future star history week")
        values = tuple(days)
        item = (total, values)
        if epoch in weeks and weeks[epoch] != item:
            raise FetchError("GitHub returned conflicting duplicate star history weeks")
        weeks[epoch] = item

    for epoch in sorted(weeks):
        sunday = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).date()
        total, values = weeks[epoch]
        future_count = 0
        for offset, value in enumerate(values):
            day = sunday + dt.timedelta(days=offset)
            if day > today:
                future_count += value
                continue
            if value <= 0:
                continue
            if today - dt.timedelta(days=29) <= day:
                key = day.isoformat()
                maps["days"][key] = maps["days"].get(key, 0) + value
            event_week = day - dt.timedelta(days=day.weekday())
            if week_start - dt.timedelta(weeks=7) <= event_week <= week_start:
                key = event_week.isoformat()
                maps["weeks"][key] = maps["weeks"].get(key, 0) + value
            event_month = day.year * 12 + day.month - 1
            if month_index - 11 <= event_month <= month_index:
                key = f"{day.year:04d}-{day.month:02d}"
                maps["months"][key] = maps["months"].get(key, 0) + value
            key = f"{day.year:04d}"
            maps["years"][key] = maps["years"].get(key, 0) + value
        count += total - future_count

    cohorts = {
        name: [{"bucket": key, "stars": buckets[key]} for key in sorted(buckets)]
        for name, buckets in maps.items()
    }
    return {
        "collectedAt": now.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "acquisitionCount": count,
        "starCohorts": cohorts,
    }


def get_token() -> str:
    try:
        result = subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True, timeout=15, check=False
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise FetchError("could not obtain a token from gh auth") from error
    token = result.stdout.strip()
    if result.returncode != 0 or not token:
        raise FetchError("gh auth token failed; authenticate with gh first")
    return token


def fetch_page(repo: str, page: int, token: str) -> tuple[list[object], str]:
    owner, name = repo.split("/", 1)
    url = (
        f"{API_ROOT}/repos/{urllib.parse.quote(owner, safe='')}/"
        f"{urllib.parse.quote(name, safe='')}/stargazers/history?per_page=30&page={page}"
    )
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": USER_AGENT,
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read(2 * 1024 * 1024 + 1)
            link = response.headers.get("Link", "")
    except urllib.error.HTTPError as error:
        raise FetchError(f"GitHub API returned HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise FetchError("GitHub API request failed") from error
    if len(raw) > 2 * 1024 * 1024:
        raise FetchError("GitHub API response exceeded the size limit")
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FetchError("GitHub API returned invalid JSON") from error
    if not isinstance(payload, list):
        raise FetchError("GitHub API returned an unexpected response")
    return payload, link


def fetch_all(repo: str, token: str) -> list[object]:
    first, link = fetch_page(repo, 1, token)
    last_page = parse_last_page(link)
    if last_page <= 1:
        return first
    pages: dict[int, list[object]] = {1: first}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(fetch_page, repo, page, token): page for page in range(2, last_page + 1)}
        for future in concurrent.futures.as_completed(futures):
            page = futures[future]
            payload, _ = future.result()
            pages[page] = payload
    return [event for page in range(1, last_page + 1) for event in pages[page]]


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not REPO_RE.fullmatch(argv[1]):
        print("usage: fetch_star_cohorts.py owner/repo", file=sys.stderr)
        return 2
    try:
        result = aggregate_history(fetch_all(argv[1], get_token()), dt.datetime.now(dt.timezone.utc))
    except FetchError as error:
        print(f"fetch_star_cohorts.py: {error}", file=sys.stderr)
        return 1
    except Exception:
        print("fetch_star_cohorts.py: unexpected fetch failure", file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
