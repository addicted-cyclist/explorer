import { Controller } from "@hotwired/stimulus"

// Fullscreen dialog overlay for the route library (upload + edit modals).
// Each `.modal` element owns one instance. Opening is declarative: any
// element on the page with `data-modal-open="<modal id>"` opens it. A modal
// rendered inside a Turbo Frame can open itself on connect with
// `data-modal-auto-open="true"`. Backdrop click, the close button and
// Escape all dismiss it — unless the modal is locked
// (`data-modal-locked="true"`; the verify-email hard gate). A dismissable
// modal may also carry `data-modal-snooze="<cookie name>"` (+ optional
// `data-modal-snooze-hours`, default 24): hiding it writes that cookie, and
// the server keeps the modal closed while it is set (verify-email nag).
export default class extends Controller {
  connect() {
    this.previouslyFocused = null
    this.boundOpenFromTrigger = this.openFromTrigger.bind(this)
    this.boundKeydown = this.onKeydown.bind(this)
    document.addEventListener("click", this.boundOpenFromTrigger)
    document.addEventListener("keydown", this.boundKeydown)

    if (this.element.dataset.modalAutoOpen === "true") this.open()
  }

  disconnect() {
    document.removeEventListener("click", this.boundOpenFromTrigger)
    document.removeEventListener("keydown", this.boundKeydown)
    document.body.classList.remove("has-open-modal")
  }

  // data-action="modal#close" (backdrop, close button, Cancel)
  close() {
    this.hide()
  }

  openFromTrigger(event) {
    const trigger = event.target.closest("[data-modal-open]")
    if (!trigger) return
    if (trigger.dataset.modalOpen !== this.element.dataset.modalId) return

    event.preventDefault()
    this.open()
  }

  onKeydown(event) {
    if (event.key === "Escape" && this.isOpen) this.hide()
  }

  get isOpen() {
    return this.element.classList.contains("is-open")
  }

  open() {
    this.closeAllOthers()
    this.previouslyFocused = document.activeElement
    this.element.classList.add("is-open")
    this.element.setAttribute("aria-hidden", "false")
    document.body.classList.add("has-open-modal")
    this.element.querySelector("input, select, textarea, button")?.focus()
  }

  hide() {
    if (!this.isOpen || this.isLocked) return

    this.element.classList.remove("is-open")
    this.element.setAttribute("aria-hidden", "true")
    document.body.classList.remove("has-open-modal")
    this.previouslyFocused?.focus?.()
    this.previouslyFocused = null
    this.writeSnooze()
  }

  // Locked modals (verify-email hard gate) ignore every dismissal path.
  get isLocked() {
    return this.element.dataset.modalLocked === "true"
  }

  // Remember the dismissal in a cookie the layout checks, so the modal
  // stays closed for the configured hours (verify-email soft nag).
  writeSnooze() {
    const name = this.element.dataset.modalSnooze
    if (!name) return

    const hours = Number(this.element.dataset.modalSnoozeHours) || 24
    document.cookie = `${name}=1; path=/; max-age=${hours * 60 * 60}; samesite=lax`
  }

  closeAllOthers() {
    document.querySelectorAll(".modal.is-open").forEach((modal) => {
      if (modal === this.element) return
      modal.classList.remove("is-open")
      modal.setAttribute("aria-hidden", "true")
    })
  }
}
