"""Render Local SEO Brain's actionable records with their pinned evidence references."""

import json
import sys
from collections import Counter
from pathlib import Path


def records(path, field):
    return {record["id"]: record for record in json.loads(path.read_text())[field]}


def main():
    root, result_path = map(Path, sys.argv[1:])
    result = json.loads(result_path.read_text())
    sources = records(root / "references/source-ledger.json", "sources")
    claims = records(root / "references/claim-ledger.json", "claims")
    queue = sorted(result["actionable"], key=lambda row: (
        row["refresh_due"] or "", row["kind"], row["id"]
    ))
    counts = Counter(row["kind"] for row in queue)

    print(f'# Evidence refresh queue for {result["as_of"]}')
    print(f'\nPinned ledger date {result["snapshot_as_of"]}. {len(queue)} actionable records.')
    for kind, count in sorted(counts.items()):
        print(f"- {kind}: {count}")
    print()

    for row in queue:
        kind, record_id = row["kind"], row["id"]
        print(f'- [{kind}] {record_id} — {row["state"]}, due {row["refresh_due"] or "unspecified"}')
        if kind == "source":
            record = sources[record_id]
            print(f'  - {record["title"]} — {record["url"]}')
        elif kind == "claim":
            record = claims[record_id]
            print(f'  - {record["statement"]}')
            for source_id in dict.fromkeys(record["source_ids"] + record["contradicting_source_ids"]):
                source = sources[source_id]
                print(f'  - {source_id} — {source["url"]}')


if __name__ == "__main__":
    main()
