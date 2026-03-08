// ==UserScript==
// @name        YouTube Ad Blocker
// @match       *://www.youtube.com/*
// @match       *://m.youtube.com/*
// @run-at      document-end
// ==/UserScript==

(function(){
var s=document.createElement('style');
s.textContent='\
.ad-showing .video-ads,\
.ytp-ad-module,\
.ytp-ad-overlay-container,\
.ytp-ad-text-overlay,\
.ytd-promoted-sparkles-web-renderer,\
.ytd-display-ad-renderer,\
.ytd-companion-slot-renderer,\
.ytd-action-companion-ad-renderer,\
.ytd-in-feed-ad-layout-renderer,\
.ytd-ad-slot-renderer,\
.ytd-banner-promo-renderer,\
.ytd-statement-banner-renderer,\
.ytd-masthead-ad-renderer,\
#player-ads,\
#masthead-ad,\
.ytd-merch-shelf-renderer,\
.ytd-engagement-panel-section-list-renderer[target-id=engagement-panel-ads]\
{display:none!important}';
document.head.appendChild(s);

var observer=new MutationObserver(function(){
var skip=document.querySelector('.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad-button');
if(skip){skip.click();return}
var v=document.querySelector('.ad-showing video');
if(v&&v.duration&&v.duration>0){v.currentTime=v.duration}
});
observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class']});
})();
