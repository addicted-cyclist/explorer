import { Controller } from "@hotwired/stimulus";

// Completion celebration (design-refs/stitch_explorer_v0.11): on check
// submit the card's completed class flips in place — the toggle_completed
// PATCH only persists (204 No Content, no repaint anywhere) — then the card
// bounces, the check pops and a confetti burst fires from the check button.
// The particle engine is ported from the reference mock's canvas confetti
// physics; the canvas is a page-wide singleton created on the first burst.
// Only checking celebrates — unchecking just un-dims the card, no burst.

const PALETTE = [
  "#06B6D4",
  "#10B981",
  "#F59E0B",
  "#8B5CF6",
  "#F43F5E",
  "#EC4899",
  "#38BDF8",
];
const BURST_COUNT = 55;

let canvas = null;
let particles = [];
let animating = false;

function ensureCanvas() {
  // Turbo swaps the <body> on navigation, which detaches the canvas —
  // rebuild (and drop the dead particles) whenever it is no longer connected.
  if (canvas && canvas.isConnected) return canvas;

  canvas = document.createElement("canvas");
  canvas.className = "confetti-canvas";
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
  particles = [];
  animating = false;
  document.body.appendChild(canvas);
  return canvas;
}

class Particle {
  constructor(x, y) {
    this.x = x;
    this.y = y;
    const angle = Math.random() * Math.PI * 2;
    const speed = Math.random() * 8.5 + 4.5;
    this.vx = Math.cos(angle) * speed * (0.8 + Math.random() * 0.4);
    this.vy = Math.sin(angle) * speed - (Math.random() * 4 + 3);
    this.gravity = 0.28;
    this.drag = 0.94;
    this.color = PALETTE[Math.floor(Math.random() * PALETTE.length)];
    this.type =
      Math.random() > 0.4 ? "rect" : Math.random() > 0.5 ? "circle" : "ribbon";
    this.size = Math.random() * 6 + 5;
    this.length = this.type === "ribbon" ? this.size * 2.4 : this.size;
    this.rotation = Math.random() * Math.PI * 2;
    this.rotSpeed = (Math.random() - 0.5) * 0.25;
    this.opacity = 1;
    this.fadeRate = Math.random() * 0.015 + 0.012;
    this.wobble = Math.random() * 10;
    this.wobbleSpeed = Math.random() * 0.12 + 0.05;
  }

  update() {
    this.vx *= this.drag;
    this.vy *= this.drag;
    this.vy += this.gravity;
    this.x += this.vx;
    this.y += this.vy;
    this.rotation += this.rotSpeed;
    this.wobble += this.wobbleSpeed;
    this.opacity -= this.fadeRate;
    return this.opacity > 0;
  }

  draw(context) {
    context.save();
    context.translate(this.x, this.y);
    context.rotate(this.rotation);
    context.globalAlpha = Math.max(0, this.opacity);
    context.fillStyle = this.color;

    const scaleX = Math.cos(this.wobble);

    if (this.type === "circle") {
      context.beginPath();
      context.ellipse(
        0,
        0,
        Math.abs(this.size * scaleX) / 2,
        this.size / 2,
        0,
        0,
        Math.PI * 2,
      );
      context.fill();
    } else {
      const width = Math.abs(this.size * scaleX);
      context.fillRect(-width / 2, -this.length / 2, width, this.length);
    }
    context.restore();
  }
}

function burst(originX, originY) {
  const context = ensureCanvas().getContext("2d");
  for (let i = 0; i < BURST_COUNT; i += 1)
    particles.push(new Particle(originX, originY));
  if (animating) return;
  animating = true;

  const animate = () => {
    context.clearRect(0, 0, canvas.width, canvas.height);
    particles = particles.filter((particle) => {
      const alive = particle.update();
      if (alive) particle.draw(context);
      return alive;
    });
    if (particles.length > 0) {
      requestAnimationFrame(animate);
    } else {
      animating = false;
    }
  };
  requestAnimationFrame(animate);
}

export default class CompletionConfettiController extends Controller {
  connect() {
    // Only my-view cards carry a check button; friend/public cards connect
    // as no-ops.
    const check = this.element.querySelector(
      ".wc-entry__check, .mob-wc__entry-check",
    );
    if (!check || !check.form) return;
    this.check = check;
    this.onCheckSubmit = () => this.handleCheckSubmit();
    check.form.addEventListener("submit", this.onCheckSubmit);
    this.bindCelebrationCleanup();
  }

  disconnect() {
    if (!this.check) return;
    this.check.form?.removeEventListener("submit", this.onCheckSubmit);
    this.check = null;
  }

  handleCheckSubmit() {
    // Flip the completed class in place — no repaint anywhere. The PATCH
    // (204 No Content) only persists, so this optimistic state stands; if
    // the request fails, the error page load restores the server truth.
    const completedClass = this.element.classList.contains("wc-entry")
      ? "wc-entry--completed"
      : "mob-wc__entry--completed";
    const checking = !this.element.classList.contains(completedClass);
    this.element.classList.toggle(completedClass, checking);
    this.check.setAttribute(
      "aria-label",
      checking ? "Mark as not completed" : "Mark as completed",
    );

    // Only checking celebrates — unchecking just un-dims the card.
    if (!checking) return;

    this.celebrate();
  }

  bindCelebrationCleanup() {
    // animationend bubbles, so match on the target + animation name — the
    // check's earlier pop must not cut the card's longer bounce short.
    this.element.addEventListener("animationend", (event) => {
      if (
        event.target === this.element &&
        event.animationName === "celebration-card-bounce"
      ) {
        this.element.classList.remove("celebration-bounce");
      }
    });
    this.check.addEventListener("animationend", (event) => {
      if (event.animationName === "celebration-check-pop") {
        this.check.classList.remove("celebration-check-pop");
      }
    });
  }

  celebrate() {
    const card = this.element;
    const check = this.check;
    // Restart the keyframes even if a previous run's class lingered.
    card.classList.remove("celebration-bounce");
    check.classList.remove("celebration-check-pop");
    void card.offsetWidth;
    card.classList.add("celebration-bounce");
    check.classList.add("celebration-check-pop");

    const rect = check.getBoundingClientRect();
    burst(rect.left + rect.width / 2, rect.top + rect.height / 2);
  }
}
