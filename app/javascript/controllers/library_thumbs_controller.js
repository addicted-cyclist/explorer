import { Controller } from "@hotwired/stimulus";
import { captureRouteThumbs } from "../map/route_thumb_capture";

// Step 2 thumbnails — library-side capture ("capture on upload / library
// return"). RoutesController#index flags the routes still missing a thumb
// (parsed before the feature existed, or the capture failed last time);
// this controller fetches the now-fast own-routes GeoJSON payload
// (GET /map/routes/own, Step 1) once, matches those routes, draws each with
// the offscreen MapLibre renderer (app/javascript/map/route_thumb_capture.js)
// and POSTs the PNG to /routes/:id/static_map. A captured thumb swaps into
// its rendered card in place, so an upload-return shows real map thumbs
// without a reload; failures keep the fallback icon and retry on the next
// visit. Nothing here can leak: the server scopes the POST to the route's
// owner, and the payload it draws from is current_user's own.
export default class extends Controller {
  static values = {
    config: Object,
    ownUrl: String,
    postUrlTemplate: String,
    pendingIds: Array,
  };

  connect() {
    this.capturePending();
  }

  async capturePending() {
    const pendingIds = new Set(this.pendingIdsValue);
    if (pendingIds.size === 0 || !this.postUrlTemplateValue) return;

    let features = [];
    try {
      const response = await fetch(this.ownUrlValue, { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      features = (payload.features || []).filter(
        (feature) => feature.geometry && feature.properties &&
          pendingIds.has(feature.properties.id) && feature.properties.bounds
      );
    } catch (error) {
      // The capture is a progressive enhancement: a failed payload fetch
      // just leaves the fallback icons for this visit.
      console.warn("Thumb capture skipped — own routes failed to load:", error);
      return;
    }

    captureRouteThumbs(features, {
      config: this.configValue,
      postUrlTemplate: this.postUrlTemplateValue,
      // A Turbo navigation disconnects this controller and drops its
      // element: stop instead of healing a page that is already gone.
      shouldContinue: () => this.element.isConnected,
      onCaptured: (feature, thumbUrl) => this.swapCardThumb(feature.properties.id, thumbUrl),
    });
  }

  // Replace a card's fallback block with the captured image in place. The
  // server-rendered thumb fragment is cache-keyed on the route, so once the
  // attachment exists the next visit renders the <img> from cache directly.
  swapCardThumb(routeId, thumbUrl) {
    const card = document.getElementById(`route_${routeId}`);
    const thumbBox = card && card.querySelector(".route-card__thumb");
    if (!thumbBox || thumbBox.querySelector(".route-card__route-map")) return;

    const fallback = thumbBox.querySelector(".route-card__thumb-fallback");
    const img = document.createElement("img");
    img.className = "route-card__route-map";
    img.alt = "";
    img.loading = "lazy";
    img.draggable = false;
    img.src = thumbUrl;
    if (fallback) {
      fallback.replaceWith(img);
    } else {
      thumbBox.prepend(img);
    }
  }
}
