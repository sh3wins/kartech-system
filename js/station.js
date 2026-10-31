/* =====================================================================
   KARTECH WORKSHOP — shared workshop computer
   1. Signed in once with the workshop account (stays signed in).
   2. A worker taps their name and sees only their own job (no PIN).
   3. Signs the worker out after a minute with no taps.
   ===================================================================== */
(function(){
  const v = $('#stView');
  let tools = null, workers = [], pinFor = null, pin = '', token = null, me = null, job = null, mats = [];
  let probOpen = false, probReason = null, idleT = null, idleLeft = 0, pollT = null, sending = false;

  if (!db){ v.innerHTML = '<h1>Not set up yet</h1><p class="lead">Add the Supabase keys in js/config.js.</p>'; return; }

  /* ---------- one-time computer setup ---------- */
  async function boot(){
    const { data: { session } } = await db.auth.getSession();
    if (!session){ $('#setView').classList.remove('hidden'); v.innerHTML = ''; return; }
    const { data: ok, error } = await db.rpc('ws_is_station');
    if (error || !ok){
      const { data: owner } = await db.rpc('is_admin');
      if (!owner){ await db.auth.signOut(); $('#setView').classList.remove('hidden'); $('#sErr').textContent = "That account isn't the workshop account."; return; }
    }
    $('#setView').classList.add('hidden'); $('#live').classList.remove('hidden'); const sb = $('#sndBtn'); if (sb) sb.classList.remove('hidden'); soundBtn();
    await loadSteps();
    await loadNames();
  }
  $('#setForm').addEventListener('submit', async e => {
    e.preventDefault(); $('#sErr').textContent = ''; $('#sBtn').disabled = true;
    const { error } = await db.auth.signInWithPassword({ email: $('#sEmail').value.trim(), password: $('#sPass').value });
    $('#sBtn').disabled = false;
    if (error){ $('#sErr').textContent = 'Wrong email or password.'; return; }
    boot();
  });

  async function loadNames(){
    let { data, error } = await db.rpc('ws_station_board');
    if (error && /ws_station_board|function/i.test(errMsg(error))) ({ data, error } = await db.rpc('ws_station_workers'));
    if (!error) announceJobs(data);
    if (error){ v.innerHTML = `<h1>Can't reach the system</h1><p class="lead">${esc(errMsg(error))}</p><button class="giant done" id="retry">Try again</button>`; return; }
    workers = data; await loadTools(); render();
  }


  /* ---------- new jobs: shown next to each name + said out loud ---------- */
  let prevJob = null, sound = true;
  try { sound = localStorage.getItem('kt-st-sound') !== 'off'; } catch(e){}
  const sayRef = ref => String(ref).replace('KT-', 'K T ').split('').join(' ').replace(/\s+/g, ' ');
  function beep(){ try { const a = new (window.AudioContext || window.webkitAudioContext)(); [0, .18].forEach(d => { const o = a.createOscillator(), g = a.createGain();
      o.frequency.value = d ? 988 : 784; o.connect(g); g.connect(a.destination); g.gain.setValueAtTime(.25, a.currentTime + d); g.gain.exponentialRampToValueAtTime(.001, a.currentTime + d + .16); o.start(a.currentTime + d); o.stop(a.currentTime + d + .17); }); } catch(e){} }
  function speak(text){
    if (!sound || !window.speechSynthesis) return;
    const u = new SpeechSynthesisUtterance(text);
    const vs = speechSynthesis.getVoices(); const v = vs.find(x => /en[-_](KE|GB)/i.test(x.lang)) || vs.find(x => /^en/i.test(x.lang)); if (v){ u.voice = v; u.lang = v.lang; } else u.lang = 'en-GB';
    u.rate = .9; speechSynthesis.speak(u);
  }
  function announceJobs(list){
    const now = new Map((list || []).map(w => [w.id, w.job ? w.job.task : null]));
    if (prevJob){
      const fresh = (list || []).filter(w => w.job && w.job.status === 'assigned' && prevJob.get(w.id) !== w.job.task);
      if (fresh.length){ beep(); setTimeout(() => fresh.slice(0, 4).forEach(w => speak(`${w.name}, new job: ${sayRef(w.job.ref)}, ${stageName(w.job.stage)}${w.job.with ? ', together with ' + w.job.with : ''}.`)), 450); }
    }
    prevJob = now;
  }
  function soundBtn(){ const b = $('#sndBtn'); if (!b) return; b.textContent = sound ? '🔊 Sound on' : '🔇 Sound off'; b.classList.toggle('off', !sound); }
  document.addEventListener('click', e => { if (!e.target.closest('#sndBtn')) return;
    sound = !sound; try { localStorage.setItem('kt-st-sound', sound ? 'on' : 'off'); } catch(x){} soundBtn(); if (sound){ beep(); speak('Job announcements are on.'); } });
  setInterval(async () => { if (me || fm || document.visibilityState !== 'visible' || !workers.length && !prevJob) return;
    const { data, error } = await db.rpc('ws_station_board'); if (error) return;
    announceJobs(data);
    if (JSON.stringify(data) !== JSON.stringify(workers)){ workers = data; if (!me && !fm) render(); } }, 10000);


  /* ---------- colour + emoji for each trade (makes the screen friendlier) ---------- */
  const TRADE = { get:['#64748B','🏗️'], cut:['#F97316','🪚'], fold:['#3B82F6','📐'], weld:['#EF4444','🔥'], grind:['#8B5CF6','⚙️'],
                  paint:['#EC4899','🎨'], foam:['#14B8A6','🛋️'], finish:['#EAB308','✨'], load:['#22C55E','🚚'] };
  const SPARE = [['#0EA5E9','🔧'],['#F43F5E','🛠️'],['#84CC16','📦'],['#A855F7','🧰']];
  const trade = id => TRADE[id] || SPARE[Math.max(0, STAGES.findIndex(x => x.id === id)) % SPARE.length];
  const tc = id => `--tc:${trade(id)[0]}`;
  const hello = () => { const h = new Date().getHours(); return h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening'; };
  const TIPS = ['Safety first: goggles and gloves on', 'Tools back on the rack by ' + (KT_CONFIG.toolCheckAt || '18:30') + '', 'Measure twice, cut once',
                'Good work makes happy customers', 'Stuck? Tap your name and report a problem', 'Leftover material goes back to the store'];
  function sideGreet(){ const g = $('#swHello'); if (!g) return; g.querySelector('b').textContent = hello() + ', team!';
    const t = g.querySelector('small'); t.classList.remove('in'); void t.offsetWidth; t.textContent = TIPS[Math.floor(Date.now() / 20000) % TIPS.length]; t.classList.add('in'); }
  setInterval(sideGreet, 20000);

  /* ---------- clock ---------- */
  function tickClock(){ const d = new Date();
    $('#clk').innerHTML = d.toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' }).replace(':', '<i>:</i>');
    $('#clkDate').textContent = d.toLocaleDateString('en-GB', { weekday:'short', day:'numeric', month:'short', year:'numeric' }); }
  tickClock(); setInterval(tickClock, 10000); setTimeout(sideGreet, 0);
  let lastScreen = '';

  /* ---------- FOREMAN page (behind the manager code) ---------- */
  async function loadTools(){
    const { data, error } = await db.rpc('ws_tool_list');
    tools = error ? null : data;
  }
  const nbNow = () => new Date(new Date().toLocaleString('en-US', { timeZone:'Africa/Nairobi' }));
  const checkTime = () => { const [h, m] = (KT_CONFIG.toolCheckAt || '18:30').split(':').map(Number); const n = nbNow(); return n.getHours() * 60 + n.getMinutes() >= h * 60 + m; };
  const checkNeeded = () => tools && tools.has_tools && !tools.done_today && checkTime();
  setInterval(async () => { if (!me && !fm){ const before = JSON.stringify(tools); await loadTools(); if (JSON.stringify(tools) !== before) render(); } }, 60000);
  let fm = null;      // { view:'pin'|'home'|'worker'|'check', pin, entry, data, wid, pick, qty, then, miss:Set }
  let fmT = null;
  function fmIdle(){ clearTimeout(fmT); fmT = setTimeout(() => { if (fm){ fm = null; render(); } }, 120000); }
  function fmClose(){ fm = null; clearTimeout(fmT); loadTools().then(render); }
  async function fmLoad(){
    const { data, error } = await db.rpc('ws_foreman_open', { p_pin: fm.pin });
    if (error){ toast(errMsg(error)); return false; }
    if (data && data.error){ return data.error; }
    fm.data = data; return true;
  }
  const fmTime = t => new Date(t).toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
  const fmW = id => fm.data.workers.find(w => w.id === id);
  function renderForeman(){
    const head = (title, sub, back) => `<div class="st-head anim"><div><h1>${title}</h1>${sub ? `<p class="lead">${sub}</p>` : ''}</div>
      <div class="st-out"><button class="btn line" id="${back ? 'fmBack' : 'fmExit'}">${back ? '← Back' : 'Close'}</button><p class="idle">Locks by itself after 2 minutes</p></div></div>`;
    if (fm.view === 'pin'){
      v.innerHTML = `<div class="fm-pin anim"><h1>Manager</h1><p class="lead">Enter the manager code</p>
        <div class="pindots">${[0,1,2,3].map(i => `<i class="${i < fm.entry.length ? 'on' : ''}"></i>`).join('')}</div>
        <div class="pad">${[1,2,3,4,5,6,7,8,9].map(n => `<button data-fk="${n}">${n}</button>`).join('')}<button data-fk="x" class="sm">Cancel</button><button data-fk="0">0</button><button data-fk="del" class="sm">⌫</button></div>
        <p class="err" id="fmErr">${fm.err || ''}</p></div>`;
      return;
    }
    const d = fm.data;
    if (fm.view === 'home'){
      const out = d.tools.filter(t => t.with);
      const notIn = d.workers.filter(w => !w.in), inn = d.workers.filter(w => w.in);
      const card = w => { const n = d.tools.filter(t => t.with === w.id).length;
        return `<button class="name fmname ${w.in ? 'in' : 'notin'}" data-fw="${w.id}"><span class="av">${w.in ? '✓' : esc(w.name.charAt(0))}</span><span>${esc(w.name)}<small>${w.in
          ? `In ${w.arrived_at ? fmTime(w.arrived_at) : ''}${n ? ' · 🔧 ' + n : ''}${w.job ? ' · ' + esc(w.job.ref) : ''}`
          : w.away ? 'Away today' : esc(stageName(w.stage)) + ' · tap when they arrive'}</small></span></button>`; };
      v.innerHTML = head('Manager', 'When a worker walks in, tap their name. Their tools pop up. Tick what they take.') + `
        <button class="tc-banner anim ${checkNeeded() ? 'due' : ''}" id="fmCheck" style="--i:1"><span>🔧</span><span><b>${d.done_today ? 'Tool check done for today ✓' : 'Evening tool check'}</b><small>${out.length ? out.length + ' tool' + (out.length > 1 ? 's' : '') + ' out right now' : 'All tools are in'}</small></span></button>
        <div class="fm-adds anim" style="--i:1"><button class="fm-add sale" id="fmNewOrder">＋ New order <small>(customer in the shop)</small></button><button class="fm-add" id="fmAddW">＋ Add a new worker</button></div>
        ${notIn.length ? `<div class="st-group anim" style="--i:2"><h4>Not in yet · ${notIn.length}</h4><div class="names">${notIn.map(card).join('')}</div></div>` : ''}
        ${inn.length ? `<div class="st-group anim" style="--i:3"><h4>In today · ${inn.length}</h4><div class="names">${inn.map(card).join('')}</div></div>` : ''}`;
      return;
    }
    if (fm.view === 'worker'){
      const w = fmW(fm.wid); if (!w){ fm.view = 'home'; return renderForeman(); }
      const mats = d.materials.filter(m => !m.stages || !m.stages.length || m.stages.includes(w.stage));
      const forTrade = t => (t.stages && t.stages.includes(w.stage)) || t.usual === w.id || t.with === w.id;
      const mine = d.tools.filter(forTrade), others = d.tools.filter(t => !forTrade(t));
      const tile = t => { const has = t.with === w.id, other = t.with && !has;
        return `<button class="tc ${has ? 'out' : other ? 'other' : ''}" data-ft="${t.id}"><span class="tc-ic">${has ? '✓' : other ? '•' : '+'}</span><span><b>${esc(t.name)}</b><small>${has ? 'Taken · ' + fmTime(t.since) : other ? 'With ' + esc(t.with_name || 'someone') : 'Tap if he takes it'}</small></span></button>`; };
      v.innerHTML = head(esc(w.name), `${stageName(w.stage)}${w.job ? ` · on <b>${esc(w.job.ref)}</b>, ${w.job.qty} × ${esc(w.job.item)}` : ''}`, true) + `
        <div class="in-strip anim"><button class="link-sm fm-edw" id="fmEditW">✏️ Change ${esc(w.name)}'s job</button>${w.in ? `<span class="in-ok">✓ In today${w.arrived_at ? ' since ' + fmTime(w.arrived_at) : ''}</span><button class="link-sm" id="fmUnarrive">Ticked by mistake? Undo</button>` : `<span>Not in yet</span><button class="btn" id="fmArrive">Tick ${esc(w.name)} in</button>`}</div>
        <div class="st-group anim" style="--i:1"><h4>${esc(stageName(w.stage))} tools · tick what ${esc(w.name)} takes</h4>
          <div class="tc-grid">${mine.map(tile).join('') || `<p class="muted">No tools set for ${esc(stageName(w.stage))} yet. The owner sets this in the app (Stock → edit a tool → "Used by").</p>`}</div>
          ${others.length ? (fm.showAll ? `<h4 style="margin-top:16px">Other tools</h4><div class="tc-grid">${others.map(tile).join('')}</div>` : `<button class="link-sm" id="fmAllTools" style="margin-top:12px">+ Show other tools (${others.length})</button>`) : ''}</div>
        <div class="st-group anim" style="--i:2"><h4>Materials · tap what he takes</h4><div class="tc-grid">${mats.map(m => { const td = w.today.find(x => x.material_id === m.id); const nf = x => +(+x).toFixed(2);
          return `<div class="mat-tile ${td ? 'has' : ''}"><button class="tc mat" data-fmat="${m.id}"><span class="tc-ic">📦</span><span><b>${esc(m.name)}</b><small>${td ? `<em>${nf(td.qty)} ${esc(m.unit)} taken today${td.times > 1 ? ' (' + td.times + ' times)' : ''}</em>` : ''}${m.counted === false ? `${nf(m.used_today || 0)} ${esc(m.unit)} used today (everyone)` : `${nf(m.in_store)} ${esc(m.unit)} in store`}</small></span></button>
            ${td && td.last ? `<button class="again" data-again="${m.id}" data-q="${nf(td.last)}">+ ${nf(td.last)} again</button>` : ''}</div>`; }).join('') || '<p class="muted">No materials for this step yet.</p>'}</div></div>
        <button class="giant go anim" id="fmDone" style="--i:3">✓ Done</button>
        ${fm.pick ? qtyPanel(w) : ''}`;
      return;
    }
    if (fm.view === 'qr' && fm.qr){
      v.innerHTML = head('Give this to the customer', `Order ${esc(fm.qr.ref)} is saved. This is the customer's own Order Room.`, false) + `
        <div class="qr-wrap anim" style="--i:1">
          <div class="qr-big">${fm.qr.svg || '<p class="muted">Making the code…</p>'}</div>
          <div class="qr-how">
            <h3>Customer: scan this with your phone camera</h3>
            <ol><li>Open your phone camera</li><li>Point it at the code</li><li>Tap the link that appears</li></ol>
            <p class="muted">In their Order Room they can send photos, write to Kartech and approve the design. Keep the page: the link works any time.</p>
            <p class="qr-link">${esc(fm.qr.link)}</p>
          </div>
        </div>
        <button class="giant go anim" id="qrDone" style="--i:2">✓ Done</button>`;
      return;
    }
    if (fm.view === 'neworder'){
      const n = fm.no, chip = st => `<button class="fm-chip ${n.stages.includes(st.id) ? 'on' : ''}" data-nst="${st.id}">${n.stages.includes(st.id) ? '✓ ' : ''}${esc(st.name)}</button>`;
      v.innerHTML = head('New order', 'A customer is here and the owner is away. Write it down here, the owner is told straight away.', true) + `
        <div class="no-grid anim" style="--i:1">
          <label class="no-f"><span>Customer name</span><input class="fm-in" data-nf="customer" value="${esc(n.customer)}" placeholder="e.g. Mary Wanjiku" autocomplete="off"></label>
          <label class="no-f"><span>Phone</span><input class="fm-in" data-nf="phone" value="${esc(n.phone)}" placeholder="07…" inputmode="tel" autocomplete="off"></label>
          <label class="no-f"><span>What</span><input class="fm-in" data-nf="item" value="${esc(n.item)}" placeholder="e.g. Bar stools" autocomplete="off"></label>
          <label class="no-f"><span>How many</span><input class="fm-in" data-nf="qty" value="${esc(n.qty)}" inputmode="numeric" placeholder="1"></label>
          <label class="no-f"><span>Ready by</span><input class="fm-in" type="date" data-nf="deadline" value="${esc(n.deadline)}"></label>
          <div class="no-f"><span>How urgent</span><div class="fm-chips">${['normal','urgent'].map(u => `<button class="fm-chip ${n.urgency === u ? 'on' : ''}" data-nurg="${u}">${u === 'normal' ? 'Normal' : '⚡ Urgent'}</button>`).join('')}</div></div>
        </div>
        <label class="no-f anim" style="--i:2"><span>Exact details: size, colour, material</span><textarea class="fm-in" data-nf="notes" rows="3" placeholder="e.g. 75 cm high, black frame, red seat">${esc(n.notes)}</textarea></label>
        <div class="st-group anim" style="--i:3"><h4>📐 Pictures of what to make</h4>
          <div class="no-pics">${n.files.map((f, i) => `<div class="ph"><img src="${f._u}" alt=""><button class="ph-rm" data-npx="${i}">✕</button></div>`).join('')}
            <label class="fm-chip no-add">📷 Add picture<input type="file" accept="image/*" capture="environment" multiple id="noPics" hidden></label></div></div>
        <div class="st-group anim" style="--i:4"><h4>Steps it needs · tap to remove</h4><div class="fm-chips">${STAGES.map(chip).join('')}</div></div>
        <p class="err" id="noErr">${esc(n.err || '')}</p>
        <button class="giant go anim" id="noSave" style="--i:5">✓ Add order</button>`;
      v.querySelectorAll('[data-nf]').forEach(el => el.addEventListener('input', () => { fm.no[el.dataset.nf] = el.value; fmIdle(); }));
      const pi = $('#noPics'); if (pi) pi.onchange = () => { [...pi.files].filter(f => /^image\//.test(f.type)).forEach(f => { f._u = URL.createObjectURL(f); fm.no.files.push(f); }); renderForeman(); };
      return;
    }
    if (fm.view === 'wedit'){
      const e = fm.ed, chip = (st, on, attr) => `<button class="fm-chip ${on ? 'on' : ''}" ${attr}="${st.id}">${on ? '✓ ' : ''}${esc(st.name)}</button>`;
      v.innerHTML = head(e.id ? 'Change ' + esc(e.orig) + "'s job" : 'Add a new worker', 'Their main job decides which work and tools come to them.', true) + `
        <div class="st-group anim" style="--i:1"><h4>Name</h4><input class="fm-in" id="fmName" value="${esc(e.name)}" placeholder="e.g. Brighton" autocomplete="off"></div>
        <div class="st-group anim" style="--i:2"><h4>Main job · pick one</h4><div class="fm-chips">${STAGES.map(st => chip(st, e.stage === st.id, 'data-fmain')).join('')}</div>
          ${e.busy ? '<p class="muted" style="margin-top:8px">He is on a job now. A new main job starts after he finishes it.</p>' : ''}</div>
        <div class="st-group anim" style="--i:3"><h4>Can also do · tap any (optional)</h4><div class="fm-chips">${STAGES.filter(st => st.id !== e.stage).map(st => chip(st, e.covers.includes(st.id), 'data-fcov')).join('')}</div></div>
        <p class="err" id="fmWErr">${esc(e.err || '')}</p>
        <button class="giant go anim" id="fmSaveW" style="--i:4">✓ ${e.id ? 'Save' : 'Add ' + (e.name ? esc(e.name) : 'worker')}</button>`;
      const inp = $('#fmName'); inp.addEventListener('input', () => { fm.ed.name = inp.value; fmIdle(); const sb = $('#fmSaveW'); if (sb && !fm.ed.id) sb.textContent = '✓ Add ' + (inp.value.trim() || 'worker'); });
      if (!e.id && !e.name) setTimeout(() => inp.focus(), 50);
      return;
    }
    if (fm.view === 'check'){
      const groups = {};
      d.tools.forEach(t => { const g = t.with ? 'With ' + (t.with_name || 'someone') : 'Should be on the rack'; (groups[g] = groups[g] || []).push(t); });
      const n = fm.miss.size;
      v.innerHTML = head('Tool check', 'Look at the rack. Everything is ticked as back. Tap only what is <b>missing</b>.', true) + `
        ${Object.entries(groups).sort((a, b) => a[0].startsWith('Should') - b[0].startsWith('Should')).map(([g, ts], gi) => `<div class="st-group anim" style="--i:${gi + 1}"><h4>${esc(g)}</h4><div class="tc-grid">${ts.map(t => { const miss = fm.miss.has(t.id);
          return `<button class="tc ${miss ? 'miss' : ''}" data-fc="${t.id}"><span class="tc-ic">${miss ? '✕' : '✓'}</span><span><b>${esc(t.name)}</b><small>${miss ? (t.missing ? 'Still missing' : 'Missing') : 'Back'}</small></span></button>`; }).join('')}</div></div>`).join('') || '<p class="muted">No tools added yet.</p>'}
        <button class="giant ${n ? 'warnb' : 'go'}" id="fmCheckDone">${n ? `Done: ${n} missing` : '✓ All tools are back'}</button>`;
    }
  }
  function qtyPanel(w){
    const m = fm.data.materials.find(x => x.id === fm.pick); if (!m) return '';
    return `<div class="fm-qty"><div class="sw-card">
      <p class="k">${esc(w.name)} takes</p><h2>${esc(m.name)}</h2>
      <div class="qty-show"><b>${fm.qty || '0'}</b> ${esc(m.unit)}</div>
      <div class="quick">${[1, 2, 5, 10].map(n => `<button data-fq="${n}">${n}</button>`).join('')}</div>
      <div class="pad">${[1,2,3,4,5,6,7,8,9].map(n => `<button data-fn="${n}">${n}</button>`).join('')}<button data-fn=".">.</button><button data-fn="0">0</button><button data-fn="del" class="sm">⌫</button></div>
      <div class="qty-acts"><button class="btn line" id="fqCancel">Cancel</button><button class="btn line" id="fqBack">Brought back</button><button class="btn" id="fqGive">Give ${fm.qty || ''} ${esc(m.unit)}</button></div>
    </div></div>`;
  }
  async function fmClick(b){
    fmIdle();
    if (b.id === 'fmExit') return fmClose();
    if (b.id === 'fmBack' && fm.view === 'neworder'){ fm.no = null; fm.view = 'home'; return renderForeman(); }
    if (b.id === 'fmBack' && fm.view === 'wedit' && fm.ed && fm.ed.id){ fm.view = 'worker'; return renderForeman(); }
    if (b.id === 'fmBack'){ fm.view = 'home'; fm.pick = null; await fmLoad(); return renderForeman(); }
    if (b.id === 'fmNewOrder'){ const d = new Date(); d.setDate(d.getDate() + 7);
      fm.no = { customer:'', phone:'', item:'', qty:'1', deadline: d.toLocaleDateString('en-CA'), urgency:'normal', notes:'', files:[], stages: STAGES.map(x => x.id), err:'' }; fm.view = 'neworder'; return renderForeman(); }
    if (b.dataset.nst){ const x = b.dataset.nst, st = fm.no.stages; fm.no.stages = st.includes(x) ? st.filter(y => y !== x) : STAGES.map(z => z.id).filter(z => st.includes(z) || z === x); return renderForeman(); }
    if (b.dataset.nurg){ fm.no.urgency = b.dataset.nurg; return renderForeman(); }
    if (b.dataset.npx){ fm.no.files.splice(+b.dataset.npx, 1); return renderForeman(); }
    if (b.id === 'noSave'){ const n = fm.no;
      if (!n.customer.trim() || !n.item.trim()){ n.err = 'Write the customer and what they want.'; return renderForeman(); }
      if (!n.stages.length){ n.err = 'Keep at least one step.'; return renderForeman(); }
      b.disabled = true; b.textContent = 'Adding…';
      const notes = [n.notes.trim(), n.phone.trim() ? 'Phone: ' + n.phone.trim() : ''].filter(Boolean).join(' · ');
      const { data, error } = await db.rpc('ws_foreman_create_order', { p_pin: fm.pin, p: { customer: n.customer.trim(), item: n.item.trim(), qty: Math.max(1, parseInt(n.qty, 10) || 1), deadline: n.deadline || null, urgency: n.urgency, notes, stages: n.stages } });
      if (error){ n.err = /ws_foreman_create_order/.test(errMsg(error)) ? 'The owner needs to run update-15-sales.sql in Supabase first.' : errMsg(error); return renderForeman(); }
      let bad = 0;
      for (const f of n.files){ b.textContent = 'Adding pictures…';
        try { if (!db.storage) throw 0; const blob = await shrinkPic(f), path = `${data.id}/${Date.now()}.jpg`;
          const up = await db.storage.from('kartech-photos').upload(path, blob, { contentType:'image/jpeg', upsert:false }); if (up.error) throw up.error;
          const r = await db.rpc('ws_foreman_add_photo', { p_pin: fm.pin, p_order: data.id, p_path: path }); if (r.error) throw r.error;
        } catch(e){ bad++; } }
      toast(`${data.ref} added ✓ The owner has been told.${bad ? ` ${bad} picture${bad > 1 ? 's' : ''} did not upload.` : ''}`);
      const rc = await db.rpc('ws_foreman_room_code', { p_pin: fm.pin, p_order: data.id });
      fm.no = null; await fmLoad();
      if (!rc.error && rc.data){ fm.qr = { ref: data.ref, link: new URL('room.html?c=' + rc.data, location.href).href, svg: '' }; fm.view = 'qr'; renderForeman();
        try { const q = (await loadQR())(0, 'M'); q.addData(fm.qr.link); q.make(); fm.qr.svg = q.createSvgTag({ cellSize: 8, margin: 3, scalable: true }); } catch(e){ fm.qr.svg = '<p class="muted">Could not make the code. Give the customer the link below.</p>'; }
        return renderForeman(); }
      fm.view = 'home'; return renderForeman(); }
    if (b.id === 'qrDone'){ fm.qr = null; fm.view = 'home'; return renderForeman(); }
    if (b.id === 'fmAddW'){ fm.ed = { id:null, name:'', stage:null, covers:[] }; fm.view = 'wedit'; return renderForeman(); }
    if (b.id === 'fmEditW'){ const w = fmW(fm.wid); if (!w) return; fm.ed = { id:w.id, orig:w.name, name:w.name, stage:w.stage, covers:(w.covers || []).slice(), busy: !!w.job }; fm.view = 'wedit'; return renderForeman(); }
    if (b.dataset.fmain){ fm.ed.stage = b.dataset.fmain; fm.ed.covers = fm.ed.covers.filter(x => x !== b.dataset.fmain); return renderForeman(); }
    if (b.dataset.fcov){ const c = fm.ed.covers, x = b.dataset.fcov; fm.ed.covers = c.includes(x) ? c.filter(y => y !== x) : c.concat(x); return renderForeman(); }
    if (b.id === 'fmSaveW'){ const e = fm.ed;
      if (!e.name.trim()){ e.err = 'Type the name first.'; return renderForeman(); }
      if (!e.stage){ e.err = 'Pick their main job.'; return renderForeman(); }
      b.disabled = true;
      const { error } = await db.rpc('ws_foreman_save_worker', { p_pin: fm.pin, p: { id: e.id, name: e.name.trim(), stage: e.stage, covers: e.covers } });
      if (error){ e.err = /ws_foreman_save_worker/.test(errMsg(error)) ? 'The owner needs to run update-12-all.sql in Supabase first.' : errMsg(error); return renderForeman(); }
      toast(e.id ? `${e.name.trim()} saved ✓` : `${e.name.trim()} added ✓ Tap their name when they arrive.`);
      await fmLoad(); fm.view = e.id ? 'worker' : 'home'; fm.ed = null; return renderForeman(); }
    if (b.dataset.fk){
      const k = b.dataset.fk;
      if (k === 'x') return fmClose();
      if (k === 'del'){ fm.entry = fm.entry.slice(0, -1); return renderForeman(); }
      if (fm.entry.length < 4) fm.entry += k;
      fm.err = ''; renderForeman();
      if (fm.entry.length === 4){
        fm.pin = fm.entry; fm.entry = '';
        const r = await fmLoad();
        if (r !== true){ fm.pin = null; fm.err = r === 'wrong' ? 'Wrong code. Try again.' : r === 'locked' ? 'Too many wrong codes. Wait 5 minutes.' : r === 'nocode' ? 'The owner has not set a manager code yet (Workers page in the app).' : ''; return renderForeman(); }
        fm.view = fm.then || 'home';
        if (fm.view === 'check') fm.miss = new Set(fm.data.tools.filter(t => t.missing).map(t => t.id));
        return renderForeman();
      }
      return;
    }
    if (b.id === 'fmCheck'){ await fmLoad(); fm.view = 'check'; fm.miss = new Set(fm.data.tools.filter(t => t.missing).map(t => t.id)); return renderForeman(); }
    if (b.dataset.fw){
      fm.wid = b.dataset.fw; fm.view = 'worker'; fm.pick = null; fm.showAll = false;
      const w = fmW(fm.wid);
      if (w && !w.in && !w.away){ const { error } = await db.rpc('ws_foreman_arrive', { p_pin: fm.pin, p_worker: w.id, p_in: true });
        if (error){ toast(errMsg(error)); } else { toast(`${w.name} is in ✓`); await fmLoad(); } }
      return renderForeman(); }
    if (b.id === 'fmArrive' || b.id === 'fmUnarrive'){
      b.disabled = true; const w = fmW(fm.wid);
      const { error } = await db.rpc('ws_foreman_arrive', { p_pin: fm.pin, p_worker: fm.wid, p_in: b.id === 'fmArrive' });
      if (error){ toast(errMsg(error)); b.disabled = false; return; }
      await fmLoad(); if (b.id === 'fmUnarrive'){ toast(`${w.name} unticked`); fm.view = 'home'; } return renderForeman(); }
    if (b.id === 'fmAllTools'){ fm.showAll = true; return renderForeman(); }
    if (b.id === 'fmDone'){ fm.view = 'home'; fm.pick = null; await fmLoad(); return renderForeman(); }
    if (b.dataset.ft){
      b.disabled = true;
      const { data, error } = await db.rpc('ws_foreman_tool', { p_pin: fm.pin, p_tool: b.dataset.ft, p_worker: fm.wid });
      if (error){ toast(errMsg(error)); b.disabled = false; return; }
      const t = fm.data.tools.find(x => x.id === b.dataset.ft);
      toast(data === 'back' ? `${t ? t.name : 'Tool'} returned ✓` : `${t ? t.name : 'Tool'} → ${fmW(fm.wid).name}`);
      await fmLoad(); return renderForeman();
    }
    if (b.dataset.fmat){ fm.pick = b.dataset.fmat; fm.qty = ''; return renderForeman(); }
    if (b.dataset.again){
      b.disabled = true; const m = fm.data.materials.find(x => x.id === b.dataset.again);
      const { error } = await db.rpc('ws_foreman_give', { p_pin: fm.pin, p_material: b.dataset.again, p_worker: fm.wid, p_qty: +b.dataset.q });
      if (error){ toast(errMsg(error)); b.disabled = false; return; }
      toast(`Given again: ${b.dataset.q} ${m ? m.unit + ' ' + m.name : ''}`);
      await fmLoad(); renderForeman();
      const t = v.querySelector(`[data-fmat="${b.dataset.again}"]`); if (t) t.closest('.mat-tile').classList.add('bump');
      return;
    }
    if (b.dataset.fq){ fm.qty = b.dataset.fq; return renderForeman(); }
    if (b.dataset.fn){ const k = b.dataset.fn;
      if (k === 'del') fm.qty = (fm.qty || '').slice(0, -1);
      else if (!(k === '.' && (fm.qty || '').includes('.')) && (fm.qty || '').length < 6) fm.qty = (fm.qty || '') + k;
      return renderForeman(); }
    if (b.id === 'fqCancel'){ fm.pick = null; return renderForeman(); }
    if (b.id === 'fqGive' || b.id === 'fqBack'){
      const q = parseFloat(fm.qty); if (!q || q <= 0){ toast('Tap how much first'); return; }
      b.disabled = true;
      const { error } = await db.rpc(b.id === 'fqGive' ? 'ws_foreman_give' : 'ws_foreman_return', { p_pin: fm.pin, p_material: fm.pick, p_worker: fm.wid, p_qty: q });
      if (error){ toast(errMsg(error)); b.disabled = false; return; }
      const m = fm.data.materials.find(x => x.id === fm.pick);
      toast(`${b.id === 'fqGive' ? 'Given' : 'Returned'}: ${q} ${m.unit} ${m.name}`);
      fm.pick = null; await fmLoad(); return renderForeman();
    }
    if (b.dataset.fc){ fm.miss.has(b.dataset.fc) ? fm.miss.delete(b.dataset.fc) : fm.miss.add(b.dataset.fc); return renderForeman(); }
    if (b.id === 'fmCheckDone'){
      b.disabled = true;
      const { data, error } = await db.rpc('ws_tool_check', { p_pin: fm.pin, p_list: [...fm.miss] });
      if (error){ b.disabled = false; toast(errMsg(error)); return; }
      fmClose();
      cheer(data ? `Saved. ${data} missing. The owner has been told.` : 'All tools are back. Thank you!');
    }
  }

  /* ---------- screens ---------- */
  function render(){
    if (!me && fm){ lastScreen = 'fm'; v.classList.remove('enter'); return renderForeman(); }
    const screen = !me ? 'names' : (job && job.task ? 'job:' + job.task.id + ':' + job.task.status : 'free');
    const fresh = screen !== lastScreen; lastScreen = screen;
    v.classList.toggle('enter', fresh);
    if (!me){
      const due = checkNeeded();
      v.innerHTML = `<div class="fm-row anim">${due ? `<button class="tc-banner due" id="tcOpen"><span>🔧</span><span><b>It's ${KT_CONFIG.toolCheckAt || '18:30'}. Manager: time for the tool check</b><small>Tap here before everyone goes home</small></span></button>` : ''}
        <button class="fm-btn" id="fmOpen"><span>🔑</span><b>Manager</b></button></div>
        <h1 class="anim hello-h">${hello()}, team! <span class="wave">👋</span></h1><p class="lead anim" style="--i:1">Find your name. Your job is right under it. Tap to see the details.</p>
        ${sound && navigator.userActivation && !navigator.userActivation.hasBeenActive ? '<p class="snd-hint anim">🔊 Tap anywhere once so the screen can call out new jobs.</p>' : ''}
        ${workers.length ? STAGES.map((s, gi) => { const ws = workers.filter(w => w.stage === s.id); return ws.length ? `<div class="st-group trade anim" style="--i:${gi + 2};${tc(s.id)}"><h4><span class="tr-ic">${trade(s.id)[1]}</span>${s.name}</h4><div class="names">${ws.map(w => { const j = w.job;
          const line = j ? `<small class="nj ${j.status === 'assigned' ? 'new' : ''}">${j.status === 'assigned' ? '<em>NEW</em>' : '▶'} ${esc(j.ref)} · ${esc(stageName(j.stage))}${j.with ? ' · with ' + esc(j.with) : ''}</small>` : w.job === null ? `<small class="nj free">Free${w.next ? ` · ${w.next} lined up` : ''}</small>` : '';
          return `<button class="name tn ${j && j.status === 'assigned' ? 'has-new' : ''}" data-who="${w.id}" style="${tc(w.stage)}"><span class="av">${esc(w.name.charAt(0))}</span><span class="nm">${esc(w.name)}${line}</span></button>`; }).join('')}</div></div>` : ''; }).join('')
          : '<div class="sw-card nowork anim" style="--i:2"><p class="big">No workers yet</p><p>The owner adds workers in the Kartech app.</p></div>'}`;
      return;
    }
    const t = job && job.task, o = job && job.order;
    const head = `<div class="st-head anim"><div><h1>Hello, ${esc(job ? job.worker.name : '')} <span class="wave">👋</span></h1><p class="lead">${job ? stageName(job.worker.stage) : ''}</p></div>
      <div class="st-out"><button class="btn line" id="stOut">Sign out</button><p class="idle" id="idleTxt"></p></div></div>`;
    if (!t){
      v.innerHTML = head + `<div class="sw-card nowork anim" style="--i:1"><div class="dots"><i></i><i></i><i></i></div><p class="big">No job right now</p><p>The owner can see you're free. Your next job will show here as soon as it's ready.</p></div>`;
      return;
    }
    const working = t.status === 'working';
    const card = `<div class="sw-card cur tcard anim" style="--i:1;${tc(t.stage)}">
        <span class="tcard-ic">${trade(t.stage)[1]}</span>
        <p class="k">Your current task</p>
        <p class="ref">${esc(o.ref)}</p>
        <p class="big">${o.qty} × ${esc(o.item)}</p>
        <p class="step">${stageName(t.stage)}${working ? ' · <span class="on">in progress</span>' : ''}</p>
        ${t.with ? `<p class="with">👥 Together with <b>${esc(t.with)}</b></p>` : ''}
        ${t.approved ? `<p class="approved">✓ <b>Customer approved this design</b> · ${new Date(t.approved).toLocaleDateString('en-GB', { weekday:'short', day:'numeric', month:'short' })}</p>` : ''}
        <div class="tags"><span class="tag u-${o.urgency}">${o.urgency === 'normal' ? 'Normal' : '● ' + URG_NAME[o.urgency] + ' priority'}</span><span class="tag due">◷ Due ${fmtDay(new Date(o.deadline + 'T17:00'))}</span><span class="tag">Then: ${job.after ? stageName(job.after) : 'Delivery'}</span></div>
        ${o.notes ? `<div class="note">📝 ${esc(o.notes)}</div>` : ''}
        ${pics.length ? `<div class="pics"><p class="k">📐 What to make · tap to see big</p><div class="pics-row">${pics.map((u, i) => `<button class="pic" data-pic="${i}"><img src="${esc(u)}" alt="Picture ${i + 1}"></button>`).join('')}</div></div>` : ''}
        ${mats.length ? `<div class="note mats-given"><b>📦 Materials given to you for this job</b><br>${mats.map(m => `${+(+m.qty).toFixed(2)} ${esc(m.unit)} ${esc(m.name)}`).join(' · ')}<br><small>Bring anything left over back to the store.</small></div>` : ''}
        ${t.problem_reason ? `<div class="note warn">⚠ You reported: <b>${esc(t.problem_reason)}</b>${t.problem_stopped ? ' · work stopped' : ''}.<br>${t.problem_ack ? '<b class="okay">✓ The owner has seen this and is on it.</b>' : t.problem_stopped ? "The owner's alarm is ringing. Please wait here." : 'The owner has been told.'}</div>` : ''}
        ${working ? `<button class="giant done" id="stDone">✓ I've finished</button>` : `<button class="giant go" id="stStart">▶ Start work</button>`}
      </div>`;
    const side = `<div class="sw-card nxt anim" style="--i:2"><p class="k">Next in line</p>
        ${job.next ? `<p class="ref">${esc(job.next.ref)}</p><p class="mid">${job.next.qty} × ${esc(job.next.item)}</p><p class="muted">${stageName(job.worker.stage)}</p>` : '<p class="muted">Nothing waiting after this one.</p>'}</div>`;
    const help = probReason ? `<div class="sw-card help anim"><p class="q">${esc(probReason)}: has your work stopped?</p><div class="stop2"><button class="yes" data-stop="1">Yes, I can't continue</button><button class="no" data-stop="0">No, I can keep going</button></div></div>`
      : probOpen ? `<div class="sw-card help anim"><p class="q">What's the problem?</p><div class="probs">${['Material missing','Machine problem','Need instructions','Something else'].map(r => `<button data-prob="${r}">${r}</button>`).join('')}</div></div>`
      : t.problem_reason ? '' : `<p class="needhelp anim" style="--i:3">Need help? <button id="stProb">Report a problem</button></p>`;
    v.innerHTML = head + `<div class="sw-grid">${card}${side}</div>` + help;
  }

  function cheer(text){
    const c = $('#cheer'); $('#cheerTxt').textContent = text;
    c.querySelectorAll('.cf').forEach(x => x.remove());
    const cols = ['#8ABFB2','#F97316','#3B82F6','#EC4899','#EAB308','#14B8A6','#fff'];
    for (let i = 0; i < 36; i++){ const f = document.createElement('i'); f.className = 'cf';
      f.style.cssText = `left:${Math.random() * 100}%;background:${cols[i % cols.length]};animation-delay:${Math.random() * .35}s;animation-duration:${1.1 + Math.random() * .7}s;transform:rotate(${Math.random() * 360}deg)`; c.appendChild(f); }
    c.classList.remove('hidden'); c.classList.remove('go'); void c.offsetWidth; c.classList.add('go');
    setTimeout(() => c.classList.add('hidden'), 1700);
  }

  async function refreshJob(){
    if (!token) return;
    const { data, error } = await db.rpc('ws_my_job', { p_token: token });
    if (error){ if (/Signed out/i.test(error.message)) return signOut(); $('#live').classList.add('off'); return; }
    $('#live').classList.remove('off');
    const mr = data && data.task ? await db.rpc('ws_my_materials', { p_token: token }) : { data: [] };
    const before = JSON.stringify([job, mats, pics]); job = data; mats = mr.error ? [] : (mr.data || []);
    await loadPics();
    if (JSON.stringify([job, mats, pics]) !== before && !probOpen && !probReason) render();
  }

  /* ---------- pictures of what to make (from the owner) ---------- */
  let pics = [], picsFor = null, picsAt = 0;
  async function loadPics(){
    const key = job && job.order ? job.order.ref : null;
    if (!key){ pics = []; picsFor = null; return; }
    if (key === picsFor && Date.now() - picsAt < 50 * 60000) return;   // signed links last an hour
    let { data, error } = await db.rpc('ws_job_pics', { p_token: token });
    if (error && /ws_job_pics/.test(errMsg(error))){ const old = await db.rpc('ws_job_pictures', { p_token: token }); error = old.error; data = (old.data || []).map(p => ({ b:'kartech-photos', p })); }
    if (error || !data || !data.length || !db.storage){ pics = []; picsFor = key; picsAt = Date.now(); return; }
    const out = [];
    for (const bk of [...new Set(data.map(x => x.b))]){ const list = data.filter(x => x.b === bk);
      const r = await db.storage.from(bk).createSignedUrls(list.map(x => x.p), 3600); (r.data || []).forEach(u => u && u.signedUrl && out.push(u.signedUrl)); }
    pics = out; picsFor = key; picsAt = Date.now();
  }
  function picView(i){
    const o = document.createElement('div'); o.className = 'pic-full';
    o.innerHTML = `<img src="${esc(pics[i])}" alt="Picture ${i + 1}"><button class="btn" aria-label="Close">✕ Close</button>${pics.length > 1 ? `<p>${i + 1} of ${pics.length} · tap the picture for the next one</p>` : ''}`;
    o.addEventListener('click', e => { resetIdle(); if (e.target.closest('button')) return o.remove(); if (pics.length > 1){ o.remove(); picView((i + 1) % pics.length); } });
    document.body.appendChild(o);
  }

  function shrinkPic(file){
    return new Promise((ok, no) => { const img = new Image(), url = URL.createObjectURL(file);
      img.onload = () => { const k = Math.min(1, 1600 / Math.max(img.width, img.height)); const c = document.createElement('canvas');
        c.width = Math.round(img.width * k); c.height = Math.round(img.height * k); c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url); c.toBlob(b => b ? ok(b) : no(new Error('Could not read the picture')), 'image/jpeg', .82); };
      img.onerror = () => { URL.revokeObjectURL(url); no(new Error('That file is not a picture')); }; img.src = url; });
  }

  let qrLib = null;
  function loadQR(){ return qrLib || (qrLib = new Promise((ok, no) => { if (window.qrcode) return ok(window.qrcode);
    const sc = document.createElement('script'); sc.src = 'https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js';
    sc.onload = () => ok(window.qrcode); sc.onerror = () => { qrLib = null; no(new Error('qr')); }; document.head.appendChild(sc); })); }

  /* ---------- idle sign-out ---------- */
  function resetIdle(){
    if (!me) return;
    idleLeft = KT_CONFIG.stationIdleSeconds; clearInterval(idleT);
    idleT = setInterval(() => {
      idleLeft--; const el = $('#idleTxt'); if (el) el.textContent = idleLeft <= 15 ? `Signing out in ${idleLeft}s` : '';
      if (idleLeft <= 0) signOut();
    }, 1000);
  }
  async function signOut(){
    const tk = token; me = null; token = null; job = null; mats = []; pinFor = null; pin = ''; probOpen = false; probReason = null;
    clearInterval(idleT); clearInterval(pollT);
    if (tk) db.rpc('ws_logout', { p_token: tk });
    await loadNames();
  }

  async function call(fn, extra){
    if (sending) return false; sending = true;
    const { error } = await db.rpc(fn, Object.assign({ p_token: token }, extra || {}));
    sending = false;
    if (error){ if (/Signed out/i.test(error.message)) { toast('Signed out. Please sign in again.'); signOut(); } else toast(errMsg(error)); return false; }
    await refreshJob(); render(); return true;
  }

  /* ---------- taps ---------- */
  v.addEventListener('click', async e => {
    resetIdle();
    const b = e.target.closest('button'); if (!b) return;
    if (b.id === 'retry') return loadNames();
    if (fm) return fmClick(b);
    if (b.dataset.pic) return picView(+b.dataset.pic);
    if (b.id === 'fmOpen' || b.id === 'tcOpen'){ fm = { view:'pin', entry:'', then: b.id === 'tcOpen' ? 'check' : 'home' }; fmIdle(); return render(); }
    if (b.dataset.who){
      b.disabled = true;
      const { data, error } = await db.rpc('ws_tap_in', { p_worker: b.dataset.who });
      if (error){ b.disabled = false; toast(errMsg(error)); return; }
      token = data; me = b.dataset.who;
      await refreshJob(); render(); resetIdle();
      pollT = setInterval(refreshJob, 8000);
      return;
    }
    if (b.id === 'stOut') return signOut();
    if (b.id === 'stStart'){ b.disabled = true; if (await call('ws_start')) toast('Started. Good work!'); return; }
    if (b.id === 'stDone'){
      if (b.dataset.sure !== '1'){ b.dataset.sure = '1'; b.textContent = 'Tap again to confirm'; b.classList.add('sure'); return; }
      b.disabled = true; probOpen = false; probReason = null;
      const nm = job ? job.worker.name : '';
      if (await call('ws_finish')){ cheer(`Well done, ${nm}!`); toast(job && job.task ? `Your next job is ${job.order.ref}.` : 'No job waiting. The owner can see you are free.'); }
      return;
    }
    if (b.id === 'stProb'){ probOpen = true; render(); return; }
    if (b.dataset.prob){ probReason = b.dataset.prob; render(); return; }
    if (b.dataset.stop && probReason){
      const stopped = b.dataset.stop === '1', reason = probReason; probOpen = false; probReason = null;
      if (await call('ws_report', { p_reason: reason, p_stopped: stopped })) toast(stopped ? "The owner's alarm is ringing." : 'The owner has been told.');
    }
  });

  boot();
})();
