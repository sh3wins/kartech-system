/* =====================================================================
   KARTECH: type with your voice
   Every text box in the owner app gets a small 🎤 button.
   Tap it, speak, and the words are typed into the box.
   Tap again to stop. Works in Chrome (Android phone and computer).
   Language: English (Kenya) or Kiswahili, chosen in Settings.
   ===================================================================== */
(() => {
  const Rec = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!Rec) return;                     // this browser can't listen: no buttons at all

  const KEY = 'kt-voice-lang';
  const getLang = () => { try { return localStorage.getItem(KEY) || 'en-KE'; } catch (e) { return 'en-KE'; } };
  window.KVoice = { getLang, setLang: l => { try { localStorage.setItem(KEY, l); } catch (e) {} } };

  const MIC = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0014 0M12 18v3"/></svg>';
  const OK = 'input[type="text"], input[type="search"], input:not([type]), textarea';

  let rec = null, field = null, btn = null, start = 0, before = '', after = '';

  function stop(){ if (rec){ try { rec.stop(); } catch (e) {} } }
  function done(){
    if (btn){ btn.classList.remove('on'); btn.setAttribute('aria-label', 'Type with your voice'); }
    rec = null; field = null; btn = null;
  }

  function listen(f, b){
    if (rec){ const same = f === field; stop(); if (same) return; }
    field = f; btn = b;
    const pos = typeof f.selectionStart === 'number' ? f.selectionStart : f.value.length;
    before = f.value.slice(0, pos); after = f.value.slice(pos);
    if (before && !/\s$/.test(before)) before += ' ';
    start = Date.now();
    rec = new Rec();
    rec.lang = getLang(); rec.interimResults = true; rec.continuous = true; rec.maxAlternatives = 1;
    rec.onresult = e => {
      let text = '';
      for (let i = 0; i < e.results.length; i++) text += e.results[i][0].transcript;
      text = text.replace(/\s+/g, ' ').trim();
      if (!before.trim()) text = text.charAt(0).toUpperCase() + text.slice(1);
      const max = f.maxLength > 0 ? f.maxLength : Infinity;
      f.value = (before + text + (after && !/^\s/.test(after) ? ' ' : '') + after).slice(0, max);
      const caret = Math.min((before + text).length, f.value.length);
      try { f.setSelectionRange(caret, caret); } catch (er) {}
      f.dispatchEvent(new Event('input', { bubbles: true }));
    };
    rec.onerror = e => {
      const t = window.toast || (m => alert(m));
      if (e.error === 'not-allowed' || e.error === 'service-not-allowed') t('Allow the microphone for this site, then tap 🎤 again.');
      else if (e.error === 'no-speech') t('Didn\'t hear anything. Tap 🎤 and speak.');
      else if (e.error === 'network') t('Voice typing needs the internet.');
    };
    rec.onend = () => { f.dispatchEvent(new Event('change', { bubbles: true })); done(); };
    try { rec.start(); } catch (e) { done(); return; }
    b.classList.add('on'); b.setAttribute('aria-label', 'Stop listening');
    f.focus();
  }

  // give a text box its 🎤 button (once)
  function add(f){
    if (f.dataset.voice || f.dataset.novoice !== undefined || f.readOnly || f.disabled) return;
    if (f.closest('#loginView, #setupView')) return;      // not on the sign-in screen
    f.dataset.voice = '1';
    const wrap = document.createElement('span');
    wrap.className = 'vt-wrap' + (f.tagName === 'TEXTAREA' ? ' vt-area' : '');
    f.parentNode.insertBefore(wrap, f); wrap.appendChild(f);
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'vt-mic'; b.innerHTML = MIC; b.setAttribute('aria-label', 'Type with your voice'); b.tabIndex = -1;
    b.addEventListener('mousedown', e => e.preventDefault());   // keep the cursor in the box
    b.addEventListener('click', e => { e.preventDefault(); e.stopPropagation(); listen(f, b); });
    wrap.appendChild(b);
  }
  const scan = root => { if (root.matches && root.matches(OK)) add(root); if (root.querySelectorAll) root.querySelectorAll(OK).forEach(add); };

  new MutationObserver(list => {
    for (const m of list){
      m.addedNodes.forEach(n => { if (n.nodeType === 1) scan(n); });
      m.removedNodes.forEach(n => { if (rec && field && n.nodeType === 1 && n.contains(field)) stop(); });
    }
  }).observe(document.documentElement, { childList: true, subtree: true });
  if (document.readyState !== 'loading') scan(document.body); else document.addEventListener('DOMContentLoaded', () => scan(document.body));

  const css = document.createElement('style');
  css.textContent = `
    .vt-wrap{position:relative;display:block;flex:1 1 auto;min-width:0}
    .vt-wrap > input, .vt-wrap > textarea{width:100%;padding-right:46px !important;box-sizing:border-box}
    .vt-mic{position:absolute;right:6px;top:50%;transform:translateY(-50%);width:34px;height:34px;border-radius:50%;
      border:0;background:transparent;color:#5F6F64;display:flex;align-items:center;justify-content:center;cursor:pointer;padding:0}
    .vt-area .vt-mic{top:8px;transform:none}
    .vt-mic:hover{background:rgba(24,88,68,.08);color:#185844}
    .vt-mic.on{background:#C2410C;color:#fff;animation:vtPulse 1.2s ease-in-out infinite}
    @keyframes vtPulse{0%,100%{box-shadow:0 0 0 0 rgba(194,65,12,.45)}50%{box-shadow:0 0 0 8px rgba(194,65,12,0)}}
    @media (prefers-reduced-motion: reduce){.vt-mic.on{animation:none}}`;
  document.head.appendChild(css);
})();
