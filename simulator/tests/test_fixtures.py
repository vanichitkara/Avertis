"""Conformance against docs/fixtures — the shared contract with the Dart engine.

If these fail, the phone and the simulator have drifted apart and packets from
one will not be understood by the other.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from avertis_sim.protocol import Packet, canonical_json, payload_hash

FIXTURES = json.loads(
    (Path(__file__).parent.parent.parent / "docs" / "fixtures"
     / "protocol_fixtures.json").read_text(encoding="utf-8")
)


@pytest.mark.parametrize("case", FIXTURES["payload_hashes"])
def test_canonical_json_and_hash(case):
    assert canonical_json(case["payload"]).decode() == case["canonical_json"]
    assert payload_hash(case["payload"]) == case["payload_hash"]


@pytest.mark.parametrize("case", FIXTURES["packets"])
def test_packet_encoding_roundtrips(case):
    packet = Packet.from_json(case["created"])
    assert packet.to_json() == case["created"]
    assert packet.encode().decode() == case["encoded"]
    assert Packet.decode(packet.encode()) == packet


@pytest.mark.parametrize("case", FIXTURES["packets"])
def test_forwarding_matches_fixture(case):
    packet = Packet.from_json(case["created"])
    hopped = packet.forwarded_by("node-12").forwarded_by("node-31")
    assert hopped.to_json() == case["after_two_hops"]


@pytest.mark.parametrize("case", FIXTURES["relay_scores"])
def test_relay_score_matches_fixture(case):
    i = case["inputs"]
    neighbor_count = min(i["neighbor_count"], 8) / 8
    gateway_proximity = (
        0.0 if i["gateway_distance"] is None
        else 1.0 / (1.0 + i["gateway_distance"])
    )
    mobility_score = 1.0 - min(i["mobility_mps"], 5.0) / 5.0
    score = (0.30 * i["battery"] + 0.20 * neighbor_count
             + 0.20 * gateway_proximity + 0.15 * i["link_stability"]
             + 0.15 * mobility_score)
    assert round(score, 6) == case["relay_score"]
