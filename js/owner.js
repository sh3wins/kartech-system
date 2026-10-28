/* =====================================================================
   KARTECH WORKSHOP — owner app (phone + computer)
   Reads from the Kartech Supabase database. Every change goes through a
   database function, so the rules (queues, who gets the next job) live in
   one place: supabase/setup-workshop.sql
   ===================================================================== */
(function(){
  const POLL_MS = 8000;
  let S = { workers:[], orders:[], tasks:[], log:[], mats:[], moves:[], std:[], tools:[], toolChecks:[], toolMissing:[], loans:[], hasCode:null };
  let tab = 'today', loaded = false, busy = false;

  const W = id => S.workers.find(w => w.id === id);
  const O = id => S.orders.find(o => o.id === id);
  const T = id => S.tasks.find(t => t.id === id);
  const taskNames = t => { const ns = S.workers.filter(w => w.task === t.id).map(w => w.name); if (!ns.length && t.worker && W(t.worker)) ns.push(W(t.worker).name); return ns.join(' & ') || 'A worker'; };
  const queue = stage => S.tasks.filter(t => t.stage === stage && t.status === 'queued').sort((a,b) => a.rank - b.rank);
  const show = id => ['loginView','setupView','owner'].forEach(v => $('#' + v).classList.toggle('hidden', v !== id));

  function orderProgress(o){
    const ts = S.tasks.filter(t => t.order === o.id);
    const cur = ts.filter(t => t.status !== 'done').sort((a,b) => a.step - b.step)[0];
    return { done: ts.filter(t => t.status === 'done').length, total: ts.length, current: cur, finished: ts.length > 0 && !cur };
  }
  function workerStatus(w){
    if (!w.active) return ['normal', 'Switched off'];
    if (w.away) return ['normal', 'Away today'];
    if (!w.here) return ['normal', 'Not in yet'];
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
    ['live','fab','side','mbar'].forEach(id => $('#' + id).classList.remove('hidden'));
    document.body.classList.add('in');
    show('owner');
    await loadSteps();
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
      const [w, o, l, wb, mt, mv, sd, tl, tc, tm, ln, hc] = await Promise.all([
        db.from('ws_workers').select('id,name,stage,active,task_id,locked_until,created_at,away_on,covers,arrived_on,arrived_at').order('name'),
        db.from('ws_orders').select('*').or('delivered_at.is.null,delivered_at.gt.' + since).order('created_at', { ascending:false }).limit(400),
        db.from('ws_log').select('*').order('id', { ascending:false }).limit(60),
        db.from('orders').select('id,order_no,created_at,status,customer_name,phone,fulfilment,delivery_location,notes,items').in('status', ['received','confirmed','workshop']).order('created_at', { ascending:false }).limit(100),
        db.from('ws_materials').select('*').order('name'),
        db.from('ws_moves').select('*').order('id', { ascending:false }).limit(500),
        db.from('ws_usage_std').select('*'),
        db.from('ws_tools').select('*').order('name'),
        db.from('ws_tool_checks').select('*').order('day', { ascending:false }).limit(40),
        db.from('ws_tool_missing').select('*').order('id', { ascending:false }).limit(300),
        db.from('ws_tool_loans').select('*').order('id', { ascending:false }).limit(300),
        db.rpc('ws_has_foreman_pin')
      ]);
      if (w.error || o.error || l.error) throw (w.error || o.error || l.error);
      const ids = o.data.map(x => x.id);
      const t = ids.length ? await db.from('ws_tasks').select('*').in('order_id', ids) : { data: [] };
      if (t.error) throw t.error;
      const today = new Date().toLocaleDateString('en-CA', { timeZone:'Africa/Nairobi' });
      S.workers = w.data.map(x => ({ id:x.id, name:x.name, stage:x.stage, active:x.active, task:x.task_id, covers:x.covers || [], away: !!x.away_on && String(x.away_on).slice(0, 10) === today, arrived: !!x.arrived_on && String(x.arrived_on).slice(0, 10) === today, arrivedAt: x.arrived_at ? new Date(x.arrived_at).getTime() : null, locked: x.locked_until && new Date(x.locked_until) > new Date() })).map(w => Object.assign(w, { here: w.active && w.arrived && !w.away }));
      S.web = wb.error ? [] : wb.data;
      S.mats = mt.error ? [] : mt.data.map(x => ({ id:x.id, name:x.name, unit:x.unit, store:+x.in_store, low:+x.low_at, counted: x.counted !== false, active:x.active, stages:x.stages || [] }));
      S.moves = mv.error ? [] : mv.data.map(x => ({ id:x.id, at:new Date(x.at).getTime(), mat:x.material_id, kind:x.kind, qty:+x.qty, order:x.order_id, worker:x.worker_id, note:x.note }));
      S.tools = tl.error ? [] : tl.data.map(x => ({ id:x.id, name:x.name, worker:x.usual_worker, active:x.active, stages:x.stages || [] }));
      S.toolChecks = tc.error ? [] : tc.data.map(x => ({ day:String(x.day).slice(0, 10), at:new Date(x.done_at).getTime(), missing:x.missing }));
      S.loans = ln.error ? [] : ln.data.filter(x => !x.back_at).map(x => ({ tool:x.tool_id, worker:x.worker_id, at:new Date(x.out_at).getTime() }));
      S.hasCode = hc.error ? null : !!hc.data;
      S.toolMissing = tm.error ? [] : tm.data.map(x => ({ tool:x.tool_id, worker:x.worker_id, since:String(x.since).slice(0, 10), found: !!x.found_at }));
      S.std = sd.error ? [] : sd.data.map(x => ({ product:x.product, mat:x.material_id, per:+x.per_piece }));
      S.orders = o.data.map(x => ({ id:x.id, ref:x.ref, src:x.source_order_id || null, srcNo:x.source_no || null, customer:x.customer, item:x.item, qty:x.qty, deadline:new Date(x.deadline + 'T17:00'), dl:String(x.deadline).slice(0, 10), urgency:x.urgency, notes:x.notes, stages:x.stages, delivered: !!x.delivered_at, createdAt: new Date(x.created_at).getTime(), delOn: x.delivery_on ? String(x.delivery_on).slice(0, 10) : null, delPlace: x.delivery_place || '', delNote: x.delivery_note || '', deliveredAt: x.delivered_at ? new Date(x.delivered_at).getTime() : null }));
      S.tasks = t.data.map(x => ({ id:x.id, order:x.order_id, step:x.step, stage:x.stage, status:x.status, worker:x.worker_id, rank:x.rank, withPrev: !!x.with_prev, doneAt: x.done_at ? new Date(x.done_at).getTime() : null, planned: Array.isArray(x.planned) ? x.planned : String(x.planned || '').replace(/[{}]/g, '').split(',').filter(Boolean),
        problem: x.problem_at ? { reason:x.problem_reason, at:new Date(x.problem_at).getTime(), stopped:!!x.problem_stopped, ack: !!x.problem_ack_at } : null }));
      S.log = l.data.map(x => ({ id:x.id, text:x.text, kind:x.kind, at:new Date(x.at).getTime(), order:x.order_id }));
      loaded = true;
      loadDay();
      announceChanges();
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
  document.querySelectorAll('.tabs [data-tab]').forEach(b => b.addEventListener('click', () => { tab = b.dataset.tab; orderFilter = null; enter = true; render(); window.scrollTo(0,0); load(); if (tab === 'history') (H.mode === 'week' ? loadWeek() : loadHistory()); }));
  $('#newOrderBtn').onclick = $('#fab').onclick = () => newOrderModal();

  function attention(){
    const items = [];
    S.tasks.filter(t => t.problem && T(t.id)).forEach(t => { const w = W(t.worker), o = O(t.order); if (!o) return;
      items.push({ lvl:'red', title:`${t.problem.stopped ? 'WORK STOPPED' : 'Problem'}: ${t.problem.reason}${t.problem.stopped && t.problem.ack ? " (you're on it)" : ''}`,
        sub:`${w ? w.name : 'Worker'} · ${o.ref} · ${stageName(t.stage)} · ${ago(t.problem.at)}`, act:`<button class="btn sm" data-solve="${t.id}">Mark solved</button>` }); });
    S.orders.filter(o => !o.delivered && !orderProgress(o).finished && isLate(o.deadline)).forEach(o => items.push({ lvl:'red', title:`${o.ref} is past its deadline`, sub:`${o.qty} × ${o.item} · ${o.customer}`, act:`<button class="btn sm line" data-open="${o.id}">Open</button>` }));
    waitingWeb().forEach(w => items.push({ lvl:'amber', title:`New website order ${w.order_no}`, sub:`${w.customer_name} · ${(w.items || []).map(i => i.qty + ' × ' + i.name).join(', ')} · ${ago(new Date(w.created_at).getTime())}`, act:`<button class="btn sm" data-web="${w.id}">Send to workshop</button>` }));
    S.mats.filter(m => m.active && m.low > 0 && m.store <= m.low).forEach(m => items.push({ lvl:'amber', title:`Low stock: ${m.name}`, sub:`Only ${n2(m.store)} ${m.unit} left in the store`, act:`<button class="btn sm line" data-move="in" data-mat="${m.id}">Received</button>` }));
    watchList().slice(0, 3).forEach(a => items.push({ lvl:'red', title:a.title, sub:a.sub, act:`<button class="btn sm line" data-tabgo="stock">See stock</button>` }));
    openMissing().forEach(x => { const t = TL(x.tool), w = x.worker && W(x.worker); if (!t) return;
      items.push({ lvl:'red', title:`Tool missing: ${t.name}`, sub:`${w ? 'Normally with ' + w.name + ' · ' : ''}not back since ${fmtDay(new Date(x.since + 'T12:00')).replace(/^(Today|Yesterday)$/, x => x.toLowerCase())}`, act:`<button class="btn sm line" data-toolfound="${t.id}">It's back</button>` }); });
    if (S.hasCode === false && (S.tools.some(t => t.active) || S.mats.length)) items.push({ lvl:'amber', title:'Set the manager code', sub:'The manager needs it to tick tools and materials on the workshop screen', act:`<button class="btn sm line" data-fmcode>Set code</button>` });
    if (S.tools.some(t => t.active) && checkDue() && !S.toolChecks.find(c => c.day === todayStr()))
      items.push({ lvl:'amber', title:'Tool check not done yet tonight', sub:`The manager should check the tools at ${KT_CONFIG.toolCheckAt || '18:30'} on the workshop screen`, act:`<button class="btn sm line" data-tabgo="stock">See tools</button>` });
    STAGES.forEach(st => { const q = queue(st.id); if (!q.length) return;
      const can = S.workers.filter(w => w.here && (w.stage === st.id || w.covers.includes(st.id)));
      if (!can.length) items.push({ lvl:'red', title:`Nobody in ${st.name} today`, sub:`${q.length} job${q.length > 1 ? 's' : ''} waiting. Pick someone to step up.`, act:`<button class="btn sm" data-give="${q[0].id}">Give to…</button>` }); });
    const nb = new Date(new Date().toLocaleString('en-US', { timeZone:'Africa/Nairobi' }));
    const notIn = S.workers.filter(w => w.active && !w.arrived && !w.away);
    if (notIn.length && nb.getHours() >= 9 && nb.getHours() < 18) items.push({ lvl:'amber', title:`${notIn.length} worker${notIn.length > 1 ? 's' : ''} not ticked in yet`, sub:`${notIn.slice(0, 4).map(w => w.name).join(', ')}${notIn.length > 4 ? '…' : ''} · they get no jobs until the manager ticks them in`, act:`<button class="btn sm line" data-tabgo="workers">See workers</button>` });
    const idle = S.workers.filter(w => w.here && !w.task);
    if (idle.length) items.push({ lvl:'amber', title: idle.length === 1 ? `${idle[0].name} is waiting for work` : `${idle.slice(0, -1).map(w => w.name).join(', ')} and ${idle[idle.length - 1].name} are waiting for work`,
      sub: idle.length === 1 ? `${stageName(idle[0].stage)} · nothing in the line` : 'Nothing in their lines. Add an order or send a website order.', act:`<button class="btn sm line" data-tabgo="workshop">See workshop</button>` });
    S.orders.filter(o => !o.delivered && o.urgency === 'urgent' && !orderProgress(o).finished && !isLate(o.deadline)).forEach(o => { const c = orderProgress(o).current;
      items.push({ lvl:'amber', title:`Urgent: ${o.ref}, due ${fmtDay(o.deadline)}`, sub:`${o.qty} × ${o.item}${c ? ' · now at ' + stageName(c.stage) : ''}`, act:`<button class="btn sm line" data-open="${o.id}">Open</button>` }); });
    S.orders.filter(o => !o.delivered && orderProgress(o).finished).forEach(o => items.push({ lvl:'green', title:`${o.ref} is loaded and ready`, sub:`${o.customer} · confirm when it leaves`, act:`<button class="btn sm" data-deliver="${o.id}">Mark delivered</button>` }));
    return items;
  }

  /* ---------- HOME: what needs her + workshop news ---------- */
  const OWNER_RX = /^(New order|Website order|New worker added|Worker updated|Owner is on it|Problem solved|Received|Gave|New material added|New tool added|Tool back|Manager code changed|Stock count: \S+ is correct)|made urgent|delivered to|switched (back on|off)/;
  const COLORS = ['#1f7a5c','#b5432f','#2f5fa8','#8a5a00','#7b3fa0','#0e7c86','#a0386b','#4d6b1f'];
  const colorOf = name => COLORS[[...name].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) % COLORS.length];
  const hhmm = t => new Date(t).toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
  const dayChip = t => { const d = new Date(t), n = new Date(); const y = new Date(); y.setDate(n.getDate() - 1);
    return d.toDateString() === n.toDateString() ? 'Today' : d.toDateString() === y.toDateString() ? 'Yesterday' : d.toLocaleDateString('en-GB', { weekday:'long', day:'numeric', month:'short' }); };
  function chatMsg(l){
    if (OWNER_RX.test(l.text)) return { me:true, text: l.text.replace(/^Owner is on it:/, "I'm on it:") };
    const names = S.workers.map(w => w.name).sort((x, y) => y.length - x.length);
    const n = names.find(n => l.text.startsWith(n + ' '));
    if (n){ const t = l.text.slice(n.length + 1).replace(/^\(.*?\) has no work waiting$/, 'is waiting for work'); return { from:n, text: t.charAt(0).toUpperCase() + t.slice(1) }; }
    return { from:'Workshop', sys:true, text:l.text };
  }
  function statusLine(){
    const act = S.workers.filter(w => w.active);
    if (!act.length) return 'No workers yet';
    const busy = act.filter(w => workerStatus(w)[0] === 'working').map(w => w.name);
    const wait = act.filter(w => !w.task).map(w => w.name);
    const prob = act.filter(w => workerStatus(w)[0] === 'attention').map(w => w.name);
    const list = (a, word, one) => a.length ? (a.length > 2 ? a.length + ' ' : a.join(', ') + ' ') + (a.length === 1 && one ? one : word) : '';
    return [list(prob, 'need you', 'needs you'), list(busy, 'working'), list(wait, 'waiting')].filter(Boolean).join(' · ') || 'Everyone has a job';
  }
  /* ---------- DASHBOARD ---------- */
  let enter = true, prevStats = {}, seenAtt = null, orderFilter = null;
  const orderHealth = o => { const p = orderProgress(o);
    if (p.finished) return ['ready', 'Ready'];
    if (isLate(o.deadline)) return ['late', 'Late'];
    const daysLeft = (o.deadline - Date.now()) / 864e5;
    const problem = S.tasks.some(t => t.order === o.id && t.problem);
    if (problem || (daysLeft < 1.5 && p.done / Math.max(1, p.total) < .5)) return ['risk', 'At risk'];
    return ['track', 'On track'];
  };
  function viewToday(){
    const att = attention();
    const now = new Date(), h = now.getHours();
    const open = S.orders.filter(o => !o.delivered && !orderProgress(o).finished);
    const st = {
      late: open.filter(o => isLate(o.deadline)).length,
      urgent: open.filter(o => o.urgency === 'urgent').length,
      waiting: S.tasks.filter(t => t.status === 'queued' && O(t.order) && !O(t.order).delivered).length,
      working: S.tasks.filter(t => t.status === 'working' || t.status === 'assigned').length
    };
    const box = (k, label, sub, go, ico) => { const changed = !enter && prevStats[k] !== undefined && prevStats[k] !== st[k];
      return `<button class="kpi k-${k} ${st[k] ? 'on' : ''} ${changed ? 'pop' : ''} anim" style="--i:${['late','urgent','waiting','working'].indexOf(k)}" data-go="${go}">
        <span class="kpi-top"><i class="kpi-ic">${ico}</i>${label}</span>
        <b data-count="${st[k]}" data-from="${enter ? 0 : (prevStats[k] ?? st[k])}">${enter ? 0 : st[k]}</b>
        <span class="kpi-sub">${sub}</span><span class="kpi-view">View →</span></button>`; };
    const keys = att.map(a => a.title);
    const fresh = seenAtt ? keys.filter(k => !seenAtt.has(k)) : [];
    seenAtt = new Set(keys);
    const active = open.slice().sort((a,b) => URG[a.urgency] - URG[b.urgency] || a.deadline - b.deadline).slice(0, 6);
    const ready = S.orders.filter(o => !o.delivered && orderProgress(o).finished);
    const web = waitingWeb();
    const html = `
      <div class="d-head anim" style="--i:0">
        <div><p class="d-date">${now.toLocaleDateString('en-GB', { weekday:'short', day:'numeric', month:'short', year:'numeric' })}</p>
        <h1>${briefing().hello} <span class="wave">👋</span></h1>
        <p class="sub" style="margin:0">${att.length ? `Here's what needs your attention today.` : 'Everything is running on its own. ✓'}</p></div>
        <button class="btn d-new" data-neworder><span>+</span> New order</button>
      </div>
      ${briefCard()}
      <div class="kpis">
        ${box('late', 'Late', 'past the deadline', 'orders:late', '!')}
        ${box('urgent', 'Urgent', 'jobs to rush', 'orders:urgent', '⚡')}
        ${box('waiting', 'In line', 'waiting for a worker', 'workshop', '◷')}
        ${box('working', 'In progress', 'being worked on', 'workshop', '▶')}
      </div>
      <div class="d-grid">
        <div class="d-col">
          ${att.length ? `<div class="panel anim" style="--i:4"><div class="p-head"><h3>Needs you <span class="count">${att.length}</span></h3></div>
            ${att.map(a => `<div class="need ${a.lvl} ${fresh.includes(a.title) ? 'fresh' : ''}"><span class="need-dot"></span><div class="grow"><b>${esc(a.title)}</b><p>${esc(a.sub)}</p></div>${a.act}</div>`).join('')}</div>` : ''}
          <div class="panel anim" style="--i:5"><div class="p-head"><h3>Active orders</h3><button class="link" data-tabgo="orders">View all</button></div>
            ${active.length ? active.map((o, i) => { const p = orderProgress(o), pct = Math.round(100 * p.done / Math.max(1, p.total)), [hk, hl] = orderHealth(o);
              return `<button class="ord" data-open="${o.id}">
                <div class="ord-name"><b>${esc(o.item)}</b> <span class="muted">(${o.ref})</span><small>${o.qty} pcs · ${esc(o.customer)}${p.current ? ' · now at ' + stageName(p.current.stage) : ''}</small></div>
                <div class="ord-bar"><i class="h-${hk}" style="width:${Math.max(pct, 4)}%;--d:${i * 80}ms"></i></div><span class="ord-pct">${pct}%</span>
                <span class="ord-due">Due ${fmtDay(o.deadline)}</span><span class="hp h-${hk}">${hl}</span></button>`; }).join('')
              : `<p class="empty">No open orders. Tap <b>+ New order</b> to add one.</p>`}
          </div>
        </div>
        <div class="d-col">
          <div class="panel anim" style="--i:6"><div class="p-head"><h3>Quick actions</h3></div>
            <button class="qa" data-neworder><i>＋</i><span><b>Create order</b><small>Add a job for the workshop</small></span></button>
            <button class="qa" data-tabgo="orders"><i>🌐</i><span><b>Website orders</b><small>${web.length ? web.length + ' waiting to be sent to the workshop' : 'None waiting'}</small></span>${web.length ? `<em>${web.length}</em>` : ''}</button>
            <button class="qa" data-move="out"><i>📦</i><span><b>Give out materials</b><small>Record what leaves the store</small></span></button>
            <button class="qa" data-tabgo="workers"><i>👥</i><span><b>View workers</b><small>${S.workers.filter(w => w.active).length} on the team</small></span></button>
            ${ready.length ? `<button class="qa" data-tabgo="orders"><i>🚚</i><span><b>Ready to deliver</b><small>${ready.length} finished and loaded</small></span><em class="g">${ready.length}</em></button>` : ''}
          </div>
          <div class="panel anim" style="--i:7"><div class="p-head"><h3>Workshop news</h3><span class="live-dot"></span></div>
            ${S.log.slice(0, 7).map(l => { const m = chatMsg(l); const who = m.me ? 'You' : m.from;
              return `<div class="news ${l.kind === 'alert' && !m.me ? 'alert' : ''}"${l.order ? ` data-open="${l.order}"` : ''}><span class="news-av" style="background:${m.me ? 'var(--ink)' : m.sys ? 'var(--metal)' : colorOf(m.from)}">${m.sys ? '⚙' : esc(who.charAt(0))}</span>
                <div class="grow"><p><b>${esc(who)}</b>${m.sys || m.me ? ' · ' : ' '}${esc(m.sys || m.me ? m.text : m.text.charAt(0).toLowerCase() + m.text.slice(1))}</p><small>${ago(l.at)}</small></div></div>`; }).join('') || '<p class="empty">News from the workshop will appear here.</p>'}
          </div>
        </div>
      </div>`;
    prevStats = st;
    return html;
  }

  function settingsModal(){
    openModal(`<div id="setModal">
      <h2>Settings</h2>
      <p class="section-title" style="margin-top:6px">🔊 Voice</p>
      <p class="sub" style="margin-bottom:10px">The phone reads workshop news out loud while this app is open.</p>
      <div class="seg-pick">${['en','sw','off'].map(l => `<button type="button" data-vlang="${l}" class="${VOICE.lang === l ? 'on' : ''}">${l === 'en' ? 'English' : l === 'sw' ? 'Kiswahili' : 'Off'}</button>`).join('')}</div>
      ${VOICE.lang !== 'off' && voicesFor(VOICE.lang).length ? `<label class="field" style="margin-top:12px"><span>Which voice</span><select id="vName">${voicesFor(VOICE.lang).map(v => `<option value="${esc(v.name)}" ${pickVoice(VOICE.lang) === v ? 'selected' : ''}>${esc(v.name.replace(/^Microsoft /,'').replace(/ - .*$/,'').replace(/ Online \(Natural\)/,' (natural)'))} · ${esc(v.lang)}</option>`).join('')}</select></label>` : ''}
      <label style="display:flex;gap:8px;align-items:center;margin:12px 0"><input type="checkbox" id="vSmall" ${VOICE.small ? 'checked' : ''} style="accent-color:var(--green);width:18px;height:18px"> Also read small updates (job finished, worker waiting)</label>
      <button class="btn line" id="vTest">Test voice</button>
      <p class="section-title">📱 On your phone</p>
      <p class="sub" style="margin-bottom:0">You stay signed in on this phone. To get an app icon: open the browser menu (⋮) and tap <b>Add to Home screen</b>.</p>
      <p class="section-title">⇄ Switch</p>
      <p class="sub" style="margin-bottom:8px">Use this phone as the workshop screen or the customer shop instead.</p>
      <a class="btn line" href="index.html?choose" style="text-decoration:none">Switch to another side</a>
      <div class="actions" style="justify-content:space-between;margin-top:22px"><button class="btn line" id="outBtn2" style="color:var(--red)">Sign out of this phone</button><button class="btn" data-x>Done</button></div>
    </div>`);
  }

  function pipe(o){
    const ts = S.tasks.filter(t => t.order === o.id);
    const cur = ts.filter(t => t.status !== 'done').sort((a, b) => a.step - b.step)[0];
    return `<div class="pipe">${o.stages.map(sid => {
      const t = ts.find(x => x.stage === sid);
      const cls = !t ? 'skip' : t.status === 'done' ? 'done' : (t.status === 'working' || t.status === 'assigned') ? 'now' : '';
      return `<div class="seg ${cls}" title="${esc(stageName(sid))}"><i></i><em>${t && cur && t.id === cur.id ? esc(stageName(sid)) : ''}</em></div>`;
    }).join('')}</div>`;
  }

  function stepChecks(selected, cls){
    return `<div class="stepchecks">${stepGroups().map(g => `<div class="sg"><p class="sg-h"><b>${esc(g.grp)}</b>${g.steps.length > 1 ? `<button type="button" class="sg-all" data-sgall>all / none</button>` : ''}</p>
      <div class="checks">${g.steps.map(st => `<label><input type="checkbox" class="${cls || ''}" value="${st.id}" ${selected === true || (selected && selected.includes(st.id)) ? 'checked' : ''}> ${esc(st.name)}</label>`).join('')}</div></div>`).join('')}</div>`;
  }
  document.addEventListener('click', e => { const b = e.target.closest('[data-sgall]'); if (!b) return;
    const boxes = [...b.closest('.sg').querySelectorAll('input[type=checkbox]')]; const on = !boxes.every(x => x.checked); boxes.forEach(x => x.checked = on); });

  function viewOrders(){
    const active = S.orders.filter(o => !o.delivered)
      .filter(o => orderFilter === 'late' ? !orderProgress(o).finished && isLate(o.deadline) : orderFilter === 'urgent' ? !orderProgress(o).finished && o.urgency === 'urgent' : true)
      .sort((a,b) => URG[a.urgency] - URG[b.urgency] || a.deadline - b.deadline);
    const delivered = S.orders.filter(o => o.delivered);
    const row = o => { const p = orderProgress(o); const late = !p.finished && isLate(o.deadline);
      return `<button class="order" data-open="${o.id}">
        <div><div class="ref">${o.ref} <span class="pill p-${o.urgency}">${URG_NAME[o.urgency]}</span>${o.srcNo ? ` <span class="pill p-web">🌐 ${esc(o.srcNo)}</span>` : ''}</div><div style="color:var(--muted);font-size:13px">${o.qty} × ${esc(o.item)} · ${esc(o.customer)}</div></div>
        ${pipe(o)}
        <div class="due ${late && !o.delivered ? 'late' : ''}">${o.delivered ? 'Delivered' : p.finished ? '<span class="pill p-done">Ready</span>' : 'Due ' + fmtDay(o.deadline)}</div>
      </button>`; };
    const web = waitingWeb();
    return `
      ${web.length ? `<div class="webbox"><p class="section-title" style="margin-top:0">🌐 New from the website · ${web.length}</p>
        <div class="list">${web.map(w => `<button class="order webrow" data-web="${w.id}">
          <div><div class="ref">${esc(w.order_no)}</div><div style="color:var(--muted);font-size:13px">${esc(w.customer_name)} · ${ago(new Date(w.created_at).getTime())}</div></div>
          <div class="webitems">${(w.items || []).map(i => `${i.qty} × ${esc(i.name)}`).join('<br>')}</div>
          <span class="btn sm">Send to workshop</span></button>`).join('')}</div></div>` : ''}
      ${orderFilter ? '' : deliveriesPanel()}
      <h2>Orders</h2>
      <p class="sub">Most urgent first. Tap an order to see who's on it.</p>
      ${orderFilter ? `<p class="filter">Showing only <b>${orderFilter}</b> orders <button id="clearFilter">Show all ✕</button></p>` : ''}
      <div class="list">${active.length ? active.map(row).join('') : `<p class="empty">${orderFilter ? 'None right now. ✓' : 'No open orders. Tap <b>+ New order</b> to add one.'}</p>`}</div>
      ${delivered.length && !orderFilter ? `<p class="section-title">Delivered (last 30 days)</p><div class="list">${delivered.map(row).join('')}</div>` : ''}`;
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
      const nPlan = w.active ? S.tasks.filter(x => x.status !== 'done' && x.planned.includes(w.id) && x.worker !== w.id && O(x.order) && !O(x.order).delivered).length : 0;
      return `<div class="item"><button class="grow w-open" data-wwork="${w.id}" ${w.active ? '' : 'disabled'}><div class="t">${esc(w.name)} <span class="pill p-${k}">${l}</span>${nPlan ? ` <span class="tog-tag">${nPlan} lined up</span>` : ''}</div>
        <div class="s">${stageName(w.stage)}${w.covers.length ? ` · also ${w.covers.map(c => stageName(c).toLowerCase()).join(', ')}` : ''}${o ? ` · on ${o.ref}` : ''}${w.active ? ' · <span class="w-give">Give work ›</span>' : ''}</div></button>
        ${w.active ? (w.here ? `<span class="in-chip">✓ In${w.arrivedAt ? ' ' + new Date(w.arrivedAt).toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' }) : ''}</span><button class="btn sm line away-btn" data-away="${w.id}" data-v="1">Away today</button>`
          : `<button class="btn sm away-btn" data-away="${w.id}" data-v="0">Mark in</button>${w.away ? '' : `<button class="btn sm line away-btn" data-away="${w.id}" data-v="1">Away</button>`}`) : ''}
        <button class="btn sm line" data-editw="${w.id}">Edit</button></div>`; };
    const away = S.workers.filter(w => w.active && w.away);
    return `
      <div style="display:flex;justify-content:space-between;align-items:end;gap:12px;flex-wrap:wrap"><div><h2>Workers</h2>
      <p class="sub" style="margin-bottom:0">On the workshop screen (Kartech app → Workshop) each worker taps their name to see their job.</p></div>
      <button class="btn" data-addw>+ Add worker</button></div>
      <div class="fm-card today-card"><span class="fm-ic">📋</span><div class="grow"><b>Today: ${S.workers.filter(w => w.here).length} in · ${S.workers.filter(w => w.active && !w.arrived && !w.away).length} not in yet${away.length ? ` · ${away.length} away` : ''}</b><p>The manager ticks each worker in when they arrive (workshop screen → Manager). Only workers who are in get jobs. You can also tap <b>Mark in</b> or <b>Away</b> here.</p></div></div>
      <div class="fm-card anim"><span class="fm-ic">🔑</span><div class="grow"><b>Manager code</b><p>${S.hasCode ? 'Set. The manager uses it on the workshop screen to tick tools and materials.' : 'Not set yet. The manager needs it to open her page on the workshop screen.'}</p></div><button class="btn ${S.hasCode ? 'line' : ''}" data-fmcode>${S.hasCode ? 'Change code' : 'Set code'}</button></div>
      <div class="fm-card"><span class="fm-ic">🪜</span><div class="grow"><b>Workshop steps</b><p>${STAGES.map(x => esc(x.name)).join(' → ')}</p></div><button class="btn line" data-steps>Edit steps</button></div>
      ${STAGES.map(s => { const ws = S.workers.filter(w => w.stage === s.id); return `<p class="section-title">${s.name}${s.grp !== s.name ? ` <span class="grp-tag">${esc(s.grp)}</span>` : ''}</p>
        <div class="list">${ws.length ? ws.map(row).join('') : '<p class="empty">No one in this step yet.</p>'}</div>`; }).join('')}`;
  }


  /* ---------- history: look back at any day ---------- */
  const H = { day: null, worker: '', data: null, loading: false, err: '', mode: 'day', week: null, wdata: null };
  const hm = ts => ts ? new Date(ts).toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit', timeZone:'Africa/Nairobi' }) : '';
  const addDays = (day, n) => { const d = new Date(day + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  async function loadHistory(day){
    H.day = day || H.day || todayStr(); H.loading = true; H.err = ''; if (tab === 'history') render();
    const want = H.day;
    const { data, error } = await db.rpc('ws_history', { p_day: want });
    if (want !== H.day) return;
    H.loading = false;
    if (error){ H.err = errMsg(error); H.data = null; } else H.data = data;
    if (tab === 'history' && !document.querySelector('.scrim')) render();
  }
  function viewHistory(){
    if (!H.day) H.day = todayStr();
    if (H.mode === 'week') return viewWeek();
    const today = todayStr(), isToday = H.day === today, d = H.data && H.data.day && String(H.data.day).slice(0, 10) === H.day ? H.data : null;
    const nm = id => { const w = W(id); return w ? w.name : 'Someone'; };
    const byW = x => !H.worker || x.worker === H.worker;
    const label = new Date(H.day + 'T12:00:00').toLocaleDateString('en-GB', { weekday:'long', day:'numeric', month:'long', year:'numeric' });
    const head = `
      <div style="display:flex;justify-content:space-between;align-items:end;gap:12px;flex-wrap:wrap"><div><h2>History</h2>
      <p class="sub" style="margin-bottom:0">Look back at any day: who came, what got done, which tools and materials went out.</p></div>
      <span style="display:flex;gap:8px;align-items:center">${modeSeg()}<button class="btn line" data-hprint>🖨 Print this day</button></span></div>
      <div class="h-bar anim">
        <button class="btn line h-arrow" data-hday="-1" aria-label="Day before">‹</button>
        <label class="h-date"><b>${isToday ? 'Today' : H.day === addDays(today, -1) ? 'Yesterday' : esc(label.split(' ')[0])}</b><span>${esc(label)}</span><input type="date" id="hDate" value="${H.day}" max="${today}"></label>
        <button class="btn line h-arrow" data-hday="1" ${isToday ? 'disabled' : ''} aria-label="Next day">›</button>
        <select id="hWorker" class="h-who"><option value="">Everyone</option>${S.workers.filter(w => w.active || (d && d.attendance.some(a => a.worker === w.id))).map(w => `<option value="${w.id}" ${H.worker === w.id ? 'selected' : ''}>${esc(w.name)}</option>`).join('')}</select>
        ${isToday ? '' : '<button class="btn sm line" data-hday="today">Back to today</button>'}
      </div>`;
    if (H.err) return head + `<p class="empty">Couldn't load this day. ${esc(H.err)}${/ws_history|function/i.test(H.err) ? '<br>Run <b>update-8-history.sql</b> in Supabase first.' : ''}</p>`;
    if (!d) return head + '<p class="empty">Loading…</p>';

    const att = new Map(d.attendance.map(a => [a.worker, a]));
    const people = S.workers.filter(w => (w.active || att.has(w.id)) && byW({ worker:w.id }));
    const came = d.attendance.filter(a => !a.away), away = d.attendance.filter(a => a.away);
    const jobs = d.jobs.filter(byW), tools = d.tools.filter(byW), mats = d.materials.filter(byW);
    const notBack = tools.filter(t => !t.back);
    const selName = H.worker ? nm(H.worker) : '';
    const log = d.log.filter(g => !H.worker || g.text.includes(selName));
    const alarms = log.filter(g => g.kind === 'alert');

    const sum = (n, l, k) => `<div class="h-sum-c ${k}"><b>${n}</b><span>${l}</span></div>`;
    const sec = (title, n, body, empty) => `<p class="section-title">${title}${n != null ? ` <span class="grp-tag">${n}</span>` : ''}</p>
      <div class="list">${body || `<p class="empty">${empty}</p>`}</div>`;
    const kindTxt = { out:'Given out', back:'Brought back', in:'Came into store', count:'Stock count' };

    return head + `
      <div class="h-sum anim">
        ${H.worker ? sum(att.has(H.worker) ? (att.get(H.worker).away ? 'Away' : hm(att.get(H.worker).at)) : (isToday ? '—' : 'No'), att.has(H.worker) && !att.get(H.worker).away ? 'Came in at' : 'Came in', 'k1')
          : sum(came.length, 'Came in', 'k1') + sum(away.length, 'Away', 'k2')}
        ${sum(jobs.length, 'Jobs finished', 'k3')}
        ${sum(tools.length, 'Tools taken', 'k4')}
        ${sum(notBack.length, isToday ? 'Tools still out' : 'Tools not back', notBack.length && !isToday ? 'k5 bad' : 'k5')}
      </div>

      ${sec('👷 Who came in', came.length + (H.worker ? '' : ' of ' + people.length), people.map(w => { const a = att.get(w.id);
        const chip = a ? (a.away ? '<span class="pill p-normal">Away</span>' : `<span class="in-chip">✓ In ${hm(a.at)}</span>`) : `<span class="pill p-normal">${isToday ? 'Not in yet' : "Didn't come"}</span>`;
        return `<div class="item"><div class="grow"><div class="t">${esc(w.name)}</div><div class="s">${esc(stageName(w.stage))}</div></div>${chip}</div>`; }).join(''), 'No workers.')}

      ${sec('✅ Jobs finished', jobs.length, jobs.map(j => `<div class="item"><span class="h-time">${hm(j.done)}</span><div class="grow"><div class="t">${esc(j.ref)} · ${esc(stageName(j.stage))}</div>
        <div class="s">${esc(nm(j.worker))} · ${j.qty} × ${esc(j.item)}${j.started ? ` · started ${hm(j.started)}` : ''}</div></div></div>`).join(''), 'No jobs finished this day.')}

      ${sec('🔧 Tools', tools.length, tools.map(t => {
        return `<div class="item"><div class="grow"><div class="t">${esc(t.tool)}</div><div class="s">${esc(nm(t.worker))}</div></div>
        <span class="h-tl">Out ${new Date(t.out).toLocaleDateString('en-CA', { timeZone:'Africa/Nairobi' }) === H.day ? hm(t.out) : 'earlier'} → ${t.back ? `<b class="ok">Back ${new Date(t.back).toLocaleDateString('en-CA', { timeZone:'Africa/Nairobi' }) === H.day ? hm(t.back) : 'later'}</b>` : `<b class="${isToday ? '' : 'bad'}">${isToday ? 'Still out' : 'Not back'}</b>`}</span></div>`; }).join('')
        + (d.check && !H.worker ? `<div class="item"><span class="h-time">${hm(d.check.at)}</span><div class="grow"><div class="t">Evening tool check done</div><div class="s">${d.check.missing ? d.check.missing + ' missing' : 'All tools back'}</div></div></div>` : '')
        + d.missing.filter(byW).map(m => `<div class="item"><div class="grow"><div class="t">Missing: ${esc(m.tool)}</div><div class="s">${m.worker ? 'Normally with ' + esc(nm(m.worker)) : ''}${m.found ? ' · found later' : ''}</div></div><span class="pill ${m.found ? 'p-normal' : 'p-attention'}">${m.found ? 'Found' : 'Missing'}</span></div>`).join(''),
        'No tools taken this day.')}

      ${sec('📦 Materials', mats.length, mats.map(m => `<div class="item"><span class="h-time">${hm(m.at)}</span><div class="grow"><div class="t">${esc(m.material)} · ${n2(Math.abs(+m.qty))} ${esc(m.unit)}</div>
        <div class="s">${kindTxt[m.kind] || esc(m.kind)}${m.worker ? ' · ' + esc(nm(m.worker)) : ''}${m.note ? ' · ' + esc(m.note) : ''}</div></div></div>`).join(''), 'No materials moved this day.')}

      ${alarms.length ? sec('🚨 Alarms', alarms.length, alarms.map(g => `<div class="item"><span class="h-time">${hm(g.at)}</span><div class="grow"><div class="t">${esc(g.text)}</div></div></div>`).join(''), '') : ''}

      <details class="h-all"><summary>Everything that happened (${log.length})</summary>
        <div class="list">${log.length ? log.map(g => `<div class="item"><span class="h-time">${hm(g.at)}</span><div class="grow"><div class="s h-${g.kind}">${esc(g.text)}</div></div></div>`).join('') : '<p class="empty">Nothing.</p>'}</div>
      </details>`;
  }

  /* ---------- weekly report (History → Week) ---------- */
  const modeSeg = () => `<div class="seg-pick h-mode"><button type="button" data-hmode="day" class="${H.mode === 'day' ? 'on' : ''}">Day</button><button type="button" data-hmode="week" class="${H.mode === 'week' ? 'on' : ''}">Week</button></div>`;
  const monday = iso => { const d = new Date(iso + 'T12:00:00Z'); const k = (d.getUTCDay() + 6) % 7; return addDays(iso, -k); };
  async function loadWeek(start){
    H.week = start || H.week || monday(todayStr()); H.wdata = null; H.err = ''; if (tab === 'history') render();
    const want = H.week, days = [...Array(7)].map((_, i) => addDays(want, i)).filter(x => x <= todayStr());
    const res = await Promise.all(days.map(x => db.rpc('ws_history', { p_day: x })));
    if (want !== H.week) return;
    const bad = res.find(r => r.error); if (bad){ H.err = errMsg(bad.error); } else H.wdata = res.map(r => r.data);
    if (tab === 'history' && !document.querySelector('.scrim')) render();
  }
  function viewWeek(){
    if (!H.week) H.week = monday(todayStr());
    const thisWeek = H.week === monday(todayStr());
    const end = addDays(H.week, 6), fmt = x => new Date(x + 'T12:00:00').toLocaleDateString('en-GB', { day:'numeric', month:'short' });
    const head = `
      <div style="display:flex;justify-content:space-between;align-items:end;gap:12px;flex-wrap:wrap"><div><h2>Weekly report</h2>
      <p class="sub" style="margin-bottom:0">The whole week at a glance: orders, work done, attendance, materials and tools.</p></div>
      <span style="display:flex;gap:8px;align-items:center">${modeSeg()}<button class="btn line" data-hprint>🖨 Print this week</button></span></div>
      <div class="h-bar anim">
        <button class="btn line h-arrow" data-hweek="-7" aria-label="Week before">‹</button>
        <div class="h-date"><b>${thisWeek ? 'This week' : H.week === addDays(monday(todayStr()), -7) ? 'Last week' : 'Week of ' + fmt(H.week)}</b><span>Mon ${fmt(H.week)} – Sun ${fmt(end)}</span></div>
        <button class="btn line h-arrow" data-hweek="7" ${thisWeek ? 'disabled' : ''} aria-label="Next week">›</button>
        ${thisWeek ? '' : '<button class="btn sm line" data-hweek="now">Back to this week</button>'}
      </div>`;
    if (H.err) return head + `<p class="empty">Couldn't load this week. ${esc(H.err)}</p>`;
    if (!H.wdata) return head + '<p class="empty">Loading…</p>';
    const D = H.wdata, nm = id => W(id)?.name || 'Someone';
    const logs = D.flatMap(d => d.log), jobs = D.flatMap(d => d.jobs);
    const newOrders = logs.filter(g => /^New order KT-/.test(g.text)).length;
    const finished = logs.filter(g => /is finished( and loaded)?\. Ready for delivery/.test(g.text)).length;
    const delivered = logs.filter(g => / delivered to /.test(g.text)).length;
    const alarms = logs.filter(g => g.kind === 'alert');
    const missing = D.flatMap(d => d.missing);
    const checks = D.filter(d => d.check).length;
    const maxJobs = Math.max(1, ...D.map(d => d.jobs.length));
    const bars = D.map(d => { const day = String(d.day).slice(0, 10);
      return `<div class="wk-bar"><i style="height:${Math.round(100 * d.jobs.length / maxJobs)}%"></i><b>${d.jobs.length}</b><span>${new Date(day + 'T12:00:00').toLocaleDateString('en-GB', { weekday:'short' })}</span></div>`; }).join('');
    const people = S.workers.filter(w => w.active || D.some(d => d.attendance.some(a => a.worker === w.id)));
    const ppl = people.map(w => { const came = D.filter(d => d.attendance.some(a => a.worker === w.id && !a.away)).length, away = D.filter(d => d.attendance.some(a => a.worker === w.id && a.away)).length;
      const steps = jobs.filter(j => j.worker === w.id).length;
      return `<div class="item"><div class="grow"><div class="t">${esc(w.name)}</div><div class="s">${esc(stageName(w.stage))}</div></div>
        <span class="wk-n"><b>${came}</b>/${D.length} days</span>${away ? `<span class="pill p-normal">${away} away</span>` : ''}<span class="wk-n"><b>${steps}</b> step${steps === 1 ? '' : 's'}</span></div>`; }).join('');
    const used = {}; D.flatMap(d => d.materials).filter(m => m.kind === 'out' || m.kind === 'back').forEach(m => { const k = m.material + '|' + m.unit; used[k] = (used[k] || 0) - +m.qty; });
    const usedRows = Object.entries(used).filter(([, q]) => q > 0).sort((a, b) => b[1] - a[1]).map(([k, q]) => { const [n, u] = k.split('|'); return `<div class="item"><div class="grow"><div class="t">${esc(n)}</div></div><span class="wk-n"><b>${n2(q)}</b> ${esc(u)}</span></div>`; }).join('');
    const sum = (n, l, k) => `<div class="h-sum-c ${k || ''}"><b>${n}</b><span>${l}</span></div>`;
    return head + `
      <div class="h-sum anim">${sum(newOrders, 'New orders', 'k1')}${sum(jobs.length, 'Steps finished')}${sum(finished, 'Orders finished')}${sum(delivered, 'Delivered')}${sum(missing.length, 'Tools went missing', missing.length ? 'bad' : '')}</div>
      <p class="section-title">✅ Steps finished each day</p><div class="panel wk-bars">${bars}</div>
      <p class="section-title">👷 Attendance and work <span class="grp-tag">${D.length} day${D.length > 1 ? 's' : ''}</span></p><div class="list">${ppl || '<p class="empty">No workers.</p>'}</div>
      <p class="section-title">📦 Materials used</p><div class="list">${usedRows || '<p class="empty">No materials given out this week.</p>'}</div>
      <p class="section-title">🔧 Tools</p><div class="list"><div class="item"><div class="grow"><div class="t">Evening tool check done</div></div><span class="wk-n"><b>${checks}</b>/${D.length} days</span></div>
        ${missing.map(m => `<div class="item"><div class="grow"><div class="t">Missing: ${esc(m.tool)}</div><div class="s">${m.worker ? 'Normally with ' + esc(nm(m.worker)) : ''}</div></div><span class="pill ${m.found ? 'p-normal' : 'p-attention'}">${m.found ? 'Found' : 'Still missing'}</span></div>`).join('')}</div>
      ${alarms.length ? `<details class="h-all"><summary>🚨 Alarms this week (${alarms.length})</summary><div class="list">${alarms.map(g => `<div class="item"><span class="h-time">${new Date(g.at).toLocaleDateString('en-GB', { weekday:'short', timeZone:'Africa/Nairobi' })}</span><div class="grow"><div class="s">${esc(g.text)}</div></div></div>`).join('')}</div></details>` : ''}`;
  }
  document.addEventListener('change', e => {
    if (e.target.id === 'hDate' && e.target.value){ loadHistory(e.target.value > todayStr() ? todayStr() : e.target.value); }
    if (e.target.id === 'hWorker'){ H.worker = e.target.value; render(); }
  });

  /* ---------- morning briefing / evening recap ---------- */
  let dayAt = 0;
  async function loadDay(){
    if (Date.now() - dayAt < 60000) return; dayAt = Date.now();
    const { data, error } = await db.rpc('ws_history', { p_day: todayStr() });
    if (!error && data){ S.day = data; if (tab === 'today' && !document.querySelector('.scrim')) render(); autoBrief(); }
  }
  const nbHour = () => +new Date().toLocaleString('en-GB', { hour:'2-digit', hour12:false, timeZone:'Africa/Nairobi' });
  const plural = (n, one, many) => `${n} ${n === 1 ? one : (many || one + 's')}`;
  function briefing(){
    const h = nbHour(), part = h < 12 ? 'morning' : h < 17 ? 'afternoon' : 'evening';
    const hello = `Good ${part}, Kartech`;
    const t0 = new Date(todayStr() + 'T00:00:00+03:00').getTime(), isToday = x => x && x >= t0;
    const active = S.workers.filter(w => w.active), here = active.filter(w => w.here), away = active.filter(w => w.away);
    const notIn = active.filter(w => !w.here && !w.away);
    const open = S.orders.filter(o => !o.delivered && !orderProgress(o).finished);
    const late = open.filter(o => isLate(o.deadline));
    const dueToday = open.filter(o => o.dl === todayStr());
    const ready = S.tasks.filter(t => t.status === 'queued' && O(t.order) && !O(t.order).delivered);
    const doneToday = S.tasks.filter(t => t.status === 'done' && isToday(t.doneAt));
    const newToday = S.orders.filter(o => isToday(o.createdAt));
    const finishedToday = S.orders.filter(o => { const ts = S.tasks.filter(t => t.order === o.id); return ts.length && ts.every(t => t.status === 'done') && ts.some(t => isToday(t.doneAt)); });
    const deliveredToday = S.orders.filter(o => isToday(o.deliveredAt));
    const web = waitingWeb();
    const byStep = list => { const c = {}; list.forEach(t => c[t.stage] = (c[t.stage] || 0) + 1);
      return Object.entries(c).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([st, n]) => `${n} ${stageName(st).toLowerCase()}`).join(', '); };
    const used = {}; ((S.day && S.day.materials) || []).filter(m => m.kind === 'out' || m.kind === 'back').forEach(m => { const k = m.material + '|' + m.unit; used[k] = (used[k] || 0) - +m.qty; });
    const usedTxt = Object.entries(used).filter(([, q]) => q > 0).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([k, q]) => { const [n, u] = k.split('|'); return `${n2(q)} ${u} ${n.toLowerCase()}`; }).join(', ');
    const toolsOut = S.loans.length, missing = openMissing().length;
    const L = [];   // [icon, text, tone]
    if (part === 'morning'){
      L.push(['👷', active.length ? `${here.length} of ${active.length} workers in so far${notIn.length && notIn.length <= 4 ? ` · not in yet: ${notIn.map(w => w.name).join(', ')}` : ''}${away.length ? ` · ${away.length} away` : ''}` : 'No workers added yet', notIn.length ? 'warn' : 'ok']);
      L.push(['🧰', ready.length ? `${plural(ready.length, 'job')} ready to start${byStep(ready) ? ': ' + byStep(ready) : ''}` : 'No jobs waiting to start', '']);
      if (dueToday.length) L.push(['📅', `Due today: ${dueToday.map(o => o.ref).join(', ')}`, 'warn']);
      const dToday = S.orders.filter(o => !o.delivered && o.delOn === todayStr());
      if (dToday.length) L.push(['🚚', `Deliveries today: ${dToday.map(o => o.ref + (o.delPlace ? ' (' + o.delPlace + ')' : '')).join(', ')}`, 'warn']);
      if (late.length) L.push(['⏰', `${plural(late.length, 'order')} past the deadline`, 'bad']);
      if (web.length) L.push(['🌐', `${plural(web.length, 'website order')} waiting to be sent to the workshop`, 'warn']);
      if (missing) L.push(['🔧', `${plural(missing, 'tool')} still missing from before`, 'bad']);
    } else if (part === 'afternoon'){
      L.push(['✅', doneToday.length ? `${plural(doneToday.length, 'step')} finished so far today: ${byStep(doneToday)}` : 'No steps finished yet today', doneToday.length ? 'ok' : '']);
      L.push(['🆕', `${plural(newToday.length, 'new order')} today`, '']);
      L.push(['▶', `${plural(S.tasks.filter(t => t.status === 'working' || t.status === 'assigned').length, 'job')} in the workshop right now · ${here.length} workers in`, '']);
      if (late.length) L.push(['⏰', `${plural(late.length, 'order')} past the deadline`, 'bad']);
      if (web.length) L.push(['🌐', `${plural(web.length, 'website order')} waiting`, 'warn']);
    } else {
      L.push(['🆕', `${plural(newToday.length, 'new order')} today${newToday.length ? ': ' + newToday.slice(0, 4).map(o => `${o.qty} × ${o.item.toLowerCase()}`).join(', ') : ''}`, newToday.length ? 'ok' : '']);
      L.push(['✅', doneToday.length ? `${plural(doneToday.length, 'step')} finished: ${byStep(doneToday)}` : 'No steps finished today', doneToday.length ? 'ok' : 'warn']);
      if (finishedToday.length) L.push(['🎉', `${plural(finishedToday.length, 'order')} completely finished: ${finishedToday.map(o => o.ref).join(', ')}`, 'ok']);
      if (deliveredToday.length) L.push(['🚚', `${plural(deliveredToday.length, 'order')} delivered`, 'ok']);
      L.push(['👷', `${here.length} of ${active.length} workers came in${away.length ? ` · ${away.length} away` : ''}`, '']);
      if (usedTxt) L.push(['📦', `Used today: ${usedTxt}`, '']);
      L.push(['🔧', toolsOut ? `${plural(toolsOut, 'tool')} still out` + (missing ? ` · ${missing} missing` : '') : 'All tools are back ✓', toolsOut || missing ? 'warn' : 'ok']);
      if (late.length) L.push(['⏰', `${plural(late.length, 'order')} past the deadline`, 'bad']);
      const dTom = S.orders.filter(o => !o.delivered && o.delOn === addDays(todayStr(), 1));
      if (dTom.length) L.push(['🚚', `Deliveries tomorrow: ${dTom.map(o => o.ref + (o.delPlace ? ' (' + o.delPlace + ')' : '')).join(', ')}`, '']);
      L.push(['🌅', ready.length ? `Tomorrow: ${plural(ready.length, 'job')} ready to start` : 'Tomorrow: nothing waiting yet', '']);
    }
    const title = part === 'evening' ? "Here's a recap of today's work" : part === 'morning' ? "Here's today's plan" : 'How today is going';
    const speech = `${hello}. ${title}. ` + L.map(x => x[1].replace(/KT-(\d+)/g, (m, d) => sayRef('KT-' + d)).replace(/ × /g, ' ').replace(/·/g, ',').replace(/✓/g, '')).join('. ') + '.';
    return { part, hello, title, lines: L, speech };
  }
  function briefCard(){
    const b = briefing();
    const ic = { morning:'☀️', afternoon:'🌤️', evening:'🌙' }[b.part];
    return `<div class="brief b-${b.part} anim" style="--i:0"><div class="brief-head"><span class="brief-ic">${ic}</span><div class="grow"><b>${b.title}</b><small>${new Date().toLocaleDateString('en-GB', { weekday:'long', day:'numeric', month:'long' })}</small></div>
      <button class="btn sm brief-say" data-brief>🔊 Read it to me</button></div>
      <ul>${b.lines.map(([i, t, tone]) => `<li class="${tone}"><span>${i}</span>${esc(t)}</li>`).join('')}</ul></div>`;
  }
  function autoBrief(){
    if (VOICE.lang === 'off' || !window.speechSynthesis) return;
    const b = briefing(), key = 'kt-brief-' + todayStr() + '-' + b.part;
    try { if (localStorage.getItem(key)) return; localStorage.setItem(key, '1'); } catch(e){ return; }
    if (b.part === 'afternoon') return;   // only the morning plan and evening recap speak by themselves
    say(b.speech, { interrupt:true });
  }

  function waitingWeb(){
    const linked = new Set(S.orders.map(o => o.src).filter(Boolean));
    return (S.web || []).filter(w => !linked.has(w.id));
  }

  function countUp(el){
    const to = +el.dataset.count, from = +el.dataset.from || 0;
    if (to === from || matchMedia('(prefers-reduced-motion: reduce)').matches){ el.textContent = to; return; }
    const t0 = performance.now(), dur = 700;
    const step = t => { const k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3); el.textContent = Math.round(from + (to - from) * e); if (k < 1) requestAnimationFrame(step); };
    requestAnimationFrame(step);
  }

  function render(){
    document.querySelectorAll('.tabs [data-tab]').forEach(b => b.classList.toggle('on', b.dataset.tab === tab));
    const n = attention().filter(a => a.lvl === 'red').length;
    $('#attnBadge').textContent = n || ''; $('#attnBadge').style.display = n ? '' : 'none';
    const v = $('#view');
    v.innerHTML = tab === 'today' ? viewToday() : tab === 'orders' ? viewOrders() : tab === 'workers' ? viewWorkers() : tab === 'stock' ? viewStock() : tab === 'history' ? viewHistory() : viewWorkshop();
    v.classList.toggle('enter', enter);
    if (enter){ v.querySelectorAll('[data-count]').forEach(countUp); }
    else v.querySelectorAll('.kpi.pop [data-count]').forEach(countUp);
    enter = false;
  }

  /* ---------- clicks ---------- */
  document.addEventListener('click', async e => {
    if (e.target.closest('[data-addw]')) return workerModal();
    if (e.target.closest('[data-brief]')){ if (VOICE.lang === 'off') return toast('Voice is off. Turn it on in Voice & settings.'); return say(briefing().speech, { interrupt:true }); }
    const hm2 = e.target.closest('[data-hmode]'); if (hm2){ H.mode = hm2.dataset.hmode; if (H.mode === 'week') return loadWeek(); render(); return loadHistory(); }
    const hw = e.target.closest('[data-hweek]'); if (hw){ return loadWeek(hw.dataset.hweek === 'now' ? monday(todayStr()) : (x => x > todayStr() ? monday(todayStr()) : x)(addDays(H.week || monday(todayStr()), +hw.dataset.hweek))); }
    const hd = e.target.closest('[data-hday]'); if (hd){ return loadHistory(hd.dataset.hday === 'today' ? todayStr() : (x => x > todayStr() ? todayStr() : x)(addDays(H.day || todayStr(), +hd.dataset.hday))); }
    if (e.target.closest('[data-hprint]')){ document.querySelectorAll('.h-all').forEach(x => x.open = true); return window.print(); }
    const wb = e.target.closest('[data-web]'); if (wb) return webModal(wb.dataset.web);
    const gb = e.target.closest('[data-go]'); if (gb){ const [t, f] = gb.dataset.go.split(':'); tab = t; orderFilter = f || null; enter = true; render(); window.scrollTo(0,0); return; }
    const mvb = e.target.closest('[data-move]'); if (mvb) return moveModal(mvb.dataset.move, mvb.dataset.mat);
    const cb = e.target.closest('[data-cnt]'); if (cb) return countModal(cb.dataset.cnt);
    if (e.target.closest('[data-addmat]')) return materialModal();
    if (e.target.closest('[data-addtool]')) return toolModal();
    if (e.target.closest('[data-fmcode]')) return fmCodeModal();
    if (e.target.closest('[data-steps]')) return stepsModal();
    const gv = e.target.closest('[data-give]'); if (gv) return giveModal(gv.dataset.give);
    const pl = e.target.closest('[data-plan]'); if (pl) return planModal(pl.dataset.plan);
    const dp = e.target.closest('[data-dplan]'); if (dp) return deliveryModal(dp.dataset.dplan);
    const ww = e.target.closest('[data-wwork]'); if (ww && !ww.disabled) return workerWorkModal(ww.dataset.wwork);
    const aw = e.target.closest('[data-away]'); if (aw){ aw.disabled = true; const w = W(aw.dataset.away);
      return act('ws_set_away', { p_worker: aw.dataset.away, p_away: aw.dataset.v === '1' }, aw.dataset.v === '1' ? `${w ? w.name : 'Worker'} is away today` : `${w ? w.name : 'Worker'} is in`); }
    const et = e.target.closest('[data-edittool]'); if (et) return toolModal(et.dataset.edittool);
    const tf = e.target.closest('[data-toolfound]'); if (tf){ tf.disabled = true; return act('ws_tool_found', { p_tool: tf.dataset.toolfound }, 'Marked as back'); }
    const em = e.target.closest('[data-editmat]'); if (em) return materialModal(em.dataset.editmat);
    const sb = e.target.closest('[data-std]'); if (sb) return stdModal(sb.dataset.std);
    if (e.target.closest('#clearFilter')){ orderFilter = null; enter = true; render(); return; }
    if (e.target.closest('#sideSet') || e.target.closest('#mSet')) return settingsModal();
    const ew = e.target.closest('[data-editw]'); if (ew) return workerModal(ew.dataset.editw);
    const b = e.target.closest('[data-tabgo],[data-open],[data-solve],[data-deliver],[data-up],[data-down]');
    if (!b) return;
    if (b.dataset.tabgo){ closeModal(); tab = b.dataset.tabgo; orderFilter = null; enter = true; render(); window.scrollTo(0,0); }
    else if (b.dataset.open) orderModal(b.dataset.open);
    else if (b.dataset.solve){ b.disabled = true; closeModal(); await act('ws_solve', { p_task: b.dataset.solve }, 'Marked solved'); }
    else if (b.dataset.deliver){ b.disabled = true; closeModal(); await act('ws_deliver', { p_order: b.dataset.deliver }, 'Marked delivered'); }
    else if (b.dataset.up || b.dataset.down){ b.disabled = true; await act('ws_move', { p_task: b.dataset.up || b.dataset.down, p_up: !!b.dataset.up }); }
  });

  /* ---------- pop-ups ---------- */
  function closeModal(){ document.querySelector('.scrim')?.remove(); }
  function openModal(html){ closeModal(); const s = document.createElement('div'); s.className = 'scrim'; s.innerHTML = `<div class="modal">${html}</div>`; s.addEventListener('click', e => { if (e.target === s || e.target.closest('[data-x]')) closeModal(); }); document.body.appendChild(s); return s; }


  /* ---------- photos of the work (private, owner only) ---------- */
  const PH_BUCKET = 'kartech-photos';
  async function loadPhotos(orderId){
    const g = $('#phGrid'); if (!g) return;
    const { data, error } = await db.from('ws_photos').select('*').in('order_id', [orderId]).order('id');
    if (!document.body.contains(g)) return;
    if (error){ g.innerHTML = `<span class="ph-empty">${/ws_photos/.test(errMsg(error)) ? 'Run update-12-all.sql in Supabase to turn on photos.' : esc(errMsg(error))}</span>`; return; }
    if (!data.length){ g.innerHTML = '<span class="ph-empty">No photos yet.</span>'; return; }
    let urls = [];
    if (db.storage){ const r = await db.storage.from(PH_BUCKET).createSignedUrls(data.map(x => x.path), 3600); urls = r.data || []; }
    if (!document.body.contains(g)) return;
    g.innerHTML = data.map((x, i) => { const u = urls[i] && urls[i].signedUrl;
      return `<div class="ph">${u ? `<a href="${esc(u)}" target="_blank" rel="noopener"><img src="${esc(u)}" alt="Photo ${i + 1}" loading="lazy"></a>` : '<span class="ph-x">📷</span>'}
        <small>${new Date(x.at).toLocaleDateString('en-GB', { day:'numeric', month:'short' })}</small><button class="ph-rm" data-phrm="${x.id}" aria-label="Remove photo">✕</button></div>`; }).join('');
    g.onclick = async e => { const b = e.target.closest('[data-phrm]'); if (!b) return;
      if (!b.classList.contains('sure')){ b.classList.add('sure'); b.textContent = 'Remove?'; setTimeout(() => { if (document.body.contains(b)){ b.classList.remove('sure'); b.textContent = '✕'; } }, 4000); return; }
      b.disabled = true; const { data: path, error } = await db.rpc('ws_remove_photo', { p_id: +b.dataset.phrm });
      if (error) return toast(errMsg(error));
      if (path && db.storage) await db.storage.from(PH_BUCKET).remove([path]);
      toast('Photo removed'); loadPhotos(orderId); };
  }
  function shrink(file){
    return new Promise((ok, no) => { const img = new Image(), url = URL.createObjectURL(file);
      img.onload = () => { const k = Math.min(1, 1600 / Math.max(img.width, img.height)); const c = document.createElement('canvas');
        c.width = Math.round(img.width * k); c.height = Math.round(img.height * k); c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url); c.toBlob(b => b ? ok(b) : no(new Error('Could not read the photo')), 'image/jpeg', .82); };
      img.onerror = () => { URL.revokeObjectURL(url); no(new Error('That file is not a photo')); }; img.src = url; });
  }
  async function addPhoto(o, file){
    const g = $('#phGrid'); if (g) g.insertAdjacentHTML('beforeend', '<span class="ph-empty" id="phUp">Uploading…</span>');
    try {
      if (!db.storage) throw new Error('Photos need the real Supabase');
      const blob = await shrink(file), path = `${o.id}/${Date.now()}.jpg`;
      const up = await db.storage.from(PH_BUCKET).upload(path, blob, { contentType:'image/jpeg', upsert:false });
      if (up.error) throw up.error;
      const { error } = await db.rpc('ws_add_photo', { p_order: o.id, p_path: path });
      if (error){ await db.storage.from(PH_BUCKET).remove([path]); throw error; }
      toast(`Photo added to ${o.ref}`); loadPhotos(o.id);
    } catch(e){ $('#phUp')?.remove(); toast(/bucket|not found/i.test(errMsg(e)) ? 'Run update-12-all.sql in Supabase to turn on photos.' : errMsg(e)); }
  }

  /* ---------- deliveries ---------- */
  const dayName = iso => { const t = todayStr(); if (iso === t) return 'Today'; if (iso === addDays(t, 1)) return 'Tomorrow';
    return new Date(iso + 'T12:00:00').toLocaleDateString('en-GB', { weekday:'short', day:'numeric', month:'short' }); };
  function deliveriesPanel(){
    const t = todayStr();
    const list = S.orders.filter(o => !o.delivered && (o.delOn || orderProgress(o).finished))
      .sort((a, b) => (a.delOn || '9999') < (b.delOn || '9999') ? -1 : (a.delOn || '9999') > (b.delOn || '9999') ? 1 : a.deadline - b.deadline);
    if (!list.length) return '';
    const row = o => { const fin = orderProgress(o).finished, late = o.delOn && o.delOn < t;
      return `<div class="dl-row ${late ? 'late' : ''}"><span class="dl-day ${o.delOn === t ? 'today' : ''}">${o.delOn ? esc(dayName(o.delOn)) : 'Not planned'}</span>
        <button class="grow dl-info" data-open="${o.id}"><b>${esc(o.ref)} · ${o.qty} × ${esc(o.item)}</b><small>${esc(o.customer)}${o.delPlace ? ' · 📍 ' + esc(o.delPlace) : ''}${o.delNote ? ' · ' + esc(o.delNote) : ''}${fin ? ' · <em class="ok">ready ✓</em>' : ' · still in the workshop'}</small></button>
        <span class="dl-acts"><button class="btn sm line" data-dplan="${o.id}">📅 ${o.delOn ? 'Move' : 'Plan'}</button>${fin ? `<button class="btn sm" data-deliver="${o.id}">Delivered</button>` : ''}</span></div>`; };
    return `<div class="panel dl-panel anim"><div class="p-head"><h3>🚚 Deliveries <span class="count">${list.length}</span></h3></div>${list.map(row).join('')}
      <p class="hint-sm">Move a date (e.g. because of the rains) and website customers see the new date on their tracking page.</p></div>`;
  }
  function deliveryModal(id){
    const o = O(id); if (!o) return;
    const why = ['Rains / roads', 'Customer asked', 'Not ready yet', 'Transport problem'];
    const s = openModal(`<h2>🚚 Delivery · ${esc(o.ref)}</h2>
      <p class="sub" style="margin-top:-6px">${o.qty} × ${esc(o.item)} for ${esc(o.customer)}</p>
      <label class="field"><span>Delivery day</span><input id="dDay" type="date" value="${o.delOn || addDays(todayStr(), 1)}" min="${todayStr()}"></label>
      <label class="field"><span>Where</span><input id="dPlace" value="${esc(o.delPlace)}" placeholder="e.g. Nyeri town, Kanisa Academy"></label>
      <div class="field"><span>Reason${o.delOn ? ' for the change' : ''} (optional, the customer sees it)</span>
        <div class="dl-why">${why.map(w => `<button type="button" class="sp-w ${o.delNote === w ? 'pk' : ''}" data-why="${esc(w)}"><b>${esc(w)}</b></button>`).join('')}</div>
        <input id="dNote" value="${esc(o.delNote)}" placeholder="or type your own" style="margin-top:8px"></div>
      <p id="dErr" class="ferr"></p>
      <div class="actions" style="justify-content:space-between">${o.delOn ? '<button class="btn line" id="dClear">Clear date</button>' : '<span></span>'}
        <span style="display:flex;gap:10px"><button class="btn line" data-x>Cancel</button><button class="btn" id="dSave">Save</button></span></div>`);
    s.addEventListener('click', e => { const b = e.target.closest('[data-why]'); if (!b) return; const on = !b.classList.contains('pk');
      s.querySelectorAll('[data-why]').forEach(x => x.classList.remove('pk')); if (on) b.classList.add('pk'); s.querySelector('#dNote').value = on ? b.dataset.why : ''; });
    const save = async clear => { const { error } = await db.rpc('ws_set_delivery', { p_order: o.id, p_day: clear ? null : (s.querySelector('#dDay').value || null), p_place: s.querySelector('#dPlace').value, p_note: clear ? '' : s.querySelector('#dNote').value });
      if (error){ s.querySelector('#dErr').textContent = /ws_set_delivery/.test(errMsg(error)) ? 'Run update-12-all.sql in Supabase first.' : errMsg(error); return; }
      closeModal(); toast(clear ? `${o.ref}: delivery date cleared` : `${o.ref}: delivery ${dayName(s.querySelector('#dDay').value)}`); await load(); };
    s.querySelector('#dSave').onclick = () => save(false);
    const c = s.querySelector('#dClear'); if (c) c.onclick = () => save(true);
  }

  /* ---------- tap a worker → the work available for them ---------- */
  function workerWorkModal(wid){
    const w = W(wid); if (!w) return;
    const fits = st => st === w.stage || (w.covers || []).includes(st);
    const cur = w.task && T(w.task), curO = cur && O(cur.order);
    const open = S.tasks.filter(t => (t.status === 'queued' || t.status === 'waiting') && O(t.order) && !O(t.order).delivered)
      .sort((a, b) => (a.status === 'queued' ? 0 : 1) - (b.status === 'queued' ? 0 : 1) || URG[O(a.order).urgency] - URG[O(b.order).urgency] || O(a.order).deadline - O(b.order).deadline);
    const mine = open.filter(t => fits(t.stage)), other = open.filter(t => !fits(t.stage));
    const before = t => S.tasks.filter(x => x.order === t.order && x.step < t.step && x.status !== 'done').map(x => stageName(x.stage).toLowerCase());
    const row = t => { const o = O(t.order), mineP = t.planned.includes(w.id), others = t.planned.filter(id => id !== w.id).map(id => W(id)?.name).filter(Boolean);
      const when = t.status === 'queued' ? `<span class="pill p-waiting">Ready now${queue(t.stage).indexOf(t) >= 0 ? ' · #' + (queue(t.stage).indexOf(t) + 1) + ' in line' : ''}</span>` : `<span class="pill p-normal">Later · after ${esc(before(t).slice(-1)[0] || 'the step before')}</span>`;
      const act = mineP ? `<span class="ww-ok">✓ For ${esc(w.name)}</span><button class="btn sm line" data-wwrm="${t.id}">Remove</button>`
        : t.status === 'queued' && w.here && !w.task ? `<button class="btn sm" data-wwnow="${t.id}">Give now</button>`
        : `<button class="btn sm" data-wwadd="${t.id}">${others.length === 1 ? `Add ${esc(w.name)} too` : others.length ? `Give to ${esc(w.name)} instead` : `Give to ${esc(w.name)}`}</button>`;
      return `<div class="ww-job ${mineP ? 'pk' : ''}"><div class="grow"><b>${esc(o.ref)} · ${esc(stageName(t.stage))}</b> ${o.urgency !== 'normal' ? `<span class="pill p-${o.urgency}">${URG_NAME[o.urgency]}</span>` : ''}
        <p>${o.qty} × ${esc(o.item)} · ${esc(o.customer)} · due ${fmtDay(o.deadline)}</p>
        <p class="ww-st">${when}${others.length ? ` <small>👤 ${esc(others.join(' & '))}</small>` : ''}</p></div><div class="ww-act">${act}</div></div>`; };
    const s = openModal(`
      <div style="display:flex;justify-content:space-between;align-items:start;gap:10px"><div><h2 style="margin:0">${esc(w.name)}</h2>
        <p class="sub" style="margin:2px 0 0">${esc(stageName(w.stage))}${w.covers.length ? ' · also ' + w.covers.map(c => stageName(c).toLowerCase()).join(', ') : ''}</p></div>
        ${w.here ? `<span class="in-chip">✓ In${w.arrivedAt ? ' ' + new Date(w.arrivedAt).toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' }) : ''}</span>` : `<span class="pill p-normal">${w.away ? 'Away today' : 'Not in yet'}</span>`}</div>
      <div class="ww-now">${cur && curO ? `<b>Now:</b> ${esc(curO.ref)} · ${esc(stageName(cur.stage))} · ${curO.qty} × ${esc(curO.item)} <span class="pill p-${cur.status === 'working' ? 'working' : 'notstarted'}">${cur.status === 'working' ? 'Working' : 'Not started'}</span>`
        : w.here ? `<b>Free right now.</b> Give him a job that is ready and it shows on the workshop screen straight away.` : `<b>Not in yet.</b> Work you give ${esc(w.name)} starts when the manager ticks him in.`}</div>
      <p class="section-title">${esc(stageName(w.stage))} work${mine.length ? ` <span class="grp-tag">${mine.length}</span>` : ''}</p>
      <div class="ww-list">${mine.map(row).join('') || '<p class="empty" style="padding:10px">No work waiting for this step.</p>'}</div>
      ${other.length ? `<details class="pm-more"><summary>Other steps (${other.length}): if ${esc(w.name)} is stepping up</summary><div class="ww-list">${other.map(row).join('')}</div></details>` : ''}
      <p class="hint-sm">Jobs you give him line up in order: when he finishes one, the next shows on his screen. Busy? It waits for him.</p>
      <p id="wwErr" class="ferr"></p>
      <div class="actions"><button class="btn line" data-x>Close</button></div>`);
    s.addEventListener('click', async e => {
      const b = e.target.closest('[data-wwnow],[data-wwadd],[data-wwrm]'); if (!b) return; b.disabled = true;
      const t = T(b.dataset.wwnow || b.dataset.wwadd || b.dataset.wwrm); if (!t) return;
      let r;
      if (b.dataset.wwnow){ r = await db.rpc('ws_plan_step', { p_task: t.id, p_people: [w.id] }); if (!r.error && !T(t.id)?.worker) r = await db.rpc('ws_give_task', { p_task: t.id, p_worker: w.id }); }
      else if (b.dataset.wwrm) r = await db.rpc('ws_plan_step', { p_task: t.id, p_people: t.planned.filter(id => id !== w.id) });
      else { const keep = t.planned.filter(id => id !== w.id); r = await db.rpc('ws_plan_step', { p_task: t.id, p_people: keep.length === 1 ? [keep[0], w.id] : [w.id] }); }
      if (r.error && !/already|busy/i.test(errMsg(r.error))){ b.disabled = false; s.querySelector('#wwErr').textContent = /ws_plan_step/.test(errMsg(r.error)) ? 'Run update-11-together.sql in Supabase first.' : errMsg(r.error); return; }
      const o = O(t.order); toast(b.dataset.wwrm ? `Removed from ${o.ref}` : `${o.ref} · ${stageName(t.stage)} → ${w.name}`);
      await load(); workerWorkModal(w.id);
    });
  }

  /* ---------- pick who does one step (any time, even before it's ready) ---------- */
  function planModal(taskId){
    const t = T(taskId), o = t && O(t.order); if (!o) return;
    const st = t.stage;
    const state = w => { if (w.away) return 'away'; if (!w.here) return 'not in'; const x = w.task && T(w.task), xo = x && O(x.order); return xo ? 'on ' + xo.ref : 'free'; };
    const mine = S.workers.filter(w => w.active && (w.stage === st || (w.covers || []).includes(st))).sort((a, b) => (b.stage === st) - (a.stage === st) || a.name.localeCompare(b.name));
    const rest = S.workers.filter(w => w.active && !mine.includes(w)).sort((a, b) => a.name.localeCompare(b.name));
    const chip = w => `<button type="button" class="sp-w ${t.planned.includes(w.id) ? 'pk' : ''}" data-w="${w.id}"><b>${esc(w.name)}</b><small>${w.stage !== st ? esc(stageName(w.stage)) + ' · ' : ''}${state(w)}</small></button>`;
    const s = openModal(`
      <h2>${esc(o.ref)} · ${esc(stageName(st))}</h2>
      <p class="sub" style="margin-top:-6px">Who does this step? Tap 1 or 2 people. When the step is ready it goes straight to them.</p>
      <div class="sp-who pm">${mine.map(chip).join('') || '<span class="sp-any">No one does this step yet</span>'}</div>
      ${rest.length ? `<details class="pm-more"><summary>Someone from another step</summary><div class="sp-who pm">${rest.map(chip).join('')}</div></details>` : ''}
      <p class="hint-sm" id="pmHint">${t.planned.length ? '' : 'Nobody picked = whoever is free.'}</p>
      <p id="pmErr" style="color:var(--red);min-height:20px;font-size:13px"></p>
      <div class="actions"><button class="btn line" data-x>Cancel</button><button class="btn" id="pmSave">Save</button></div>`);
    s.addEventListener('click', e => { const b = e.target.closest('.sp-w'); if (!b) return;
      if (!b.classList.contains('pk')){ const pk = [...s.querySelectorAll('.sp-w.pk')]; if (pk.length >= 2) pk[0].classList.remove('pk'); }
      b.classList.toggle('pk'); s.querySelector('#pmHint').textContent = s.querySelector('.sp-w.pk') ? '' : 'Nobody picked = whoever is free.'; });
    s.querySelector('#pmSave').onclick = async () => { const btn = s.querySelector('#pmSave'); btn.disabled = true; btn.textContent = 'Saving…';
      const ids = [...s.querySelectorAll('.sp-w.pk')].map(b => b.dataset.w);
      const { error } = await db.rpc('ws_plan_step', { p_task: t.id, p_people: ids });
      if (error){ btn.disabled = false; btn.textContent = 'Save'; s.querySelector('#pmErr').textContent = /ws_plan_step/.test(errMsg(error)) ? 'Run update-11-together.sql in Supabase first.' : errMsg(error); return; }
      const names = ids.map(id => W(id)?.name).filter(Boolean).join(' & ');
      closeModal(); toast(names ? `${stageName(st)} on ${o.ref}: ${names}` : `${stageName(st)} on ${o.ref}: anyone free`); await load(); orderModal(o.id); };
  }

  /* ---------- steps + who does each one (new order / edit) ---------- */
  // stages: ticked steps (true = all) · people: {stage:[ids]} · lock: {stage:'done'|'started'}
  function stepPeople(stages, people, lock, together){
    people = people || {}; lock = lock || {}; together = together || [];
    const can = st => S.workers.filter(w => w.active && (w.stage === st || (w.covers || []).includes(st)))
      .sort((a, b) => (b.stage === st) - (a.stage === st) || a.name.localeCompare(b.name));
    const state = w => { if (w.away) return 'away'; if (!w.here) return 'not in'; const t = w.task && T(w.task), o = t && O(t.order); return o ? 'on ' + o.ref : 'free'; };
    return `<div class="sp">${stepGroups().map(g => `<p class="sp-g">${esc(g.grp)}</p>${g.steps.map(st => {
      const on = stages === true || (stages || []).includes(st.id) || !!lock[st.id], l = lock[st.id], picked = people[st.id] || [], ws = can(st.id);
      return `<div class="sp-row ${on ? 'on' : ''} ${l ? 'lk' : ''}" data-st="${st.id}">
        <label class="sp-step"><input type="checkbox" class="spStage" value="${st.id}" ${on ? 'checked' : ''} ${l ? 'disabled' : ''}><span>${esc(st.name)}</span>${l ? `<small>${l === 'done' ? '✓ done' : 'in progress'}</small>` : ''}</label>
        <div class="sp-who">${l === 'done' ? '' : ws.length ? ws.map(w => `<button type="button" class="sp-w ${picked.includes(w.id) ? 'pk' : ''}" data-w="${w.id}"><b>${esc(w.name)}</b><small>${w.stage !== st.id ? 'can cover · ' : ''}${state(w)}</small></button>`).join('')
          + `<span class="sp-any">${picked.length ? '' : 'Anyone free'}</span>` : '<span class="sp-any">No workers for this step yet</span>'}</div>
        <label class="sp-tog"><input type="checkbox" class="spTog" ${together.includes(st.id) ? 'checked' : ''} ${l ? 'disabled' : ''}> ⇉ Same time as the step above</label>
      </div>`; }).join('')}`).join('')}
      <p class="hint-sm">Tick the steps. Under each one, tap who does it, 1 or 2 people. Nobody picked = whoever is free. Tick <b>⇉ Same time</b> when a step can start together with the one above it.</p></div>`;
  }
  function spFirst(root){ const rows = [...root.querySelectorAll('.sp-row')]; const f = rows.find(r => r.querySelector('.spStage').checked); rows.forEach(r => r.classList.toggle('first', r === f)); }
  function bindStepPeople(root){
    spFirst(root);
    root.addEventListener('change', e => { const c = e.target.closest('.spStage'); if (!c) return; c.closest('.sp-row').classList.toggle('on', c.checked); spFirst(root); });
    root.addEventListener('click', e => { const b = e.target.closest('.sp-w'); if (!b) return;
      const row = b.closest('.sp-row'); const box = row.querySelector('.spStage');
      if (!box.checked && !box.disabled){ box.checked = true; row.classList.add('on'); spFirst(root); }
      if (!b.classList.contains('pk')){ const pk = [...row.querySelectorAll('.sp-w.pk')]; if (pk.length >= 2) pk[0].classList.remove('pk'); }
      b.classList.toggle('pk');
      const any = row.querySelector('.sp-any'); if (any) any.textContent = row.querySelector('.sp-w.pk') ? '' : 'Anyone free'; });
  }
  function readStepPeople(root){
    const stages = [], people = {}, together = [];
    root.querySelectorAll('.sp-row').forEach(r => { const box = r.querySelector('.spStage'); if (!box.checked) return;
      stages.push(box.value); people[box.value] = [...r.querySelectorAll('.sp-w.pk')].map(b => b.dataset.w);
      if (stages.length > 1 && r.querySelector('.spTog').checked) together.push(box.value); });
    return { stages, people, together };
  }

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
      <div class="field"><span>Steps and who does them</span>${stepPeople(true)}</div>
      <p id="fErr" style="color:var(--red);min-height:20px;font-size:13px"></p>
      <div class="actions"><button class="btn line" data-x>Cancel</button><button class="btn" id="fSave">Add to workshop</button></div>`);
    let urg = 'normal'; bindStepPeople(s);
    s.querySelector('#fUrg').addEventListener('click', e => { const b = e.target.closest('[data-u]'); if (!b) return; urg = b.dataset.u; s.querySelectorAll('#fUrg button').forEach(x => x.classList.toggle('on', x === b)); });
    s.querySelector('#fSave').onclick = async () => {
      const customer = s.querySelector('#fCust').value.trim(), item = s.querySelector('#fItem').value.trim();
      const qty = parseInt(s.querySelector('#fQty').value, 10) || 0;
      const { stages, people, together } = readStepPeople(s);
      if (!customer || !item || qty < 1) return s.querySelector('#fErr').textContent = 'Fill in the customer, what, and how many.';
      if (!stages.length) return s.querySelector('#fErr').textContent = 'Pick at least one step.';
      const btn = s.querySelector('#fSave'); btn.disabled = true; btn.textContent = 'Adding…';
      const { data, error } = await db.rpc('ws_create_order', { p: { customer, item, qty, deadline: s.querySelector('#fDate').value || null, urgency: urg, stages, people, together, notes: s.querySelector('#fNote').value.trim() } });
      if (error){ btn.disabled = false; btn.textContent = 'Add to workshop'; s.querySelector('#fErr').textContent = errMsg(error); return; }
      closeModal(); tab = 'orders'; await load();
      const o = S.orders.find(x => x.ref === data); const t = o && S.tasks.find(x => x.order === o.id && x.worker);
      const first = o && S.tasks.filter(x => x.order === o.id).sort((a, b) => a.step - b.step)[0];
      const wait = first && !first.worker && first.planned.length ? first.planned.map(id => W(id)?.name).filter(Boolean).join(' & ') : '';
      toast(t ? `${data} added. ${taskNames(t)} has it now.` : wait ? `${data} added. Waiting for ${wait} to be free.` : `${data} added to the line.`);
    };
    setTimeout(() => s.querySelector('#fCust').focus(), 50);
  }


  /* ---------- edit / delete an order (typed something wrong) ---------- */
  function editOrderModal(id){
    const o = O(id); if (!o) return;
    const ts = S.tasks.filter(t => t.order === o.id);
    const lock = {}; ts.forEach(t => { if (['done','assigned','working'].includes(t.status)) lock[t.stage] = t.status === 'done' ? 'done' : 'started'; });
    const s = openModal(`
      <h2>Edit ${esc(o.ref)}</h2>
      <p class="sub" style="margin-top:-6px">Fix anything that was typed wrong. The workshop sees the change straight away.</p>
      <label class="field"><span>Customer</span><input id="eCust" value="${esc(o.customer)}" autocomplete="off"></label>
      <div class="row2">
        <label class="field"><span>What</span><input id="eItem" value="${esc(o.item)}" autocomplete="off"></label>
        <label class="field"><span>How many</span><input id="eQty" type="number" min="1" value="${o.qty}"></label>
      </div>
      <label class="field"><span>Deadline</span><input id="eDate" type="date" value="${o.dl}"></label>
      <label class="field"><span>Note for the workshop</span><textarea id="eNote" rows="2">${esc(o.notes || '')}</textarea></label>
      <div class="field"><span>How urgent</span><div class="seg-pick" id="eUrg">
        ${['normal','high','urgent'].map(u => `<button type="button" data-u="${u}" class="${o.urgency === u ? 'on' : ''}">${URG_NAME[u]}</button>`).join('')}</div></div>
      <div class="field"><span>Steps and who does them</span>${stepPeople(o.stages, Object.fromEntries(ts.map(t => [t.stage, t.planned])), lock, ts.filter(t => t.withPrev).map(t => t.stage))}
        ${Object.keys(lock).length ? '<p class="hint-sm">Steps already done or being worked on can\'t be removed.</p>' : ''}</div>
      <p id="eErr" style="color:var(--red);min-height:20px;font-size:13px"></p>
      <div class="actions" style="justify-content:space-between">
        <button class="btn red line" id="eDel">🗑 Delete order</button>
        <span style="display:flex;gap:10px"><button class="btn line" data-x>Cancel</button><button class="btn" id="eSave">Save changes</button></span>
      </div>`);
    let urg = o.urgency; bindStepPeople(s);
    s.querySelector('#eUrg').addEventListener('click', e => { const b = e.target.closest('[data-u]'); if (!b) return; urg = b.dataset.u; s.querySelectorAll('#eUrg button').forEach(x => x.classList.toggle('on', x === b)); });
    s.querySelector('#eSave').onclick = async () => {
      const customer = s.querySelector('#eCust').value.trim(), item = s.querySelector('#eItem').value.trim();
      const qty = parseInt(s.querySelector('#eQty').value, 10) || 0;
      const { stages, people, together } = readStepPeople(s);
      if (!customer || !item || qty < 1) return s.querySelector('#eErr').textContent = 'Fill in the customer, what, and how many.';
      if (!stages.length) return s.querySelector('#eErr').textContent = 'Pick at least one step.';
      const btn = s.querySelector('#eSave'); btn.disabled = true; btn.textContent = 'Saving…';
      const { error } = await db.rpc('ws_edit_order', { p: { id: o.id, customer, item, qty, deadline: s.querySelector('#eDate').value || null, urgency: urg, stages, people, together, notes: s.querySelector('#eNote').value.trim() } });
      if (error){ btn.disabled = false; btn.textContent = 'Save changes'; s.querySelector('#eErr').textContent = /ws_edit_order/.test(errMsg(error)) ? 'Run update-9-edit-orders.sql in Supabase first.' : errMsg(error); return; }
      closeModal(); toast(`${o.ref} updated`); await load(); orderModal(o.id);
    };
    const del = s.querySelector('#eDel'); let sure = false;
    del.onclick = async () => {
      if (!sure){ sure = true; del.classList.remove('line'); del.textContent = 'Tap again to delete';
        s.querySelector('#eErr').textContent = `This removes ${o.ref} from the workshop. Anyone working on it gets their next job.`; setTimeout(() => { if (document.body.contains(del) && sure){ sure = false; del.classList.add('line'); del.textContent = '🗑 Delete order'; s.querySelector('#eErr').textContent = ''; } }, 5000); return; }
      del.disabled = true; del.textContent = 'Deleting…';
      const { error } = await db.rpc('ws_delete_order', { p_order: o.id });
      if (error){ del.disabled = false; del.textContent = '🗑 Delete order'; s.querySelector('#eErr').textContent = /ws_delete_order/.test(errMsg(error)) ? 'Run update-9-edit-orders.sql in Supabase first.' : errMsg(error); return; }
      closeModal(); toast(`${o.ref} deleted`); await load();
    };
  }

  function webModal(id){
    const w = (S.web || []).find(x => x.id === id); if (!w) return;
    const d = new Date(); d.setDate(d.getDate() + 7);
    const items = w.items || [];
    const s = openModal(`
      <div style="display:flex;justify-content:space-between;align-items:start;gap:10px"><div><h2 style="margin:0">${esc(w.order_no)}</h2><p class="sub" style="margin:2px 0 0">From the website · ${ago(new Date(w.created_at).getTime())}</p></div><span class="pill p-web">🌐 Website</span></div>
      <div class="webcust">
        <b>${esc(w.customer_name)}</b>${w.phone ? ` · <a href="tel:${esc(w.phone)}">${esc(w.phone)}</a>` : ''}<br>
        <span style="color:var(--muted)">${esc(w.fulfilment || '')}${w.delivery_location ? ' · ' + esc(w.delivery_location) : ''}</span>
        ${w.notes ? `<p style="margin:8px 0 0">📝 ${esc(w.notes)}</p>` : ''}
      </div>
      <div class="field"><span>What they ordered</span><div class="weblist">${items.map(i => `<div><b>${i.qty} ×</b> ${esc(i.name)}${i.finish ? ` <span style="color:var(--muted)">(${esc(i.finish)})</span>` : ''}</div>`).join('')}</div>
        <small style="color:var(--muted)">${items.length > 1 ? `Each line becomes its own job in the workshop (${items.length} jobs).` : 'This becomes one job in the workshop.'}</small></div>
      <label class="field"><span>Deadline</span><input id="wDate" type="date" value="${d.toLocaleDateString('en-CA')}"></label>
      <div class="field"><span>How urgent</span><div class="seg-pick" id="wUrg">
        <button type="button" data-u="normal" class="on">Normal</button><button type="button" data-u="high">High</button><button type="button" data-u="urgent">Urgent</button></div></div>
      <div class="field"><span>Steps it needs</span>${stepChecks(true)}</div>
      <label class="field"><span>Note for the workshop (optional)</span><textarea id="wNote" rows="2" placeholder="e.g. Black frames, red seats."></textarea></label>
      <p style="font-size:13px;color:var(--muted);margin:0">The customer's tracking page will show each step live as the workers finish them.</p>
      <p id="wErr" style="color:var(--red);min-height:20px;font-size:13px"></p>
      <div class="actions"><button class="btn line" data-x>Not now</button><button class="btn" id="wSave">Send to workshop</button></div>`);
    let urg = 'normal';
    s.querySelector('#wUrg').addEventListener('click', e => { const b = e.target.closest('[data-u]'); if (!b) return; urg = b.dataset.u; s.querySelectorAll('#wUrg button').forEach(x => x.classList.toggle('on', x === b)); });
    s.querySelector('#wSave').onclick = async () => {
      const stages = [...s.querySelectorAll('.checks input:checked')].map(x => x.value);
      if (!stages.length) return s.querySelector('#wErr').textContent = 'Pick at least one step.';
      const btn = s.querySelector('#wSave'); btn.disabled = true; btn.textContent = 'Sending…';
      const { data, error } = await db.rpc('ws_from_website', { p: { order_id: w.id, stages, deadline: s.querySelector('#wDate').value || null, urgency: urg, notes: s.querySelector('#wNote').value.trim() } });
      if (error){ btn.disabled = false; btn.textContent = 'Send to workshop'; s.querySelector('#wErr').textContent = errMsg(error); return; }
      closeModal(); tab = 'orders'; await load();
      toast(`${w.order_no} is in the workshop as ${data}`);
    };
  }

  function orderModal(id){
    const o = O(id); if (!o) return; const p = orderProgress(o);
    const ts = o.stages.map(st => S.tasks.find(t => t.order === o.id && t.stage === st)).filter(Boolean);
    const lbl = t => t.status === 'done' ? ['done','Done'] : t.status === 'working' ? (t.problem ? ['attention','Problem'] : ['working','In progress']) : t.status === 'assigned' ? ['notstarted','Given, not started'] : t.status === 'queued' ? ['waiting', `#${queue(t.stage).indexOf(t) + 1} in line`] : ['normal','Later'];
    openModal(`
      <div style="display:flex;justify-content:space-between;align-items:start;gap:10px"><div><h2 style="margin:0">${o.ref}</h2><p class="sub" style="margin:2px 0 0">${esc(o.customer)}</p></div><span class="pill p-${o.urgency}">${URG_NAME[o.urgency]}</span></div>
      <p style="margin:14px 0 4px;font-size:17px"><b>${o.qty} × ${esc(o.item)}</b></p>
      ${o.srcNo ? `<p style="margin:4px 0;font-size:13px;color:var(--muted)">🌐 Website order ${esc(o.srcNo)} · the customer sees these steps live on their tracking page</p>` : ''}
      ${o.notes ? `<p style="margin:6px 0;padding:10px 12px;background:#fff;border:1px solid var(--line);border-radius:6px">📝 ${esc(o.notes)}</p>` : ''}
      <p class="${!p.finished && isLate(o.deadline) ? 'due late' : ''}" style="text-align:left">Deadline: ${fmtDay(o.deadline)}</p>
      ${!o.delivered ? `<div class="dl-line">🚚 ${o.delOn ? `Delivery <b>${esc(dayName(o.delOn))}</b>${o.delPlace ? ' · ' + esc(o.delPlace) : ''}${o.delNote ? ` <small>(${esc(o.delNote)})</small>` : ''}` : 'No delivery day yet'} <button class="btn sm line" data-dplan="${o.id}">${o.delOn ? 'Move' : 'Plan delivery'}</button></div>` : ''}
      <div style="margin:14px 0">${pipe(o)}</div>
      ${(() => { const use = orderUse(o); return use.length ? `<p class="section-title">Materials</p><div class="steps">${use.map(r => { const m = M(r.mat);
        return `<div class="step"><div style="flex:1"><b>${esc(m.name)}</b><div style="color:var(--muted);font-size:13px">Given ${n2(r.given)} ${esc(m.unit)}${r.normal != null ? ` · normal ${n2(r.normal)} ${esc(m.unit)}` : ''}</div></div>${r.over ? '<span class="pill p-attention">More than normal</span>' : r.normal != null ? '<span class="pill p-working">OK</span>' : ''}</div>`; }).join('')}</div>` : ''; })()}
      <div class="ph-box"><div class="ph-head"><b>📷 Photos</b>${p.finished && !o.delivered ? '<small>Take a photo of the finished work before it leaves</small>' : ''}
        <label class="btn sm line ph-add">＋ Add photo<input type="file" accept="image/*" capture="environment" id="phIn" hidden></label></div>
        <div class="ph-grid" id="phGrid"><span class="ph-empty">Loading…</span></div></div>
      <p class="section-title">Steps</p>
      <div class="steps">${ts.map(t => { const [k, l] = lbl(t); const w = t.worker && W(t.worker); const plan = t.planned.map(id => W(id)?.name).filter(Boolean).join(' & '); return `<div class="step"><div style="flex:1"><b>${stageName(t.stage)}</b>${t.withPrev ? ' <span class="tog-tag">⇉ same time as above</span>' : ''}<div style="color:var(--muted);font-size:13px">${w ? esc(taskNames(t)) + (x => x ? ` · ${esc(x)} joins when free` : '')(t.planned.filter(id => !S.workers.some(v => v.id === id && v.task === t.id)).map(id => W(id)?.name).filter(Boolean).join(' & ')) : plan ? '👤 For ' + esc(plan) : 'Whoever is free'}${t.problem ? ` · ⚠ ${esc(t.problem.reason)}` : ''}</div></div><span class="pill p-${k}">${l}</span>${t.problem ? `<button class="btn sm" data-solve="${t.id}">Solved</button>` : ''}${o.delivered || t.status === 'done' ? '' : t.worker ? `<button class="btn sm line" data-give="${t.id}">Change</button>` : `<button class="btn sm line" data-plan="${t.id}">👤 ${t.planned.length ? 'Change' : 'Pick'}</button>`}</div>`; }).join('')}</div>
      ${!o.delivered && o.urgency !== 'urgent' && !p.finished ? `<p style="margin-top:14px;font-size:13px;color:var(--muted)">Customer pushing? Make it urgent and it jumps to the front of every line. No one's current job gets interrupted.</p>` : ''}
      <div class="actions">
        ${!o.delivered && o.urgency !== 'urgent' && !p.finished ? `<button class="btn red" id="mkUrgent">Make urgent</button>` : ''}
        ${p.finished && !o.delivered ? `<button class="btn" data-deliver="${o.id}">Mark delivered</button>` : ''}
        ${!o.delivered ? `<button class="btn line" id="edOrder">✏️ Edit</button>` : ''}
        <button class="btn line" data-x>Close</button>
      </div>`);
    const eb = $('#edOrder'); if (eb) eb.onclick = () => editOrderModal(o.id);
    loadPhotos(o.id);
    const phIn = $('#phIn'); if (phIn) phIn.onchange = () => { const f = phIn.files && phIn.files[0]; if (f) addPhoto(o, f); phIn.value = ''; };
    const u = $('#mkUrgent');
    if (u) u.onclick = async () => { u.disabled = true; closeModal(); await act('ws_make_urgent', { p_order: o.id }, `${o.ref} is now urgent`); };
  }

  /* =====================================================================
     STOCK: raw materials. Only the owner changes stock.
     ===================================================================== */
  const M = id => S.mats.find(m => m.id === id);
  const n2 = x => (Math.round(x * 100) / 100).toLocaleString('en-KE');
  const prodKey = p => String(p || '').replace(/\s*\(.*\)\s*$/, '').trim().toLowerCase();
  // given (out minus returned) per order + material, and the normal amount
  function orderUse(o){
    const by = {};
    S.moves.filter(x => x.order === o.id && (x.kind === 'out' || x.kind === 'back')).forEach(x => { by[x.mat] = (by[x.mat] || 0) - x.qty; });
    S.std.filter(s => s.product === prodKey(o.item)).forEach(s => { if (!(s.mat in by)) by[s.mat] = 0; });
    return Object.entries(by).map(([mat, given]) => { const s = S.std.find(z => z.product === prodKey(o.item) && z.mat === mat);
      const normal = s ? s.per * o.qty : null; return { mat, given, normal, over: normal != null && given > normal * 1.1 }; })
      .filter(r => M(r.mat));
  }
  function watchList(){
    const out = [];
    S.orders.forEach(o => orderUse(o).filter(r => r.over).forEach(r => { const m = M(r.mat);
      out.push({ lvl:'red', title:`${o.ref}: ${Math.round(100 * (r.given - r.normal) / r.normal)}% more ${m.name} than normal`, sub:`Given ${n2(r.given)} ${m.unit}, normal for ${o.qty} × ${o.item} is ${n2(r.normal)} ${m.unit}`, order:o.id }); }));
    S.moves.filter(x => x.kind === 'count' && x.qty < 0 && Date.now() - x.at < 30 * 864e5).forEach(x => { const m = M(x.mat); if (!m) return;
      out.push({ lvl:'red', title:`${n2(-x.qty)} ${m.unit} of ${m.name} missing`, sub:`Found at the store count · ${ago(x.at)}` }); });
    return out;
  }
  /* ---------- TOOLS: evening check by the manager ---------- */
  const TL = id => S.tools.find(t => t.id === id);
  const todayStr = () => new Date().toLocaleDateString('en-CA', { timeZone:'Africa/Nairobi' });
  const checkDue = () => { const [h, m] = (KT_CONFIG.toolCheckAt || '18:30').split(':').map(Number);
    const n = new Date(new Date().toLocaleString('en-US', { timeZone:'Africa/Nairobi' })); return n.getHours() * 60 + n.getMinutes() >= h * 60 + m + 15; };
  const openMissing = () => S.toolMissing.filter(x => !x.found);
  function toolsPanel(){
    const done = S.toolChecks.find(c => c.day === todayStr());
    const miss = openMissing();
    const since = Date.now() - 30 * 864e5;
    const per = {}; S.toolMissing.filter(x => new Date(x.since).getTime() >= since && x.worker).forEach(x => { per[x.worker] = (per[x.worker] || 0) + 1; });
    const status = done ? (done.missing ? `<span class="hp h-late">Tonight: ${done.missing} missing</span>` : `<span class="hp h-ready">Tonight: all back ✓</span>`)
      : `<span class="hp ${checkDue() ? 'h-risk' : 'h-track'}">Tonight's check: ${checkDue() ? 'not done yet' : 'at ' + (KT_CONFIG.toolCheckAt || '18:30')}</span>`;
    return `<div class="panel anim tools" style="--i:1"><div class="p-head"><h3>🔧 Tools</h3><span class="st-btns">${status}<button class="link" data-addtool>+ Add tool</button></span></div>
      <p class="sub" style="font-size:13px;margin-bottom:6px">The manager ticks who takes which tool on the workshop screen (Manager page) and checks them all at ${KT_CONFIG.toolCheckAt || '18:30'}.</p>
      ${S.tools.filter(t => t.active).length ? `<div class="tool-grid">${S.tools.filter(t => t.active).map(t => { const m = miss.find(x => x.tool === t.id); const w = t.worker && W(t.worker);
        return `<div class="tool ${m ? 'missing' : ''}"><button class="tool-name" data-edittool="${t.id}"><b>${esc(t.name)}</b><small>${t.stages.length ? t.stages.map(x => esc(stageName(x))).join(', ') : w ? 'Normally ' + esc(w.name) : 'No trade set'}</small></button>
          ${!m && S.loans.find(l => l.tool === t.id) ? (() => { const l = S.loans.find(z => z.tool === t.id), lw = W(l.worker); return `<span class="tool-out">With ${esc(lw ? lw.name : 'someone')}<small>since ${new Date(l.at).toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' })}</small></span>`; })() : ''}
          ${m ? `<span class="tool-st">Missing since ${fmtDay(new Date(m.since + 'T12:00')).replace(/^(Today|Yesterday)$/, x => x.toLowerCase())}</span><button class="btn sm" data-toolfound="${t.id}">It's back</button>` : S.loans.find(l => l.tool === t.id) ? '' : '<span class="tool-ok">✓ In</span>'}</div>`; }).join('')}</div>`
        : '<p class="empty">No tools yet. Add each one with its painted number, e.g. "Grinder 1", "Grinder 2", "Welding machine".</p>'}
      ${Object.keys(per).length ? `<p class="tool-hist"><b>Missing in the last 30 days:</b> ${Object.entries(per).sort((a,b) => b[1] - a[1]).map(([wid, c]) => `${esc((W(wid) || {}).name || 'Unknown')} ${c}×`).join(' · ')}</p>` : ''}
    </div>`;
  }
  function giveModal(taskId){
    const t = T(taskId); if (!t) return; const o = O(t.order);
    const here = S.workers.filter(w => w.here);
    const fits = here.filter(w => w.stage === t.stage || w.covers.includes(t.stage));
    const others = here.filter(w => !fits.includes(w));
    const btn = w => { const wt = w.task && T(w.task), wo = wt && O(wt.order); const mine = t.worker === w.id;
      return `<button class="give-w ${w.task && !mine ? 'busy' : ''}" data-gw="${w.id}" ${w.task && !mine ? 'disabled' : ''}><span class="av">${esc(w.name.charAt(0))}</span><span><b>${esc(w.name)}</b><small>${mine ? 'Has it now' : wt ? `Busy on ${wo ? wo.ref : 'a job'} (${stageName(wt.stage)})` : 'Free · ' + esc(stageName(w.stage))}</small></span></button>`; };
    const s = openModal(`<h2>Who should do this?</h2>
      <p class="sub"><b>${o ? o.ref : ''} · ${stageName(t.stage)}</b>${o ? ` · ${o.qty} × ${esc(o.item)}` : ''}</p>
      <p class="section-title" style="margin-top:4px">${esc(stageName(t.stage))} workers</p>
      <div class="give-list">${fits.length ? fits.map(btn).join('') : '<p class="empty" style="padding:8px">Nobody in this step is here today.</p>'}</div>
      ${others.length ? `<p class="section-title">Someone else stepping up</p><div class="give-list">${others.map(btn).join('')}</div>` : ''}
      <p class="sub" style="font-size:13px;margin-top:10px">Busy people can't be picked until they finish. If someone didn't come, mark them <b>Away today</b> on the Workers page and their job comes back here.</p>
      <p id="gErr" class="ferr"></p>
      <div class="actions"><button class="btn line" data-x>Cancel</button></div>`);
    s.addEventListener('click', async e => { const b = e.target.closest('[data-gw]'); if (!b || b.disabled) return; b.disabled = true;
      const { error } = await db.rpc('ws_give_task', { p_task: taskId, p_worker: b.dataset.gw });
      if (error){ b.disabled = false; s.querySelector('#gErr').textContent = errMsg(error); return; }
      closeModal(); toast(`Given to ${W(b.dataset.gw).name}`); await load(); });
  }
  function stepsModal(){
    const s = openModal(`<h2>Workshop steps</h2>
      <p class="sub">Each job goes through these in order. Each step has its own workers and its own line. "Customer sees" is the simple name shown on the website.</p>
      <div class="steps-ed">${ALL_STEPS.map((st, i) => `<div class="se ${st.active === false ? 'off' : ''}" data-sid="${st.id}">
        <span class="se-n">${i + 1}</span>
        <div class="grow"><input class="se-name" value="${esc(st.name)}"><label class="se-grp">Customer sees <input class="se-g" value="${esc(st.grp)}" list="grps"></label></div>
        <span class="se-btns"><button type="button" class="mini" data-sup="${st.id}" ${i === 0 ? 'disabled' : ''}>▲</button><button type="button" class="mini" data-sdown="${st.id}" ${i === ALL_STEPS.length - 1 ? 'disabled' : ''}>▼</button>
        <button type="button" class="se-tog" data-stog="${st.id}">${st.active === false ? 'Switched off' : 'On'}</button></span></div>`).join('')}</div>
      <datalist id="grps">${[...new Set(ALL_STEPS.map(x => x.grp))].map(g => `<option>${esc(g)}</option>`).join('')}</datalist>
      <div class="se-add"><input id="seNew" placeholder="New step, e.g. Polishing"><button class="btn line" id="seAdd">+ Add step</button></div>
      <p id="seErr" class="ferr"></p>
      <div class="actions"><button class="btn line" data-x>Close</button><button class="btn" id="seSave">Save names</button></div>`);
    const err = m => s.querySelector('#seErr').textContent = m;
    const refresh = async () => { await loadSteps(); await load(); stepsModal(); };
    s.addEventListener('click', async e => {
      const up = e.target.closest('[data-sup]'), dn = e.target.closest('[data-sdown]'), tg = e.target.closest('[data-stog]');
      if (up || dn){ const { error } = await db.rpc('ws_move_step', { p_id: (up || dn).dataset[up ? 'sup' : 'sdown'], p_up: !!up }); if (error) return err(errMsg(error)); return refresh(); }
      if (tg){ const st = ALL_STEPS.find(x => x.id === tg.dataset.stog);
        if (st.active !== false && S.workers.some(w => w.active && w.stage === st.id) && !tg.dataset.sure){ tg.dataset.sure = 1; tg.textContent = 'Workers are here. Tap again'; return; }
        const { error } = await db.rpc('ws_save_step', { p: { id: st.id, name: st.name, grp: st.grp, active: st.active === false } }); if (error) return err(errMsg(error)); return refresh(); }
      if (e.target.id === 'seAdd'){ const n = s.querySelector('#seNew').value.trim(); if (!n) return err('Type the name of the new step');
        const { error } = await db.rpc('ws_save_step', { p: { name: n, grp: n } }); if (error) return err(errMsg(error)); toast('Step added at the end. Use ▲ to move it.'); return refresh(); }
      if (e.target.id === 'seSave'){
        for (const row of s.querySelectorAll('.se')){ const st = ALL_STEPS.find(x => x.id === row.dataset.sid);
          const name = row.querySelector('.se-name').value.trim(), grp = row.querySelector('.se-g').value.trim() || name;
          if (name !== st.name || grp !== st.grp){ const { error } = await db.rpc('ws_save_step', { p: { id: st.id, name, grp, active: st.active !== false } }); if (error) return err(errMsg(error)); } }
        toast('Steps saved'); closeModal(); await loadSteps(); await load(); }
    });
  }
  function fmCodeModal(){
    const s = openModal(`<h2>Manager code</h2><p class="sub">4 numbers. Tell the manager in person. Change it any time, e.g. if the manager changes.</p>
      <label class="field"><span>New code</span><input id="fcPin" inputmode="numeric" maxlength="4" placeholder="e.g. 4821" autocomplete="off" style="font-size:24px;letter-spacing:.3em"></label>
      <p id="fcErr" class="ferr"></p>
      <div class="actions"><button class="btn line" data-x>Cancel</button><button class="btn" id="fcSave">Save code</button></div>`);
    s.querySelector('#fcSave').onclick = async () => { const pin = s.querySelector('#fcPin').value.trim();
      if (!/^\d{4}$/.test(pin)) return s.querySelector('#fcErr').textContent = 'The code must be exactly 4 numbers.';
      const { error } = await db.rpc('ws_set_foreman_pin', { p_pin: pin });
      if (error) return s.querySelector('#fcErr').textContent = errMsg(error);
      closeModal(); toast('Manager code saved'); await load(); };
    setTimeout(() => s.querySelector('#fcPin').focus(), 50);
  }
  function toolModal(id){
    const t = id ? TL(id) : null;
    const s = openModal(`<h2>${t ? 'Edit ' + esc(t.name) : 'Add a tool'}</h2>
      <label class="field"><span>Name (use the number painted on it)</span><input id="tName" value="${t ? esc(t.name) : ''}" placeholder="e.g. Grinder 1" autocomplete="off"></label>
      <div class="field"><span>Used by which trades (the manager sees it when she taps these workers)</span>${stepChecks(t ? t.stages : [], 'tStage')}</div>
      <label class="field"><span>Who normally uses it (optional)</span><select id="tWho"><option value="">Anyone</option>${S.workers.filter(w => w.active).map(w => `<option value="${w.id}" ${t && t.worker === w.id ? 'selected' : ''}>${esc(w.name)} · ${stageName(w.stage)}</option>`).join('')}</select></label>
      <p id="tErr" class="ferr"></p>
      <div class="actions" style="justify-content:space-between">${t ? '<button class="btn line" id="tOff" style="color:var(--c-late)">Remove tool</button>' : '<span></span>'}<span style="display:flex;gap:8px"><button class="btn line" data-x>Cancel</button><button class="btn" id="tSave">Save</button></span></div>`);
    const save = async extra => { const { error } = await db.rpc('ws_save_tool', { p: Object.assign({ id: t ? t.id : null, name: s.querySelector('#tName').value, usual_worker: s.querySelector('#tWho').value, stages: [...s.querySelectorAll('.tStage:checked')].map(x => x.value) }, extra || {}) });
      if (error){ s.querySelector('#tErr').textContent = errMsg(error); return; } closeModal(); toast('Saved'); await load(); };
    s.querySelector('#tSave').onclick = () => save();
    const off = s.querySelector('#tOff'); if (off) off.onclick = () => save({ active:false });
    setTimeout(() => s.querySelector('#tName').focus(), 50);
  }

  function viewStock(){
    const mats = S.mats.filter(m => m.active);
    const watch = watchList();
    const moveTxt = x => { const m = M(x.mat), w = x.worker && W(x.worker), o = x.order && O(x.order); if (!m) return '';
      return x.kind === 'in' ? `Received <b>${n2(x.qty)} ${m.unit}</b> ${esc(m.name)}${x.note ? ' · ' + esc(x.note) : ''}`
        : x.kind === 'out' ? `Gave <b>${n2(-x.qty)} ${m.unit}</b> ${esc(m.name)} to ${esc(w ? w.name : 'a worker')}${o ? ' for ' + o.ref : ''}`
        : x.kind === 'back' ? `${esc(w ? w.name : 'A worker')} returned <b>${n2(x.qty)} ${m.unit}</b> ${esc(m.name)}`
        : `Count: ${esc(m.name)} ${x.qty === 0 ? 'correct ✓' : x.qty < 0 ? `<b style="color:var(--c-late)">${n2(-x.qty)} ${m.unit} missing</b>` : `${n2(x.qty)} ${m.unit} extra`}`; };
    const stdByProd = {};
    S.std.forEach(s => (stdByProd[s.product] = stdByProd[s.product] || []).push(s));
    return `
      <div class="d-head anim" style="--i:0"><div><h1>Stock &amp; tools</h1><p class="sub" style="margin:0">Raw materials in the store and the workshop tools. Only you can change these.</p></div>
        <span class="st-btns"><button class="btn line" data-addmat>+ Add material</button><button class="btn" data-move="out">Give out</button></span></div>
      ${watch.length ? `<div class="panel watch anim" style="--i:1"><div class="p-head"><h3>⚠ Watch list <span class="count">${watch.length}</span></h3></div>
        ${watch.map(a => `<div class="need red"${a.order ? ` data-open="${a.order}"` : ''}><span class="need-dot"></span><div class="grow"><b>${esc(a.title)}</b><p>${esc(a.sub)}</p></div></div>`).join('')}</div>` : ''}
      ${toolsPanel()}
      <p class="section-title anim" style="--i:2">Materials</p>
      ${mats.length ? `<div class="mats">${mats.map((m, i) => { const low = m.counted && m.low > 0 && m.store <= m.low; const full = Math.max(m.low * 3, m.store, 1);
        const t0 = new Date(todayStr() + 'T00:00:00+03:00').getTime(); const used = -S.moves.filter(x => x.mat === m.id && x.at >= t0 && (x.kind === 'out' || x.kind === 'back')).reduce((a, x) => a + x.qty, 0) || 0;
        return `<div class="mat anim ${low ? 'low' : ''} ${m.counted ? '' : 'nc'}" style="--i:${i + 2}">
          <button class="mat-name" data-editmat="${m.id}"><b>${esc(m.name)}</b>${low ? '<span class="hp h-late">Low</span>' : ''}</button>
          ${m.counted ? `<p class="mat-qty"><b>${n2(m.store)}</b> ${esc(m.unit)}</p>
          <div class="mat-bar"><i style="width:${Math.min(100, 100 * m.store / full)}%"></i>${m.low > 0 ? `<em style="left:${100 * m.low / full}%"></em>` : ''}</div>
          <p class="mat-low">${m.low > 0 ? `Warns at ${n2(m.low)} ${esc(m.unit)}` : 'No low-stock warning set'}${used ? ` · ${n2(used)} used today` : ''}</p>`
          : `<p class="mat-qty"><b>${n2(used)}</b> ${esc(m.unit)} <small>used today</small></p>
          <p class="mat-low">Store not counted yet. The app is adding up what goes out. Count it once to start tracking the store.</p>`}
          <div class="mat-acts"><button data-move="in" data-mat="${m.id}">＋ Received</button><button data-move="out" data-mat="${m.id}">Give out</button><button data-move="back" data-mat="${m.id}">Returned</button><button data-cnt="${m.id}">${m.counted ? 'Count' : 'First count'}</button></div>
        </div>`; }).join('')}</div>`
      : `<div class="panel anim" style="--i:1"><p class="empty">No materials yet. Tap <b>+ Add material</b>, e.g. "Steel tube 1 inch" in metres, "Foam sheet" in sheets.</p></div>`}
      <div class="d-grid" style="margin-top:20px">
        <div class="panel anim" style="--i:8"><div class="p-head"><h3>Recent movements</h3></div>
          ${S.moves.slice(0, 15).map(x => `<div class="news"><span class="news-av" style="background:${x.kind === 'out' ? 'var(--c-urg)' : x.kind === 'count' ? (x.qty < 0 ? 'var(--c-late)' : 'var(--metal)') : 'var(--c-work)'}">${x.kind === 'in' ? '＋' : x.kind === 'out' ? '−' : x.kind === 'back' ? '↩' : '#'}</span><div class="grow"><p>${moveTxt(x)}</p><small>${ago(x.at)}</small></div></div>`).join('') || '<p class="empty">Nothing yet.</p>'}
        </div>
        <div class="panel anim" style="--i:9"><div class="p-head"><h3>Normal amount per piece</h3><button class="link" data-std>+ Add</button></div>
          <p class="sub" style="font-size:13px;margin-bottom:8px">Tell the app how much one piece normally takes. If an order is given more, you get an alert.</p>
          ${Object.keys(stdByProd).length ? Object.entries(stdByProd).map(([p, list]) => `<div class="std"><b>${esc(p.charAt(0).toUpperCase() + p.slice(1))}</b>${list.map(s => { const m = M(s.mat); return m ? `<button data-std="${esc(p)}|${s.mat}">${n2(s.per)} ${esc(m.unit)} ${esc(m.name)}</button>` : ''; }).join('')}</div>`).join('')
            : '<p class="empty">Not set yet. Example: Bar stool = 2 m Steel tube.</p>'}
        </div>
      </div>`;
  }

  function materialModal(id){
    const m = id ? M(id) : null;
    const s = openModal(`<h2>${m ? 'Edit ' + esc(m.name) : 'Add a material'}</h2>
      <label class="field"><span>Name</span><input id="mName" value="${m ? esc(m.name) : ''}" placeholder="e.g. Steel tube 1 inch" autocomplete="off"></label>
      <div class="row2"><label class="field"><span>Counted in</span><input id="mUnit" value="${m ? esc(m.unit) : ''}" placeholder="m, sheets, pcs, litres" list="units"></label>
      <label class="field"><span>Warn me when it's down to</span><input id="mLow" type="number" min="0" step="any" value="${m ? m.low : ''}" placeholder="e.g. 20"></label></div>
      <div class="field"><span>Used in which steps (the manager only sees it for these workers)</span>${stepChecks(m ? m.stages : [], 'mStage')}</div>
      <datalist id="units"><option>m</option><option>pcs</option><option>sheets</option><option>litres</option><option>kg</option><option>rolls</option></datalist>
      ${m ? '' : '<p class="sub" style="font-size:13px">Starts at 0. Then tap <b>Received</b> to add what is in the store now.</p>'}
      <p id="mErr" class="ferr"></p>
      <div class="actions"><button class="btn line" data-x>Cancel</button><button class="btn" id="mSave">Save</button></div>`);
    s.querySelector('#mSave').onclick = async () => { const b = s.querySelector('#mSave'); b.disabled = true;
      const { error } = await db.rpc('ws_save_material', { p: { id: m ? m.id : null, name: s.querySelector('#mName').value, unit: s.querySelector('#mUnit').value, low_at: s.querySelector('#mLow').value || 0, stages: [...s.querySelectorAll('.mStage:checked')].map(x => x.value) } });
      if (error){ b.disabled = false; s.querySelector('#mErr').textContent = errMsg(error); return; }
      closeModal(); toast('Saved'); await load(); };
    setTimeout(() => s.querySelector('#mName').focus(), 50);
  }

  function moveModal(kind, matId){
    if (!S.mats.length) return materialModal();
    const T_ = { in:['Received','Add a delivery to the store'], out:['Give out','Materials leaving the store'], back:['Returned','Leftovers brought back to the store'] }[kind];
    const open = S.orders.filter(o => !o.delivered && !orderProgress(o).finished);
    const s = openModal(`<h2>${T_[0]}</h2><p class="sub">${T_[1]}</p>
      <label class="field"><span>Material</span><select id="vMat">${S.mats.filter(m => m.active).map(m => `<option value="${m.id}" ${m.id === matId ? 'selected' : ''}>${esc(m.name)}${m.counted ? ` · ${n2(m.store)} ${esc(m.unit)} in store` : ''}</option>`).join('')}</select></label>
      <label class="field"><span>How much</span><div class="qty-in"><input id="vQty" type="number" min="0" step="any" inputmode="decimal"><em id="vUnit"></em></div></label>
      ${kind !== 'in' ? `<label class="field"><span>${kind === 'out' ? 'Who is taking it' : 'Who brought it back'}</span><select id="vWho"><option value="">Pick a worker</option>${S.workers.filter(w => w.active).map(w => `<option value="${w.id}">${esc(w.name)} · ${stageName(w.stage)}</option>`).join('')}</select></label>
      <label class="field"><span>For which order</span><select id="vOrd"><option value="">Not for a specific order</option>${open.map(o => `<option value="${o.id}">${o.ref} · ${o.qty} × ${esc(o.item)}</option>`).join('')}</select></label>
      <p class="hint2" id="vHint"></p>` : `<label class="field"><span>Note (optional)</span><input id="vNote" placeholder="e.g. From Gikomba supplier, invoice 234"></label>`}
      <p id="vErr" class="ferr"></p>
      <div class="actions"><button class="btn line" data-x>Cancel</button><button class="btn" id="vSave">${T_[0]}</button></div>`);
    const upd = () => { const m = M(s.querySelector('#vMat').value); s.querySelector('#vUnit').textContent = m ? m.unit : '';
      const h = s.querySelector('#vHint'); if (!h) return;
      const w = s.querySelector('#vWho').value; const ws = w && W(w);
      if (ws && kind === 'out' && !s.querySelector('#vOrd').value){ const t = ws.task && T(ws.task); if (t) s.querySelector('#vOrd').value = t.order; }
      const o = O(s.querySelector('#vOrd').value);
      if (o && m){ const r = orderUse(o).find(x => x.mat === m.id); const q = parseFloat(s.querySelector('#vQty').value) || 0;
        h.innerHTML = r && r.normal != null ? `${o.ref} has had <b>${n2(r.given)} ${esc(m.unit)}</b> so far. Normal for the whole order: <b>${n2(r.normal)} ${esc(m.unit)}</b>.${kind === 'out' && r.given + q > r.normal * 1.1 ? ' <span style="color:var(--c-late);font-weight:600">This is more than normal.</span>' : ''}`
          : r ? `${o.ref} has had <b>${n2(r.given)} ${esc(m.unit)}</b> of this so far.` : ''; }
      else h.innerHTML = ''; };
    s.addEventListener('input', upd); s.addEventListener('change', upd); upd();
    s.querySelector('#vSave').onclick = async () => { const b = s.querySelector('#vSave'); b.disabled = true;
      const p = { kind, material_id: s.querySelector('#vMat').value, qty: s.querySelector('#vQty').value,
        worker_id: s.querySelector('#vWho') ? s.querySelector('#vWho').value : null, order_id: s.querySelector('#vOrd') ? s.querySelector('#vOrd').value : null,
        note: s.querySelector('#vNote') ? s.querySelector('#vNote').value : null };
      const { error } = await db.rpc('ws_stock_move', { p });
      if (error){ b.disabled = false; s.querySelector('#vErr').textContent = errMsg(error); return; }
      closeModal(); toast('Saved'); await load(); };
    setTimeout(() => s.querySelector('#vQty').focus(), 50);
  }

  function countModal(matId){
    const m = M(matId); if (!m) return;
    const s = openModal(`<h2>Count ${esc(m.name)}</h2>
      <p class="sub">${m.counted ? `Go to the store and count what is really there. The app says there should be <b>${n2(m.store)} ${esc(m.unit)}</b>.` : `Go to the store and count how much ${esc(m.name)} is there. From now on the app keeps the store amount and warns you when it runs low.`}</p>
      <label class="field"><span>What you counted</span><div class="qty-in"><input id="cQty" type="number" min="0" step="any" inputmode="decimal"><em>${esc(m.unit)}</em></div></label>
      <p class="hint2" id="cHint"></p><p id="cErr" class="ferr"></p>
      <div class="actions"><button class="btn line" data-x>Cancel</button><button class="btn" id="cSave">Save count</button></div>`);
    s.querySelector('#cQty').addEventListener('input', e => { const v = parseFloat(e.target.value); const d = isNaN(v) || !m.counted ? null : v - m.store;
      s.querySelector('#cHint').innerHTML = d == null ? '' : d < 0 ? `<span style="color:var(--c-late);font-weight:600">${n2(-d)} ${esc(m.unit)} missing</span>` : d > 0 ? `${n2(d)} ${esc(m.unit)} more than expected` : '✓ Matches'; });
    s.querySelector('#cSave').onclick = async () => { const b = s.querySelector('#cSave'); b.disabled = true;
      const { data, error } = await db.rpc('ws_stock_count', { p_material: m.id, p_counted: s.querySelector('#cQty').value });
      if (error){ b.disabled = false; s.querySelector('#cErr').textContent = errMsg(error); return; }
      closeModal(); toast(data < 0 ? `${n2(-data)} ${m.unit} missing. Added to the watch list.` : 'Count saved'); await load(); };
    setTimeout(() => s.querySelector('#cQty').focus(), 50);
  }

  function stdModal(key){
    if (!S.mats.length) return materialModal();
    const [prod, mat] = key ? key.split('|') : ['', ''];
    const cur = key ? S.std.find(x => x.product === prod && x.mat === mat) : null;
    const prods = [...new Set(S.orders.map(o => o.item.replace(/\s*\(.*\)\s*$/, '').trim()))];
    const s = openModal(`<h2>Normal amount per piece</h2>
      <label class="field"><span>Product</span><input id="sProd" list="prods" value="${esc(prod ? prod.charAt(0).toUpperCase() + prod.slice(1) : '')}" placeholder="e.g. Bar stool" ${key ? 'readonly' : ''}></label>
      <datalist id="prods">${prods.map(p => `<option>${esc(p)}</option>`).join('')}</datalist>
      <label class="field"><span>Material</span><select id="sMat" ${key ? 'disabled' : ''}>${S.mats.filter(m => m.active).map(m => `<option value="${m.id}" ${m.id === mat ? 'selected' : ''}>${esc(m.name)}</option>`).join('')}</select></label>
      <label class="field"><span>One piece normally takes</span><div class="qty-in"><input id="sPer" type="number" min="0" step="any" value="${cur ? cur.per : ''}"><em id="sUnit"></em></div></label>
      <p id="sErr" class="ferr"></p>
      <div class="actions" style="justify-content:space-between">${cur ? '<button class="btn line" id="sDel" style="color:var(--c-late)">Remove</button>' : '<span></span>'}<span style="display:flex;gap:8px"><button class="btn line" data-x>Cancel</button><button class="btn" id="sSave">Save</button></span></div>`);
    const upd = () => { const m = M(s.querySelector('#sMat').value); s.querySelector('#sUnit').textContent = m ? m.unit : ''; };
    s.querySelector('#sMat').addEventListener('change', upd); upd();
    const save = async per => { const { error } = await db.rpc('ws_save_std', { p_product: s.querySelector('#sProd').value, p_material: s.querySelector('#sMat').value, p_per_piece: per });
      if (error){ s.querySelector('#sErr').textContent = errMsg(error); return; } closeModal(); toast('Saved'); await load(); };
    s.querySelector('#sSave').onclick = () => save(s.querySelector('#sPer').value || 0);
    const d = s.querySelector('#sDel'); if (d) d.onclick = () => save(0);
  }

  function workerModal(id){
    const w = id ? W(id) : null;
    const s = openModal(`
      <h2>${w ? 'Edit ' + esc(w.name) : 'Add a worker'}</h2>
      <label class="field"><span>Name</span><input id="wName" value="${w ? esc(w.name) : ''}" placeholder="e.g. Odhiambo" autocomplete="off"></label>
      <label class="field"><span>Works in</span><select id="wStage" ${w && w.task ? 'disabled' : ''}>${stepGroups().map(g => `<optgroup label="${esc(g.grp)}">${g.steps.map(st => `<option value="${st.id}" ${w && w.stage === st.id ? 'selected' : ''}>${esc(st.name)}</option>`).join('')}</optgroup>`).join('')}</select>
        ${w && w.task ? '<small style="color:var(--muted)">Can change step once their current job is finished.</small>' : ''}</label>
      <div class="field"><span>Can also do (optional): when their own step has no work, they help here</span>${stepChecks(w ? w.covers : [], 'wCover')}</div>
      <p style="font-size:13px;color:var(--muted)">They go in on the workshop screen by tapping their name.</p>
      <p id="wErr" style="color:var(--red);min-height:20px;font-size:13px"></p>
      <div class="actions" style="justify-content:space-between">
        ${w ? `<button class="btn ${!w.active ? '' : 'red'}" id="wToggle">${!w.active ? 'Switch back on' : 'Switch off'}</button>` : '<span></span>'}
        <span style="display:flex;gap:8px"><button class="btn line" data-x>Cancel</button><button class="btn" id="wSave">Save</button></span>
      </div>`);
    s.querySelector('#wSave').onclick = async () => {
      const name = s.querySelector('#wName').value.trim(), stage = s.querySelector('#wStage').value;
      if (!name) return s.querySelector('#wErr').textContent = 'Add a name.';
      const btn = s.querySelector('#wSave'); btn.disabled = true;
      const { error } = await db.rpc('ws_save_worker', { p: { id: w ? w.id : null, name, stage: w && w.task ? w.stage : stage, covers: [...s.querySelectorAll('.wCover:checked')].map(x => x.value) } });
      if (error){ btn.disabled = false; s.querySelector('#wErr').textContent = errMsg(error); return; }
      closeModal(); toast('Saved'); await load();
    };
    const tg = s.querySelector('#wToggle');
    if (tg) tg.onclick = async () => { tg.disabled = true; closeModal(); await act('ws_set_worker_active', { p_worker: w.id, p_active: !w.active }, 'Saved'); };
    if (!w) setTimeout(() => s.querySelector('#wName').focus(), 50);
  }

  /* =====================================================================
     ALARM: when a worker says their work has STOPPED
     Siren + vibration + the voice reading it out, until the owner taps "I'm on it".
     After 10 minutes with no answer it escalates: faster, and the voice says it's urgent.
     No outside services (no SMS, no WhatsApp).
     ===================================================================== */
  const ESCALATE_AFTER_MIN = 10;
  let muted = false, beepT = null, actx = null, tick = null, beepMode = 0;

  /* ---------- VOICE: the phone reads alerts out loud (built into the phone, free) ---------- */
  const VOICE = { lang: 'en', small: true, name: { en: null, sw: null } };
  try { const sv = JSON.parse(localStorage.getItem('kt-voice') || 'null'); if (sv) Object.assign(VOICE, sv); } catch(e){}
  const saveVoice = () => { try { localStorage.setItem('kt-voice', JSON.stringify(VOICE)); } catch(e){} };
  const SW_REASON = { 'Material missing':'Vifaa vimeisha', 'Machine problem':'Mashine ina shida', 'Need instructions':'Anahitaji maelekezo', 'Something else':'Kuna shida nyingine' };
  const SW_STAGE = { metal:'kazi ya chuma', foam:'foam na ushonaji', finish:'umaliziaji', load:'upakiaji' };
  const sayRef = ref => ref.replace('KT-', 'K T ').split('').join(' ').replace(/\s+/g, ' ');
  function voicesFor(lang){
    const vs = window.speechSynthesis ? speechSynthesis.getVoices() : [];
    const want = lang === 'sw' ? ['sw-ke','sw-tz','sw'] : ['en-ke','en-gb','en-us','en'];
    const score = v => { const n = v.name.toLowerCase(); const l = (v.lang || '').replace('_','-').toLowerCase();
      const li = want.findIndex(w => l.startsWith(w)); if (li < 0) return -1;
      return (n.includes('natural') ? 300 : n.includes('online') ? 200 : n.includes('google') ? 150 : 0) + (10 - li) * 10; };
    return vs.filter(v => score(v) >= 0).sort((x, y) => score(y) - score(x));
  }
  const pickVoice = lang => { const l = voicesFor(lang); return l.find(v => v.name === VOICE.name[lang]) || l[0] || null; };
  function say(text, opts){
    if (VOICE.lang === 'off' || !window.speechSynthesis) return;
    const u = new SpeechSynthesisUtterance(text);
    const v = pickVoice(VOICE.lang); if (v){ u.voice = v; u.lang = v.lang; } else u.lang = VOICE.lang === 'sw' ? 'sw-KE' : 'en-GB';
    u.rate = .92; u.pitch = 1; u.volume = 1;
    if (opts && opts.interrupt) speechSynthesis.cancel();
    speechSynthesis.speak(u);
  }
  const hush = () => { if (window.speechSynthesis) speechSynthesis.cancel(); if (navigator.vibrate) navigator.vibrate(0); };
  const sw = () => VOICE.lang === 'sw';
  const MSG = {
    stopped: (w, t, o, mins) => mins >= ESCALATE_AFTER_MIN
      ? (sw() ? `Dharura. ${w} amesubiri dakika ${mins}. ${SW_REASON[t.problem.reason] || t.problem.reason}. Oda ${sayRef(o.ref)}.`
              : `Urgent. ${w} has been waiting ${mins} minutes. ${t.problem.reason}. Order ${sayRef(o.ref)}.`)
      : (sw() ? `Tahadhari. ${w} amesimama kazi. ${SW_REASON[t.problem.reason] || t.problem.reason}. Oda ${sayRef(o.ref)}.`
              : `Alert. ${w} has stopped work. ${t.problem.reason}. Order ${sayRef(o.ref)}, ${stageName(t.stage)}.`),
    problem: (w, t) => sw() ? `${w} ana shida. ${SW_REASON[t.problem.reason] || t.problem.reason}. Bado anaendelea na kazi.` : `${w} reported a problem. ${t.problem.reason}. They are still working.`,
    finished: (w, o, next) => sw() ? `${w} amemaliza ${o.item}. ${next ? 'Imeenda ' + (SW_STAGE[next] || stageName(next)) + '.' : 'Iko tayari kupelekwa.'}`
                                   : `${w} finished the ${o.item.toLowerCase()}. ${next ? 'It has gone to ' + stageName(next) + '.' : 'It is ready for delivery.'}`,
    web: (w) => sw() ? `Oda mpya kutoka kwa website. ${w.customer_name}.` : `New order from the website. ${w.customer_name}.`,
    waiting: w => sw() ? `${w} anasubiri kazi.` : `${w} is waiting for work.`,
    test: () => sw() ? 'Habari. Hii ni sauti ya Kartech.' : 'Hello. This is the Kartech voice.'
  };
  if (window.speechSynthesis) speechSynthesis.onvoiceschanged = () => { if (tab === 'today' && !document.querySelector('.scrim') && loaded) render(); };

  /* Small updates: compare what changed since the last refresh and read it out once */
  let prevTasks = null, prevWorkers = null, prevWeb = null, prevLogId = Infinity;
  function announceChanges(){
    if (!prevTasks){ prevTasks = new Map(S.tasks.map(t => [t.id, t])); prevWorkers = new Map(S.workers.map(w => [w.id, w])); prevWeb = new Set((S.web || []).map(w => w.id)); prevLogId = S.log.length ? S.log[0].id : 0; return; }
    const lines = [];
    (S.web || []).forEach(w => { if (!prevWeb.has(w.id)) lines.push(MSG.web(w)); });
    prevWeb = new Set((S.web || []).map(w => w.id));
    S.log.filter(l => l.id > prevLogId && l.kind === 'alert' && /^Low stock|MISSING|has been given|^Tool check: \d/.test(l.text)).slice(0, 2)
      .forEach(l => lines.push(sw() ? (/^Low stock/.test(l.text) ? 'Tahadhari ya stoo. ' : 'Tahadhari ya vifaa. ') + l.text : l.text.replace(/KT-(\d+)/g, (m, d) => sayRef('KT-' + d)).replace(/ × /g, ' ')));
    prevLogId = S.log.length ? S.log[0].id : prevLogId;
    S.tasks.forEach(t => { const p = prevTasks.get(t.id); const o = O(t.order); if (!p || !o) return;
      if (p.status !== 'done' && t.status === 'done'){ const w = W(t.worker); lines.push(MSG.finished(w ? w.name : 'A worker', o, o.stages[t.step])); }
      if (t.problem && !t.problem.stopped && !(p.problem)){ const w = W(t.worker); lines.push(MSG.problem(w ? w.name : 'A worker', t)); } });
    S.workers.forEach(w => { const p = prevWorkers.get(w.id); if (p && w.active && p.task && !w.task) lines.push(MSG.waiting(w.name)); });
    prevTasks = new Map(S.tasks.map(t => [t.id, t])); prevWorkers = new Map(S.workers.map(w => [w.id, w]));
    if (VOICE.small && !stoppedOpen().length) lines.slice(0, 3).forEach(l => say(l));
  }

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
    if (!list.length){ el.classList.add('hidden'); if (beepT) hush(); clearInterval(beepT); beepT = null; clearInterval(tick); tick = null; return; }
    const t = list[0], w = W(t.worker), o = O(t.order); if (!o) return;
    const n = Math.max(0, Math.floor((Date.now() - t.problem.at) / 1000));
    el.innerHTML = `<button class="mute" id="muteBtn">${muted ? '🔇 Sound off' : '🔊 Sound on'}</button><div class="box">
      <p class="tag">⚠ WORK HAS STOPPED</p>
      <h1>${esc(t.problem.reason)}</h1>
      <p class="who"><b>${esc(w ? w.name : 'A worker')}</b> · ${stageName(t.stage)} · ${o.ref}</p>
      <p class="timer">${o.qty} × ${esc(o.item)} · waiting ${mmss(n)}</p>
      <div class="ladder">
        <div><span class="ok">✓ Siren + vibration</span><span class="ok">now</span></div>
        <div class="${VOICE.lang === 'off' ? 'not-yet' : ''}"><span class="${VOICE.lang === 'off' ? '' : 'ok'}">${VOICE.lang === 'off' ? '○' : '✓'} Voice reads it out</span><span>${VOICE.lang === 'off' ? 'off' : sw() ? 'Kiswahili' : 'English'}</span></div>
        <div class="${n >= ESCALATE_AFTER_MIN * 60 ? '' : 'not-yet'}"><span class="${n >= ESCALATE_AFTER_MIN * 60 ? 'ok' : ''}">${n >= ESCALATE_AFTER_MIN * 60 ? '✓' : '○'} Louder, faster, "urgent"</span><span>${n >= ESCALATE_AFTER_MIN * 60 ? 'now' : 'in ' + mmss(Math.max(0, ESCALATE_AFTER_MIN * 60 - n))}</span></div>
      </div>
      <button class="giant ack" data-ack="${t.id}">I'M ON IT</button>
      <p class="more">Tapping this stops the alarm and tells ${esc(w ? w.name : 'them')} you've seen it.${list.length > 1 ? ` <b>${list.length - 1} more waiting.</b>` : ''}</p>
    </div>`;
    el.classList.remove('hidden');
    if (!tick) tick = setInterval(alarmRender, 1000);
    const mode = n >= ESCALATE_AFTER_MIN * 60 ? 2 : 1;          // 2 = escalated: repeats twice as often
    if (beepT && mode !== beepMode){ clearInterval(beepT); beepT = null; }
    if (!beepT && !muted){
      beepMode = mode;
      const cycle = () => { const x = stoppedOpen()[0]; if (muted || !x) return; beep();
        setTimeout(() => { const y = stoppedOpen()[0]; if (!y || muted) return; const wy = W(y.worker), oy = O(y.order); if (!oy) return;
          say(MSG.stopped(wy ? wy.name : 'A worker', y, oy, Math.floor((Date.now() - y.problem.at) / 60000)), { interrupt:true }); }, 1400); };
      cycle(); beepT = setInterval(cycle, mode === 2 ? 4000 : 8000);
    }
  }
  document.addEventListener('click', async e => {
    const vl = e.target.closest('[data-vlang]'); if (vl){ VOICE.lang = vl.dataset.vlang; saveVoice(); if ($('#setModal')) settingsModal(); render(); say(MSG.test(), { interrupt:true }); return; }
    if (e.target.closest('#setBtn')) return settingsModal();
    if (e.target.closest('#moreNews')){ showAll = true; render(); return; }
    if (e.target.closest('#outBtn2')){ await db.auth.signOut(); location.reload(); return; }
    if (e.target.closest('[data-neworder]')) return newOrderModal();
    if (e.target.closest('#vTest')){ say(MSG.test(), { interrupt:true }); return; }
    if (e.target.id === 'vSmall'){ VOICE.small = e.target.checked; saveVoice(); return; }
    if (e.target.closest('#muteBtn')){ muted = !muted; if (muted){ clearInterval(beepT); beepT = null; hush(); } alarmRender(); return; }
    const a = e.target.closest('[data-ack]'); if (!a) return;
    a.disabled = true; a.textContent = 'Telling them…';
    hush();
    const t = T(a.dataset.ack); if (t) t.problem.ack = true;   // stop the siren straight away
    alarmRender();
    await act('ws_ack', { p_task: a.dataset.ack }, "They've been told you're on it");
  });
  document.addEventListener('change', e => { if (e.target.id === 'vName'){ VOICE.name[VOICE.lang] = e.target.value; saveVoice(); say(MSG.test(), { interrupt:true }); } });
  // Phones block sound until the first tap. Any tap on the page unlocks it.
  document.addEventListener('pointerdown', () => { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); if (actx.state === 'suspended') actx.resume(); } catch(e){} }, { once:true });

  db.auth.onAuthStateChange(ev => { if (ev === 'SIGNED_OUT') show('loginView'); });
  start();
})();
