// Vanilla replacement for jQuery UI .tabs().
//
// Usage: initTabs('#container', { activate: function (panel) { ... } })
//
// Expected markup:
//   <div id="x">
//     <ul><li><a href="#panel-a">A</a></li><li><a href="#panel-b">B</a></li></ul>
//     <div id="panel-a">...</div>
//     <div id="panel-b">...</div>
//   </div>
//
// opts.activate fires on user click only (not on initial selection),
// matching jQuery UI's behaviour.
(function () {
  function initTabs(selectorOrEl, opts) {
    opts = opts || {};
    var root = typeof selectorOrEl === 'string'
      ? document.querySelector(selectorOrEl) : selectorOrEl;
    if (!root) return;
    var nav = root.querySelector(':scope > ul');
    if (!nav) return;
    var links = nav.querySelectorAll('a[href^="#"]');
    if (links.length === 0) return;

    var panels = [];
    links.forEach(function (a) {
      var id = a.getAttribute('href').slice(1);
      var panel = document.getElementById(id);
      if (panel) panels.push(panel);
    });

    function activate(index, fromUser) {
      links.forEach(function (a, i) {
        a.parentNode.classList.toggle('tab-active', i === index);
      });
      panels.forEach(function (p, i) {
        p.style.display = (i === index) ? '' : 'none';
      });
      if (fromUser && typeof opts.activate === 'function' && panels[index]) {
        opts.activate(panels[index]);
      }
    }

    links.forEach(function (a, i) {
      a.addEventListener('click', function (e) { e.preventDefault(); activate(i, true); });
    });

    var initial = 0;
    if (window.location.hash) {
      var target = window.location.hash.slice(1);
      for (var i = 0; i < panels.length; i++) {
        if (panels[i].id === target) { initial = i; break; }
      }
    }
    activate(initial, false);
  }
  window.initTabs = initTabs;
})();
