import { Controller } from "@hotwired/stimulus";

// Phase 9 — public-calendar share control. `copy` writes the share URL to
// the clipboard and flashes "Copied!" on the button label (desktop telemetry
// bar + account page). `share` opens the native OS share sheet (mobile
// header icon), falling back to a copy when Web Share is unavailable or the
// sheet errors out; an intentional dismissal (AbortError) is left alone.
export default class extends Controller {
  static targets = ["label"];

  static values = {
    url: String,
    title: { type: String, default: "My calendar" },
    copiedText: { type: String, default: "Copied!" },
    flashMs: { type: Number, default: 2000 },
  };

  async copy() {
    await this.#writeClipboard();
    this.#flashCopied();
  }

  async share() {
    if (navigator.share) {
      try {
        await navigator.share({ title: this.titleValue, url: this.urlValue });
        return;
      } catch (error) {
        // User dismissed the share sheet — nothing to do.
        if (error.name === "AbortError") return;
      }
    }
    await this.copy();
  }

  async #writeClipboard() {
    try {
      await navigator.clipboard.writeText(this.urlValue);
    } catch {
      // Clipboard API needs a secure context (https or localhost); older
      // browsers and plain-http dev hosts land here.
      this.#copyFallback();
    }
  }

  #copyFallback() {
    const textarea = document.createElement("textarea");
    textarea.value = this.urlValue;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);
    textarea.select();
    document.execCommand("copy");
    textarea.remove();
  }

  // Swap the button label to "Copied!" for a beat, then restore it. A timer
  // guard keeps rapid double-clicks from stacking overlapping restores.
  #flashCopied() {
    if (!this.hasLabelTarget) return;

    clearTimeout(this.restoreTimer);
    if (!this.originalLabel) this.originalLabel = this.labelTarget.textContent;
    this.labelTarget.textContent = this.copiedTextValue;

    this.restoreTimer = setTimeout(() => {
      this.labelTarget.textContent = this.originalLabel;
    }, this.flashMsValue);
  }
}
