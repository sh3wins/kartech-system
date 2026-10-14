/* =====================================================================
   KARTECH WORKSHOP — owner app (phone + computer)
   Reads from the Kartech Supabase database. Every change goes through a
   database function, so the rules (queues, who gets the next job) live in
   one place: supabase/setup-workshop.sql
   ===================================================================== */
(function(){
  const POLL_MS = 8000;
  let S = { workers:[], orders:[], tasks:[], log:[] };
  let tab = 'today', loaded = false, busy = false;

  const W = id => S.workers.find(w => w.id === id);
  const O = id => S.orders.find(o => o.id === id);
  const T = id => S.tasks.find(t => t.id === id);
  const queue = stage => S.tasks.filter(t => t.stage === stage && t.status === 'queued').sort((a,b) => a.rank - b.rank);
  const show = id => ['loginView','setupView','owner'].forEach(v => $('#' + v).classList.toggle('hidden', v !== id));

  function orderProgress(o){
    const ts = S.tasks.filter(t => t.order === o.id);
    const cur = ts.filter(t => t.status !== 'done').sort((a,b) => a.step - b.step)[0];
    return { done: ts.filter(t => t.status === 'done').length, total: ts.length, current: cur, finished: ts.length > 0 && !cur };
  }
  function workerStatus(w){
    if (!w.active) return ['normal', 'Switched off'];
    if (!w.task) return ['waiting', 'Waiting for work'];
    const t = T(w.task);
    if (!t) return ['notstarted', 'Not started'];
    if (t.problem) return ['attention', 'Needs attention'];
    if (t.status === 'working') return ['working', 'Working'];
    return ['notstarted', 'Not started'];
  }

  /* ---------- sign in ---------- */
  if (!db){ show('setupView'); return; }
  async function start(){
    const { data: { session } } = await db.auth.getSession();
    if (!session){ show('loginView'); return; }
    const { data: ok } = await db.rpc('is_admin');
    if (!ok){
      await db.auth.signOut(); show('loginView');
      $('#lErr').textContent = "This login isn't a Kartech owner account.";
      return;
    }
    $('#who').textContent = session.user.email;
    ['who','outBtn','live','fab'].forEach(id => $('#' + id).classList.remove('hidden'));
    show('owner');
    await load();
  }
  $('#loginForm').addEventListener('submit', async e => {
    e.preventDefault();
    $('#lErr').textContent = ''; $('#lBtn').disabled = true; $('#lBtn').textContent = 'Signing in…';
    const { error } = await db.auth.signInWithPassword({ email: $('#lEmail').value.trim(), password: $('#lPass').value });
    $('#lBtn').disabled = false; $('#lBtn').textContent = 'Sign in';
    if (error){ $('#lErr').textContent = 'Wrong email or password.'; return; }
    start();
  });
  $('#outBtn').onclick = async () => { await db.auth.signOut(); location.reload(); };

  /* ---------- load everything ---------- */
  async function load(){
    if (busy) return; busy = true;
    try {
      const since = new Date(Date.now() - 30 * 864e5).toISOString();
      const [w, o, l] = await Promise.all([
        db.from('ws_workers').select('id,name,stage,active,task_id,locked_until,created_at').order('name'),
        db.from('ws_orders').select('*').or('delivered_at.is.null,delivered_at.gt.' + since).order('created_at', { ascending:false }).limit(400),
        db.from('ws_log').select('*').order('id', { ascending:false }).limit(30)
      ]);
      if (w.error || o.error || l.error) throw (w.error || o.error || l.error);
      const ids = o.data.map(x => x.id);
      const t = ids.length ? await db.from('ws_tasks').select('*').in('order_id', ids) : { data: [] };
      if (t.error) throw t.error;
      S.workers = w.data.map(x => ({ id:x.id, name:x.name, stage:x.stage, active:x.active, task:x.task_id, locked: x.locked_until && new Date(x.locked_until) > new Date() }));
      S.orders = o.data.map(x => ({ id:x.id, ref:x.ref, customer:x.customer, item:x.item, qty:x.qty, deadline:new Date(x.deadline + 'T17:00'), urgency:x.urgency, notes:x.notes, stages:x.stages, delivered: !!x.delivered_at }));
      S.tasks = t.data.map(x => ({ id:x.id, order:x.order_id, step:x.step, stage:x.stage, status:x.status, worker:x.worker_id, rank:x.rank,
        problem: x.problem_at ? { reason:x.problem_reason, at:new Date(x.problem_at).getTime(), stopped:!!x.problem_stopped, ack: !!x.problem_ack_at } : null }));
      S.log = l.data.map(x => ({ text:x.text, kind:x.kind, at:new Date(x.at).getTime(), order:x.order_id }));
      loaded = true;
      $('#live').classList.remove('off'); $('#live').lastChild.textContent = ' Live';
      if (!document.querySelector('.scrim')) render();
      alarmRender();
    } catch(e){
      $('#live').classList.add('off'); $('#live').lastChild.textContent = ' Offline';
      if (!loaded) $('#view').innerHTML = `<p class="empty">Couldn't load. ${esc(errMsg(e))}</p>`;
    } finally { busy = false; }
  }
  setInterval(() => { if (!$('#owner').classList.contains('hidden') && document.visibilityState === 'visible') load(); }, POLL_MS);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && loaded) load(); });

  async function act(fn, args, okMsg){
    const { error } = await db.rpc(fn, args);
    if (error){ toast(errMsg(error)); return false; }
    if (okMsg) toast(okMsg);
    await load();
    return true;
  }

  /* ---------- views ---------- */
  document.querySelectorAll('.tabs [data-tab]').forEach(b => b.addEventListener('click', () => { tab = b.dataset.tab; render(); window.scrollTo(0,0); load(); }));
  $('#newOrderBtn').onclick = $('#fab').onclick = () => newOrderModal();

  function attention(){
    const items = [];
    S.tasks.filter(t => t.problem && T(t.id)).forEach(t => { const w = W(t.worker), o = O(t.order); if (!o) return;
      items.push({ lvl:'red', title:`${t.problem.stopped ? 'WORK STOPPED' : 'Problem'}: ${t.problem.reason}${t.problem.stopped && t.problem.ack ? " (you're on it)" : ''}`,
        sub:`${w ? w.name : 'Worker'} · ${o.ref} · ${stageName(t.stage)} · ${ago(t.problem.at)}`, act:`<button class="btn sm" data-solve="${t.id}">Mark solved</button>` }); });
    S.orders.filter(o => !o.delivered && !orderProgress(o).finished && isLate(o.deadline)).forEach(o => items.push({ lvl:'red', title:`${o.ref} is past its deadline`, sub:`${o.qty} × ${o.item} · ${o.customer}`, act:`<button class="btn sm line" data-open="${o.id}">Open</button>` }));
    S.workers.filter(w => w.active && !w.task).forEach(w => items.push({ lvl:'amber', title:`${w.name} is waiting for work`, sub:`${stageName(w.stage)} · nothing in the line`, act:`<button class="btn sm line" data-tabgo="workshop">See workshop</button>` }));
    S.workers.filter(w => w.locked).forEach(w => items.push({ lvl:'amber', title:`${w.name} is locked out`, sub:'Too many wrong PINs. Unlocks by itself in 5 minutes, or give a new PIN.', act:`<button class="btn sm line" data-editw="${w.id}">New PIN</button>` }));
    S.orders.filter(o => !o.delivered && o.urgency === 'urgent' && !orderProgress(o).finished && !isLate(o.deadline)).forEach(o => { const c = orderProgress(o).current;
      items.push({ lvl:'amber', title:`Urgent: ${o.ref} due ${fmtDay(o.deadline).toLowerCase()}`, sub:`${o.qty} × ${o.item}${c ? ' · now at ' + stageName(c.stage) : ''}`, act:`<button class="btn sm line" data-open="${o.id}">Open</button>` }); });
    S.orders.filter(o => !o.delivered && orderProgress(o).finished).forEach(o => items.push({ lvl:'green', title:`${o.ref} is loaded and ready`, sub:`${o.customer} · confirm when it leaves`, act:`<button class="btn sm" data-deliver="${o.id}">Mark delivered</button>` }));
    return items;
  }

  function viewToday(){
    const att = attention();
    const active = S.workers.filter(w => w.active);
    const working = active.filter(w => workerStatus(w)[0] === 'working').length;
    const waiting = active.filter(w => !w.task).length;
    const probs = S.tasks.filter(t => t.problem).length;
    const late = S.orders.filter(o => !o.delivered && !orderProgress(o).finished && isLate(o.deadline)).length;
    const h = new Date().getHours();
    const firstRun = !S.workers.length ? `<div class="list" style="margin-bottom:18px"><div class="item"><span class="dot amber"></span><div class="grow"><div class="t">Start here: add your workers</div><div class="s">Give each one a 4-digit PIN. Then add your first order.</div></div><button class="btn sm" data-tabgo="workers">Add workers</button></div></div>` : '';
    return `
      <h2>Good ${h < 12 ? 'morning' : h < 17 ? 'afternoon' : 'evening'}</h2>
      <p class="sub">What needs you right now. Everything else is running on its own.</p>
      ${firstRun}
      <div class="cards">
        <button class="stat ${probs ? 'alert' : ''}" data-tabgo="workshop"><b>${probs}</b><span>Problems reported</span></button>
        <button class="stat ${waiting ? 'warn' : ''}" data-tabgo="workshop"><b>${waiting}</b><span>Waiting for work</span></button>
        <button class="stat ${late ? 'alert' : ''}" data-tabgo="orders"><b>${late}</b><span>Orders past deadline</span></button>
        <button class="stat" data-tabgo="workshop"><b>${working}/${active.length}</b><span>Workers busy</span></button>
      </div>
      <p class="section-title">Needs your attention</p>
      <div class="list">${att.length ? att.map(a => `
        <div class="item"><span class="dot ${a.lvl}"></span><div class="grow"><div class="t">${esc(a.title)}</div><div class="s">${esc(a.sub)}</div></div>${a.act}</div>`).join('') : '<p class="empty">Nothing needs you. The workshop is running. ✓</p>'}</div>
      <p class="section-title">Latest from the workshop</p>
      <div class="list feed">${S.log.length ? S.log.slice(0, 12).map(l => `
        <div class="item"><span class="dot ${l.kind === 'alert' ? 'red' : l.kind === 'warn' ? 'amber' : l.kind === 'good' ? 'green' : 'grey'}"></span><div class="grow">${esc(l.text)}</div><span class="when">${ago(l.at)}</span></div>`).join('') : '<p class="empty">Nothing yet.</p>'}</div>`;
  }

  function pipe(o){
    const ts = S.tasks.filter(t => t.order === o.id);
    return `<div class="pipe">${STAGES.map(s => {
      const t = ts.find(x => x.stage === s.id);
      const cls = !t ? 'skip' : t.status === 'done' ? 'done' : (t.status === 'working' || t.status === 'assigned') ? 'now' : '';
      return `<div class="seg ${cls}"><i></i><em>${!t ? 'not needed' : s.short}</em></div>`;
    }).join('')}</div>`;
  }

  function viewOrders(){
    const active = S.orders.filter(o => !o.delivered).sort((a,b) => URG[a.urgency] - URG[b.urgency] || a.deadline - b.deadline);
    const delivered = S.orders.filter(o => o.delivered);
    const row = o => { const p = orderProgress(o); const late = !p.finished && isLate(o.deadline);
      return `<button class="order" data-open="${o.id}">
        <div><div class="ref">${o.ref} <span class="pill p-${o.urgency}">${URG_NAME[o.urgency]}</span></div><div style="color:var(--muted);font-size:13px">${o.qty} × ${esc(o.item)} · ${esc(o.customer)}</div></div>
        ${pipe(o)}
        <div class="due ${late && !o.delivered ? 'late' : ''}">${o.delivered ? 'Delivered' : p.finished ? '<span class="pill p-done">Ready</span>' : 'Due ' + fmtDay(o.deadline)}</div>
      </button>`; };
    return `
      <h2>Orders</h2>
      <p class="sub">Most urgent first. Tap an order to see who's on it.</p>
      <div class="list">${active.length ? active.map(row).join('') : '<p class="empty">No open orders. Tap <b>+ New order</b> to add one.</p>'}</div>
      ${delivered.length ? `<p class="section-title">Delivered (last 30 days)</p><div class="list">${delivered.map(row).join('')}</div>` : ''}`;
  }

  function viewWorkshop(){
    return `
      <h2>Workshop</h2>
      <p class="sub">Each step has its own line of jobs. When someone finishes, they get the top job automatically. Use ▲▼ to change the order.</p>
      <div class="board">${STAGES.map(s => {
        const ws = S.workers.filter(w => w.active && w.stage === s.id);
        const q = queue(s.id);
        return `<div class="col">
          <h3>${s.name}</h3><p class="s">${ws.length} worker${ws.length === 1 ? '' : 's'} · ${q.length} waiting</p>
          ${ws.map(w => { const [k, label] = workerStatus(w); const t = w.task && T(w.task); const o = t && O(t.order);
            return `<div class="wk"><div class="n">${esc(w.name)} <span class="pill p-${k}">${label}</span></div>
              <div class="c">${o ? `${o.ref} · ${o.qty} × ${esc(o.item)}${t.problem ? `<br><b style="color:var(--red)">⚠ ${esc(t.problem.reason)}</b> <button class="btn sm" style="margin-top:6px" data-solve="${t.id}">Mark solved</button>` : ''}` : 'Free. Will get the next job that arrives.'}</div></div>`; }).join('') || '<p class="s" style="color:var(--muted);font-size:13px">No workers in this step. Add one in Workers.</p>'}
          <p class="q-label">UP NEXT</p>
          ${q.length ? q.map((t, i) => { const o = O(t.order); if (!o) return ''; return `<div class="q">
            <span class="num">${i + 1}</span>
            <div class="grow"><b>${o.ref} <span class="pill p-${o.urgency}">${URG_NAME[o.urgency]}</span></b>${o.qty} × ${esc(o.item)} · due ${fmtDay(o.deadline).toLowerCase()}</div>
            <button class="mini" data-up="${t.id}" ${i === 0 ? 'disabled' : ''} aria-label="Move up">▲</button>
            <button class="mini" data-down="${t.id}" ${i === q.length - 1 ? 'disabled' : ''} aria-label="Move down">▼</button>
          </div>`; }).join('') : '<p class="s" style="color:var(--muted);font-size:13px">Nothing waiting.</p>'}
        </div>`; }).join('')}</div>`;
  }

  function viewWorkers(){
    const row = w => { const [k, l] = workerStatus(w); const t = w.task && T(w.task); const o = t && O(t.order);
      return `<div class="item"><div class="grow"><div class="t">${esc(w.name)} <span class="pill p-${k}">${l}</span>${w.locked ? ' <span class="pill p-attention">Locked out</span>' : ''}</div>
        <div class="s">${stageName(w.stage)}${o ? ` · on ${o.ref}` : ''}</div></div>
        <button class="btn sm line" data-editw="${w.id}">Edit</button></div>`; };
    return `
      <div style="display:flex;justify-content:space-between;align-items:end;gap:12px;flex-wrap:wrap"><div><h2>Workers</h2>
      <p class="sub" style="margin-bottom:0">Each worker signs in on the workshop computer (<a href="station.html">station.html</a>) with their own PIN.</p></div>
      <button class="btn" data-addw>+ Add worker</button></div>
      ${STAGES.map(s => { const ws = S.workers.filter(w => w.stage === s.id); return `<p class="section-title">${s.name}</p>
        <div class="list">${ws.length ? ws.map(row).join('') : '<p class="empty">No one in this step yet.</p>'}</div>`; }).join('')}`;
  }

  function render(){
    document.querySelectorAll('.tabs [data-tab]').forEach(b => b.classList.toggle('on', b.dataset.tab === tab));
    const n = attention().filter(a => a.lvl === 'red').length;
    $('#attnBadge').textContent = n || ''; $('#attnBadge').style.display = n ? '' : 'none';
    $('#view').innerHTML = tab === 'today' ? viewToday() : tab === 'orders' ? viewOrders() : tab === 'workers' ? viewWorkers() : viewWorkshop();
  }

  /* ---------- clicks ---------- */
  document.addEventListener('click', async e => {
    if (e.target.closest('[data-addw]')) return workerModal();
    const ew = e.target.closest('[data-editw]'); if (ew) return workerModal(ew.dataset.editw);
    const b = e.target.closest('[data-tabgo],[data-open],[data-solve],[data-deliver],[data-up],[data-down]');
    if (!b) return;
    if (b.dataset.tabgo){ closeModal(); tab = b.dataset.tabgo; render(); window.scrollTo(0,0); }
    else if (b.dataset.open) orderModal(b.dataset.open);
    else if (b.dataset.solve){ b.disabled = true; closeModal(); await act('ws_solve', { p_task: b.dataset.solve }, 'Marked solved'); }
    else if (b.dataset.deliver){ b.disabled = true; closeModal(); await act('ws_deliver', { p_order: b.dataset.deliver }, 'Marked delivered'); }
    else if (b.dataset.up || b.dataset.down){ b.disabled = true; await act('ws_move', { p_task: b.dataset.up || b.dataset.down, p_up: !!b.dataset.up }); }
  });

  /* ---------- pop-ups ---------- */
  function closeModal(){ document.querySelector('.scrim')?.remove(); }
  function openModal(html){ closeModal(); const s = document.createElement('div'); s.className = 'scrim'; s.innerHTML = `<div class="modal">${html}</div>`; s.addEventListener('click', e => { if (e.target === s || e.target.closest('[data-x]')) closeModal(); }); document.body.appendChild(s); return s; }

  function newOrderModal(){
    const d = new Date(); d.setDate(d.getDate() + 7);
    const iso = d.toLocaleDateString('en-CA');
    const s = openModal(`
      <h2>New order</h2>
      <label class="field"><span>Customer</span><input id="fCust" placeholder="e.g. Mama Oliech Restaurant" autocomplete="off"></label>
      <div class="row2">
        <label class="field"><span>What</span><input id="fItem" placeholder="e.g. Bar stools" autocomplete="off"></label>
        <label class="field"><span>How many</span><input id="fQty" type="number" min="1" value="10"></label>
      </div>
      <label class="field"><span>Deadline</span><input id="fDate" type="date" value="${iso}"></label>
      <label class="field"><span>Note for the workshop (optional)</span><textarea id="fNote" rows="2" placeholder="e.g. Black frames, red seats. Customer collects."></textarea></label>
      <div class="field"><span>How urgent</span><div class="seg-pick" id="fUrg">
        <button type="button" data-u="normal" class="on">Normal</button><button type="button" data-u="high">High</button><button type="button" data-u="urgent">Urgent</button></div></div>
      <div class="field"><span>Steps it needs</span><div class="checks">${STAGES.map(st => `<label><input type="checkbox" value="${st.id}" checked> ${st.name}</label>`).join('')}</div></div>
      <p id="fErr" style="color:var(--red);min-height:20px;font-size:13px"></p>
      <div class="actions"><button class="btn line" data-x>Cancel</button><button class="btn" id="fSave">Add to workshop</button></div>`);
    let urg = 'normal';
    s.querySelector('#fUrg').addEventListener('click', e => { const b = e.target.closest('[data-u]'); if (!b) return; urg = b.dataset.u; s.querySelectorAll('#fUrg button').forEach(x => x.classList.toggle('on', x === b)); });
    s.querySelector('#fSave').onclick = async () => {
      const customer = s.querySelector('#fCust').value.trim(), item = s.querySelector('#fItem').value.trim();
      const qty = parseInt(s.querySelector('#fQty').value, 10) || 0;
      const stages = [...s.querySelectorAll('.checks input:checked')].map(x => x.value);
      if (!customer || !item || qty < 1) return s.querySelector('#fErr').textContent = 'Fill in the customer, what, and how many.';
      if (!stages.length) return s.querySelector('#fErr').textContent = 'Pick at least one step.';
      const btn = s.querySelector('#fSave'); btn.disabled = true; btn.textContent = 'Adding…';
      const { data, error } = await db.rpc('ws_create_order', { p: { customer, item, qty, deadline: s.querySelector('#fDate').value || null, urgency: urg, stages, notes: s.querySelector('#fNote').value.trim() } });
      if (error){ btn.disabled = false; btn.textContent = 'Add to workshop'; s.querySelector('#fErr').textContent = errMsg(error); return; }
      closeModal(); tab = 'orders'; await load();
      const o = S.orders.find(x => x.ref === data); const t = o && S.tasks.find(x => x.order === o.id && x.worker);
      toast(t ? `${data} added. ${W(t.worker)?.name || 'A worker'} has it now.` : `${data} added to the line.`);
    };
    setTimeout(() => s.querySelector('#fCust').focus(), 50);
  }

  function orderModal(id){
    const o = O(id); if (!o) return; const p = orderProgress(o);
    const ts = o.stages.map(st => S.tasks.find(t => t.order === o.id && t.stage === st)).filter(Boolean);
    const lbl = t => t.status === 'done' ? ['done','Done'] : t.status === 'working' ? (t.problem ? ['attention','Problem'] : ['working','In progress']) : t.status === 'assigned' ? ['notstarted','Given, not started'] : t.status === 'queued' ? ['waiting', `#${queue(t.stage).indexOf(t) + 1} in line`] : ['normal','Later'];
    openModal(`
      <div style="display:flex;justify-content:space-between;align-items:start;gap:10px"><div><h2 style="margin:0">${o.ref}</h2><p class="sub" style="margin:2px 0 0">${esc(o.customer)}</p></div><span class="pill p-${o.urgency}">${URG_NAME[o.urgency]}</span></div>
      <p style="margin:14px 0 4px;font-size:17px"><b>${o.qty} × ${esc(o.item)}</b></p>
      ${o.notes ? `<p style="margin:6px 0;padding:10px 12px;background:#fff;border:1px solid var(--line);border-radius:6px">📝 ${esc(o.notes)}</p>` : ''}
      <p class="${!p.finished && isLate(o.deadline) ? 'due late' : ''}" style="text-align:left">Deadline: ${fmtDay(o.deadline)}</p>
      <div style="margin:14px 0">${pipe(o)}</div>
      <div class="steps">${ts.map(t => { const [k, l] = lbl(t); const w = t.worker && W(t.worker); return `<div class="step"><div style="flex:1"><b>${stageName(t.stage)}</b><div style="color:var(--muted);font-size:13px">${w ? esc(w.name) : 'Not given to anyone yet'}${t.problem ? ` · ⚠ ${esc(t.problem.reason)}` : ''}</div></div><span class="pill p-${k}">${l}</span>${t.problem ? `<button class="btn sm" data-solve="${t.id}">Solved</button>` : ''}</div>`; }).join('')}</div>
      ${!o.delivered && o.urgency !== 'urgent' && !p.finished ? `<p style="margin-top:14px;font-size:13px;color:var(--muted)">Customer pushing? Make it urgent and it jumps to the front of every line. No one's current job gets interrupted.</p>` : ''}
      <div class="actions">
        ${!o.delivered && o.urgency !== 'urgent' && !p.finished ? `<button class="btn red" id="mkUrgent">Make urgent</button>` : ''}
        ${p.finished && !o.delivered ? `<button class="btn" data-deliver="${o.id}">Mark delivered</button>` : ''}
        <button class="btn line" data-x>Close</button>
      </div>`);
    const u = $('#mkUrgent');
    if (u) u.onclick = async () => { u.disabled = true; closeModal(); await act('ws_make_urgent', { p_order: o.id }, `${o.ref} is now urgent`); };
  }

  function workerModal(id){
    const w = id ? W(id) : null;
    const s = openModal(`
      <h2>${w ? 'Edit ' + esc(w.name) : 'Add a worker'}</h2>
      <label class="field"><span>Name</span><input id="wName" value="${w ? esc(w.name) : ''}" placeholder="e.g. Odhiambo" autocomplete="off"></label>
      <label class="field"><span>Works in</span><select id="wStage" ${w && w.task ? 'disabled' : ''}>${STAGES.map(st => `<option value="${st.id}" ${w && w.stage === st.id ? 'selected' : ''}>${st.name}</option>`).join('')}</select>
        ${w && w.task ? '<small style="color:var(--muted)">Can change step once their current job is finished.</small>' : ''}</label>
      <label class="field"><span>${w ? 'New PIN (leave empty to keep the old one)' : '4-digit PIN'}</span><input id="wPin" inputmode="numeric" maxlength="4" placeholder="e.g. 4821" autocomplete="off"></label>
      <p style="font-size:13px;color:var(--muted)">Tell the worker their PIN in person. It is stored scrambled, so no one can look it up later, not even you. Forgotten PIN? Just set a new one.</p>
      <p id="wErr" style="color:var(--red);min-height:20px;font-size:13px"></p>
      <div class="actions" style="justify-content:space-between">
        ${w ? `<button class="btn ${!w.active ? '' : 'red'}" id="wToggle">${!w.active ? 'Switch back on' : 'Switch off'}</button>` : '<span></span>'}
        <span style="display:flex;gap:8px"><button class="btn line" data-x>Cancel</button><button class="btn" id="wSave">Save</button></span>
      </div>`);
    s.querySelector('#wSave').onclick = async () => {
      const name = s.querySelector('#wName').value.trim(), stage = s.querySelector('#wStage').value, pin = s.querySelector('#wPin').value.trim();
      if (!name) return s.querySelector('#wErr').textContent = 'Add a name.';
      if ((!w || pin) && !/^\d{4}$/.test(pin)) return s.querySelector('#wErr').textContent = 'The PIN must be exactly 4 numbers.';
      const btn = s.querySelector('#wSave'); btn.disabled = true;
      const { error } = await db.rpc('ws_save_worker', { p: { id: w ? w.id : null, name, stage: w && w.task ? w.stage : stage, pin } });
      if (error){ btn.disabled = false; s.querySelector('#wErr').textContent = errMsg(error); return; }
      closeModal(); toast('Saved'); await load();
    };
    const tg = s.querySelector('#wToggle');
    if (tg) tg.onclick = async () => { tg.disabled = true; closeModal(); await act('ws_set_worker_active', { p_worker: w.id, p_active: !w.active }, 'Saved'); };
    if (!w) setTimeout(() => s.querySelector('#wName').focus(), 50);
  }

  /* =====================================================================
     ALARM: when a worker says their work has STOPPED
     Siren + vibration until the owner taps "I'm on it".
     SMS and phone call need an SMS service (e.g. Africa's Talking): not connected yet.
     ===================================================================== */
  let muted = false, beepT = null, actx = null, tick = null;
  const stoppedOpen = () => S.tasks.filter(t => t.problem && t.problem.stopped && !t.problem.ack);
  const mmss = n => Math.floor(n / 60) + ':' + String(n % 60).padStart(2, '0');
  function beep(){
    try {
      actx = actx || new (window.AudioContext || window.webkitAudioContext)();
      const now = actx.currentTime;
      const o = actx.createOscillator(), o2 = actx.createOscillator(), g = actx.createGain();
      o.type = 'sawtooth'; o2.type = 'square';
      [o, o2].forEach((osc, i) => { const f = i ? 1.5 : 1;
        osc.frequency.setValueAtTime(650 * f, now); osc.frequency.linearRampToValueAtTime(1350 * f, now + .55); osc.frequency.linearRampToValueAtTime(650 * f, now + 1.1); osc.connect(g); });
      g.gain.setValueAtTime(.0001, now); g.gain.exponentialRampToValueAtTime(.5, now + .05); g.gain.setValueAtTime(.5, now + 1.0); g.gain.exponentialRampToValueAtTime(.0001, now + 1.15);
      g.connect(actx.destination); o.start(now); o2.start(now); o.stop(now + 1.2); o2.stop(now + 1.2);
    } catch(e){}
    if (navigator.vibrate) navigator.vibrate([700, 150, 700, 150, 700]);
  }
  function alarmRender(){
    const list = stoppedOpen(); const el = $('#alarm');
    if (!list.length){ el.classList.add('hidden'); clearInterval(beepT); beepT = null; clearInterval(tick); tick = null; return; }
    const t = list[0], w = W(t.worker), o = O(t.order); if (!o) return;
    const n = Math.max(0, Math.floor((Date.now() - t.problem.at) / 1000));
    el.innerHTML = `<button class="mute" id="muteBtn">${muted ? '🔇 Siren off' : '🔊 Siren + vibrate on'}</button><div class="box">
      <p class="tag">⚠ WORK HAS STOPPED</p>
      <h1>${esc(t.problem.reason)}</h1>
      <p class="who"><b>${esc(w ? w.name : 'A worker')}</b> · ${stageName(t.stage)} · ${o.ref}</p>
      <p class="timer">${o.qty} × ${esc(o.item)} · waiting ${mmss(n)}</p>
      <div class="ladder">
        <div><span class="ok">✓ Siren + vibration</span><span class="ok">now</span></div>
        <div class="not-yet"><span>○ SMS to your phone</span><span>not connected yet</span></div>
        <div class="not-yet"><span>○ Phone call to you</span><span>not connected yet</span></div>
      </div>
      <button class="giant ack" data-ack="${t.id}">I'M ON IT</button>
      <p class="more">Tapping this stops the alarm and tells ${esc(w ? w.name : 'them')} you've seen it.${list.length > 1 ? ` <b>${list.length - 1} more waiting.</b>` : ''}</p>
    </div>`;
    el.classList.remove('hidden');
    if (!tick) tick = setInterval(alarmRender, 1000);
    if (!beepT && !muted){ beep(); beepT = setInterval(() => { if (!muted) beep(); }, 1300); }
  }
  document.addEventListener('click', async e => {
    if (e.target.closest('#muteBtn')){ muted = !muted; if (muted){ clearInterval(beepT); beepT = null; if (navigator.vibrate) navigator.vibrate(0); } alarmRender(); return; }
    const a = e.target.closest('[data-ack]'); if (!a) return;
    a.disabled = true; a.textContent = 'Telling them…';
    if (navigator.vibrate) navigator.vibrate(0);
    const t = T(a.dataset.ack); if (t) t.problem.ack = true;   // stop the siren straight away
    alarmRender();
    await act('ws_ack', { p_task: a.dataset.ack }, "They've been told you're on it");
  });
  // Phones block sound until the first tap. Any tap on the page unlocks it.
  document.addEventListener('pointerdown', () => { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); if (actx.state === 'suspended') actx.resume(); } catch(e){} }, { once:true });

  db.auth.onAuthStateChange(ev => { if (ev === 'SIGNED_OUT') show('loginView'); });
  start();
})();
