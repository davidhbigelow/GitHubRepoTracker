#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const context = vm.createContext({
  Array,
  Date,
  Infinity,
  JSON,
  Math,
  Number,
  String,
  encodeURIComponent,
  isFinite,
  isNaN,
});
vm.runInContext(fs.readFileSync(path.join(root, "Model.js"), "utf8"), context);

const config = context.parseConfig(JSON.stringify({
  categories: { mine: ["owner/project"], others: ["other/tool"] },
  refreshHours: 12,
  token: "must-not-survive",
}));
assert.deepEqual(Array.from(config.categories.mine), ["owner/project"]);
assert.equal(config.refreshHours, 12);
assert.equal(Object.hasOwn(config, "token"), false);
assert.equal(context.configText(config).includes("token"), false);

assert.equal(context.sanitizeRepo(" owner/project ").repo, "owner/project");
assert.equal(context.sanitizeRepo("missing-slash").valid, false);
assert.equal(context.sanitizeRepo("owner/project/extra").valid, false);

assert.equal(
  context.githubUrl("owner/project", 2),
  "https://api.github.com/repos/owner/project/releases?per_page=100&page=2",
);
const command = Array.from(context.fetchCommand("https://api.github.com/example"));
assert.equal(command[0], "curl");
assert.equal(command.includes("--max-filesize"), true);
assert.equal(command.some((part) => part.includes("Authorization")), false);
assert.equal(command.some((part) => part.includes("X-GitHub-Api-Version")), true);
assert.equal(context.miniSpark([], 9), "○");
assert.equal(context.miniSpark([42], 9), "●");

const summary = context.sumReleases([
  {
    tag_name: "v1.0.0",
    published_at: "2026-01-02T03:04:05Z",
    assets: [{ download_count: 7 }, { download_count: 5 }],
  },
  { tag_name: "v1.1.0", published_at: null, assets: [] },
]);
assert.equal(summary.total, 12);
assert.equal(summary.releaseCount, 2);
assert.equal(summary.assetCount, 2);

const cohortReleases = [
  { published_at: "2026-09-14T03:00:00Z", assets: [{ download_count: 7 }, { download_count: 5 }] },
  { published_at: "2026-09-14T18:00:00Z", assets: [{ download_count: 8 }] },
  { published_at: "2026-08-01T00:00:00Z", assets: [{ download_count: 30 }] },
  { published_at: "2024-02-01T00:00:00Z", assets: [] },
];
const cohorts = context.releaseCohorts(cohortReleases, "2026-09-14T20:00:00Z");
assert.deepEqual(
  { ...cohorts.days[0] },
  { bucket: "2026-09-14", downloads: 20, releases: 2, assets: 3 },
);
assert.equal(cohorts.weeks.at(-1).downloads, 20);
assert.equal(cohorts.months.find((point) => point.bucket === "2026-09").releases, 2);
assert.deepEqual(Array.from(cohorts.years, (point) => point.bucket), ["2024", "2026"]);
assert.equal(cohorts.years[1].downloads, 50);

const cohortEntry = { history: { days: [], weeks: [], months: [], years: [] }, cohorts };
const cohortDaily = context.cohortTimeline([cohortEntry], "dl", "daily", "2026-09-14T20:00:00Z");
assert.equal(cohortDaily.steps.length, 30);
assert.equal(cohortDaily.totals.filter((value) => value === 0).length, 29);
assert.equal(cohortDaily.totals.at(-1), 20);
const cohortWeekly = context.cohortTimeline([cohortEntry], "releases", "weekly", "2026-09-14T20:00:00Z");
assert.equal(cohortWeekly.steps.length, 8);
assert.equal(cohortWeekly.totals.at(-1), 2);
const cohortMonthly = context.cohortTimeline([cohortEntry], "dl", "monthly", "2026-09-14T20:00:00Z");
assert.equal(cohortMonthly.steps.length, 12);
assert.equal(cohortMonthly.totals.at(-2), 30);
assert.equal(cohortMonthly.totals.at(-1), 20);
const cohortAnnual = context.cohortTimeline([cohortEntry], "releases", "annual", "2026-09-14T20:00:00Z");
assert.equal(cohortAnnual.steps.length, 3);
assert.deepEqual(Array.from(cohortAnnual.totals), [1, 0, 3]);
assert.equal(context.selectedTimeline([cohortEntry], "dl", "monthly", "2026-09-14T20:00:00Z").source, "cohort");
assert.equal(context.selectedTimeline([cohortEntry], "stars", "monthly", "2026-09-14T20:00:00Z").source, "observed");
const helperResult = context.parseStarCohorts(JSON.stringify({
  collectedAt: "2026-09-14T19:00:00Z",
  acquisitionCount: 5,
  starCohorts: {
    days: [{ bucket: "2026-09-14", stars: 2 }],
    weeks: [{ bucket: "2026-09-14", stars: 2 }],
    months: [{ bucket: "2026-08", stars: 3 }, { bucket: "2026-09", stars: 2 }],
    years: [{ bucket: "2026", stars: 5 }],
  },
}));
assert.equal(helperResult.acquisitionCount, 5);
const starCohortEntry = {
  history: { days: [], weeks: [], months: [], years: [] },
  starCohorts: helperResult.starCohorts,
  starCohortsUpdatedAt: helperResult.collectedAt,
};
const selectedStars = context.selectedTimeline([starCohortEntry], "stars", "monthly", "2026-09-14T20:00:00Z");
assert.equal(selectedStars.source, "star-cohort");
assert.equal(selectedStars.steps.length, 12);
assert.deepEqual(Array.from(selectedStars.totals.slice(-2)), [3, 2]);
assert.deepEqual(Array.from(context.displayTimeline(selectedStars, true).totals.slice(-2)), [3, 5]);
assert.equal(context.parseStarCohorts('{"collectedAt":"bad"}'), null);
const rawCohorts = context.displayTimeline(cohortMonthly, false);
assert.deepEqual(Array.from(rawCohorts.totals.slice(-2)), [30, 20]);
const cumulativeCohorts = context.displayTimeline(cohortMonthly, true);
assert.deepEqual(Array.from(cumulativeCohorts.totals.slice(-2)), [30, 50]);
const oneObservation = {
  ...cohortEntry,
  history: {
    days: [],
    weeks: [],
    months: [{ bucket: "2026-09", observedAt: "2026-09-14T20:00:00Z", downloads: 50 }],
    years: [],
  },
};
assert.equal(context.selectedTimeline([oneObservation], "dl", "monthly", "2026-09-14T20:00:00Z").source, "cohort");

// A bounded cohort timeline must not render the current, still-open month as
// zero: real observed activity inside that bucket (from the daily series) is
// blended into the trailing slot so events and cumulative stay consistent.
const blendedEntry = {
  history: {
    days: [
      { bucket: "2026-09-10", observedAt: "2026-09-10T12:00:00.000Z", downloads: 100 },
      { bucket: "2026-09-14", observedAt: "2026-09-14T12:00:00.000Z", downloads: 130 },
      { bucket: "2026-09-22", observedAt: "2026-09-22T12:00:00.000Z", downloads: 155 },
    ],
    weeks: [], months: [], years: [],
  },
  cohorts: {
    days: [], weeks: [], months: [
      { bucket: "2026-07", downloads: 40, releases: 1, assets: 1 },
      { bucket: "2026-08", downloads: 30, releases: 1, assets: 1 },
    ], years: [],
  },
};
const blended = context.selectedTimeline([blendedEntry], "dl", "monthly", "2026-09-22T12:00:00.000Z");
assert.equal(blended.source, "cohort");
assert.deepEqual(Array.from(blended.totals.slice(-2)), [30, 55]);
assert.deepEqual(Array.from(context.displayTimeline(blended, true).totals.slice(-2)), [70, 125]);

// A lifetime-cohort value would otherwise masquerade as this month's
// downloads (a release's asset count is its all-time total). Real observed
// activity in the current bucket takes precedence over it.
const trailingCohort = {
  ...blendedEntry,
  cohorts: {
    ...blendedEntry.cohorts,
    months: [
      ...blendedEntry.cohorts.months,
      { bucket: "2026-09", downloads: 20, releases: 1, assets: 1 },
    ],
  },
};
const keepSlot = context.selectedTimeline([trailingCohort], "dl", "monthly", "2026-09-22T12:00:00.000Z");
assert.equal(Number(keepSlot.totals.at(-1)), 55);

// Aggregates must not under-report either: when any repo contributes an
// observed current-bucket delta, the whole group's trailing slot uses the sum
// of observed deltas, not the release-cohort scraps.
const secondEntry = {
  ...blendedEntry,
  history: {
    days: [
      { bucket: "2026-09-11", observedAt: "2026-09-11T12:00:00.000Z", downloads: 20 },
      { bucket: "2026-09-20", observedAt: "2026-09-20T12:00:00.000Z", downloads: 23 },
    ],
    weeks: [], months: [], years: [],
  },
  cohorts: {
    days: [], weeks: [], months: [
      { bucket: "2026-09", downloads: 10, releases: 1, assets: 1 },
    ], years: [],
  },
};
const aggregate = context.selectedTimeline([trailingCohort, secondEntry], "dl", "monthly", "2026-09-22T12:00:00.000Z");
assert.deepEqual(Array.from(aggregate.totals.slice(-2)), [30, 58]);

// Repos with no observed activity in the current bucket keep their cohort
// value, so an unseen month stays as the release estimate rather than 0.
const noObservations = {
  ...blendedEntry,
  history: { days: [], weeks: [], months: [], years: [] },
  cohorts: {
    ...blendedEntry.cohorts,
    months: [
      ...blendedEntry.cohorts.months,
      { bucket: "2026-09", downloads: 20, releases: 1, assets: 1 },
    ],
  },
};
const unseen = context.selectedTimeline([noObservations], "dl", "monthly", "2026-09-22T12:00:00.000Z");
assert.equal(Number(unseen.totals.at(-1)), 20);

// The in-progress year is NOT overridden: the lifetime total of this year's
// releases is a better year-to-date estimate than the measured daily span.
const yearline = context.selectedTimeline([trailingCohort], "dl", "annual", "2026-09-22T12:00:00.000Z");
assert.equal(Number(yearline.totals.at(-1)), 0);

// Release/asset counts are snapshot counts, never blended into a cohort slot.
const releaseBlend = context.selectedTimeline([blendedEntry], "releases", "monthly", "2026-09-22T12:00:00.000Z");
assert.equal(Number(releaseBlend.totals.at(-1)), 0);

const legacy = {
  repo: "owner/project",
  category: "mine",
  added: "2025-01-01T00:00:00.000Z",
  lastUpdated: "2026-02-03T12:00:00.000Z",
  total: 120,
  releases: 4,
  assets: 9,
  releaseMeta: [{ tag: "v1", published: "2020-01-01T00:00:00Z", downloads: 120 }],
  snapshots: [
    { week: "2026-01-26", total: 80 },
    { at: "2026-02-02T08:00:00.000Z", total: 100 },
  ],
  starSnapshots: [{ at: "2026-02-02T09:00:00.000Z", total: 10 }],
  stars: 12,
  created: "2020-01-01T00:00:00+00:00",
  error: "old error",
};
const migrated = context.parseCache(JSON.stringify(legacy));
assert.equal(migrated.schemaVersion, 3);
assert.deepEqual(
  { ...migrated.current },
  { downloads: 120, stars: 12, releases: 4, assets: 9, observedAt: legacy.lastUpdated },
);
assert.equal(migrated.history.days.some((point) => point.downloads === 80), true);
assert.equal(migrated.history.days.some((point) => point.downloads === 120 && point.stars === 12), true);
assert.equal(Object.hasOwn(migrated, "releaseMeta"), false);
assert.equal(Object.hasOwn(migrated, "snapshots"), false);
assert.equal(migrated.cohorts.years[0].downloads, 120);

const v2WithoutCohorts = context.migrateCache({
  ...context.emptyCache("owner/project", "mine"),
  schemaVersion: 2,
  cohorts: undefined,
  starCohorts: undefined,
  starCohortsUpdatedAt: undefined,
});
assert.deepEqual(Array.from(v2WithoutCohorts.cohorts.days), []);
assert.deepEqual(Array.from(v2WithoutCohorts.starCohorts.days), []);
assert.equal(v2WithoutCohorts.starCohortsUpdatedAt, "");
assert.equal(context.starCohortsStale(v2WithoutCohorts, 7, "2026-09-14T20:00:00Z"), true);
v2WithoutCohorts.starCohortsUpdatedAt = "2026-09-10T20:00:00Z";
assert.equal(context.starCohortsStale(v2WithoutCohorts, 7, "2026-09-14T20:00:00Z"), false);

let bounded = context.emptyCache("owner/project", "mine");
bounded = context.recordObservation(bounded, { downloads: 1, stars: 2, releases: 3, assets: 4 }, "2026-09-13T10:00:00.000Z");
bounded = context.recordObservation(bounded, { downloads: 5, stars: 6, releases: 7, assets: 8 }, "2026-09-13T18:00:00.000Z");
assert.equal(bounded.history.days.length, 1);
assert.equal(bounded.history.days[0].downloads, 5);
assert.equal(bounded.history.weeks[0].bucket, "2026-09-07");
bounded = context.recordObservation(bounded, { downloads: 9, stars: 10, releases: 11, assets: 12 }, "2026-09-14T01:00:00.000Z");
assert.equal(bounded.history.weeks[1].bucket, "2026-09-14");

bounded = context.emptyCache("owner/project", "mine");
for (let i = 0; i < 40; i += 1) {
  const at = new Date(Date.UTC(2023, 0, 1 + i * 32)).toISOString();
  bounded = context.recordObservation(bounded, { downloads: i, stars: i, releases: i, assets: i }, at);
}
assert.equal(bounded.history.days.length, 30);
assert.equal(bounded.history.weeks.length, 8);
assert.equal(bounded.history.months.length, 12);
assert.equal(bounded.history.years.length >= 4, true);

const dailyDomain = context.periodDomain("daily", [], "2026-09-14T12:00:00.000Z");
assert.equal(dailyDomain.slots, 30);
assert.equal((dailyDomain.end - dailyDomain.start) / 86400000, 29);
const weeklyDomain = context.periodDomain("weekly", [], "2026-09-14T12:00:00.000Z");
assert.equal(weeklyDomain.slots, 8);
assert.equal((weeklyDomain.end - weeklyDomain.start) / 86400000, 49);
const monthlyDomain = context.periodDomain("monthly", [], "2026-09-14T12:00:00.000Z");
assert.equal(monthlyDomain.slots, 12);
assert.equal(new Date(monthlyDomain.end).toISOString(), "2026-09-14T00:00:00.000Z");
const annualDomain = context.periodDomain("annual", [Date.UTC(2023, 0, 1)], "2026-09-14T12:00:00.000Z");
assert.equal(annualDomain.slots, 4);
assert.equal(new Date(annualDomain.end).toISOString(), "2026-09-14T00:00:00.000Z");
const midweekDomain = context.periodDomain("weekly", [], "2026-09-16T12:00:00.000Z");
assert.equal(new Date(midweekDomain.end).toISOString(), "2026-09-16T00:00:00.000Z");
assert.equal(context.formatDateShort(Date.UTC(2026, 8, 14), "daily"), "14 Sep 2026");

const beforeFailure = JSON.stringify({ current: bounded.current, history: bounded.history });
bounded = context.recordFailure(bounded, "HTTP error 22", "2026-12-31T00:00:00.000Z");
assert.equal(JSON.stringify({ current: bounded.current, history: bounded.history }), beforeFailure);
assert.equal(bounded.status.lastAttemptAt, "2026-12-31T00:00:00.000Z");
assert.equal(bounded.status.error, "HTTP error 22");

let first = context.emptyCache("owner/project", "mine");
let second = context.emptyCache("other/tool", "others");
for (const [at, a, b] of [
  ["2026-08-03T12:00:00.000Z", 10, 20],
  ["2026-08-10T12:00:00.000Z", 15, 25],
]) {
  first = context.recordObservation(first, { downloads: a, stars: a, releases: 1, assets: 2 }, at);
  second = context.recordObservation(second, { downloads: b, stars: b, releases: 2, assets: 3 }, at);
}
first.starCohorts = helperResult.starCohorts;
first.starCohortsUpdatedAt = helperResult.collectedAt;
second.starCohorts = helperResult.starCohorts;
second.starCohortsUpdatedAt = helperResult.collectedAt;
const store = context.buildStore(config, { "owner/project": first, "other/tool": second });
assert.equal(store.schemaVersion, 3);
assert.equal(store.totals.all, 40);
assert.equal(store.history.weeks.length, 2);
assert.equal(store.history.weeks[1].downloads, 40);
assert.equal(store.history.weeks[1].stars, 40);
assert.equal(store.history.weeks[1].releases, 3);
assert.equal(store.starCohorts.years[0].stars, 10);
const entries = [...store.categories.mine, ...store.categories.others];
const weekly = context.historyTimeline(entries, "dl", "weekly");
assert.deepEqual(Array.from(weekly.totals), [30, 40]);
const daily = context.historyTimeline(entries, "stars", "daily");
assert.deepEqual(Array.from(daily.totals), [30, 40]);
const observedSelected = context.selectedTimeline(entries, "dl", "weekly", "2026-08-10T20:00:00Z");
assert.equal(observedSelected.source, "observed");
assert.deepEqual(Array.from(observedSelected.totals), [30, 40]);
assert.deepEqual(Array.from(context.displayTimeline(observedSelected, false).totals), [0, 10]);
assert.deepEqual(Array.from(context.displayTimeline(observedSelected, true).totals), [30, 40]);
assert.equal(context.selectedTimeline(entries, "stars", "weekly", "2026-08-10T20:00:00Z").source, "observed");

// Staggered observation start: an older repo's earlier years must survive in
// the group annual timeline (a newer repo simply contributes nothing there).
const older = context.emptyCache("older/thing", "mine");
older.history.years = [
  { bucket: "2025", observedAt: "2025-12-31T12:00:00.000Z", downloads: 500, stars: 0, releases: 1, assets: 2 },
  { bucket: "2026", observedAt: "2026-09-14T12:00:00.000Z", downloads: 700, stars: 0, releases: 2, assets: 4 },
];
const newer = context.emptyCache("newer/thing", "others");
newer.history.years = [
  { bucket: "2026", observedAt: "2026-09-14T12:00:00.000Z", downloads: 200, stars: 0, releases: 2, assets: 4 },
];
const staggered = context.selectedTimeline([older, newer], "dl", "annual");
assert.equal(staggered.source, "observed");
assert.deepEqual(Array.from(staggered.buckets), ["2025", "2026"]);
assert.deepEqual(Array.from(staggered.totals), [500, 900]);
assert.deepEqual(Array.from(context.displayTimeline(staggered, false).totals), [0, 400]);

// Cumulative cohort/star-cohort lines run the total along the source
// timeline's own bucket positions, so the cumulative view steps exactly where
// the events view spikes (cumulative[i] - cumulative[i-1] === events[i]).
const anchoredEntry = {
  history: { days: [], weeks: [], months: [], years: [] },
  starCohorts: {
    days: [], weeks: [], months: [], years: [
      { bucket: "2025", stars: 17891 },
      { bucket: "2026", stars: 23215 },
    ],
  },
};
const anchored = context.displayTimeline(
  context.starCohortTimeline([anchoredEntry], "annual", "2026-09-15T02:00:00Z"),
  true);
assert.equal(anchored.source, "star-cohort");
assert.deepEqual(Array.from(anchored.totals), [17891, 41106]);
assert.deepEqual(
  Array.from(anchored.steps, (t) => new Date(t).toISOString().slice(0, 10)),
  ["2025-01-01", "2026-09-15"]);
const anchoredEvents = context.displayTimeline(
  context.starCohortTimeline([anchoredEntry], "annual", "2026-09-15T02:00:00Z"),
  false);
assert.deepEqual(Array.from(anchoredEvents.totals), [17891, 23215]);
assert.equal(context.grouped(16308), "16,308");
assert.equal(context.grouped(0), "0");
assert.equal(context.grouped(999), "999");
assert.equal(context.grouped(1000000), "1,000,000");

console.log("Model tests passed.");
