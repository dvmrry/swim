// ==SwimScript==
// @name        Focus Mode
// @description Reader view with theme-aware styling
// @internal    true
// ==/SwimScript==

(function(){
var overlay=document.getElementById('swim-focus');
if(overlay){overlay.remove();document.body.style.overflow='';return;}

// Find main content — site-specific then generic
var article,isReddit=location.hostname==='old.reddit.com';
var isRedditListing=false;
if(isReddit){
  article=document.querySelector('.sitetable.nestedlisting');
  if(!article){article=document.querySelector('#siteTable');isRedditListing=!!article;}
}else{
  article=document.querySelector('article')
  ||document.querySelector('[role=main]')
  ||document.querySelector('.post-content,.entry-content,main');
}
if(!article){
  var ps=document.querySelectorAll('p'),best=null,bestLen=0;
  var cs=new Set();ps.forEach(function(p){cs.add(p.parentElement)});
  cs.forEach(function(c){var l=c.textContent.length;if(l>bestLen){bestLen=l;best=c}});
  article=best;
}
if(!article)return;

// Get title text, strip common site suffixes
var titleText=document.title||'';
titleText=titleText.replace(/\s*[-|\u2013\u2014]\s*(Wikipedia|Reddit|reddit\.com).*$/i,'');
titleText=titleText.replace(/\s*:\s*(reddit\.com)$/i,'');
if(isReddit&&!isRedditListing){
  var pt=document.querySelector('.top-matter .title a');
  if(pt)titleText=pt.textContent;
}

// Build overlay
var o=document.createElement('div');
o.id='swim-focus';
o.style.cssText='position:fixed;top:0;left:0;width:100%;height:100%;z-index:99999;background:{{bg}};overflow-y:auto;';

// Inner content column
var inner=document.createElement('div');
inner.style.cssText='max-width:700px;margin:60px auto 120px;padding:0 40px;';

// Title
var h=document.createElement('h1');
h.textContent=titleText;
h.style.cssText='font:bold 26px/1.3 system-ui,-apple-system,sans-serif;color:{{fg}};margin:0 0 8px;border:none;letter-spacing:-0.3px;';
inner.appendChild(h);

// Reddit post body (self-text, images, galleries, video)
if(isReddit&&!isRedditListing){
  (function loadRedditMedia(){
    var jsonUrl=location.pathname.replace(/\/$/,'')+ '.json';
    fetch(jsonUrl).then(function(r){return r.json()}).then(function(data){
      var post=data[0].data.children[0].data;
      if(post.media_metadata){
        var ids=post.gallery_data?post.gallery_data.items.map(function(i){return i.media_id})
          :Object.keys(post.media_metadata);
        ids.forEach(function(id){
          var m=post.media_metadata[id];if(!m||m.status!=='valid')return;
          var src=m.s?m.s.u||m.s.gif||'':'';
          src=src.replace(/&amp;/g,'&');
          if(!src)return;
          var img=document.createElement('img');img.src=src;img.loading='lazy';
          img.style.cssText='max-width:100%;height:auto;border-radius:4px;margin:0 0 16px;';
          inner.insertBefore(img,inner.querySelector('#swim-focus-sep'));
        });
      }
      else if(post.url&&/\.(jpg|jpeg|png|gif|webp)(\?.*)?$/i.test(post.url)){
        var img=document.createElement('img');img.src=post.url;
        img.style.cssText='max-width:100%;height:auto;border-radius:4px;margin:0 0 16px;';
        inner.insertBefore(img,inner.querySelector('#swim-focus-sep'));
      }
      else if(post.preview&&post.preview.images&&post.preview.images[0]){
        var src=post.preview.images[0].source.url.replace(/&amp;/g,'&');
        var img=document.createElement('img');img.src=src;
        img.style.cssText='max-width:100%;height:auto;border-radius:4px;margin:0 0 16px;';
        inner.insertBefore(img,inner.querySelector('#swim-focus-sep'));
      }
      if(post.secure_media&&post.secure_media.reddit_video){
        var v=document.createElement('video');v.controls=true;
        v.src=post.secure_media.reddit_video.fallback_url;
        v.style.cssText='max-width:100%;border-radius:4px;margin:0 0 16px;';
        inner.insertBefore(v,inner.querySelector('#swim-focus-sep'));
      }
    }).catch(function(){});
  })();
  var selfText=document.querySelector('.expando .usertext-body');
  if(selfText&&selfText.textContent.trim()){
    var pb=selfText.cloneNode(true);
    pb.style.cssText='font:15px/1.7 Georgia,serif;color:{{fg}};margin:0 0 8px;';
    inner.appendChild(pb);
  }
}

// Separator
var hr=document.createElement('div');
hr.id='swim-focus-sep';
hr.style.cssText='width:60px;height:1px;background:{{fg_dim}};margin:16px 0 32px;';
inner.appendChild(hr);

// Extract content — reddit-specific
if(isReddit&&isRedditListing){
  var things=article.querySelectorAll('.thing.link');
  things.forEach(function(t){
    var titleEl=t.querySelector('.title a.title');
    if(!titleEl)return;
    var author=t.querySelector('.author');
    var score=t.querySelector('.score.unvoted');
    var comments=t.querySelector('.comments');
    var domain=t.querySelector('.domain a');
    var selfText=t.querySelector('.expando .usertext-body');
    var thumb=t.querySelector('.thumbnail img');

    var row=document.createElement('div');
    row.style.cssText='padding:16px 0;border-bottom:1px solid {{status_bg}};';

    var h=document.createElement('a');
    h.href=titleEl.href;
    h.textContent=titleEl.textContent;
    h.style.cssText='font:bold 16px/1.4 system-ui,sans-serif;color:{{accent}};text-decoration:none;display:block;margin:0 0 6px;';
    row.appendChild(h);

    if(thumb&&thumb.src&&!thumb.src.includes('self')&&!thumb.src.includes('nsfw')){
      var img=document.createElement('img');img.src=thumb.src;img.loading='lazy';
      img.style.cssText='max-width:100%;max-height:300px;border-radius:4px;margin:0 0 8px;display:block;';
      row.appendChild(img);
    }

    if(selfText&&selfText.textContent.trim()){
      var preview=document.createElement('div');
      preview.innerHTML=selfText.innerHTML;
      preview.style.cssText='font:14px/1.6 Georgia,serif;color:{{fg_dim}};margin:0 0 8px;max-height:120px;overflow:hidden;';
      row.appendChild(preview);
    }

    var meta=document.createElement('div');
    meta.style.cssText='font:12px/1 system-ui,sans-serif;color:{{fg_dim}};';
    var parts=[];
    if(score)parts.push(score.textContent);
    if(author)parts.push(author.textContent);
    if(comments)parts.push(comments.textContent);
    if(domain)parts.push(domain.textContent);
    meta.textContent=parts.join(' \u00B7 ');
    row.appendChild(meta);

    inner.appendChild(row);
  });
}else if(isReddit){
  var comments=article.querySelectorAll('.comment');
  comments.forEach(function(c){
    var entry=c.querySelector('.entry');
    if(!entry)return;
    var author=c.querySelector('.author');
    var body=c.querySelector('.usertext-body');
    var score=c.querySelector('.score.unvoted');
    if(!body||!body.textContent.trim())return;
    var depth=0;var p=c;while(p=p.parentElement){
      if(p.classList&&p.classList.contains('comment'))depth++;
    }

    var row=document.createElement('div');
    row.style.cssText='margin:0 0 4px;padding:12px 0 12px '+(depth*24)+'px;border-bottom:1px solid {{status_bg}};';

    var meta=document.createElement('div');
    meta.style.cssText='font:12px/1 system-ui,sans-serif;color:{{fg_dim}};margin:0 0 6px;';
    meta.textContent=(author?author.textContent:'[deleted]')
      +(score?' \u00B7 '+score.textContent:'');
    row.appendChild(meta);

    var text=document.createElement('div');
    text.innerHTML=body.innerHTML;
    text.style.cssText='font:15px/1.7 Georgia,serif;color:{{fg}};';
    text.querySelectorAll('a').forEach(function(a){
      var u=a.href||'';
      if(/\.(jpg|jpeg|png|gif|webp)(\?.*)?$/i.test(u)
        ||/i\.redd\.it|preview\.redd\.it|i\.imgur\.com/i.test(u)){
        var img=document.createElement('img');
        img.src=u;img.loading='lazy';
        img.style.cssText='max-width:100%;height:auto;border-radius:4px;margin:8px 0;display:block;';
        a.parentNode.insertBefore(img,a.nextSibling);
      }
    });
    row.appendChild(text);

    inner.appendChild(row);
  });
}else{

  var clone=article.cloneNode(true);
  clone.querySelectorAll('nav,header,footer,.sidebar,.ad,.social-share,.related-posts,.newsletter,aside,[role=complementary],script,style,iframe,.share,.hidden').forEach(function(e){e.remove()});
  inner.appendChild(clone);
}

// Styles
var s=document.createElement('style');
s.textContent='\
#swim-focus *{box-sizing:border-box}\
#swim-focus p{margin:0 0 1.2em;line-height:1.7}\
#swim-focus img{max-width:100%;height:auto;border-radius:4px;margin:1em auto;display:block}\
#swim-focus a{color:{{accent}};text-decoration:none}\
#swim-focus a:hover{text-decoration:underline}\
#swim-focus pre{background:{{status_bg}};padding:16px;border-radius:6px;overflow-x:auto;font:14px/1.5 ui-monospace,monospace;color:{{fg_dim}}}\
#swim-focus code{font:14px ui-monospace,monospace;color:{{fg_dim}};background:{{status_bg}};padding:2px 5px;border-radius:3px}\
#swim-focus pre code{padding:0;background:none}\
#swim-focus h1,#swim-focus h2,#swim-focus h3,#swim-focus h4{font-family:system-ui,sans-serif;color:{{fg}};margin:1.5em 0 0.5em;line-height:1.3}\
#swim-focus h2{font-size:22px}#swim-focus h3{font-size:18px}\
#swim-focus blockquote{border-left:3px solid {{fg_dim}};margin:1em 0;padding:0 0 0 20px;color:{{fg_dim}}}\
#swim-focus ul,#swim-focus ol{padding-left:24px}\
#swim-focus li{margin:0.3em 0;color:{{fg}}}\
#swim-focus table{border-collapse:collapse;width:100%;margin:1em 0}\
#swim-focus td,#swim-focus th{border:1px solid {{status_bg}};padding:8px;text-align:left;color:{{fg_dim}}}\
#swim-focus th{background:{{status_bg}};color:{{fg}}}\
#swim-focus hr{border:none;border-top:1px solid {{status_bg}};margin:2em 0}\
#swim-focus .md{font:15px/1.7 Georgia,serif;color:{{fg}}}\
';
o.appendChild(s);

o.appendChild(inner);
document.body.appendChild(o);
document.body.style.overflow='hidden';
o.scrollTop=0;
o.focus();
})()
