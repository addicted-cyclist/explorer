import maplibregl from "maplibre-gl";

// Route Planner engine (technote.ROUTE-DRAW.md) — the editing brain behind
// the My Map "Draw new route" mode. Owns the editor session (Routing
// Waypoints, POIs, routing profile, per-segment calculated geometry), the
// undo/redo stacks and all map interaction. Routing is delegated to Rails
// (POST /planner/calculate → Routing::BrouterClient): the frontend NEVER
// talks to BRouter directly (§10.4). Design reference:
// design-refs/stitch_explorer_v.0.15.
//
// §12 model: the route is a pure sequence of plotted waypoints. There are no
// hidden shaping points — dragging the line plants a new plotted waypoint,
// clicking a waypoint selects it so the dashed pending line starts there and
// the next map click inserts right after it, and marker drags move waypoints.
//
// Recalculation discipline (§10.6): every request carries a monotonically
// increasing revision — stale responses are dropped; requests are debounced
// during drags, capped at MAX_INFLIGHT concurrent, and a failure keeps the
// last valid geometry (only the affected segment turns red).

const ROUTE_COLOR = "#000dff";
const ROUTE_CASING = "#ffffff";
const FAILED_COLOR = "#b91c1c";
// The route's direction cue (§5.1): an EVEN dashed overlay — one dash length
// everywhere — in blues that run deep → light along every segment, so the
// line still reads start → finish. Deliberately static: no animation, the
// dashes and their colors never move. Failed segments are excluded by the
// layer's filter, keeping §10.6's red state undecorated.
const ROUTE_FLOW_DASH = [2, 2]; // dash/gap in line-width multiples — equal by design
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

// Haversine length of a [lon, lat(, ele)] polyline in metres. The editor boot
// state ships point arrays only (no engine stats), so booted segments derive
// their panel distance from the geometry itself until a recalculation
// replaces it — the readouts stay honest from the moment the editor opens.
function polylineDistanceM(points) {
  const EARTH_RADIUS_M = 6371000;
  let total = 0;
  for (let index = 1; index < points.length; index += 1) {
    const [lon1, lat1] = points[index - 1];
    const [lon2, lat2] = points[index];
    const phi1 = (lat1 * Math.PI) / 180;
    const phi2 = (lat2 * Math.PI) / 180;
    const dPhi = ((lat2 - lat1) * Math.PI) / 180;
    const dLambda = ((lon2 - lon1) * Math.PI) / 180;
    const a =
      Math.sin(dPhi / 2) ** 2 +
      Math.cos(phi1) * Math.cos(phi2) * Math.sin(dLambda / 2) ** 2;
    total += 2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(a));
  }
  return total;
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
    this.waypoints = (state.waypoints || []).map((point) => ({
      lat: point.lat,
      lon: point.lon,
    }));
    // Defensive fallback — the server seeds editor waypoints itself now
    // (sliced tracks, RW at every cut). A state that still arrives with one
    // full-track segment and no RWs gets its start/end seeded here so every
    // planner tool works (technote §2.2).
    if (
      this.waypoints.length === 0 &&
      (state.segments || []).length === 1 &&
      (state.segments[0] || []).length >= 2
    ) {
      const track = state.segments[0];
      this.waypoints = [
        { lat: track[0][1], lon: track[0][0] },
        { lat: track[track.length - 1][1], lon: track[track.length - 1][0] },
      ];
    }
    this.pois = (state.pois || []).map((poi) => ({
      id: this.nextId(),
      lat: poi.lat,
      lon: poi.lon,
      title: poi.title || "",
      description: poi.description || "",
      external_url: poi.external_url || "",
      image_url: poi.image_url || null,
      image_signed_id: null,
      waypoint_index: Number.isFinite(Number(poi.waypoint_index))
        ? Number(poi.waypoint_index)
        : null,
    }));
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
    this.flowTimer = null;
    this.dragContext = null;
    this.draggingMarker = false;
    this.suppressNextMapClick = false;
    this.selectedWaypointIndex = null;
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
    if (this.segments.some((segment) => segment.status === "pending"))
      this.recalculateAll();
  }

  nextId() {
    this.idCounter += 1;
    return `${Date.now().toString(36)}-${this.idCounter}`;
  }

  buildInitialSegments(storedSegments) {
    const count = this.segmentCount();
    if (count === 0) return [];
    // A booted segment carries its geometry but no engine stats — derive the
    // panel's distance from the points until a recalculation replaces them.
    const bootSegment = (points) => {
      const usable = points && points.length >= 2;
      return {
        points: usable ? points : [],
        distanceM: usable ? polylineDistanceM(points) : 0,
        ascendM: 0,
        timeS: 0,
        status: usable ? "ok" : "pending",
      };
    };
    if (storedSegments.length === count) {
      return storedSegments.map((points) => bootSegment(points));
    }
    // Uploaded route: its whole stored track is segment 0's geometry; the
    // RW seeds above make it editable without a recalculation.
    if (count === 1 && storedSegments.length === 1) {
      return [bootSegment(storedSegments[0])];
    }
    return Array.from({ length: count }, () => ({
      points: [],
      distanceM: 0,
      ascendM: 0,
      timeS: 0,
      status: "pending",
    }));
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
    this.pois = deepClone(snapshot.pois);
    // Selection is transient UI state — a restored index may point at a
    // different waypoint after undo/redo.
    this.selectedWaypointIndex = null;
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
    return (
      JSON.stringify(this.stateSnapshot()) !== JSON.stringify(this.persisted)
    );
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
      button.addEventListener("click", () =>
        this.setProfile(button.getAttribute("data-profile")),
      );
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
    this.dom["confirm-stay"].addEventListener("click", () =>
      this.hideConfirm(),
    );
    this.dom["confirm-discard"].addEventListener("click", () => {
      this.hideConfirm();
      this.teardown();
      if (this.onExit) this.onExit({ discarded: true });
    });
    this.keyHandler = (event) => this.onKeydown(event);
    document.addEventListener("keydown", this.keyHandler);
    // NOTE: the map handlers (click/mousemove/mouseout) deliberately do NOT
    // bind here — addMapLayers() is their single registration site. Binding
    // them in both methods stacked two listeners per session: every click ran
    // onMapClick twice (duplicate waypoints at the same coordinates) and
    // teardown could only detach the last-assigned closure.
    // POI modal (§7).
    this.dom["poi-form"].addEventListener("submit", (event) => {
      event.preventDefault();
      this.commitPoiModal();
    });
    this.dom["poi-cancel"].addEventListener("click", () =>
      this.closePoiModal(),
    );
    this.dom["poi-modal-close"].addEventListener("click", () =>
      this.closePoiModal(),
    );
    this.dom["poi-modal-backdrop"].addEventListener("click", () =>
      this.closePoiModal(),
    );
    this.dom["poi-image"].addEventListener("change", (event) =>
      this.uploadPoiImage(event),
    );
    this.dom["poi-image-remove"].addEventListener("click", () =>
      this.clearPoiImage(),
    );
  }

  onKeydown(event) {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z") {
      event.preventDefault();
      if (event.shiftKey) this.redo();
      else this.undo();
    } else if (event.key === "Escape" && !this.poiModalOpen) {
      // Esc first releases the waypoint selection (§12.1), only then exits.
      if (this.selectedWaypointIndex !== null) {
        this.selectWaypoint(this.selectedWaypointIndex);
        return;
      }
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

  // Align segments with the RW sequence; existing geometry is kept
  // so unaffected segments are never recalculated (§5.3).
  reconcileSegments() {
    const count = this.segmentCount();
    const next = [];
    for (let index = 0; index < count; index += 1) {
      next.push(
        this.segments[index] || {
          points: [],
          distanceM: 0,
          ascendM: 0,
          timeS: 0,
          status: "pending",
        },
      );
    }
    this.segments = next;
  }

  // ---- recalculation pipeline (§10.6) ----------------------------------------

  // Coalescing + debounce + concurrency cap: at most MAX_INFLIGHT requests
  // to Rails; the newest control-point set per segment wins; drags debounce.
  scheduleSegmentRecalc(indexes, immediate) {
    const valid = [...new Set(indexes || [])].filter(
      (index) => index >= 0 && index < this.segmentCount(),
    );
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
    const to =
      index === this.waypoints.length - 1
        ? this.loop
          ? this.waypoints[0]
          : null
        : this.waypoints[index + 1];
    if (!from || !to) return;
    // The segment's two plotted waypoints; while its line is being dragged
    // (§12.3) the temp point rides between them so the preview bends along
    // real roads under the cursor — not just on drop.
    const points = [[from.lat, from.lon]];
    if (this.dragContext && this.dragContext.segmentIndex === index)
      points.push([this.dragContext.point.lat, this.dragContext.point.lon]);
    points.push([to.lat, to.lon]);
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
      .then((response) =>
        response.json().then((payload) => ({ ok: response.ok, payload })),
      )
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
    for (let index = 0; index < this.segmentCount(); index += 1)
      indexes.push(index);
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

  // RW deletion (§5.3): the two adjoining segments merge into one across the
  // remaining neighbours, and only the merged span recalculates. In loop mode
  // the closing segment also loses an endpoint when the first or last RW goes
  // — it must recalculate too, or the saver's endpoint check would reject the
  // next save. POIs linked to the RW keep coordinates and metadata (§3.4).
  deleteWaypoint(index) {
    if (this.waypoints.length <= 2) {
      this.clearRoute();
      return;
    }
    this.pushUndo();
    const last = this.waypoints.length - 1;
    const wasLast = index === last;
    this.waypoints.splice(index, 1);
    // Drop the segment that can no longer exist: for a middle deletion the
    // right adjoining one (the left keeps its slot and recalculates across
    // the merged span); for the first RW, segment 0 (the old second segment
    // is already the valid merged one); for the last RW, the final chain
    // segment. All later segments shift with the splice.
    this.segments.splice(wasLast ? index - 1 : index, 1);
    if (this.selectedWaypointIndex !== null) {
      if (this.selectedWaypointIndex === index) this.selectedWaypointIndex = null;
      else if (this.selectedWaypointIndex > index) this.selectedWaypointIndex -= 1;
    }
    this.pois.forEach((poi) => {
      if (poi.waypoint_index === index) poi.waypoint_index = null;
      else if (poi.waypoint_index > index) poi.waypoint_index -= 1;
    });
    this.syncWaypointMarkers();
    this.syncPoiMarkers();
    this.renderWaypointList();
    this.renderStats();
    const indexes = new Set();
    if (index > 0 && index < last) indexes.add(index - 1);
    if (this.loop && (index === 0 || wasLast))
      indexes.add(this.segmentCount() - 1);
    this.scheduleSegmentRecalc([...indexes], true);
  }

  // RW move (marker drag): only the segments that reference the moved RW
  // recalculate (§5.3) — in loop mode that includes the closing segment.
  moveWaypoint(index, lat, lon) {
    const waypoint = this.waypoints[index];
    if (!waypoint) return;
    waypoint.lat = lat;
    waypoint.lon = lon;
    this.scheduleSegmentRecalc(this.waypointSegmentIndexes(index), true);
    this.renderStats();
    this.renderWaypointList();
  }

  // Indexes of the segments whose geometry depends on RW[index]: the chain
  // segments on both sides, plus the loop closing segment whenever the moved
  // RW is one of its endpoints (§5.6 — RW[0] is its target, the last RW its
  // source). Missing the closing segment here used to leave stale geometry
  // that the saver's endpoint check rejects on save.
  waypointSegmentIndexes(index) {
    const indexes = new Set();
    if (index > 0) indexes.add(index - 1);
    if (index < this.waypoints.length - 1) indexes.add(index);
    if (this.loop && (index === 0 || index === this.waypoints.length - 1))
      indexes.add(this.segmentCount() - 1);
    return [...indexes];
  }

  // §12.1: clicking a plotted waypoint selects it — the dashed pending line
  // then starts there (updatePendingLine) and the next map click inserts a
  // waypoint right after it. Clicking the selected one again deselects.
  selectWaypoint(index) {
    this.selectedWaypointIndex =
      this.selectedWaypointIndex === index ? null : index;
    this.syncWaypointMarkers();
    this.renderWaypointList();
    this.updatePendingLine();
  }

  // §12.1: insert a plotted waypoint directly after the selected one. The
  // old segment RW[index]→old target splits in two — it keeps its slot
  // (recalculates down to the new waypoint) and a pending segment splices in
  // after it (new waypoint → old target); both recalculate with the active
  // profile. The selection follows the new waypoint, so the next click keeps
  // extending the route from it. Loop closing geometry shifts with the splice
  // and stays valid unless the insert lands inside the closing segment.
  insertWaypointAfter(index, lat, lon) {
    if (this.waypoints.length >= MAX_WAYPOINTS) {
      this.toast("A route can hold at most 100 waypoints.");
      return;
    }
    this.pushUndo();
    this.waypoints.splice(index + 1, 0, { lat, lon });
    this.segments.splice(index + 1, 0, {
      points: [],
      distanceM: 0,
      ascendM: 0,
      timeS: 0,
      status: "pending",
    });
    this.selectedWaypointIndex = index + 1;
    this.syncWaypointMarkers();
    this.renderWaypointList();
    this.renderStats();
    this.scheduleSegmentRecalc([index, index + 1], true);
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
  // continuity, everything recalculates (oneways make the reversed ride a
  // different problem).
  reverseRoute() {
    if (this.waypoints.length < 2) return;
    this.pushUndo();
    this.waypoints.reverse();
    this.selectedWaypointIndex = null;
    const count = this.segmentCount();
    const segments = [];
    for (let index = 0; index < count; index += 1) {
      const source = this.segments[count - 1 - index];
      segments.push({
        points: source ? [...source.points].reverse() : [],
        distanceM: source ? source.distanceM : 0,
        ascendM: source ? source.ascendM : 0,
        timeS: source ? source.timeS : 0,
        status: source ? source.status : "pending",
      });
    }
    this.segments = segments;
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
    this.pois = [];
    this.segments = [];
    this.loop = false;
    this.selectedWaypointIndex = null;
    this.syncWaypointMarkers();
    this.syncPoiMarkers();
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
      // lineMetrics: per-vertex line-progress — REQUIRED for the flow
      // overlay's line-gradient (the direction shimmer) to render at all.
      this.map.addSource("planner-route", {
        type: "geojson",
        data: empty,
        lineMetrics: true,
      });
      this.map.addSource("planner-pending", {
        type: "geojson",
        data: empty,
        lineMetrics: true,
      });
    }
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
          "line-color": [
            "case",
            ["==", ["get", "failed"], true],
            FAILED_COLOR,
            ROUTE_COLOR,
          ],
          "line-width": 4.5,
        },
      },
      {
        // Wide transparent hit-area so the line is easy to catch for a drag.
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
        paint: {
          "line-color": ROUTE_COLOR,
          "line-width": 3,
          "line-dasharray": ROUTE_FLOW_DASH,
        },
      },
      {
        // Blue route path. Failed
        // segments are excluded so §10.6's red failure state reads undecorated.
        id: "planner-route",
        type: "line",
        source: "planner-route",
        filter: ["!", ["get", "failed"]],
        layout: { "line-cap": "round", "line-join": "round" },
        paint: {
          "line-width": 5,
          "line-color": ROUTE_COLOR,
        },
      },
    ];

    definitions.forEach((definition) => {
      if (this.map.getLayer(definition.id)) return;
      // No beforeId — append to the very top of the stack (see the comment
      // above the definitions: bridges must never paint over the route).
      this.map.addLayer(definition);
    });

    // ALL map handlers bind HERE — one registration site per planner session.
    // They are kept on the instance so teardown can detach them; binding the
    // same event twice (this used to happen with bindDom) makes MapLibre fire
    // both listeners — one click produced two waypoints.
    this.map.on(
      "mousemove",
      (this.moveHandler = (event) => this.onMapMouseMove(event)),
    );
    this.map.on(
      "click",
      (this.clickHandler = (event) => this.onMapClick(event)),
    );
    this.map.on(
      "mouseout",
      (this.outHandler = () => {
        this.cursorPoint = null;
        this.updatePendingLine();
      }),
    );
    // Layer-scoped handlers, kept on the instance so teardown can detach them —
    // otherwise every re-entry stacks another copy and one drag fires N times.
    this.hitDownHandler = (event) => this.onRouteMouseDown(event);
    this.hitEnterHandler = () => {
      // The editor draws: pointer everywhere — never the browsing hand.
      if (!this.dragContext) this.map.getCanvas().style.cursor = "pointer";
    };
    this.hitLeaveHandler = () => {
      this.map.getCanvas().style.cursor = "pointer";
    };
    this.map.on("mousedown", "planner-route-hit", this.hitDownHandler);
    this.map.on("mouseenter", "planner-route-hit", this.hitEnterHandler);
    this.map.on("mouseleave", "planner-route-hit", this.hitLeaveHandler);
    // Planning mode's base cursor: the map is a click-to-place surface.
    this.map.getCanvas().style.cursor = "pointer";
  }

  // The shimmer is static by design (§5.1): no timers, no repaints — the
  // dashed overlay and its direction gradient are set once in addMapLayers.

  onMapMouseMove(event) {
    this.cursorPoint = event.lngLat;
    this.updatePendingLine();
  }

  // Sequential waypoint placement (§5.1) — or POI placement when armed (§7).
  // With a selected waypoint (§12.1) the click inserts right after it instead
  // of appending at the route's end.
  onMapClick(event) {
    // A real marker drag ends with its closing click landing on the canvas
    // (the marker is pointer-events:none mid-drag) — that click must not
    // add or insert a waypoint at the drop point.
    if (this.suppressNextMapClick) return;
    if (this.poiArmed) {
      this.poiArmed = false;
      this.panel.classList.remove("mymap-planner--poi-armed");
      this.openPoiModal({ at: event.lngLat });
      return;
    }
    if (this.selectedWaypointIndex !== null) {
      this.insertWaypointAfter(
        this.selectedWaypointIndex,
        event.lngLat.lat,
        event.lngLat.lng,
      );
      return;
    }
    this.addWaypoint(event.lngLat.lat, event.lngLat.lng);
  }

  // Segment drag (§12.3): dragging the line plants a NEW plotted waypoint at
  // the drop point — the route then leads n-1 → new n → n+1, both halves
  // recalculated with the active profile. The temp marker follows the cursor
  // while requestSegment splices it into the preview, so the line bends along
  // real roads during the drag (debounced, §10.6). A plain click (mousedown +
  // up, no movement) commits nothing — waypoints come from real drags.
  onRouteMouseDown(event) {
    if (this.waypoints.length < 2) return;
    if (this.waypoints.length >= MAX_WAYPOINTS) {
      this.toast("A route can hold at most 100 waypoints.");
      return;
    }
    // Marker mousedowns bubble to the map and match the route hit-area
    // (every plotted waypoint sits ON its line): dragging a waypoint must
    // never also start a segment drag that plants a second waypoint.
    const target = event.originalEvent && event.originalEvent.target;
    if (target && target.closest && target.closest(".planner-marker, .planner-poi"))
      return;
    event.preventDefault();
    const segmentIndex = Number(event.features[0].properties.segment);
    const point = { lat: event.lngLat.lat, lon: event.lngLat.lng };
    this.dragContext = {
      segmentIndex,
      point,
      marker: this.makeGhostWaypointMarker(point),
    };
    this.map.getCanvas().style.cursor = "move";
    this.map.dragPan.disable();

    let moved = false;
    const onMove = (moveEvent) => {
      if (!moved) {
        // The undo snapshot belongs to the first real movement — the mousedown
        // itself changes nothing, and a no-op entry would make Ctrl+Z feel
        // broken (§5.4).
        moved = true;
        this.pushUndo();
      }
      this.dragContext.point.lat = moveEvent.lngLat.lat;
      this.dragContext.point.lon = moveEvent.lngLat.lng;
      this.dragContext.marker.setLngLat(moveEvent.lngLat);
      this.scheduleSegmentRecalc([segmentIndex]);
    };
    const onUp = () => {
      this.map.off("mousemove", onMove);
      this.map.off("mouseup", onUp);
      this.map.dragPan.enable();
      this.map.getCanvas().style.cursor = "pointer";
      if (moved && this.dragContext) {
        const context = this.dragContext;
        this.dragContext = null;
        context.marker.remove();
        this.commitDraggedWaypoint(context.segmentIndex, context.point);
      } else {
        this.dragContext = null;
      }
    };
    // Kept on the instance so teardown can detach them: an exit mid-drag
    // (Escape while holding) must not leave ghost handlers behind — they
    // would crash on the cleared dragContext and keep dragPan disabled.
    this.dragMoveHandler = onMove;
    this.dragUpHandler = onUp;
    this.map.on("mousemove", onMove);
    this.map.on("mouseup", onUp);
  }

  // Commit the drag (§12.3): the new plotted waypoint splits the dragged
  // segment — it keeps its slot (recalculates down to the new waypoint) and
  // a pending segment splices in after it (new waypoint → old target); both
  // recalculate immediately. A drag on the loop's closing segment appends the
  // waypoint as the new last RW, re-basing the closing segment on it.
  commitDraggedWaypoint(segmentIndex, point) {
    this.waypoints.splice(segmentIndex + 1, 0, {
      lat: point.lat,
      lon: point.lon,
    });
    this.segments.splice(segmentIndex + 1, 0, {
      points: [],
      distanceM: 0,
      ascendM: 0,
      timeS: 0,
      status: "pending",
    });
    this.syncWaypointMarkers();
    this.renderWaypointList();
    this.renderStats();
    this.scheduleSegmentRecalc([segmentIndex, segmentIndex + 1], true);
  }

  // Transient drag marker: a waypoint-shaped ghost without a number — the
  // number is assigned when the drag commits a real plotted waypoint.
  makeGhostWaypointMarker(point) {
    const element = document.createElement("div");
    element.className = "planner-marker planner-marker--ghost";
    return new maplibregl.Marker({ element, anchor: "center" })
      .setLngLat([point.lon, point.lat])
      .addTo(this.map);
  }

  // The dashed rubber band (§12.1): from the SELECTED waypoint when one is
  // selected, otherwise from the last one. Hidden while the route is closed
  // (loop) or while a drag owns the cursor.
  updatePendingLine() {
    const source = this.map.getSource("planner-pending");
    if (!source) return;
    const origin =
      this.selectedWaypointIndex !== null
        ? this.waypoints[this.selectedWaypointIndex]
        : this.waypoints[this.waypoints.length - 1];
    const closed = this.loop && this.waypoints.length >= 2;
    if (
      !origin ||
      closed ||
      !this.cursorPoint ||
      this.dragContext ||
      this.draggingMarker
    ) {
      source.setData({ type: "FeatureCollection", features: [] });
      return;
    }
    source.setData({
      type: "FeatureCollection",
      features: [
        {
          type: "Feature",
          properties: {},
          geometry: {
            type: "LineString",
            coordinates: [
              [origin.lon, origin.lat],
              [this.cursorPoint.lng, this.cursorPoint.lat],
            ],
          },
        },
      ],
    });
  }

  updateRouteGeometry() {
    const source = this.map.getSource("planner-route");
    if (!source) return;
    const features = this.segments
      .filter((segment) => segment.points && segment.points.length >= 2)
      .map((segment) => ({
        type: "Feature",
        properties: {
          failed: segment.status === "failed",
          segment: this.segments.indexOf(segment),
        },
        geometry: { type: "LineString", coordinates: segment.points },
      }));
    source.setData({ type: "FeatureCollection", features });
  }

  // ---- markers -----------------------------------------------------------------

  // Numbered RW markers: click to select (§12.1), drag to move (§5.3),
  // right-click to delete. The whole set re-renders on every change —
  // numbers and the selected state are positional.
  syncWaypointMarkers() {
    if (this.waypointMarkers)
      this.waypointMarkers.forEach((marker) => marker.remove());
    this.waypointMarkers = this.waypoints.map((waypoint, index) => {
      const element = document.createElement("div");
      element.className = "planner-marker";
      if (index === this.selectedWaypointIndex)
        element.classList.add("planner-marker--selected");
      element.setAttribute("role", "button");
      element.setAttribute("tabindex", "0");
      element.setAttribute(
        "aria-pressed",
        index === this.selectedWaypointIndex ? "true" : "false",
      );
      element.setAttribute(
        "aria-label",
        `Waypoint ${index + 1}: click to select, drag to move, right-click to delete`,
      );
      element.textContent = String(index + 1);
      element.addEventListener("click", (event) => {
        // Marker elements sit above the canvas: without stopPropagation the
        // click would bubble to the map and place another waypoint.
        event.stopPropagation();
        this.selectWaypoint(index);
      });
      element.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        this.deleteWaypoint(index);
      });
      // clickTolerance: MapLibre's marker default is 0 — ANY cursor jitter
      // during a press became a drag (the element click never fired), which
      // made the waypoint impossible to select. 10px keeps human clicks
      // clicks and real moves drags.
      const marker = new maplibregl.Marker({
        element,
        draggable: true,
        anchor: "center",
        clickTolerance: 10,
      })
        .setLngLat([waypoint.lon, waypoint.lat])
        .addTo(this.map);
      marker.on("dragstart", () => {
        this.pushUndo();
        this.draggingMarker = true;
        this.updatePendingLine();
        this.map.getCanvas().style.cursor = "move";
      });
      marker.on("dragend", () => {
        this.draggingMarker = false;
        this.map.getCanvas().style.cursor = "pointer";
        // A drag's closing click lands on the canvas, not on this element —
        // drop it so moving a waypoint never adds/inserts another one.
        this.suppressNextMapClick = true;
        setTimeout(() => {
          this.suppressNextMapClick = false;
        }, 0);
        const lngLat = marker.getLngLat();
        this.moveWaypoint(index, lngLat.lat, lngLat.lng);
      });
      return marker;
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
      : (at
          ? { lat: at.lat, lon: at.lng !== undefined ? at.lng : at.lon }
          : null) ||
        (waypointIndex !== undefined && waypointIndex !== null
          ? this.waypoints[waypointIndex]
          : null);
    this.poiWaypointIndex = waypointIndex === undefined ? null : waypointIndex;
    this.poiImageState = {
      signedId: null,
      url: poi ? poi.image_url : null,
      removed: false,
    };
    this.dom.poiTitle.value = poi ? poi.title : "";
    this.dom.poiDescription.value = poi ? poi.description : "";
    this.dom.poiUrl.value = poi ? poi.external_url : "";
    this.dom.poiHeading.textContent =
      poi && poi.title
        ? poi.title
        : poi
          ? "Point of interest"
          : "New point of interest";
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
      const source =
        this.poiWaypointIndex !== null
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
        this.poiImageState = {
          signedId: payload.signed_id,
          url: payload.url,
          removed: false,
        };
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
      button.classList.toggle(
        "is-active",
        button.getAttribute("data-profile") === this.profile,
      );
    });
    const label = this.dom["loop-label"];
    if (label) label.textContent = this.loop ? "Unloop" : "Loop";
    this.dom.loop.classList.toggle("is-active", this.loop);
  }

  renderButtons() {
    this.dom.undo.disabled = this.undoStack.length === 0;
    this.dom.redo.disabled = this.redoStack.length === 0;
    // Save needs a finished route: every segment calculated at least once.
    this.dom.save.disabled =
      this.waypoints.length < 2 ||
      this.segments.length !== this.segmentCount() ||
      this.segments.some(
        (segment) => !segment.points || segment.points.length < 2,
      );
  }

  renderStats() {
    const distanceM = this.segments.reduce(
      (total, segment) => total + (segment.distanceM || 0),
      0,
    );
    const timeS = this.segments.reduce(
      (total, segment) => total + (segment.timeS || 0),
      0,
    );
    const elevations = this.combinedElevations();
    const deltas =
      elevations.length >= 2
        ? elevationDeltas(elevations)
        : { gain: 0, loss: 0 };
    this.dom.statDistance.textContent =
      distanceM > 0 ? `${KM_FORMAT.format(distanceM / 1000)} km` : "—";
    this.dom.statElevation.textContent =
      deltas.gain > 0 ? `+${Math.round(deltas.gain)} m` : "—";
    this.dom.statTime.textContent = timeS > 0 ? formatDuration(timeS) : "—";
    this.dom.statPoints.textContent = INT_FORMAT.format(this.waypoints.length);
  }

  combinedElevations() {
    const elevations = [];
    this.segments.forEach((segment) => {
      (segment.points || []).forEach((point) => {
        if (point.length >= 3 && point[2] !== null && point[2] !== undefined)
          elevations.push(point[2]);
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
      row.classList.toggle(
        "mymap-planner__row--selected",
        index === this.selectedWaypointIndex,
      );
      // §12.1: rows mirror the map markers — clicking a row selects the RW
      // (clicking the selected row again deselects), the dashed pending line
      // then starts there and the next map click inserts right after it.
      // The flag/delete buttons keep their own handlers and must not toggle.
      row.setAttribute("role", "button");
      row.setAttribute("tabindex", "0");
      row.setAttribute(
        "aria-pressed",
        index === this.selectedWaypointIndex ? "true" : "false",
      );
      row.setAttribute(
        "aria-label",
        `Waypoint ${index + 1}: click to select`,
      );
      row.addEventListener("click", (event) => {
        if (event.target.closest(".mymap-planner__row-action")) return;
        this.selectWaypoint(index);
      });
      row.addEventListener("keydown", (event) => {
        if (event.target.closest(".mymap-planner__row-action")) return;
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        this.selectWaypoint(index);
      });
      const badge = document.createElement("span");
      badge.className = "mymap-planner__row-badge";
      badge.textContent = String(index + 1);
      row.appendChild(badge);
      const text = document.createElement("span");
      text.className = "mymap-planner__row-text";
      const title = document.createElement("span");
      title.className = "mymap-planner__row-title";
      title.textContent =
        index === 0
          ? "Start"
          : index === this.waypoints.length - 1
            ? "Finish"
            : `Waypoint ${index + 1}`;
      text.appendChild(title);
      const subtitle = document.createElement("span");
      subtitle.className = "mymap-planner__row-sub t-code-sm c-tertiary";
      subtitle.textContent = `${KM_FORMAT.format(distances[index] / 1000)} km`;
      text.appendChild(subtitle);
      row.appendChild(text);
      row.appendChild(
        this.rowButton("flag", "Convert to POI", () =>
          this.openPoiModal({
            lat: waypoint.lat,
            lon: waypoint.lon,
            waypointIndex: index,
          }),
        ),
      );
      row.appendChild(
        this.rowButton("delete", "Delete waypoint", () =>
          this.deleteWaypoint(index),
        ),
      );
      list.appendChild(row);
    });
    this.pois.forEach((poi) => {
      const row = document.createElement("div");
      row.className = "mymap-planner__row mymap-planner__row--poi";
      const badge = document.createElement("span");
      badge.className =
        "mymap-planner__row-badge mymap-planner__row-badge--poi";
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
      row.appendChild(
        this.rowButton("edit", "Edit POI", () => this.openPoiModal({ poi })),
      );
      row.appendChild(
        this.rowButton("delete", "Delete POI", () => this.deletePoi(poi)),
      );
      list.appendChild(row);
    });
    this.dom["list-hint"].hidden =
      this.waypoints.length > 0 || this.pois.length > 0;
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
    this.segments.forEach((segment) =>
      (segment.points || []).forEach((point) => points.push(point)),
    );
    const elevated = points.filter(
      (point) =>
        point.length >= 3 && point[2] !== null && point[2] !== undefined,
    );
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
    this.dom["profile-area"].setAttribute(
      "d",
      `M0,${height} L${coords.join(" L")} L${width},${height} Z`,
    );
    this.dom["profile-max"].textContent = `Max ${Math.round(max)} m`;
  }

  // ---- POI placement + deletion ---------------------------------------------------

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

  // The editor state IS the save payload: RWs, POIs, profile, per-segment
  // geometry (§12: no shaping points exist anymore). The server validates
  // it, recomputes the stats and generates the GPX (Planner::RouteSaver).
  buildSavePayload() {
    return {
      route_id: this.routeId || undefined,
      title: this.title,
      profile: this.profile,
      loop: this.loop,
      waypoints: this.waypoints.map((point) => ({
        lat: point.lat,
        lon: point.lon,
      })),
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
    if (
      this.segments.some(
        (segment) => !segment.points || segment.points.length < 2,
      )
    ) {
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
        const message =
          payload.errors && payload.errors.length
            ? payload.errors.join(" ")
            : payload.error || "The route could not be saved.";
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
    const coordinates = this.segments
      .flatMap((segment) => segment.points || [])
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
    // The editor owned the canvas cursor (pointer/move); give the browsing
    // default back (its own hover handlers take over from here).
    this.map.getCanvas().style.cursor = "";
    this.queuedSegments = new Set();
    if (this.waypointMarkers)
      this.waypointMarkers.forEach((marker) => marker.remove());
    if (this.poiMarkers) this.poiMarkers.forEach((marker) => marker.remove());
    if (this.dragContext && this.dragContext.marker)
      this.dragContext.marker.remove();
    this.dragContext = null;
    if (this.keyHandler)
      document.removeEventListener("keydown", this.keyHandler);
    if (this.moveHandler) this.map.off("mousemove", this.moveHandler);
    if (this.clickHandler) this.map.off("click", this.clickHandler);
    if (this.outHandler) this.map.off("mouseout", this.outHandler);
    // Transient segment-drag handlers (bound in onRouteMouseDown): an exit
    // mid-drag must not leave them behind — onMove would crash on the
    // cleared dragContext, and dragPan would stay disabled until the next
    // click. Re-enable panning unconditionally: the planner owned it.
    if (this.dragMoveHandler) this.map.off("mousemove", this.dragMoveHandler);
    if (this.dragUpHandler) this.map.off("mouseup", this.dragUpHandler);
    this.dragMoveHandler = null;
    this.dragUpHandler = null;
    this.map.dragPan.enable();
    if (this.hitDownHandler)
      this.map.off("mousedown", "planner-route-hit", this.hitDownHandler);
    if (this.hitEnterHandler)
      this.map.off("mouseenter", "planner-route-hit", this.hitEnterHandler);
    if (this.hitLeaveHandler)
      this.map.off("mouseleave", "planner-route-hit", this.hitLeaveHandler);
    if (this.map.getSource("planner-route"))
      this.map
        .getSource("planner-route")
        .setData({ type: "FeatureCollection", features: [] });
    if (this.map.getSource("planner-pending"))
      this.map
        .getSource("planner-pending")
        .setData({ type: "FeatureCollection", features: [] });
  }
}
