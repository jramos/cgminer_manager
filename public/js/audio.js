var AUDIO_KEY = 'enable-audio';

var playWarningSound = function () {
  if (config.enable_audio) {
    var el = document.getElementById('audio-warning');
    if (el && el.play) el.play();
  }
};

var initAudioStatus = function () {
  if (localStorage.getItem(AUDIO_KEY) === null) {
    localStorage.setItem(AUDIO_KEY, String(config.enable_audio));
  }
  var on = localStorage.getItem(AUDIO_KEY) === 'true';
  config.enable_audio = on;
  var el = document.getElementById('audio-status');
  if (el) el.textContent = on ? 'Enabled' : 'Disabled';
};

var toggleAudioStatus = function () {
  var on = localStorage.getItem(AUDIO_KEY) !== 'true';
  config.enable_audio = on;
  localStorage.setItem(AUDIO_KEY, String(on));
  var el = document.getElementById('audio-status');
  if (el) el.textContent = on ? 'Enabled' : 'Disabled';
};

document.addEventListener('DOMContentLoaded', initAudioStatus);
