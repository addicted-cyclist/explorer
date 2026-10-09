import { Controller } from "@hotwired/stimulus";

// Instant client-side filtering for the friends page (Phase 11): the toolbar
// search + "riding this week" select narrow the friend cards, and the Find
// friends popup's search narrows its candidate rows. Everything matches
// against data attributes, so filtering needs no round trips.
export default class extends Controller {
  static targets = [
    "search", "filter", "grid", "noResults",
    "candidateSearch", "candidates", "noCandidates"
  ];

  apply() {
    this.applyCards();
    this.applyCandidates();
  }

  // Toolbar: search text + riding filter over the friend cards.
  applyCards() {
    if (!this.hasGridTarget) return;

    const query = this.hasSearchTarget ? this.searchTarget.value.trim().toLowerCase() : "";
    const mode = this.hasFilterTarget ? this.filterTarget.value : "all";
    let visible = 0;

    this.gridTarget.querySelectorAll(".friends__card").forEach((card) => {
      const matchesQuery = query === "" || (card.dataset.search || "").includes(query);
      const matchesMode = mode === "all" || card.dataset.riding === "true";
      const show = matchesQuery && matchesMode;

      card.classList.toggle("is-hidden", !show);
      if (show) visible += 1;
    });

    if (this.hasNoResultsTarget) this.noResultsTarget.hidden = visible > 0;
  }

  // Popup: search text over the candidate rows.
  applyCandidates() {
    if (!this.hasCandidatesTarget) return;

    const query = this.candidateSearchTarget.value.trim().toLowerCase();
    let visible = 0;

    this.candidatesTarget.querySelectorAll(".friends-find__row").forEach((row) => {
      const show = query === "" || (row.dataset.candidate || "").includes(query);

      row.classList.toggle("is-hidden", !show);
      if (show) visible += 1;
    });

    if (this.hasNoCandidatesTarget) this.noCandidatesTarget.hidden = visible > 0;
  }
}