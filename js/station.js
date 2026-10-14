/* =====================================================================
   KARTECH WORKSHOP — shared workshop computer
   1. Signed in once with the workshop account (stays signed in).
   2. A worker taps their name, enters their PIN, and sees only their own job.
   3. Signs the worker out after a minute with no taps.
   ===================================================================== */
(function(){
  const v = $('#stView');
  let workers = [], pinFor = null, pin = '', token = null, me = null, job = null;
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
    workers = data; render();
  }

  /* ---------- screens ---------- */
  function render(){
    if (!me && !pinFor){
      v.innerHTML = `<h1>Who's working?</h1><p class="lead">Tap your name.</p>
        ${workers.length ? STAGES.map(s => { const ws = workers.filter(w => w.stage === s.id); return ws.length ? `<div class="st-group"><h4>${s.name.toUpperCase()}</h4><div class="names">${ws.map(w => `<button class="name" data-who="${w.id}">${esc(w.name)}</button>`).join('')}</div></div>` : ''; }).join('')
          : '<div class="nowork"><p class="big">No workers yet</p><p style="color:#B9B8B2;font-size:17px">The owner adds workers on the Workers page.</p></div>'}`;
      return;
    }
    if (pinFor && !me){
      const w = workers.find(x => x.id === pinFor);
      v.innerHTML = `<div class="pinbox"><h1>Hi ${esc(w ? w.name : '')}</h1><p class="lead">Enter your PIN</p>
        <div class="pindots">${[0,1,2,3].map(i => `<i class="${i < pin.length ? 'on' : ''}"></i>`).join('')}</div>
        <div class="pad">${[1,2,3,4,5,6,7,8,9].map(n => `<button data-k="${n}">${n}</button>`).join('')}<button data-k="back" style="font-size:18px">Back</button><button data-k="0">0</button><button data-k="del" style="font-size:18px">⌫</button></div>
        <p class="err" id="pinErr"></p></div>`;
      return;
    }
    const t = job && job.task, o = job && job.order;
    let body;
    if (!t){
      body = `<div class="nowork"><p class="big">No job right now</p><p style="color:#B9B8B2;font-size:17px">The owner can see you're free. Your next job will show here as soon as it's ready.</p></div>`;
    } else {
      body = `<div class="task">
        <p class="k">${stageName(t.stage).toUpperCase()} · ${esc(o.ref)}</p>
        <p class="big">${o.qty} × ${esc(o.item)}</p>
        ${o.notes ? `<div class="note" style="font-size:19px">📝 ${esc(o.notes)}</div>` : ''}
        <div class="meta" style="margin-top:12px"><span><span class="pill p-${o.urgency}">${URG_NAME[o.urgency]}</span></span><span>Due <b>${fmtDay(new Date(o.deadline + 'T17:00'))}</b></span><span>Then goes to: <b>${job.after ? stageName(job.after) : 'Delivery'}</b></span></div>
        ${t.problem_reason ? `<div class="note" style="border-color:var(--red);color:var(--red)">⚠ You reported: <b>${esc(t.problem_reason)}</b>${t.problem_stopped ? ' · work stopped' : ''}.<br>${t.problem_ack ? '<b style="color:var(--green)">✓ The owner has seen this and is on it.</b>' : t.problem_stopped ? "The owner's alarm is ringing. Please wait here." : 'The owner has been told.'}</div>` : ''}
      </div>
      ${t.status === 'assigned' ? `<button class="giant go" id="stStart">START THIS JOB</button>` : `<button class="giant done" id="stDone">✓ I'VE FINISHED</button>`}
      ${probReason ? `<p style="margin-top:18px;font-size:20px;font-weight:600">${esc(probReason)}: has your work stopped?</p><div class="stop2"><button class="yes" data-stop="1">YES, I CAN'T CONTINUE</button><button class="no" data-stop="0">No, I can keep going for now</button></div>`
        : probOpen ? `<div class="probs">${['Material missing','Machine problem','Need instructions','Something else'].map(r => `<button data-prob="${r}">${r}</button>`).join('')}</div>`
        : t.problem_reason ? '' : `<button class="giant prob" id="stProb">Report a problem</button>`}`;
    }
    v.innerHTML = `<div class="st-head"><div><h1>${esc(job ? job.worker.name : '')}</h1><p class="lead" style="margin:0">${job ? stageName(job.worker.stage) : ''}</p></div><div style="text-align:right"><button class="btn line" id="stOut" style="color:var(--paper);border-color:#555">Sign out</button><p class="idle" id="idleTxt"></p></div></div>
      ${body}
      ${t && job.next ? `<p class="upnext">Up next in ${stageName(job.worker.stage)}: <b>${esc(job.next.ref)} · ${job.next.qty} × ${esc(job.next.item)}</b></p>` : ''}`;
  }

  async function refreshJob(){
    if (!token) return;
    const { data, error } = await db.rpc('ws_my_job', { p_token: token });
    if (error){ if (/Signed out/i.test(error.message)) return signOut(); $('#live').classList.add('off'); return; }
    $('#live').classList.remove('off');
    const before = JSON.stringify(job); job = data;
    if (JSON.stringify(job) !== before && !probOpen && !probReason) render();
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
    const tk = token; me = null; token = null; job = null; pinFor = null; pin = ''; probOpen = false; probReason = null;
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
    if (b.dataset.who){ pinFor = b.dataset.who; pin = ''; render(); return; }
    if (b.dataset.k){
      const k = b.dataset.k;
      if (k === 'back'){ pinFor = null; pin = ''; render(); return; }
      if (k === 'del'){ pin = pin.slice(0, -1); render(); return; }
      if (pin.length < 4) pin += k;
      render();
      if (pin.length === 4){
        const { data, error } = await db.rpc('ws_login', { p_worker: pinFor, p_pin: pin });
        if (error){ pin = ''; render(); $('#pinErr').textContent = errMsg(error) + (/Wrong PIN/.test(error.message) ? '. Try again.' : ''); return; }
        token = data; me = pinFor; pinFor = null; pin = '';
        await refreshJob(); render(); resetIdle();
        pollT = setInterval(refreshJob, 8000);
      }
      return;
    }
    if (b.id === 'stOut') return signOut();
    if (b.id === 'stStart'){ b.disabled = true; if (await call('ws_start')) toast('Started. Good work!'); return; }
    if (b.id === 'stDone'){
      if (b.dataset.sure !== '1'){ b.dataset.sure = '1'; b.textContent = 'TAP AGAIN TO CONFIRM'; b.style.background = 'var(--green)'; b.style.color = '#fff'; return; }
      b.disabled = true; probOpen = false; probReason = null;
      if (await call('ws_finish')) toast(job && job.task ? `Done! Your next job is ${job.order.ref}.` : 'Done! No job waiting. The owner can see you are free.');
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
