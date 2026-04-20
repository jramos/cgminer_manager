// Match chart axis/legend typography to surrounding HAML text. The font
// stack must stay in sync with body { font-family } in public/css/base.css.
if (typeof Chart !== 'undefined') {
  Chart.defaults.font.family = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';
  Chart.defaults.font.size   = 12;
  Chart.defaults.color       = '#333';
}

// Chart-ready signalling. Graph partials tick window.__chartReady() once
// each canvas has rendered (or the partial removed itself because it had
// no data). The miner detail page's update handler calls
// window.__resetChartsReady() before swapping in a new fragment so the
// counter re-arms for the next batch of canvases.
(function () {
  var expected = 0, done = 0, readyResolve = null;

  function makePromise() {
    window.__chartsReady = false;
    window.__chartsReadyPromise = new Promise(function (res) { readyResolve = res; });
  }
  makePromise();

  function arm() {
    expected = document.querySelectorAll('canvas').length;
    done = 0;
    if (expected === 0) { window.__chartsReady = true; readyResolve(); }
  }

  document.addEventListener('DOMContentLoaded', arm);

  window.__resetChartsReady = function () {
    makePromise();
    arm();
  };

  window.__chartReady = function () {
    if (done >= expected) return;
    done++;
    if (done >= expected) {
      window.__chartsReady = true;
      readyResolve();
    }
  };
})();

function _el(tag, text) {
  var e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  return e;
}
function _row(cells) {
  var tr = _el('tr');
  cells.forEach(function (c) { tr.appendChild(c); });
  return tr;
}
function _appendTable(selector, table) {
  var t = document.querySelector(selector);
  if (t) t.appendChild(table);
}
function _sum(arr) { return arr.reduce(function (a, b) { return a + b; }, 0); }

var injectHashrateTable = function (hash_rates_5s, hash_rates_av, error_rates, target) {
  var table = _el('table');
  var thead = _el('thead');
  thead.appendChild(_el('th', ''));
  thead.appendChild(_el('th', 'Min'));
  thead.appendChild(_el('th', 'Avg'));
  thead.appendChild(_el('th', 'Max'));
  table.appendChild(thead);

  if (hash_rates_5s.length > 0) {
    var min = 1e9 * Math.min.apply(Math, hash_rates_5s);
    var avg = 1e9 * _sum(hash_rates_5s) / hash_rates_5s.length;
    var max = 1e9 * Math.max.apply(Math, hash_rates_5s);
    table.appendChild(_row([_el('td', '5s'),
      _el('td', formatHashrate(min)), _el('td', formatHashrate(avg)), _el('td', formatHashrate(max))]));
  }
  if (hash_rates_av.length > 0) {
    var min2 = 1e9 * Math.min.apply(Math, hash_rates_av);
    var avg2 = 1e9 * _sum(hash_rates_av) / hash_rates_av.length;
    var max2 = 1e9 * Math.max.apply(Math, hash_rates_av);
    table.appendChild(_row([_el('td', 'Avg'),
      _el('td', formatHashrate(min2)), _el('td', formatHashrate(avg2)), _el('td', formatHashrate(max2))]));
  }
  if (error_rates.length > 0) {
    var min3 = 100 * Math.min.apply(Math, error_rates);
    var avg3 = 100 * _sum(error_rates) / error_rates.length;
    var max3 = 100 * Math.max.apply(Math, error_rates);
    table.appendChild(_row([_el('td', '%'),
      _el('td', min3.toFixed(3) + '%'), _el('td', avg3.toFixed(3) + '%'), _el('td', max3.toFixed(3) + '%')]));
  }
  _appendTable(target, table);
};

var injectTemperatureTable = function (min_temperatures, avg_temperatures, max_temperatures, target) {
  var table = _el('table');
  var thead = _el('thead');
  thead.appendChild(_el('th', ''));
  thead.appendChild(_el('th', 'Min'));
  thead.appendChild(_el('th', 'Avg'));
  thead.appendChild(_el('th', 'Max'));
  table.appendChild(thead);

  var avg = (_sum(avg_temperatures) / avg_temperatures.length).toFixed(1);
  var min = Math.min.apply(Math, min_temperatures).toFixed(1);
  var max = Math.max.apply(Math, max_temperatures).toFixed(1);

  table.appendChild(_row([_el('td', 'C'), _el('td', min), _el('td', avg), _el('td', max)]));
  table.appendChild(_row([_el('td', 'F'),
    _el('td', toFerinheight(min)), _el('td', toFerinheight(avg)), _el('td', toFerinheight(max))]));

  _appendTable(target, table);
};

var injectAvailabilityTable = function (availabilities, target) {
  var table = _el('table');
  var thead = _el('thead');
  thead.appendChild(_el('th', 'Min'));
  thead.appendChild(_el('th', 'Avg'));
  thead.appendChild(_el('th', 'Max'));
  table.appendChild(thead);

  var avg = _sum(availabilities) / availabilities.length;
  var min = Math.min.apply(Math, availabilities);
  var max = Math.max.apply(Math, availabilities);

  table.appendChild(_row([
    _el('td', min.toFixed(2) + ' %'),
    _el('td', avg.toFixed(2) + ' %'),
    _el('td', max.toFixed(2) + ' %')
  ]));
  _appendTable(target, table);
};
