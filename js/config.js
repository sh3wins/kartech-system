/* KARTECH WORKSHOP: settings. Same values as the website (kartech-website/js/settings.js). */
const KT_CONFIG = {
  supabaseUrl: 'https://zwnaufwunzaqchgxyrfv.supabase.co',
  supabaseKey: 'sb_publishable_-m1Qm057XAkFk9IX21wN7Q_de7zzP2C',
  stationIdleSeconds: 60,     // workshop PC signs the worker out after this long with no taps
  toolCheckAt: '18:30'        // closing time: the foreman's evening tool check
};
const STAGES = [
  { id:'metal',  name:'Metalwork',             short:'Metal' },
  { id:'foam',   name:'Foaming & fabrication', short:'Foam & fab' },
  { id:'finish', name:'Finishing',             short:'Finishing' },
  { id:'load',   name:'Loading',               short:'Loading' }
];
const URG = { urgent:0, high:1, normal:2 };
const URG_NAME = { urgent:'Urgent', high:'High', normal:'Normal' };
const stageName = id => (STAGES.find(s => s.id === id) || { name:id }).name;
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
