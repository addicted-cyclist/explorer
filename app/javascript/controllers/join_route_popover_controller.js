import { Controller } from "@hotwired/stimulus";

// The "Join" popover on a friend's scheduled ride. Toggles in place and
// closes on ✕ / outside click / Escape. The join POST answers with a Turbo
// Stream that repaints the entry card in its green "Joined" state.
export default class extends Controller {
  static targets = ["button", "popover", "actions"];

  toggle() {
    if (this.popoverTarget.hidden) {
      this.open();
    } else {
      this.close();
    }
  }

  open() {
    this.popoverTarget.hidden = false;
    this.buttonTarget.setAttribute("aria-expanded", "true");
    document.addEventListener("click", this.outsideClick, true);
    document.addEventListener("keydown", this.escapeKey, true);
  }

  close() {
    this.popoverTarget.hidden = true;
    this.buttonTarget.setAttribute("aria-expanded", "false");
    document.removeEventListener("click", this.outsideClick, true);
    document.removeEventListener("keydown", this.escapeKey, true);
  }

  // The stream swap replaces the card; if it is a no-op, at least close.
  onSubmitEnd() {
    this.close();
  }

  disconnect() {
    document.removeEventListener("click", this.outsideClick, true);
    document.removeEventListener("keydown", this.escapeKey, true);
  }

  outsideClick = (event) => {
    if (this.element.contains(event.target)) return;
    this.close();
  };

  escapeKey = (event) => {
    if (event.key === "Escape") this.close();
  };
}