// Legacy jQuery $.ajaxSetup — still needed in commit 1 because the graph
// partials and admin form still use $.getJSON / $.ajax. fetch_helpers.js
// handles CSRF for the vanilla callers. This file is deleted in commit 4
// once the last jQuery AJAX caller is gone.
$(function() {
  var token = $('meta[name="csrf-token"]').attr('content');
  if (token) {
    $.ajaxSetup({
      beforeSend: function(xhr) { xhr.setRequestHeader('X-CSRF-Token', token); }
    });
  }
});