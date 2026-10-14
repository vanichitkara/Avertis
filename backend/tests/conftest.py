"""Test-wide setup.

The suite must never call the real Gemini API. Three reasons: it costs money
on every run, it is slow enough to stop anyone running the tests (0.3s became
42s the moment a key was present), and it makes results depend on whether a
model happens to be available — so a red suite would no longer mean the code
is broken.

Credentials are therefore cleared before `avertis_backend.main` is imported,
which is when the reasoner is chosen. The Gemini code path is covered
separately in test_gemini_reasoner.py with a stubbed client.
"""

from __future__ import annotations

import os
import pathlib

# Must happen at import time: conftest is loaded before the test modules that
# import the app.
for _var in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "FIRESTORE_PROJECT",
             "AVERTIS_API_KEY"):
    os.environ.pop(_var, None)

# A developer's backend/.env would otherwise put the key straight back.
from avertis_backend import config  # noqa: E402

config.ENV_FILE = pathlib.Path("/nonexistent/.env")
