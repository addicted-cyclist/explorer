import { Controller } from "@hotwired/stimulus";

// Friends page filtering (Phase 11). The toolbar search + "riding this
// week" select narrow the friend cards client-side — the friends list is
// naturally small, so that needs no round trips. The Find friends popup,
// in contrast, searches the whole user base: once the query reaches three
// characters it loads friends/candidates into its Turbo Frame (debounced),
// so the page never preloads every account and the payload stays flat at
// any app size.
export default class extends Controller {
  static targets = [
    "search", "filter", "grid", "noResults",
    "candidateSearch", "frame", "prompt", "loading"
  ];

  static values = {
    candidatesUrl: String,
    minQueryLength: { type: Number, default: 3 },
    debounceDelay: { type: Number, default: 300 }
  };

  // Toolbar: search text + riding filter over the friend cards.
  apply() {
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

  // Popup: debounce the input, then load matching candidates into the frame.
  searchCandidates() {
    clearTimeout(this.searchTimer);
    const query = this.candidateSearchTarget.value.trim();
    this.searchTimer = setTimeout(() => this.loadCandidates(query), this.debounceDelayValue);
  }

  // turbo:frame-load on the results frame — the spinner's stop signal.
  candidatesLoaded() {
    this.loadingTarget.hidden = true;
  }

  loadCandidates(query) {
    const frame = this.frameTarget;

    if (query.length < this.minQueryLengthValue) {
      // Too short: drop any in-flight results and return to the prompt.
      frame.removeAttribute("src");
      frame.innerHTML = "";
      this.promptTarget.hidden = false;
      this.loadingTarget.hidden = true;
      return;
    }

    const url = new URL(this.candidatesUrlValue, window.location.origin);
    url.searchParams.set("q", query);

    this.promptTarget.hidden = true;
    // Same query as the loaded frame (e.g. a row action just repainted it):
    // keep what is rendered instead of refetching.
    if (frame.src === url.href) {
      this.loadingTarget.hidden = true;
      return;
    }

    this.loadingTarget.hidden = false;
    frame.src = url.href;
  }

  disconnect() {
    clearTimeout(this.searchTimer);
  }
}
