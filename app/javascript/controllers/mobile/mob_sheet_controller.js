import { Controller } from "@hotwired/stimulus";

// Mobile bottom sheets (Phase 8). One controller owns every sheet on the
// page: open() reveals the sheet named by data-mob-sheet-id-param over a
// scrim, fills its [data-field] controls from the triggering element's
// context (scheduled date / route) and locks body scroll. Escape, scrim
// taps, dismiss buttons and a successful Turbo submit from inside the sheet
// all close it again.
export default class extends Controller {
  static targets = ["sheet", "backdrop", "field"];
  static classes = ["open", "locked"];

  open({ params: { id, date = "", routeId = "", routeTitle = "" } }) {
    const sheet = this.sheetTargets.find((el) => el.dataset.sheetId === id);
    if (!sheet) return;

    this.current = sheet;
    const context = {
      date: date,
      dayName: date ? this.dayNameOf(date) : "",
      dateLabel: date ? this.dateLabelOf(date) : "",
      routeId: routeId,
      routeTitle: routeTitle,
    };
    this.fieldTargets
      .filter((el) => sheet.contains(el))
      .forEach((el) => this.applyField(el, context));

    sheet.classList.add(this.openClass);
    sheet.setAttribute("aria-hidden", "false");
    this.backdropTarget.classList.add(this.openClass);
    document.body.classList.add(this.lockedClass);
  }

  close() {
    if (!this.current) return;

    const closing = this.current;
    this.current = null;
    closing.classList.remove(this.openClass);
    closing.setAttribute("aria-hidden", "true");
    this.backdropTarget.classList.remove(this.openClass);
    document.body.classList.remove(this.lockedClass);
    // mob-week listens for this to reset the sheet's picker state.
    this.dispatch("closed", { detail: { id: closing.dataset.sheetId } });
  }

  // Turbo submits from inside a sheet (allocate) close it on success;
  // failures fall through to Turbo's own redirect handling.
  onSubmitEnd(event) {
    if (!event.detail.success) return;
    if (this.current && this.current.contains(event.target)) this.close();
  }

  applyField(element, context) {
    const value = context[element.dataset.field] || "";
    if (element.tagName === "INPUT" || element.tagName === "SELECT") {
      element.value = value;
    } else {
      element.textContent = value || element.dataset.fieldFallback || "";
    }
  }

  // Local-noon parsing keeps %A / "%b %-d" day-stable across time zones.
  dayNameOf(iso) {
    return new Date(`${iso}T12:00:00`).toLocaleString("en-US", {
      weekday: "long",
    });
  }

  dateLabelOf(iso) {
    return new Date(`${iso}T12:00:00`).toLocaleString("en-US", {
      weekday: "long",
      month: "short",
      day: "numeric",
    });
  }
}
