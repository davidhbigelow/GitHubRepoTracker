import datetime as dt
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

    def test_fetch_all_uses_discovered_pages(self):
        responses = {
            1: ([self.record(2026, 9, 13, [1, 0, 0, 0, 0, 0, 0])], '<x?page=3>; rel="last"'),
            2: ([self.record(2026, 9, 6, [2, 0, 0, 0, 0, 0, 0])], ""),
            3: ([self.record(2026, 8, 30, [3, 0, 0, 0, 0, 0, 0])], ""),
        }
        with mock.patch.object(helper, "fetch_page", side_effect=lambda repo, page, token: responses[page]) as fetch:
            events = helper.fetch_all("owner/repo", "secret")
        self.assertEqual([record["total"] for record in events], [1, 2, 3])
        self.assertEqual(fetch.call_count, 3)


if __name__ == "__main__":
    unittest.main()
