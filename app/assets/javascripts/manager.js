// Place all the behaviors and hooks related to the matching controller here.
// All this logic will automatically be available in application.js.

function playWarningSound() {
    warning = $("#audio-warning")[0];

    if (warning && warning.play) {
        warning.play();
    }
}