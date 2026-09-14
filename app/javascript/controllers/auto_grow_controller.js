import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  connect() {
    this.onObserverChange = this.onObserverChange.bind(this);
    this.observer = new ResizeObserver(this.onObserverChange);
    this.observer.observe(this.element);

    this.lastWidth = this.element.offsetWidth;
    this.resize();
  }

  disconnect() {
    this.observer.disconnect();
  }

  // Wired via data-action="input->auto-grow#resize"
  resize() {
    const el = this.element;
    const cs = getComputedStyle(el);

    const borders =
      parseFloat(cs.borderTopWidth) + parseFloat(cs.borderBottomWidth);

    el.style.overflowY = "hidden";
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight + borders}px`;
    // If a CSS max-height clamps the grown size, let the extra text scroll.
    el.style.overflowY =
      el.scrollHeight > el.clientHeight + 1 ? "auto" : "hidden";
    this.lastWidth = el.offsetWidth;
  }

  onObserverChange() {
    if (this.element.offsetWidth !== this.lastWidth) this.resize();
  }
}
