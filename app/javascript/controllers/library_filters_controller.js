import { Controller } from "@hotwired/stimulus";

// Instant client-side filtering for the routes grid, mirroring the stitch
// route library reference: search box, difficulty chips and sorting all run
// against data attributes on the cards, so no round trip is needed.
export default class extends Controller {
  static targets = ["search", "sort", "grid", "chip", "noResults", "noRoutes"];

  connect() {
    this.activeTier = "all";
  }

  setTier(event) {
    this.activeTier = event.currentTarget.dataset.tier;
    this.chipTargets.forEach((chip) => {
      chip.classList.toggle("is-active", chip === event.currentTarget);
    });
    this.apply();
  }

  apply() {
    const cards = Array.from(this.gridTarget.querySelectorAll(".route-card"));

    if (cards.length === 0) {
      this.noRoutesTarget.hidden = false;
      this.noResultsTarget.hidden = true;
      return;
    }
    this.noRoutesTarget.hidden = true;

    const query = this.searchTarget.value.trim().toLowerCase();
    let visible = 0;

    cards.forEach((card) => {
      const matchesTier =
        this.activeTier === "all" || card.dataset.tier === this.activeTier;
      const haystack = (card.dataset.search || "").toLowerCase();
      const matchesQuery = query === "" || haystack.includes(query);
      const show = matchesTier && matchesQuery;
      card.classList.toggle("is-hidden", !show);
      if (show) visible += 1;
    });

    this.noResultsTarget.hidden = visible !== 0;
    this.sortCards(cards);
  }

  sortCards(cards) {
    const mode = this.hasSortTarget ? this.sortTarget.value : "date-desc";

    const sorted = cards.sort((a, b) => {
      switch (mode) {
        case "distance-desc":
          return this.numberFor(b, "distance") - this.numberFor(a, "distance");
        case "elevation-desc":
          return (
            this.numberFor(b, "elevation") - this.numberFor(a, "elevation")
          );
        case "duration-desc":
          return this.numberFor(b, "duration") - this.numberFor(a, "duration");
        default:
          // Newest first — the server renders the grid in this order
          return this.numberFor(a, "created") - this.numberFor(b, "created");
      }
    });

    sorted.forEach((card) => this.gridTarget.appendChild(card));
  }

  numberFor(card, key) {
    const value = Number.parseFloat(card.dataset[key]);
    return Number.isNaN(value) ? 0 : value;
  }
}
