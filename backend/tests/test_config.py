"""Loading credentials from backend/.env.

Two properties matter here. A key placed in the file must actually be picked
up — a key that silently does nothing is worse than no key, because the
operator believes Gemini is running. And a real environment variable must win
over the file, so a shell export or a Cloud Run setting is never overridden by
a stale local file.
"""

from __future__ import annotations

import pathlib

import pytest

from avertis_backend import config


@pytest.fixture
def env_file(tmp_path, monkeypatch):
    path = tmp_path / ".env"
    monkeypatch.setattr(config, "ENV_FILE", path)
    for key in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "FIRESTORE_PROJECT",
                "AVERTIS_API_KEY", "GEMINI_MODEL"):
        monkeypatch.delenv(key, raising=False)
    return path


def test_a_key_in_the_file_is_picked_up(env_file):
    env_file.write_text("GEMINI_API_KEY=from-the-file\n")
    settings = config.load_settings()

    assert settings.gemini_api_key == "from-the-file"
    assert settings.gemini_configured


def test_a_real_environment_variable_wins(env_file, monkeypatch):
    env_file.write_text("GEMINI_API_KEY=from-the-file\n")
    monkeypatch.setenv("GEMINI_API_KEY", "from-the-shell")

    # Cloud Run sets real variables; a stale local file must not shadow them.
    assert config.load_settings().gemini_api_key == "from-the-shell"


def test_no_file_is_not_an_error(env_file):
    assert not env_file.exists()
    settings = config.load_settings()

    # The backend must run with nothing configured at all.
    assert settings.gemini_api_key == ""
    assert not settings.gemini_configured


def test_comments_and_blank_lines_are_ignored(env_file):
    env_file.write_text(
        "# a comment\n"
        "\n"
        "GEMINI_API_KEY=real-value\n"
        "   # indented comment\n"
    )
    assert config.load_settings().gemini_api_key == "real-value"


def test_quotes_are_stripped(env_file):
    # People paste keys with quotes around them; a key with a stray quote
    # fails authentication with an unhelpful error.
    env_file.write_text('GEMINI_API_KEY="quoted-value"\n')
    assert config.load_settings().gemini_api_key == "quoted-value"


def test_an_empty_value_counts_as_unset(env_file):
    # The template ships with GEMINI_API_KEY= and no value.
    env_file.write_text("GEMINI_API_KEY=\n")
    assert not config.load_settings().gemini_configured


def test_google_api_key_is_accepted_as_an_alias(env_file):
    env_file.write_text("GOOGLE_API_KEY=alias-value\n")
    assert config.load_settings().gemini_api_key == "alias-value"


def test_the_shipped_template_has_no_real_key():
    """The committed example must never contain a usable credential."""
    template = pathlib.Path(__file__).resolve().parent.parent / ".env.example"
    assert template.exists()
    for line in template.read_text().splitlines():
        if line.startswith("GEMINI_API_KEY="):
            assert line.strip() == "GEMINI_API_KEY=", (
                "the committed template must ship empty"
            )
