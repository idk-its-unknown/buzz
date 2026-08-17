#!/usr/bin/env python3
"""One-time cleanup of phantom-twin persona definitions (2026-08-17).

Before the display-only gate landed in `migration/backfill.rs`, the B5
standalone backfill manufactured a key-less definition (slug = agent pubkey)
for every display-only fleet record and linked the record to it
(`persona_id` = own pubkey). This script removes that pollution:

  1. drops every key-less definition row in `managed-agents.json` whose slug
     is the 64-hex pubkey of a display-only record (the twins);
  2. nulls `persona_id` + `persona_source_version` on those display-only
     records;
  3. deletes the twins' retained kind:30175 rows from every scoped retention
     database (`agents/retention/*.db`) — a row left `pending_sync=1` there
     would be republished to the relay by the flush loop on next launch.

Safety rails (same contract as the in-app migrations):
  - refuses to run while buzz-desktop is running (the app rewrites the store);
  - pre-cleanup backups (store copy + per-DB copy), create-if-absent — a
    re-run never clobbers the pristine backups;
  - idempotent — a second run finds nothing to do and says so;
  - atomic store write (tmp + fsync + replace) and post-write verification:
    the rewritten file is re-read and re-scanned; any surviving twin or link
    is a hard failure with the original restored.

Run ONLY with the patched desktop build deployed (the un-gated backfill in an
old exe would re-manufacture the twins on next boot; the relay may also
re-deliver old twin events, which the patched inbound gate drops).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

AGENTS_DIR = Path(os.environ["APPDATA"]) / "xyz.block.buzz.app" / "agents"
STORE = AGENTS_DIR / "managed-agents.json"
RETENTION_DIR = AGENTS_DIR / "retention"
KIND_PERSONA = 30175
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def buzz_running() -> bool:
    out = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq buzz-desktop.exe", "/NH"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    return "buzz-desktop.exe" in out


def scan(records: list[dict]) -> tuple[list[int], list[int]]:
    """Return (twin definition indexes, linked display-only record indexes)."""
    display_only_pubkeys = display_only_pubkeys_of(records)
    twin_rows = [
        i
        for i, r in enumerate(records)
        if not r.get("pubkey") and (r.get("slug") or "") in display_only_pubkeys
    ]
    linked_rows = [
        i
        for i, r in enumerate(records)
        if r.get("display_only") and r.get("persona_id") is not None
    ]
    return twin_rows, linked_rows


def display_only_pubkeys_of(records: list[dict]) -> set[str]:
    return {
        r.get("pubkey")
        for r in records
        if r.get("display_only") and HEX64.match(r.get("pubkey") or "")
    }


def backup_once(src: Path, tag: str) -> None:
    backup = src.with_name(f"{src.name}.bak-{tag}-{date.today():%Y%m%d}")
    if not backup.exists():
        shutil.copy2(src, backup)
        print(f"backup: {backup.name}")
    else:
        print(f"backup already present (kept pristine): {backup.name}")


def clean_store() -> set[str]:
    """Rewrite managed-agents.json; return the display-only pubkey set."""
    original = STORE.read_text(encoding="utf-8")
    records = json.loads(original)
    pubkeys = display_only_pubkeys_of(records)
    twin_rows, linked_rows = scan(records)

    if not twin_rows and not linked_rows:
        print("store: already clean - no twin definitions, no linked display-only records.")
        return pubkeys

    backup_once(STORE, "phantom-twins")

    twin_set = set(twin_rows)
    cleaned = [r for i, r in enumerate(records) if i not in twin_set]
    for r in cleaned:
        if r.get("display_only") and r.get("persona_id") is not None:
            r["persona_id"] = None
            r["persona_source_version"] = None

    payload = json.dumps(cleaned, indent=2, ensure_ascii=False) + "\n"
    fd, tmp_name = tempfile.mkstemp(dir=STORE.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(payload)
            fh.flush()
            # The app's own writer fsyncs before rename (atomic_write_file);
            # match it so a crash can't complete the rename with unflushed data.
            os.fsync(fh.fileno())
        os.replace(tmp_name, STORE)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise

    # Verify at the write boundary. Explicit raises, NOT assert — assert is
    # stripped under `python -O`, which would silently disarm this contract.
    try:
        reread = json.loads(STORE.read_text(encoding="utf-8"))
        left_twins, left_links = scan(reread)
        if left_twins or left_links:
            raise RuntimeError(
                f"pollution survived the rewrite ({len(left_twins)} twins, {len(left_links)} links)"
            )
        if len(reread) != len(records) - len(twin_rows):
            raise RuntimeError(
                f"row count mismatch: expected {len(records) - len(twin_rows)}, got {len(reread)}"
            )
    except Exception as err:
        STORE.write_text(original, encoding="utf-8", newline="\n")
        raise SystemExit(f"FAIL: post-write verification failed ({err}); original restored.")

    print(
        f"store: removed {len(twin_rows)} twin definitions, "
        f"unlinked {len(linked_rows)} display-only records "
        f"({len(records)} -> {len(reread)} rows)."
    )
    return pubkeys


def clean_retention(pubkeys: set[str]) -> None:
    """Delete retained twin kind:30175 rows from every scoped retention DB."""
    if not pubkeys:
        print("retention: no display-only pubkeys - nothing to check.")
        return
    dbs = sorted(RETENTION_DIR.glob("*.db")) if RETENTION_DIR.exists() else []
    if not dbs:
        print("retention: no databases found.")
        return
    placeholders = ",".join("?" for _ in pubkeys)
    params = [KIND_PERSONA, *sorted(pubkeys)]
    for db in dbs:
        conn = sqlite3.connect(db)
        try:
            (count,) = conn.execute(
                f"SELECT COUNT(*) FROM persona_events WHERE kind=? AND d_tag IN ({placeholders})",
                params,
            ).fetchone()
            if count == 0:
                print(f"retention {db.name}: already clean.")
                continue
            backup_once(db, "phantom-twins")
            conn.execute(
                f"DELETE FROM persona_events WHERE kind=? AND d_tag IN ({placeholders})",
                params,
            )
            conn.commit()
            (left,) = conn.execute(
                f"SELECT COUNT(*) FROM persona_events WHERE kind=? AND d_tag IN ({placeholders})",
                params,
            ).fetchone()
            if left != 0:
                raise SystemExit(f"FAIL: retention {db.name}: {left} twin rows survived the delete.")
            print(f"retention {db.name}: deleted {count} twin rows.")
        except sqlite3.OperationalError as err:
            raise SystemExit(f"FAIL: retention {db.name}: {err}")
        finally:
            conn.close()


def main() -> int:
    if buzz_running():
        print("FAIL: buzz-desktop is running - close it first (Stop-Process -Name buzz-desktop).")
        return 1
    if not STORE.exists():
        print(f"FAIL: store not found: {STORE}")
        return 1

    pubkeys = clean_store()
    clean_retention(pubkeys)
    print("OK: cleanup complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
