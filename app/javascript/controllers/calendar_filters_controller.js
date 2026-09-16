import { Controller } from "@hotwired/stimulus";

// Client-side filter for the calendar sidebar route pool. Matches against the
// card's data-search attribute (title, sport, tier) and its distance; keeps
// the count label and the no-match row in sync.
export default class extends Controller {
  static targets = ["search", "list", "count", "empty", "query"];

  filter() {
    const term = this.searchTarget.value.trim().toLowerCase();
    const cards = this.listTarget.querySelectorAll("[data-search]");
    let visible = 0;

    cards.forEach((card) => {
      const haystack = `${card.dataset.search} ${card.dataset.distance || ""}`.toLowerCase();
      const match = term === "" || haystack.includes(term);
      card.hidden = !match;
      if (match) visible += 1;
    });

    this.countTarget.textContent = String(visible);
    this.emptyTarget.hidden = visible > 0 || term === "";
    this.queryTarget.textContent = this.searchTarget.value.trim();
  }
}