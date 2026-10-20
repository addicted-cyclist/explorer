import { Controller } from "@hotwired/stimulus"

// v0.12 — verify-email modal UX (design-refs/stitch_explorer_v0.12): six
// single-digit OTP boxes that auto-advance (backspace walks back, a paste
// distributes all six digits) plus a resend link counting down the
// server-driven cooldown (1 minute) before it can fire again. Also toggles
// the inline change-email form, shared by the hard gate and the soft modal.
export default class extends Controller {
  static targets = ["input", "resend", "resendLabel", "emailForm"]
  static values = { cooldown: Number }

  connect() {
    this.startCooldown()
  }

  disconnect() {
    this.stopCooldown()
  }

  // Keep one digit per box and walk forward as the user types.
  input(event) {
    const field = event.target
    field.value = field.value.replace(/\D/g, "").slice(-1)
    if (field.value !== "") this.focusNext(field)
  }

  // Backspace on an empty box walks back to the previous digit and clears it.
  keydown(event) {
    if (event.key !== "Backspace") return

    const index = this.inputTargets.indexOf(event.target)
    if (index > 0 && event.target.value === "") {
      event.preventDefault()
      const previous = this.inputTargets[index - 1]
      previous.value = ""
      previous.focus()
    }
  }

  // A pasted code fills every box from the one receiving the paste.
  paste(event) {
    const digits = (event.clipboardData?.getData("text") ?? "").match(/\d/g)
    if (!digits) return

    event.preventDefault()
    const start = this.inputTargets.indexOf(event.target)
    this.inputTargets.slice(start).forEach((box, index) => {
      box.value = digits[index] ?? ""
    })
    this.focusAfter(Math.min(start + digits.length, this.inputTargets.length - 1))
  }

  // The resend button stays disabled while the server-side cooldown runs;
  // the label renders the actual remaining seconds. A successful resend
  // reloads the page and re-seeds this.cooldownValue from the server.
  startCooldown() {
    this.renderCooldown()
    if (this.cooldownValue <= 0) return

    this.timer = setInterval(() => {
      this.cooldownValue -= 1
      this.renderCooldown()
    }, 1000)
  }

  stopCooldown() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  renderCooldown() {
    if (!this.hasResendTarget || !this.hasResendLabelTarget) return

    const button = this.resendTarget.querySelector("button")
    if (this.cooldownValue > 0) {
      button.disabled = true
      this.resendLabelTarget.textContent = `Resend code (${this.cooldownValue}s)`
    } else {
      button.disabled = false
      this.resendLabelTarget.textContent = "Resend code"
      this.stopCooldown()
    }
  }

  // Reveal/hide the inline change-email form (gate + soft modal).
  toggleEmailForm(event) {
    event.preventDefault()
    this.emailFormTarget.hidden = !this.emailFormTarget.hidden
    if (!this.emailFormTarget.hidden) {
      this.emailFormTarget.querySelector("input")?.focus()
    }
  }

  focusNext(field) {
    this.focusAfter(this.inputTargets.indexOf(field) + 1)
  }

  focusAfter(index) {
    const next = this.inputTargets[index]
    if (next) {
      next.focus()
      next.select()
    }
  }
}