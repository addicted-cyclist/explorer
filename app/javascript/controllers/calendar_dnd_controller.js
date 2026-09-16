import { Controller } from "@hotwired/stimulus";

// Drag & drop scheduling for the weekly calendar (my view). Sidebar cards are
// HTML5 drag sources; day columns and the sidebar pool are drop zones. Drops
// fill and submit the hidden allocate transport forms via Turbo — the server
// answers with Turbo Stream fragment swaps of the affected day column(s).
export default class extends Controller {
  static targets = ["allocateForm", "removeForm", "dayColumn"];

  connect() {
    this.dragged = null;
  }

  // ---- Sidebar drag sources ------------------------------------------------

  dragStart(event) {
    const card = event.currentTarget;
    this.dragged = card.dataset.calendarDndIdParam;
    card.classList.add("is-dragging");
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", this.dragged);
    }
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("is-dragging");
    this.clearHighlights();
  }

  // ---- Day columns ----------------------------------------------------------

  dragOverDay(event) {
    if (!this.dragged) return;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
    event.currentTarget.classList.add("wc-day--drag-over");
  }

  dragLeaveDay(event) {
    if (!this.dragged) return;
    event.currentTarget.classList.remove("wc-day--drag-over");
  }

  dropOnDay(event) {
    if (!this.dragged) return;
    event.preventDefault();
    event.currentTarget.classList.remove("wc-day--drag-over");
    if (!this.hasAllocateFormTarget) {
      this.dragged = null;
      return;
    }

    // The drop date travels on the column as data-calendar-dnd-date-param,
    // with the plain data-date attribute as a fallback. Never submit without
    // one — a blank date only earns a cryptic server-side validation alert.
    const column = event.currentTarget;
    const date = column.dataset.calendarDndDateParam || column.dataset.date;
    if (!date) {
      this.dragged = null;
      return;
    }

    this.allocateFormTarget.elements["route_id"].value = this.dragged;
    this.allocateFormTarget.elements["scheduled_on"].value = date;
    this.allocateFormTarget.requestSubmit();
    this.dragged = null;
  }

  // ---- Sidebar pool (dropping back clears the gesture) ----------------------

  dragOverPool(event) {
    if (!this.dragged) return;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
    event.currentTarget.classList.add("wc-sidebar__pool--drag-over");
  }

  dragLeavePool(event) {
    if (!this.dragged) return;
    event.currentTarget.classList.remove("wc-sidebar__pool--drag-over");
  }

  dropOnPool(event) {
    if (!this.dragged) return;
    event.preventDefault();
    event.currentTarget.classList.remove("wc-sidebar__pool--drag-over");
    this.dragged = null;
  }

  // ---- Unscheduling ----------------------------------------------------------
  // Scheduled-card eject button: unschedules without dragging.

  removeEntry(event) {
    if (!this.hasRemoveFormTarget) return;
    this.removeFormTarget.elements["route_id"].value = event.currentTarget.dataset.routeId;
    this.removeFormTarget.requestSubmit();
  }

  clearHighlights() {
    this.dayColumnTargets.forEach((column) => column.classList.remove("wc-day--drag-over"));
    const pool = this.element.querySelector(".wc-sidebar__pool");
    if (pool) pool.classList.remove("wc-sidebar__pool--drag-over");
  }
}