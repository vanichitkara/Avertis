"""Network Agent — understands the mesh, does not operate it.

Plan §22 is explicit: this agent reasons about topology, partitions, gateways,
node health and reachability, and must **not** touch packet-level routing.
That stays in the deterministic mesh engine on the device and in the
simulator.

So nothing here forwards anything. It consumes the network state that arrives
in every gateway sync and answers the one question the Response Agent needs:
*can these two points actually talk to each other right now, and how well?*
"""

from __future__ import annotations

from collections import deque

from ..models import LinkSnapshot, NodeSnapshot

# A link below this stability is treated as present but not dependable. It
# still carries traffic; it just should not be the thing a rescue plan rests
# on.
USABLE_LINK_STABILITY = 0.35


class NetworkView:
    """A queryable snapshot of the mesh at one moment."""

    def __init__(
        self, nodes: list[NodeSnapshot], links: list[LinkSnapshot]
    ) -> None:
        self.nodes = {n.node_id: n for n in nodes}
        self.links = links

        self._adjacency: dict[str, dict[str, float]] = {n: {} for n in self.nodes}
        for link in links:
            if link.a not in self._adjacency or link.b not in self._adjacency:
                # A link to a node we have never seen. Keep the node so the
                # topology is not silently wrong.
                self._adjacency.setdefault(link.a, {})
                self._adjacency.setdefault(link.b, {})
            self._adjacency[link.a][link.b] = link.stability
            self._adjacency[link.b][link.a] = link.stability

        self._partitions = self._compute_partitions()

    # -- partitions --------------------------------------------------------

    def _compute_partitions(self) -> dict[str, int]:
        """Connected components over usable links.

        A partition is the honest unit of "who can reach whom". Two nodes in
        different components cannot communicate at all, however close they
        are on a map — which is the entire premise of the project.
        """
        seen: dict[str, int] = {}
        component = 0
        for start in sorted(self._adjacency):
            if start in seen:
                continue
            queue = deque([start])
            seen[start] = component
            while queue:
                current = queue.popleft()
                for peer, stability in self._adjacency[current].items():
                    if stability < USABLE_LINK_STABILITY:
                        continue
                    if peer not in seen:
                        seen[peer] = component
                        queue.append(peer)
            component += 1
        return seen

    @property
    def partition_count(self) -> int:
        return len(set(self._partitions.values())) if self._partitions else 0

    def partition_of(self, node_id: str) -> int | None:
        return self._partitions.get(node_id)

    def same_partition(self, a: str, b: str) -> bool:
        pa, pb = self.partition_of(a), self.partition_of(b)
        return pa is not None and pa == pb

    # -- reachability ------------------------------------------------------

    def best_path(self, src: str, dst: str) -> tuple[list[str], float]:
        """The most reliable path, and its end-to-end reliability.

        Reliability multiplies along the path: a five-hop route of 0.9 links
        is 0.59, not 0.9. That compounding is exactly why a distant responder
        on a short stable path can beat a near one behind a long fragile
        chain.

        Widest-path search (Dijkstra with max-min replaced by max-product).
        """
        if src == dst:
            return [src], 1.0
        if src not in self._adjacency or dst not in self._adjacency:
            return [], 0.0

        best: dict[str, float] = {src: 1.0}
        previous: dict[str, str] = {}
        unvisited = set(self._adjacency)

        while unvisited:
            current = max(unvisited, key=lambda n: best.get(n, 0.0))
            score = best.get(current, 0.0)
            if score <= 0.0:
                break
            unvisited.discard(current)
            if current == dst:
                break
            for peer, stability in self._adjacency[current].items():
                if peer not in unvisited:
                    continue
                candidate = score * stability
                if candidate > best.get(peer, 0.0):
                    best[peer] = candidate
                    previous[peer] = current

        reliability = best.get(dst, 0.0)
        if reliability <= 0.0:
            return [], 0.0

        path = [dst]
        while path[-1] != src:
            path.append(previous[path[-1]])
        return list(reversed(path)), round(reliability, 4)

    def reliability_between(self, src: str, dst: str) -> float:
        return self.best_path(src, dst)[1]

    # -- health ------------------------------------------------------------

    @property
    def gateways(self) -> list[str]:
        return [n.node_id for n in self.nodes.values() if n.role.value == "GATEWAY"]

    def reachable_count(self) -> int:
        return sum(1 for n in self.nodes.values() if n.reachable)

    def summary(self) -> dict:
        return {
            "nodes_total": len(self.nodes),
            "nodes_reachable": self.reachable_count(),
            "partitions": self.partition_count,
            "gateways": self.gateways,
            # Named link_count, not links: /api/v1/world puts the actual
            # link list under "links", and two endpoints using one key for
            # an int and a list is a trap for anyone consuming both.
            "link_count": len(self.links),
            "mean_link_stability": round(
                sum(link.stability for link in self.links) / len(self.links), 3
            ) if self.links else 0.0,
        }


class NetworkAgent:
    """Builds a :class:`NetworkView` and reports on it. Never routes packets."""

    name = "network"

    def view(
        self, nodes: list[NodeSnapshot], links: list[LinkSnapshot]
    ) -> NetworkView:
        return NetworkView(nodes, links)
