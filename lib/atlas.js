(function(){
function openTarget(){var id=location.hash.slice(1);if(!id)return;var el=document.getElementById(id);for(var p=el;p;p=p.parentElement)if(p.tagName==='DETAILS')p.open=true;}
window.addEventListener('hashchange',openTarget);openTarget();
window.addEventListener('beforeprint',function(){document.querySelectorAll('details').forEach(function(d){d.dataset.wasOpen=d.open;d.open=true;});});
window.addEventListener('afterprint',function(){document.querySelectorAll('details').forEach(function(d){d.open=d.dataset.wasOpen==='true';});});
var t=document.querySelector('[data-age]');if(t){var h=(Date.now()-new Date(t.getAttribute('datetime')))/36e5;if(h>=0){var s=h<1?'less than an hour ago':h<48?Math.round(h)+' hours ago':Math.round(h/24)+' days ago';var a=document.createElement('span');a.className='age'+(h>24?' age-old':'');a.textContent=' ('+s+')';t.after(a);}}
})();
