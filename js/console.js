// ==SwimScript==
// @name        Console Capture
// @description Intercept console.log/warn/error/info and buffer messages
// @internal    true
// ==/SwimScript==

(function(){
if(window.__swim_console) return;
window.__swim_console = [];
var orig = {
  log: console.log,
  warn: console.warn,
  error: console.error,
  info: console.info
};
['log','warn','error','info'].forEach(function(level){
  console[level] = function(){
    var args = [].slice.call(arguments).map(function(a){
      try { return typeof a === 'object' ? JSON.stringify(a) : String(a) }
      catch(e) { return String(a) }
    });
    window.__swim_console.push({level:level, text:args.join(' '), ts:Date.now()});
    if(window.__swim_console.length > 200) window.__swim_console.shift();
    orig[level].apply(console, arguments);
  };
});
})();
