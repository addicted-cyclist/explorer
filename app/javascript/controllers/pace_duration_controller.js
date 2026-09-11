import { Controller } from "@hotwired/stimulus";

// Links the Est. Duration and Moving Pace metric inputs on the route detail
// page: pace = distance / duration. Editing either recalculates the other,
// writes whole seconds into the hidden route[duration] field and saves the
// wrapping form. Pace is derived only — duration is what persists.
export default class extends Controller {
  static targets = ["duration", "pace", "hidden"];
  static values = { distance: Number };

  durationChanged() {
    const seconds = this.parseDuration(this.durationTarget.value);
    if (!seconds || seconds <= 0) return;

    this.hiddenTarget.value = Math.round(seconds);
    if (this.distanceValue > 0) {
      this.paceTarget.value = this.formatPace(this.distanceValue / (seconds / 3600.0));
    }
    this.element.requestSubmit();
  }

  paceChanged() {
    const pace = parseFloat(String(this.paceTarget.value).replace(",", "."));
    if (!Number.isFinite(pace) || pace <= 0 || this.distanceValue <= 0) return;

    const seconds = Math.round((this.distanceValue / pace) * 3600.0);
    this.hiddenTarget.value = seconds;
    this.durationTarget.value = this.formatDuration(seconds);
    this.element.requestSubmit();
  }

  // Accepts "6h 15m", "6h", "45m", "6:15", "6.25" (decimal = hours) and a
  // bare integer ("45" = minutes, matching the displayed "45 min" style).
  // Returns NaN when nothing sensible can be read.
  parseDuration(raw) {
    const text = String(raw).trim().toLowerCase();
    if (!text) return NaN;

    let match = text.match(/^(\d+)\s*h(?:\s+(\d{1,2})\s*m?)?$/);
    if (match) return Number(match[1]) * 3600 + Number(match[2] || 0) * 60;

    match = text.match(/^(\d{1,2}):(\d{2})$/);
    if (match) return Number(match[1]) * 3600 + Number(match[2]) * 60;

    match = text.match(/^(\d+(?:\.\d+)?)\s*(h|hr|hrs|hours|m|min|mins)?$/);
    if (!match) return NaN;

    const value = Number(match[1]);
    if (!Number.isFinite(value) || value <= 0) return NaN;
    const unit = match[2];
    if (unit && unit !== "h" && unit !== "hr" && unit !== "hrs" && unit !== "hours") {
      return value * 60;
    }
    if (!unit && Number.isInteger(value) && value <= 120) return value * 60;
    return value * 3600;
  }

  // 22500 -> "6h 15m", 2700 -> "45m", 3600 -> "1h"
  formatDuration(seconds) {
    let hours = Math.floor(seconds / 3600);
    let minutes = Math.round((seconds % 3600) / 60);
    if (minutes === 60) {
      hours += 1;
      minutes = 0;
    }
    if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
    return `${minutes}m`;
  }

  // 30.0 -> "30", 27.6 -> "27.6"
  formatPace(pace) {
    const rounded = Math.round(pace * 10) / 10;
    return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(1);
  }
}
