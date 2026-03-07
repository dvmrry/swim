(function() {
    'use strict';

    var HINT_CHARS = 'asdfghjkl';
    var hints = [];
    var container = null;

    function generateLabels(count) {
        var labels = [];
        var chars = HINT_CHARS;
        var len = chars.length;
        if (count <= len) {
            for (var i = 0; i < count; i++) labels.push(chars[i]);
        } else {
            // Two-character labels
            for (var i = 0; i < len && labels.length < count; i++) {
                for (var j = 0; j < len && labels.length < count; j++) {
                    labels.push(chars[i] + chars[j]);
                }
            }
        }
        return labels;
    }

    function findClickable() {
        var selectors = 'a[href], button, input, select, textarea, ' +
            '[onclick], [role="button"], [role="link"], [tabindex], summary';
        var els = document.querySelectorAll(selectors);
        var visible = [];
        for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var rect = el.getBoundingClientRect();
            if (rect.width > 0 && rect.height > 0 &&
                rect.top < window.innerHeight && rect.bottom > 0 &&
                rect.left < window.innerWidth && rect.right > 0) {
                visible.push({el: el, rect: rect});
            }
        }
        return visible;
    }

    function showHints(newTab) {
        removeHints();
        var clickable = findClickable();
        if (clickable.length === 0) return;

        var labels = generateLabels(clickable.length);
        container = document.createElement('div');
        container.id = '__swim_hints';
        document.body.appendChild(container);

        for (var i = 0; i < clickable.length; i++) {
            var item = clickable[i];
            var label = labels[i];

            var overlay = document.createElement('div');
            overlay.className = '__swim_hint';
            overlay.textContent = label;
            overlay.style.cssText = 'position:fixed;z-index:2147483647;' +
                'background:#f0e040;color:#000;font:bold 11px monospace;' +
                'padding:1px 3px;border:1px solid #c0a020;border-radius:2px;' +
                'pointer-events:none;line-height:1.2;';
            overlay.style.left = item.rect.left + 'px';
            overlay.style.top = item.rect.top + 'px';

            container.appendChild(overlay);
            hints.push({el: item.el, label: label, overlay: overlay, newTab: !!newTab});
        }

        window.webkit.messageHandlers.swim.postMessage({
            type: 'hints-shown',
            count: hints.length
        });
    }

    function filterHints(typed) {
        var remaining = 0;
        var lastMatch = null;
        for (var i = 0; i < hints.length; i++) {
            var h = hints[i];
            if (h.label.indexOf(typed) === 0) {
                h.overlay.style.display = '';
                remaining++;
                lastMatch = h;
                // Highlight matched portion
                h.overlay.innerHTML = '<span style="color:#d00">' +
                    typed + '</span>' + h.label.slice(typed.length);
            } else {
                h.overlay.style.display = 'none';
            }
        }

        if (remaining === 1 && lastMatch.label === typed) {
            activateHint(lastMatch);
        } else if (remaining === 0) {
            removeHints();
            window.webkit.messageHandlers.swim.postMessage({type: 'hints-cancelled'});
        }
    }

    function activateHint(hint) {
        removeHints();
        if (hint.newTab) {
            // Open in new tab
            var href = hint.el.href || hint.el.closest('a[href]')?.href;
            if (href) {
                window.webkit.messageHandlers.swim.postMessage({
                    type: 'hint-activate',
                    url: href,
                    newTab: true
                });
            }
        } else {
            hint.el.click();
            // Focus if it's an input
            if (hint.el.tagName === 'INPUT' || hint.el.tagName === 'TEXTAREA' ||
                hint.el.tagName === 'SELECT') {
                hint.el.focus();
            }
        }
        window.webkit.messageHandlers.swim.postMessage({type: 'hints-done'});
    }

    function removeHints() {
        if (container) {
            container.remove();
            container = null;
        }
        hints = [];
    }

    // Exposed API
    window.__swim_hints = {
        show: function(newTab) { showHints(newTab); },
        filter: function(typed) { filterHints(typed); },
        remove: function() {
            removeHints();
            window.webkit.messageHandlers.swim.postMessage({type: 'hints-cancelled'});
        }
    };
})();
