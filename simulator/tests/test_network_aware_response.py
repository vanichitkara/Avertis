"""The signature behaviour (plan §6, §7): killing a relay changes who is sent.

Nothing physical moves in this test. The responders stay exactly where they
are, the hazards do not change, the incident does not change. The *only* thing
that changes is the communication topology — and the recommendation flips.
"""

from __future__ import annotations

import pytest

from avertis_sim.protocol import NodeRole
from avertis_sim.responders import NetworkAwareSelector, ResponderPool, Responder
from avertis_sim.responders.selection import DistanceOnlySelector, assess
from avertis_sim.topology import World, WorldConfig
from avertis_sim.transport.sim_transport import RadioModel


@pytest.fixture
def scene():
    """Incident at the origin. Responder A is closer but reaches the incident
    only through relay R7. Responder B is further but has a redundant path.

        A --- R7 --- INC --- R2 --- R3 --- B
    """
    cfg = WorldConfig(seed=21,
                      radio=RadioModel(range_m=110.0, base_loss=0.0,
                                       edge_loss=0.0))
    w = World(cfg)
    w.add_node("node-inc", role=NodeRole.SURVIVOR, x=0, y=0, battery=0.8)
    # Responder A's only route in is R7.
    w.add_node("R7", role=NodeRole.RELAY, x=-100, y=0, battery=0.95)
    w.add_node("node-ra", role=NodeRole.RESPONDER, x=-200, y=0, battery=0.9)
    # Responder B is further away but chained through two stable relays.
    w.add_node("R2", role=NodeRole.RELAY, x=100, y=0, battery=0.95)
    w.add_node("R3", role=NodeRole.RELAY, x=200, y=0, battery=0.95)
    w.add_node("node-rb", role=NodeRole.RESPONDER, x=300, y=0, battery=0.9)

    pool = ResponderPool()
    pool.add(Responder("Responder A", "node-ra", capability="RESCUE"))
    pool.add(Responder("Responder B", "node-rb", capability="RESCUE"))
    w.run_for(15)
    return w, pool


def test_scene_is_set_up_as_intended(scene):
    w, pool = scene
    a = [x for x in assess(w, pool, "node-inc") if x.responder_id == "Responder A"][0]
    b = [x for x in assess(w, pool, "node-inc") if x.responder_id == "Responder B"][0]
    assert a.distance_m < b.distance_m, "A must be the physically closer one"
    assert a.reachable and b.reachable
    assert a.hops == 2 and b.hops == 3


def test_before_failure_the_closer_responder_is_chosen(scene):
    w, pool = scene
    rec = NetworkAwareSelector().select("INC-142", assess(w, pool, "node-inc"))
    assert rec.chosen.responder_id == "Responder A"
    assert rec.chosen.network_reliability > 0.5


def test_killing_the_relay_flips_the_recommendation(scene):
    w, pool = scene
    selector = NetworkAwareSelector()

    before = selector.select("INC-142", assess(w, pool, "node-inc"))
    assert before.chosen.responder_id == "Responder A"

    # The only thing that changes in the entire world.
    w.kill_node("R7", reason="RELAY_FAILURE")
    w.run_for(20)

    after = selector.select("INC-142", assess(w, pool, "node-inc"))
    assert after.chosen.responder_id == "Responder B", (
        "recommendation did not adapt to the network change"
    )

    a_after = [x for x in after.considered if x.responder_id == "Responder A"][0]
    assert not a_after.reachable
    assert not a_after.same_partition
    assert a_after.network_reliability == 0.0
    # And A is still physically closer — the change is purely network-driven.
    assert a_after.distance_m < after.chosen.distance_m


def test_the_conventional_baseline_does_not_adapt(scene):
    """This contrast is the whole argument for Avertis."""
    w, pool = scene
    baseline, avertis = DistanceOnlySelector(), NetworkAwareSelector()

    assert baseline.select("INC-142", assess(w, pool, "node-inc")).chosen.responder_id == "Responder A"
    w.kill_node("R7", reason="RELAY_FAILURE")
    w.run_for(20)

    still_a = baseline.select("INC-142", assess(w, pool, "node-inc"))
    now_b = avertis.select("INC-142", assess(w, pool, "node-inc"))
    assert still_a.chosen.responder_id == "Responder A", (
        "the distance-only baseline should keep sending the unreachable responder"
    )
    assert now_b.chosen.responder_id == "Responder B"


def test_why_explanation_is_grounded_in_measured_state(scene):
    w, pool = scene
    w.kill_node("R7", reason="RELAY_FAILURE")
    w.run_for(20)
    rec = NetworkAwareSelector().select("INC-142", assess(w, pool, "node-inc"))

    why = rec.why
    assert "Responder B" in why
    assert "Responder A" in why, "the WHY must address the passed-over responder"
    assert "separate network partition" in why
    # The numbers quoted must match the assessment, not be free text.
    assert f"{rec.chosen.network_reliability:.0%}" in why
    a = [x for x in rec.considered if x.responder_id == "Responder A"][0]
    assert f"{a.distance_m / 1000:.1f} km" in why


def test_recommendation_reverts_when_the_relay_comes_back(scene):
    """The loop closes in both directions — this is not a one-way demo trick."""
    w, pool = scene
    selector = NetworkAwareSelector()
    w.kill_node("R7", reason="RELAY_FAILURE")
    w.run_for(20)
    assert selector.select("INC-142", assess(w, pool, "node-inc")).chosen.responder_id == "Responder B"

    w.revive_node("R7", battery=0.95)
    w.run_for(25)
    back = selector.select("INC-142", assess(w, pool, "node-inc"))
    assert back.chosen.responder_id == "Responder A", (
        "recommendation did not recover when the network did"
    )


def test_hazard_change_alone_can_change_the_recommendation(scene):
    """Scenario 5: the physical world changes, the network does not."""
    from avertis_sim.responders.model import Hazard

    w, pool = scene
    selector = NetworkAwareSelector()
    assert selector.select("INC-142", assess(w, pool, "node-inc")).chosen.responder_id == "Responder A"

    # A flood opens across A's approach.
    pool.add_hazard(Hazard("HZ-1", "FLOOD", x=-150, y=0, radius_m=90,
                           severity=0.95))
    after = selector.select("INC-142", assess(w, pool, "node-inc"))
    assert after.chosen.responder_id == "Responder B"
    a = [x for x in after.considered if x.responder_id == "Responder A"][0]
    assert a.hazard_exposure > 0.3
    assert a.reachable, "the network is untouched — only the hazard changed"
