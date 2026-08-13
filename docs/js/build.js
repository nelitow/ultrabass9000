/*
 * Copy-to-clipboard for the "Build from source" terminal block.
 *
 * Tries the async Clipboard API first (needs a secure context — https or
 * localhost). Falls back to the classic textarea + execCommand('copy')
 * trick, which still works on a plain file:// origin, since this page has
 * to work opened directly from disk with no build step.
 */
(function () {
  function legacyCopy(text) {
    try {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "-1000px";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, text.length);
      var ok = document.execCommand("copy");
      document.body.removeChild(ta);
      return ok;
    } catch (e) {
      return false;
    }
  }

  function copyText(text) {
    if (window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).then(
        function () { return true; },
        function () { return legacyCopy(text); }
      );
    }
    return Promise.resolve(legacyCopy(text));
  }

  function init() {
    var buttons = document.querySelectorAll(".code-copy");
    buttons.forEach(function (btn) {
      var targetId = btn.getAttribute("data-copy-target");
      var target = targetId && document.getElementById(targetId);
      if (!target) return;
      var idleLabel = btn.textContent;
      btn.addEventListener("click", function () {
        copyText(target.textContent.trim()).then(function (ok) {
          btn.textContent = ok ? "Copied" : "Copy failed";
          btn.disabled = true;
          setTimeout(function () {
            btn.textContent = idleLabel;
            btn.disabled = false;
          }, 1600);
        });
      });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
