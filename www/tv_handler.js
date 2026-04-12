(function () {
  "use strict";

  var RETRY_INTERVAL_MS = 150;
  var MAX_RETRIES = 60; // 9 seconds max

  /**
   * Try to instantiate the TradingView widget inside `containerId`.
   * Retries until both the TradingView library and the DOM element exist.
   */
  function initWidget(containerId, symbol, attempt) {
    attempt = attempt || 0;

    if (attempt >= MAX_RETRIES) {
      console.warn("[TradingView] Timed out waiting for container:", containerId);
      return;
    }

    if (typeof TradingView === "undefined") {
      setTimeout(function () {
        initWidget(containerId, symbol, attempt + 1);
      }, RETRY_INTERVAL_MS);
      return;
    }

    var el = document.getElementById(containerId);
    if (!el) {
      setTimeout(function () {
        initWidget(containerId, symbol, attempt + 1);
      }, RETRY_INTERVAL_MS);
      return;
    }

    // Wipe any previous widget content before re-initialising
    el.innerHTML = "";

    new TradingView.widget({
      container_id:        containerId,
      autosize:            true,
      symbol:              symbol,
      interval:            "60",
      timezone:            "America/New_York",
      theme:               "light",
      style:               "1",
      locale:              "en",
      toolbar_bg:          "#f1f3f6",
      enable_publishing:   false,
      hide_side_toolbar:   false,
      allow_symbol_change: true,
      studies:             ["BB@tv-basicstudies", "ATR@tv-basicstudies"],
      save_image:          false
    });
  }

  // Shiny sends this after renderUI places the container in the DOM
  Shiny.addCustomMessageHandler("tv_init", function (data) {
    initWidget(data.id, data.symbol);
  });

}());
