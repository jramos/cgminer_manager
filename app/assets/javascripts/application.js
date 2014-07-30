//= require jquery
//= require jquery-ui
//= require_tree .

var reload = function() {
  $('#updated').addClass('updating').text('Updating...');
  location.reload();
};

$(document).ready(function() {
  if (parseInt(config.reload_interval) > 0) {
    setInterval(reload, config.reload_interval * 1000);
  }
});