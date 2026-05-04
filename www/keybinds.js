// Market Stress Copilot — keyboard shortcuts
// ⌘1..5 / Ctrl1..5 → switch sidebar nav

(function () {
  const TAB_BY_KEY = {
    "1": "equities",
    "2": "crypto",
    "3": "risk",
    "4": "quality",
    "5": "alerts",
  };

  function isEditableTarget(el) {
    if (!el) return false;
    const tag = (el.tagName || "").toLowerCase();
    if (tag === "input" || tag === "textarea" || tag === "select") return true;
    if (el.isContentEditable) return true;
    return false;
  }

  document.addEventListener("keydown", function (e) {
    if (!(e.metaKey || e.ctrlKey)) return;
    if (e.altKey || e.shiftKey) return;
    if (isEditableTarget(e.target)) return;
    const target = TAB_BY_KEY[e.key];
    if (!target) return;
    e.preventDefault();
    if (window.Shiny && Shiny.setInputValue) {
      Shiny.setInputValue("nav_to", target, { priority: "event" });
    }
  });
})();
