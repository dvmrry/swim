// old.reddit.com cleanup userscript
(function() {
    if (window.location.hostname !== 'old.reddit.com') return;

    // Event delegation — survives BFCache since listener is on document
    document.addEventListener('click', function(e) {
        if (e.target.id !== 'swim-sidebar-btn') return;
        e.stopPropagation();
        var s = document.querySelector('.side');
        if (!s) return;
        s.classList.add('swim-animate');
        s.classList.toggle('swim-hidden');
        var h = s.classList.contains('swim-hidden');
        e.target.textContent = h ? '\u00BB' : '\u00AB';
        localStorage.setItem('swim-sidebar-hidden', h ? '1' : '0');
    });

    function setup() {
        if (document.getElementById('swim-sidebar-btn')) return true;
        var side = document.querySelector('.side');
        if (!side) return false;

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
        document.body.appendChild(btn);
        return true;
    }

    // Run setup now, retry if .side isn't in DOM yet
    if (!setup()) {
        var n = 0;
        var iv = setInterval(function() {
            if (setup() || ++n >= 20) clearInterval(iv);
        }, 250);
    }
})();
