// old.reddit.com cleanup userscript
(function() {
    if (window.location.hostname !== 'old.reddit.com') return;

    var style = document.createElement('style');
    style.textContent = [
        '.sponsorlink, .promoted, .promotedlink { display: none !important; }',
        '#siteTable_organic { display: none !important; }',
        '.infobar.listingsignupbar { display: none !important; }',
        '.side { transition: width 0.2s, opacity 0.2s, padding 0.2s; overflow: hidden; }',
        '.side.swim-hidden { width: 0 !important; opacity: 0; padding: 0 !important; margin: 0 !important; }',
        '.content { transition: margin-right 0.2s; }',
        '.side.swim-hidden ~ .content, .side.swim-hidden + .content { margin-right: 20px !important; }',
    ].join('\n');
    document.head.appendChild(style);

    // Collapsible sidebar toggle button
    var side = document.querySelector('.side');
    if (!side) return;

    var hidden = localStorage.getItem('swim-sidebar-hidden') === '1';
    if (hidden) { side.classList.add('swim-hidden'); }

    var btn = document.createElement('div');
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
})();
