// ==UserScript==
// @name        Old Reddit Cleanup
// @match       *://old.reddit.com/*
// @run-at      document-start
// ==/UserScript==

(function(){
var s=document.createElement('style');
s.textContent='\
.sponsorlink,.promoted,.promotedlink{display:none!important}\
#siteTable_organic{display:none!important}\
.infobar.listingsignupbar{display:none!important}\
.premium-banner-outer,.goldvertisement,.ad-container{display:none!important}\
.spacer .premium-banner,.spacer .gold-accent{display:none!important}\
.side{overflow:hidden}\
.side.swim-hidden{width:0!important;opacity:0;padding:0!important;margin:0!important}\
.side.swim-animate,.side.swim-animate~.content,.side.swim-animate+.content{transition:all 0.2s}\
.side.swim-hidden~.content,.side.swim-hidden+.content{margin-right:20px!important}\
';
(document.head||document.documentElement).appendChild(s);
try{if(localStorage.getItem('swim-sidebar-hidden')==='1'){
document.documentElement.classList.add('swim-sidebar-will-hide');
s.textContent+='.swim-sidebar-will-hide .side{width:0!important;opacity:0;padding:0!important;margin:0!important}'
+'.swim-sidebar-will-hide .content{margin-right:20px!important}';
}}catch(e){}

// --- Sidebar toggle (also runs at document-start, but waits for DOM) ---
document.addEventListener('click',function(e){
if(e.target.id!=='swim-sidebar-btn')return;
e.stopPropagation();
var s=document.querySelector('.side');
if(!s)return;
document.documentElement.classList.remove('swim-sidebar-will-hide');
s.classList.add('swim-animate');
s.classList.toggle('swim-hidden');
var h=s.classList.contains('swim-hidden');
e.target.textContent=h?'\u00BB':'\u00AB';
localStorage.setItem('swim-sidebar-hidden',h?'1':'0');
});

function setup(){
if(document.getElementById('swim-sidebar-btn'))return true;
var side=document.querySelector('.side');
if(!side)return false;
var hidden=localStorage.getItem('swim-sidebar-hidden')==='1';
if(hidden){side.classList.add('swim-hidden')}
var btn=document.createElement('div');
btn.id='swim-sidebar-btn';
btn.textContent=hidden?'\u00BB':'\u00AB';
btn.style.cssText='position:fixed;right:16px;top:50%;transform:translateY(-50%);'
+'z-index:9999;cursor:pointer;font-size:16px;color:#666;background:#1a1a1a;'
+'border:1px solid #333;border-radius:4px;padding:12px 6px;'
+'user-select:none;opacity:0;transition:opacity 0.3s';
setTimeout(function(){btn.style.opacity='1'},100);
btn.title='Toggle sidebar';
document.body.appendChild(btn);
return true;
}

if(document.readyState==='loading'){
document.addEventListener('DOMContentLoaded',function(){if(!setup()){var n=0;var iv=setInterval(function(){if(setup()||++n>=20)clearInterval(iv)},250);}});
}else{
if(!setup()){var n=0;var iv=setInterval(function(){if(setup()||++n>=20)clearInterval(iv)},250);}
}
})();
