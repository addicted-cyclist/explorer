import { Controller } from "@hotwired/stimulus";

// Slider bounds — the design's ticks (design-refs/stitch_explorer_v0.14).
// A thumb parked on a bound means "open-ended": that bound is NOT sent, so
// the server filters nothing on that side ("180+ km", "3,000+ m").
const DISTANCE_MIN = 5;
const DISTANCE_MAX = 180;
const ELEVATION_MIN = 200;
const ELEVATION_MAX = 3000;

// Duration radio cards → semantic second ranges. "any" carries no bounds:
// both duration params are omitted, so the server applies no duration
// constraint and routes with unspecified (NULL) duration match too.
const DURATION_RANGES = {
  any: {},
  "under-1h": { max: 3600 },
  "1-4h": { min: 3600, max: 14400 },
  "4-6h": { min: 14400, max: 21600 },
  "6h-plus": { min: 21600 },
};

// First-open state — the prototype's demo values (code.html).
const DEFAULTS = {
  sport: "all",
  distanceMin: 20,
  distanceMax: 98,
  elevation: 1500,
  duration: "1-4h",
};

const INT_FORMAT = new Intl.NumberFormat("en-US");

// Find-new-routes filter modal (design-refs/stitch_explorer_v0.14). Small
// and single-purpose: it owns only the control state — segmented route
// type, dual-thumb distance range, elevation cap, duration cards — and
// their labels. my_map_controller owns everything else: it asks for a sync
// with find-routes:open (sub-bar button / drawer Edit chip, carrying the
// active filter set) and receives the applied semantic filters back via
// find-routes:apply (Find). Cancel never dispatches: the next open re-syncs
// from my-map, so dismissing is lossless by construction.
export default class extends Controller {
  static targets = [
    "distanceMin",
    "distanceMax",
    "distanceFill",
    "distanceLabel",
    "elevation",
    "elevationFill",
    "elevationLabel",
    "durationOption",
  ];

  connect() {
    this.boundSync = this.syncFromMap.bind(this);
    document.addEventListener("find-routes:open", this.boundSync);
    this.syncFromMap({ detail: { filters: null } });
  }

  disconnect() {
    document.removeEventListener("find-routes:open", this.boundSync);
  }

  // my-map#openFindRoutes broadcasts the active filter set (null before the
  // first Find): restore every control to exactly those positions.
  syncFromMap(event) {
    this.restore(event.detail.filters);
  }

  pickSport(event) {
    this.sport = event.currentTarget.dataset.sport;
    this.sportButtons().forEach((button) => {
      button.classList.toggle("is-active", button === event.currentTarget);
    });
  }

  distanceChanged() {
    // Keep the thumbs from crossing (clamp the moving one, never swap).
    let min = Number(this.distanceMinTarget.value);
    let max = Number(this.distanceMaxTarget.value);
    if (min > max) {
      if (document.activeElement === this.distanceMinTarget) min = max;
      else max = min;
      this.distanceMinTarget.value = min;
      this.distanceMaxTarget.value = max;
    }
    this.paintDistance(min, max);
  }

  elevationChanged() {
    this.paintElevation(Number(this.elevationTarget.value));
  }

  durationChanged(event) {
    this.duration = event.currentTarget.value;
    this.paintDuration();
  }

  // Find (form submit): hand the semantic filter set to my-map — open ends
  // (thumb on a bound) and the all-passing sport are omitted — then close
  // the modal through the co-located overlay controller.
  apply(event) {
    event.preventDefault();

    const filters = {};
    if (this.sport !== "all") filters.sport_type = this.sport;
    filters.distance_min = Number(this.distanceMinTarget.value);
    const distanceMax = Number(this.distanceMaxTarget.value);
    if (distanceMax < DISTANCE_MAX) filters.distance_max = distanceMax;
    const elevation = Number(this.elevationTarget.value);
    if (elevation < ELEVATION_MAX) filters.elevation_max = elevation;
    const range =
      DURATION_RANGES[this.duration] || DURATION_RANGES[DEFAULTS.duration];
    if (range.min) filters.duration_min = range.min;
    if (range.max) filters.duration_max = range.max;

    this.dispatch("apply", { detail: { filters } });
    this.modal()?.hide();
  }

  // ---- internals ------------------------------------------------------------

  // Restore control positions from a semantic filter set (the inverse of
  // apply). Applied-but-open bounds park their thumb on the bound; null
  // (never applied) falls back to the prototype defaults.
  restore(filters) {
    const applied = filters !== null && filters !== undefined;

    this.sport = (applied && filters.sport_type) || DEFAULTS.sport;
    this.sportButtons().forEach((button) => {
      button.classList.toggle("is-active", button.dataset.sport === this.sport);
    });

    const min =
      applied && filters.distance_min !== undefined
        ? filters.distance_min
        : applied
          ? DISTANCE_MIN
          : DEFAULTS.distanceMin;
    const max =
      applied && filters.distance_max !== undefined
        ? filters.distance_max
        : applied
          ? DISTANCE_MAX
          : DEFAULTS.distanceMax;
    this.distanceMinTarget.value = min;
    this.distanceMaxTarget.value = max;
    this.paintDistance(min, max);

    const elevation =
      applied && filters.elevation_max !== undefined
        ? filters.elevation_max
        : applied
          ? ELEVATION_MAX
          : DEFAULTS.elevation;
    this.elevationTarget.value = elevation;
    this.paintElevation(elevation);

    this.duration = applied ? this.durationFrom(filters) : DEFAULTS.duration;
    this.durationOptionTargets.forEach((option) => {
      option.checked = option.value === this.duration;
    });
    this.paintDuration();
  }

  // Map a semantic (min, max) duration pair back onto its radio card.
  durationFrom(filters) {
    const match = Object.entries(DURATION_RANGES).find(
      ([, range]) =>
        (range.min || 0) === (filters.duration_min || 0) &&
        (range.max || Infinity) === (filters.duration_max || Infinity),
    );
    return match ? match[0] : DEFAULTS.duration;
  }

  sportButtons() {
    return Array.from(
      this.element.querySelectorAll(".find-routes__segment-btn"),
    );
  }

  modal() {
    return this.application.getControllerForElementAndIdentifier(
      this.element,
      "modal",
    );
  }

  paintDistance(min, max) {
    const span = DISTANCE_MAX - DISTANCE_MIN;
    this.distanceFillTarget.style.left = `${((min - DISTANCE_MIN) / span) * 100}%`;
    this.distanceFillTarget.style.right = `${((DISTANCE_MAX - max) / span) * 100}%`;
    this.distanceLabelTarget.textContent = max >= DISTANCE_MAX
      ? `${INT_FORMAT.format(min)}+ km`
      : `${INT_FORMAT.format(min)} – ${INT_FORMAT.format(max)} km`;
  }

  paintElevation(value) {
    this.elevationFillTarget.style.left = "0";
    this.elevationFillTarget.style.right =
      `${((ELEVATION_MAX - value) / (ELEVATION_MAX - ELEVATION_MIN)) * 100}%`;
    this.elevationLabelTarget.textContent = value >= ELEVATION_MAX
      ? `${INT_FORMAT.format(ELEVATION_MAX)}+ m`
      : `≤ ${INT_FORMAT.format(value)} m`;
  }

  paintDuration() {
    this.durationOptionTargets.forEach((option) => {
      const card = option.closest(".find-routes__duration-card");
      if (card) card.classList.toggle("is-active", option.checked);
    });
  }
}
