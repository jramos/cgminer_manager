$(function() {
  var token = $('meta[name="csrf-token"]').attr('content');
  if (token) {
    $.ajaxSetup({
      beforeSend: function(xhr) { xhr.setRequestHeader('X-CSRF-Token', token); }
    });
  }
});

// Place all the behaviors and hooks related to the matching controller here.
// All this logic will automatically be available in application.js.
