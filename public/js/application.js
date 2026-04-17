var update = function() {
  $(document).trigger('update');
  updateCgminerMonitorStatus();
  updatePoolSizeStatus();
};

var setWindowHash = function(event, ui) {
  window.location.hash = ui.newPanel[0].id;
  update();
}

$(document).ready(function() {
  if (typeof config !== 'undefined' && parseInt(config.reload_interval) > 0) {
    setInterval(update, config.reload_interval * 1000);
  }
});

var formatUpdatedAt = function(d) {
  var h = d.getHours();
  if (h < 10) h = '0' + h;

  var m = d.getMinutes();
  if (m < 10) m = '0' + m;

  var s = d.getSeconds();
  if (s < 10) s = '0' + s;

  return h + ':' + m + ':' + s;
}

var updateCgminerMonitorStatus = function() {
  $.getJSON('/healthz', function(data) {
    if (data && data.ok) {
      $('#cgminer-monitor-status').attr('class', 'green bold').text('running');
    } else {
      $('#cgminer-monitor-status').attr('class', 'red bold').text('unavailable');
      $('#warnings').append($('<div/>').attr('id', 'cgminer-monitor-unavailable').addClass('warning').text('cgminer_monitor is unavailable'));
      if (typeof playWarningSound === 'function') playWarningSound();
    }
  }).fail(function() {
    $('#cgminer-monitor-status').attr('class', 'red bold').text('unavailable');
  });
}

var updatePoolSizeStatus = function() {
  $.getJSON('/api/v1/ping.json', function(data) {
    var available = data['available_miners'];
    var unavailable = data['unavailable_miners'];
    var str = available + '/' + (available + unavailable).toString() + ' miners';

    if (unavailable == 0) {
      $('#pool-size-status').attr('class', 'green bold').text(str);
    } else {
      $('#pool-size-status').attr('class', 'red bold').text(str);
      $('#warnings').append($('<div/>').attr('id', 'miner-unavailable').addClass('warning').text('One or more miners is unavailable'));
      if (typeof playWarningSound === 'function') playWarningSound();
    }
  });
}

var formatHashrate = function(rate) {
  rate = parseFloat(rate); var unit = 'H/s';
  if (rate >= 1000) { rate /= 1000; unit = 'KH/s'; }
  if (rate >= 1000) { rate /= 1000; unit = 'MH/s'; }
  if (rate >= 1000) { rate /= 1000; unit = 'GH/s'; }
  if (rate >= 1000) { rate /= 1000; unit = 'TH/s'; }
  if (rate >= 1000) { rate /= 1000; unit = 'PH/s'; }
  if (rate >= 1000) { rate /= 1000; unit = 'EH/s'; }
  if (rate >= 1000) { rate /= 1000; unit = 'ZH/s'; }
  if (rate >= 1000) { rate /= 1000; unit = 'YH/s'; }
  return (rate.toFixed(2) + ' ' + unit);
}

var toFerinheight = function(centigrade) {
  return (1.8 * centigrade + 32).toFixed(1);
}
