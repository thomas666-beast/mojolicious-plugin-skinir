/*! Skinir — Vue 3 admin client. Source parts live in assets/src; `node assets/build.mjs` bundles them. */
(function (global) {
'use strict';

const { createApp, reactive, ref, computed, watch, onMounted, onBeforeUnmount, nextTick } = Vue;

// ---------------------------------------------------------------------------------------
// Config / state
// ---------------------------------------------------------------------------------------
const CFG = JSON.parse(document.getElementById('skinir-config').textContent);

const S = reactive({
  boot: null,                 // /bootstrap payload
  route: { name: 'dashboard' },
  toasts: [],
  dialog: null,               // confirm dialog
  sidebar: false,
  dark: document.documentElement.classList.contains('dark'),
  menu: false,
});

// Public extension surface (custom fields / pages)
const Skinir = {
  _fields: {},
  _components: {},
  field(type, def) { Skinir._fields[type] = def; return Skinir; },
  component(name, def) { Skinir._components[name] = def; return Skinir; },
  api: null, t: null, navigate: null, toast: null, confirm: null, state: S,
};

// ---------------------------------------------------------------------------------------
// i18n
// ---------------------------------------------------------------------------------------
function t(key, params) {
  const msgs = (S.boot && S.boot.messages) || {};
  let s = Object.prototype.hasOwnProperty.call(msgs, key) ? msgs[key] : key;
  if (params) s = s.replace(/\{(\w+)\}/g, (m, k) => (k in params ? params[k] : m));
  return s;
}

function locale() { return (S.boot && S.boot.locale) || CFG.locale || 'en'; }

function fmtNumber(n, decimals) {
  if (n === null || n === undefined || n === '') return '';
  const opts = decimals === undefined
    ? { maximumFractionDigits: 20 }
    : { minimumFractionDigits: decimals, maximumFractionDigits: decimals };
  try { return new Intl.NumberFormat(locale(), opts).format(n); } catch (e) { return String(n); }
}

function fmtDate(v) {
  if (!v) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v);
  if (!m) return String(v);
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  try { return d.toLocaleDateString(locale(), { dateStyle: 'medium', timeZone: 'UTC' }); } catch (e) { return v; }
}

function fmtDateTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d)) return String(iso);
  try { return d.toLocaleString(locale(), { dateStyle: 'medium', timeStyle: 'short' }); } catch (e) { return String(iso); }
}

const pad = n => String(n).padStart(2, '0');

// server sends UTC ISO strings; <input type=datetime-local> works in local time
function isoToLocalInput(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d)) return '';
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + 'T' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

function localInputToUtc(v) {
  if (!v) return null;
  const d = new Date(v);
  if (isNaN(d)) return null;
  return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()) + ' ' +
    pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()) + ':' + pad(d.getUTCSeconds());
}

function safeUrl(u) { return typeof u === 'string' && /^https?:\/\//i.test(u) ? u : null; }

// ---------------------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------------------
async function api(method, path, body) {
  const headers = { 'Accept': 'application/json', 'X-CSRF-Token': CFG.csrf };
  let payload;
  if (typeof FormData !== 'undefined' && body instanceof FormData) payload = body;
  else if (body !== undefined) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(body); }

  let res;
  try {
    res = await fetch(CFG.api + path, { method, headers, body: payload, credentials: 'same-origin' });
  } catch (e) {
    const err = new Error(t('error_network')); err.status = 0; throw err;
  }
  if (res.status === 401) { window.location.href = CFG.base + '/login'; throw new Error('Unauthenticated'); }

  let data = null;
  try { data = await res.json(); } catch (e) { /* empty body */ }
  if (!res.ok) {
    const err = new Error((data && data.message) || t('error_generic'));
    err.status = res.status;
    err.errors = (data && data.errors) || null;
    if (res.status === 419) toast('error', (data && data.message) || t('error_generic'));
    throw err;
  }
  return data;
}

function qs(obj) {
  const p = new URLSearchParams();
  Object.keys(obj).forEach(k => {
    const v = obj[k];
    if (v !== null && v !== undefined && v !== '') p.set(k, v);
  });
  const s = p.toString();
  return s ? '?' + s : '';
}

// ---------------------------------------------------------------------------------------
// Toasts + confirm dialog
// ---------------------------------------------------------------------------------------
let toastId = 0;
function toast(type, message) {
  const id = ++toastId;
  S.toasts.push({ id, type, message });
  setTimeout(() => dismissToast(id), type === 'error' ? 7000 : 4000);
}
function dismissToast(id) {
  const i = S.toasts.findIndex(x => x.id === id);
  if (i >= 0) S.toasts.splice(i, 1);
}

function confirmDialog(opts) {
  return new Promise(resolve => {
    S.dialog = Object.assign({ title: '', text: '', button: t('confirm'), danger: false }, opts, {
      resolve: v => { S.dialog = null; resolve(v); },
    });
  });
}

// ---------------------------------------------------------------------------------------
// Router (history API, no dependencies)
// ---------------------------------------------------------------------------------------
function parsePath() {
  let p = window.location.pathname;
  if (p.indexOf(CFG.base) === 0) p = p.slice(CFG.base.length);
  const seg = p.replace(/^\/+|\/+$/g, '').split('/').filter(Boolean).map(decodeURIComponent);
  if (!seg.length) return { name: 'dashboard' };
  if (seg[0] === 'resources' && seg[1]) {
    const r = seg[1];
    if (seg.length === 2) return { name: 'index', resource: r };
    if (seg.length === 3 && seg[2] === 'new') return { name: 'create', resource: r };
    if (seg.length === 3) return { name: 'detail', resource: r, id: seg[2] };
    if (seg.length === 4 && seg[3] === 'edit') return { name: 'edit', resource: r, id: seg[2] };
  }
  return { name: 'notfound' };
}

function navigate(path, replace) {
  const url = CFG.base + path;
  if (replace) window.history.replaceState({}, '', url); else window.history.pushState({}, '', url);
  S.route = parsePath();
  S.sidebar = false;
  S.menu = false;
  window.scrollTo(0, 0);
}

const R = {
  dashboard: () => '',
  index: r => '/resources/' + encodeURIComponent(r),
  create: r => '/resources/' + encodeURIComponent(r) + '/new',
  detail: (r, id) => '/resources/' + encodeURIComponent(r) + '/' + encodeURIComponent(id),
  edit: (r, id) => '/resources/' + encodeURIComponent(r) + '/' + encodeURIComponent(id) + '/edit',
};

// ---------------------------------------------------------------------------------------
// Style tokens (full literal class strings so the Tailwind build can see them)
// ---------------------------------------------------------------------------------------
const B = {
  primary: 'inline-flex items-center justify-center gap-2 rounded-lg bg-brand-600 px-3.5 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 dark:focus-visible:ring-offset-slate-950',
  secondary: 'inline-flex items-center justify-center gap-2 rounded-lg border border-slate-300 bg-white px-3.5 py-2 text-sm font-medium text-slate-700 shadow-sm transition hover:bg-slate-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 disabled:cursor-not-allowed disabled:opacity-50 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200 dark:hover:bg-slate-800',
  danger: 'inline-flex items-center justify-center gap-2 rounded-lg bg-red-600 px-3.5 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-red-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-red-500 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 dark:focus-visible:ring-offset-slate-950',
  ghost: 'inline-flex h-8 w-8 items-center justify-center rounded-lg text-slate-500 transition hover:bg-slate-100 hover:text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 disabled:opacity-40 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-white',
  ghostDanger: 'inline-flex h-8 w-8 items-center justify-center rounded-lg text-slate-500 transition hover:bg-red-50 hover:text-red-600 focus:outline-none focus-visible:ring-2 focus-visible:ring-red-500 dark:text-slate-400 dark:hover:bg-red-950 dark:hover:text-red-400',
  input: 'block w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm placeholder:text-slate-400 focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/30 disabled:bg-slate-100 disabled:text-slate-500 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-100 dark:placeholder:text-slate-500 dark:disabled:bg-slate-800',
  inputError: 'block w-full rounded-lg border border-red-400 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-red-500 focus:outline-none focus:ring-2 focus:ring-red-500/30 dark:border-red-500 dark:bg-slate-900 dark:text-slate-100',
  card: 'rounded-xl border border-slate-200 bg-white shadow-sm dark:border-slate-800 dark:bg-slate-900',
  link: 'font-medium text-brand-600 hover:text-brand-700 hover:underline dark:text-brand-400 dark:hover:text-brand-300',
};

const BADGE = {
  success: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20 dark:bg-emerald-950 dark:text-emerald-300 dark:ring-emerald-400/20',
  info: 'bg-sky-50 text-sky-700 ring-sky-600/20 dark:bg-sky-950 dark:text-sky-300 dark:ring-sky-400/20',
  warning: 'bg-amber-50 text-amber-800 ring-amber-600/20 dark:bg-amber-950 dark:text-amber-300 dark:ring-amber-400/20',
  danger: 'bg-red-50 text-red-700 ring-red-600/20 dark:bg-red-950 dark:text-red-300 dark:ring-red-400/20',
  neutral: 'bg-slate-100 text-slate-700 ring-slate-500/20 dark:bg-slate-800 dark:text-slate-300 dark:ring-slate-400/20',
};

// ---------------------------------------------------------------------------------------
// Icons (24x24, stroke based)
// ---------------------------------------------------------------------------------------
const ICONS = {
  home: '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h5v-6h4v6h5V10"/>',
  collection: '<rect x="3" y="4" width="18" height="5" rx="1"/><rect x="3" y="11" width="18" height="5" rx="1"/><path d="M5 19h14"/>',
  document: '<path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4M10 12h5M10 16h5"/>',
  users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6"/><path d="M16 4.6a3.5 3.5 0 010 6.8M18 14.4c2 .7 3.5 2.6 3.5 5.6"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-7 8-7s8 2.6 8 7"/>',
  tag: '<path d="M3 12V4h8l10 10-8 8z"/><circle cx="7.5" cy="8.5" r="1.2"/>',
  cog: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  pencil: '<path d="M4 20l4-1 11-11-3-3L5 16z"/><path d="M14 6l3 3"/>',
  eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/>',
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  check: '<path d="M5 13l4 4L19 7"/>',
  'chevron-down': '<path d="M6 9l6 6 6-6"/>',
  'chevron-left': '<path d="M15 6l-6 6 6 6"/>',
  'chevron-right': '<path d="M9 6l6 6-6 6"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  moon: '<path d="M21 12.8A9 9 0 1111.2 3a7 7 0 009.8 9.8z"/>',
  menu: '<path d="M4 6h16M4 12h16M4 18h16"/>',
  logout: '<path d="M10 4H5v16h5M15 8l4 4-4 4M19 12H9"/>',
  filter: '<path d="M3 5h18l-7 8v6l-4-2v-4z"/>',
  'arrow-up': '<path d="M12 19V5M6 11l6-6 6 6"/>',
  'arrow-down': '<path d="M12 5v14M6 13l6 6 6-6"/>',
  refresh: '<path d="M20 11a8 8 0 10-2.3 5.7"/><path d="M20 4v7h-7"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/>',
  upload: '<path d="M12 16V4M7 9l5-5 5 5M4 20h16"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="1.6"/><path d="M21 16l-5-5-8 8"/>',
  folder: '<path d="M3 6h7l2 2h9v11H3z"/>',
  mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
  shield: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',
  chart: '<path d="M5 20V10M11 20V4M17 20v-8M3 20h18"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  bolt: '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
  star: '<path d="M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.5l6.1-.9z"/>',
  bookmark: '<path d="M6 3h12v18l-6-4-6 4z"/>',
  inbox: '<path d="M3 13l3-8h12l3 8v6H3z"/><path d="M3 13h5l1 3h6l1-3h5"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M16 7l3 3"/>',
  lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 018 0v4"/>',
  external: '<path d="M14 4h6v6M20 4l-9 9M18 14v6H4V6h6"/>',
};
