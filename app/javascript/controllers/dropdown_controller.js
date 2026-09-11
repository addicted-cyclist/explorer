import { Controller } from "@hotwired/stimulus";

// Disclosure menu controller (account chip → account menu).
// Mirrors the stitch_explorer_v0.2 shell: trigger toggles the panel,
// outside click and Escape close it.
export default class extends Controller {
  static targets = ["trigger", "menu"];

  connect() {
    this.boundOutsideClick = this.handleOutsideClick.bind(this);
    this.boundKeydown = this.handleKeydown.bind(this);
    document.addEventListener("click", this.boundOutsideClick);
    document.addEventListener("keydown", this.boundKeydown);
  }

  disconnect() {
    document.removeEventListener("click", this.boundOutsideClick);
    document.removeEventListener("keydown", this.boundKeydown);
  }

  toggle() {
    this.menuTarget.hidden ? this.open() : this.close();
  }

  open() {
    this.menuTarget.hidden = false;
    this.triggerTarget.setAttribute("aria-expanded", "true");
  }

  close() {
    this.menuTarget.hidden = true;
    this.triggerTarget.setAttribute("aria-expanded", "false");
  }

  handleOutsideClick(event) {
    if (!this.element.contains(event.target)) this.close();
  }

  handleKeydown(event) {
    if (event.key === "Escape" && !this.menuTarget.hidden) {
      this.close();
      this.triggerTarget.focus();
    }
  }
}
