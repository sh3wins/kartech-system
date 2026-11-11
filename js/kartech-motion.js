/* Kartech OS: non-invasive UI motion and chart detail cards. No database writes. */
(()=>{'use strict';
 const view=document.getElementById('view');if(!view)return;
 const reduce=matchMedia('(prefers-reduced-motion: reduce)');
 let popup=null,previous=null;
 function close(){if(popup){popup.remove();popup=null;}if(previous){previous.focus({preventScroll:true});previous=null;}}
 function entrance(){
   if(popup)close();
   if(reduce.matches)return;
   const selectors=':scope > *, .kt-charts > .kt-chart-panel';
   const nodes=Array.from(view.querySelectorAll(selectors)).filter(el=>el.offsetParent!==null);
   nodes.slice(0,20).forEach((el,i)=>{
     el.classList.remove('kt-enter');el.style.setProperty('--kt-delay',Math.min(i*65,550)+'ms');
     void el.offsetWidth;el.classList.add('kt-enter');
   });
   view.querySelectorAll('.kt-bar-row').forEach(el=>{el.tabIndex=0;el.setAttribute('role','button');el.setAttribute('aria-label','Show details for '+(el.querySelector('span')?.textContent||'orders'));});
   view.querySelectorAll('.kt-donut').forEach(el=>{el.tabIndex=0;el.setAttribute('role','button');el.setAttribute('aria-label','Show workshop completion details');});
 }
 let scheduled=false;
 new MutationObserver(()=>{if(scheduled)return;scheduled=true;requestAnimationFrame(()=>{scheduled=false;entrance();});}).observe(view,{childList:true});
 function details(el){
   if(!el)return;
   const panel=el.closest('.kt-chart-panel');if(!panel)return;
   const title=panel.querySelector('h3')?.textContent?.trim()||'Workshop overview';
   const label=el.classList.contains('kt-bar-row')?el.querySelector('span')?.textContent?.trim():'Completion progress';
   const count=el.classList.contains('kt-bar-row')?el.querySelector('b')?.textContent?.trim():el.querySelector('strong')?.textContent?.trim();
   close();previous=el;
   popup=document.createElement('section');popup.className='kt-insight';popup.setAttribute('role','dialog');popup.setAttribute('aria-label',title+' details');
   const x=document.createElement('button');x.type='button';x.textContent='×';x.setAttribute('aria-label','Close details');x.addEventListener('click',close);
   const h=document.createElement('h4');h.textContent=label||title;
   const p=document.createElement('p');p.textContent=(count||'0')+(el.classList.contains('kt-bar-row')?' orders':' of tasks completed')+' · '+title+'. Figures reflect the latest data loaded by Kartech OS.';
   popup.append(x,h,p);document.body.appendChild(popup);
   const r=el.getBoundingClientRect();const w=popup.offsetWidth,hgt=popup.offsetHeight;
   popup.style.left=Math.max(12,Math.min(innerWidth-w-12,r.left))+'px';
   popup.style.top=Math.max(12,Math.min(innerHeight-hgt-12,r.bottom+10))+'px';
   x.focus({preventScroll:true});
 }
 view.addEventListener('click',e=>{const el=e.target.closest('.kt-bar-row,.kt-donut');if(el)details(el);});
 view.addEventListener('keydown',e=>{if((e.key==='Enter'||e.key===' ')&&e.target.matches('.kt-bar-row,.kt-donut')){e.preventDefault();details(e.target);}});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&popup)close();});
 document.addEventListener('pointerdown',e=>{if(popup&&!popup.contains(e.target)&&!e.target.closest('.kt-bar-row,.kt-donut'))close();});
 entrance();
})();
