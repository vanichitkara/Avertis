"""Partition detection over the live link graph.

Deterministic graph work only — this is what lets the system say "responder A
is in a different partition from the incident", which is the input the Response
Agent reasons over. See plan §18 and §23.
"""

from __future__ import annotations

import networkx as nx


def build_graph(nodes: list[str], links: list[tuple[str, str, float]]) -> nx.Graph:
    g = nx.Graph()
    g.add_nodes_from(nodes)
    for a, b, stability in links:
        g.add_edge(a, b, stability=stability, weight=1.0 - min(stability, 0.999))
    return g


def connected_components(graph: nx.Graph) -> list[set[str]]:
    """Components, largest first, ties broken by lowest member ID.

    Deterministic ordering matters: partition IDs appear in the world model
    sent to the backend, and they must be stable across a replay.
    """
    comps = [set(c) for c in nx.connected_components(graph)]
    return sorted(comps, key=lambda c: (-len(c), min(c)))


def partition_map(graph: nx.Graph) -> dict[str, int]:
    """node_id -> partition index (0 is the largest component)."""
    return {
        node: idx
        for idx, comp in enumerate(connected_components(graph))
        for node in comp
    }


def reachability(graph: nx.Graph, targets: set[str]) -> dict[str, bool]:
    """Which nodes can currently reach *any* of `targets` (e.g. the gateways)."""
    if not targets:
        return {n: False for n in graph.nodes}
    reachable: set[str] = set()
    for comp in connected_components(graph):
        if comp & targets:
            reachable |= comp
    return {n: n in reachable for n in graph.nodes}


def path_reliability(graph: nx.Graph, source: str, target: str) -> float:
    """Product of link stabilities along the most reliable path, 0 if none.

    This is the number the WHY explanation quotes as "network reliability".
    It is measured from real link state, never invented.
    """
    if source not in graph or target not in graph:
        return 0.0
    if source == target:
        return 1.0
    try:
        # Minimising summed (1 - stability) approximates maximising the
        # product of stabilities and is what networkx can do directly.
        path = nx.shortest_path(graph, source, target, weight="weight")
    except nx.NetworkXNoPath:
        return 0.0
    reliability = 1.0
    for a, b in zip(path, path[1:]):
        reliability *= graph[a][b]["stability"]
    return reliability


def hop_distance(graph: nx.Graph, source: str, target: str) -> int | None:
    try:
        return nx.shortest_path_length(graph, source, target)
    except (nx.NetworkXNoPath, nx.NodeNotFound):
        return None
