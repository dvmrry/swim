// ==UserScript==
// @name        Dark Mode
// @match       *://*/*
// @run-at      document-start
// ==/UserScript==

(function(){
var s=document.createElement('style');
s.textContent='\
html{filter:invert(1) hue-rotate(180deg)!important}\
img,video,canvas,svg,picture,[style*="background-image"]{filter:invert(1) hue-rotate(180deg)!important}\
';
(document.head||document.documentElement).appendChild(s);
})();
