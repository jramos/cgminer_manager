//= require jquery
//= require jquery_ujs
//= require jquery-ui
//= require_tree .

var update = function() {
  $(document).trigger('update');
};

var setWindowHash = function(event, ui) {
  window.location.hash = ui.newPanel[0].id;
}

$(document).ready(function() {
  if (parseInt(config.reload_interval) > 0) {
    setInterval(update, config.reload_interval * 1000);
  }
});