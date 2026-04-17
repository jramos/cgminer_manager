// Admin form submission handler. Serializes the form, POSTs via XHR,
// and injects the rendered response partial into the form's
// data-target element. CSRF token is already attached to every
// $.ajax request via the $.ajaxSetup in application.js / manager.js.
//
// On error, shows the server body (or status code) in the target so
// operators can see what went wrong.

$(function() {
  $(document).on('submit', 'form.admin-form', function(e) {
    e.preventDefault();
    var $form  = $(this);
    var target = $form.data('target');
    var $target = $(target);

    $target.html('<p class="muted">Running…</p>');

    $.ajax({
      url: $form.attr('action'),
      method: 'post',
      data: $form.serialize()
    }).done(function(html) {
      $target.html(html);
    }).fail(function(xhr) {
      var body = xhr.responseText || '(no body)';
      $target.html('<div class="admin-error"><strong>Error ' + xhr.status + ':</strong> ' + $('<div/>').text(body).html() + '</div>');
    });

    return false;
  });
});

// Extra confirmation for the raw-command form: show the exact cgminer
// verb + args + scope the operator is about to dispatch so they can
// double-check before firing.
function confirmRawCommand(form) {
  var cmd   = form.command.value;
  var args  = form.args ? form.args.value : '';
  var scope = form.scope ? form.scope.value : 'this miner';
  var msg   = 'Send raw cgminer RPC?\n\n'
            + '  command: ' + cmd + '\n'
            + '  args:    ' + (args || '(none)') + '\n'
            + '  scope:   ' + scope;
  return confirm(msg);
}
