// CSRF-aware fetch wrapper. Reads the token from <meta name="csrf-token">
// once at module load. Non-GET requests auto-include X-CSRF-Token.
// Accepts opts.signal for AbortController integration.
(function () {
  var meta  = document.querySelector('meta[name="csrf-token"]');
  var token = meta ? meta.getAttribute('content') : null;

  window.csrfFetch = function (url, opts) {
    opts = opts || {};
    var method  = (opts.method || 'GET').toUpperCase();
    var headers = new Headers(opts.headers || {});
    if (token && method !== 'GET' && method !== 'HEAD') {
      headers.set('X-CSRF-Token', token);
    }
    opts.headers     = headers;
    opts.credentials = opts.credentials || 'same-origin';
    return fetch(url, opts);
  };

  window.getJSON = function (url, opts) {
    return window.csrfFetch(url, opts).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + url);
      return r.json();
    });
  };
})();
