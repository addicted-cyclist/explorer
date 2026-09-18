import { Controller } from "@hotwired/stimulus";

// Month-grid date picker for "Add to my calendar" (design: route_detail).
// Renders the grid client-side; picking a date (or Today) fills the hidden
// scheduled_on field and submits the wrapping form immediately, Done just
// closes the popover. Adjacent-month days render muted and inert.
export default class extends Controller {
  static targets = ["popover", "label", "grid", "hidden", "form", "chipLabel"];
  static values = { scheduled: String };

  connect() {
    this.view = this.viewOf(this.hiddenTarget.value || this.scheduledValue || this.todayISO());
    this.render();
  }

  toggle() {
    if (this.popoverTarget.hidden) {
      this.popoverTarget.hidden = false;
    } else {
      this.close();
    }
  }

  close() {
    this.popoverTarget.hidden = true;
  }

  prev() {
    this.shiftMonth(-1);
  }

  next() {
    this.shiftMonth(1);
  }

  // A date click commits straight away: hidden field + submit.
  pick(event) {
    this.hiddenTarget.value = event.currentTarget.dataset.date;
    this.submit();
  }

  // Today jumps to and commits today's date.
  today() {
    this.hiddenTarget.value = this.todayISO();
    this.view = this.viewOf(this.hiddenTarget.value);
    this.render();
    this.submit();
  }

  submit() {
    if (!this.hiddenTarget.value) return;
    this.close();
    this.formTarget.requestSubmit();
  }

  // The allocate/remove Turbo Streams only repaint wc-day-* day columns,
  // which don't exist on the detail page — so the chip label is kept in sync
  // here, from the date the picker itself just committed.
  onScheduleSubmitEnd(event) {
    if (!event.detail.success) return;
    this.scheduledValue = this.hiddenTarget.value;
    this.chipLabelTarget.textContent = `Added to ${this.shortDate(this.hiddenTarget.value)}`;
  }

  onRemoveSubmitEnd(event) {
    if (!event.detail.success) return;
    this.hiddenTarget.value = "";
    this.scheduledValue = "";
    this.chipLabelTarget.textContent = "Add to calendar";
    this.close();
    this.render();
  }

  // "Oct 3" for the chip, matching the server-rendered %b %-d format
  shortDate(iso) {
    const [year, month, day] = iso.split("-").map(Number);
    return new Date(year, month - 1, day).toLocaleString("en-US", { month: "short", day: "numeric" });
  }

  // ---- rendering ---------------------------------------------------------

  render() {
    const [year, month] = this.view;
    this.labelTarget.textContent =
      new Date(year, month, 1).toLocaleString("en-US", { month: "long", year: "numeric" });

    const first = new Date(year, month, 1);
    const cursor = new Date(year, month, 1 - first.getDay());
    const selected = this.hiddenTarget.value || this.scheduledValue;
    const today = this.todayISO();

    let html = "";
    for (let i = 0; i < 42; i++) {
      const day = new Date(cursor);
      day.setDate(cursor.getDate() + i);
      const iso = this.isoOf(day);
      if (day.getMonth() === month) {
        const classes = ["calendar-day"];
        if (iso === today) classes.push("calendar-day--today");
        if (iso === selected) classes.push("calendar-day--selected");
        html += `<button type="button" class="${classes.join(" ")}" data-date="${iso}" data-action="calendar-picker#pick">${day.getDate()}</button>`;
      } else {
        html += `<span class="calendar-day calendar-day--muted">${day.getDate()}</span>`;
      }
    }
    this.gridTarget.innerHTML = html;
  }

  shiftMonth(delta) {
    const [year, month] = this.view;
    this.view = month + delta < 0 ? [year - 1, 11] : month + delta > 11 ? [year + 1, 0] : [year, month + delta];
    this.render();
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
