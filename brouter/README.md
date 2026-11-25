# BRouter — self-hosted routing engine for the Route Planner

The Route Planner (technote.ROUTE-DRAW.md §10) routes through a **self-hosted
BRouter** container. The application never depends on public BRouter services,
and the frontend never talks to BRouter directly — every request flows
Rails (`PlannerController` → `Routing::BrouterClient`) → the internal
endpoint.

## Topology

```
Browser ──POST /planner/calculate──▶ Rails (Routing::BrouterClient)
                                          │  private `explorer` network only
                                          ▼
                              brouter:17777 (ghcr.io/abrensch/brouter)
                                ├─ /segments4      OSM + elevation data (volume)
                                └─ /customprofiles brouter/profiles/*.brf (repo, ro)
```

* **No ports are published** — BRouter is reachable only from the app's
  compose network (§10.3).
* Profiles (`road.brf`, `gravel.brf`, `mtb.brf`) ship in this directory and
  mount read-only at `/customprofiles`. Requests address them as
  `custom_road` / `custom_gravel` / `custom_mtb`. Tune them without touching
  the Rails app or rebuilding the image (§10.5).
* Resource limits, health check and threads are set in `docker-compose.yml`
  (§10.7).

## Installing routing data (first deploy)

The container starts without routing data — the health check stays unhealthy
until segments are installed. The segments4 server serves a **5-degree tile
grid**, not countries: `E<west>_<south>.rd5` (e.g. `E105_N15.rd5` covers
105–110E / 15–20N). Download the tiles for the regions you serve into the
`brouter_segments` volume with the helper script:

```sh
# from the host, in the project directory — Thailand + Vietnam
./brouter/download-segments.sh E95_N5 E95_N10 E95_N15 E95_N20 \
    E100_N5 E100_N10 E100_N15 E100_N20 E105_N10 E105_N15 E105_N20
```

(The full tile list lives at `https://brouter.de/brouter/segments4/`.)
The script downloads into the `brouter_segments` volume — the same one the
container mounts at `/segments4` — via a temporary Alpine container, so the
running BRouter never sees partial files (§10.9). Each tile is ~10–45 MB.

## Image + lookup table (must match the segment data)

* The compose file pins **`ghcr.io/abrensch/brouter:v1.7.8`** — the published
  `:latest` lags the segment server, and its bundled `lookups.dat` (v10)
  mismatches the current v11 tiles: every request then dies with
  `lookup version mismatch (old rd5?)`.
* The repo ships **`brouter/lookups.dat`** (v11, from abrensch/brouter
  master `misc/profiles2/`) mounted read-only over the image's
  `/profiles2/lookups.dat`. When you refresh segment tiles, refresh this file
  from the same upstream revision.
* Custom profiles (`brouter/profiles/*.brf`) must only reference lookups that
  exist in that file — an unknown name fails every request with
  `ParseException ... unknown lookup name: ...` (e.g. the legacy `mtbscale`
  is spelled `mtb:scale` in v11).

## Updating routing data (§10.9)

1. Run `./brouter/download-segments.sh <countries...>` again — new files land
   beside the old ones atomically (download to `.part`, rename on success).
2. Restart the engine so it reopens the data:
   `docker compose restart brouter` (dokploy: restart the brouter service).
3. Watch the health check flip back to healthy before routing traffic.

Never delete an `.rd5` while BRouter is serving — update-then-restart keeps
the engine away from partially updated data.

## Monitoring (§10.8)

* `docker compose ps` — health of the `brouter` service (the health check
  routes a small trip through `custom_road`).
* `docker compose logs brouter` — the engine's own request log.
* Rails log, `[planner/routing]` lines — per-request outcome, point count,
  profile and duration_ms from the adapter; failures are counted there
  (`outcome=unavailable|...`), enough to size the container or add instances.
* `docker stats brouter` — live CPU/memory.

## Scaling later

The adapter is stateless; horizontal scaling means running more `brouter`
instances behind an internal load balancer (e.g. nginx on the `explorer`
network) and pointing `BRROUTER_URL` at it — no application change.
