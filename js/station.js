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
    $('#setView').classList.add('hidden'); $('#live').classList.remove('hidden');
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
    const { data, error } = await db.rpc('ws_station_workers');
    if (error){ v.innerHTML = `<h1>Can't reach the system</h1><p class="lead">${esc(errMsg(error))}</p><button class="giant done" id="retry">Try again</button>`; return; }
    workers = data; await loadTools(); render();
  }

  /* ---------- clock ---------- */
  function tickClock(){ const d = new Date();
    $('#clk').innerHTML = d.toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' }).replace(':', '<i>:</i>');
    $('#clkDate').textContent = d.toLocaleDateString('en-GB', { weekday:'short', day:'numeric', month:'short', year:'numeric' }); }
  tickClock(); setInterval(tickClock, 10000);
  let lastScreen = '';

  /* ---------- FOREMAN page (behind the foreman code) ---------- */
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
      v.innerHTML = `<div class="fm-pin anim"><h1>Foreman</h1><p class="lead">Enter the foreman code</p>
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
      v.innerHTML = head('Foreman', 'When a worker walks in, tap their name. Their tools pop up. Tick what they take.') + `
        <button class="tc-banner anim ${checkNeeded() ? 'due' : ''}" id="fmCheck" style="--i:1"><span>🔧</span><span><b>${d.done_today ? 'Tool check done for today ✓' : 'Evening tool check'}</b><small>${out.length ? out.length + ' tool' + (out.length > 1 ? 's' : '') + ' out right now' : 'All tools are in'}</small></span></button>
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
        <div class="in-strip anim">${w.in ? `<span class="in-ok">✓ In today${w.arrived_at ? ' since ' + fmTime(w.arrived_at) : ''}</span><button class="link-sm" id="fmUnarrive">Ticked by mistake? Undo</button>` : `<span>Not in yet</span><button class="btn" id="fmArrive">Tick ${esc(w.name)} in</button>`}</div>
        <div class="st-group anim" style="--i:1"><h4>${esc(stageName(w.stage))} tools · tick what ${esc(w.name)} takes</h4>
          <div class="tc-grid">${mine.map(tile).join('') || `<p class="muted">No tools set for ${esc(stageName(w.stage))} yet. The owner sets this in the app (Stock → edit a tool → "Used by").</p>`}</div>
          ${others.length ? (fm.showAll ? `<h4 style="margin-top:16px">Other tools</h4><div class="tc-grid">${others.map(tile).join('')}</div>` : `<button class="link-sm" id="fmAllTools" style="margin-top:12px">+ Show other tools (${others.length})</button>`) : ''}</div>
        <div class="st-group anim" style="--i:2"><h4>Materials · tap what he takes</h4><div class="tc-grid">${mats.map(m => { const td = w.today.find(x => x.material_id === m.id); const nf = x => +(+x).toFixed(2);
          return `<div class="mat-tile ${td ? 'has' : ''}"><button class="tc mat" data-fmat="${m.id}"><span class="tc-ic">📦</span><span><b>${esc(m.name)}</b><small>${td ? `<em>${nf(td.qty)} ${esc(m.unit)} taken today${td.times > 1 ? ' (' + td.times + ' times)' : ''}</em>` : ''}${nf(m.in_store)} ${esc(m.unit)} in store</small></span></button>
            ${td && td.last ? `<button class="again" data-again="${m.id}" data-q="${nf(td.last)}">+ ${nf(td.last)} again</button>` : ''}</div>`; }).join('') || '<p class="muted">No materials for this step yet.</p>'}</div></div>
        <button class="giant go anim" id="fmDone" style="--i:3">✓ Done</button>
        ${fm.pick ? qtyPanel(w) : ''}`;
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
    if (b.id === 'fmBack'){ fm.view = 'home'; fm.pick = null; await fmLoad(); return renderForeman(); }
    if (b.dataset.fk){
      const k = b.dataset.fk;
      if (k === 'x') return fmClose();
      if (k === 'del'){ fm.entry = fm.entry.slice(0, -1); return renderForeman(); }
      if (fm.entry.length < 4) fm.entry += k;
      fm.err = ''; renderForeman();
      if (fm.entry.length === 4){
        fm.pin = fm.entry; fm.entry = '';
        const r = await fmLoad();
        if (r !== true){ fm.pin = null; fm.err = r === 'wrong' ? 'Wrong code. Try again.' : r === 'locked' ? 'Too many wrong codes. Wait 5 minutes.' : r === 'nocode' ? 'The owner has not set a foreman code yet (Workers page in the app).' : ''; return renderForeman(); }
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
      v.innerHTML = `<div class="fm-row anim">${due ? `<button class="tc-banner due" id="tcOpen"><span>🔧</span><span><b>It's ${KT_CONFIG.toolCheckAt || '18:30'}. Foreman: time for the tool check</b><small>Tap here before everyone goes home</small></span></button>` : ''}
        <button class="fm-btn" id="fmOpen"><span>🔑</span><b>Foreman</b></button></div>
        <h1 class="anim">Who's working?</h1><p class="lead anim" style="--i:1">Tap your name to see your job.</p>
        ${workers.length ? STAGES.map((s, gi) => { const ws = workers.filter(w => w.stage === s.id); return ws.length ? `<div class="st-group anim" style="--i:${gi + 2}"><h4>${s.name}</h4><div class="names">${ws.map(w => `<button class="name" data-who="${w.id}"><span class="av">${esc(w.name.charAt(0))}</span>${esc(w.name)}</button>`).join('')}</div></div>` : ''; }).join('')
          : '<div class="sw-card nowork anim" style="--i:2"><p class="big">No workers yet</p><p>The owner adds workers in the Kartech app.</p></div>'}`;
      return;
    }
    const t = job && job.task, o = job && job.order;
    const head = `<div class="st-head anim"><div><h1>Hello, ${esc(job ? job.worker.name : '')}</h1><p class="lead">${job ? stageName(job.worker.stage) : ''}</p></div>
      <div class="st-out"><button class="btn line" id="stOut">Sign out</button><p class="idle" id="idleTxt"></p></div></div>`;
    if (!t){
      v.innerHTML = head + `<div class="sw-card nowork anim" style="--i:1"><div class="dots"><i></i><i></i><i></i></div><p class="big">No job right now</p><p>The owner can see you're free. Your next job will show here as soon as it's ready.</p></div>`;
      return;
    }
    const working = t.status === 'working';
    const card = `<div class="sw-card cur anim" style="--i:1">
        <p class="k">Your current task</p>
        <p class="ref">${esc(o.ref)}</p>
        <p class="big">${o.qty} × ${esc(o.item)}</p>
        <p class="step">${stageName(t.stage)}${working ? ' · <span class="on">in progress</span>' : ''}</p>
        ${t.with ? `<p class="with">👥 Together with <b>${esc(t.with)}</b></p>` : ''}
        <div class="tags"><span class="tag u-${o.urgency}">${o.urgency === 'normal' ? 'Normal' : '● ' + URG_NAME[o.urgency] + ' priority'}</span><span class="tag due">◷ Due ${fmtDay(new Date(o.deadline + 'T17:00'))}</span><span class="tag">Then: ${job.after ? stageName(job.after) : 'Delivery'}</span></div>
        ${o.notes ? `<div class="note">📝 ${esc(o.notes)}</div>` : ''}
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
    c.classList.remove('hidden'); c.classList.remove('go'); void c.offsetWidth; c.classList.add('go');
    setTimeout(() => c.classList.add('hidden'), 1700);
  }

  async function refreshJob(){
    if (!token) return;
    const { data, error } = await db.rpc('ws_my_job', { p_token: token });
    if (error){ if (/Signed out/i.test(error.message)) return signOut(); $('#live').classList.add('off'); return; }
    $('#live').classList.remove('off');
    const mr = data && data.task ? await db.rpc('ws_my_materials', { p_token: token }) : { data: [] };
    const before = JSON.stringify([job, mats]); job = data; mats = mr.error ? [] : (mr.data || []);
    if (JSON.stringify([job, mats]) !== before && !probOpen && !probReason) render();
  }

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
