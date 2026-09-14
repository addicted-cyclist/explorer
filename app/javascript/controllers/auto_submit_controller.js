import { Controller } from "@hotwired/stimulus";

// Submits the surrounding form whenever any of its fields changes. Used by
// the route detail inline editors (title, description, tier): text fields
// commit on blur/Enter (the browser fires `change`), selects immediately.
export default class extends Controller {
  // Focus a named field (used by the hover pencil buttons next to the
  // editable title/description inputs).
  focus(event) {
    const field = document.getElementById(event.params.field);
    if (field) field.focus();
  }

  submit() {
    this.element.requestSubmit();
  }

  keydown(event) {
    if (event.target.tagName !== "TEXTAREA") return;
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.submit();
    }
  }

  connect() {
    this.element.addEventListener("change", () => this.submit());
    this.element.addEventListener("keydown", (event) => this.keydown(event));
  }
}
