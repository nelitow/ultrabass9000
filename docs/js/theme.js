/*
 * Minimal light/dark toggle.
 *
 * Default (no [data-theme] attribute) follows the OS via the
 * prefers-color-scheme rules in nelitomorphism/theme-light.css. Clicking the
 * toggle sets an explicit [data-theme] on <html> and remembers it; the
 * button label always names the mode a click will switch TO.
 */
(function () {
  var root = document.documentElement;
  var STORAGE_KEY = "ub9k-theme";

  function systemPrefersLight() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches;
  }

  function currentMode() {
    var explicit = root.getAttribute("data-theme");
    if (explicit === "light" || explicit === "dark") return explicit;
    return systemPrefersLight() ? "light" : "dark";
  }

  function updateLabel(btn) {
    var mode = currentMode();
    var next = mode === "light" ? "dark" : "light";
    btn.textContent = next + " mode";
    btn.setAttribute("aria-label", "Switch to " + next + " mode");
  }

  function init() {
    var stored = null;
    try { stored = localStorage.getItem(STORAGE_KEY); } catch (e) {}
    if (stored === "light" || stored === "dark") root.setAttribute("data-theme", stored);

    var btn = document.getElementById("theme-toggle");
    if (!btn) return;
    updateLabel(btn);

    btn.addEventListener("click", function () {
      var next = currentMode() === "light" ? "dark" : "light";
      root.setAttribute("data-theme", next);
      try { localStorage.setItem(STORAGE_KEY, next); } catch (e) {}
      updateLabel(btn);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
