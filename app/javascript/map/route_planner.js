import maplibregl from "maplibre-gl";

// Route Planner engine (technote.ROUTE-DRAW.md) — the editing brain behind
// the My Map "Draw new route" mode. Owns the editor session (Routing
// Waypoints, Shaping Points, POIs, routing profile, per-segment calculated
// geometry), the undo/redo stacks and all map interaction. Routing is
// delegated to Rails (POST /planner/calculate → Routing::BrouterClient):
// the frontend NEVER talks to BRouter directly (§10.4). Design reference:
// design-refs/stitch_explorer_v.0.15.
//
// Recalculation discipline (§10.6): every request carries a monotonically
// increasing revision — stale responses are dropped; requests are debounced
// during drags, capped at MAX_INFLIGHT concurrent, and a failure keeps the
// last valid geometry (only the affected segment turns red).

const ROUTE_COLOR = "#e11d48";
const ROUTE_CASING = "#ffffff";
const FAILED_COLOR = "#b91c1c";
const MAX_INFLIGHT = 2;
const MAX_SNAPSHOTS = 50;
const MAX_WAYPOINTS = 100;
const DRAG_RECALC_DEBOUNCE_MS = 500;
const PROFILES = ["road", "gravel", "mtb"];
const KM_FORMAT = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });
const INT_FORMAT = new Intl.NumberFormat("en-US");

// Client mirror of Map::ElevationStats (5-point centered smoothing) so the
// panel's figures agree with what the server stores on save.
function smoothElevations(elevations) {
  if (elevations.length < 3) return elevations.slice();
  return elevations.map((_, i) => {
    const from = Math.max(i - 2, 0);
    const to = Math.min(i + 2, elevations.length - 1);
    let sum = 0;
    for (let k = from; k <= to; k += 1) sum += elevations[k];
    return sum / (to - from + 1);
  });
}

function elevationDeltas(elevations) {
  const smoothed = smoothElevations(elevations);
  let gain = 0;
  let loss = 0;
  for (let i = 1; i < smoothed.length; i += 1) {
    const delta = smoothed[i] - smoothed[i - 1];
    if (delta > 0) gain += delta;
    else loss -= delta;
  }
  return { gain, loss };
}

function deepClone(value) {
  return JSON.parse(JSON.stringify(value));
}

function formatDuration(seconds) {
  if (!seconds || seconds <= 0) return "\u2014";
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);
  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes} min`;
}

export class RoutePlanner {
  constructor({ map, panel, urls, initialState, onExit, onSaved, onToast }) {
    this.map = map;
    this.panel = panel;
    this.urls = urls;
    this.onExit = onExit;
    this.onSaved = onSaved;
    this.onToast = onToast || null;
    this.active = true;

    const state = initialState || {};
    this.routeId = state.route_id || null;
    this.title = state.title || "";
    this.profile = state.profile || "road";
    this.loop = !!state.loop;
    this.waypoints = (state.waypoints || []).map((point) => ({ lat: point.lat, lon: point.lon }));
    this.shaping = this.loadShaping(state.shaping_points || []);
    this.pois = (state.pois || []).map((poi) => ({
      id: this.nextId(),
      lat: poi.lat,
      lon: poi.lon,
      title: poi.title || "",
      description: poi.description || "",
      external_url: poi.external_url || "",
      image_url: poi.image_url || null,
      image_signed_id: null,
      waypoint_index: Number.isFinite(Number(poi.waypoint_index)) ? Number(poi.waypoint_index) : null,
    }));
    // Uploaded (never-drawn) routes carry their full track as one "segment"
    // and no RWs: seed RWs at the track ends so every planner tool works
    // (technote §2.2).
    if (this.waypoints.length === 0 && (state.segments || []).length === 1 && (state.segments[0] || []).length >= 2) {
      const track = state.segments[0];
      this.waypoints = [
        { lat: track[0][1], lon: track[0][0] },
        { lat: track[track.length - 1][1], lon: track[track.length - 1][0] },
      ];
    }
    this.segments = this.buildInitialSegments(state.segments || []);

    this.undoStack = [];
    this.redoStack = [];
    this.revisionCounter = 1;
    this.appliedRevisions = {};
    // Recalculation pipeline state (§10.6). inFlightCount MUST start at 0:
    // pumpCalcQueue guards on `inFlightCount < MAX_INFLIGHT`, and an
    // undefined counter makes that comparison false — the queue would never
    // drain and no calculation request would ever leave the browser.
    this.inFlightCount = 0;
    this.queuedSegments = new Set();
    this.calcTimer = null;
    this.dragContext = null;
    this.cursorPoint = null;
    this.poiArmed = false;
    this.pendingPoiPoint = null;
    this.poiEditing = null;
    this.poiImageState = { signedId: null, url: null, removed: false };
    this.idCounter = 0;
    this.persisted = deepClone(this.stateSnapshot());

    this.dom = this.collectDom();
    this.bindDom();
    this.addMapLayers();
    this.syncWaypointMarkers();
    this.syncPoiMarkers();
    this.renderAll();
    this.fitToRoute();
    if (this.segments.some((segment) => segment.status === "pending")) this.recalculateAll();
  }

  nextId() {
    this.idCounter += 1;
    return `${Date.now().toString(36)}-${this.idCounter}`;
  }

  buildInitialSegments(storedSegments) {
    const count = this.segmentCount();
    if (count === 0) return [];
    if (storedSegments.length === count) {
      return storedSegments.map((points) => ({
        points: points && points.length >= 2 ? points : [],
        distanceM: 0,
        ascendM: 0,
        timeS: 0,
        status: points && points.length >= 2 ? "ok" : "pending",
      }));
    }
    // Uploaded route: its whole stored track is segment 0's geometry; the
    // RW seeds above make it editable without a recalculation.
    if (count === 1 && storedSegments.length === 1) {
      return [{
        points: storedSegments[0] || [], distanceM: 0, ascendM: 0, timeS: 0,
        status: storedSegments[0] && storedSegments[0].length >= 2 ? "ok" : "pending",
      }];
    }
    return Array.from({ length: count }, () => ({
      points: [], distanceM: 0, ascendM: 0, timeS: 0, status: "pending",
    }));
  }

  loadShaping(rawPoints) {
    const shaping = this.waypoints.map(() => []);
    (rawPoints || []).forEach((raw) => {
      const index = Number(raw.segment_index) || 0;
      if (!shaping[index]) shaping[index] = [];
      shaping[index].push({ id: `s${this.nextId()}`, lat: raw.lat, lon: raw.lon, position: Number(raw.position) || 0 });
    });
    shaping.forEach((points) => points.sort((a, b) => a.position - b.position));
    return shaping;
  }

  // ---- session state + undo (§5.4) ------------------------------------------

  // Everything undo must restore — geometry, point collections, associations
  // and metadata (§5.4) — snapshot in one serializable object. Also the
  // dirty check behind Cancel (§6.2).
  stateSnapshot() {
    return {
      title: this.title,
      profile: this.profile,
      loop: this.loop,
      waypoints: deepClone(this.waypoints),
      shaping: deepClone(this.shaping),
      pois: deepClone(this.pois),
      segments: this.segments.map((segment) => ({
        points: deepClone(segment.points),
        distanceM: segment.distanceM,
        status: segment.status,
      })),
    };
  }

  pushUndo() {
    this.undoStack.push(this.stateSnapshot());
    if (this.undoStack.length > MAX_SNAPSHOTS) this.undoStack.shift();
    this.redoStack = [];
    this.renderButtons();
  }

  undo() {
    if (!this.undoStack.length) return;
    this.redoStack.push(this.stateSnapshot());
    this.restoreSnapshot(this.undoStack.pop());
  }

  redo() {
    if (!this.redoStack.length) return;
    this.undoStack.push(this.stateSnapshot());
    this.restoreSnapshot(this.redoStack.pop());
  }

  restoreSnapshot(snapshot) {
    this.title = snapshot.title;
    this.profile = snapshot.profile;
    this.loop = snapshot.loop;
    this.waypoints = deepClone(snapshot.waypoints);
    this.shaping = deepClone(snapshot.shaping);
    this.pois = deepClone(snapshot.pois);
    this.segments = snapshot.segments.map((segment) => ({
      points: deepClone(segment.points),
      distanceM: segment.distanceM,
      ascendM: 0,
      timeS: 0,
      status: segment.status,
    }));
    this.dom.title.value = this.title;
    this.syncWaypointMarkers();
    this.syncPoiMarkers();
    this.renderAll();
  }

  isDirty() {
    return JSON.stringify(this.stateSnapshot()) !== JSON.stringify(this.persisted);
  }

  // ---- DOM contract (the data-planner hooks in maps/show.html.erb) ----------

  collectDom() {
    const dom = {};
    const store = (node) => {
      const key = node.getAttribute("data-planner");
      // Every hook is reachable both ways: raw ("stat-distance") and camel
      // ("statDistance") — the module's render code uses whichever reads
      // more naturally.
      dom[key] = node;
      dom[key.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = node;
    };
    this.panel.querySelectorAll("[data-planner]").forEach((node) => {
      if (node.getAttribute("data-planner") === "profile") {
        dom.profiles = dom.profiles || [];
        dom.profiles.push(node);
      } else {
        store(node);
      }
    });
    const modal = document.getElementById("planner-poi-modal");
    if (modal) {
      dom.poiModal = modal;
      modal.querySelectorAll("[data-planner]").forEach(store);
    }
    return dom;
  }

  bindDom() {
    this.dom.title.value = this.title;
    this.dom.title.addEventListener("input", () => {
      this.title = this.dom.title.value;
      this.renderButtons();
    });
    this.dom.profiles.forEach((button) => {
      button.addEventListener("click", () => this.setProfile(button.getAttribute("data-profile")));
    });
    this.dom.undo.addEventListener("click", () => this.undo());
    this.dom.redo.addEventListener("click", () => this.redo());
    this.dom.reverse.addEventListener("click", () => this.reverseRoute());
    this.dom.loop.addEventListener("click", () => this.toggleLoop());
    this.dom.clear.addEventListener("click", () => this.clearRoute());
    this.dom.save.addEventListener("click", () => this.save());
    this.dom.cancel.addEventListener("click", () => this.requestExit());
    this.dom.close.addEventListener("click", () => this.requestExit());
    this.dom.addPoi.addEventListener("click", () => this.armPoiPlacement());
    this.dom["confirm-stay"].addEventListener("click", () => this.hideConfirm());
    this.dom["confirm-discard"].addEventListener("click", () => {
      this.hideConfirm();
      this.teardown();
      if (this.onExit) this.onExit({ discarded: true });
    });
    this.keyHandler = (event) => this.onKeydown(event);
    document.addEventListener("keydown", this.keyHandler);
    this.map.on("mousemove", this.moveHandler = (event) => this.onMapMouseMove(event));
    this.map.on("click", this.clickHandler = (event) => this.onMapClick(event));
    this.map.on("mouseout", this.outHandler = () => {
      this.cursorPoint = null;
      this.updatePendingLine();
    });
    // POI modal (§7).
    this.dom["poi-form"].addEventListener("submit", (event) => {
      event.preventDefault();
      this.commitPoiModal();
    });
    this.dom["poi-cancel"].addEventListener("click", () => this.closePoiModal());
    this.dom["poi-modal-close"].addEventListener("click", () => this.closePoiModal());
    this.dom["poi-modal-backdrop"].addEventListener("click", () => this.closePoiModal());
    this.dom["poi-image"].addEventListener("change", (event) => this.uploadPoiImage(event));
    this.dom["poi-image-remove"].addEventListener("click", () => this.clearPoiImage());
  }

  onKeydown(event) {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z") {
      event.preventDefault();
      if (event.shiftKey) this.redo();
      else this.undo();
    } else if (event.key === "Escape" && !this.poiModalOpen) {
      this.requestExit();
    }
  }

  // ---- segment model ---------------------------------------------------------

  segmentCount() {
    if (this.waypoints.length < 2) return 0;
    return this.waypoints.length - 1 + (this.loop ? 1 : 0);
  }

  // Segment i: RW[i] → RW[i+1]; the last segment closes the loop back to
  // RW[0] in loop mode (§5.6 — no duplicate user-facing RW).
  segmentTo(index) {
    if (index < this.waypoints.length - 1) return this.waypoints[index + 1];
    return this.loop ? this.waypoints[0] : null;
  }

  // Control points for BRouter: the segment's two RWs with its SPs spliced
  // in order (§3.3 — SPs participate in the calculation).
  segmentControlPoints(index) {
    const from = this.waypoints[index];
    const to = this.segmentTo(index);
    if (!from || !to) return null;
    return [
      [from.lat, from.lon],
      ...(this.shaping[index] || []).map((point) => [point.lat, point.lon]),
      [to.lat, to.lon],
    ];
  }

  // Align segments/shaping with the RW sequence; existing geometry is kept
  // so unaffected segments are never recalculated (§5.3).
  reconcileSegments() {
    const count = this.segmentCount();
    const next = [];
    for (let index = 0; index < count; index += 1) {
      next.push(this.segments[index] || {
        points: [], distanceM: 0, ascendM: 0, timeS: 0, status: "pending",
      });
    }
    this.segments = next;
    while (this.shaping.length < count) this.shaping.push([]);
    this.shaping.length = count;
  }

  // ---- recalculation pipeline (§10.6) ----------------------------------------

  // Coalescing + debounce + concurrency cap: at most MAX_INFLIGHT requests
  // to Rails; the newest control-point set per segment wins; drags debounce.
  scheduleSegmentRecalc(indexes, immediate) {
    const valid = [...new Set(indexes || [])]
      .filter((index) => index >= 0 && index < this.segmentCount());
    if (!valid.length) return;
    this.queuedSegments = this.queuedSegments || new Set();
    valid.forEach((index) => this.queuedSegments.add(index));
    if (immediate) {
      if (this.calcTimer) clearTimeout(this.calcTimer);
      this.calcTimer = null;
      this.pumpCalcQueue();
      return;
    }
    if (this.calcTimer) clearTimeout(this.calcTimer);
    this.calcTimer = setTimeout(() => {
      this.calcTimer = null;
      this.pumpCalcQueue();
    }, DRAG_RECALC_DEBOUNCE_MS);
  }

  pumpCalcQueue() {
    if (!this.active) return;
    this.queuedSegments = this.queuedSegments || new Set();
    while (this.inFlightCount < MAX_INFLIGHT && this.queuedSegments.size) {
      const index = this.queuedSegments.values().next().value;
      this.queuedSegments.delete(index);
      this.requestSegment(index);
    }
  }

  // One segment calculation through Rails (§10.2 — the frontend never talks
  // to BRouter). Revisions drop stale responses; failures keep the last
  // valid geometry and mark only this segment (§10.6).
  requestSegment(index) {
    const from = this.waypoints[index];
    const to = index === this.waypoints.length - 1
      ? (this.loop ? this.waypoints[0] : null)
      : this.waypoints[index + 1];
    if (!from || !to) return;
    const points = [
      [from.lat, from.lon],
      ...(this.shaping[index] || []).map((point) => [point.lat, point.lon]),
      [to.lat, to.lon],
    ];
    const revision = ++this.revisionCounter;
    const segment = this.segments[index];
    segment.status = segment.points.length >= 2 ? segment.status : "pending";
    this.inFlightCount = (this.inFlightCount || 0) + 1;

    fetch(this.urls.calculate, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken(),
      },
      body: JSON.stringify({ profile: this.profile, points }),
    })
      .then((response) => response.json().then((payload) => ({ ok: response.ok, payload })))
      .then(({ ok, payload }) => {
        if (!ok) throw new Error(payload.error || "Routing failed.");
        if (!this.active) return; // planner exited while in flight
        if (revision < this.revisionCounter - 1) return; // superseded
        const data = payload.segment || {};
        segment.points = data.coordinates || [];
        segment.distanceM = Number(data.distance_m) || 0;
        segment.ascendM = Number(data.ascend_m) || 0;
        segment.timeS = Number(data.time_s) || 0;
        segment.status = "ok";
        this.updateRouteGeometry();
        this.renderStats();
        this.renderProfile();
        this.renderWaypointList();
      })
      .catch((error) => {
        if (!this.active) return; // planner exited while in flight
        segment.status = "failed";
        this.updateRouteGeometry();
        this.renderWaypointList();
        this.toast(error.message || "This segment could not be calculated.");
      })
      .finally(() => {
        this.inFlightCount = Math.max(0, this.inFlightCount - 1);
        if (this.active) this.pumpCalcQueue();
      });
  }

  recalculateAll() {
    const indexes = [];
    for (let index = 0; index < this.segmentCount(); index += 1) indexes.push(index);
    this.scheduleSegmentRecalc(indexes, true);
  }

  csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.content : "";
  }

  // ---- route actions ---------------------------------------------------------

  // Sequential waypoint placement (§5.1): every map click appends an RW and
  // Rails/BRouter calculates the connecting segment.
  addWaypoint(lat, lon) {
    if (this.waypoints.length >= MAX_WAYPOINTS) {
      this.toast("A route can hold at most 100 waypoints.");
      return;
    }
    this.pushUndo();
    this.waypoints.push({ lat, lon });
    this.reconcileSegments();
    this.syncWaypointMarkers();
    this.renderWaypointList();
    this.renderStats();
    this.scheduleSegmentRecalc([this.segmentCount() - 1], true);
  }

  // RW deletion (§5.3): the adjoining segments merge, their SPs are
  // reassigned to the merged segment in order, and only the merged segment
  // recalculates. POIs linked to the RW keep coordinates and metadata (§3.4).
  deleteWaypoint(index) {
    if (this.waypoints.length <= 2) {
      this.clearRoute();
      return;
    }
    this.pushUndo();
    // §5.3: the two adjoining segments merge; their SPs are reassigned into
    // the merged segment in order, other segments keep their constraints.
    this.waypoints.splice(index, 1);
    const mergedShaping = [...(this.shaping[index - 1] || []), ...(this.shaping[index] || [])];
    if (index > 0) {
      this.shaping.splice(index - 1, 2, mergedShaping);
    } else {
      this.shaping.splice(index, 1);
    }
    this.reconcileSegments();
    this.pois.forEach((poi) => {
      if (poi.waypoint_index === index) poi.waypoint_index = null;
      else if (poi.waypoint_index > index) poi.waypoint_index -= 1;
    });
    this.syncWaypointMarkers();
    this.syncPoiMarkers();
    this.syncShapingMarkers();
    this.renderWaypointList();
    this.renderStats();
    this.scheduleSegmentRecalc([index - 1], true);
  }

  // RW move (marker drag): only the adjoining segments recalculate (§5.3).
  moveWaypoint(index, lat, lon) {
    const waypoint = this.waypoints[index];
    if (!waypoint) return;
    waypoint.lat = lat;
    waypoint.lon = lon;
    this.scheduleSegmentRecalc([index - 1, index], true);
    this.renderStats();
    this.renderWaypointList();
  }

  // Profile switch (§4.4): preserve RWs, SPs and POIs; recalculate everything.
  setProfile(profile) {
    if (profile === this.profile) return;
    this.pushUndo();
    this.profile = profile;
    this.renderModeButtons();
    this.recalculateAll();
  }

  // Reverse (§5.5): RW order reverses, geometry reverses for visual
  // continuity, SP associations follow their segments, everything
  // recalculates (oneways make the reversed ride a different problem).
  reverseRoute() {
    if (this.waypoints.length < 2) return;
    this.pushUndo();
    this.waypoints.reverse();
    const count = this.segmentCount();
    const segments = [];
    const shaping = [];
    for (let index = 0; index < count; index += 1) {
      const source = this.segments[count - 1 - index];
      segments.push({
        points: source ? [...source.points].reverse() : [],
        distanceM: source ? source.distanceM : 0,
        ascendM: source ? source.ascendM : 0,
        timeS: source ? source.timeS : 0,
        status: source ? source.status : "pending",
      });
      shaping.push([...(this.shaping[count - 1 - index] || [])]);
    }
    this.segments = segments;
    this.shaping = shaping;
    this.syncWaypointMarkers();
    this.updateRouteGeometry();
    this.renderWaypointList();
    this.recalculateAll();
  }

  // Loop (§5.6): connects the last RW back to the first with a closing
  // segment; toggling off removes it. No duplicate user-facing RW is created.
  toggleLoop() {
    if (this.waypoints.length < 2) {
      this.toast("Place at least two waypoints first.");
      return;
    }
    this.pushUndo();
    this.loop = !this.loop;
    this.reconcileSegments();
    this.renderAll();
    if (this.loop) this.scheduleSegmentRecalc([this.segmentCount() - 1], true);
  }

  clearRoute() {
    if (!this.waypoints.length && !this.pois.length) return;
    this.pushUndo();
    this.waypoints = [];
    this.shaping = [];
    this.pois = [];
    this.segments = [];
    this.loop = false;
    this.syncWaypointMarkers();
    this.syncPoiMarkers();
    this.syncShapingMarkers();
    this.updateRouteGeometry();
    this.renderAll();
  }

  // ---- map layers + interactions ----------------------------------------------

  // Planner geometry rides its own sources ABOVE the browsing layers; labels
  // stay on top by inserting before the style's first symbol-ish layer.
  //
  // Idempotent: sources/layers survive teardown (a removed-and-re-added source
  // races the base style), so a re-entry after Exit must NOT addSource again.
  // Handlers are always re-bound — teardown removes the previous ones.
  addMapLayers() {
    if (!this.map.getSource("planner-route")) {
      const empty = { type: "FeatureCollection", features: [] };
      this.map.addSource("planner-route", { type: "geojson", data: empty });
      this.map.addSource("planner-pending", { type: "geojson", data: empty });
    }
    const layers = (this.map.getStyle() || { layers: [] }).layers || [];
    const beforeId = (layers.find((layer) => layer.type === "symbol") || {}).id;
    const definitions = [
      {
        id: "planner-route-casing",
        type: "line",
        source: "planner-route",
        layout: { "line-cap": "round", "line-join": "round" },
        paint: { "line-color": ROUTE_CASING, "line-width": 8 },
      },
      {
        id: "planner-route-line",
        type: "line",
        source: "planner-route",
        layout: { "line-cap": "round", "line-join": "round" },
        paint: {
          "line-color": ["case", ["==", ["get", "failed"], true], FAILED_COLOR, ROUTE_COLOR],
          "line-width": 4.5,
        },
      },
      {
        // Wide transparent hit-area so grabbing the line is easy.
        id: "planner-route-hit",
        type: "line",
        source: "planner-route",
        layout: { "line-cap": "round", "line-join": "round" },
        paint: { "line-color": "rgba(0,0,0,0.001)", "line-width": 22 },
      },
      {
        id: "planner-pending-line",
        type: "line",
        source: "planner-pending",
        layout: { "line-cap": "round" },
        paint: { "line-color": ROUTE_COLOR, "line-width": 3, "line-dasharray": [1.5, 1.5] },
      },
    ];
    definitions.forEach((definition) => {
      if (this.map.getLayer(definition.id)) return;
      if (beforeId) this.map.addLayer(definition, beforeId);
      else this.map.addLayer(definition);
    });

    this.map.on("mousemove", this.moveHandler = (event) => this.onMapMouseMove(event));
    this.map.on("click", this.clickHandler = (event) => this.onMapClick(event));
    // Layer-scoped handlers, kept on the instance so teardown can detach them —
    // otherwise every re-entry stacks another copy and one drag fires N times.
    this.hitDownHandler = (event) => this.onRouteMouseDown(event);
    this.hitEnterHandler = () => {
      if (!this.dragContext) this.map.getCanvas().style.cursor = "grab";
    };
    this.hitLeaveHandler = () => {
      this.map.getCanvas().style.cursor = "";
    };
    this.map.on("mousedown", "planner-route-hit", this.hitDownHandler);
    this.map.on("mouseenter", "planner-route-hit", this.hitEnterHandler);
    this.map.on("mouseleave", "planner-route-hit", this.hitLeaveHandler);
  }

  onMapMouseMove(event) {
    this.cursorPoint = event.lngLat;
    this.updatePendingLine();
  }

  // Sequential waypoint placement (§5.1) — or POI placement when armed (§7).
  onMapClick(event) {
    if (this.poiArmed) {
      this.poiArmed = false;
      this.panel.classList.remove("mymap-planner--poi-armed");
      this.openPoiModal({ at: event.lngLat });
      return;
    }
    this.addWaypoint(event.lngLat.lat, event.lngLat.lng);
  }

  // Segment drag (§5.2): grab the line → a temporary Shaping Point appears
  // under the cursor, follows it, and the segment recalculates (debounced).
  // On drop the SP is persisted as part of the segment.
  onRouteMouseDown(event) {
    if (this.waypoints.length < 2) return;
    event.preventDefault();
    this.pushUndo();
    const segmentIndex = Number(event.features[0].properties.segment);
    const points = this.segments[segmentIndex].points;
    let nearest = { distance: Infinity, index: 0 };
    points.forEach((point, index) => {
      const distance = this.screenDistance(event.point, this.map.project(point));
      if (distance < nearest.distance) nearest = { distance, index };
    });
    const point = { lat: event.lngLat.lat, lon: event.lngLat.lng };
    this.dragContext = { segmentIndex, point, marker: this.makeShapingMarker(point) };
    this.map.getCanvas().style.cursor = "grabbing";
    this.map.dragPan.disable();

    const onMove = (moveEvent) => {
      this.dragContext.point.lat = moveEvent.lngLat.lat;
      this.dragContext.point.lon = moveEvent.lngLat.lng;
      this.dragContext.marker.setLngLat(moveEvent.lngLat);
      this.scheduleSegmentRecalc([segmentIndex]);
    };
    const onUp = () => {
      this.map.off("mousemove", onMove);
      this.map.off("mouseup", onUp);
      this.map.dragPan.enable();
      this.map.getCanvas().style.cursor = "";
      if (this.dragContext) {
        const context = this.dragContext;
        this.dragContext = null;
        context.marker.remove();
        (this.shaping[segmentIndex] = this.shaping[segmentIndex] || []).push(context.point);
        this.syncShapingMarkers();
        this.scheduleSegmentRecalc([segmentIndex], true);
      }
    };
    this.map.on("mousemove", onMove);
    this.map.on("mouseup", onUp);
  }

  screenDistance(a, b) {
    return Math.hypot(a.x - b.x, a.y - b.y);
  }

  makeShapingMarker(point) {
    const element = document.createElement("div");
    element.className = "planner-sp-marker";
    return new maplibregl.Marker({ element, anchor: "center" })
      .setLngLat([point.lon, point.lat])
      .addTo(this.map);
  }

  updatePendingLine() {
    const source = this.map.getSource("planner-pending");
    if (!source) return;
    const last = this.waypoints[this.waypoints.length - 1];
    const closed = this.loop && this.waypoints.length >= 2;
    if (!last || closed || !this.cursorPoint) {
      source.setData({ type: "FeatureCollection", features: [] });
      return;
    }
    source.setData({
      type: "FeatureCollection",
      features: [{
        type: "Feature",
        properties: {},
        geometry: { type: "LineString", coordinates: [[last.lon, last.lat], [this.cursorPoint.lng, this.cursorPoint.lat]] },
      }],
    });
  }

  updateRouteGeometry() {
    const source = this.map.getSource("planner-route");
    if (!source) return;
    const features = this.segments
      .filter((segment) => segment.points && segment.points.length >= 2)
      .map((segment) => ({
        type: "Feature",
        properties: { failed: segment.status === "failed", segment: this.segments.indexOf(segment) },
        geometry: { type: "LineString", coordinates: segment.points },
      }));
    source.setData({ type: "FeatureCollection", features });
  }

  // ---- markers -----------------------------------------------------------------

  // Numbered RW markers: drag to move (§5.3), right-click to delete.
  syncWaypointMarkers() {
    if (this.waypointMarkers) this.waypointMarkers.forEach((marker) => marker.remove());
    this.waypointMarkers = this.waypoints.map((waypoint, index) => {
      const element = document.createElement("div");
      element.className = "planner-marker";
      element.setAttribute("role", "button");
      element.setAttribute("tabindex", "0");
      element.setAttribute("aria-label", `Waypoint ${index + 1}: drag to move, right-click to delete`);
      element.textContent = String(index + 1);
      element.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        this.deleteWaypoint(index);
      });
      const marker = new maplibregl.Marker({ element, draggable: true, anchor: "center" })
        .setLngLat([waypoint.lon, waypoint.lat])
        .addTo(this.map);
      marker.on("dragstart", () => {
        this.pushUndo();
        this.map.getCanvas().style.cursor = "grabbing";
      });
      marker.on("dragend", () => {
        this.map.getCanvas().style.cursor = "";
        const lngLat = marker.getLngLat();
        this.moveWaypoint(index, lngLat.lat, lngLat.lng);
      });
      return marker;
    });
    this.syncShapingMarkers();
  }

  // SPs stay hidden unless their segment is being dragged (§3.3: not
  // user-facing waypoints); right-click removes the constraint (§5.2).
  syncShapingMarkers() {
    if (this.shapingMarkers) this.shapingMarkers.forEach((marker) => marker.remove());
    this.shapingMarkers = [];
    if (!this.dragContext) return;
    this.shaping.forEach((points) => {
      (points || []).forEach((point) => {
        const element = document.createElement("div");
        element.className = "planner-sp";
        element.title = "Shaping point — right-click to remove";
        element.addEventListener("contextmenu", (event) => {
          event.preventDefault();
          event.stopPropagation();
          this.removeShapingPoint(point);
        });
        const marker = new maplibregl.Marker({ element, anchor: "center" })
          .setLngLat([point.lon, point.lat])
          .addTo(this.map);
        this.shapingMarkers.push(marker);
      });
    });
  }

  // POI markers (§7): icon on the route, click opens the editor popup.
  syncPoiMarkers() {
    if (this.poiMarkers) this.poiMarkers.forEach((marker) => marker.remove());
    this.poiMarkers = this.pois.map((poi) => {
      const element = document.createElement("div");
      element.className = "planner-poi";
      element.title = poi.title || "Point of interest";
      const icon = document.createElement("span");
      icon.className = "material-symbols-outlined";
      icon.textContent = "flag";
      element.appendChild(icon);
      element.addEventListener("click", (event) => {
        event.stopPropagation();
        this.openPoiModal({ poi });
      });
      return new maplibregl.Marker({ element, anchor: "bottom" })
        .setLngLat([poi.lon, poi.lat])
        .addTo(this.map);
    });
  }

  // ---- POI modal (§7) -------------------------------------------------------------

  // Opens for: a new POI at +at+, an existing +poi+, or an RW conversion
  // (+waypointIndex+ — the POI inherits the RW's coordinates).
  openPoiModal({ poi, at, waypointIndex } = {}) {
    this.poiEditing = poi || null;
    // New POIs remember where they were placed (map click or RW position);
    // commitPoiModal reads the source when the modal is saved.
    this.pendingPoiPoint = poi
      ? null
      : (at ? { lat: at.lat, lon: at.lng !== undefined ? at.lng : at.lon } : null)
        || (waypointIndex !== undefined && waypointIndex !== null
          ? this.waypoints[waypointIndex]
          : null);
    this.poiWaypointIndex = waypointIndex === undefined ? null : waypointIndex;
    this.poiImageState = { signedId: null, url: poi ? poi.image_url : null, removed: false };
    this.dom.poiTitle.value = poi ? poi.title : "";
    this.dom.poiDescription.value = poi ? poi.description : "";
    this.dom.poiUrl.value = poi ? poi.external_url : "";
    this.dom.poiHeading.textContent = poi && poi.title ? poi.title : (poi ? "Point of interest" : "New point of interest");
    this.dom.poiSaveLabel.textContent = poi ? "Save POI" : "Add to Route";
    this.dom.poiUploadError.hidden = true;
    this.renderPoiImage();
    this.poiModalOpen = true;
    this.dom.poiModal.classList.add("is-open");
    this.dom.poiModal.setAttribute("aria-hidden", "false");
    this.dom.poiTitle.focus();
  }

  closePoiModal() {
    this.poiModalOpen = false;
    this.poiEditing = null;
    this.dom.poiModal.classList.remove("is-open");
    this.dom.poiModal.setAttribute("aria-hidden", "true");
  }

  // §7: POIs never affect routing — commit just stores the metadata.
  commitPoiModal() {
    const payload = {
      title: this.dom.poiTitle.value.trim(),
      description: this.dom.poiDescription.value.trim(),
      external_url: this.dom.poiUrl.value.trim(),
    };
    if (this.poiEditing) {
      Object.assign(this.poiEditing, payload);
      if (this.poiImageState.removed) this.poiEditing.image_url = null;
      else if (this.poiImageState.signedId) {
        this.poiEditing.image_url = this.poiImageState.url;
        this.poiEditing.image_signed_id = this.poiImageState.signedId;
      }
    } else {
      const source = this.poiWaypointIndex !== null
        ? this.waypoints[this.poiWaypointIndex]
        : this.pendingPoiPoint;
      this.pois.push({
        id: this.nextId(),
        lat: source ? source.lat : 0,
        lon: source ? source.lon : 0,
        ...payload,
        image_url: this.poiImageState.url,
        image_signed_id: this.poiImageState.signedId,
        waypoint_index: this.poiWaypointIndex,
      });
    }
    this.closePoiModal();
    this.syncPoiMarkers();
    this.renderWaypointList();
    this.renderButtons();
  }

  uploadPoiImage(event) {
    const file = event.target.files && event.target.files[0];
    if (!file) return;
    const body = new FormData();
    body.append("image", file);
    fetch(this.urls.poiImage, {
      method: "POST",
      headers: { "X-CSRF-Token": this.csrfToken(), Accept: "application/json" },
      body,
      credentials: "same-origin",
    })
      .then(async (response) => {
        const payload = await response.json();
        if (!response.ok) throw new Error(payload.error || "Upload failed.");
        this.poiImageState = { signedId: payload.signed_id, url: payload.url, removed: false };
        this.renderPoiImage();
      })
      .catch((error) => {
        this.dom.poiUploadError.textContent = error.message;
        this.dom.poiUploadError.hidden = false;
      })
      .finally(() => {
        event.target.value = "";
      });
  }

  clearPoiImage() {
    this.poiImageState = { signedId: null, url: null, removed: true };
    this.renderPoiImage();
  }

  renderPoiImage() {
    const visible = this.poiImageState.url && !this.poiImageState.removed;
    this.dom.poiImageWrap.hidden = !visible;
    if (visible) this.dom.poiImagePreview.src = this.poiImageState.url;
  }

  // ---- rendering -----------------------------------------------------------------

  renderAll() {
    this.updateRouteGeometry();
    this.updatePendingLine();
    this.renderStats();
    this.renderWaypointList();
    this.renderProfile();
    this.renderModeButtons();
    this.renderButtons();
  }

  renderModeButtons() {
    this.dom.profiles.forEach((button) => {
      button.classList.toggle("is-active", button.getAttribute("data-profile") === this.profile);
    });
    const label = this.dom["loop-label"];
    if (label) label.textContent = this.loop ? "Open Loop" : "Close Loop";
    this.dom.loop.classList.toggle("is-active", this.loop);
  }

  renderButtons() {
    this.dom.undo.disabled = this.undoStack.length === 0;
    this.dom.redo.disabled = this.redoStack.length === 0;
    // Save needs a finished route: every segment calculated at least once.
    this.dom.save.disabled = this.waypoints.length < 2 ||
      this.segments.length !== this.segmentCount() ||
      this.segments.some((segment) => !segment.points || segment.points.length < 2);
  }

  renderStats() {
    const distanceM = this.segments.reduce((total, segment) => total + (segment.distanceM || 0), 0);
    const timeS = this.segments.reduce((total, segment) => total + (segment.timeS || 0), 0);
    const elevations = this.combinedElevations();
    const deltas = elevations.length >= 2 ? elevationDeltas(elevations) : { gain: 0, loss: 0 };
    this.dom.statDistance.textContent = distanceM > 0 ? `${KM_FORMAT.format(distanceM / 1000)} km` : "—";
    this.dom.statElevation.textContent = deltas.gain > 0 ? `+${Math.round(deltas.gain)} m` : "—";
    this.dom.statTime.textContent = timeS > 0 ? formatDuration(timeS) : "—";
    this.dom.statPoints.textContent = INT_FORMAT.format(this.waypoints.length);
  }

  combinedElevations() {
    const elevations = [];
    this.segments.forEach((segment) => {
      (segment.points || []).forEach((point) => {
        if (point.length >= 3 && point[2] !== null && point[2] !== undefined) elevations.push(point[2]);
      });
    });
    return elevations;
  }

  // Cumulative kilometres at each waypoint (list subtitles + profile axis).
  waypointDistances() {
    const distances = [0];
    let total = 0;
    this.segments.forEach((segment, index) => {
      total += segment.distanceM || 0;
      if (index < this.waypoints.length - 1) distances.push(total);
    });
    return distances;
  }

  // The PLOTTED WAYPOINTS list (design's cue sheet): numbered rows with
  // distance/elevation subtitles, POI flag buttons and delete buttons.
  renderWaypointList() {
    const list = this.dom["waypoint-list"];
    list.textContent = "";
    const distances = this.waypointDistances();
    this.waypoints.forEach((waypoint, index) => {
      const row = document.createElement("div");
      row.className = "mymap-planner__row";
      const badge = document.createElement("span");
      badge.className = "mymap-planner__row-badge";
      badge.textContent = String(index + 1);
      row.appendChild(badge);
      const text = document.createElement("span");
      text.className = "mymap-planner__row-text";
      const title = document.createElement("span");
      title.className = "mymap-planner__row-title";
      title.textContent = index === 0 ? "Start" : (index === this.waypoints.length - 1 ? "Finish" : `Waypoint ${index + 1}`);
      text.appendChild(title);
      const subtitle = document.createElement("span");
      subtitle.className = "mymap-planner__row-sub t-code-sm c-tertiary";
      subtitle.textContent = `${KM_FORMAT.format(distances[index] / 1000)} km`;
      text.appendChild(subtitle);
      row.appendChild(text);
      row.appendChild(this.rowButton("flag", "Convert to POI", () => this.openPoiModal({
        lat: waypoint.lat,
        lon: waypoint.lon,
        waypointIndex: index,
      })));
      row.appendChild(this.rowButton("delete", "Delete waypoint", () => this.deleteWaypoint(index)));
      list.appendChild(row);
    });
    this.pois.forEach((poi) => {
      const row = document.createElement("div");
      row.className = "mymap-planner__row mymap-planner__row--poi";
      const badge = document.createElement("span");
      badge.className = "mymap-planner__row-badge mymap-planner__row-badge--poi";
      const icon = document.createElement("span");
      icon.className = "material-symbols-outlined";
      icon.textContent = "flag";
      badge.appendChild(icon);
      row.appendChild(badge);
      const text = document.createElement("span");
      text.className = "mymap-planner__row-text";
      const title = document.createElement("span");
      title.className = "mymap-planner__row-title";
      title.textContent = poi.title || "Point of interest";
      text.appendChild(title);
      const subtitle = document.createElement("span");
      subtitle.className = "mymap-planner__row-sub t-code-sm c-tertiary";
      subtitle.textContent = poi.external_url || "POI";
      text.appendChild(subtitle);
      row.appendChild(text);
      row.appendChild(this.rowButton("edit", "Edit POI", () => this.openPoiModal({ poi })));
      row.appendChild(this.rowButton("delete", "Delete POI", () => this.deletePoi(poi)));
      list.appendChild(row);
    });
    this.dom["list-hint"].hidden = this.waypoints.length > 0 || this.pois.length > 0;
  }

  rowButton(iconName, label, handler) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "mymap-planner__row-action";
    button.title = label;
    button.setAttribute("aria-label", label);
    const icon = document.createElement("span");
    icon.className = "material-symbols-outlined";
    icon.textContent = iconName;
    button.appendChild(icon);
    button.addEventListener("click", handler);
    return button;
  }

  // LIVE ALTITUDE PROFILE mini chart (design): a simple area+line SVG built
  // from the combined elevation series.
  renderProfile() {
    const points = [];
    this.segments.forEach((segment) => (segment.points || []).forEach((point) => points.push(point)));
    const elevated = points.filter((point) => point.length >= 3 && point[2] !== null && point[2] !== undefined);
    if (elevated.length < 2) {
      this.dom["profile-block"].hidden = true;
      return;
    }
    this.dom["profile-block"].hidden = false;
    const elevations = elevated.map((point) => point[2]);
    const max = Math.max(...elevations);
    const min = Math.min(...elevations);
    const span = Math.max(max - min, 1);
    const width = 300;
    const height = 56;
    const coords = elevations.map((ele, index) => {
      const x = (index / (elevations.length - 1)) * width;
      const y = height - ((ele - min) / span) * (height - 6) - 3;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    });
    this.dom["profile-line"].setAttribute("d", `M${coords.join(" L")}`);
    this.dom["profile-area"].setAttribute("d", `M0,${height} L${coords.join(" L")} L${width},${height} Z`);
    this.dom["profile-max"].textContent = `Max ${Math.round(max)} m`;
  }

  // ---- POI placement + deletion ---------------------------------------------------

  // Remove a shaping constraint and restore normal routing for its
  // segment (§5.2: "users must be able to remove shaping constraints").
  removeShapingPoint(point) {
    this.pushUndo();
    let segmentIndex = -1;
    this.shaping.forEach((points, index) => {
      const at = (points || []).indexOf(point);
      if (at >= 0) {
        points.splice(at, 1);
        segmentIndex = index;
      }
    });
    this.syncShapingMarkers();
    if (segmentIndex >= 0) this.scheduleSegmentRecalc([segmentIndex], true);
  }

  armPoiPlacement() {
    this.poiArmed = !this.poiArmed;
    this.panel.classList.toggle("mymap-planner--poi-armed", this.poiArmed);
  }

  deletePoi(poi) {
    this.pushUndo();
    this.pois = this.pois.filter((candidate) => candidate !== poi);
    this.syncPoiMarkers();
    this.renderWaypointList();
  }

  // ---- save / exit (§6.1/§6.2) ------------------------------------------------------

  // The editor state IS the save payload: RWs, SPs with their segment
  // associations, POIs, profile, per-segment geometry. The server validates
  // it, recomputes the stats and generates the GPX (Planner::RouteSaver).
  buildSavePayload() {
    const shaping = [];
    this.shaping.forEach((points, segmentIndex) => {
      (points || []).forEach((point, position) => {
        shaping.push({ segment_index: segmentIndex, position, lat: point.lat, lon: point.lon });
      });
    });
    return {
      route_id: this.routeId || undefined,
      title: this.title,
      profile: this.profile,
      loop: this.loop,
      waypoints: this.waypoints.map((point) => ({ lat: point.lat, lon: point.lon })),
      shaping_points: shaping,
      pois: this.pois.map((poi) => ({
        lat: poi.lat,
        lon: poi.lon,
        title: poi.title || null,
        description: poi.description || null,
        external_url: poi.external_url || null,
        image_signed_id: poi.image_signed_id || null,
        waypoint_index: poi.waypoint_index,
      })),
      segments: this.segments.map((segment) => ({
        points: segment.points,
        time_s: segment.timeS > 0 ? segment.timeS : null,
      })),
    };
  }

  async save() {
    if (this.waypoints.length < 2) {
      this.toast("Place at least two waypoints before saving.");
      return;
    }
    if (this.segments.some((segment) => !segment.points || segment.points.length < 2)) {
      this.toast("The route is still calculating — try again in a moment.");
      return;
    }
    this.dom.save.disabled = true;
    try {
      const response = await fetch(this.urls.save, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken(),
        },
        body: JSON.stringify({ state: this.buildSavePayload() }),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        const message = payload.errors && payload.errors.length
          ? payload.errors.join(" ")
          : (payload.error || "The route could not be saved.");
        throw new Error(message);
      }
      this.routeId = payload.id;
      this.persisted = deepClone(this.stateSnapshot());
      this.teardown();
      if (this.onSaved) this.onSaved(payload);
    } catch (error) {
      this.toast(error.message || "The route could not be saved.");
      this.dom.save.disabled = false;
    }
  }

  requestExit() {
    // §6.2: confirm when unsaved changes exist.
    if (this.isDirty()) {
      this.dom.confirm.hidden = false;
      return;
    }
    this.teardown();
    if (this.onExit) this.onExit({ discarded: false });
  }

  hideConfirm() {
    this.dom.confirm.hidden = true;
  }

  toast(message) {
    if (this.onToast) this.onToast(message);
  }

  // Center the camera on the drawn route (§2.2 edit entry lands where the
  // route lives, not at the default viewport).
  fitToRoute() {
    const coordinates = this.segments.flatMap((segment) => segment.points || [])
      .map((point) => [point[0], point[1]]);
    if (coordinates.length < 2) return;
    const bounds = coordinates.reduce(
      (accumulator, coordinate) => accumulator.extend(coordinate),
      new maplibregl.LngLatBounds(coordinates[0], coordinates[0]),
    );
    this.map.fitBounds(bounds, { padding: 120, maxZoom: 15, duration: 0 });
  }

  // Remove the planner from the map and the document. Sources/layers stay
  // (empty) — re-adding them on re-entry races the base style, so
  // addMapLayers() is idempotent instead. Every handler bound here is
  // detached; missing one means a re-entry runs the action twice.
  teardown() {
    this.active = false;
    if (this.calcTimer) {
      clearTimeout(this.calcTimer);
      this.calcTimer = null;
    }
    this.queuedSegments = new Set();
    if (this.waypointMarkers) this.waypointMarkers.forEach((marker) => marker.remove());
    if (this.poiMarkers) this.poiMarkers.forEach((marker) => marker.remove());
    if (this.shapingMarkers) this.shapingMarkers.forEach((marker) => marker.remove());
    if (this.dragContext && this.dragContext.marker) this.dragContext.marker.remove();
    this.dragContext = null;
    if (this.keyHandler) document.removeEventListener("keydown", this.keyHandler);
    if (this.moveHandler) this.map.off("mousemove", this.moveHandler);
    if (this.clickHandler) this.map.off("click", this.clickHandler);
    if (this.outHandler) this.map.off("mouseout", this.outHandler);
    if (this.hitDownHandler) this.map.off("mousedown", "planner-route-hit", this.hitDownHandler);
    if (this.hitEnterHandler) this.map.off("mouseenter", "planner-route-hit", this.hitEnterHandler);
    if (this.hitLeaveHandler) this.map.off("mouseleave", "planner-route-hit", this.hitLeaveHandler);
    if (this.map.getSource("planner-route")) this.map.getSource("planner-route").setData({ type: "FeatureCollection", features: [] });
    if (this.map.getSource("planner-pending")) this.map.getSource("planner-pending").setData({ type: "FeatureCollection", features: [] });
  }
}
