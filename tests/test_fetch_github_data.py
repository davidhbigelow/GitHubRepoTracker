import datetime as dt
import io
import threading
import unittest
import urllib.error
from unittest import mock

import fetch_github_data as helper


class StarCohortTests(unittest.TestCase):
    @staticmethod
    def record(year, month, day, days):
        sunday = dt.datetime(year, month, day, tzinfo=dt.timezone.utc)
        return {"week": int(sunday.timestamp()), "total": sum(days), "days": days}

    def test_parse_last_page(self):
        link = '<https://api.github.test/stargazers/history?per_page=30&page=2>; rel="next", <https://api.github.test/stargazers/history?per_page=30&page=33>; rel="last"'
        self.assertEqual(helper.parse_last_page(link), 33)
        self.assertEqual(helper.parse_last_page(None), 1)

    def test_week_expansion_crosses_sunday_iso_boundary_and_excludes_future(self):
        now = dt.datetime(2026, 9, 14, 20, tzinfo=dt.timezone.utc)
        records = [self.record(2026, 9, 13, [2, 3, 9, 0, 0, 0, 0])]
        result = helper.aggregate_history(records, now)
        self.assertEqual(result["acquisitionCount"], 5)
        self.assertEqual(result["collectedAt"], "2026-09-14T20:00:00Z")
        self.assertEqual(result["starCohorts"]["days"], [
            {"bucket": "2026-09-13", "stars": 2},
            {"bucket": "2026-09-14", "stars": 3},
        ])
        self.assertEqual(result["starCohorts"]["weeks"], [
            {"bucket": "2026-09-07", "stars": 2},
            {"bucket": "2026-09-14", "stars": 3},
        ])
        self.assertEqual(result["starCohorts"]["years"], [{"bucket": "2026", "stars": 5}])

    def test_duplicate_week_is_counted_once(self):
        record = self.record(2026, 9, 13, [1, 2, 0, 0, 0, 0, 0])
        result = helper.aggregate_history([record, dict(record)], dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc))
        self.assertEqual(result["acquisitionCount"], 3)
        self.assertEqual(sum(item["stars"] for item in result["starCohorts"]["days"]), 3)

    def test_invalid_week_total_is_rejected(self):
        record = self.record(2026, 9, 13, [1, 0, 0, 0, 0, 0, 0])
        record["total"] = 2
        with self.assertRaisesRegex(helper.FetchError, "total"):
            helper.aggregate_history([record], dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc))

    def test_fetch_cohorts_uses_discovered_pages(self):
        responses = {
            1: ([self.record(2026, 9, 13, [1, 0, 0, 0, 0, 0, 0])], '<x?page=3>; rel="last"', 10),
            2: ([self.record(2026, 9, 6, [2, 0, 0, 0, 0, 0, 0])], "", 10),
            3: ([self.record(2026, 8, 30, [3, 0, 0, 0, 0, 0, 0])], "", 10),
        }
        now = dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc)
        with mock.patch.object(helper, "fetch_page", side_effect=lambda repo, page, token: responses[page]) as fetch:
            result = helper.fetch_cohorts("owner/repo", "secret", now)
        self.assertEqual(result["acquisitionCount"], 6)
        self.assertEqual(sum(item["stars"] for item in result["starCohorts"]["years"]), 6)
        self.assertEqual(fetch.call_count, 3)

    def test_fetch_cohorts_refuses_page_budget_overflow(self):
        now = dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc)
        response = ([], f'<x?page={helper.MAX_PAGES + 1}>; rel="last"', 10)
        with mock.patch.object(helper, "fetch_page", side_effect=lambda repo, page, token: response) as fetch:
            with self.assertRaisesRegex(helper.FetchError, "refusing more than"):
                helper.fetch_cohorts("owner/repo", "secret", now)
        self.assertEqual(fetch.call_count, 1)

    def test_fetch_cohorts_refuses_event_budget_overflow(self):
        now = dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc)
        records = [
            self.record(2026, 9, 13, [1, 0, 0, 0, 0, 0, 0]),
            self.record(2026, 9, 6, [1, 0, 0, 0, 0, 0, 0]),
            self.record(2026, 8, 30, [1, 0, 0, 0, 0, 0, 0]),
        ]
        responses = {
            1: (records, f'<x?page={helper.MAX_PAGES}>; rel="last"', 30),
            2: (records, "", 30),
        }
        with mock.patch.object(helper, "MAX_TOTAL_EVENTS", 2), \
                mock.patch.object(helper, "fetch_page", side_effect=lambda repo, page, token: responses[page]) as fetch:
            with self.assertRaisesRegex(helper.FetchError, "refusing more than"):
                helper.fetch_cohorts("owner/repo", "secret", now)
        self.assertEqual(fetch.call_count, 1)

    def test_fetch_cohorts_refuses_byte_budget_overflow(self):
        now = dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc)
        response = ([self.record(2026, 9, 13, [4, 0, 0, 0, 0, 0, 0])], "", 10)
        with mock.patch.object(helper, "MAX_TOTAL_BYTES", 5), \
                mock.patch.object(helper, "fetch_page", side_effect=lambda repo, page, token: response) as fetch:
            with self.assertRaisesRegex(helper.FetchError, "refusing more than"):
                helper.fetch_cohorts("owner/repo", "secret", now)
        self.assertEqual(fetch.call_count, 1)

    def test_fetch_cohorts_bounds_in_flight_requests(self):
        base = dt.datetime(2026, 9, 13, tzinfo=dt.timezone.utc)
        responses = {}
        for page in range(1, 9):
            sunday = base - dt.timedelta(weeks=page - 1)
            responses[page] = ([self.record(sunday.year, sunday.month, sunday.day, [page, 0, 0, 0, 0, 0, 0])],
                               f'<x?page=8>; rel="last"' if page == 1 else "", 10)
        state = {"active": 0, "peak": 0}
        lock = threading.Lock()

        def fetch(repo, page, token):
            with lock:
                state["active"] += 1
                state["peak"] = max(state["peak"], state["active"])
            payload, link, size = responses[page]
            with lock:
                state["active"] -= 1
            return payload, link, size

        now = dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc)
        with mock.patch.object(helper, "MAX_IN_FLIGHT", 2), \
                mock.patch.object(helper, "fetch_page", side_effect=fetch):
            result = helper.fetch_cohorts("owner/repo", "secret", now)
        self.assertLessEqual(state["peak"], 2)
        self.assertEqual(result["acquisitionCount"], sum(range(1, 9)))


def http_error(case, code, headers=None, body=b""):
    """Build a urllib HTTPError shaped like the ones GitHub actually sends."""
    buffer = io.BytesIO(body)
    case.addCleanup(buffer.close)
    return urllib.error.HTTPError("https://api.github.test", code, "err", headers or {}, buffer)


class RepositoryFetchTests(unittest.TestCase):
    @staticmethod
    def release(tag, downloads, published="2026-01-02T03:04:05Z"):
        return {"tag_name": tag, "published_at": published,
                "assets": [{"download_count": downloads}]}

    def test_fetch_releases_walks_pages_until_a_short_one(self):
        full = [self.release(f"v{i}", i) for i in range(helper.RELEASE_PAGE_SIZE)]
        pages = {
            1: (full, {}, len(str(full))),
            2: (full, {}, len(str(full))),
            3: ([self.release("v3", 3)], {}, 10),
        }
        with mock.patch.object(helper, "api_get", side_effect=lambda url, token, part, **kw: pages[
            int(url.rsplit("page=", 1)[1])]) as get:
            releases = helper.fetch_releases("owner/repo", "secret")
        self.assertEqual(len(releases), 2 * helper.RELEASE_PAGE_SIZE + 1)
        self.assertEqual(get.call_count, 3)
        self.assertEqual(get.call_args[0][2], "releases")

    def test_fetch_releases_stops_on_an_empty_first_page(self):
        with mock.patch.object(helper, "api_get", return_value=([], {}, 2)) as get:
            self.assertEqual(helper.fetch_releases("owner/repo", ""), [])
        self.assertEqual(get.call_count, 1)

    def test_fetch_releases_refuses_page_budget_overflow(self):
        full = [self.release("v", 1)] * helper.RELEASE_PAGE_SIZE
        with mock.patch.object(helper, "MAX_RELEASE_PAGES", 3), \
                mock.patch.object(helper, "api_get", return_value=(full, {}, 10)):
            with self.assertRaisesRegex(helper.FetchError, "refusing more than"):
                helper.fetch_releases("owner/repo", "")

    def test_fetch_releases_rejects_a_non_list_payload(self):
        with mock.patch.object(helper, "api_get", return_value=({"message": "nope"}, {}, 2)):
            with self.assertRaisesRegex(helper.ApiError, "unexpected release list"):
                helper.fetch_releases("owner/repo", "")

    def test_fetch_info_normalises_the_created_timestamp(self):
        with mock.patch.object(helper, "api_get", return_value=(
                {"stargazers_count": 150, "created_at": "2017-06-13T23:21:21Z"}, {}, 2)):
            self.assertEqual(
                helper.fetch_info("owner/repo", "secret"),
                {"stars": 150, "created": "2017-06-13T23:21:21+00:00"},
            )

    def test_fetch_info_rejects_a_missing_star_count(self):
        with mock.patch.object(helper, "api_get", return_value=({"created_at": "2017-06-13T23:21:21Z"}, {}, 2)):
            with self.assertRaisesRegex(helper.ApiError, "invalid star count"):
                helper.fetch_info("owner/repo", "")

    def test_api_get_sends_the_token_only_when_there_is_one(self):
        seen = {}

        class FakeResponse:
            headers = {}

            def read(self, _n):
                return b"[]"

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def fake_urlopen(request, timeout=None):
            seen["auth"] = request.get_header("Authorization")
            return FakeResponse()

        with mock.patch.object(helper.urllib.request, "urlopen", fake_urlopen):
            helper.api_get("https://api.github.test/x", "secret", "releases")
            self.assertEqual(seen["auth"], "Bearer secret")
            helper.api_get("https://api.github.test/x", "", "releases")
            self.assertIsNone(seen["auth"])

    def test_get_token_is_optional(self):
        failed = mock.Mock(returncode=1, stdout="\n")
        with mock.patch.object(helper.subprocess, "run", return_value=failed):
            self.assertEqual(helper.get_token(required=False), "")
            with self.assertRaisesRegex(helper.FetchError, "authenticate with gh"):
                helper.get_token(required=True)

    def test_get_token_returns_empty_when_gh_is_missing(self):
        with mock.patch.object(helper.subprocess, "run", side_effect=OSError("no gh")):
            self.assertEqual(helper.get_token(required=False), "")
            with self.assertRaisesRegex(helper.FetchError, "could not obtain a token"):
                helper.get_token(required=True)

    def test_http_error_classification(self):
        limited = helper._http_error(http_error(self,
            403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1790553795"},
            b'{"message":"API rate limit exceeded"}'), "releases")
        self.assertEqual(limited.kind, "rate-limited")
        self.assertEqual(limited.reset_at, "2026-09-28T00:03:15Z")
        self.assertEqual(limited.part, "releases")
        # A 403 with budget to spare is a refusal, not a spent budget.
        self.assertEqual(helper._http_error(http_error(self, 403, {"X-RateLimit-Remaining": "42"}), "releases").kind,
                         "forbidden")
        # GitHub states the limit in the body even when the header is missing.
        self.assertEqual(helper._http_error(http_error(self, 403, {}, b'{"message":"rate limit exceeded"}'), "info").kind,
                         "rate-limited")
        self.assertEqual(helper._http_error(http_error(self, 429), "info").kind, "rate-limited")
        self.assertEqual(helper._http_error(http_error(self, 401), "info").kind, "not-authenticated")
        self.assertEqual(helper._http_error(http_error(self, 404), "releases").kind, "not-found")
        self.assertEqual(helper._http_error(http_error(self, 500), "stars").kind, "unknown")
        self.assertEqual(helper._http_error(http_error(self, 403), "stars").part, "stars")

    def test_collect_keeps_partial_results_when_metadata_and_stars_fail(self):
        releases = [self.release("v1", 5)]
        now = dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc)
        info_error = helper.ApiError("GitHub returned HTTP 500", kind="unknown", part="info")
        star_error = helper.ApiError("GitHub API rate limit reached", kind="rate-limited",
                                     part="stars", reset_at="2026-09-28T00:03:15Z")
        with mock.patch.object(helper, "fetch_releases", return_value=releases), \
                mock.patch.object(helper, "fetch_info", side_effect=info_error), \
                mock.patch.object(helper, "fetch_cohorts", side_effect=star_error):
            result = helper.collect("owner/repo", "secret", now)
        self.assertEqual(result["releases"], releases)
        self.assertNotIn("info", result)
        self.assertNotIn("starCohorts", result)
        self.assertEqual([f["part"] for f in result["failures"]], ["info", "stars"])
        self.assertEqual(result["authenticated"], True)

    def test_collect_lets_a_release_failure_escape(self):
        with mock.patch.object(helper, "fetch_releases",
                               side_effect=helper.ApiError("gone", kind="not-found", part="releases")):
            with self.assertRaises(helper.ApiError):
                helper.collect("owner/repo", "", dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc))

    def test_collect_reports_an_unauthenticated_run(self):
        with mock.patch.object(helper, "fetch_releases", return_value=[]), \
                mock.patch.object(helper, "fetch_info", side_effect=helper.ApiError("x", part="info")), \
                mock.patch.object(helper, "fetch_cohorts", side_effect=helper.ApiError("y", part="stars")):
            result = helper.collect("owner/repo", "", dt.datetime(2026, 9, 14, tzinfo=dt.timezone.utc))
        self.assertEqual(result["authenticated"], False)


if __name__ == "__main__":
    unittest.main()
