"""A reference implementation of POST /api/v1/gateway/sync (docs/api.md).

Two purposes:

1. It lets me test the real HTTP path of the gateway client without waiting
   for the backend.
2. It is an executable statement of the contract for my teammate — if their
   FastAPI service behaves like this, my client will work against it.

It is deliberately dumb: it assigns incident IDs and deduplicates by
report_id. It does no Gemini analysis, no fusion, no prioritisation — those
are the backend's job, and faking them here would invite us to demo a
capability that does not exist.

    python -m avertis_sim.mock_gateway_server --port 8000
"""

from __future__ import annotations

import argparse
import json
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

MAX_BODY_BYTES = 2 * 1024 * 1024


class GatewayState:
    """Everything the mock remembers, guarded for concurrent syncs."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.reports: dict[str, str] = {}       # report_id -> incident_id
        self.syncs: list[dict[str, Any]] = []
        self.nodes: dict[str, dict[str, Any]] = {}
        self.next_incident = 1042

    def accept(self, body: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            self.syncs.append({
                "gateway_id": body.get("gateway_id"),
                "at": body.get("sent_at"),
                "reports": len(body.get("incidents", [])),
            })
            for node in body.get("nodes", []):
                if isinstance(node, dict) and node.get("node_id"):
                    self.nodes[node["node_id"]] = node

            accepted: list[str] = []
            rejected: list[dict[str, str]] = []
            incidents: list[dict[str, Any]] = []

            for report in body.get("incidents", []):
                report_id = report.get("report_id")
                if not report_id:
                    rejected.append({"report_id": "", "reason": "MISSING_ID"})
                    continue
                location = report.get("location")
                if location is not None and (
                    not isinstance(location, dict)
                    or "lat" not in location
                    or "lon" not in location
                ):
                    rejected.append({"report_id": report_id,
                                     "reason": "MALFORMED_LOCATION"})
                    continue

                if report_id in self.reports:
                    # Idempotent: a custody retry is acknowledged, not
                    # re-ingested. The real backend must do this too.
                    incident_id = self.reports[report_id]
                else:
                    incident_id = f"INC-{self.next_incident}"
                    self.next_incident += 1
                    self.reports[report_id] = incident_id
                accepted.append(report_id)
                incidents.append({"report_id": report_id,
                                  "incident_id": incident_id,
                                  "fused_into": None})

            return {
                "received_at": datetime.now(timezone.utc)
                .isoformat(timespec="milliseconds")
                .replace("+00:00", "Z"),
                "accepted": accepted,
                "rejected": rejected,
                "incidents": incidents,
                "commands": [
                    {"type": "SYNC_ACK", "report_id": i["report_id"],
                     "incident_id": i["incident_id"]}
                    for i in incidents
                ],
            }


STATE = GatewayState()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802 - stdlib naming
        if self.path == "/api/v1/health":
            self._send(200, {"status": "ok", "version": "mock-1.0"})
        elif self.path == "/api/v1/debug/state":
            self._send(200, {"reports": len(STATE.reports),
                             "syncs": len(STATE.syncs),
                             "nodes": len(STATE.nodes)})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - stdlib naming
        if self.path != "/api/v1/gateway/sync":
            self._send(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY_BYTES:
            self._send(413, {"error": "payload too large"})
            return
        try:
            body = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self._send(400, {"error": "malformed JSON"})
            return
        if not isinstance(body, dict) or "gateway_id" not in body:
            self._send(400, {"error": "gateway_id is required"})
            return

        self._send(200, STATE.accept(body))

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"  [gateway] {fmt % args}")


def serve(port: int = 8000) -> None:
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"Mock Avertis gateway API on http://127.0.0.1:{port}")
    print("  POST /api/v1/gateway/sync   GET /api/v1/health")
    server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock Avertis gateway API")
    parser.add_argument("--port", type=int, default=8000)
    serve(parser.parse_args().port)
