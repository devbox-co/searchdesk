"""Command-line adapter for the Searchdesk evidence importer."""

import argparse
from pathlib import Path
import sys

sys.path.insert(0, sys.argv.pop(1))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib" / "seo_brain"))
from runtime import require_source
from searchdesk_import import import_bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ("vault", "file", "site-host", "searchdesk-url", "as-of"):
        parser.add_argument(f"--{field}", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        reports, grids = import_bundle(
            vault_path=args.vault, data=require_source(args.file, suffixes={".json"}).read_bytes(),
            site_host=args.site_host, searchdesk_url=args.searchdesk_url, as_of=args.as_of, dry_run=args.dry_run,
        )
    except (AttributeError, KeyError, OSError, TypeError, ValueError) as error:
        parser.exit(2, f"ERROR: {error}\n")
    action = "Would import" if args.dry_run else "Imported"
    print(f"{action} {reports} R1 reports and {grids} M1 grids.")


if __name__ == "__main__":
    main()
