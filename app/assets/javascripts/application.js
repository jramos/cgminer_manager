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
}

$(document).ready(function() {
  if (parseInt(config.reload_interval) > 0) {
    setInterval(update, config.reload_interval * 1000);
  }
});

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
  $.getJSON('/cgminer_monitor/api/v1/graph_data/local_availability.json', function(data) {
    most_recent = data[data.length - 1];
    str = most_recent[1].toString() + '/' + most_recent[2].toString() + ' miners';

    if (most_recent[1] == most_recent[2]) {
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