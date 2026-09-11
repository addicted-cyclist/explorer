import { Controller } from "@hotwired/stimulus"

// Drag-and-drop + click-to-browse for the GPX upload dropzone. Dropped files
// are routed through the (visually hidden) file input so the form submits a
// normal multipart payload — no custom upload logic needed.
export default class extends Controller {
  static targets = ["zone", "input", "files"]

  browse() {
    this.inputTarget.click()
  }

  dragOver(event) {
    event.preventDefault()
    this.zoneTarget.classList.add("is-dragover")
  }

  dragLeave() {
    this.zoneTarget.classList.remove("is-dragover")
  }

  drop(event) {
    event.preventDefault()
    this.zoneTarget.classList.remove("is-dragover")

    const { files } = event.dataTransfer
    if (!files || files.length === 0) return

    this.inputTarget.files = files
    this.renderFileList(files)
  }

  changed() {
    this.renderFileList(this.inputTarget.files)
  }

  renderFileList(fileList) {
    const names = Array.from(fileList).map((file) => file.name)

    if (names.length === 0) {
      this.filesTarget.hidden = true
      this.filesTarget.textContent = ""
      return
    }

    this.filesTarget.hidden = false
    this.filesTarget.textContent =
      names.length === 1
        ? names[0]
        : `${names.length} files selected: ${names.join(", ")}`
  }
}
