import { Controller } from "@hotwired/stimulus";

// Month-grid date picker for "Add to my calendar".
// Renders the grid client-side; picking a date (or Today) only stages it so
// the user can still pick a start time, Done submits the wrapping form with
// both (rescheduling the picker's tracked entry instead of stacking a
// duplicate), and outside click / Escape dismiss without commit (same
// disclosure pattern as the dropdown). Adjacent-month days render muted and
// inert.
export default class extends Controller {
  static targets = [
    "popover",
    "trigger",
    "label",
    "grid",
    "hidden",
    "form",
    "chipLabel",
  ];

  connect() {
    this.view = this.viewOf(this.hiddenTarget.value || this.todayISO());
    this.render();
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
    if (this.popoverTarget.hidden) {
      this.popoverTarget.hidden = false;
    } else {
      this.close();
    }
  }

  close() {
    this.popoverTarget.hidden = true;
  }

  // Clicking anywhere outside the picker dismisses the open popover
  // without committing.
  handleOutsideClick(event) {
    if (!this.popoverTarget.hidden && !this.element.contains(event.target))
      this.close();
  }

  // Escape dismisses and hands focus back to the disclosure trigger.
  handleKeydown(event) {
    if (event.key === "Escape" && !this.popoverTarget.hidden) {
      this.close();
      if (this.hasTriggerTarget) this.triggerTarget.focus();
    }
  }

  prev() {
    this.shiftMonth(-1);
  }

  next() {
    this.shiftMonth(1);
  }

  // A date click only stages it — the user still picks a start time before
  // committing with Done.
  pick(event) {
    event.stopPropagation();

    this.hiddenTarget.value = event.currentTarget.dataset.date;
    this.render();
  }

  // Today stages today's date and jumps the view to the current month.
  today() {
    this.hiddenTarget.value = this.todayISO();
    this.view = this.viewOf(this.hiddenTarget.value);
    this.render();
  }

  // Done commits the staged date together with the chosen start time; with
  // nothing staged there is nothing to commit — just close.
  done() {
    if (this.hiddenTarget.value) this.formTarget.requestSubmit();
    this.close();
  }

  // The allocate/remove Turbo Streams repaint the whole picker fragment with
  // fresh server state; these submit-end refreshes are the same-tick preview
  // from the date the picker itself just committed. The card variant renders
  // no chip label, hence the guard.
  onScheduleSubmitEnd(event) {
    if (!event.detail.success) return;
    if (this.hasChipLabelTarget) {
      this.chipLabelTarget.textContent = `Added to ${this.shortDate(this.hiddenTarget.value)}`;
    }
  }

  onRemoveSubmitEnd(event) {
    if (!event.detail.success) return;
    this.hiddenTarget.value = "";
    if (this.hasChipLabelTarget)
      this.chipLabelTarget.textContent = "Add to calendar";
    this.close();
    this.render();
  }

  // "Oct 3" for the chip, matching the server-rendered %b %-d format
  shortDate(iso) {
    const [year, month, day] = iso.split("-").map(Number);
    return new Date(year, month - 1, day).toLocaleString("en-US", {
      month: "short",
      day: "numeric",
    });
  }

  // ---- rendering ---------------------------------------------------------

  render() {
    const [year, month] = this.view;
    this.labelTarget.textContent = new Date(year, month, 1).toLocaleString(
      "en-US",
      { month: "long", year: "numeric" },
    );

    const first = new Date(year, month, 1);
    const cursor = new Date(year, month, 1 - first.getDay());
    const selected = this.hiddenTarget.value;
    const today = this.todayISO();

    let html = "";
    for (let i = 0; i < 42; i++) {
      const day = new Date(cursor);
      day.setDate(cursor.getDate() + i);
      const iso = this.isoOf(day);
      if (day.getMonth() === month) {
        const classes = ["calendar-day", "c-primary"];
        if (iso === today) classes.push("calendar-day--today");
        if (iso === selected) classes.push("calendar-day--selected");
        html += `<button type="button" class="${classes.join(" ")}" data-date="${iso}" data-action="calendar-picker#pick">${day.getDate()}</button>`;
      } else {
        html += `<span class="calendar-day c-primary calendar-day--muted c-tertiary">${day.getDate()}</span>`;
      }
    }
    this.gridTarget.innerHTML = html;
  }

  shiftMonth(delta) {
    const [year, month] = this.view;
    this.view =
      month + delta < 0
        ? [year - 1, 11]
        : month + delta > 11
          ? [year + 1, 0]
          : [year, month + delta];
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
