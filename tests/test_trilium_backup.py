"""Exercise recovery artifacts, including changes still held in SQLite's WAL."""

import importlib.util
import contextlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "trilium_backup",
    Path(__file__).resolve().parents[1] / "modules/services/trilium-backup.py",
)
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


class TriliumBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        config = self.root / "declarative-config.ini"
        config.write_text("[General]\nnoAuthentication=false\n")
        (self.source / "config.ini").symlink_to(config)
        self.database = sqlite3.connect(self.source / "document.db")
        self.addCleanup(self.database.close)
        self.database.executescript("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE options (name TEXT PRIMARY KEY, value TEXT);
            INSERT INTO options VALUES ('initialized', 'true'), ('dbVersion', '250');
            CREATE TABLE notes (noteId TEXT, content TEXT);
            CREATE TABLE revisions (revisionId TEXT, content TEXT);
            CREATE TABLE blobs (blobId TEXT, content BLOB);
            CREATE TABLE attachments (attachmentId TEXT);
            INSERT INTO notes VALUES ('test', 'current content');
            INSERT INTO revisions VALUES ('before-truncation', 'recoverable original');
            INSERT INTO blobs VALUES ('image', X'01020304');
            INSERT INTO attachments VALUES ('image');
        """)
        self.destination = self.root / "backups"

    def create(self):
        return backup.create(self.source, self.destination, "0.106.1")

    def test_wal_revisions_attachments_and_portable_configuration(self):
        self.assertGreater((self.source / "document.db-wal").stat().st_size, 0)
        generation = self.create()
        self.assertFalse((generation / "config.ini").is_symlink())
        metadata = backup.validate(generation)
        self.assertEqual(metadata["database"]["row_counts"]["revisions"], 1)
        with contextlib.closing(sqlite3.connect(generation / "document.db")) as recovered:
            self.assertEqual(recovered.execute("SELECT content FROM revisions").fetchone()[0],
                             "recoverable original")
            self.assertEqual(recovered.execute("SELECT content FROM blobs").fetchone()[0], b"\x01\x02\x03\x04")
        self.database.execute("UPDATE notes SET content = 'later edit'")
        self.database.commit()
        with contextlib.closing(sqlite3.connect(generation / "document.db")) as recovered:
            self.assertEqual(recovered.execute("SELECT content FROM notes").fetchone()[0], "current content")
        self.assertEqual(set(p.name for p in generation.iterdir()),
                         {"document.db", "config.ini", "metadata.json"})

    def test_corruption_and_manifest_mismatch_are_rejected(self):
        generation = self.create()
        database = generation / "document.db"
        with database.open("r+b") as stream:
            stream.write(b"broken header")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            backup.validate(generation)
        metadata_path = generation / "metadata.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["sha256"]["document.db"] = backup.checksum(database)
        metadata_path.write_text(json.dumps(metadata))
        with self.assertRaises(sqlite3.DatabaseError):
            backup.validate(generation)

    def test_uninitialized_database_does_not_publish_a_generation(self):
        self.database.execute("UPDATE options SET value = 'false' WHERE name = 'initialized'")
        self.database.commit()
        with self.assertRaisesRegex(ValueError, "not initialized"):
            self.create()
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_symlink_artifact_is_rejected(self):
        generation = self.create()
        path = generation / "config.ini"
        path.unlink()
        path.symlink_to(self.source / "config.ini")
        with self.assertRaisesRegex(ValueError, "regular backup artifact"):
            backup.validate(generation)


if __name__ == "__main__":
    unittest.main()
