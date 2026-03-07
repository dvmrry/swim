(function(){
  var MAX_ELEMENTS = 200;
  var MAX_TOTAL = 300;
  var MAX_OPTIONS = 50;

  // Generate a unique CSS selector for an element
  function uniqueSelector(el) {
    if (el.id) return '#' + CSS.escape(el.id);
    if (el.name && el.tagName !== 'BUTTON') {
      var byName = document.querySelectorAll(el.tagName + '[name="' + el.name.replace(/"/g, '\\"') + '"]');
      if (byName.length === 1) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
    }
    // Build nth-of-type path
    var parts = [];
    var cur = el;
    while (cur && cur !== document.body && cur !== document.documentElement) {
      var tag = cur.tagName.toLowerCase();
      if (cur.id) {
        parts.unshift('#' + CSS.escape(cur.id));
        break;
      }
      var parent = cur.parentElement;
      if (!parent) { parts.unshift(tag); break; }
      var siblings = parent.children;
      var sameTag = 0;
      var idx = 0;
      for (var i = 0; i < siblings.length; i++) {
        if (siblings[i].tagName === cur.tagName) {
          sameTag++;
          if (siblings[i] === cur) idx = sameTag;
        }
      }
      if (sameTag > 1) {
        parts.unshift(tag + ':nth-of-type(' + idx + ')');
      } else {
        parts.unshift(tag);
      }
      cur = parent;
    }
    return parts.join(' > ');
  }

  // Check if element is visible
  function isVisible(el) {
    if (el.offsetParent === null && el.tagName !== 'BODY' && el.tagName !== 'HTML') {
      var style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden') return false;
      if (style.position !== 'fixed' && style.position !== 'sticky') return false;
    }
    var rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    return true;
  }

  // Get label text for a form element
  function getLabel(el) {
    // Explicit label[for]
    if (el.id) {
      var label = document.querySelector('label[for="' + el.id.replace(/"/g, '\\"') + '"]');
      if (label) return label.textContent.trim().substring(0, 200);
    }
    // Wrapping label
    var parent = el.closest('label');
    if (parent) {
      var text = parent.textContent.trim();
      // Remove the element's own text contribution
      var own = el.value || '';
      if (text && text !== own) return text.substring(0, 200);
    }
    // aria-label
    var aria = el.getAttribute('aria-label');
    if (aria) return aria.trim().substring(0, 200);
    // aria-labelledby
    var labelledBy = el.getAttribute('aria-labelledby');
    if (labelledBy) {
      var ref = document.getElementById(labelledBy);
      if (ref) return ref.textContent.trim().substring(0, 200);
    }
    // placeholder
    var ph = el.getAttribute('placeholder');
    if (ph) return ph.trim().substring(0, 200);
    // title
    var title = el.getAttribute('title');
    if (title) return title.trim().substring(0, 200);
    return '';
  }

  // Get button text
  function getButtonText(el) {
    var text = el.textContent.trim();
    if (text) return text.substring(0, 200);
    var val = el.value;
    if (val) return val.substring(0, 200);
    var aria = el.getAttribute('aria-label');
    if (aria) return aria.trim().substring(0, 200);
    var title = el.getAttribute('title');
    if (title) return title.trim().substring(0, 200);
    return '';
  }

  // Collect form elements
  var elements = [];
  var formMap = {}; // form element -> form info
  var forms = [];
  var seen = {};

  // Query all interactable form elements
  var inputSel = 'input, textarea, select';
  var inputs = document.querySelectorAll(inputSel);

  for (var i = 0; i < inputs.length && elements.length < MAX_ELEMENTS; i++) {
    var el = inputs[i];
    if (!isVisible(el)) continue;

    var tag = el.tagName.toLowerCase();
    var type = (el.getAttribute('type') || '').toLowerCase();

    // Skip hidden inputs
    if (tag === 'input' && type === 'hidden') continue;
    // Skip submit/button/reset/image — handled as buttons
    if (tag === 'input' && (type === 'submit' || type === 'button' || type === 'reset' || type === 'image')) continue;

    var selector = uniqueSelector(el);
    if (seen[selector]) continue;
    seen[selector] = true;

    var info = {
      tag: tag,
      type: type || (tag === 'input' ? 'text' : tag),
      selector: selector,
      name: el.name || '',
      label: getLabel(el),
      value: el.value || '',
      enabled: !el.disabled,
      required: el.required || false
    };

    // Checkboxes and radios
    if (type === 'checkbox' || type === 'radio') {
      info.checked = el.checked;
      info.value = el.value || 'on';
    }

    // Selects: include options
    if (tag === 'select') {
      info.type = el.multiple ? 'select-multiple' : 'select-one';
      var options = [];
      for (var j = 0; j < el.options.length && options.length < MAX_OPTIONS; j++) {
        var opt = el.options[j];
        options.push({
          value: opt.value,
          text: opt.textContent.trim().substring(0, 200),
          selected: opt.selected
        });
      }
      info.options = options;
      info.option_count = el.options.length;
    }

    // Track parent form
    if (el.form) {
      var formEl = el.form;
      var formSel = uniqueSelector(formEl);
      if (!formMap[formSel]) {
        var formInfo = {
          selector: formSel,
          id: formEl.id || '',
          action: formEl.action || '',
          method: (formEl.method || 'get').toUpperCase(),
          element_selectors: []
        };
        formMap[formSel] = formInfo;
        forms.push(formInfo);
      }
      formMap[formSel].element_selectors.push(selector);
      info.form_selector = formSel;
    }

    elements.push(info);
  }

  // Collect buttons
  var buttons = [];
  var buttonSel = 'button, input[type="submit"], input[type="button"], input[type="reset"], input[type="image"], [role="button"]';
  var btnEls = document.querySelectorAll(buttonSel);
  var totalCount = elements.length;

  for (var i = 0; i < btnEls.length && totalCount < MAX_TOTAL; i++) {
    var el = btnEls[i];
    if (!isVisible(el)) continue;

    var selector = uniqueSelector(el);
    if (seen[selector]) continue;
    seen[selector] = true;

    var tag = el.tagName.toLowerCase();
    var type = (el.getAttribute('type') || '').toLowerCase();

    var btn = {
      tag: tag,
      type: type || (tag === 'button' ? 'button' : 'button'),
      selector: selector,
      text: getButtonText(el),
      enabled: !el.disabled
    };

    // Track parent form for buttons too
    var formEl = el.form || (el.closest ? el.closest('form') : null);
    if (formEl) {
      var formSel = uniqueSelector(formEl);
      if (!formMap[formSel]) {
        var formInfo = {
          selector: formSel,
          id: formEl.id || '',
          action: formEl.action || '',
          method: (formEl.method || 'get').toUpperCase(),
          element_selectors: []
        };
        formMap[formSel] = formInfo;
        forms.push(formInfo);
      }
      formMap[formSel].element_selectors.push(selector);
      btn.form_selector = formSel;
    }

    buttons.push(btn);
    totalCount++;
  }

  return JSON.stringify({
    url: location.href,
    title: document.title,
    elements: elements,
    buttons: buttons,
    forms: forms,
    element_count: elements.length,
    button_count: buttons.length,
    form_count: forms.length
  });
})();
