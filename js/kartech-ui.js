/* Presentation-only enhancement: no database, permissions, or workflow changes. */
(()=>{
  const KEY='kartech-owner-theme';
  const root=document.documentElement;
  const saved=localStorage.getItem(KEY);
  const systemDark=window.matchMedia('(prefers-color-scheme: dark)').matches;
  const apply=(theme)=>{root.dataset.theme=theme;document.querySelectorAll('.theme-toggle').forEach(b=>{b.querySelector('.theme-icon').textContent=theme==='dark'?'☀':'☾';b.querySelector('.theme-label').textContent=theme==='dark'?'Light mode':'Dark mode';b.setAttribute('aria-pressed',String(theme==='dark'));});};
  apply(saved==='light'||saved==='dark'?saved:(systemDark?'dark':'light'));
  function mount(){
    const foot=document.querySelector('.side-foot');
    if(foot&&!foot.querySelector('.theme-toggle')){
      const btn=document.createElement('button');btn.type='button';btn.className='theme-toggle';btn.innerHTML='<span class="theme-icon" aria-hidden="true">☾</span><span class="theme-label">Dark mode</span>';
      btn.addEventListener('click',()=>{const next=root.dataset.theme==='dark'?'light':'dark';localStorage.setItem(KEY,next);apply(next);});
      foot.insertBefore(btn,foot.firstChild);
    }
    const mbar=document.getElementById('mbar');
    if(mbar&&!mbar.querySelector('.theme-toggle')){
      const btn=document.createElement('button');btn.type='button';btn.className='theme-toggle';btn.style.width='auto';btn.style.margin='0 6px';btn.setAttribute('aria-label','Toggle dark mode');btn.innerHTML='<span class="theme-icon" aria-hidden="true">☾</span><span class="theme-label" style="display:none">Dark mode</span>';
      btn.addEventListener('click',()=>{const next=root.dataset.theme==='dark'?'light':'dark';localStorage.setItem(KEY,next);apply(next);});mbar.appendChild(btn);
    }
    apply(root.dataset.theme);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount);else mount();
})();
