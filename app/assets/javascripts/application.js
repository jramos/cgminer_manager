//= require jquery
//= require jquery_ujs
//= require jquery-ui
//= require_tree .

var update = function() {
  $(document).trigger('update');
  updateCgminerMonitorStatus();
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
    status = data['status'];

    if (status == 'running') {
      $('#cgminer-monitor-status').addClass('green bold').text(data['status']);
    } else {
      $('#cgminer-monitor-status').addClass('red bold').text(data['status']);
      div = $('<div/>').
        attr('id', 'cgminer-monitor-unavailable').
        addClass('warning').
        text('cgminer_monitor is unavailable');

      $('#warnings').append(div);
      playWarningSound();
    }
  });
}