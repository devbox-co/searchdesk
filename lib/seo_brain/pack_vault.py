"""Prepare and package a Local SEO Brain vault for a Searchdesk download."""

from pathlib import Path
import subprocess
import sys
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile

UPSTREAM = Path(sys.argv[1])
sys.path.insert(0, str(UPSTREAM / "scripts"))
from searchdesk_import import import_bundle, NoStructuredEvidence


def pack_vault(upstream, evidence, site_host, searchdesk_url, as_of, output):
    with tempfile.TemporaryDirectory(prefix="searchdesk-vault-") as temporary:
        subprocess.run(
            [sys.executable, "-E", "-s", "-B", str(upstream / "scripts" / "scaffold_vault.py"),
             "--client", "searchdesk-vault", "--owner", "Workspace owner",
             "--out-dir", temporary, "--as-of", as_of],
            stdout=subprocess.DEVNULL, check=True,
        )
        vault = Path(temporary) / "searchdesk-vault"
        import_bundle(vault_path=vault, data=evidence, site_host=site_host, searchdesk_url=searchdesk_url, as_of=as_of)

        with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
            for path in sorted(vault.rglob("*")):
                if path.is_file() and path.name != "ingest.lock":
                    archive.write(path, path.relative_to(vault.parent))
            for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
                archive.write(upstream / name, vault.name + "/" + name)


if __name__ == "__main__":
    try:
        pack_vault(UPSTREAM, sys.stdin.buffer.read(), *sys.argv[2:], sys.stdout.buffer)
    except NoStructuredEvidence:
        sys.exit(3)
