/* Workshop appearance only. Does not alter station workflow or verification. */
(()=>{
  const KEY='kartech-station-theme';
  const root=document.documentElement;
  let theme='light';
  try{theme=localStorage.getItem(KEY)||'light'}catch(e){}
  const apply=()=>{root.dataset.theme=theme;document.querySelectorAll('.sw-theme-toggle').forEach(b=>{b.textContent=theme==='dark'?'Light mode':'Dark mode';b.setAttribute('aria-pressed',String(theme==='dark'));});};
  apply();
  const mount=()=>{
    const foot=document.querySelector('.sw-foot');
    if(!foot||foot.querySelector('.sw-theme-toggle'))return;
    const button=document.createElement('button');button.type='button';button.className='sw-theme-toggle';
    button.addEventListener('click',()=>{theme=theme==='dark'?'light':'dark';try{localStorage.setItem(KEY,theme)}catch(e){}apply()});
    foot.appendChild(button);apply();
  };
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount);else mount();
})();
