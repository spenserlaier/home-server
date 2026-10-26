"""Create and validate portable, consistent Trilium SQLite backup generations."""

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
import time


TABLES = ("notes", "revisions", "blobs", "attachments", "options")
GENERATION = re.compile(r"trilium-\d{8}T\d{12}Z")


def connect_readonly(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected a regular database file: {path}")
    return sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=30)


def inspect_database(path):
    with contextlib.closing(connect_readonly(path)) as database:
        if database.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ValueError("SQLite integrity check failed")
        counts = {
            table: database.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            for table in TABLES
        }
        options = dict(database.execute(
            "SELECT name, value FROM options WHERE name IN ('dbVersion', 'initialized')"
        ))
        if options.get("initialized") != "true" or not str(options.get("dbVersion", "")).isdigit():
            raise ValueError("Trilium database is not initialized or has no schema version")
        return {"schema_version": int(options["dbVersion"]), "row_counts": counts}


def checksum(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Backup must be a regular directory")
    for name in ("document.db", "config.ini", "metadata.json"):
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Missing regular backup artifact: {name}")
    metadata = json.loads((directory / "metadata.json").read_text())
    if metadata.get("format_version") != 1 or metadata.get("service") != "trilium":
        raise ValueError("Unrecognized Trilium backup format")
    if not re.fullmatch(r"\d+\.\d+\.\d+", metadata.get("application_version", "")):
        raise ValueError("Missing application version")
    for name in ("document.db", "config.ini"):
        if metadata.get("sha256", {}).get(name) != checksum(directory / name):
            raise ValueError(f"Checksum mismatch: {name}")
    if metadata.get("database") != inspect_database(directory / "document.db"):
        raise ValueError("Database schema or row counts do not match the manifest")
    return metadata


def create(source, destination, version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected a pinned application version")
    # Native module config.ini is a Nix-store symlink; copy its contents so the
    # artifact does not rely on the old store surviving disaster recovery.
    config = source / "config.ini"
    if not config.is_file():
        raise ValueError("Trilium configuration is missing")
    destination.mkdir(parents=True, exist_ok=True)
    now = dt.datetime.now(dt.timezone.utc)
    final = destination / now.strftime("trilium-%Y%m%dT%H%M%S%fZ")
    with tempfile.TemporaryDirectory(prefix=".incomplete-", dir=destination) as temporary:
        work = Path(temporary)
        deadline = time.monotonic() + 120

        def progress(_status, _remaining, _total):
            if time.monotonic() > deadline:
                raise TimeoutError("SQLite backup exceeded two minutes")

        with contextlib.closing(connect_readonly(source / "document.db")) as original:
            with contextlib.closing(sqlite3.connect(work / "document.db")) as backup:
                original.backup(backup, pages=1024, progress=progress, sleep=0.1)
                # Publish a standalone database. Even read-only inspection of a
                # WAL-mode backup can otherwise leave -wal/-shm sidecars behind.
                backup.execute("PRAGMA journal_mode=DELETE")
        shutil.copyfile(config, work / "config.ini")
        metadata = {
            "format_version": 1,
            "service": "trilium",
            "application_version": version,
            "created_at": now.isoformat(),
            "database": inspect_database(work / "document.db"),
            "sha256": {name: checksum(work / name) for name in ("document.db", "config.ini")},
        }
        (work / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        for path in work.iterdir():
            path.chmod(0o600)
        validate(work)
        # Flush the artifacts before atomically publishing the generation.
        for path in work.iterdir():
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
        work.rename(final)
        # TemporaryDirectory sees the old path as absent after the rename.
    for path in destination.iterdir():
        if (GENERATION.fullmatch(path.name) and path != final and not path.is_symlink()
                and path.is_dir() and now.timestamp() - path.stat().st_mtime > 7 * 86400):
            shutil.rmtree(path)
    return final


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    backup = subparsers.add_parser("create")
    backup.add_argument("source", type=Path)
    backup.add_argument("destination", type=Path)
    backup.add_argument("version")
    check = subparsers.add_parser("validate")
    check.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "create":
            print(f"Created validated Trilium backup: {create(args.source, args.destination, args.version)}")
        else:
            metadata = validate(args.directory)
            print(f"Validated Trilium {metadata['application_version']} backup: {args.directory}")
    except (OSError, ValueError, sqlite3.Error, TimeoutError) as error:
        parser.exit(1, f"Trilium backup failed: {error}\n")


if __name__ == "__main__":
    main()
