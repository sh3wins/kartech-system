/* KARTECH WORKSHOP: settings. Same values as the website (kartech-website/js/settings.js). */
const KT_CONFIG = {
  supabaseUrl: 'https://zwnaufwunzaqchgxyrfv.supabase.co',
  supabaseKey: 'sb_publishable_-m1Qm057XAkFk9IX21wN7Q_de7zzP2C',
  stationIdleSeconds: 60,     // workshop PC signs the worker out after this long with no taps
  toolCheckAt: '18:30'        // closing time: the manager's evening tool check
};
// Workshop steps. Loaded from the database (the owner can change them); these are the defaults.
const STAGES = [
  { id:'get',    name:'Getting metals',        short:'Get metals', grp:'Metalwork' },
  { id:'cut',    name:'Cutting',               short:'Cutting',    grp:'Metalwork' },
  { id:'fold',   name:'Folding',               short:'Folding',    grp:'Metalwork' },
  { id:'weld',   name:'Welding',               short:'Welding',    grp:'Metalwork' },
  { id:'grind',  name:'Grinding',              short:'Grinding',   grp:'Metalwork' },
  { id:'paint',  name:'Painting',              short:'Painting',   grp:'Metalwork' },
  { id:'foam',   name:'Foaming & fabrication', short:'Foam & fab', grp:'Foaming & fabrication' },
  { id:'finish', name:'Finishing',             short:'Finishing',  grp:'Finishing' },
  { id:'load',   name:'Loading',               short:'Loading',    grp:'Loading' }
];
const ALL_STEPS = STAGES.slice();
async function loadSteps(){
  if (!db) return;
  const { data, error } = await db.from('ws_steps').select('*').order('sort');
  if (error || !data || !data.length) return;
  const all = data.map(x => ({ id:x.id, name:x.name, short:x.name.length > 12 ? x.name.split(/[ &]/)[0] : x.name, grp:x.grp, active:x.active, sort:x.sort }));
  ALL_STEPS.splice(0, ALL_STEPS.length, ...all);
  STAGES.splice(0, STAGES.length, ...all.filter(x => x.active));
}
// steps grouped for forms: [{ grp, steps:[…] }]
const stepGroups = (list = STAGES) => list.reduce((a, s) => { const g = a.find(x => x.grp === s.grp); g ? g.steps.push(s) : a.push({ grp:s.grp, steps:[s] }); return a; }, []);
const URG = { urgent:0, high:1, normal:2 };
const URG_NAME = { urgent:'Urgent', high:'High', normal:'Normal' };
const stageName = id => (ALL_STEPS.find(s => s.id === id) || { metal:{ name:'Metalwork' } }[id] || { name:id }).name;
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtDay = d => {
  const t = new Date(); t.setHours(0,0,0,0);
  const x = new Date(d); x.setHours(0,0,0,0);
  const diff = Math.round((x - t) / 864e5);
  if (diff === 0) return 'Today'; if (diff === 1) return 'Tomorrow'; if (diff === -1) return 'Yesterday';
  if (diff < 0) return Math.abs(diff) + ' days late';
  return x.toLocaleDateString('en-KE', { weekday:'short', day:'numeric', month:'short' });
};
const isLate = d => { const t = new Date(); t.setHours(0,0,0,0); const x = new Date(d); x.setHours(0,0,0,0); return x < t; };
const ago = t => { const m = Math.round((Date.now() - t) / 60000); return m < 1 ? 'just now' : m < 60 ? m + ' min ago' : m < 1440 ? Math.round(m/60) + ' h ago' : Math.round(m/1440) + ' d ago'; };
let toastT;
function toast(m){ const el = $('#toast'); el.textContent = m; el.classList.add('show'); clearTimeout(toastT); toastT = setTimeout(() => el.classList.remove('show'), 2800); }
const errMsg = e => (e && (e.message || e.error_description)) ? String(e.message || e.error_description).replace(/^.*?:\s(?=[A-Z])/,'') : 'Something went wrong. Check the internet and try again.';
const db = (window.supabase && KT_CONFIG.supabaseUrl) ? window.supabase.createClient(KT_CONFIG.supabaseUrl, KT_CONFIG.supabaseKey) : null;
