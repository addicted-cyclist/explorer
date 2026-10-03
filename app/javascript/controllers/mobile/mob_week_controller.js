import { Controller } from "@hotwired/stimulus";

// Mobile weekly calendar orchestration (Phase 8): one visible day panel
// driven by the week strip, a filtered route picker inside the "Add route"
// sheet and a client-rendered month grid inside the "Schedule route" sheet.
// Day-panel selection survives Turbo Stream repaints: every stream render
// re-applies the classes for the day the user is currently on.
export default class extends Controller {
  static targets = [
    "dayPill",
    "dayPanel",
    "search",
    "routeRow",
    "pickerEmpty",
    "addRouteField",
    "addSubmit",
    "scheduleDate",
    "scheduleSubmit",
    "monthLabel",
    "monthGrid",
  ];
  static values = {
    initialDate: String,
    bookedDates: Array,
    initialMonth: String,
  };

  connect() {
    this.selectedDate = this.initialDateValue;
    this.view = this.viewOf(this.initialMonthValue || this.todayISO());
    this.renderMonthGrid();
    this.applySelection();

    // Day panels are swapped whole by the allocate/remove/join streams;
    // wrapping the original render re-applies the visible-day selection the
    // moment the replacement lands, and puts each panel's swipe slider back
    // on the slide the user was reading (a fresh track always starts at 1).
    this.onBeforeStreamRender = (event) => {
      const original = event.detail.render;
      event.detail.render = (element) => {
        const sliderPositions = this.captureSliderPositions();
        original(element);
        this.applySelection();
        this.restoreSliderPositions(sliderPositions);
      };
    };
    document.addEventListener(
      "turbo:before-stream-render",
      this.onBeforeStreamRender,
    );
  }

  disconnect() {
    document.removeEventListener(
      "turbo:before-stream-render",
      this.onBeforeStreamRender,
    );
  }

  // ---- slider state across stream repaints --------------------------------

  // Each day panel's slider position, keyed by panel id — captured while the
  // old panels are still mounted (before the stream swaps them). Same math
  // as mob-slider#sync.
  captureSliderPositions() {
    const positions = {};
    this.dayPanelTargets.forEach((panel) => {
      const track = panel.querySelector("[data-mob-slider-target='track']");
      if (track && track.clientWidth > 0) {
        positions[panel.id] =
          Math.round(track.scrollLeft / track.clientWidth) || 0;
      }
    });
    return positions;
  }

  // Puts every replaced panel's slider back on its captured slide — an
  // instant jump (no smooth glide), so the repaint is imperceptible. The
  // reconnected mob-slider syncs from the scroll position afterwards and
  // lights the matching dot. Panels that were not replaced (or lost their
  // slider) resolve to the same position or no track at all — both no-ops.
  restoreSliderPositions(positions) {
    Object.entries(positions).forEach(([panelId, index]) => {
      const panel = document.getElementById(panelId);
      const track =
        panel && panel.querySelector("[data-mob-slider-target='track']");
      const slide = track && track.children[index];
      if (slide) track.scrollTo({ left: slide.offsetLeft });
    });
  }

  // ---- day strip ----------------------------------------------------------

  selectDay({ params: { date } }) {
    this.selectedDate = date;
    this.applySelection();
  }

  applySelection() {
    this.dayPillTargets.forEach((pill) => {
      const active = pill.dataset.date === this.selectedDate;
      pill.classList.toggle("is-selected", active);
      pill.setAttribute("aria-selected", active ? "true" : "false");
    });
    this.dayPanelTargets.forEach((panel) => {
      panel.classList.toggle(
        "is-selected",
        panel.dataset.date === this.selectedDate,
      );
    });
  }

  // ---- "Add route to {date}" sheet ----------------------------------------

  filterRoutes() {
    if (!this.hasSearchTarget) return;

    const query = this.searchTarget.value.trim().toLowerCase();
    let visible = 0;
    this.routeRowTargets.forEach((row) => {
      const match = row.dataset.routeTitle.toLowerCase().includes(query);
      row.hidden = !match;
      if (match) visible += 1;
    });
    if (this.hasPickerEmptyTarget) this.pickerEmptyTarget.hidden = visible > 0;
  }

  pickRoute({ params: { routeId } }) {
    this.routeRowTargets.forEach((row) => {
      row.classList.toggle(
        "is-selected",
        row.dataset.routeId === String(routeId),
      );
    });
    this.addRouteFieldTarget.value = routeId;
    this.addSubmitTarget.disabled = false;
  }

  // ---- "Schedule route" sheet ---------------------------------------------

  pickDate(event) {
    this.scheduleDateTarget.value = event.currentTarget.dataset.date;
    this.scheduleSubmitTarget.disabled = false;
    this.renderMonthGrid();
  }

  shiftMonth({ params: { delta } }) {
    const [year, month] = this.view;
    const next = month + Number(delta);
    this.view =
      next < 0
        ? [year - 1, next + 12]
        : next > 11
          ? [year + 1, next - 12]
          : [year, next];
    this.renderMonthGrid();
  }

  // ---- sheet lifecycle (mob-sheet:closed resets picker state) --------------

  onSheetClosed(event) {
    if (event.detail.id === "add-route") this.resetAddSheet();
    if (event.detail.id === "schedule-route") this.resetScheduleSheet();
  }

  onScheduleSubmitEnd(event) {
    if (!event.detail.success) return;
    const date = this.scheduleDateTarget.value;
    if (!date) return;
    this.bookedDatesValue = [...new Set([...this.bookedDatesValue, date])];
  }

  resetAddSheet() {
    if (this.hasSearchTarget) this.searchTarget.value = "";
    this.filterRoutes();
    this.routeRowTargets.forEach((row) => row.classList.remove("is-selected"));
    if (this.hasAddRouteFieldTarget) this.addRouteFieldTarget.value = "";
    if (this.hasAddSubmitTarget) this.addSubmitTarget.disabled = true;
  }

  resetScheduleSheet() {
    if (this.hasScheduleDateTarget) this.scheduleDateTarget.value = "";
    if (this.hasScheduleSubmitTarget) this.scheduleSubmitTarget.disabled = true;
    this.view = this.viewOf(this.initialMonthValue || this.todayISO());
    this.renderMonthGrid();
  }

  // ---- month grid rendering (mirrors calendar_picker_controller) -----------

  renderMonthGrid() {
    if (!this.hasMonthGridTarget) return;

    const [year, month] = this.view;
    if (this.hasMonthLabelTarget) {
      this.monthLabelTarget.textContent = new Date(
        year,
        month,
        1,
      ).toLocaleString("en-US", { month: "long", year: "numeric" });
    }

    const first = new Date(year, month, 1);
    const cursor = new Date(year, month, 1 - first.getDay());
    const today = this.todayISO();
    const selected = this.hasScheduleDateTarget
      ? this.scheduleDateTarget.value
      : "";
    const booked = new Set(this.bookedDatesValue || []);

    let html = "";
    for (let i = 0; i < 42; i += 1) {
      const day = new Date(cursor);
      day.setDate(cursor.getDate() + i);
      const iso = this.isoOf(day);
      if (day.getMonth() !== month) {
        html += `<span class="calendar-day c-primary calendar-day--muted c-tertiary">${day.getDate()}</span>`;
      } else {
        const classes = ["calendar-day", "c-primary"];
        if (iso === today) classes.push("calendar-day--today");
        if (iso === selected) classes.push("calendar-day--selected");
        const dot = booked.has(iso)
          ? '<span class="mob-sheet__day-dot" aria-hidden="true"></span>'
          : "";
        html += `<button type="button" class="${classes.join(" ")}" data-date="${iso}" data-action="mob-week#pickDate">${day.getDate()}${dot}</button>`;
      }
    }
    this.monthGridTarget.innerHTML = html;
  }

  viewOf(iso) {
    const [year, month] = iso.split("-").map(Number);
    return [year, month - 1];
  }

  todayISO() {
    return this.isoOf(new Date());
  }

  isoOf(date) {
    const pad = (n) => String(n).padStart(2, "0");
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  }
}
