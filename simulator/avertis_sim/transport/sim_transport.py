"""Simulated radio transport.

Models what BLE actually gives us: short range, distance-dependent loss, a
finite per-link throughput, and links that vanish when a node dies. Everything
is driven by a seeded RNG so a scenario replays identically.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass

from ..protocol import Packet
from .base import MeshTransport


@dataclass
class RadioModel:
    """Parameters of the modelled BLE radio."""

    range_m: float = 120.0
    # Probability a frame is lost at zero distance (radio noise floor).
    base_loss: float = 0.01
    # Additional loss approaching max range.
    edge_loss: float = 0.35
    # One-way latency, seconds, per hop.
    latency_s: float = 0.06
    # Bytes per second per link (BLE realistic-ish, conservative).
    throughput_bps: float = 8000.0

    def link_quality(self, distance_m: float) -> float:
        """1.0 at zero distance, 0.0 beyond range."""
        if distance_m >= self.range_m:
            return 0.0
        x = distance_m / self.range_m
        # Quadratic falloff — closer to real RSSI behaviour than linear.
        return max(0.0, 1.0 - x * x)

    def loss_probability(self, distance_m: float) -> float:
        q = self.link_quality(distance_m)
        if q <= 0.0:
            return 1.0
        return self.base_loss + (1.0 - q) * self.edge_loss

    def rssi(self, distance_m: float) -> int:
        if distance_m <= 1.0:
            return -40
        # Log-distance path loss, n=2.5, ref -40 dBm at 1 m.
        return int(-40 - 10 * 2.5 * math.log10(distance_m))


class SimRadioTransport(MeshTransport):
    """A node's radio inside the simulated world.

    Holds a back-reference to the world so it can ask "who can I hear right
    now?" — this is exactly what a BLE scan answers on a real device.
    """

    def __init__(self, node_id: str, world: "World", radio: RadioModel):
        super().__init__(node_id)
        self.world = world
        self.radio = radio
        self.running = False
        self.bytes_sent = 0
        self.frames_sent = 0
        self.frames_dropped = 0

    def start(self) -> None:
        self.running = True

    def stop(self) -> None:
        self.running = False

    def peers(self) -> list[str]:
        if not self.running:
            return []
        return self.world.peers_of(self.node_id)

    def send(self, to_node: str, packet: Packet) -> bool:
        if not self.running:
            return False
        return self.world.transmit(self.node_id, to_node, packet)

    def broadcast(self, packet: Packet) -> int:
        if not self.running:
            return 0
        sent = 0
        for peer in self.peers():
            if self.world.transmit(self.node_id, peer, packet):
                sent += 1
        return sent
