import { Controller } from "@hotwired/stimulus";
import maplibregl from "maplibre-gl";
import { captureRouteThumbs } from "../map/route_thumb_capture";

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
//   * draw own routes (private included) and other users' public routes,
//     both loaded per viewport and merged client-side, so previously
//     fetched areas stay cached (§5.1/§5.2)
//   * direction chevrons along the SELECTED route show travel direction (the
//     coordinate order of the stored track) — screen-pixel spacing keeps the
//     cue sparse zoomed out, and zooming in re-places glyphs so any viewport
//     stretch of the line keeps an arrow in view; canvas-generated, no
//     provider sprite (§7: rendering stays provider-independent)
//   * refresh own + public routes on viewport change — debounced, in-flight-
//     safe, and delta-loaded: responses merge by id and only not-yet-loaded
//     routes are requested, so covered areas never re-download
//   * the "Found Routes" drawer, scope pills (All / My Routes / Public) and
//     status pill count only routes intersecting the CURRENT viewport; the
//     map keeps drawing everything already fetched so revisits are instant
//   * location chip: "City, Region, Country" for the viewport center via
//     the reverse-geocoder endpoint (Photon server-side), refreshed on
//     every settled camera move
//   * click/select: highlight + popup with stats, elevation profile and the
//     links to the existing detail page / GPX download (§6.1)
//   * initial viewport: my most-ridden place (zoom-capped) → persisted view →
//     browser geolocation → configured default (§3.1)
export default class MyMapController extends Controller {
  static targets = [
    "stage",
    "canvas",
    "locationLabel",
    "scopePill",
    "allCount",
    "ownCount",
    "publicCount",
    "drawer",
    "drawerToggle",
    "drawerCount",
    "cardList",
    "drawerEmpty",
    "cardTemplate",
    "status",
    "popup",
    "popupDot",
    "popupBadge",
    "popupTitle",
    "popupDescription",
    "popupDistance",
    "popupElevation",
    "popupSpeed",
    "popupDuration",
    "profileBlock",
    "profileMax",
    "profileArea",
    "profileLine",
    "profileMarker",
    "profileMid",
    "profileEnd",
    "popupLink",
    "popupDownload",
  ];

  static values = {
    config: Object,
    // The most-ridden place ([w, s, e, n]) computed server-side from the
    // full own-routes library (MapsController#show → Map::OwnRoutesHotspot);
    // [] when no parsed routes. The initial viewport (§3.1) and the heart
    // control (§3.2) land here — own routes load per viewport now, so the
    // client can no longer derive the hotspot itself.
    hotspotBounds: Array,
    ownUrl: String,
    publicUrl: String,
    // GET endpoint for the location chip's reverse-geocoded label
    // (maps/show.html.erb renders it from the map_place_label route).
    placeLabelUrl: String,
    // POST URL template for the thumbnail capture, with the route id as the
    // "__ROUTE_ID__" placeholder (maps/show.html.erb renders it from the
    // static_map member route).
    thumbPostUrlTemplate: String,
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
    this.viewportResolved = false;
    this.lastFetchedKey = null;
    // Delta-loading state per feed: merged features by id (never evicted —
    // previously fetched viewports stay cached), the padded rectangles
    // already fetched, and the request keys (last committed + the one in
    // flight, committed synchronously — see loadOwnRoutes/loadPublicRoutes).
    this.inFlightKey = null;
    this.publicById = new Map();
    this.coveredBounds = [];
    this.ownInFlightKey = null;
    this.ownById = new Map();
    this.ownCoveredBounds = [];
    this.ownLastFetchedKey = null;
    // Bounds of the current (unpadded) viewport: the drawer, the scope
    // pills and the status pill count only routes intersecting it.
    this.viewportBounds = null;
    this.refreshTimer = null;
    this.abortController = null;
    this.ownAbortController = null;
    // True once the map's "load" event ran and the route sources/layers
    // exist. Everything that writes into those sources is gated on it, so a
    // broken or slow base-map style degrades to console warnings instead of
    // setData TypeErrors (the map surface must stay alive even then).
    this.layersReady = false;
    // Location chip fetch (updateLocationLabel): a newer viewport aborts an
    // older in-flight label request, same contract as the public fetch.
    this.labelAbortController = null;

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
    if (this.ownAbortController) this.ownAbortController.abort();
    if (this.labelAbortController) this.labelAbortController.abort();
    if (this.ro) this.ro.disconnect();
    if (this.map) {
      this.map.remove();
      this.map = null;
    }
  }

  buildMap() {
    const center = this.config.defaultCenter || [0, 0];
    this.map = new maplibregl.Map({
      container: this.canvasTarget,
      style: this.config.styleUrl || MyMapController.FALLBACK_STYLE,
      center: center,
      zoom: this.config.defaultZoom || 12,
      attributionControl: false,
    });
    this.map.addControl(
      new maplibregl.NavigationControl({ visualizePitch: false }),
      "top-right",
    );
    this.map.addControl(this.fitRoutesControl(), "top-right");
    this.map.addControl(
      new maplibregl.GeolocateControl({
        positionOptions: { enableHighAccuracy: false },
        trackUserLocation: false,
      }),
      "top-right",
    );
    // Fullscreen the whole stage (canvas + drawer + popup + status pill),
    // not the bare map canvas — the found-routes drawer and the selected-
    // route popup are stage children and must stay visible in fs mode.
    this.map.addControl(
      new maplibregl.FullscreenControl({ container: this.stageTarget }),
      "top-right",
    );
    this.map.addControl(
      new maplibregl.ScaleControl({ unit: "metric" }),
      "bottom-right",
    );
    this.map.addControl(
      new maplibregl.AttributionControl({
        customAttribution: this.config.customAttribution || [],
      }),
      "bottom-right",
    );

    this.map.on("load", () => this.onMapLoad());
    this.map.on("moveend", () => this.onMoveEnd());
    this.map.on("error", (event) => {
      // Tile/style/network hiccups must not throw; surface in console only.
      if (event && event.error)
        console.warn("Map error:", event.error.message || event.error);
    });
  }

  onMapLoad() {
    this.addRouteLayers();
    this.bindClicks();

    // Selection highlight draws above both route sources (§6.1).
    this.map.addSource("route-highlight", {
      type: "geojson",
      data: MyMapController.EMPTY_COLLECTION,
    });
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

    // Direction chevrons ride the highlight source: they draw only on the
    // selected route, above its casing/line, and vanish on closePopup.
    this.addArrowLayer();

    this.layersReady = true;
    // Own routes load per viewport (§5.1), so the initial viewport comes
    // straight from the server-provided hotspot; the first own+public fetch
    // rides the fit transition's moveend (see resolveInitialViewport).
    this.resolveInitialViewport();
    this.updateLocationLabel();
  }

  // Route GeoJSON sources/layers — deliberately plain LineString styling so
  // rendering is independent of the base-map provider (technote §6/§7: no
  // provider feature ids, source layers or road attributes involved).
  addRouteLayers() {
    this.map.addSource("own-routes", {
      type: "geojson",
      data: MyMapController.EMPTY_COLLECTION,
    });
    this.map.addSource("public-routes", {
      type: "geojson",
      data: MyMapController.EMPTY_COLLECTION,
    });

    // Public routes under the viewer's own (scarlet #e11d48 vs emerald
    // #10b981 — the two visibility classes the technote asks to distinguish).
    this.map.addLayer(
      this.lineLayer("public-casing", "public-routes", "#ffffff", 6.5),
    );
    this.map.addLayer(
      this.lineLayer("public-line", "public-routes", "#10b981", 3.5),
    );
    this.map.addLayer(
      this.lineLayer("own-casing", "own-routes", "#ffffff", 7.5),
    );
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

  // Direction chevrons along the SELECTED route only: they ride the
  // route-highlight source, so selectRoute's setData draws them and
  // closePopup's EMPTY_COLLECTION removes them — no per-feed arrow layers,
  // no clutter while browsing unselected routes. Travel direction is the
  // coordinate order of the stored track (GPX trackpoint order, preserved
  // by Map::TrackGeometry), and symbol-placement: line rotates every placed
  // glyph to the path tangent aligning the glyph's local X-AXIS with it
  // (style spec: icon-rotation-alignment "map" — "aligns icon x-axes with
  // the line"). So the chevron must be drawn pointing RIGHT in image space
  // (see arrowImage); an up-pointing glyph renders 90° off the path.
  // Spacing is in SCREEN pixels and placements are recomputed every frame:
  // zoomed out the whole route shrinks to just a few glyphs (a direction
  // cue, not a carpet), while zooming in re-places glyphs every SPACING px
  // along the line, so any viewport stretch of the route keeps at least one
  // arrow in view. The glyph is canvas-generated (no sprite dependency on
  // the base-map provider, §7); any failure degrades to an arrow-less
  // highlight.
  addArrowLayer() {
    try {
      this.map.addImage("route-arrow", this.arrowImage(), { pixelRatio: 2 });
    } catch (error) {
      console.warn("Route direction arrows unavailable:", error);
      return;
    }
    this.map.addLayer({
      id: "route-arrows",
      type: "symbol",
      source: "route-highlight",
      layout: {
        "symbol-placement": "line",
        "symbol-spacing": 200,
        "icon-image": "route-arrow",
        "icon-rotation-alignment": "map",
        "icon-pitch-alignment": "map",
        "icon-allow-overlap": true,
        "icon-ignore-placement": true,
      },
    });
  }

  // The glyph: a white chevron pointing RIGHT in image space. MapLibre's
  // symbol-placement: line rotates each placed symbol so the glyph's local
  // +x axis follows the path direction (travel order) — an up-pointing
  // glyph would render 90° counterclockwise off the line, i.e. "random"
  // perpendicular arrows. A wider under-stroke in the highlight line's
  // color keeps the white chevron readable where it overhangs the line
  // onto its white casing. Rendered at 2x and handed to MapLibre with
  // pixelRatio: 2 so it stays crisp on HiDPI screens.
  arrowImage() {
    const scale = 2;
    const size = 18 * scale;
    const canvas = document.createElement("canvas");
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext("2d");
    ctx.scale(scale, scale);
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    const chevron = () => {
      ctx.beginPath();
      ctx.moveTo(5.5, 3.5);
      ctx.lineTo(12.5, 9);
      ctx.lineTo(5.5, 14.5);
      ctx.stroke();
    };
    ctx.lineWidth = 6;
    ctx.strokeStyle = "#0f172a";
    chevron();
    ctx.lineWidth = 3;
    ctx.strokeStyle = "#ffffff";
    chevron();
    return ctx.getImageData(0, 0, size, size);
  }

  bindClicks() {
    const layers = ["own-line", "public-line", "own-casing", "public-casing"];
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
        button.setAttribute("aria-label", "Show my fav spot");
        button.title = "Show my fav spot";
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

  // Own routes for the current viewport (technote §5.1), delta-loaded
  // exactly like the public feed: debounced via onMoveEnd, aborted when
  // superseded, never repeated for ground the client already holds, and
  // responses MERGED by id so previously visited viewports stay cached
  // ("already loaded routes should be cached and shouldn't be loaded again
  // after returning to visited viewport"). No min-zoom gate and no cap —
  // the library is the viewer's own (§4.1).
  async loadOwnRoutes(bounds) {
    if (!this.map || !bounds) return;

    const padded = this.padBounds(bounds, MyMapController.BOUNDS_MARGIN_RATIO);
    if (this.coveredBy(this.ownCoveredBounds, padded)) return;

    const key = this.boundsKey(padded);
    if (key === this.ownLastFetchedKey || key === this.ownInFlightKey) return;

    if (this.ownAbortController) this.ownAbortController.abort();
    this.ownAbortController = new AbortController();
    // Committed synchronously, not after the response lands: with a slow
    // endpoint every extra moveend must not refire the same viewport.
    this.ownInFlightKey = key;
    this.setUpdatingStatus();

    try {
      const params = new URLSearchParams({
        west: padded.west,
        south: padded.south,
        east: padded.east,
        north: padded.north,
      });
      const excluded = this.excludeIds(this.ownById);
      if (excluded.length) params.set("exclude_ids", excluded.join(","));

      const response = await fetch(`${this.ownUrlValue}?${params}`, {
        headers: { Accept: "application/json" },
        signal: this.ownAbortController.signal,
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();

      const source = this.map && this.map.getSource("own-routes");
      if (!source) {
        // Defensive (layers vanished → base style reloaded/failed): surface a
        // readable status, keep the viewport key uncommitted so the next pan
        // or the click-to-retry refetches instead of drawing nothing.
        console.warn(
          "Own routes: map route layers are missing — base style may have failed to load.",
        );
        this.ownInFlightKey = null;
        this.setStatus("Base map failed to load — click to retry.", "error");
        return;
      }
      this.mergeOwnFeatures(payload.features || []);
      source.setData({
        type: "FeatureCollection",
        features: this.ownFeatures,
      });
      this.ownCoveredBounds.push(padded);
      if (this.ownCoveredBounds.length > MyMapController.COVERED_BOUNDS_CAP) {
        this.ownCoveredBounds.shift();
      }
      this.ownLastFetchedKey = key;
      this.ownInFlightKey = null;
      this.renderDrawer();
      this.updateCounts();
      this.settleStatus();
      // Step 2 thumbnails: routes the payload shows without a thumb are
      // healed invisibly right after the map data lands.
      this.selfHealThumbs();
    } catch (error) {
      if (error.name === "AbortError") return; // superseded by a newer viewport
      this.ownInFlightKey = null;
      console.warn("Own routes failed to load:", error);
      this.setStatus("Couldn't load your routes — click to retry.", "error");
    }
  }

  // Step 2 thumbnails — invisible self-heal on My Map load: own routes the
  // payload shows without a thumb (parsed before the feature existed, or a
  // failed capture elsewhere) are drawn by the offscreen renderer from this
  // now-fast payload and POSTed to /routes/:id/static_map. Fire-and-forget:
  // the map flow above never waits on tile downloads, and a page navigated
  // away stops the batch through shouldContinue. Public features are never
  // touched — thumbs are attached by their own owners only.
  selfHealThumbs() {
    const pending = this.ownFeatures.filter(
      (feature) => !feature.properties.thumb_url,
    );
    if (pending.length === 0 || !this.thumbPostUrlTemplateValue) return;

    captureRouteThumbs(pending, {
      config: this.config,
      postUrlTemplate: this.thumbPostUrlTemplateValue,
      shouldContinue: () => Boolean(this.map), // false once disconnect() removed it
      onCaptured: (feature, thumbUrl) => {
        // Mutating the feature keeps later re-renders (scope switches,
        // selection) showing the thumb without another fetch.
        feature.properties.thumb_url = thumbUrl;
        this.updateDrawerCardThumb(feature.properties.id, thumbUrl);
      },
    });
  }

  // Swap one drawer card's fallback icon for the freshly captured thumb.
  updateDrawerCardThumb(routeId, thumbUrl) {
    const card = this.cardListTarget.querySelector(
      `[data-route-id="${routeId}"]`,
    );
    if (!card) return;
    if (card.querySelector(".mymap-card__route-map")) return; // already showing a thumb

    this.showCardThumb(card, thumbUrl);
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
      // Keep whatever is drawn; settle the pill for the new viewport unless
      // it is holding an error the user may still want to click-retry.
      this.settleStatus();
      return;
    }

    const padded = this.padBounds(bounds, MyMapController.BOUNDS_MARGIN_RATIO);
    if (this.coveredBy(this.coveredBounds, padded)) return;

    const key = this.boundsKey(padded);
    if (key === this.lastFetchedKey || key === this.inFlightKey) return;

    if (this.abortController) this.abortController.abort();
    this.abortController = new AbortController();
    // Committed synchronously, not after the response lands: the old code
    // committed only on completion, so with a slow endpoint every extra
    // moveend aborted and refired the very same viewport endlessly.
    this.inFlightKey = key;
    this.setUpdatingStatus();

    try {
      const params = new URLSearchParams({
        west: padded.west,
        south: padded.south,
        east: padded.east,
        north: padded.north,
      });
      const excluded = this.excludeIds(this.publicById);
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
        console.warn(
          "Public routes: map route layers are missing — base style may have failed to load.",
        );
        this.inFlightKey = null;
        this.setStatus("Base map failed to load — click to retry.", "error");
        return;
      }
      this.mergePublicFeatures(payload.features || []);
      this.publicTruncated = Boolean(payload.truncated);
      source.setData({
        type: "FeatureCollection",
        features: this.publicFeatures,
      });
      this.coveredBounds.push(padded);
      if (this.coveredBounds.length > MyMapController.COVERED_BOUNDS_CAP) {
        this.coveredBounds.shift();
      }
      this.lastFetchedKey = key;
      this.inFlightKey = null;
      this.renderDrawer();
      this.updateCounts();
      this.settleStatus();
    } catch (error) {
      if (error.name === "AbortError") return; // superseded by a newer viewport
      this.inFlightKey = null;
      console.warn("Public routes failed to load:", error);
      this.setStatus("Public routes failed to load — click to retry.", "error");
    }
  }

  // Click-to-retry on an errored pill: both viewport feeds re-run for the
  // current viewport (failed rectangles never commit to the covered lists,
  // so clearing the last-fetched keys is enough to force them).
  retry() {
    if (!this.statusTarget.classList.contains("is-error")) return;
    this.ownLastFetchedKey = null;
    this.lastFetchedKey = null;
    this.refreshViewportData();
  }

  // ---- viewport → fetch cycle (§5.1/§5.2) ------------------------------------

  // One settled viewport: snapshot the visible bounds (the drawer and every
  // count consider only routes intersecting them), re-render from the cache,
  // then load own + public routes for the area. Runs directly for the
  // initial settle and debounced from onMoveEnd afterwards.
  refreshViewportData() {
    if (!this.map) return;
    this.viewportBounds = this.map.getBounds();
    this.renderDrawer();
    this.updateCounts();
    this.loadOwnRoutes(this.viewportBounds);
    this.loadPublicRoutes(this.viewportBounds);
    this.updateLocationLabel();
    this.settleStatus();
  }

  onMoveEnd() {
    // MapLibre also fires moveend for the initial camera settle, before (or
    // — when the base style fails to load — instead of) "load": a fetch
    // scheduled then would setData into sources that don't exist yet. The
    // initial-viewport chain (resolveInitialViewport) seeds the first
    // own+public fetch once layers are ready, so skipping here costs
    // nothing.
    if (!this.layersReady) return;
    this.persistViewport();
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      this.refreshViewportData();
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

  // ---- delta-loading helpers (§5.1/§5.2) ------------------------------------

  // Zoom threshold from the server config (config/initializers/map.rb →
  // map_frontend_config), with the built-in default as fallback.
  publicMinZoom() {
    return this.config.publicMinZoom || MyMapController.PUBLIC_ROUTES_MIN_ZOOM;
  }

  // Stable identity of a padded rectangle — the dedupe/in-flight key.
  boundsKey(padded) {
    return [padded.west, padded.south, padded.east, padded.north]
      .map((value) => value.toFixed(2))
      .join(",");
  }

  // True when +padded+ sits wholly inside a rectangle fetched before — every
  // route intersecting it is already merged into that feed's store, so a
  // request would only re-download data the map already shows.
  coveredBy(rects, padded) {
    return rects.some(
      (rect) =>
        padded.west >= rect.west &&
        padded.south >= rect.south &&
        padded.east <= rect.east &&
        padded.north <= rect.north,
    );
  }

  // The ids to exclude from the next request: everything already merged,
  // capped to the most recent EXCLUDED_IDS_CAP so the URL stays bounded on
  // far-roaming sessions (Map keys keep insertion order — oldest first,
  // so the tail is what was loaded most recently).
  excludeIds(byId) {
    const ids = Array.from(byId.keys());
    return ids.length > MyMapController.EXCLUDED_IDS_CAP
      ? ids.slice(-MyMapController.EXCLUDED_IDS_CAP)
      : ids;
  }

  // Merge +features+ into a store by id (never evicting: previously fetched
  // viewports stay cached) and return the derived array consumed by the
  // layers, drawer and counts.
  mergeFeatures(byId, features) {
    features.forEach((feature) => {
      const id = feature.properties && feature.properties.id;
      if (id === null || id === undefined) return;
      byId.set(id, feature);
    });
    return Array.from(byId.values());
  }

  mergeOwnFeatures(features) {
    this.ownFeatures = this.mergeFeatures(this.ownById, features);
  }

  mergePublicFeatures(features) {
    this.publicFeatures = this.mergeFeatures(this.publicById, features);
  }

  // Loading indicator shared by the two viewport fetches; never overwrites
  // an error the user may still want to click-retry.
  setUpdatingStatus() {
    if (this.statusTarget.classList.contains("is-error")) return;
    this.setStatus("Updating routes…", "loading");
  }

  // Settle the pill once neither feed is in flight and no error is showing.
  // Its counts are viewport-filtered, so every settled viewport re-answers
  // it — fetched or already covered alike.
  settleStatus() {
    if (this.ownInFlightKey || this.inFlightKey) return;
    if (this.statusTarget.classList.contains("is-error")) return;
    this.setStatus(this.statusCounts(), "");
  }

  // ---- initial viewport (technote §3.1) -------------------------------------

  resolveInitialViewport() {
    if (this.viewportResolved) return;
    this.viewportResolved = true;

    const bounds = this.hotspotBounds();
    if (bounds) {
      // The most-ridden place wins; maxZoom keeps tiny tracks from blowing
      // the map up (§3.1: "avoid excessive zoom levels for very small
      // extents").
      // The own+public fetch rides the fit transition's own moveend so it
      // queries the FINAL bounds — an immediate getBounds() raced the
      // animation and fetched the wrong, pre-fit region on page load.
      this.map.once("moveend", () => this.refreshViewportData());
      this.map.fitBounds(bounds, { padding: 64, maxZoom: 14, duration: 800 });
      return;
    }

    // No hotspot: a persisted viewport beats geolocation beats the default
    // (which the map was initialized with, so failure paths change nothing).
    if (this.restorePersistedViewport()) {
      this.refreshViewportData();
      return;
    }
    this.requestGeolocation();
    this.refreshViewportData();
  }

  // The server-computed most-ridden place ([w, s, e, n], §3.1/§3.2) or null
  // when the rider has no parsed routes. Own routes load per viewport now,
  // so this arrives with the page instead of being derived from the payload.
  hotspotBounds() {
    const box = this.hotspotBoundsValue;
    if (!Array.isArray(box) || box.length !== 4) return null;
    return box.every((value) => Number.isFinite(value)) ? box : null;
  }

  // "Return to my routes" control action (technote §3.2): the heart button
  // dives into the same place the page loads on — the server-computed
  // most-ridden own-routes hotspot (see resolveInitialViewport). No hotspot
  // → configured default, same as before.
  fitToOwnRoutes(fly) {
    const bounds = this.hotspotBounds();
    if (bounds) {
      this.map.fitBounds(bounds, {
        padding: 64,
        maxZoom: 14,
        duration: fly ? 800 : 0,
      });
    } else {
      this.map.jumpTo({
        center: this.configValue.defaultCenter,
        zoom: this.configValue.defaultZoom,
      });
    }
  }

  restorePersistedViewport() {
    try {
      const saved = JSON.parse(
        window.localStorage.getItem(MyMapController.VIEW_STORAGE_KEY),
      );
      if (!saved || !Array.isArray(saved.c) || typeof saved.z !== "number")
        return false;
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
        JSON.stringify({ c: [center.lng, center.lat], z: this.map.getZoom() }),
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
          center: [position.coords.longitude, position.coords.latitude],
          zoom: this.configValue.defaultZoom,
          duration: 1200,
        });
      },
      () => {}, // denied / unavailable / timeout → stay on the default
      { enableHighAccuracy: false, timeout: 8000, maximumAge: 300000 },
    );
  }

  // ---- location chip (sub-bar) -------------------------------------------------

  // "City, Region, Country" for the viewport center — server-side reverse
  // geocoding (Photon, MapsController#place_label, cached per ~1 km cell).
  // The camera-move debounce in onMoveEnd already throttles this to one
  // request per settle; a newer viewport aborts an older in-flight request,
  // and any failure keeps the current label (the server-rendered default on
  // first paint) instead of blanking the chip.
  async updateLocationLabel() {
    if (!this.map || !this.placeLabelUrlValue || !this.hasLocationLabelTarget)
      return;
    const center = this.map.getCenter();
    if (this.labelAbortController) this.labelAbortController.abort();
    this.labelAbortController = new AbortController();
    const signal = this.labelAbortController.signal;
    try {
      const params = new URLSearchParams({ lon: center.lng, lat: center.lat });
      const response = await fetch(`${this.placeLabelUrlValue}?${params}`, {
        headers: { Accept: "application/json" },
        signal,
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      if (signal.aborted) return; // superseded while the response was in flight
      const label = payload && payload.place_label;
      if (label) this.locationLabelTarget.textContent = label;
    } catch (error) {
      if (error.name === "AbortError") return; // superseded by a newer viewport
      console.warn("Place label failed to load:", error);
    }
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
    if (highlight)
      highlight.setData({ type: "FeatureCollection", features: [feature] });
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

    this.popupDistanceTarget.textContent = this.formatDistance(
      properties.distance,
    );
    this.popupElevationTarget.textContent = this.formatElevation(
      properties.elevation_gain,
    );
    this.popupSpeedTarget.textContent = this.formatSpeed(
      properties.avg_speed_kmh,
    );
    this.popupDurationTarget.textContent = this.formatDuration(
      properties.duration,
    );

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
    const y = (ele) =>
      height - pad - ((ele - minEle) / span) * (height - pad * 2 - 4);

    let line = `M ${x(distances[0]).toFixed(1)} ${y(elevations[0]).toFixed(1)}`;
    for (let i = 1; i < distances.length; i += 1) {
      line += ` L ${x(distances[i]).toFixed(1)} ${y(elevations[i]).toFixed(1)}`;
    }
    this.profileLineTarget.setAttribute("d", line);
    this.profileAreaTarget.setAttribute(
      "d",
      `${line} L ${x(maxDistance).toFixed(1)} ${height - pad} L ${pad} ${height - pad} Z`,
    );

    let maxIndex = 0;
    elevations.forEach((ele, index) => {
      if (ele > elevations[maxIndex]) maxIndex = index;
    });
    this.profileMarkerTarget.setAttribute(
      "cx",
      x(distances[maxIndex]).toFixed(1),
    );
    this.profileMarkerTarget.setAttribute(
      "cy",
      y(elevations[maxIndex]).toFixed(1),
    );

    this.profileMaxTarget.textContent = `${INT_FORMAT.format(maxEle)} m`;
    this.profileMidTarget.textContent = `${KM_FORMAT.format(maxDistance / 2000)} km`;
    this.profileEndTarget.textContent = `${KM_FORMAT.format(maxDistance / 1000)} km`;
    this.profileBlockTarget.hidden = false;
  }

  // ---- drawer ----------------------------------------------------------------

  toggleDrawer() {
    this.drawerTarget.classList.toggle("is-collapsed");
    const collapsed = this.drawerTarget.classList.contains("is-collapsed");
    this.drawerToggleTarget.setAttribute(
      "aria-label",
      collapsed ? "Expand routes panel" : "Collapse routes panel",
    );
    this.drawerToggleTarget.setAttribute("aria-expanded", String(!collapsed));
    this.drawerToggleTarget.querySelector(
      ".material-symbols-outlined",
    ).textContent = collapsed ? "menu" : "close";
  }

  collapseDrawer() {
    if (!this.drawerTarget.classList.contains("is-collapsed"))
      this.toggleDrawer();
  }

  // Routes the drawer lists for the active scope: everything cached that
  // intersects the CURRENT viewport ("Found Routes contains only routes on
  // the current map viewport"). Cached routes from other viewports stay in
  // the stores (and on the map) — they reappear here the moment the camera
  // returns, with no refetch.
  visibleFeatures() {
    if (this.activeScope === "own")
      return this.featuresInView(this.ownFeatures);
    if (this.activeScope === "public")
      return this.featuresInView(this.publicFeatures);
    return this.featuresInView(this.ownFeatures.concat(this.publicFeatures));
  }

  // True when the route's stored bounding box intersects the current
  // viewport — the client-side mirror of the server's intersecting_viewport
  // scope, antimeridian branch (west > east for wrapped MapLibre bounds)
  // included.
  featureInView(feature) {
    if (!this.viewportBounds) return false;
    const box = feature.properties && feature.properties.bounds;
    if (!box) return false;
    const west = this.viewportBounds.getWest();
    const south = this.viewportBounds.getSouth();
    const east = this.viewportBounds.getEast();
    const north = this.viewportBounds.getNorth();
    const lonMatch =
      west > east
        ? box[2] >= west || box[0] <= east
        : box[2] >= west && box[0] <= east;
    return lonMatch && box[3] >= south && box[1] <= north;
  }

  featuresInView(features) {
    return features.filter((feature) => this.featureInView(feature));
  }

  renderDrawer() {
    const features = this.visibleFeatures();
    this.cardListTarget.replaceChildren();

    const shown = features.slice(0, MyMapController.DRAWER_MAX_CARDS);
    shown.forEach((feature) =>
      this.cardListTarget.appendChild(this.buildCard(feature)),
    );

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
    const card =
      this.cardTemplateTarget.content.firstElementChild.cloneNode(true);

    card.dataset.routeId = properties.id;
    card.classList.add(properties.own ? "is-own" : "is-public");
    card.classList.toggle("is-selected", properties.id === this.selectedId);

    card.querySelector("[data-card-field=sport]").textContent =
      properties.sport_type || "Ride";
    card.querySelector("[data-card-field=tier]").textContent =
      properties.tier || "";
    card.querySelector("[data-card-field=title]").textContent =
      properties.title || "Untitled Route";

    // Metrics + thumb skeleton is the shared card partial rendered for a
    // blank route: the three __metric-value <dd>s are Dist / Elev / Time in
    // order, the first two ending in the partial's unit <span> — the fill
    // rewrites only the leading text node so that span survives.
    const [dist, elev, time] = card.querySelectorAll(
      ".mymap-card__metric-value",
    );
    this.fillMetric(dist, this.distanceValue(properties.distance));
    this.fillMetric(elev, this.elevationValue(properties.elevation_gain));
    this.fillMetric(time, this.formatDuration(properties.duration));
    this.showCardThumb(card, properties.thumb_url);

    const select = () => {
      this.selectRoute(properties.id);
      const box = properties.bounds;
      if (box) {
        this.map.fitBounds(
          [
            [box[0], box[1]],
            [box[2], box[3]],
          ],
          { padding: 64, maxZoom: 14, duration: 800 },
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

  // One card metric <dd> from the shared partial: "<value> <span …__unit>"
  // (no unit span on Time). Rewrite only the leading text node — the
  // server-styled unit span must survive the fill.
  fillMetric(dd, value) {
    if (dd.querySelector(".mymap-card__unit")) {
      dd.firstChild.nodeValue = `${value} `;
    } else {
      dd.textContent = value;
    }
  }

  // Swap the partial's empty-thumb fallback for a real <img>, mirroring the
  // markup the server renders for routes that have a static map.
  showCardThumb(card, thumbUrl) {
    if (!thumbUrl) return;
    const thumb = card.querySelector(".mymap-card__route-thumb");
    if (!thumb) return;
    const img = document.createElement("img");
    img.className = "mymap-card__route-map";
    img.loading = "lazy";
    img.alt = "";
    img.draggable = false;
    img.src = thumbUrl;
    thumb.classList.remove("mymap-card__route-thumb--empty", "c-tertiary");
    thumb.replaceChildren(img);
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
    this.map.setLayoutProperty(
      "public-casing",
      "visibility",
      visibility(false),
    );
  }

  // Scope-pill counts — the same viewport-filtered population the drawer
  // lists.
  updateCounts() {
    const own = this.featuresInView(this.ownFeatures);
    const pub = this.featuresInView(this.publicFeatures);
    const publicCount = pub.length + (this.publicTruncated ? 500 : 0);
    this.ownCountTarget.textContent = INT_FORMAT.format(own.length);
    this.publicCountTarget.textContent =
      publicCount > 500 ? "500+" : INT_FORMAT.format(publicCount);
    this.allCountTarget.textContent = INT_FORMAT.format(
      own.length + pub.length,
    );
  }

  statusCounts() {
    const own = this.featuresInView(this.ownFeatures);
    const pub = this.featuresInView(this.publicFeatures);
    const parts = [
      `${INT_FORMAT.format(own.length)} yours`,
      `${INT_FORMAT.format(pub.length)} public`,
    ];
    // Truncation now counts only routes the client hasn't loaded yet
    // (exclude_ids deltas): the honest cue is "zoom in", not "showing 500".
    const suffix = this.publicTruncated
      ? " (more public in view — zoom in to load)"
      : "";
    return `${INT_FORMAT.format(own.length + pub.length)} routes in view (${parts.join(", ")})${suffix}`;
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
  // Popup stats are plain text ("12.3 km"); the drawer card's metric <dd>s
  // come from the shared card partial, which carries the unit in its own
  // styled <span> after the value — the card fills use the bare value.

  distanceValue(km) {
    if (km === null || km === undefined) return "—";
    return KM_FORMAT.format(km);
  }

  elevationValue(meters) {
    if (!meters) return "—";
    return `+${INT_FORMAT.format(Math.round(meters))}`;
  }

  formatDistance(km) {
    if (km === null || km === undefined) return "—";
    return `${this.distanceValue(km)} km`;
  }

  formatElevation(meters) {
    if (!meters) return "—";
    return `${this.elevationValue(meters)} m`;
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
