import requests
import pandas as pd
from datetime import datetime, timezone

owner = "SimplifiedLogic"
repo = "creoson"
period = "Y"   # "M" = month, "Q" = quarter, "Y" = year

# 1. Pull all releases (paginated)
releases = []
page = 1
while True:
    resp = requests.get(
        f"https://api.github.com/repos/{owner}/{repo}/releases",
        params={"per_page": 100, "page": page},
        headers={"Accept": "application/vnd.github+json"},
        timeout=30,
    )
    resp.raise_for_status()
    batch = resp.json()
    if not batch:
        break
    releases.extend(batch)
    if len(batch) < 100:
        break
    page += 1

# 2. Flatten into one row per release with its publish date + summed asset downloads
rows = []
for r in releases:
    published = r.get("published_at")
    if not published:
        continue
    dt = datetime.fromisoformat(published.replace("Z", "+00:00"))
    downloads = sum(a.get("download_count", 0) or 0 for a in r.get("assets", []))
    rows.append({"tag": r.get("tag_name"), "published_at": dt, "downloads": downloads})

df = pd.DataFrame(rows).sort_values("published_at")

# 3. Group by chosen period
df["period"] = df["published_at"].dt.to_period(period)
grouped = df.groupby("period", as_index=False)["downloads"].sum()
grouped["cumulative"] = grouped["downloads"].cumsum()

print(grouped.to_string(index=False))
print(f"\nTotal downloads: {df['downloads'].sum():,}")
print(f"Retrieved (UTC): {datetime.now(timezone.utc).isoformat()}")
