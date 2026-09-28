#!/usr/bin/env python3
"""Fetch everything the tracker needs for one repository, behind one token.

Emits a single JSON document, so a refresh costs one child process per
repository instead of three and the GitHub token is read once and held in this
process's memory. It is never placed in any child's arguments, where it would
be visible in /proc to other local users, and never written to disk.
"""

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
USER_AGENT = "ghrepotracker-omarchy-plugin"
REPO_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9_.-]+$")
PAGE_SIZE = 30
RELEASE_PAGE_SIZE = 100
MAX_IN_FLIGHT = 4
MAX_PAGES = 1000
MAX_TOTAL_EVENTS = 30000
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_RELEASE_PAGES = 200
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
BUDGET_MESSAGE = (
    f"refusing more than {MAX_PAGES} pages, {MAX_TOTAL_EVENTS} star events, "
    f"{MAX_RELEASE_PAGES} release pages, or {MAX_TOTAL_BYTES} bytes per fetch"
)


class FetchError(Exception):
    pass


class ApiError(FetchError):
    """A failure that already knows what kind it is, for the panel to render.

    `kind` matches the vocabulary Model.js classifies into, so the panel shows
    "Rate limited by GitHub, resets 20:03" rather than passing along a sentence
    it would then have to take apart again.
    """

    def __init__(self, message: str, *, kind: str = "unknown", part: str = "releases", reset_at: str = "") -> None:
        super().__init__(message)
        self.kind = kind
        self.part = part
        self.reset_at = reset_at

    def diagnostic(self) -> dict[str, str]:
        return {"part": self.part, "kind": self.kind, "message": str(self), "resetAt": self.reset_at}


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


class CohortAggregator:
    """Incrementally fold validated star-history weeks into aggregate cohorts."""

    def __init__(self, now: dt.datetime) -> None:
        if now.tzinfo is None:
            now = now.replace(tzinfo=dt.timezone.utc)
        self._now = now.astimezone(dt.timezone.utc)
        today = self._now.date()
        self._today = today
        self._week_start = today - dt.timedelta(days=today.weekday())
        self._month_index = self._now.year * 12 + self._now.month - 1
        self._weeks: dict[int, tuple[int, tuple[int, ...]]] = {}

    def feed(self, records: list[object]) -> None:
        """Validate and accumulate a page of star-history records."""
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
            if sunday.date() > self._today:
                raise FetchError("GitHub returned a future star history week")
            values = tuple(days)
            item = (total, values)
            if epoch in self._weeks and self._weeks[epoch] != item:
                raise FetchError("GitHub returned conflicting duplicate star history weeks")
            self._weeks[epoch] = item

    def result(self) -> dict[str, object]:
        """Render the accumulated weeks as aggregate cohorts."""
        today = self._today
        week_start = self._week_start
        month_index = self._month_index
        maps: dict[str, dict[str, int]] = {
            "days": {}, "weeks": {}, "months": {}, "years": {}
        }
        count = 0

        for epoch in sorted(self._weeks):
            sunday = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).date()
            total, values = self._weeks[epoch]
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
            "collectedAt": self._now.isoformat(timespec="seconds").replace("+00:00", "Z"),
            "acquisitionCount": count,
            "starCohorts": cohorts,
        }


def aggregate_history(records: list[object], now: dt.datetime) -> dict[str, object]:
    """Validate and aggregate a full list of GitHub star-history records."""
    aggregator = CohortAggregator(now)
    aggregator.feed(records)
    return aggregator.result()


def get_token(required: bool = True) -> str:
    """Return a GitHub token, or "" when the user has not signed in.

    A token is worth having (5,000 requests/hour instead of 60) but not worth
    failing over: without one every endpoint used here still works, and the
    panel says so if the budget runs out.
    """
    try:
        result = subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True, timeout=15, check=False
        )
    except (OSError, subprocess.SubprocessError) as error:
        if required:
            raise FetchError("could not obtain a token from gh auth") from error
        return ""
    token = result.stdout.strip()
    if result.returncode != 0 or not token:
        if required:
            raise FetchError("gh auth token failed; authenticate with gh first")
        return ""
    return token


def repo_url(repo: str, suffix: str = "") -> str:
    owner, name = repo.split("/", 1)
    return (
        f"{API_ROOT}/repos/{urllib.parse.quote(owner, safe='')}/"
        f"{urllib.parse.quote(name, safe='')}{suffix}"
    )


def _http_error(error: urllib.error.HTTPError, part: str) -> ApiError:
    """Turn an HTTPError into a diagnosis the panel can act on."""
    headers = error.headers
    remaining = headers.get("X-RateLimit-Remaining") if headers else None
    reset = headers.get("X-RateLimit-Reset") if headers else None
    message = ""
    try:
        payload = json.loads(error.read())
        if isinstance(payload, dict):
            message = str(payload.get("message", "")).lower()
    except Exception:  # noqa: BLE001 - the body is advisory only
        pass
    finally:
        # urllib hands back an error whose file handle is still open and nothing
        # else will ever read it.
        error.close()
    reset_at = ""
    if reset and str(reset).isdigit():
        reset_at = (
            dt.datetime.fromtimestamp(int(reset), dt.timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z")
        )
    # A 403 only means the budget is spent when GitHub says so: either the
    # remaining count is zero or the body names the limit. Any other 403 is a
    # refusal, and must not be reported as a rate limit.
    limited = error.code == 429 or (error.code == 403 and (remaining == "0" or "rate limit" in message))
    if limited:
        text = "GitHub API rate limit reached"
        if reset:
            text += f", resets {reset}"
        return ApiError(text, kind="rate-limited", part=part, reset_at=reset_at)
    if error.code == 401:
        return ApiError("GitHub rejected the credentials", kind="not-authenticated", part=part)
    if error.code == 403:
        return ApiError("GitHub refused the request (403)", kind="forbidden", part=part)
    if error.code == 404:
        return ApiError("Repository or endpoint not found", kind="not-found", part=part)
    return ApiError(f"GitHub returned HTTP {error.code}", kind="unknown", part=part)


def api_get(url: str, token: str, part: str, *, max_bytes: int = MAX_RESPONSE_BYTES) -> tuple[object, object, int]:
    """GET a GitHub endpoint, authenticated when a token is available."""
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": USER_AGENT,
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read(max_bytes + 1)
            response_headers = response.headers
    except urllib.error.HTTPError as error:
        raise _http_error(error, part) from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ApiError("Could not reach the GitHub API", kind="network", part=part) from error
    if len(raw) > max_bytes:
        raise ApiError("GitHub API response exceeded the size limit", kind="unknown", part=part)
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ApiError("GitHub API returned invalid JSON", kind="unknown", part=part) from error
    return payload, response_headers, len(raw)


def fetch_releases(repo: str, token: str) -> list[object]:
    """Every release, paginated until GitHub returns a short page."""
    releases: list[object] = []
    total_bytes = 0
    page = 1
    while True:
        if page > MAX_RELEASE_PAGES:
            raise ApiError(BUDGET_MESSAGE, kind="unknown", part="releases")
        url = repo_url(repo, f"/releases?per_page={RELEASE_PAGE_SIZE}&page={page}")
        payload, _, size = api_get(url, token, "releases")
        total_bytes += size
        if total_bytes > MAX_TOTAL_BYTES:
            raise ApiError(BUDGET_MESSAGE, kind="unknown", part="releases")
        if not isinstance(payload, list):
            raise ApiError("GitHub returned an unexpected release list", kind="unknown", part="releases")
        releases.extend(payload)
        if len(payload) < RELEASE_PAGE_SIZE:
            return releases
        page += 1


def fetch_info(repo: str, token: str) -> dict[str, object]:
    """Star count and creation date, which the rows and the daily chart need."""
    payload, _, _ = api_get(repo_url(repo), token, "info")
    if not isinstance(payload, dict):
        raise ApiError("GitHub returned an unexpected repository", kind="unknown", part="info")
    stars = payload.get("stargazers_count")
    created = payload.get("created_at")
    if not isinstance(stars, int) or isinstance(stars, bool) or stars < 0:
        raise ApiError("GitHub returned an invalid star count", kind="unknown", part="info")
    if not isinstance(created, str) or not created:
        raise ApiError("GitHub returned an invalid creation date", kind="unknown", part="info")
    return {"stars": stars, "created": created.replace("Z", "+00:00")}


def fetch_page(repo: str, page: int, token: str) -> tuple[list[object], str, int]:
    """One star-history page, kept as its own wrapper for the Link header."""
    url = repo_url(repo, f"/stargazers/history?per_page={PAGE_SIZE}&page={page}")
    payload, headers, size = api_get(url, token, "stars")
    if not isinstance(payload, list):
        raise ApiError("GitHub returned an unexpected response", kind="unknown", part="stars")
    return payload, (headers.get("Link", "") if headers else ""), size


def fetch_cohorts(repo: str, token: str, now: dt.datetime) -> dict[str, object]:
    """Stream star-history pages into cohorts without retaining the full history."""
    aggregator = CohortAggregator(now)
    first, link, first_size = fetch_page(repo, 1, token)
    aggregator.feed(first)
    total_events = len(first)
    total_bytes = first_size
    if total_events > MAX_TOTAL_EVENTS or total_bytes > MAX_TOTAL_BYTES:
        raise FetchError(BUDGET_MESSAGE)
    last_page = parse_last_page(link)
    if last_page > MAX_PAGES:
        raise FetchError(BUDGET_MESSAGE)
    if last_page <= 1:
        return aggregator.result()

    pending = last_page - 1
    next_page = 2
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_IN_FLIGHT) as executor:
        in_flight: set[concurrent.futures.Future[object]] = set()
        try:
            while pending or in_flight:
                while pending and len(in_flight) < MAX_IN_FLIGHT:
                    in_flight.add(executor.submit(fetch_page, repo, next_page, token))
                    next_page += 1
                    pending -= 1
                if not in_flight:
                    break
                done, _ = concurrent.futures.wait(
                    in_flight, return_when=concurrent.futures.FIRST_COMPLETED
                )
                in_flight.difference_update(done)
                for future in done:
                    payload, _, size = future.result()
                    aggregator.feed(payload)
                    total_events += len(payload)
                    total_bytes += size
                    if total_events > MAX_TOTAL_EVENTS or total_bytes > MAX_TOTAL_BYTES:
                        raise FetchError(BUDGET_MESSAGE)
        finally:
            for future in in_flight:
                future.cancel()
    return aggregator.result()


def collect(repo: str, token: str, now: dt.datetime) -> dict[str, object]:
    """Gather every part of a refresh, keeping partial results.

    Releases are the critical path: without them there is no observation to
    record, so their failure fails the whole repository. Metadata and star
    history are refinements -- a failure there still reports what did land,
    which is what keeps a rate-limited star call from discarding good download
    counts.
    """
    result: dict[str, object] = {
        "collectedAt": now.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "authenticated": bool(token),
        "failures": [],
    }
    failures: list[dict[str, str]] = result["failures"]  # type: ignore[assignment]

    result["releases"] = fetch_releases(repo, token)

    try:
        result["info"] = fetch_info(repo, token)
    except ApiError as error:
        failures.append(error.diagnostic())
    try:
        cohorts = fetch_cohorts(repo, token, now)
    except ApiError as error:
        failures.append(error.diagnostic())
    else:
        result["starCohorts"] = cohorts["starCohorts"]
        result["starCohortsCollectedAt"] = cohorts["collectedAt"]
    return result


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not REPO_RE.fullmatch(argv[1]):
        print("usage: fetch_github_data.py owner/repo", file=sys.stderr)
        return 2
    try:
        token = get_token(required=False)
    except FetchError as error:
        print(f"fetch_github_data.py: {error}", file=sys.stderr)
        return 1
    try:
        result = collect(argv[1], token, dt.datetime.now(dt.timezone.utc))
    except ApiError as error:
        # A diagnosis, not a sentence: the panel keys its notice off `kind`.
        print(json.dumps(error.diagnostic(), separators=(",", ":"), sort_keys=True), file=sys.stderr)
        return 1
    except FetchError as error:
        print(json.dumps(
            {"part": "releases", "kind": "unknown", "message": str(error), "resetAt": ""},
            separators=(",", ":"), sort_keys=True,
        ), file=sys.stderr)
        return 1
    except Exception:
        print("fetch_github_data.py: unexpected fetch failure", file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
