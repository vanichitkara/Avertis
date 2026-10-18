

def test_recovery_is_visible_to_a_gateway_not_only_to_the_simulator():
    """"Returned to Responder A" has to be true of what a gateway reports.

    The scenario's closing finding is that the recommendation comes back
    to A once the relay recovers. That was computed from the simulator's
    own selector, which reads the world directly. A gateway cannot: it
    knows the mesh through beacons, and its view of a just-restored link
    lags the world by much longer than the scenario used to wait.

    So at 30 s of settling the finding said A while every gateway sync
    still carried a topology on which the backend chose B — the command
    centre contradicting the terminal, on the one moment the demo exists
    to show.
    """
    from avertis_sim.scenarios import get_scenario

    scenario = get_scenario("response_adaptation")(seed=42)
    result = scenario.run()

    recovered = [f for f in result.findings if "after R7 recovered" in f]
    assert recovered, "the scenario no longer reports a recovery"
    assert "Responder A" in recovered[0]

    # The synced topology must agree, because that is all the backend and
    # the dashboard ever see. Reliability along a path is the product of
    # its links, which is what the backend computes from exactly this.
    links = {
        frozenset((link["a"], link["b"])): link["stability"]
        for link in scenario.backend.syncs[-1]["links"]
    }

    def path(*hops: str) -> float:
        total = 1.0
        for a, b in zip(hops, hops[1:]):
            stability = links.get(frozenset((a, b)))
            assert stability is not None, f"no link {a}–{b} was synced"
            total *= stability
        return total

    to_a = path("resp-a", "R7", "node-inc")
    to_b = path("resp-b", "R3", "R2", "node-inc")
    assert to_a > to_b, (
        f"the synced mesh still rates B ({to_b:.0%}) above A ({to_a:.0%}), "
        f"so the command centre would contradict the terminal on the one "
        f"moment this scenario exists to show"
    )
