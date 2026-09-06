# Avertis Resilience Benchmark

Reproduce everything here with:

```bash
cd simulator && .venv/bin/python -m avertis_sim benchmark --nodes 100 --seeds 3
```

Every figure is produced by running the simulator. Nothing is hardcoded. Where
a result is unflattering or an artifact, it is written down as such.

---

## 1. What is measured

Two separate questions, deliberately not blended into one score:

1. **Mesh resilience** — does critical traffic still reach a gateway as the
   network is damaged, and how fast does the mesh recover?
2. **Response quality** — does making dispatch network-aware actually stop us
   sending responders we cannot communicate with?

## 2. Setup

100 nodes (5 gateways, 10 responders, 85 survivors) in a 1 km × 1 km area,
180 m radio range, seeded RNG. Three seeds per condition, averaged.

Node density is chosen so that the undamaged network is **fully connected** —
otherwise "damage caused a partition" would be unfalsifiable.

## 3. Mesh resilience under failure

| Condition | critical delivery | p50 latency | recovery | coverage | partitions | battery |
|---|---|---|---|---|---|---|
| no failures | 100.0% | 14.2 s | — | 100% | 1 | 2.2% |
| 20% node loss | 100.0% | 1.1 s | 1.5 s | 100% | 1 | 1.9% |
| 50% node loss | 96.1% | 0.5 s | 1.5 s | 91.2% | 4 | 1.5% |
| 20% loss + gateway lost | 97.0% | 0.9 s | 1.5 s | 100% | 1 | 1.9% |

Notes, including the uncomfortable one:

- **Latency is survivorship-biased.** p50 is computed only over reports that
  were *delivered*. A damaged network can therefore show a *lower* p50 than an
  intact one, because the slow deliveries it would have made are missing from
  the sample rather than slow. This is why "no failures" reads 14.2 s while
  "50% node loss" reads 0.5 s. Latency must be read alongside delivery rate,
  never on its own.
- **Critical delivery stays at or near 100% up to 50% node loss.** The residual
  4% at 50% loss are reports originating inside a partition with no gateway.
  They are **not** dropped — they stay in custody and are retransmitted when a
  route reappears (see §5).
- Battery consumption *falls* under damage simply because there are fewer
  nodes left forwarding.

## 4. Response quality: conventional baseline vs Avertis

Damage model: 20% scattered node loss **plus a linear damage corridor** across
the field (a flooded river, a collapsed road). This matters — see §6.

90 dispatch decisions across 3 seeds:

| | distance-only baseline | Avertis (network-aware) |
|---|---|---|
| dispatched an unreachable responder | 12/90 (13%) | 1/90 (1%) |
| mean network reliability of the chosen responder | 81% | 93% |

**Contested decisions** — the closest responder is cut off but another is
reachable. These are the only decisions where network-awareness can change
anything:

| | baseline | Avertis |
|---|---|---|
| contested decisions | 11/90 | 11/90 |
| dispatched an unreachable responder | **11/11 (100%)** | **0/11 (0%)** |

Cost of the trade: when the two selectors disagree (19/90 decisions), Avertis
sends a responder **57 m further** on average.

The remaining 1/90 case where Avertis also chose an unreachable responder is
one where *every* responder was unreachable — there was no better option.

## 5. Custody: what "not lost" means

A report that cannot reach a gateway is retained by its originating node and
retransmitted when connectivity returns (same `report_id`, fresh `packet_id`).
`test_custody_flushes_when_the_partition_heals` proves the full cycle:
partition → report retained, not delivered → partition heals → report
delivered → custody cleared on ACK.

Delivery-rate figures above count only reports that actually reached a gateway.
Reports in custody are reported separately and never counted as delivered.

## 6. A finding worth stating plainly

**On a well-connected mesh, network-aware dispatch and distance-only dispatch
agree, and they should.** Scattered random failures barely partition a dense
mesh — it routes around them — and under those conditions the naive baseline is
never punished. An earlier version of this benchmark used uniform random
failure and measured 0/27 vs 0/27: no difference at all.

That is not evidence the idea is worthless; it is evidence that the *failure
model* was wrong. Partitions come from **linear** damage — a river, a fire
front, a collapsed corridor — not from scattered device loss. Once the damage
model reflects that, the difference is stark (100% vs 0% on contested
decisions).

The honest claim is therefore narrow and defensible:

> Network-aware dispatch changes nothing most of the time. When the network
> partitions, it is the difference between dispatching a responder you can
> coordinate with and one you cannot.

## 7. What is *not* claimed

- Not that Avertis routes packets better than established mesh protocols. The
  forwarding logic is a deliberately transparent baseline (docs/protocol.md §8).
- Not that the relay scoring weights are optimal or learned. They are fixed,
  documented, and identical in both implementations.
- Not that these figures predict real-world BLE performance. They come from a
  modelled radio (distance-based loss, 8 kB/s per link, 180 m range). Physical
  phone testing is what validates the transport; the simulator validates the
  *logic* at a scale phones cannot reach.
