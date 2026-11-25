/* =====================================================================
   KARTECH: pick a piece from the shop stock (Stock → Shop products)
   KStock.pick(db) → opens a picker over whatever is on screen and
   resolves with { product, file } (file = its main photo, ready to add
   as a "What to make" picture), or null if closed.
   No prices are shown here (the workshop screen uses it too).
   ===================================================================== */
window.KStock = (() => {
  const SITE = 'https://sh3wins.github.io/kartech-website/';
  const url = s => !s ? '' : /^(https?:|\/|blob:|data:)/.test(s) ? s : SITE + s;
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
  let cache = null;
  function css(){
    if (document.getElementById('kstock-css')) return;
    const st = document.createElement('style'); st.id = 'kstock-css';
    st.textContent = `.kst{position:fixed;inset:0;z-index:300;background:rgba(10,31,26,.55);display:flex;align-items:flex-end;justify-content:center}
      @media(min-width:700px){.kst{align-items:center}}
      .kst-p{background:#fff;width:100%;max-width:760px;max-height:88vh;border-radius:18px 18px 0 0;display:flex;flex-direction:column;overflow:hidden;font-family:inherit;color:#102F27}
      @media(min-width:700px){.kst-p{border-radius:18px}}
      .kst-h{display:flex;gap:10px;align-items:center;padding:16px 16px 10px}
      .kst-h b{font-size:19px;flex:1}
      .kst-x{border:1px solid #E3D9C6;background:#fff;border-radius:999px;padding:8px 14px;font:inherit;font-weight:600;cursor:pointer}
      .kst-s{margin:0 16px 10px;padding:12px 14px;border:1px solid #E3D9C6;border-radius:12px;font:inherit;font-size:15px}
      .kst-g{overflow:auto;padding:0 16px 18px;display:grid;grid-auto-rows:max-content;align-content:start;flex:1 1 auto;min-height:0;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:12px}
      .kst .kst-c{border:1px solid #E3D9C6;border-radius:12px;background:#fff;padding:0 0 9px;overflow:hidden;text-align:left;cursor:pointer;color:inherit;display:block;height:auto;min-height:0;margin:0}
      .kst-c:hover,.kst-c:focus-visible{border-color:#185844;box-shadow:0 0 0 2px #185844}
      .kst .kst-c .kst-i{display:block;position:relative;width:100%;padding-top:125%;height:auto;background:#E6E2D8;margin:0 0 7px}
      .kst .kst-c .kst-i img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;display:block;margin:0;max-width:none}
      .kst .kst-c .kst-n{display:block;font-size:13.5px;font-weight:600;padding:0 9px;line-height:1.3}
      .kst-e{padding:20px 16px;color:#5F6F64}
      .kst-busy{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;background:rgba(255,255,255,.75);font-weight:700}`;
    document.head.appendChild(st);
  }
  async function list(db){
    if (cache) return cache;
    const { data, error } = await db.from('kt_products').select('id,name,images,tags,active').order('sort').order('name');
    if (error) throw new Error(/kt_products/.test(error.message || '') ? 'Run update-26-shop-products.sql in Supabase first.' : (error.message || 'Could not load the stock'));
    cache = data.filter(p => p.active && (p.images || []).length);
    setTimeout(() => { cache = null; }, 60000);
    return cache;
  }
  async function fileOf(p){
    const r = await fetch(url(p.images[0]), { mode: 'cors' });
    if (!r.ok) throw new Error('Could not get that photo');
    const b = await r.blob();
    return new File([b], p.id + '.jpg', { type: b.type && /^image\//.test(b.type) ? b.type : 'image/jpeg' });
  }
  function pick(db){
    css();
    return new Promise(async done => {
      const el = document.createElement('div'); el.className = 'kst';
      el.innerHTML = `<div class="kst-p" role="dialog" aria-label="Pick from stock" style="position:relative"><div class="kst-h"><b>Pick from stock</b><button class="kst-x" type="button">Close</button></div>
        <input class="kst-s" type="search" placeholder="Search, e.g. bar stool"><div class="kst-g"><p class="kst-e">Loading the stock…</p></div></div>`;
      document.body.appendChild(el);
      const close = v => { el.remove(); done(v); };
      el.addEventListener('click', e => { if (e.target === el || e.target.closest('.kst-x')) close(null); });
      let items = [];
      const draw = q => {
        const k = String(q || '').toLowerCase().trim();
        const show = items.filter(p => !k || (p.name + ' ' + (p.tags || []).join(' ')).toLowerCase().includes(k));
        el.querySelector('.kst-g').innerHTML = show.length ? show.map(p => `<div class="kst-c" role="button" tabindex="0" data-id="${esc(p.id)}"><div class="kst-i"><img src="${esc(url(p.images[0]))}" alt="" loading="lazy"></div><div class="kst-n">${esc(p.name)}</div></div>`).join('')
          : `<p class="kst-e">${items.length ? 'Nothing matches. Try another word.' : 'No stock with photos yet. Add some in Stock → Shop products.'}</p>`;
      };
      try { items = await list(db); draw(''); } catch (e){ el.querySelector('.kst-g').innerHTML = `<p class="kst-e">${esc(e.message)}</p>`; }
      el.querySelector('.kst-s').addEventListener('input', e => draw(e.target.value));
      el.querySelector('.kst-g').addEventListener('keydown', e => { if ((e.key === 'Enter' || e.key === ' ') && e.target.closest('[data-id]')){ e.preventDefault(); e.target.click(); } });
      el.querySelector('.kst-g').addEventListener('click', async e => {
        const b = e.target.closest('[data-id]'); if (!b) return;
        const p = items.find(x => x.id === b.dataset.id);
        const busy = document.createElement('div'); busy.className = 'kst-busy'; busy.textContent = 'Getting the photo…'; el.querySelector('.kst-p').appendChild(busy);
        try { close({ product: p, file: await fileOf(p) }); }
        catch (er){ busy.remove(); close({ product: p, file: null }); }
      });
    });
  }
  return { pick };
})();
