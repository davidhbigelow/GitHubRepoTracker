import datetime as dt
import threading
import unittest
from unittest import mock

import fetch_star_cohorts as helper


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


if __name__ == "__main__":
    unittest.main()
