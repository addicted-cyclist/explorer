import maplibregl from "maplibre-gl";

// Step 2 route thumbnails — client-side capture (MapLibre thumbnails).
//
// A hidden offscreen MapLibre map draws one route over the SAME base style
// the /map page uses (config.styleUrl resolved by config/initializers/map.rb,
// handed over as data by the page), with the tile provider's attribution
// rendered in-frame (compact: false — the capture must carry the attribution
// line even when the cover-cropped thumb boxes later trim it). Once the
// render settles, the canvas is exported with canvas.toBlob("image/png") and
// POSTed to the route's static_map endpoint (RoutesController#static_map),
// which stores it as the route's :static_map attachment. 200 answers with
// { thumb_url } (the cacheable /route_thumbs/:signed_id URL), 204 means a
// concurrent visit healed it first — treat both as success, everything else
// as "no thumb this time": the route keeps its fallback icon and a later
// visit retries. This replaced the server-side Mapbox::StaticImage render
// (and its MAPBOX_ACCESS_TOKEN dependency) with a zero-dependency browser
// render.
//
// Contract notes:
//   * ONE WebGL context at a time — batches are serialized through a
//     module-level queue, and the renderer map is created per batch and
//     removed in the finally block. The style/tiles come from the HTTP
//     cache, so the per-batch setup cost is small.
//   * Rendering is rAF-driven, so a hidden tab would never reach "idle";
//     batches defer until the tab is visible again instead of burning the
//     idle timeout per route in the background.
//   * preserveDrawingBuffer: true — required for canvas.toBlob() to see the
//     last rendered frame (MapLibre defaults to false and the buffer would
//     be cleared after compositing).
//   * setPixelRatio(2) — deterministic 2x render (1440x480 backing store)
//     matching the sharpness the old Mapbox @2x render had, regardless of
//     the device's actual devicePixelRatio.

// 3:1 render. The four thumb boxes this image is cover-cropped into:
// my-routes card 334x144 (2.3:1), desktop calendar sidebar 240x56 (4.3:1),
// friend card 350x88 (4:1), mobile calendar 328x88 (3.7:1) — 3:1 sits
// between them, so object-fit: cover never trims more than ~30% of one axis.
const THUMB_WIDTH = 720;
const THUMB_HEIGHT = 240;
const PIXEL_RATIO = 2;

// Auto-fit padding in px (top/bottom, left/right), sized so the stroked
// track stays clear of the cover-cropped edges: the 334x144 card box shows
// 557/720 of the width (82px per side trimmed), the 240x56 sidebar shows
// 168/240 of the height (36px per side) — 86/40 covers both crops plus the
// stroke, exactly the padding the old Mapbox auto-fit used.
const FIT_PADDING = { top: 40, bottom: 40, left: 86, right: 86 };
// Keep tiny tracks from zooming into tile-noise; bigger extents fit exactly.
const FIT_MAX_ZOOM = 16;
const DEGENERATE_ZOOM = 15;

// Line styling mirrors the my-map page's own-route rendering (white casing
// under the app's scarlet track accent) so thumbs and map agree.
const LINE_COLOR = "#e11d48";
const CASING_COLOR = "#ffffff";

// A capture that cannot reach idle (broken base style, throttled tab) gives
// up after this long; the route stays on its fallback icon until a later
// visit heals it instead of wedging the queue.
const IDLE_TIMEOUT_MS = 15000;

// Placeholder in the POST URL template the server renders into the page
// (static_map_route_path("__ROUTE_ID__")).
const ID_PLACEHOLDER = "__ROUTE_ID__";

// Provider-less final fallback (identical to MyMapController's): when no
// style is configured the thumb still renders the track over a plain
// background, so the capture degrades but never breaks.
const FALLBACK_STYLE = {
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

const EMPTY_COLLECTION = { type: "FeatureCollection", features: [] };

// Batches are chained so at most one offscreen renderer (and WebGL context)
// exists at any time, no matter how many pages fire a batch concurrently.
let queue = Promise.resolve();

// Public entry point. +features+ are GeoJSON route features carrying
// geometry, properties.bounds ([west, south, east, north]) and
// properties.id. Options:
//   config            — { styleUrl, customAttribution } (the /map config)
//   postUrlTemplate   — the route's static_map POST URL with ID_PLACEHOLDER
//   onCaptured        — (feature, thumbUrl) called per attached thumb
//   shouldContinue    — () => boolean polled between captures; lets a
//                       disconnecting controller stop a running batch
// Resolves after the batch drained (or was stopped). Never rejects.
export function captureRouteThumbs(features, options) {
  const run = () => captureBatch(features, options || {});
  queue = queue.then(run, run);
  return queue;
}

async function captureBatch(features, { config, postUrlTemplate, onCaptured, shouldContinue }) {
  if (!postUrlTemplate) return;
  const pending = (features || []).filter(
    (feature) => feature.geometry && feature.properties &&
      feature.properties.bounds && Number.isFinite(feature.properties.id)
  );
  if (pending.length === 0) return;
  // Background tabs never paint (rAF is paused), so "idle" would never fire
  // and every capture would burn its timeout. Wait for the tab instead.
  await waitUntilVisible();
  if (stopped(shouldContinue)) return;

  const container = document.createElement("div");
  container.setAttribute("aria-hidden", "true");
  Object.assign(container.style, {
    position: "fixed",
    left: "-10000px",
    top: "0px",
    width: `${THUMB_WIDTH}px`,
    height: `${THUMB_HEIGHT}px`,
    pointerEvents: "none",
  });
  document.body.appendChild(container);

  let map = null;
  try {
    map = new maplibregl.Map({
      container,
      style: (config && config.styleUrl) || FALLBACK_STYLE,
      // Attribution rendered IN-FRAME (compact: false): the captured PNG
      // carries the tile provider's attribution line, as required when the
      // image is stored and re-served.
      attributionControl: { compact: false, customAttribution: (config && config.customAttribution) || [] },
      interactive: false,
      fadeDuration: 0,
      canvasContextAttributes: { preserveDrawingBuffer: true },
    });
    map.setPixelRatio(PIXEL_RATIO);
    map.on("error", (event) => {
      if (event && event.error) console.warn("Thumb render error:", event.error.message || event.error);
    });

    await waitForIdle(map); // style + first tiles settle before any capture
    addRouteLayers(map);

    for (const feature of pending) {
      if (stopped(shouldContinue)) break;
      const postUrl = postUrlTemplate.replace(ID_PLACEHOLDER, String(feature.properties.id));
      try {
        const thumbUrl = await captureFeature(map, feature, postUrl);
        if (thumbUrl && onCaptured) onCaptured(feature, thumbUrl);
      } catch (error) {
        // One bad route (corrupt geometry, network hiccup) must not stop the
        // batch — the rest heal, the failure retries on a later visit.
        console.warn("Thumb capture failed:", error);
      }
    }
  } catch (error) {
    // Renderer start failure (WebGL unavailable, style rejected) degrades to
    // the fallback icons — never a user-facing error.
    console.warn("Thumbnail renderer failed to start:", error);
  } finally {
    if (map) map.remove();
    container.remove();
  }
}

function stopped(shouldContinue) {
  return typeof shouldContinue === "function" && !shouldContinue();
}

async function captureFeature(map, feature, postUrl) {
  const source = map.getSource("route-thumb");
  if (!source) return null;

  source.setData(feature);
  const [west, south, east, north] = feature.properties.bounds;
  if (east > west || north > south) {
    map.fitBounds([ [ west, south ], [ east, north ] ],
      { padding: FIT_PADDING, maxZoom: FIT_MAX_ZOOM, duration: 0 });
  } else {
    // Zero-extent track (all points share one location): fitBounds would
    // degenerate, jump to a sane fixed view instead.
    map.jumpTo({ center: [ west, south ], zoom: DEGENERATE_ZOOM });
  }

  const completed = await waitForIdle(map);
  if (!completed) return null;

  const blob = await canvasToPng(map.getCanvas());
  if (!blob || blob.size === 0) return null;

  const response = await fetch(postUrl, {
    method: "POST",
    headers: {
      "Content-Type": "image/png",
      Accept: "application/json",
      "X-CSRF-Token": csrfToken(),
    },
    body: blob,
  });
  if (response.status === 204) return null; // healed by another visit already
  if (!response.ok) {
    console.warn(`Thumb upload failed: HTTP ${response.status}`);
    return null;
  }
  const payload = await response.json().catch(() => null);
  return (payload && payload.thumb_url) || null;
}

// Casing + line above the base style, rebuilt per batch on the fresh map.
function addRouteLayers(map) {
  map.addSource("route-thumb", { type: "geojson", data: EMPTY_COLLECTION });
  map.addLayer({
    id: "route-thumb-casing",
    type: "line",
    source: "route-thumb",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": CASING_COLOR, "line-width": 7.5 },
  });
  map.addLayer({
    id: "route-thumb-line",
    type: "line",
    source: "route-thumb",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": LINE_COLOR, "line-width": 4.5 },
  });
}

// Resolves true when the map reached idle (style loaded, tiles drawn),
// false on timeout — a stale render must never become a blank thumb.
function waitForIdle(map) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      map.off("idle", onIdle);
      resolve(false);
    }, IDLE_TIMEOUT_MS);
    const onIdle = () => {
      clearTimeout(timer);
      resolve(true);
    };
    map.once("idle", onIdle);
  });
}

function canvasToPng(canvas) {
  return new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
}

function waitUntilVisible() {
  if (!document.hidden) return Promise.resolve();
  return new Promise((resolve) => {
    const onChange = () => {
      if (!document.hidden) {
        document.removeEventListener("visibilitychange", onChange);
        resolve();
      }
    };
    document.addEventListener("visibilitychange", onChange);
  });
}

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta && meta.content;
}
