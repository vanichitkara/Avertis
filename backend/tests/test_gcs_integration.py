"""GcsMediaStorage against a real Cloud Storage bucket.

Skipped unless AVERTIS_TEST_BUCKET names one, so the default suite stays
hermetic and free:

    AVERTIS_TEST_BUCKET=avertis-media-0373165899 \\
      .venv/bin/python -m pytest tests/test_gcs_integration.py

Why this exists despite test_media_storage.py already stubbing the client:
the stub cannot catch what a real API rejects. The first real upload failed
with "User project specified in the request is invalid" — an ADC quota
project pointing at a deleted project — which no amount of stubbing would
have surfaced.

Each run writes a handful of small objects under a unique prefix and deletes
them afterwards.
"""

from __future__ import annotations

import os
import uuid

import pytest

pytest.importorskip("google.cloud.storage")

BUCKET = os.environ.get("AVERTIS_TEST_BUCKET")
if not BUCKET:
    pytest.skip(
        "set AVERTIS_TEST_BUCKET to run these against real Cloud Storage",
        allow_module_level=True,
    )

from avertis_backend.storage.gcs import GcsMediaStorage  # noqa: E402


@pytest.fixture(scope="module")
def storage() -> GcsMediaStorage:
    return GcsMediaStorage(BUCKET)


@pytest.fixture
def media_id(storage):
    """A unique id per test, removed from the bucket afterwards."""
    identifier = f"test-{uuid.uuid4().hex[:12]}"
    yield identifier
    blob = storage._find(identifier)
    if blob is not None:
        blob.delete()


def test_a_real_round_trip_is_byte_identical(storage, media_id):
    payload = bytes([0xFF, 0xD8, 0xFF, 0xE0]) + b"jpeg-ish evidence" * 50

    stored = storage.save(media_id, payload, content_type="image/jpeg",
                          filename="scene.jpg")

    assert stored.uri == f"gs://{BUCKET}/media/{media_id}.jpg"
    assert stored.bytes == len(payload)

    loaded = storage.load(media_id)
    assert loaded is not None
    assert loaded[0] == payload, "the bytes came back changed"
    assert loaded[1] == "image/jpeg"


def test_an_object_that_was_never_written_is_missing(storage):
    assert storage.load(f"absent-{uuid.uuid4().hex}") is None
    assert storage.exists(f"absent-{uuid.uuid4().hex}") is False


def test_exists_agrees_with_load(storage, media_id):
    assert storage.exists(media_id) is False
    storage.save(media_id, b"x", content_type="image/png")
    assert storage.exists(media_id) is True


def test_overwriting_replaces_the_object(storage, media_id):
    storage.save(media_id, b"first", content_type="text/plain",
                 filename="a.txt")
    storage.save(media_id, b"second", content_type="text/plain",
                 filename="a.txt")

    assert storage.load(media_id)[0] == b"second"


def test_a_hostile_id_stays_inside_the_prefix(storage):
    # The id is sanitised before it becomes an object name, so this lands at
    # media/etcpasswd rather than escaping anywhere.
    stored = storage.save("../../etc/passwd", b"x", content_type="text/plain",
                          filename="p.txt")
    try:
        assert stored.uri.startswith(f"gs://{BUCKET}/media/")
        assert ".." not in stored.uri
    finally:
        blob = storage._find("../../etc/passwd")
        if blob is not None:
            blob.delete()


def test_an_empty_object_round_trips(storage, media_id):
    storage.save(media_id, b"", content_type="image/png")
    loaded = storage.load(media_id)
    assert loaded is not None and loaded[0] == b""


def test_a_larger_object_round_trips(storage, media_id):
    # Roughly a phone photo, to exercise a chunked upload rather than a
    # single small write.
    payload = os.urandom(2 * 1024 * 1024)
    storage.save(media_id, payload, content_type="image/jpeg",
                 filename="big.jpg")

    assert storage.load(media_id)[0] == payload
