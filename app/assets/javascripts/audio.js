var playWarningSound = function () {
    warning = $("#audio-warning")[0];

    if (warning && warning.play) {
        warning.play();
    }
}

var initAudioStatus = function () {
  if ($.cookie('enable-audio') == undefined) {
    $.cookie('enable-audio', config.enable_audio, { expires: 365, path: '/' });
  }

  current_value = $.cookie('enable-audio');
  current_value = current_value == 'true' ? true : false;
  config.enable_audio = current_value;
  $('#audio-status').text(current_value ? 'Enabled' : 'Disabled');
}

var toggleAudioStatus = function () {
  current_value = $.cookie('enable-audio');
  current_value = current_value == 'true' ? true : false;
  new_value = !current_value;
  config.enable_audio = new_value;

  $.cookie('enable-audio', config.enable_audio, { expires: 365, path: '/' });
  $('#audio-status').text(new_value ? 'Enabled' : 'Disabled');
}