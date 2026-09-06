"""Avertis simulator CLI.

    python -m avertis_sim list
    python -m avertis_sim run relay_failure --replay out/relay.jsonl
    python -m avertis_sim run all
    python -m avertis_sim benchmark --nodes 200
    python -m avertis_sim replay out/relay.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .benchmark import run_benchmark
from .gateway_client import HttpBackend, InMemoryBackend
from .replay import load_replay, render_timeline
from .scenarios import SCENARIOS, get_scenario


def cmd_list(args: argparse.Namespace) -> int:
    print("Available scenarios:\n")
    for key in sorted(SCENARIOS):
        print(f"  {key:22s} {SCENARIOS[key].title}")
    return 0


def _backend(args: argparse.Namespace):
    if getattr(args, "api", None):
        print(f"→ syncing to backend at {args.api}")
        return HttpBackend(args.api, api_key=getattr(args, "api_key", "") or "")
    return InMemoryBackend()


def cmd_run(args: argparse.Namespace) -> int:
    keys = sorted(SCENARIOS) if args.scenario == "all" else [args.scenario]
    for key in keys:
        try:
            cls = get_scenario(key)
        except KeyError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        scenario = cls(seed=args.seed, backend=_backend(args))
        replay = args.replay
        if replay and len(keys) > 1:
            replay = str(Path(replay).with_name(f"{key}.jsonl"))
        result = scenario.run(replay_path=replay)
        print(result.render())
        if args.json:
            Path(args.json).parent.mkdir(parents=True, exist_ok=True)
            Path(args.json).write_text(
                json.dumps({"scenario": result.key,
                            "benchmark": result.benchmark.to_json(),
                            "timeline": result.timeline,
                            "recommendations": [r.to_json()
                                                for r in result.recommendations],
                            "findings": result.findings}, indent=2)
            )
            print(f"\n  results written to {args.json}")
    return 0


def cmd_benchmark(args: argparse.Namespace) -> int:
    run_benchmark(nodes=args.nodes, seeds=args.seeds, json_out=args.json)
    return 0


def cmd_replay(args: argparse.Namespace) -> int:
    events = load_replay(args.path)
    print(f"{len(events)} events in {args.path}\n")
    for clock, label in render_timeline(events):
        print(f"  {clock}  {label}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="avertis_sim", description="Avertis disaster mesh simulator"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="list scenarios").set_defaults(func=cmd_list)

    run = sub.add_parser("run", help="run a scenario (or 'all')")
    run.add_argument("scenario")
    run.add_argument("--seed", type=int, default=42)
    run.add_argument("--replay", help="write the replay log here")
    run.add_argument("--json", help="write results as JSON here")
    run.add_argument("--api", help="POST to a real backend, e.g. http://localhost:8000")
    run.add_argument("--api-key", default="")
    run.set_defaults(func=cmd_run)

    bench = sub.add_parser("benchmark", help="baseline vs Avertis resilience")
    bench.add_argument("--nodes", type=int, default=100)
    bench.add_argument("--seeds", type=int, default=5,
                       help="how many seeds to average over")
    bench.add_argument("--json", help="write results as JSON here")
    bench.set_defaults(func=cmd_benchmark)

    rep = sub.add_parser("replay", help="render a replay log as a timeline")
    rep.add_argument("path")
    rep.set_defaults(func=cmd_replay)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
