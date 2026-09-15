import requests
from datetime import datetime, timezone

owner = "SimplifiedLogic"
repo = "creoson"

releases = []
page = 1

# Retrieve every release page (100 releases per page).
while True:
    response = requests.get(
        f"https://api.github.com/repos/{owner}/{repo}/releases",
        params={"per_page": 100, "page": page},
        headers={"Accept": "application/vnd.github+json"},
        timeout=30,
    )
    response.raise_for_status()

    batch = response.json()
    if not batch:
        break

    releases.extend(batch)

    if len(batch) < 100:
        break

    page += 1

total_downloads = sum(
    asset.get("download_count", 0) or 0
    for release in releases
    for asset in release.get("assets", [])
)

asset_count = sum(
    len(release.get("assets", []))
    for release in releases
)

print(f"Total release-asset downloads: {total_downloads:,}")
print(f"Releases: {len(releases):,}")
print(f"Assets: {asset_count:,}")
print(f"Retrieved (UTC): {datetime.now(timezone.utc).isoformat()}")
