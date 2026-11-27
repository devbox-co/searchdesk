"""Run with SEARCHDESK_SEO_BRAIN_REPO set to the pinned upstream checkout."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


CLI = Path(__file__).resolve().parents[2] / "bin" / "seo-brain"
TODAY = "2026-11-27"
WEEK = "2026-11-22"
GRID_PATH = "/source_snapshots/8"


class SearchdeskBrainImportTest(unittest.TestCase):
    def run_cli(self, *args, success=True):
        process = subprocess.run([CLI, *args], text=True, capture_output=True)
        self.assertEqual(process.returncode == 0, success, process.stdout + process.stderr)
        return process

    def test_scoped_import_uses_saved_measurements_and_reuses_note_identities(self):
        with tempfile.TemporaryDirectory() as temporary:
            private = Path(temporary)
            vault = private / "fixture"
            self.run_cli("scaffold", "--client", "fixture", "--owner", "Fixture Owner",
                         "--out-dir", temporary, "--as-of", TODAY)
            export = private / "evidence.json"
            bundle = {
                "schema": "searchdesk-seo-evidence-v1",
                "site_host": "coverage.example",
                "site_scope": "1" * 64,
                "generated_at": f"{TODAY}T09:00:00Z",
                "reports": [{
                    "template": "R1", "period_on": WEEK, "status": "complete", "report_path": "/seo_workflows/9",
                    "weekly_performance": {
                        "coverage": "partial",
                        "organic": {"pairs": 2, "counts": {"improved": 1, "declined": 0}},
                        "maps": {"current": {"date": WEEK, "share": 20, "average_rank": 7, "source_path": GRID_PATH}},
                        "reviews": {"current": {"date": WEEK, "new_reviews": 713, "new_one_star": 0}},
                        "next_action": {"text": "Confirm the fixture baseline.", "source_path": GRID_PATH},
                    },
                }],
                "maps_grids": [{
                    "provider": "Local Falcon", "platform": "Google Maps",
                    "reference": "fixture-scan", "keyword": "fixture local service", "observed_on": WEEK,
                    "grid_size": 3, "radius": 2, "unit": "mi", "share_of_local_voice": 20,
                    "average_rank": 7, "source_path": GRID_PATH,
                    "points": [{"lat": 51.2, "lng": -1.1, "rank": 2}, {"lat": 51.3, "lng": -1, "rank": None}],
                }],
            }
            export.write_text(json.dumps(bundle))
            original = export.read_bytes()
            args = ["import-searchdesk", "--file", export, "--vault", vault, "--site-host", "coverage.example",
                    "--searchdesk-url", "http://localhost:3038", "--as-of", TODAY]
            self.run_cli(*args, "--dry-run")
            self.assertFalse((vault / ".vault-meta/searchdesk-site.json").exists())
            self.run_cli(*args)
            self.run_cli(*args)
            report = vault / "wiki/reports" / f"Searchdesk R1 {WEEK}.md"
            grid, = (vault / "wiki/sources").glob("Searchdesk M1 *.md")
            raw, = (vault / ".raw/sources/searchdesk").glob("*.json")
            self.assertEqual(raw.read_bytes(), original)
            self.assertEqual(raw.stem, hashlib.sha256(original).hexdigest())
            self.assertIn("New reviews 713", report.read_text())
            self.assertIn("New one-star reviews 0", report.read_text())
            self.assertIn("Previous week · Unknown", report.read_text())
            self.assertIn("Confirm the fixture baseline.", report.read_text())
            self.assertIn(f"[[{grid.stem}|Current week’s imported grid]]", report.read_text())
            self.assertIn("http://localhost:3038/source_snapshots/8", grid.read_text())
            self.assertIn("Rank Unknown", grid.read_text())

            bundle["generated_at"] = f"{TODAY}T10:00:00Z"
            bundle["reports"][0]["weekly_performance"]["reviews"]["current"]["new_reviews"] = 714
            export.write_text(json.dumps(bundle))
            self.run_cli(*args)
            export.write_bytes(original)
            self.run_cli(*args)
            self.assertIn("New reviews 714", report.read_text())
            self.assertEqual(list((vault / "wiki/reports").glob("Searchdesk R1 *.md")), [report])

            bundle["site_scope"] = "2" * 64
            export.write_text(json.dumps(bundle))
            self.assertIn("different Searchdesk site or workspace", self.run_cli(*args, success=False).stderr)
            del bundle["site_scope"]
            export.write_text(json.dumps(bundle))
            self.assertIn("site-scoped Searchdesk evidence export", self.run_cli(*args, success=False).stderr)
            self.assertEqual(len(list((vault / ".raw/sources/searchdesk").glob("*.json"))), 2)
            self.run_cli("synthesize", "--vault", vault, "--as-of", TODAY)
            self.assertIn("New reviews 714", report.read_text())
            self.run_cli("lint", "--vault", vault)


if __name__ == "__main__":
    unittest.main()
