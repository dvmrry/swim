(function(){
  // Get page metadata
  var meta = {};
  var metaTags = document.querySelectorAll('meta[name], meta[property]');
  for (var i = 0; i < metaTags.length; i++) {
    var name = metaTags[i].getAttribute('name') || metaTags[i].getAttribute('property');
    var content = metaTags[i].getAttribute('content');
    if (name && content) meta[name] = content;
  }

  // Find main content — reuse focus.js strategy
  var article = null;
  var host = location.hostname;

  // Site-specific extraction
  if (host === 'old.reddit.com') {
    article = document.querySelector('.sitetable.nestedlisting') ||
              document.querySelector('#siteTable');
  } else if (host.includes('reddit.com')) {
    article = document.querySelector('[data-testid="post-container"]') ||
              document.querySelector('.Post');
  } else if (host.includes('github.com')) {
    article = document.querySelector('.markdown-body') ||
              document.querySelector('.repository-content');
  }

  // Generic extraction
  if (!article) {
    article = document.querySelector('article') ||
              document.querySelector('[role="main"]') ||
              document.querySelector('main') ||
              document.querySelector('.post-content') ||
              document.querySelector('.article-content') ||
              document.querySelector('.entry-content');
  }

  var source = article || document.body;

  // Convert to markdown-ish text
  function toMarkdown(el) {
    var out = '';
    var children = el.childNodes;
    for (var i = 0; i < children.length; i++) {
      var node = children[i];
      if (node.nodeType === 3) {
        // Text node
        out += node.textContent;
      } else if (node.nodeType === 1) {
        var tag = node.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' ||
            tag === 'NAV' || tag === 'FOOTER' || tag === 'HEADER') continue;
        if (tag === 'H1') out += '\n# ' + node.textContent.trim() + '\n\n';
        else if (tag === 'H2') out += '\n## ' + node.textContent.trim() + '\n\n';
        else if (tag === 'H3') out += '\n### ' + node.textContent.trim() + '\n\n';
        else if (tag === 'H4') out += '\n#### ' + node.textContent.trim() + '\n\n';
        else if (tag === 'P') out += node.textContent.trim() + '\n\n';
        else if (tag === 'LI') out += '- ' + node.textContent.trim() + '\n';
        else if (tag === 'BR') out += '\n';
        else if (tag === 'PRE' || tag === 'CODE') out += '\n```\n' + node.textContent + '\n```\n\n';
        else if (tag === 'BLOCKQUOTE') out += '> ' + node.textContent.trim() + '\n\n';
        else if (tag === 'A') {
          var href = node.getAttribute('href');
          var text = node.textContent.trim();
          if (href && text) out += '[' + text + '](' + href + ')';
          else out += text;
        }
        else if (tag === 'IMG') {
          var alt = node.getAttribute('alt') || '';
          var src = node.getAttribute('src') || '';
          if (src) out += '![' + alt + '](' + src + ')\n';
        }
        else out += toMarkdown(node);
      }
    }
    return out;
  }

  var content = toMarkdown(source)
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  // Collect visible links
  var links = [];
  var anchors = document.querySelectorAll('a[href]');
  for (var i = 0; i < anchors.length && links.length < 100; i++) {
    var a = anchors[i];
    var rect = a.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    var text = a.textContent.trim();
    if (!text || text.length > 200) continue;
    var href = a.href;
    if (href && !href.startsWith('javascript:')) {
      links.push({text: text.substring(0, 100), href: href});
    }
  }

  return JSON.stringify({
    url: location.href,
    title: document.title,
    content: content,
    links: links,
    meta: meta
  });
})();
