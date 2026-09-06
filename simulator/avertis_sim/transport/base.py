"""Transport abstraction — the seam that keeps the mesh engine radio-agnostic.

The engine only ever sees `MeshTransport`. In the simulator that is a modelled
radio; on the phone it is BLE. Mirrors mobile/lib/mesh/transport/mesh_transport.dart.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Callable, Protocol

from ..protocol import Packet


class TransportListener(Protocol):
    def on_packet(self, from_node: str, packet: Packet) -> None: ...
    def on_peer_lost(self, node_id: str) -> None: ...


class MeshTransport(ABC):
    """One node's link layer.

    Implementations are responsible only for getting bytes to a *directly
    reachable* peer. Routing, TTL, dedup and queueing are the engine's job.
    """

    def __init__(self, node_id: str):
        self.node_id = node_id
        self._listener: TransportListener | None = None

    def bind(self, listener: TransportListener) -> None:
        self._listener = listener

    @abstractmethod
    def start(self) -> None: ...

    @abstractmethod
    def stop(self) -> None: ...

    @abstractmethod
    def peers(self) -> list[str]:
        """Currently reachable peer node IDs (link-local only)."""

    @abstractmethod
    def send(self, to_node: str, packet: Packet) -> bool:
        """Unicast to a direct peer. False if the link is unusable right now."""

    @abstractmethod
    def broadcast(self, packet: Packet) -> int:
        """Send to every direct peer. Returns the number of links written to."""

    # -- delivery into the engine -------------------------------------

    def _deliver(self, from_node: str, packet: Packet) -> None:
        if self._listener is not None:
            self._listener.on_packet(from_node, packet)

    def _peer_lost(self, node_id: str) -> None:
        if self._listener is not None:
            self._listener.on_peer_lost(node_id)
