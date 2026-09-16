import { Controller } from "@hotwired/stimulus";

// Inline start-time editor on my scheduled cards: the clock button opens the
// editor, picking a time submits the patch form, and the Turbo Stream
// response repaints the day column with the new slot.
export default class extends Controller {
  static targets = ["editor", "input", "form"];

  open() {
    this.editorTarget.hidden = false;
    this.inputTarget.focus();
  }

  // Stream repaint replaces the card; reset in case it stays mounted.
  onSubmitEnd() {
    this.editorTarget.hidden = true;
  }
}