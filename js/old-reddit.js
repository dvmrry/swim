// old.reddit.com cleanup userscript
(function() {
    if (window.location.hostname !== 'old.reddit.com') return;

    function setup(side) {
        if (document.getElementById('swim-sidebar-btn')) return;

        var hidden = localStorage.getItem('swim-sidebar-hidden') === '1';
        if (hidden) { side.classList.add('swim-hidden'); }

        var btn = document.createElement('div');
        btn.id = 'swim-sidebar-btn';
        btn.textContent = hidden ? '\u00BB' : '\u00AB';
        btn.style.cssText = 'position:fixed;right:16px;top:50%;transform:translateY(-50%);' +
            'z-index:9999;cursor:pointer;font-size:16px;color:#666;background:#1a1a1a;' +
            'border:1px solid #333;border-radius:4px;padding:12px 6px;' +
            'user-select:none;opacity:0;transition:opacity 0.3s';
        setTimeout(function() { btn.style.opacity = '1'; }, 100);
        btn.title = 'Toggle sidebar';
        btn.addEventListener('click', function() {
            side.classList.add('swim-animate');
            side.classList.toggle('swim-hidden');
            var h = side.classList.contains('swim-hidden');
            btn.textContent = h ? '\u00BB' : '\u00AB';
            localStorage.setItem('swim-sidebar-hidden', h ? '1' : '0');
        });
        document.body.appendChild(btn);
    }

    var side = document.querySelector('.side');
    if (side) { setup(side); return; }

    // Sidebar may load after DocumentEnd on some pages (e.g. /r/popular)
    var obs = new MutationObserver(function() {
        var s = document.querySelector('.side');
        if (s) { obs.disconnect(); setup(s); }
    });
    obs.observe(document.body, { childList: true, subtree: true });
})();
