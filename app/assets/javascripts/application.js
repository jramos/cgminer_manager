//= require jquery
//= require jquery_ujs
//= require jquery-ui
//= require_tree .

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
  if (parseInt(config.reload_interval) > 0) {
    setInterval(update, config.reload_interval * 1000);
  }
});

var formatUpdatedAt = function(d) {
  var h = d.getHours();
  if ( h < 10 ) h = '0' + h;

  var m = d.getMinutes();
  if ( m < 10 ) m = '0' + m;

  var s = d.getSeconds();
  if ( s < 10 ) s = '0' + s;

  return h+':'+m+':'+s;
}

var updateCgminerMonitorStatus = function() {
  $.getJSON('/cgminer_monitor/api/v1/ping.json', function(data) {
    daemon_status = data['status'];

    if (daemon_status == 'running') {
      $('#cgminer-monitor-status').attr('class', 'green bold').text(data['status']);
    } else {
      $('#cgminer-monitor-status').attr('class', 'red bold').text(data['status']);
      div = $('<div/>').
        attr('id', 'cgminer-monitor-unavailable').
        addClass('warning').
        text('cgminer_monitor is unavailable');

      $('#warnings').append(div);
      playWarningSound();
    }
  });
}

var updatePoolSizeStatus = function() {
  $.getJSON('/api/v1/ping.json', function(data) {
    available = data['available_miners']
    unavailable = data['unavailable_miners']

    str = available + '/' + (available + unavailable).toString() + ' miners';

    if (unavailable == 0) {
      $('#pool-size-status').attr('class', 'green bold').text(str);
    } else {
      $('#pool-size-status').attr('class', 'red bold').text(str);
      div = $('<div/>').
        attr('id', 'miner-unavailable').
        addClass('warning').
        text('One or more miners is unavailable');

      $('#warnings').append(div);
      playWarningSound();
    }
  });  
}

var formatHashrate = function(rate) {
  rate= parseFloat(rate); unit= 'H/s';
  if(rate >= 1000) { rate /= 1000; unit= 'KH/s'; }
  if(rate >= 1000) { rate /= 1000; unit= 'MH/s'; }
  if(rate >= 1000) { rate /= 1000; unit= 'GH/s'; }
  if(rate >= 1000) { rate /= 1000; unit= 'TH/s'; }
  if(rate >= 1000) { rate /= 1000; unit= 'PH/s'; }
  if(rate >= 1000) { rate /= 1000; unit= 'EH/s'; }
  if(rate >= 1000) { rate /= 1000; unit= 'ZH/s'; }
  if(rate >= 1000) { rate /= 1000; unit= 'YH/s'; }
  return (rate.toFixed(2) + ' ' + unit);
}

var toFerinheight = function(centigrade) {
  return (1.8 * centigrade + 32).toFixed(1);
}