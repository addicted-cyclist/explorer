import { Controller } from "@hotwired/stimulus";
import maplibregl from "maplibre-gl";

const KM_FORMAT = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });
const INT_FORMAT = new Intl.NumberFormat("en-US");

// My Map page (technote.MYMAP-FEATURE.md): MapLibre rendering, route data
// loading and interaction. Rails (MapsController + Map::RouteFeature) owns
// authentication, authorization and the GeoJSON payloads; this controller
// only consumes the two endpoints and never touches provider specifics —
// the base-map style arrives as one config value resolved by
// config/initializers/map.rb, and route sources/layers are added on top of
// whatever style loaded (§7: route rendering is provider-independent).
//
// Stage 1 responsibilities:
//   * draw own routes (all, private included) and other users' public routes
//   * refresh public routes on viewport change — debounced, in-flight-safe,
//     and delta-loaded: responses merge by id and only not-yet-loaded routes
//     are requested, so covered areas never re-download (§5.2)
//   * scope pills (All / My Routes / Public), routes drawer, status pill
//   * click/select: highlight + popup with stats, elevation profile and the
//     links to the existing detail page / GPX download (§6.1)
//   * initial viewport: fit my routes (zoom-capped) → persisted view →
//     browser geolocation → configured default (§3.1)
export default class MyMapController extends Controller {
  static targets = [
    "canvas", "scopePill", "allCount", "ownCount", "publicCount",
    "drawer", "drawerToggle", "drawerCount", "cardList", "drawerEmpty",
    "cardTemplate", "status", "popup", "popupDot", "popupBadge",
    "popupTitle", "popupDescription", "popupDistance", "popupElevation",
    "popupSpeed", "popupDuration", "profileBlock", "profileMax",
    "profileArea", "profileLine", "profileMarker", "profileMid",
    "profileEnd", "popupLink", "popupDownload",
  ];

  static values = {
    config: Object,
    ownUrl: String,
    publicUrl: String,
  };

  // Debounce for viewport-driven public fetches (§5.2).
  static REFRESH_DEBOUNCE_MS = 400;
  // Fetch a little beyond the visible area so slow pans don't refetch on
  // every stop.
  static BOUNDS_MARGIN_RATIO = 0.2;
  // Below this zoom a public fetch is pure waste: the padded viewport covers
  // a whole region and the §5.1 cap only ever returns a truncated head of
  // it, replaced the moment the rider zooms in. Overridable per environment
  // from the server config (map_frontend_config.publicMinZoom).
  static PUBLIC_ROUTES_MIN_ZOOM = 8.5;
  // Delta-loading caps: the largest exclude_ids list sent in one request,
  // and how many fetched rectangles the coverage skip remembers. Both are
  // efficiency hints only — an overflow id simply ships back again and
  // dedupes in the merge; a pruned rectangle merely refetches its region.
  static EXCLUDED_IDS_CAP = 1000;
  static COVERED_BOUNDS_CAP = 24;
  // The endpoint can return up to 500 public routes; the drawer lists the
  // first 200 and says so, keeping DOM rebuilds cheap on every refresh.
  static DRAWER_MAX_CARDS = 200;
  static VIEW_STORAGE_KEY = "explorer:map-view";

  static EMPTY_COLLECTION = { type: "FeatureCollection", features: [] };

  // Provider-less final fallback (used when the resolved config styleUrl is
  // falsy): a valid style object with no sources — route layers still render
  // over a plain background so the page stays usable and offline-safe.
  static FALLBACK_STYLE = {
    version: 8,
    sources: {},
    layers: [
      {
        id: "background",
        type: "background",
        paint: { "background-color": "#e8e8e8" },
      },
    ],
  };

  connect() {
    this.config = this.configValue;
    this.ownFeatures = [];
    this.publicFeatures = [];
    this.publicTruncated = false;
    this.activeScope = "all";
    this.selectedId = null;
    this.initialViewportResolved = false;
    this.lastFetchedKey = null;
    // Key of the request currently in flight (committed synchronously — see
    // loadPublicRoutes), plus the delta-loading state: merged public
    // features by id and the padded rectangles already fetched.
    this.inFlightKey = null;
    this.publicById = new Map();
    this.coveredBounds = [];
    this.refreshTimer = null;
    this.abortController = null;
    // True once the map's "load" event ran and the route sources/layers
    // exist. Everything that writes into those sources is gated on it, so a
    // broken or slow base-map style degrades to console warnings instead of
    // setData TypeErrors (the map surface must stay alive even then).
    this.layersReady = false;

    this.buildMap();
    this.ro = new ResizeObserver(() => {
      // MapLibre needs an explicit resize when its container changes size
      // (responsive layout shifts, drawer collapse, browser UI hiding).
      if (this.map) this.map.resize();
    });
    this.ro.observe(this.canvasTarget);

    // On phones the drawer starts collapsed so the map gets the room.
    if (window.matchMedia("(max-width: 1023px)").matches) {
      this.collapseDrawer();
    }
  }

  disconnect() {
    // Turbo navigations must not leak the WebGL context, the observers, the
    // pending fetch or the debounce timer.
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    if (this.abortController) this.abortController.abort();
    if (this.ro) this.ro.disconnect();
    if (this.map) {
      this.map.remove();
      this.map = null;
    }
  }

  buildMap() {
    const center = this.config.defaultCenter || [ 0, 0 ];
    this.map = new maplibregl.Map({
      container: this.canvasTarget,
      style: this.config.styleUrl || MyMapController.FALLBACK_STYLE,
      center: center,
      zoom: this.config.defaultZoom || 12,
      attributionControl: false,
    });
    this.map.addControl(new maplibregl.NavigationControl({ visualizePitch: false }), "top-right");
    this.map.addControl(this.fitRoutesControl(), "top-right");
    this.map.addControl(new maplibregl.GeolocateControl({
      positionOptions: { enableHighAccuracy: false },
      trackUserLocation: false,
    }), "top-right");
    this.map.addControl(new maplibregl.FullscreenControl(), "top-right");
    this.map.addControl(new maplibregl.ScaleControl({ unit: "metric" }), "bottom-right");
    this.map.addControl(
      new maplibregl.AttributionControl({ customAttribution: this.config.customAttribution || [] }),
      "bottom-right"
    );

    this.map.on("load", () => this.onMapLoad());
    this.map.on("moveend", () => this.onMoveEnd());
    this.map.on("error", (event) => {
      // Tile/style/network hiccups must not throw; surface in console only.
      if (event && event.error) console.warn("Map error:", event.error.message || event.error);
    });
  }

  onMapLoad() {
    this.addRouteLayers();
    this.bindClicks();

    // Selection highlight draws above both route sources (§6.1).
    this.map.addSource("route-highlight", { type: "geojson", data: MyMapController.EMPTY_COLLECTION });
    this.map.addLayer({
      id: "highlight-casing",
      type: "line",
      source: "route-highlight",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#ffffff", "line-width": 9 },
    });
    this.map.addLayer({
      id: "highlight-line",
      type: "line",
      source: "route-highlight",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#0f172a", "line-width": 5 },
    });

    this.layersReady = true;
    this.loadOwnRoutes();
  }

  // Route GeoJSON sources/layers — deliberately plain LineString styling so
  // rendering is independent of the base-map provider (technote §6/§7: no
  // provider feature ids, source layers or road attributes involved).
  addRouteLayers() {
    this.map.addSource("own-routes", { type: "geojson", data: MyMapController.EMPTY_COLLECTION });
    this.map.addSource("public-routes", { type: "geojson", data: MyMapController.EMPTY_COLLECTION });

    // Public routes under the viewer's own (scarlet #e11d48 vs emerald
    // #10b981 — the two visibility classes the technote asks to distinguish).
    this.map.addLayer(this.lineLayer("public-casing", "public-routes", "#ffffff", 6.5));
    this.map.addLayer(this.lineLayer("public-line", "public-routes", "#10b981", 3.5));
    this.map.addLayer(this.lineLayer("own-casing", "own-routes", "#ffffff", 7.5));
    this.map.addLayer(this.lineLayer("own-line", "own-routes", "#e11d48", 4.5));
  }

  lineLayer(id, source, color, width) {
    return {
      id: id,
      type: "line",
      source: source,
      layout: { "line-cap": "round", "line-join": "round" },
      paint: {
        "line-color": color,
        "line-width": width,
        "line-opacity": source === "public-routes" ? 0.9 : 1,
      },
    };
  }

  bindClicks() {
    const layers = [ "own-line", "public-line", "own-casing", "public-casing" ];
    this.map.on("click", layers, (event) => {
      const feature = event.features && event.features[0];
      if (feature) this.selectRoute(Number(feature.properties.id));
    });
    this.map.on("mouseenter", layers, () => {
      this.map.getCanvas().style.cursor = "pointer";
    });
    this.map.on("mouseleave", layers, () => {
      this.map.getCanvas().style.cursor = "";
    });
  }

  // "Return to my routes" button (technote §3.2) as a small custom control.
  fitRoutesControl() {
    const controller = this;
    return {
      onAdd() {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "maplibregl-ctrl-icon maplibregl-ctrl-my-routes";
        button.setAttribute("aria-label", "Show my routes");
        button.title = "Show my routes";
        button.addEventListener("click", () => controller.fitToOwnRoutes(true));
        const group = document.createElement("div");
        group.className = "maplibregl-ctrl maplibregl-ctrl-group";
        group.appendChild(button);
        return group;
      },
      onRemove() {},
    };
  }

  // ---- data loading -------------------------------------------------------

  async loadOwnRoutes() {
    try {
      const response = await fetch(this.ownUrlValue, { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      this.ownFeatures = payload.features || [];
      const source = this.map && this.map.getSource("own-routes");
      if (source) {
        source.setData({ type: "FeatureCollection", features: this.ownFeatures });
      } else {
        console.warn("Own routes: map route layers are missing — base style may have failed to load.");
      }
      this.updateCounts();
      this.renderDrawer();
      this.resolveInitialViewport();
    } catch (error) {
      // Own routes failing (offline, 500) must not kill the page: keep the
      // default viewport and the public flow alive.
      console.warn("Own routes failed to load:", error);
      this.setStatus("Couldn't load your routes — reload the page to retry.", "error");
      this.resolveInitialViewport();
    }
  }

  // Public routes for the current viewport (technote §5.1), delta-loaded:
  // debounced via onMoveEnd, aborted when superseded, and never repeated
  // for ground the client already holds.
  //  * below PUBLIC_ROUTES_MIN_ZOOM the viewport spans a whole region and
  //    the §5.1 cap only ever returns a truncated head — don't fetch.
  //  * a padded viewport fully inside an earlier fetched rectangle is all
  //    client-side data already — don't fetch.
  //  * otherwise the request carries the merged ids as exclude_ids so the
  //    payload ships only routes still missing.
  // Responses are MERGED by id, never replaced: well-trodden areas cost zero
  // requests and zero bytes on every revisit.
  async loadPublicRoutes(bounds) {
    if (!this.map || !bounds) return;

    if (this.map.getZoom() < this.publicMinZoom()) {
      // Keep whatever is drawn; only settle the pill when it isn't holding
      // an error the user may still want to click-retry.
      if (!this.statusTarget.classList.contains("is-error")) {
        this.setStatus(this.statusCounts(), "");
      }
      return;
    }

    const padded = this.padBounds(bounds, MyMapController.BOUNDS_MARGIN_RATIO);
    if (this.isCovered(padded)) return;

    const key = [ padded.west, padded.south, padded.east, padded.north ]
      .map((value) => value.toFixed(2)).join(",");
    if (key === this.lastFetchedKey || key === this.inFlightKey) return;

    if (this.abortController) this.abortController.abort();
    this.abortController = new AbortController();
    // Committed synchronously, not after the response lands: the old code
    // committed only on completion, so with a slow endpoint every extra
    // moveend aborted and refired the very same viewport endlessly.
    this.inFlightKey = key;
    this.setStatus("Updating public routes…", "loading");

    try {
      const params = new URLSearchParams({
        west: padded.west, south: padded.south, east: padded.east, north: padded.north,
      });
      const excluded = this.publicExcludeIds();
      if (excluded.length) params.set("exclude_ids", excluded.join(","));

      const response = await fetch(`${this.publicUrlValue}?${params}`, {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal,
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();

      const source = this.map && this.map.getSource("public-routes");
      if (!source) {
        // Defensive (layers vanished → base style reloaded/failed): surface a
        // readable status, keep the viewport key uncommitted so the next pan
        // or the click-to-retry refetches instead of drawing nothing.
        console.warn("Public routes: map route layers are missing — base style may have failed to load.");
        this.inFlightKey = null;
        this.setStatus("Base map failed to load — click to retry.", "error");
        return;
      }
      this.mergePublicFeatures(payload.features || []);
      this.publicTruncated = Boolean(payload.truncated);
      source.setData({
        type: "FeatureCollection", features: this.publicFeatures,
      });
      this.coveredBounds.push(padded);
      if (this.coveredBounds.length > MyMapController.COVERED_BOUNDS_CAP) {
        this.coveredBounds.shift();
      }
      this.lastFetchedKey = key;
      this.inFlightKey = null;
      this.updateCounts();
      this.renderDrawer();
      this.setStatus(this.statusCounts(), "");
    } catch (error) {
      if (error.name === "AbortError") return; // superseded by a newer viewport
      this.inFlightKey = null;
      console.warn("Public routes failed to load:", error);
      this.setStatus("Public routes failed to load — click to retry.", "error");
    }
  }

  retryPublic() {
    if (!this.statusTarget.classList.contains("is-error")) return;
    this.lastFetchedKey = null;
    this.loadPublicRoutes(this.map.getBounds());
  }

  // ---- viewport → fetch cycle (§5.2) ---------------------------------------

  onMoveEnd() {
    // MapLibre also fires moveend for the initial camera settle, before (or
    // — when the base style fails to load — instead of) "load": a fetch
    // scheduled then would setData into sources that don't exist yet. The
    // initial-viewport chain (loadOwnRoutes → resolveInitialViewport) seeds
    // the first public fetch once layers are ready, so skipping here costs
    // nothing.
    if (!this.layersReady) return;
    this.persistViewport();
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      if (this.map) this.loadPublicRoutes(this.map.getBounds());
    }, MyMapController.REFRESH_DEBOUNCE_MS);
  }

  // Expanded bounds: routes just past the viewport edge are already on
  // screen when the user pans one step further — fewer refetches.
  padBounds(bounds, ratio) {
    const west = bounds.getWest();
    const south = bounds.getSouth();
    const east = bounds.getEast();
    const north = bounds.getNorth();
    const latPad = Math.max((north - south) * ratio, 0.02);
    const lonPad = Math.max((east - west) * ratio, 0.02);
    return {
      west: west - lonPad,
      south: Math.max(south - latPad, -90),
      east: east + lonPad,
      north: Math.min(north + latPad, 90),
    };
  }

  // ---- delta-loading helpers (§5.2) ---------------------------------------

  // Zoom threshold from the server config (config/initializers/map.rb →
  // map_frontend_config), with the built-in default as fallback.
  publicMinZoom() {
    return this.config.publicMinZoom || MyMapController.PUBLIC_ROUTES_MIN_ZOOM;
  }

  // True when +padded+ sits wholly inside a rectangle fetched before — every
  // public route intersecting it is already in publicById, so a request
  // would only re-download data the map already shows.
  isCovered(padded) {
    return this.coveredBounds.some((rect) =>
      padded.west >= rect.west && padded.south >= rect.south &&
      padded.east <= rect.east && padded.north <= rect.north);
  }

  // The ids to exclude from the next request: everything already merged,
  // capped to the most recent EXCLUDED_IDS_CAP so the URL stays bounded on
  // far-roaming sessions (Map keys keep insertion order — oldest first,
  // so the tail is what was loaded most recently).
  publicExcludeIds() {
    const ids = Array.from(this.publicById.keys());
    return ids.length > MyMapController.EXCLUDED_IDS_CAP
      ? ids.slice(-MyMapController.EXCLUDED_IDS_CAP)
      : ids;
  }

  // Merge +features+ into the public store by id and rebuild the derived
  // array consumed by the layers, drawer and counts.
  mergePublicFeatures(features) {
    features.forEach((feature) => {
      const id = feature.properties && feature.properties.id;
      if (id === null || id === undefined) return;
      this.publicById.set(id, feature);
    });
    this.publicFeatures = Array.from(this.publicById.values());
  }

  // ---- initial viewport (technote §3.1) -------------------------------------

  resolveInitialViewport() {
    if (this.viewportResolved) return;
    this.viewportResolved = true;

    const bounds = this.ownRoutesBounds();
    if (bounds) {
      // Own routes win; maxZoom keeps tiny tracks from blowing the map up
      // (§3.1: "avoid excessive zoom levels for very small extents").
      // The public fetch rides the fit transition's own moveend so it
      // queries the FINAL bounds — an immediate getBounds() raced the
      // animation and fetched the wrong, pre-fit region on page load.
      this.map.once("moveend", () => this.loadPublicRoutes(this.map.getBounds()));
      this.map.fitBounds(bounds, { padding: 64, maxZoom: 14, duration: 800 });
      return;
    }

    // No routes: a persisted viewport beats geolocation beats the default
    // (which the map was initialized with, so failure paths change nothing).
    if (this.restorePersistedViewport()) {
      this.loadPublicRoutes(this.map.getBounds());
      return;
    }
    this.requestGeolocation();
    this.loadPublicRoutes(this.map.getBounds());
  }

  ownRoutesBounds() {
    const bounds = new maplibregl.LngLatBounds();
    let any = false;
    this.ownFeatures.forEach((feature) => {
      const box = feature.properties && feature.properties.bounds;
      if (!box) return;
      bounds.extend([ box[0], box[1] ]);
      bounds.extend([ box[2], box[3] ]);
      any = true;
    });
    return any ? bounds : null;
  }

  // "Return to my routes / reset" control action (technote §3.2).
  fitToOwnRoutes(fly) {
    const bounds = this.ownRoutesBounds();
    if (bounds) {
      this.map.fitBounds(bounds, { padding: 64, maxZoom: 14, duration: fly ? 800 : 0 });
    } else {
      this.map.jumpTo({
        center: this.configValue.defaultCenter,
        zoom: this.configValue.defaultZoom,
      });
    }
  }

  restorePersistedViewport() {
    try {
      const saved = JSON.parse(window.localStorage.getItem(MyMapController.VIEW_STORAGE_KEY));
      if (!saved || !Array.isArray(saved.c) || typeof saved.z !== "number") return false;
      this.map.jumpTo({ center: saved.c, zoom: saved.z });
      return true;
    } catch (_error) {
      return false;
    }
  }

  persistViewport() {
    // Only moves after the initial viewport resolved persist — the initial
    // fit/jump must not corrupt the restore chain's priority order.
    if (!this.viewportResolved || !this.map) return;
    try {
      const center = this.map.getCenter();
      window.localStorage.setItem(
        MyMapController.VIEW_STORAGE_KEY,
        JSON.stringify({ c: [ center.lng, center.lat ], z: this.map.getZoom() })
      );
    } catch (_error) {
      // Private mode / quota: persistence is best-effort only.
    }
  }

  // Browser geolocation (technote §3.1: optional, requires permission).
  // The map already shows the configured default, so denial simply keeps
  // it there; the Geolocation API needs HTTPS or localhost.
  requestGeolocation() {
    if (!("geolocation" in navigator)) return;
    navigator.geolocation.getCurrentPosition(
      (position) => {
        if (!this.map) return;
        this.map.flyTo({
          center: [ position.coords.longitude, position.coords.latitude ],
          zoom: this.configValue.defaultZoom,
          duration: 1200,
        });
      },
      () => {}, // denied / unavailable / timeout → stay on the default
      { enableHighAccuracy: false, timeout: 8000, maximumAge: 300000 }
    );
  }

  // ---- selection + popup (technote §6.1) -------------------------------------

  findFeature(id) {
    return (
      this.ownFeatures.find((feature) => feature.properties.id === id) ||
      this.publicFeatures.find((feature) => feature.properties.id === id) ||
      null
    );
  }

  selectRoute(id) {
    const feature = this.findFeature(id);
    if (!feature) return;

    this.selectedId = id;
    const highlight = this.map.getSource("route-highlight");
    if (highlight) highlight.setData({ type: "FeatureCollection", features: [ feature ] });
    this.renderPopup(feature);
    this.renderDrawer(); // re-mark the selected card
  }

  closePopup() {
    this.selectedId = null;
    this.popupTarget.hidden = true;
    const highlight = this.map && this.map.getSource("route-highlight");
    if (highlight) highlight.setData(MyMapController.EMPTY_COLLECTION);
    this.renderDrawer();
  }

  renderPopup(feature) {
    const properties = feature.properties;
    const own = Boolean(properties.own);

    this.popupDotTarget.classList.toggle("mymap-popup__dot--public", !own);
    this.popupBadgeTarget.classList.toggle("mymap-popup__badge--public", !own);
    this.popupBadgeTarget.textContent = own
      ? `Your route • ${properties.public ? "Public" : "Private"}`
      : "Public route";
    this.popupTitleTarget.textContent = properties.title || "Untitled Route";

    if (properties.description) {
      this.popupDescriptionTarget.textContent = properties.description;
      this.popupDescriptionTarget.hidden = false;
    } else {
      this.popupDescriptionTarget.hidden = true;
    }

    this.popupDistanceTarget.textContent = this.formatDistance(properties.distance);
    this.popupElevationTarget.textContent = this.formatElevation(properties.elevation_gain);
    this.popupSpeedTarget.textContent = this.formatSpeed(properties.avg_speed_kmh);
    this.popupDurationTarget.textContent = this.formatDuration(properties.duration);

    this.popupLinkTarget.href = properties.url || "#";
    this.popupDownloadTarget.href = properties.download_url || "#";

    this.renderProfile(properties.elevation_profile);
    this.popupTarget.hidden = false;
  }

  // Small SVG elevation chart from the server-provided [distance_m, ele_m]
  // buckets; hidden entirely when the GPX carried no elevations.
  renderProfile(profile) {
    if (!profile || profile.length < 2) {
      this.profileBlockTarget.hidden = true;
      return;
    }
    const width = 300;
    const height = 80;
    const pad = 3;
    const distances = profile.map((pair) => pair[0]);
    const elevations = profile.map((pair) => pair[1]);
    const maxDistance = distances[distances.length - 1] || 1;
    const minEle = Math.min(...elevations);
    const maxEle = Math.max(...elevations);
    const span = Math.max(maxEle - minEle, 1);
    const x = (distance) => pad + (distance / maxDistance) * (width - pad * 2);
    const y = (ele) => height - pad - ((ele - minEle) / span) * (height - pad * 2 - 4);

    let line = `M ${x(distances[0]).toFixed(1)} ${y(elevations[0]).toFixed(1)}`;
    for (let i = 1; i < distances.length; i += 1) {
      line += ` L ${x(distances[i]).toFixed(1)} ${y(elevations[i]).toFixed(1)}`;
    }
    this.profileLineTarget.setAttribute("d", line);
    this.profileAreaTarget.setAttribute(
      "d",
      `${line} L ${x(maxDistance).toFixed(1)} ${height - pad} L ${pad} ${height - pad} Z`
    );

    let maxIndex = 0;
    elevations.forEach((ele, index) => {
      if (ele > elevations[maxIndex]) maxIndex = index;
    });
    this.profileMarkerTarget.setAttribute("cx", x(distances[maxIndex]).toFixed(1));
    this.profileMarkerTarget.setAttribute("cy", y(elevations[maxIndex]).toFixed(1));

    this.profileMaxTarget.textContent = `${INT_FORMAT.format(maxEle)} m`;
    this.profileMidTarget.textContent = `${KM_FORMAT.format(maxDistance / 2000)} km`;
    this.profileEndTarget.textContent = `${KM_FORMAT.format(maxDistance / 1000)} km`;
    this.profileBlockTarget.hidden = false;
  }

  // ---- drawer ----------------------------------------------------------------

  toggleDrawer() {
    this.drawerTarget.classList.toggle("is-collapsed");
    const collapsed = this.drawerTarget.classList.contains("is-collapsed");
    this.drawerToggleTarget.setAttribute("aria-label", collapsed ? "Expand routes panel" : "Collapse routes panel");
    this.drawerToggleTarget.setAttribute("aria-expanded", String(!collapsed));
    this.drawerToggleTarget.querySelector(".material-symbols-outlined").textContent =
      collapsed ? "menu" : "close";
  }

  collapseDrawer() {
    if (!this.drawerTarget.classList.contains("is-collapsed")) this.toggleDrawer();
  }

  visibleFeatures() {
    if (this.activeScope === "own") return this.ownFeatures;
    if (this.activeScope === "public") return this.publicFeatures;
    return this.ownFeatures.concat(this.publicFeatures);
  }

  renderDrawer() {
    const features = this.visibleFeatures();
    this.cardListTarget.replaceChildren();

    const shown = features.slice(0, MyMapController.DRAWER_MAX_CARDS);
    shown.forEach((feature) => this.cardListTarget.appendChild(this.buildCard(feature)));

    if (features.length > shown.length) {
      const note = document.createElement("p");
      note.className = "mymap-drawer__more t-code-sm c-tertiary";
      note.textContent = `…and ${INT_FORMAT.format(features.length - shown.length)} more on the map`;
      this.cardListTarget.appendChild(note);
    }

    this.drawerCountTarget.textContent = INT_FORMAT.format(features.length);
    this.drawerEmptyTarget.hidden = features.length !== 0;
  }

  buildCard(feature) {
    const properties = feature.properties;
    const card = this.cardTemplateTarget.content.firstElementChild.cloneNode(true);

    card.dataset.routeId = properties.id;
    card.classList.add(properties.own ? "is-own" : "is-public");
    card.classList.toggle("is-selected", properties.id === this.selectedId);

    card.querySelector("[data-card-field=sport]").textContent = properties.sport_type || "Ride";
    card.querySelector("[data-card-field=tier]").textContent = properties.tier || "";
    card.querySelector("[data-card-field=title]").textContent = properties.title || "Untitled Route";
    card.querySelector("[data-card-field=distance]").textContent = this.formatDistance(properties.distance);
    card.querySelector("[data-card-field=elevation]").textContent = this.formatElevation(properties.elevation_gain);
    card.querySelector("[data-card-field=duration]").textContent = this.formatDuration(properties.duration);

    const img = card.querySelector(".mymap-card__thumb-img");
    const fallback = card.querySelector(".mymap-card__thumb-fallback");
    if (properties.thumb_url) {
      img.src = properties.thumb_url;
      img.hidden = false;
      fallback.hidden = true;
    }

    const select = () => {
      this.selectRoute(properties.id);
      const box = properties.bounds;
      if (box) {
        this.map.fitBounds(
          [ [ box[0], box[1] ], [ box[2], box[3] ] ],
          { padding: 64, maxZoom: 14, duration: 800 }
        );
      }
    };
    card.addEventListener("click", select);
    card.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        select();
      }
    });
    return card;
  }

  // ---- scope pills, counts, status pill ---------------------------------------

  setScope(event) {
    this.activeScope = event.currentTarget.dataset.scope || "all";
    this.scopePillTargets.forEach((pill) => {
      pill.classList.toggle("is-active", pill === event.currentTarget);
    });
    this.applyScopeToLayers();
    this.renderDrawer();
  }

  applyScopeToLayers() {
    const visibility = (ownLayer) => {
      if (this.activeScope === "all") return "visible";
      return (this.activeScope === "own") === ownLayer ? "visible" : "none";
    };
    if (!this.map || !this.map.isStyleLoaded()) return;
    this.map.setLayoutProperty("own-line", "visibility", visibility(true));
    this.map.setLayoutProperty("own-casing", "visibility", visibility(true));
    this.map.setLayoutProperty("public-line", "visibility", visibility(false));
    this.map.setLayoutProperty("public-casing", "visibility", visibility(false));
  }

  updateCounts() {
    const publicCount = this.publicFeatures.length + (this.publicTruncated ? 500 : 0);
    this.ownCountTarget.textContent = INT_FORMAT.format(this.ownFeatures.length);
    this.publicCountTarget.textContent = publicCount > 500 ? "500+" : INT_FORMAT.format(publicCount);
    this.allCountTarget.textContent = INT_FORMAT.format(this.ownFeatures.length + this.publicFeatures.length);
  }

  statusCounts() {
    const parts = [
      `${INT_FORMAT.format(this.ownFeatures.length)} yours`,
      `${INT_FORMAT.format(this.publicFeatures.length)} public`,
    ];
    // Truncation now counts only routes the client hasn't loaded yet
    // (exclude_ids deltas): the honest cue is "zoom in", not "showing 500".
    const suffix = this.publicTruncated ? " (more public in view — zoom in to load)" : "";
    return `${INT_FORMAT.format(this.ownFeatures.length + this.publicFeatures.length)} routes in view (${parts.join(", ")})${suffix}`;
  }

  setStatus(text, tone) {
    const status = this.statusTarget;
    status.hidden = false;
    status.textContent = text;
    status.classList.toggle("is-loading", tone === "loading");
    status.classList.toggle("is-error", tone === "error");
    if (tone === "") {
      this.applyScopeToLayers();
    }
  }

  // ---- formatters (client-side mirrors of the library-card helpers) -----------

  formatDistance(km) {
    if (km === null || km === undefined) return "—";
    return `${KM_FORMAT.format(km)} km`;
  }

  formatElevation(meters) {
    if (!meters) return "—";
    return `+${INT_FORMAT.format(Math.round(meters))} m`;
  }

  formatSpeed(kmh) {
    if (kmh === null || kmh === undefined) return "—";
    return `${KM_FORMAT.format(kmh)} km/h`;
  }

  formatDuration(seconds) {
    if (!seconds) return "—";
    const hours = Math.round(seconds / 3600);
    const minutes = Math.round((seconds % 3600) / 60);
    if (seconds >= 3600) return `${hours}h ${minutes}m`;
    return `${minutes} min`;
  }
}
