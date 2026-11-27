import { Turbo } from "@hotwired/turbo-rails"

const filterLinks = new WeakMap()
document.addEventListener("turbo:click", event => {
  const link = event.target
  const frame = link.closest("turbo-frame[data-filter-frame]")
  if (frame && link.dataset.turboFrame === frame.id) filterLinks.set(frame, link)
})

document.addEventListener("turbo:before-frame-render", event => {
  const frame = event.target
  if (!frame.matches("turbo-frame[data-filter-frame]")) return
  // Another tab can switch sites. The workspace header must change with the data.
  if (frame.dataset.filterFrame !== event.detail.newFrame.dataset.filterFrame) {
    event.preventDefault()
    window.location.assign(frame.src)
    return
  }
  event.detail.render = (current, incoming) => {
    // Measure at render time so scrolling while the request was in flight is respected.
    const link = filterLinks.get(current)
    filterLinks.delete(current)
    const bounds = link?.getBoundingClientRect()
    const keepPosition = bounds && bounds.bottom > 0 && bounds.top < window.innerHeight
    const hadFocus = link && document.activeElement === link
    for (const details of current.querySelectorAll("details[id][open]")) {
      const replacement = incoming.querySelector(`details#${CSS.escape(details.id)}`)
      if (replacement) replacement.open = true
    }
    // Morph in place. Removing and reinserting the tall map would collapse the
    // document temporarily and make the browser clamp its scroll position.
    Turbo.morphChildren(current, incoming, { callbacks: {
      beforeNodeMorphed: (node, next) => !(node.hasAttribute("data-saved-map") && node.id === next?.id)
    } })
    if (!link) return
    const updated = current.querySelector(`#${CSS.escape(link.id)}`)
    if (!updated) return
    if (hadFocus && document.activeElement !== updated) updated.focus({ preventScroll: true })
    if (keepPosition) {
      const delta = updated.getBoundingClientRect().top - bounds.top
      if (Math.abs(delta) >= 1) window.scrollBy({ top: delta, behavior: "instant" })
    }
  }
})

// A sign-in redirect or error page has no results frame. Load its full layout.
document.addEventListener("turbo:frame-missing", event => {
  if (!event.target.matches("turbo-frame[data-filter-frame]")) return
  event.preventDefault()
  window.location.assign(event.detail.response.url)
})

document.addEventListener("keydown", event => {
  if (event.key !== "Escape") return
  const menu = document.querySelector(".switcher[open]")
  if (menu) {
    menu.open = false
    menu.querySelector("summary").focus()
  }
})

document.addEventListener("click", event => {
  const menu = document.querySelector(".switcher[open]")
  if (menu && !menu.contains(event.target)) menu.open = false
})

let assistantPoll
let assistantPath
let pollCount = 0

document.addEventListener("turbo:before-visit", () => clearTimeout(assistantPoll))
document.addEventListener("turbo:load", () => {
  clearTimeout(assistantPoll)
  if (!document.querySelector("[data-ai-pending]")) {
    assistantPath = undefined
    return
  }
  if (assistantPath !== location.pathname) {
    assistantPath = location.pathname
    pollCount = 0
  }
  if (pollCount >= 12) return
  pollCount += 1
  assistantPoll = setTimeout(() => {
    if (!document.hidden && document.querySelector("[data-ai-pending]")) {
      window.Turbo.visit(location.href, {action: "replace"})
    }
  }, Math.min(pollCount * 1500, 15000))
})

function updateStreetMap(image) {
  const views = image.closest(".lf-views")
  if (!views || !image.complete) return

  const street = views.querySelector("#lf-street")
  const notice = views.querySelector("[data-lf-map-unavailable]")
  const retry = notice.querySelector("[data-lf-retry]")
  retry.disabled = false
  if (image.naturalWidth > 0) {
    if (!notice.hidden) {
      street.disabled = false
      street.checked = true
      if (document.activeElement === retry) street.focus()
      notice.hidden = true
    }
  } else {
    street.disabled = true
    views.querySelector("#lf-pins").checked = true
    notice.hidden = false
  }
}

for (const eventName of ["error", "load"]) {
  document.addEventListener(eventName, event => {
    if (event.target instanceof HTMLImageElement && event.target.matches("[data-lf-street-image]")) {
      updateStreetMap(event.target)
    }
  }, true)
}

document.addEventListener("click", event => {
  const retry = event.target.closest?.("[data-lf-retry]")
  if (!retry) return
  const image = retry.closest(".lf-views").querySelector("[data-lf-street-image]")
  retry.disabled = true
  image.src = image.getAttribute("src")
})

// Back can restore the form selection from before submission. Reset to the rendered scan.
window.addEventListener("pageshow", () => {
  const picker = document.querySelector(".lf-picker")
  if (picker) requestAnimationFrame(() => picker.reset())
})

// An image may already have finished loading before a Turbo visit or restoration.
document.addEventListener("turbo:load", () => {
  const image = document.querySelector("[data-lf-street-image]")
  if (image) updateStreetMap(image)
})

// Native submission preserves the link-check fragment in the server redirect.
document.addEventListener("submit", event => {
  if (!event.target.matches(".action-link-check-form, .cp-advice-form, .cp-listing-form")) return
  const progress = event.target.nextElementSibling
  if (progress?.matches("[data-review-progress]")) progress.hidden = false
})
window.addEventListener("pageshow", () => {
  document.querySelectorAll("[data-review-progress]").forEach(progress => { progress.hidden = true })
})

// The request remains ordinary selectable text when clipboard access is unavailable.
document.addEventListener("turbo:load", () => {
  document.querySelectorAll("[data-copy-handoff]").forEach(button => { button.hidden = false })
})

document.addEventListener("click", async event => {
  const button = event.target.closest?.("[data-copy-handoff]")
  if (!button) return
  const section = button.closest("section")
  const request = section.querySelector("[data-action-handoff]")
  const status = section.querySelector("[data-copy-status]")
  try {
    await navigator.clipboard.writeText(request.value)
    status.textContent = "Instructions copied."
  } catch {
    const details = request.closest("details")
    if (details) details.open = true
    request.focus()
    request.select()
    status.textContent = "Text selected. Use your device’s Copy command."
  }
})
