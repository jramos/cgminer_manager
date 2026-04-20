// Admin form submission. Serializes via FormData (so the hidden
// authenticity_token hidden field ships with the body) and POSTs via
// csrfFetch (which also adds X-CSRF-Token for defense-in-depth). The
// response partial is rendered into the form's data-target element.

document.addEventListener('submit', function (e) {
  var form = e.target;
  if (!(form instanceof HTMLFormElement)) return;
  if (!form.classList.contains('admin-form')) return;
  e.preventDefault();

  var targetSel = form.dataset.target;
  var target    = targetSel ? document.querySelector(targetSel) : null;
  if (target) target.innerHTML = '<p class="muted">Running…</p>';

  csrfFetch(form.action, {
    method:  'POST',
    body:    new URLSearchParams(new FormData(form)),
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' }
  }).then(function (r) {
    return r.text().then(function (body) { return { ok: r.ok, status: r.status, body: body }; });
  }).then(function (res) {
    if (!target) return;
    if (res.ok) {
      target.innerHTML = res.body; // server-rendered partial, trusted
    } else {
      var wrap   = document.createElement('div');
      wrap.className = 'admin-error';
      var strong = document.createElement('strong');
      strong.textContent = 'Error ' + res.status + ':';
      wrap.append(strong, ' ', res.body || '(no body)');
      target.replaceChildren(wrap);
    }
  });
});

// Extra confirmation for the raw-command form.
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
