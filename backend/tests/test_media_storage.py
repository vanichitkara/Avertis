"""Where media bytes live.

Two things are being protected here. Evidence should not silently vanish,
and when it does vanish the system should say so rather than imply the photo
is still there. And a media id arrives over the network, so it does not get
to choose a filesystem path.
"""

from __future__ import annotations

import pathlib

import pytest

from avertis_backend.storage.base import StoredMedia
from avertis_backend.storage.local import LocalMediaStorage, _safe, _suffix


@pytest.fixture
def storage(tmp_path) -> LocalMediaStorage:
    return LocalMediaStorage(str(tmp_path / "media"))


class TestLocalStorage:
    def test_a_file_round_trips(self, storage):
        stored = storage.save("med-1", b"jpeg bytes",
                              content_type="image/jpeg", filename="a.jpg")

        assert isinstance(stored, StoredMedia)
        assert stored.bytes == 10
        payload, content_type = storage.load("med-1")
        assert payload == b"jpeg bytes"
        assert content_type == "image/jpeg"

    def test_a_missing_object_is_none_not_an_error(self, storage):
        # Local disk gets cleared; a bucket object can be deleted. Missing is
        # a normal outcome the caller has to handle.
        assert storage.load("never-saved") is None
        assert storage.exists("never-saved") is False

    def test_the_directory_is_created_on_demand(self, tmp_path):
        storage = LocalMediaStorage(str(tmp_path / "deep" / "nested"))
        storage.save("med-1", b"x", content_type="image/png")
        assert storage.exists("med-1")

    def test_saving_twice_replaces_rather_than_accumulates(self, storage):
        storage.save("med-1", b"first", content_type="image/jpeg",
                     filename="a.jpg")
        storage.save("med-1", b"second", content_type="image/jpeg",
                     filename="a.jpg")

        payload, _ = storage.load("med-1")
        assert payload == b"second"

    def test_local_storage_admits_it_is_not_durable(self, storage):
        # On Cloud Run this disk is per-instance and discarded on restart.
        # The API reports this so nobody believes evidence is safe.
        assert storage.durable is False

    def test_an_empty_file_is_still_stored(self, storage):
        storage.save("med-empty", b"", content_type="image/jpeg")
        payload, _ = storage.load("med-empty")
        assert payload == b""


class TestIdSanitising:
    @pytest.mark.parametrize("hostile,expected", [
        ("../../etc/passwd", "etcpasswd"),
        ("med-1", "med-1"),
        ("med_1", "med_1"),
        ("/absolute", "absolute"),
        ("a/../../b", "ab"),
    ])
    def test_a_media_id_cannot_choose_a_path(self, hostile, expected):
        # Media ids arrive over the network. Without this, an id of
        # "../../etc/passwd" writes outside the media directory.
        assert _safe(hostile) == expected

    def test_a_hostile_id_writes_inside_the_directory(self, tmp_path):
        root = tmp_path / "media"
        storage = LocalMediaStorage(str(root))
        stored = storage.save("../../escape", b"x", content_type="image/png")

        assert pathlib.Path(stored.uri).resolve().is_relative_to(
            root.resolve()
        )

    def test_a_very_long_id_is_truncated(self):
        assert len(_safe("a" * 500)) == 128


class TestSuffix:
    @pytest.mark.parametrize("content_type,filename,expected", [
        ("image/jpeg", "photo.jpg", ".jpg"),
        ("image/png", None, ".png"),
        ("audio/mp4", None, ".m4a"),
        (None, None, ".bin"),
        (None, "clip.m4a", ".m4a"),
    ])
    def test_a_sensible_extension_is_chosen(self, content_type, filename,
                                            expected):
        assert _suffix(content_type, filename) == expected

    def test_an_absurd_filename_extension_is_bounded(self):
        assert len(_suffix(None, "x." + "y" * 400)) <= 10


class TestGcsStorage:
    """The Cloud Storage path, with the client stubbed.

    This has never run against real Cloud Storage — see docs/deployment.md.
    What is tested is the part that is ours: object naming, the gs:// URI,
    and that a storage outage degrades to "missing" rather than a 500.
    """

    def _storage(self, *, blobs=None, raises=None):
        from avertis_backend.storage.gcs import GcsMediaStorage

        class StubBlob:
            def __init__(self, name, data=b"", content_type=None):
                self.name = name
                self._data = data
                self.content_type = content_type
                self.uploaded = None

            def upload_from_string(self, payload, content_type=None):
                self.uploaded = (payload, content_type)
                self._data = payload
                self.content_type = content_type

            def download_as_bytes(self):
                return self._data

        class StubBucket:
            def __init__(self):
                self.created: dict[str, StubBlob] = {}

            def blob(self, name):
                blob = StubBlob(name)
                self.created[name] = blob
                return blob

        class StubClient:
            def __init__(self, bucket):
                self._bucket = bucket

            def bucket(self, name):
                return self._bucket

            def list_blobs(self, bucket, prefix=None, max_results=None):
                if raises:
                    raise raises
                return list(blobs or [])

        instance = GcsMediaStorage.__new__(GcsMediaStorage)
        bucket = StubBucket()
        instance._bucket = bucket
        instance._client = StubClient(bucket)
        instance.bucket_name = "avertis-media"
        instance.name = "gcs:avertis-media"
        return instance, bucket, StubBlob

    def test_an_object_is_named_under_the_media_prefix(self):
        storage, bucket, _ = self._storage()
        stored = storage.save("med-1", b"bytes", content_type="image/jpeg",
                              filename="a.jpg")

        assert "media/med-1.jpg" in bucket.created
        assert stored.uri == "gs://avertis-media/media/med-1.jpg"
        assert stored.bytes == 5

    def test_the_content_type_is_sent_to_the_bucket(self):
        storage, bucket, _ = self._storage()
        storage.save("med-1", b"x", content_type="image/png")

        blob = bucket.created["media/med-1.png"]
        assert blob.uploaded[1] == "image/png"

    def test_a_hostile_id_cannot_escape_the_prefix(self):
        storage, bucket, _ = self._storage()
        storage.save("../../secret", b"x", content_type="image/png")
        assert all(n.startswith("media/") for n in bucket.created)

    def test_a_stored_object_reads_back(self):
        storage, _, StubBlob = self._storage()
        storage, _, _ = self._storage(
            blobs=[StubBlob("media/med-1.jpg", b"evidence", "image/jpeg")]
        )
        assert storage.load("med-1") == (b"evidence", "image/jpeg")

    def test_a_missing_object_is_none(self):
        storage, _, _ = self._storage(blobs=[])
        assert storage.load("med-1") is None
        assert storage.exists("med-1") is False

    def test_a_storage_outage_degrades_to_missing(self):
        storage, _, _ = self._storage(raises=RuntimeError("503 backend error"))

        # A bucket outage must not become a 500 from the incident API.
        assert storage.load("med-1") is None
        assert storage.exists("med-1") is False

    def test_gcs_claims_durability(self):
        storage, _, _ = self._storage()
        assert storage.durable is True
