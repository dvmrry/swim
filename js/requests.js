// ==SwimScript==
// @name        Network Request Capture
// @description Intercept fetch/XHR and buffer request/response data
// @internal    true
// ==/SwimScript==

(function(){
if(window.__swim_req) return;
window.__swim_req = [];

var BODY_MAX = 4096;
function clampBody(b){
  if(!b) return undefined;
  var s = String(b);
  return s.length > BODY_MAX ? s.substring(0, BODY_MAX) + '...(truncated)' : s;
}
function hdrs(h){
  var o = {};
  if(!h) return o;
  if(typeof h.forEach === 'function') h.forEach(function(v,k){ o[k] = v });
  else if(typeof h.getAllResponseHeaders === 'function'){
    var raw = h.getAllResponseHeaders() || '';
    raw.split('\r\n').forEach(function(l){
      var i = l.indexOf(':');
      if(i > 0) o[l.substring(0,i).trim().toLowerCase()] = l.substring(i+1).trim();
    });
  }
  return o;
}

// Patch fetch
var origFetch = window.fetch;
window.fetch = function(){
  var url = arguments[0], opts = arguments[1] || {};
  if(typeof url === 'object') url = url.url || String(url);
  var method = (opts.method || 'GET').toUpperCase();
  var entry = {method:method, url:String(url), ts:Date.now(), type:'fetch'};
  if(opts.body) entry.requestBody = clampBody(opts.body);
  if(opts.headers){
    var rh = {};
    var h = opts.headers;
    if(h instanceof Headers) h.forEach(function(v,k){ rh[k] = v });
    else if(typeof h === 'object') for(var k in h) rh[k] = h[k];
    entry.requestHeaders = rh;
  }
  var idx = window.__swim_req.length;
  window.__swim_req.push(entry);
  if(window.__swim_req.length > 500) window.__swim_req.shift();
  return origFetch.apply(this, arguments).then(function(r){
    var e = window.__swim_req[idx >= window.__swim_req.length ? window.__swim_req.length-1 : idx];
    e.status = r.status; e.statusText = r.statusText;
    e.responseHeaders = hdrs(r.headers);
    e.duration = Date.now() - e.ts;
    var ct = r.headers.get('content-type') || '';
    if(ct.indexOf('json') >= 0 || ct.indexOf('text') >= 0){
      r.clone().text().then(function(t){ e.responseBody = clampBody(t) }).catch(function(){});
    }
    return r;
  }, function(err){
    var e = window.__swim_req[idx >= window.__swim_req.length ? window.__swim_req.length-1 : idx];
    e.error = err.message; e.duration = Date.now() - e.ts;
    throw err;
  });
};

// Patch XMLHttpRequest
var origOpen = XMLHttpRequest.prototype.open;
var origSend = XMLHttpRequest.prototype.send;
var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;

XMLHttpRequest.prototype.open = function(method, url){
  this.__swim = {method:method.toUpperCase(), url:String(url), headers:{}};
  return origOpen.apply(this, arguments);
};

XMLHttpRequest.prototype.setRequestHeader = function(k, v){
  if(this.__swim) this.__swim.headers[k] = v;
  return origSetHeader.apply(this, arguments);
};

XMLHttpRequest.prototype.send = function(body){
  if(this.__swim){
    var entry = {method:this.__swim.method, url:this.__swim.url, ts:Date.now(), type:'xhr'};
    if(body) entry.requestBody = clampBody(body);
    if(Object.keys(this.__swim.headers).length) entry.requestHeaders = this.__swim.headers;
    var idx = window.__swim_req.length;
    window.__swim_req.push(entry);
    if(window.__swim_req.length > 500) window.__swim_req.shift();
    var self = this;
    this.addEventListener('load', function(){
      var e = window.__swim_req[idx >= window.__swim_req.length ? window.__swim_req.length-1 : idx];
      e.status = self.status; e.statusText = self.statusText;
      e.duration = Date.now() - e.ts;
      e.responseHeaders = hdrs(self);
      var ct = self.getResponseHeader('content-type') || '';
      if(ct.indexOf('json') >= 0 || ct.indexOf('text') >= 0){
        e.responseBody = clampBody(self.responseText);
      }
    });
    this.addEventListener('error', function(){
      var e = window.__swim_req[idx >= window.__swim_req.length ? window.__swim_req.length-1 : idx];
      e.error = 'network error'; e.duration = Date.now() - e.ts;
    });
  }
  return origSend.apply(this, arguments);
};
})();
