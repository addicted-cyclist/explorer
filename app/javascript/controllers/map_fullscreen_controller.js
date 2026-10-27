import { Controller } from "@hotwired/stimulus";

// Full-screen map toggle for the route detail page's gpx.studio embed
// (FEATURES: open route map on full screen). Native Fullscreen API first —
// true OS fullscreen on desktop and Android. When the API is unavailable or
// refuses (iPhone Safari only fullscreens <video>), falls back to a fixed
// overlay class that covers the viewport. The card head (pill + exit button)
// stays visible in both paths; Escape exits either.
export default class extends Controller {
  static targets = ["icon"];

  connect() {
    this.boundSync = this.sync.bind(this);
    this.boundKeydown = this.handleKeydown.bind(this);
    document.addEventListener("fullscreenchange", this.boundSync);
    document.addEventListener("webkitfullscreenchange", this.boundSync);
    document.addEventListener("keydown", this.boundKeydown);
  }

  disconnect() {
    document.removeEventListener("fullscreenchange", this.boundSync);
    document.removeEventListener("webkitfullscreenchange", this.boundSync);
    document.removeEventListener("keydown", this.boundKeydown);
    // Never leak the scroll lock or fullscreen state across Turbo visits.
    if ((document.fullscreenElement || document.webkitFullscreenElement) === this.element) {
      (document.exitFullscreen || document.webkitExitFullscreen)?.call(document);
    }
    this.collapse();
  }

  toggle() {
    this.isOpen ? this.close() : this.open();
  }

  get isOpen() {
    const fsElement = document.fullscreenElement || document.webkitFullscreenElement;
    return fsElement === this.element ||
           this.element.classList.contains("route-detail__map--expanded");
  }

  open() {
    const request = this.element.requestFullscreen || this.element.webkitRequestFullscreen;
    if (!request) return this.expand(); // iPhone Safari: no element fullscreen

    // A rejection (permission/policy) degrades to the CSS overlay fallback.
    const result = request.call(this.element);
    if (result && typeof result.catch === "function") result.catch(() => this.expand());
  }

  close() {
    const exit = document.exitFullscreen || document.webkitExitFullscreen;
    if ((document.fullscreenElement || document.webkitFullscreenElement) && exit) {
      exit.call(document);
    } else {
      this.collapse();
    }
  }

  // CSS overlay fallback: fixed positioning instead of element fullscreen.
  expand() {
    this.element.classList.add("route-detail__map--expanded");
    document.body.classList.add("has-open-map");
    this.setIcon("fullscreen_exit");
  }

  collapse() {
    this.element.classList.remove("route-detail__map--expanded");
    document.body.classList.remove("has-open-map");
    this.setIcon("fullscreen");
  }

  // Native path: the user can leave fullscreen via Esc, F11 or the browser
  // UI without the button being involved — keep the icon honest.
  sync() {
    this.setIcon(this.isOpen ? "fullscreen_exit" : "fullscreen");
  }

  // Fallback path: only the controller can exit the overlay.
  handleKeydown(event) {
    if (event.key === "Escape" &&
        this.element.classList.contains("route-detail__map--expanded")) {
      this.collapse();
    }
  }

  setIcon(name) {
    if (this.hasIconTarget) this.iconTarget.textContent = name;
  }
}
