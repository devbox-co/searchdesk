"""Project a private Searchdesk export into evidence-linked Local SEO Brain notes."""

from datetime import date, datetime, timezone
import hashlib
import html
import json
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit

from runtime import (
    install_immutable_raw, json_text, parse_as_of, reject_symlink_components,
    require_vault, update_raw_manifest, vault_mutation, write_text,
)

SCHEMA = "searchdesk-seo-evidence-v1"
DIGEST = re.compile(r"[a-f0-9]{64}")
HOST = re.compile(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")
SOURCE_PATH = re.compile(
    r"/(?:seo_workflows/(?:[1-9]\d*|competitor_capture/[1-9]\d*|setup(?:#M2)?)"
    r"|source_snapshots/[1-9]\d*|keywords/[1-9]\d*(?:\?device=(?:desktop|mobile))?"
    r"|rankings\?(?:source=local&day=\d{4}-\d{2}-\d{2}|day=\d{4}-\d{2}-\d{2}&source=local)"
    r"|local_falcon_connection(?:#maps-scans)?)"
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def text(value):
    if value is None or value == "":
        return "Unknown"
    if not isinstance(value, (str, int, float)) or isinstance(value, bool):
        raise ValueError("invalid measurement or text")
    # Keep data inside the generated prose and out of Obsidian links or markup.
    return html.escape(" ".join(str(value).split())).replace("[", "&#91;").replace("]", "&#93;").replace("`", "&#96;")


def link(origin, path, label="Searchdesk evidence"):
    if isinstance(path, str) and SOURCE_PATH.fullmatch(path):
        return f"[{label}]({origin}{path})"
    return "Source link unavailable"


def readings(lines, origin, title, section, metrics):
    lines.extend(("", f"## {title}"))
    for field in ("keyword", "market", "device"):
        if field in section:
            lines.append(f"- {field.title()} · {text(section[field])}")
    for key, label in (("current", "Current week"), ("previous", "Previous week")):
        reading = section.get(key)
        if reading is None:
            lines.append(f"- {label} · Unknown")
            continue
        measures = " · ".join(f"{name} {text(reading.get(field))}" for field, name in metrics)
        lines.append(f"- {label} · {text(reading.get('date'))} · {measures} · {link(origin, reading.get('source_path'))}")


def weekly(entry, origin, grid_links):
    report = entry["weekly_performance"]
    organic = report.get("organic", {})
    counts = organic.get("counts", {})
    action = report.get("next_action", {})
    lines = [
        f"- Reporting week · {text(report.get('start'))} to {text(report.get('end'))}",
        f"- Comparison week · {text(report.get('previous_start'))} to {text(report.get('previous_end'))}",
        f"- Coverage · {text(report.get('coverage'))}",
        f"- Searchdesk status · {text(entry['status'])}",
        f"- {link(origin, entry.get('report_path'), 'Open weekly report in Searchdesk')}",
        "", text(report.get("status")), "", "## Organic rankings",
        f"- Comparable keyword and device pairs · {text(organic.get('pairs'))}",
    ]
    for direction in ("improved", "declined", "steady", "outside"):
        lines.append(f"- {direction.title()} · {text(counts.get(direction))}")
    for change in organic.get("changes", []):
        before, after = change["previous"], change["current"]
        previous = "Outside tracked results" if before.get("status") == "outside" else text(before.get("position"))
        current = "Outside tracked results" if after.get("status") == "outside" else text(after.get("position"))
        lines.append(f"- {text(change.get('term'))} · {text(change.get('device'))} · "
                     f"{previous} ({text(before.get('date'))}) → {current} ({text(after.get('date'))}) · "
                     f"{link(origin, change.get('source_path'))}")

    maps = report.get("maps", {})
    readings(lines, origin, "Maps grids", maps, (("share", "SoLV (%)"), ("average_rank", "Average rank")))
    for key in ("current", "previous"):
        if grid_note := grid_links.get(maps.get(key, {}).get("source_path")):
            lines.append(f"- [[{grid_note}|{key.title()} week’s imported grid]]")
    readings(lines, origin, "Local pack", report.get("local_pack", {}),
             (("position", "Top-three position"), ("rating", "Rating")))
    readings(lines, origin, "Google review activity", report.get("reviews", {}),
             (("new_reviews", "New reviews"), ("average_rating", "Average rating"),
              ("unanswered_low_rating", "Unanswered low ratings"), ("new_one_star", "New one-star reviews")))
    lines.extend(("", "## Finding", text(report.get("finding")), "", "## Next action",
                  f"- {text(action.get('text'))} · {link(origin, action.get('source_path'))}"))
    return "\n".join(lines)


def geogrid(grid, origin):
    points = grid["points"]
    if not isinstance(points, list) or not points:
        raise ValueError("a Maps scan must include its saved grid points")
    lines = [
        f"- Search term · {text(grid['keyword'])}",
        f"- Collected on · {text(grid['observed_on'])}",
        f"- Provider reference · {text(grid['reference'])}",
        f"- Grid size · {text(grid.get('grid_size'))}",
        f"- Radius · {text(grid.get('radius'))} {text(grid.get('unit'))}",
        f"- Share of local voice (%) · {text(grid.get('share_of_local_voice'))}",
        f"- Average rank · {text(grid.get('average_rank'))}",
        f"- {link(origin, grid.get('source_path'), 'Open saved grid in Searchdesk')}",
        "", "## Saved grid points",
    ]
    for point in points:
        lines.append(f"- {text(point['lat'])}, {text(point['lng'])} · Rank {text(point.get('rank'))}")
    return "\n".join(lines)


def note(kind, title, observed_on, today, generated, body, source):
    return f"""---
type: "{kind}"
title: "{title}"
created: "{observed_on}"
updated: "{today}"
status: "draft"
tags: ["type/{kind}", "domain/local-seo", "provenance/searchdesk"]
searchdesk_generated_at: "{generated}"
---

# {title}

{body}

## Provenance

- [[{source}]]
"""


def add_hub_links(vault, writes, directory, names):
    hub = vault / "wiki" / directory / "_index.md"
    reject_symlink_components(vault, hub)
    contents = hub.read_text(encoding="utf-8")
    added = [f"- [[{name}]]" for name in sorted(names) if f"[[{name}]]" not in contents]
    if added:
        heading = "\n## Searchdesk imports\n"
        separator = "\n" if heading in contents else "\n" + heading
        writes[hub] = contents.rstrip() + separator + "\n".join(added)


class NoStructuredEvidence(ValueError):
    pass


def import_bundle(*, vault_path, data, site_host, searchdesk_url, as_of, dry_run=False):
    origin = urlsplit(searchdesk_url)
    if (origin.scheme not in ("http", "https") or not origin.hostname or origin.username is not None
            or origin.path not in ("", "/") or origin.query or origin.fragment
            or not re.fullmatch(r"[a-zA-Z0-9.\-\[\]:]+", origin.netloc)):
        raise ValueError("--searchdesk-url must be a Searchdesk origin")
    origin = origin.geturl().rstrip("/")
    today = parse_as_of(as_of)
    vault = require_vault(str(vault_path))
    bundle = json.loads(data)
    scope = bundle.get("site_scope")
    if bundle.get("schema") != SCHEMA or not isinstance(scope, str) or not DIGEST.fullmatch(scope):
        raise ValueError("download a fresh, site-scoped Searchdesk evidence export")
    if not HOST.fullmatch(site_host) or bundle.get("site_host") != site_host:
        raise ValueError("export host does not match --site-host")
    timestamp = datetime.fromisoformat(bundle["generated_at"])
    if timestamp.utcoffset() is None:
        raise ValueError("export timestamp must include a time zone")
    generated = timestamp.astimezone(timezone.utc).isoformat(timespec="microseconds")
    raw_hash = digest(data)
    source = "Searchdesk export " + raw_hash
    raw = vault / ".raw" / "sources" / "searchdesk" / f"{raw_hash}.json"
    binding = vault / ".vault-meta" / "searchdesk-site.json"
    identity = {"site_host": site_host, "site_scope": scope}

    with vault_mutation(vault, dry_run=dry_run):
        reject_symlink_components(vault, binding)
        if binding.exists() and json.loads(binding.read_text(encoding="utf-8")) != identity:
            raise ValueError("vault is bound to a different Searchdesk site or workspace")
        names = {"reports": {}, "sources": {}}
        grid_links = {}
        for grid in bundle["maps_grids"]:
            if (grid["provider"], grid["platform"]) != ("Local Falcon", "Google Maps"):
                raise ValueError("unsupported Maps grid provider or platform")
            observed = date.fromisoformat(grid["observed_on"]).isoformat()
            name = f"Searchdesk M1 {observed} {digest(grid['reference'].encode())[:16]}"
            if name in names["sources"]:
                raise ValueError("duplicate Maps scan identity")
            names["sources"][name] = (observed, geogrid(grid, origin))
            grid_links[grid.get("source_path")] = name
        for entry in bundle["reports"]:
            if entry["template"] != "R1" or "weekly_performance" not in entry:
                continue
            if entry["status"] not in ("complete", "approved", "delivered"):
                raise ValueError("unsupported R1 report status")
            observed = date.fromisoformat(entry["period_on"]).isoformat()
            name = f"Searchdesk R1 {observed}"
            if name in names["reports"]:
                raise ValueError("duplicate weekly report date")
            names["reports"][name] = (observed, weekly(entry, origin, grid_links))
        if not any(names.values()):
            raise NoStructuredEvidence("export contains no structured R1 reports or M1 grids; refresh older R1 reports in Searchdesk before exporting")

        writes = {}
        for folder, entries in names.items():
            for name, (observed, body) in entries.items():
                target = vault / "wiki" / folder / f"{name}.md"
                reject_symlink_components(vault, target)
                if target.exists():
                    existing = re.search(r'^searchdesk_generated_at: "([^"]+)"$', target.read_text(encoding="utf-8"), re.M)
                    if not existing:
                        raise ValueError("generated filename conflicts with an existing note")
                    if existing.group(1) >= generated:
                        continue
                kind = "report" if folder == "reports" else "source"
                writes[target] = note(kind, name, observed, today, generated, body, source)
        raw_note = vault / "wiki" / "sources" / f"{source}.md"
        provenance = (f"- Site · {text(site_host)}\n- Exported at · {generated}\n"
                      f"- Raw file · `{raw.relative_to(vault)}`\n- SHA-256 · `{raw_hash}`")
        writes[raw_note] = note("source", source, timestamp.date().isoformat(), timestamp.date().isoformat(),
                                generated, provenance, "wiki/sources/_index|Sources Hub")
        for folder, entries in names.items():
            add_hub_links(vault, writes, folder, list(entries) + ([source] if folder == "sources" else []))
        for target in [raw, *writes]:
            reject_symlink_components(vault, target)
        if not dry_run:
            write_text(binding, json_text(identity))
            with tempfile.TemporaryDirectory(prefix="searchdesk-evidence-") as private:
                copy = Path(private) / "evidence.json"
                copy.write_bytes(data)
                install_immutable_raw(copy, raw, raw_hash)
            update_raw_manifest(vault, raw_path=raw, digest=raw_hash, kind="searchdesk",
                                as_of=timestamp.date().isoformat(), client=site_host)
            for target, contents in writes.items():
                write_text(target, contents)
        return len(names["reports"]), len(names["sources"])
