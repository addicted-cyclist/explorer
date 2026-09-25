import { Controller } from "@hotwired/stimulus";

// Dot-nav slider for days with several scheduled routes (Phase 8, mechanic:
// swipe). The track is a native horizontal scroll-snap container — swipes
// are the browser's own — while this controller keeps the dots in sync with
// the snapped slide and lets the dots drive the track back.
export default class extends Controller {
  static targets = ["track", "dot"];

  connect() {
    this.onScroll = () => this.sync();
    this.trackTarget.addEventListener("scroll", this.onScroll, { passive: true });
    this.sync();
  }

  disconnect() {
    this.trackTarget.removeEventListener("scroll", this.onScroll);
  }

  goTo({ params: { index } }) {
    const slide = this.trackTarget.children[index];
    if (slide) this.trackTarget.scrollTo({ left: slide.offsetLeft, behavior: "smooth" });
  }

  sync() {
    const track = this.trackTarget;
    const index = Math.round(track.scrollLeft / track.clientWidth);
    this.dotTargets.forEach((dot, i) => {
      dot.classList.toggle("is-active", i === index);
      dot.setAttribute("aria-current", i === index ? "true" : "false");
    });
  }
}
