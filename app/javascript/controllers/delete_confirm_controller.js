import { Controller } from "@hotwired/stimulus";

// Phase 12 — account-deletion dialog: the "Permanently Delete" button stays
// disabled until the confirmation input holds DELETE, so the destructive
// request can't be fired by a stray click or an autofilled field.
export default class extends Controller {
  static targets = ["input", "submit"];

  connect() {
    if (this.hasInputTarget) this.inputTarget.value = "";
    if (this.hasSubmitTarget) this.submitTarget.disabled = true;
  }

  check() {
    const armed = this.inputTarget.value.trim() === "DELETE";
    this.submitTarget.disabled = !armed;
  }
}
