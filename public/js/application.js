var update = function () {
  document.dispatchEvent(new CustomEvent('update'));
  updateCgminerMonitorStatus();
  updatePoolSizeStatus();
};

var setWindowHash = function (newPanel) {
  window.location.hash = newPanel.id;
  update();
};

document.addEventListener('DOMContentLoaded', function () {
  if (typeof config !== 'undefined' && parseInt(config.reload_interval) > 0) {
    setInterval(update, config.reload_interval * 1000);
  }
});

var formatUpdatedAt = function (d) {
  var h = d.getHours(); if (h < 10) h = '0' + h;
  var m = d.getMinutes(); if (m < 10) m = '0' + m;
  var s = d.getSeconds(); if (s < 10) s = '0' + s;
  return h + ':' + m + ':' + s;
};

var updateCgminerMonitorStatus = function () {
  getJSON('/healthz').then(function (data) {
    var el = document.getElementById('cgminer-monitor-status');
    if (!el) return;
    if (data && data.ok) {
      el.className   = 'green bold';
      el.textContent = 'running';
    } else {
      el.className   = 'red bold';
      el.textContent = 'unavailable';
      appendWarning('cgminer-monitor-unavailable', 'cgminer_monitor is unavailable');
      if (typeof playWarningSound === 'function') playWarningSound();
    }
  }).catch(function () {
    var el = document.getElementById('cgminer-monitor-status');
    if (el) { el.className = 'red bold'; el.textContent = 'unavailable'; }
  });
};

var updatePoolSizeStatus = function () {
  getJSON('/api/v1/ping.json').then(function (data) {
    var avail   = data['available_miners'];
    var unavail = data['unavailable_miners'];
    var str     = avail + '/' + (avail + unavail).toString() + ' miners';
    var el      = document.getElementById('pool-size-status');
    if (!el) return;
    if (unavail == 0) {
      el.className = 'green bold'; el.textContent = str;
    } else {
      el.className = 'red bold';   el.textContent = str;
      appendWarning('miner-unavailable', 'One or more miners is unavailable');
      if (typeof playWarningSound === 'function') playWarningSound();
    }
  });
};

// Dedupes by id so repeated polls don't stack identical warning divs.
function appendWarning(id, message) {
  var warnings = document.getElementById('warnings');
  if (!warnings) return;
  if (document.getElementById(id)) return;
  var div = document.createElement('div');
  div.id = id; div.className = 'warning'; div.textContent = message;
  warnings.appendChild(div);
}

var formatHashrate = function (rate) {
  rate = parseFloat(rate); var unit = 'H/s';
  var units = ['KH/s','MH/s','GH/s','TH/s','PH/s','EH/s','ZH/s','YH/s'];
  for (var i = 0; i < units.length && rate >= 1000; i++) { rate /= 1000; unit = units[i]; }
  return rate.toFixed(2) + ' ' + unit;
};

var toFerinheight = function (centigrade) {
  return (1.8 * centigrade + 32).toFixed(1);
};
