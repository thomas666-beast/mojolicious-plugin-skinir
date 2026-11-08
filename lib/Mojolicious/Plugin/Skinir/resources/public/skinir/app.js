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


// ---------------------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------------------
const C = {};

C['s-link'] = {
  props: { to: { type: String, required: true } },
  setup(props) {
    const href = computed(() => CFG.base + props.to);
    function click(e) {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      e.preventDefault();
      navigate(props.to);
    }
    return { href, click };
  },
  template: '<a :href="href" @click="click"><slot /></a>',
};

C['s-icon'] = {
  props: { name: String, sm: Boolean },
  setup(props) {
    return { paths: computed(() => ICONS[props.name] || ICONS.collection) };
  },
  template: '<svg :class="sm ? \'h-4 w-4 shrink-0\' : \'h-5 w-5 shrink-0\'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" v-html="paths"></svg>',
};

C['s-modal'] = {
  props: { title: String, wide: Boolean },
  emits: ['close'],
  setup(props, { emit }) {
    const onKey = e => { if (e.key === 'Escape') emit('close'); };
    onMounted(() => document.addEventListener('keydown', onKey));
    onBeforeUnmount(() => document.removeEventListener('keydown', onKey));
    return {};
  },
  template: `
    <div class="fixed inset-0 z-50 flex items-end justify-center p-4 sm:items-center" role="dialog" aria-modal="true">
      <div class="fixed inset-0 bg-slate-900/50 backdrop-blur-sm" @click="$emit('close')"></div>
      <div :class="[B.card, 'relative z-10 w-full shadow-xl', wide ? 'max-w-2xl' : 'max-w-md']">
        <div class="flex items-start justify-between gap-4 border-b border-slate-200 px-5 py-4 dark:border-slate-800">
          <h3 class="text-base font-semibold text-slate-900 dark:text-white">{{ title }}</h3>
          <button type="button" :class="B.ghost" @click="$emit('close')"><s-icon name="x" sm /></button>
        </div>
        <div class="max-h-[70vh] overflow-y-auto px-5 py-4"><slot /></div>
        <div v-if="$slots.footer" class="flex justify-end gap-2 border-t border-slate-200 px-5 py-3 dark:border-slate-800"><slot name="footer" /></div>
      </div>
    </div>`,
};

C['s-toasts'] = {
  setup() {
    const cls = {
      success: 'border-emerald-200 bg-white text-emerald-800 dark:border-emerald-900 dark:bg-slate-900 dark:text-emerald-300',
      error: 'border-red-200 bg-white text-red-800 dark:border-red-900 dark:bg-slate-900 dark:text-red-300',
      info: 'border-slate-200 bg-white text-slate-800 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200',
    };
    return { S, cls, dismissToast };
  },
  template: `
    <div class="pointer-events-none fixed inset-x-0 top-4 z-[60] flex flex-col items-center gap-2 px-4 sm:items-end sm:pr-6">
      <div v-for="x in S.toasts" :key="x.id" role="status"
           :class="['pointer-events-auto flex w-full max-w-sm items-start gap-3 rounded-xl border px-4 py-3 text-sm shadow-lg', cls[x.type] || cls.info]">
        <s-icon :name="x.type === 'error' ? 'shield' : 'check'" sm class="mt-0.5" />
        <p class="flex-1">{{ x.message }}</p>
        <button type="button" class="opacity-60 hover:opacity-100" @click="dismissToast(x.id)"><s-icon name="x" sm /></button>
      </div>
    </div>`,
};

C['s-confirm'] = {
  setup() { return { S }; },
  template: `
    <s-modal v-if="S.dialog" :title="S.dialog.title" @close="S.dialog.resolve(false)">
      <p class="text-sm text-slate-600 dark:text-slate-300">{{ S.dialog.text }}</p>
      <template #footer>
        <button type="button" :class="B.secondary" @click="S.dialog.resolve(false)">{{ t('cancel') }}</button>
        <button type="button" :class="S.dialog.danger ? B.danger : B.primary" @click="S.dialog.resolve(true)">{{ S.dialog.button }}</button>
      </template>
    </s-modal>`,
};

// ---- read-only rendering of a field value --------------------------------------------------
C['field-display'] = {
  props: { field: Object, value: null, large: Boolean },
  setup(props) {
    const custom = computed(() => (Skinir._fields[props.field.type] || {}).display || null);
    const isEmpty = computed(() => {
      if (props.field.type === 'boolean') return false;
      const v = props.value;
      return v === null || v === undefined || v === '';
    });
    const optionLabel = computed(() => {
      const o = (props.field.options || []).find(x => String(x.value) === String(props.value));
      return o ? o.label : props.value;
    });
    const badgeLabel = computed(() => (props.field.labels || {})[props.value] || props.value);
    const badgeClass = computed(() => BADGE[(props.field.types || {})[props.value]] || BADGE.neutral);
    const dateText = computed(() => fmtDate(props.value));
    const dateTimeText = computed(() => fmtDateTime(props.value));
    const numberText = computed(() => {
      const f = props.field;
      return (f.prefix || '') + fmtNumber(props.value) + (f.suffix ? ' ' + f.suffix : '');
    });
    const url = computed(() => safeUrl(props.value));
    return { custom, isEmpty, optionLabel, badgeLabel, badgeClass, dateText, dateTimeText, numberText, url, R };
  },
  template: `
    <component v-if="custom" :is="custom" :field="field" :value="value" :large="large" />
    <span v-else-if="isEmpty" class="text-slate-400 dark:text-slate-500">{{ t('no_value') }}</span>
    <span v-else-if="field.type === 'boolean'">
      <span v-if="value" class="inline-flex items-center gap-1 text-emerald-600 dark:text-emerald-400"><s-icon name="check" sm />{{ t('yes') }}</span>
      <span v-else class="inline-flex items-center gap-1 text-slate-400 dark:text-slate-500"><s-icon name="x" sm />{{ t('no') }}</span>
    </span>
    <span v-else-if="field.type === 'badge'" :class="['inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset', badgeClass]">{{ badgeLabel }}</span>
    <span v-else-if="field.type === 'select'">{{ optionLabel }}</span>
    <s-link v-else-if="field.type === 'belongs_to' && field.resource" :to="R.detail(field.resource, value.id)" :class="B.link">{{ value.title }}</s-link>
    <span v-else-if="field.type === 'belongs_to'">{{ value.title }}</span>
    <template v-else-if="field.type === 'image'">
      <img :src="value.url" :alt="value.name" :class="large ? 'max-h-72 rounded-lg border border-slate-200 object-contain dark:border-slate-700' : 'h-9 w-9 rounded-md object-cover ring-1 ring-slate-200 dark:ring-slate-700'" loading="lazy">
    </template>
    <a v-else-if="field.type === 'file'" :href="value.url" target="_blank" rel="noopener" :class="[B.link, 'inline-flex items-center gap-1']"><s-icon name="document" sm />{{ value.name }}</a>
    <span v-else-if="field.type === 'color'" class="inline-flex items-center gap-2"><span class="h-4 w-4 rounded border border-slate-300 dark:border-slate-600" :style="{ backgroundColor: value }"></span><code class="text-xs">{{ value }}</code></span>
    <a v-else-if="field.type === 'url' && url" :href="url" target="_blank" rel="noopener noreferrer" :class="[B.link, 'inline-flex items-center gap-1']">{{ value }}<s-icon name="external" sm /></a>
    <a v-else-if="field.type === 'email'" :href="'mailto:' + value" :class="B.link">{{ value }}</a>
    <span v-else-if="field.type === 'date'">{{ dateText }}</span>
    <span v-else-if="field.type === 'datetime'">{{ dateTimeText }}</span>
    <span v-else-if="field.type === 'number'" class="tabular-nums">{{ numberText }}</span>
    <pre v-else-if="field.type === 'json' || field.type === 'code'" :class="large ? 'max-h-96 overflow-auto rounded-lg bg-slate-100 p-3 text-xs dark:bg-slate-800' : 'max-w-xs truncate text-xs'">{{ value }}</pre>
    <span v-else-if="field.type === 'textarea'" :class="large ? 'whitespace-pre-wrap break-words' : 'block max-w-xs truncate'">{{ value }}</span>
    <span v-else>{{ value }}</span>`,
};

// ---- form control for a field --------------------------------------------------------------
C['field-input'] = {
  props: { field: Object, modelValue: null, error: null, owner: String },
  emits: ['update:modelValue'],
  setup(props, { emit }) {
    const custom = computed(() => (Skinir._fields[props.field.type] || {}).input || null);
    const errors = computed(() => {
      const e = props.error;
      if (!e) return [];
      return (Array.isArray(e) ? e : [e]).map(m => props.field.label + ' ' + m);
    });
    const cls = computed(() => (errors.value.length ? B.inputError : B.input));
    const inputType = computed(() => ({ email: 'email', url: 'url', password: 'password' }[props.field.type] || 'text'));
    const set = v => emit('update:modelValue', v);

    // belongs_to options
    const options = ref([]);
    const optLoading = ref(false);
    const optSearch = ref('');
    let timer = null;
    async function loadOptions() {
      if (props.field.type !== 'belongs_to' || !props.owner) return;
      optLoading.value = true;
      try {
        const r = await api('GET', '/resources/' + encodeURIComponent(props.owner) + '/options/' +
          encodeURIComponent(props.field.attribute) + qs({ search: optSearch.value, current: props.modelValue }));
        options.value = r.data;
      } catch (e) { toast('error', e.message); }
      optLoading.value = false;
    }
    watch(optSearch, () => { clearTimeout(timer); timer = setTimeout(loadOptions, 250); });
    onMounted(loadOptions);
    onBeforeUnmount(() => clearTimeout(timer));

    // uploads
    const preview = computed(() => {
      const m = props.modelValue;
      if (m && m.file && props.field.type === 'image') return URL.createObjectURL(m.file);
      return m && !m.clear && m.current && props.field.type === 'image' ? m.current.url : null;
    });
    function pick(e) {
      const f = e.target.files && e.target.files[0];
      if (f) set(Object.assign({}, props.modelValue, { file: f, clear: false }));
    }
    function removeFile() { set(Object.assign({}, props.modelValue, { file: null, clear: true })); }

    const onClass = 'bg-brand-600';
    return { custom, errors, cls, inputType, set, options, optLoading, optSearch, preview, pick, removeFile, onClass };
  },
  template: `
    <div>
      <label v-if="field.type !== 'boolean'" :for="'f-' + field.attribute" class="mb-1.5 flex items-center gap-1.5 text-sm font-medium text-slate-700 dark:text-slate-300">
        {{ field.label }}<span v-if="field.required" class="text-red-500" :title="t('required')">*</span>
      </label>

      <component v-if="custom" :is="custom" :field="field" :modelValue="modelValue" :error="error" @update:modelValue="set" />

      <div v-else-if="field.readonly" class="rounded-lg bg-slate-50 px-3 py-2 text-sm dark:bg-slate-800/50"><field-display :field="field" :value="modelValue" /></div>

      <textarea v-else-if="field.type === 'textarea'" :id="'f-' + field.attribute" :rows="field.rows || 5" :class="cls" :placeholder="field.placeholder" :value="modelValue" @input="set($event.target.value)"></textarea>

      <textarea v-else-if="field.type === 'code'" :id="'f-' + field.attribute" rows="8" spellcheck="false" :class="[cls, 'font-mono text-xs']" :placeholder="field.placeholder" :value="modelValue" @input="set($event.target.value)"></textarea>

      <div v-else-if="field.type === 'boolean'" class="flex items-center gap-3 pt-1">
        <button type="button" role="switch" :aria-checked="!!modelValue" :id="'f-' + field.attribute" @click="set(!modelValue)"
                :class="['relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full transition focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-slate-900', modelValue ? 'bg-brand-600' : 'bg-slate-300 dark:bg-slate-700']">
          <span :class="['pointer-events-none mt-0.5 inline-block h-5 w-5 rounded-full bg-white shadow transition', modelValue ? 'translate-x-[22px]' : 'translate-x-0.5']"></span>
        </button>
        <span class="text-sm font-medium text-slate-700 dark:text-slate-300">{{ field.label }}</span>
      </div>

      <select v-else-if="field.type === 'select'" :id="'f-' + field.attribute" :class="cls" :value="modelValue === null || modelValue === undefined ? '' : modelValue" @change="set($event.target.value === '' ? null : $event.target.value)">
        <option v-if="!field.required || modelValue === null || modelValue === undefined || modelValue === ''" value="">{{ t('choose') }}</option>
        <option v-for="o in field.options" :key="o.value" :value="o.value">{{ o.label }}</option>
      </select>

      <div v-else-if="field.type === 'belongs_to'" class="space-y-2">
        <input v-if="field.searchable" type="search" v-model="optSearch" :placeholder="t('search_placeholder')" :class="B.input">
        <select :id="'f-' + field.attribute" :class="cls" :disabled="optLoading && !options.length" @change="set($event.target.value === '' ? null : $event.target.value)">
          <option value="" :selected="modelValue === null || modelValue === undefined || modelValue === ''">{{ t('choose') }}</option>
          <option v-for="o in options" :key="o.value" :value="o.value" :selected="String(o.value) === String(modelValue)">{{ o.label }}</option>
        </select>
      </div>

      <div v-else-if="field.type === 'number'" class="flex items-center gap-2">
        <span v-if="field.prefix" class="text-sm text-slate-500">{{ field.prefix }}</span>
        <input :id="'f-' + field.attribute" type="number" :step="field.step" :min="field.min" :max="field.max" :class="cls" :placeholder="field.placeholder" :value="modelValue" @input="set($event.target.value)">
        <span v-if="field.suffix" class="text-sm text-slate-500">{{ field.suffix }}</span>
      </div>

      <input v-else-if="field.type === 'date'" :id="'f-' + field.attribute" type="date" :class="cls" :value="modelValue" @input="set($event.target.value)">
      <input v-else-if="field.type === 'datetime'" :id="'f-' + field.attribute" type="datetime-local" :class="cls" :value="modelValue" @input="set($event.target.value)">

      <div v-else-if="field.type === 'color'" class="flex items-center gap-3">
        <input :id="'f-' + field.attribute" type="color" class="h-9 w-12 cursor-pointer rounded border border-slate-300 bg-white p-1 dark:border-slate-700 dark:bg-slate-900" :value="modelValue || '#000000'" @input="set($event.target.value)">
        <input type="text" maxlength="7" :class="[cls, 'max-w-[8rem] font-mono']" :value="modelValue" @input="set($event.target.value)" placeholder="#000000">
      </div>

      <div v-else-if="field.type === 'image' || field.type === 'file'" class="space-y-2">
        <div v-if="preview" class="flex items-center gap-3"><img :src="preview" alt="" class="h-20 w-20 rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-700"></div>
        <div v-else-if="modelValue && modelValue.current && !modelValue.clear && !modelValue.file" class="text-sm"><field-display :field="field" :value="modelValue.current" /></div>
        <div class="flex flex-wrap items-center gap-2">
          <label :class="[B.secondary, 'cursor-pointer']">
            <s-icon name="upload" sm />{{ t('choose_file') }}
            <input type="file" class="sr-only" :accept="field.accept" @change="pick">
          </label>
          <span v-if="modelValue && modelValue.file" class="truncate text-sm text-slate-500">{{ modelValue.file.name }}</span>
          <button v-if="modelValue && (modelValue.file || (modelValue.current && !modelValue.clear))" type="button" :class="B.ghostDanger" :title="t('remove_file')" @click="removeFile"><s-icon name="trash" sm /></button>
        </div>
      </div>

      <input v-else :id="'f-' + field.attribute" :type="inputType" :class="cls" :placeholder="field.type === 'password' && !field.required ? t('keep_password') : field.placeholder"
             :autocomplete="field.type === 'password' ? 'new-password' : 'off'" :value="modelValue" @input="set($event.target.value)">

      <p v-if="field.help" class="mt-1.5 text-xs text-slate-500 dark:text-slate-400">{{ field.help }}</p>
      <p v-for="(m, i) in errors" :key="i" class="mt-1.5 text-xs font-medium text-red-600 dark:text-red-400">{{ m }}</p>
    </div>`,
};

// ---- dashboard / resource cards -----------------------------------------------------------------
C['metric-card'] = {
  props: { metric: Object, scope: String },
  setup(props) {
    const data = ref(null);
    const loading = ref(true);
    const failed = ref(false);
    const range = ref(props.metric.default_range);
    const widths = { '1/3': '', '1/2': '', '2/3': 'lg:col-span-2', full: 'lg:col-span-3' };
    const widthClass = computed(() => widths[props.metric.width] || '');

    function rangeLabel(r) {
      if (/^\d+$/.test(String(r))) {
        return props.metric.type === 'trend' ? t('range_units_' + (props.metric.unit || 'day'), { n: r }) : t('range_days', { n: r });
      }
      return t('range_' + r);
    }

    let seq = 0;
    async function load() {
      const id = ++seq;
      loading.value = true; failed.value = false;
      const path = (props.scope === 'dashboard'
        ? '/metrics/dashboard/' + encodeURIComponent(props.metric.key)
        : '/metrics/resources/' + encodeURIComponent(props.scope) + '/' + encodeURIComponent(props.metric.key)) + qs({ range: range.value });
      try {
        const r = await api('GET', path);
        if (id === seq) data.value = r;
      } catch (e) { if (id === seq) failed.value = true; }
      if (id === seq) loading.value = false;
    }
    onMounted(load);
    watch(range, load);

    const fmt = v => (props.metric.prefix || '') + fmtNumber(v, props.metric.decimals) + (props.metric.suffix ? ' ' + props.metric.suffix : '');

    // trend sparkline
    const spark = computed(() => {
      const d = data.value;
      if (!d || !d.values || !d.values.length) return null;
      const w = 300, h = 64, v = d.values, max = Math.max.apply(null, v.concat([1])), min = Math.min.apply(null, v.concat([0]));
      const span = max - min || 1;
      const pts = v.map((y, i) => [v.length === 1 ? w / 2 : (i / (v.length - 1)) * w, h - 4 - ((y - min) / span) * (h - 10)]);
      const line = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
      return { line, area: line + ' L' + w + ' ' + h + ' L0 ' + h + ' Z' };
    });
    const total = computed(() => {
      const items = (data.value && data.value.items) || [];
      return items.reduce((a, x) => a + Number(x.value || 0), 0) || 1;
    });
    return { data, loading, failed, range, widthClass, rangeLabel, fmt, spark, total, fmtNumber };
  },
  template: `
    <div :class="[B.card, 'flex flex-col p-5', widthClass]">
      <div class="flex items-start justify-between gap-3">
        <h3 class="text-sm font-medium text-slate-500 dark:text-slate-400">{{ metric.label }}</h3>
        <select v-if="metric.ranges && metric.ranges.length > 1" v-model="range" class="rounded-md border-0 bg-slate-100 py-1 pl-2 pr-6 text-xs text-slate-600 focus:ring-2 focus:ring-brand-500 dark:bg-slate-800 dark:text-slate-300">
          <option v-for="r in metric.ranges" :key="r" :value="r">{{ rangeLabel(r) }}</option>
        </select>
      </div>

      <div v-if="loading && !data" class="mt-4 h-9 w-24 animate-pulse rounded bg-slate-100 dark:bg-slate-800"></div>
      <p v-else-if="failed" class="mt-4 text-sm text-red-500">{{ t('error_generic') }}</p>

      <template v-else-if="data">
        <template v-if="metric.type === 'value'">
          <p class="mt-2 text-3xl font-semibold tabular-nums text-slate-900 dark:text-white">{{ fmt(data.value) }}</p>
          <p v-if="data.change !== null && data.change !== undefined" :class="['mt-1 flex items-center gap-1 text-xs font-medium', data.change >= 0 ? 'text-emerald-600 dark:text-emerald-400' : 'text-red-600 dark:text-red-400']">
            <s-icon :name="data.change >= 0 ? 'arrow-up' : 'arrow-down'" sm />{{ Math.abs(data.change) }}%
            <span class="font-normal text-slate-400">{{ t('previous_period') }}</span>
          </p>
        </template>

        <template v-else-if="metric.type === 'trend'">
          <p class="mt-2 text-3xl font-semibold tabular-nums text-slate-900 dark:text-white">{{ fmt(data.total) }}</p>
          <svg v-if="spark" viewBox="0 0 300 64" preserveAspectRatio="none" class="mt-3 h-16 w-full text-brand-500">
            <path :d="spark.area" fill="currentColor" fill-opacity="0.12"></path>
            <path :d="spark.line" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"></path>
          </svg>
        </template>

        <template v-else-if="metric.type === 'partition'">
          <p v-if="!data.items.length" class="mt-4 text-sm text-slate-400">{{ t('no_data') }}</p>
          <ul v-else class="mt-3 space-y-2.5">
            <li v-for="(it, i) in data.items" :key="i">
              <div class="flex justify-between text-sm"><span class="truncate text-slate-600 dark:text-slate-300">{{ it.label }}</span><span class="ml-3 font-medium tabular-nums text-slate-900 dark:text-white">{{ fmt(it.value) }}</span></div>
              <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-slate-100 dark:bg-slate-800"><div class="h-full rounded-full bg-brand-500" :style="{ width: Math.max(2, (it.value / total) * 100) + '%' }"></div></div>
            </li>
          </ul>
        </template>
      </template>
    </div>`,
};


// ---------------------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------------------
C['view-notfound'] = {
  template: `
    <div class="mx-auto max-w-md py-24 text-center">
      <p class="text-5xl font-semibold text-slate-300 dark:text-slate-700">404</p>
      <h1 class="mt-4 text-xl font-semibold text-slate-900 dark:text-white">{{ t('not_found') }}</h1>
      <p class="mt-2 text-sm text-slate-500">{{ t('not_found_text') }}</p>
      <s-link to="" :class="[B.primary, 'mt-6']">{{ t('back_to_dashboard') }}</s-link>
    </div>`,
};

C['view-dashboard'] = {
  setup() { return { S, R }; },
  template: `
    <div>
      <h1 class="text-2xl font-semibold text-slate-900 dark:text-white">{{ t('dashboard') }}</h1>
      <div v-if="S.boot.dashboard.length" class="mt-6 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
        <metric-card v-for="m in S.boot.dashboard" :key="m.key" :metric="m" scope="dashboard" />
      </div>
      <section v-for="g in S.boot.navigation" :key="g.group" class="mt-8">
        <h2 class="mb-3 text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">{{ g.group }}</h2>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <s-link v-for="it in g.items" :key="it.key" :to="R.index(it.key)"
                  :class="[B.card, 'group flex items-center gap-3 p-4 transition hover:border-brand-300 hover:shadow-md dark:hover:border-brand-700']">
            <span class="flex h-9 w-9 items-center justify-center rounded-lg bg-brand-50 text-brand-600 dark:bg-brand-950 dark:text-brand-400"><s-icon :name="it.icon" /></span>
            <span class="text-sm font-medium text-slate-800 dark:text-slate-200">{{ it.label }}</span>
          </s-link>
        </div>
      </section>
    </div>`,
};

// ---- index -------------------------------------------------------------------------------------
C['view-index'] = {
  props: { resource: String },
  setup(props) {
    const st = reactive({
      loading: true, error: null, res: null, rows: [], meta: null, selected: [],
      search: '', page: 1, perPage: null, orderBy: null, orderDir: 'asc', trashed: '', filters: {},
      showFilters: false, bulk: '', modal: null,
    });

    function readUrl() {
      const p = new URLSearchParams(window.location.search);
      st.search = p.get('q') || '';
      st.page = parseInt(p.get('page') || '1', 10) || 1;
      st.perPage = p.get('per_page') ? parseInt(p.get('per_page'), 10) : null;
      st.orderBy = p.get('sort') || null;
      st.orderDir = p.get('dir') === 'desc' ? 'desc' : 'asc';
      st.trashed = p.get('trashed') || '';
      try { st.filters = JSON.parse(p.get('f') || '{}'); } catch (e) { st.filters = {}; }
      if (!st.filters || typeof st.filters !== 'object') st.filters = {};
    }

    function activeFilters() {
      const o = {};
      Object.keys(st.filters).forEach(k => {
        const v = st.filters[k];
        if (v === null || v === undefined || v === '') return;
        if (typeof v === 'object' && !v.from && !v.to) return;
        o[k] = v;
      });
      return o;
    }
    const filterCount = computed(() => Object.keys(activeFilters()).length + (st.trashed ? 1 : 0));

    function query() {
      const af = activeFilters();
      return {
        search: st.search, page: st.page, per_page: st.perPage, order_by: st.orderBy,
        order_dir: st.orderBy ? st.orderDir : '', trashed: st.trashed,
        filters: Object.keys(af).length ? JSON.stringify(af) : '',
      };
    }

    function writeUrl() {
      const af = activeFilters();
      const s = qs({
        q: st.search, page: st.page > 1 ? st.page : '', per_page: st.perPage, sort: st.orderBy,
        dir: st.orderBy ? st.orderDir : '', trashed: st.trashed, f: Object.keys(af).length ? JSON.stringify(af) : '',
      });
      window.history.replaceState({}, '', CFG.base + R.index(props.resource) + s);
    }

    let seq = 0;
    async function load(keepSelection) {
      const id = ++seq;
      st.loading = true; st.error = null;
      try {
        const r = await api('GET', '/resources/' + encodeURIComponent(props.resource) + qs(query()));
        if (id !== seq) return;
        st.res = r.resource; st.rows = r.data; st.meta = r.meta;
        const ids = r.data.map(x => x.id);
        st.selected = keepSelection ? st.selected.filter(x => ids.indexOf(x) >= 0) : [];
        if (st.page > r.meta.last_page) { st.page = r.meta.last_page; return load(keepSelection); }
        writeUrl();
        document.title = r.resource.label + ' · ' + S.boot.app.name;
      } catch (e) { if (id === seq) st.error = e.message; }
      if (id === seq) st.loading = false;
    }

    function apply() { st.page = 1; load(); }
    function resetFilters() { st.filters = {}; st.trashed = ''; apply(); }
    function goPage(p) { st.page = p; load(); }
    function sortBy(col) {
      if (!col.sortable) return;
      if (st.orderBy === col.attribute) st.orderDir = st.orderDir === 'asc' ? 'desc' : 'asc';
      else { st.orderBy = col.attribute; st.orderDir = 'asc'; }
      st.page = 1; load();
    }
    function setDate(key, side, v) {
      const cur = Object.assign({}, st.filters[key] || {});
      cur[side] = v;
      st.filters[key] = cur;
      apply();
    }

    let timer = null;
    watch(() => st.search, () => { clearTimeout(timer); timer = setTimeout(apply, 300); });
    onBeforeUnmount(() => clearTimeout(timer));
    readUrl();
    onMounted(() => load());

    // selection
    const allSelected = computed(() => st.rows.length > 0 && st.rows.every(r => st.selected.indexOf(r.id) >= 0));
    function toggleAll() { st.selected = allSelected.value ? [] : st.rows.map(r => r.id); }
    function toggle(id) {
      const i = st.selected.indexOf(id);
      if (i >= 0) st.selected.splice(i, 1); else st.selected.push(id);
    }
    const selectedRows = computed(() => st.rows.filter(r => st.selected.indexOf(r.id) >= 0));

    const bulkOps = computed(() => {
      const ops = [];
      if (!st.res) return ops;
      const rows = selectedRows.value;
      if (rows.some(r => r.abilities.delete)) ops.push({ key: '__delete', label: t('delete'), danger: true });
      if (st.res.soft_deletes) {
        if (rows.some(r => r.abilities.restore)) ops.push({ key: '__restore', label: t('restore') });
        if (rows.some(r => r.abilities.force_delete)) ops.push({ key: '__force_delete', label: t('force_delete'), danger: true });
      }
      (st.res.actions || []).filter(a => !a.standalone).forEach(a => ops.push({ key: 'a:' + a.key, label: a.name, danger: a.destructive, action: a }));
      return ops;
    });
    const standalone = computed(() => ((st.res && st.res.actions) || []).filter(a => a.standalone));

    function done(r) {
      let msg = t('bulk_done', { count: r.processed });
      if (r.skipped) msg += ' ' + t('bulk_skipped', { skipped: r.skipped });
      toast('success', msg);
    }

    async function runBulk() {
      const op = bulkOps.value.find(o => o.key === st.bulk);
      if (!op || !st.selected.length) return;
      if (op.action) return startAction(op.action);
      const resLabel = st.res.label.toLowerCase();
      const text = op.key === '__restore' ? t('confirm_restore_text', { resource: resLabel })
        : op.key === '__force_delete' ? t('confirm_force_text', { resource: resLabel })
        : t('confirm_delete_text', { resource: resLabel });
      const ok = await confirmDialog({ title: op.label, text, button: op.label, danger: !!op.danger });
      if (!ok) return;
      try {
        const r = await api('POST', '/resources/' + encodeURIComponent(props.resource) + '/bulk', { op: op.key.slice(2), ids: st.selected });
        done(r); st.bulk = ''; load();
      } catch (e) { toast('error', e.message); }
    }

    // custom actions
    function startAction(action) {
      if (action.fields && action.fields.length) {
        const values = {};
        action.fields.forEach(f => { values[f.attribute] = f.type === 'boolean' ? false : (f.type === 'select' || f.type === 'belongs_to' ? null : ''); });
        st.modal = { action, values, errors: null, busy: false };
      } else {
        confirmAction(action, {});
      }
    }
    async function confirmAction(action, values) {
      const ok = await confirmDialog({
        title: action.name, text: action.confirm_text || t('confirm_action_text'),
        button: action.confirm_button || action.name, danger: action.destructive,
      });
      if (ok) await execAction(action, values);
    }
    async function execAction(action, values) {
      try {
        const r = await api('POST', '/resources/' + encodeURIComponent(props.resource) + '/actions/' + encodeURIComponent(action.key),
          Object.assign({}, values, { ids: action.standalone ? [] : st.selected }));
        toast(r.type === 'error' ? 'error' : 'success', r.message);
        st.modal = null; st.bulk = '';
        if (r.redirect) { window.location.href = r.redirect; return; }
        load();
      } catch (e) {
        if (st.modal && e.errors) { st.modal.errors = e.errors; st.modal.busy = false; }
        else { toast('error', e.message); if (st.modal) st.modal.busy = false; }
      }
    }
    async function submitModal() {
      st.modal.busy = true; st.modal.errors = null;
      await execAction(st.modal.action, st.modal.values);
      if (st.modal) st.modal.busy = false;
    }

    // row actions
    async function removeRow(row) {
      const ok = await confirmDialog({
        title: t('confirm_delete_title', { resource: st.res.singular }),
        text: t('confirm_delete_text', { resource: st.res.singular.toLowerCase() }), button: t('delete'), danger: true,
      });
      if (!ok) return;
      try { await api('DELETE', '/resources/' + encodeURIComponent(props.resource) + '/' + encodeURIComponent(row.id)); toast('success', t('deleted')); load(true); }
      catch (e) { toast('error', e.message); }
    }
    async function restoreRow(row) {
      try { await api('POST', '/resources/' + encodeURIComponent(props.resource) + '/' + encodeURIComponent(row.id) + '/restore'); toast('success', t('restored')); load(true); }
      catch (e) { toast('error', e.message); }
    }
    async function forceRow(row) {
      const ok = await confirmDialog({
        title: t('force_delete'), text: t('confirm_force_text', { resource: st.res.singular.toLowerCase() }), button: t('force_delete'), danger: true,
      });
      if (!ok) return;
      try { await api('DELETE', '/resources/' + encodeURIComponent(props.resource) + '/' + encodeURIComponent(row.id) + '/force'); toast('success', t('deleted')); load(true); }
      catch (e) { toast('error', e.message); }
    }

    const pages = computed(() => {
      if (!st.meta) return [];
      const last = st.meta.last_page, cur = st.meta.current_page, out = [];
      let a = Math.max(1, cur - 2), b = Math.min(last, cur + 2);
      if (a > 1) { out.push(1); if (a > 2) out.push('…'); }
      for (let i = a; i <= b; i++) out.push(i);
      if (b < last) { if (b < last - 1) out.push('…'); out.push(last); }
      return out;
    });

    return {
      st, R, S, load, apply, resetFilters, goPage, sortBy, setDate, filterCount, allSelected, toggleAll, toggle,
      bulkOps, standalone, runBulk, startAction, submitModal, removeRow, restoreRow, forceRow, pages,
    };
  },
  template: `
    <div>
      <div v-if="st.error" :class="[B.card, 'p-8 text-center']">
        <p class="text-sm text-red-600 dark:text-red-400">{{ st.error }}</p>
        <s-link to="" :class="[B.secondary, 'mt-4']">{{ t('back_to_dashboard') }}</s-link>
      </div>

      <template v-else>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold text-slate-900 dark:text-white">{{ st.res ? st.res.label : '' }}</h1>
          <div v-if="st.res" class="flex flex-wrap items-center gap-2">
            <button v-for="a in standalone" :key="a.key" type="button" :class="a.destructive ? B.danger : B.secondary" @click="startAction(a)">{{ a.name }}</button>
            <s-link v-if="st.res.can_create" :to="R.create(resource)" :class="B.primary"><s-icon name="plus" sm />{{ t('create_resource', { resource: st.res.singular }) }}</s-link>
          </div>
        </div>

        <div v-if="st.res && st.res.cards.length" class="mt-6 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          <metric-card v-for="m in st.res.cards" :key="m.key" :metric="m" :scope="resource" />
        </div>

        <div :class="[B.card, 'mt-6 overflow-hidden']">
          <!-- toolbar -->
          <div class="flex flex-wrap items-center gap-3 border-b border-slate-200 p-3 dark:border-slate-800">
            <div v-if="!st.res || st.res.searchable" class="relative min-w-[12rem] flex-1 sm:max-w-xs">
              <s-icon name="search" sm class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
              <input type="search" v-model="st.search" :placeholder="t('search_placeholder')" :class="[B.input, 'pl-9']">
            </div>
            <div class="ml-auto flex items-center gap-2">
              <button v-if="st.res && (st.res.filters.length || st.res.soft_deletes)" type="button" :class="B.secondary" @click="st.showFilters = !st.showFilters">
                <s-icon name="filter" sm />{{ t('filters') }}
                <span v-if="filterCount" class="rounded-full bg-brand-600 px-1.5 text-xs font-semibold text-white">{{ filterCount }}</span>
              </button>
              <button type="button" :class="B.ghost" :title="t('loading')" @click="load(true)"><s-icon name="refresh" sm /></button>
            </div>
          </div>

          <!-- filters -->
          <div v-if="st.showFilters && st.res" class="grid gap-4 border-b border-slate-200 bg-slate-50/60 p-4 sm:grid-cols-2 lg:grid-cols-4 dark:border-slate-800 dark:bg-slate-900/50">
            <div v-if="st.res.soft_deletes">
              <label class="mb-1.5 block text-xs font-medium text-slate-500 dark:text-slate-400">{{ t('trashed') }}</label>
              <select v-model="st.trashed" :class="B.input" @change="apply">
                <option value="">{{ t('without_trashed') }}</option>
                <option value="with">{{ t('with_trashed') }}</option>
                <option value="only">{{ t('only_trashed') }}</option>
              </select>
            </div>
            <div v-for="f in st.res.filters" :key="f.key">
              <label class="mb-1.5 block text-xs font-medium text-slate-500 dark:text-slate-400">{{ f.label }}</label>
              <select v-if="f.type === 'select'" v-model="st.filters[f.key]" :class="B.input" @change="apply">
                <option value="">{{ t('all') }}</option>
                <option v-for="o in f.options" :key="o.value" :value="o.value">{{ o.label }}</option>
              </select>
              <select v-else-if="f.type === 'boolean'" v-model="st.filters[f.key]" :class="B.input" @change="apply">
                <option value="">{{ t('all') }}</option>
                <option value="true">{{ t('yes') }}</option>
                <option value="false">{{ t('no') }}</option>
              </select>
              <input v-else-if="f.type === 'text'" type="text" v-model.lazy="st.filters[f.key]" :class="B.input" @change="apply">
              <div v-else-if="f.type === 'date'" class="flex items-center gap-2">
                <input type="date" :value="(st.filters[f.key] || {}).from" :class="B.input" :aria-label="t('from')" @change="setDate(f.key, 'from', $event.target.value)">
                <input type="date" :value="(st.filters[f.key] || {}).to" :class="B.input" :aria-label="t('to')" @change="setDate(f.key, 'to', $event.target.value)">
              </div>
            </div>
            <div class="flex items-end"><button type="button" :class="B.secondary" @click="resetFilters">{{ t('reset_filters') }}</button></div>
          </div>

          <!-- bulk bar -->
          <div v-if="st.selected.length" class="flex flex-wrap items-center gap-3 border-b border-brand-200 bg-brand-50 px-4 py-2.5 text-sm dark:border-brand-900 dark:bg-brand-950/50">
            <span class="font-medium text-brand-800 dark:text-brand-200">{{ t('selected', { count: st.selected.length }) }}</span>
            <select v-model="st.bulk" :class="[B.input, 'max-w-[14rem] py-1.5']">
              <option value="">{{ t('select_action') }}</option>
              <option v-for="o in bulkOps" :key="o.key" :value="o.key">{{ o.label }}</option>
            </select>
            <button type="button" :class="B.primary" :disabled="!st.bulk" @click="runBulk">{{ t('run') }}</button>
            <button type="button" class="ml-auto text-xs text-brand-700 hover:underline dark:text-brand-300" @click="st.selected = []">{{ t('clear_selection') }}</button>
          </div>

          <!-- table -->
          <div :class="['overflow-x-auto transition-opacity', st.loading ? 'opacity-60' : '']">
            <table class="min-w-full divide-y divide-slate-200 text-sm dark:divide-slate-800">
              <thead class="bg-slate-50 dark:bg-slate-900/60">
                <tr>
                  <th class="w-10 px-4 py-3"><input type="checkbox" :checked="allSelected" :aria-label="t('select_all')" class="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500 dark:border-slate-600 dark:bg-slate-800" @change="toggleAll"></th>
                  <th v-for="col in (st.res ? st.res.columns : [])" :key="col.attribute" scope="col" class="whitespace-nowrap px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    <button v-if="col.sortable" type="button" class="inline-flex items-center gap-1 uppercase tracking-wide hover:text-slate-900 dark:hover:text-white" @click="sortBy(col)">
                      {{ col.label }}
                      <s-icon v-if="st.orderBy === col.attribute" :name="st.orderDir === 'asc' ? 'arrow-up' : 'arrow-down'" sm />
                    </button>
                    <span v-else>{{ col.label }}</span>
                  </th>
                  <th class="px-4 py-3"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-100 dark:divide-slate-800/70">
                <tr v-for="row in st.rows" :key="row.id" :class="[st.selected.indexOf(row.id) >= 0 ? 'bg-brand-50/40 dark:bg-brand-950/20' : '', row.trashed ? 'opacity-60' : '', 'hover:bg-slate-50 dark:hover:bg-slate-800/40']">
                  <td class="px-4 py-3"><input type="checkbox" :checked="st.selected.indexOf(row.id) >= 0" class="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500 dark:border-slate-600 dark:bg-slate-800" @change="toggle(row.id)"></td>
                  <td v-for="(col, ci) in st.res.columns" :key="col.attribute" class="whitespace-nowrap px-4 py-3 text-slate-700 dark:text-slate-300">
                    <s-link v-if="ci === 0 && col.type !== 'image' && col.type !== 'belongs_to'" :to="R.detail(resource, row.id)" :class="B.link"><field-display :field="col" :value="row.fields[col.attribute]" /></s-link>
                    <field-display v-else :field="col" :value="row.fields[col.attribute]" />
                  </td>
                  <td class="whitespace-nowrap px-4 py-3 text-right">
                    <div class="inline-flex items-center gap-0.5">
                      <s-link v-if="row.abilities.view" :to="R.detail(resource, row.id)" :class="B.ghost" :title="t('view')"><s-icon name="eye" sm /></s-link>
                      <s-link v-if="row.abilities.update" :to="R.edit(resource, row.id)" :class="B.ghost" :title="t('edit')"><s-icon name="pencil" sm /></s-link>
                      <button v-if="row.abilities.delete" type="button" :class="B.ghostDanger" :title="t('delete')" @click="removeRow(row)"><s-icon name="trash" sm /></button>
                      <button v-if="row.abilities.restore" type="button" :class="B.ghost" :title="t('restore')" @click="restoreRow(row)"><s-icon name="refresh" sm /></button>
                      <button v-if="row.abilities.force_delete" type="button" :class="B.ghostDanger" :title="t('force_delete')" @click="forceRow(row)"><s-icon name="trash" sm /></button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>

            <div v-if="!st.loading && !st.rows.length" class="px-6 py-16 text-center">
              <s-icon name="inbox" class="mx-auto text-slate-300 dark:text-slate-600" />
              <p class="mt-3 text-sm font-medium text-slate-700 dark:text-slate-300">{{ t('no_results', { resource: st.res ? st.res.label.toLowerCase() : '' }) }}</p>
              <p class="mt-1 text-xs text-slate-500">{{ t('no_results_hint') }}</p>
            </div>
            <div v-if="st.loading && !st.rows.length" class="px-6 py-16 text-center text-sm text-slate-400">{{ t('loading') }}</div>
          </div>

          <!-- pagination -->
          <div v-if="st.meta && st.meta.total" class="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200 px-4 py-3 text-sm dark:border-slate-800">
            <div class="flex items-center gap-3 text-slate-500 dark:text-slate-400">
              <span>{{ t('showing', { from: st.meta.from, to: st.meta.to, total: st.meta.total }) }}</span>
              <label class="flex items-center gap-2"><span class="hidden sm:inline">{{ t('per_page') }}</span>
                <select :value="st.meta.per_page" class="rounded-md border-0 bg-slate-100 py-1 pl-2 pr-7 text-xs focus:ring-2 focus:ring-brand-500 dark:bg-slate-800" @change="st.perPage = parseInt($event.target.value, 10); apply()">
                  <option v-for="n in S.boot.per_page_options" :key="n" :value="n">{{ n }}</option>
                </select>
              </label>
            </div>
            <nav class="flex items-center gap-1" aria-label="Pagination">
              <button type="button" :class="B.ghost" :disabled="st.meta.current_page <= 1" :title="t('previous')" @click="goPage(st.meta.current_page - 1)"><s-icon name="chevron-left" sm /></button>
              <template v-for="(p, i) in pages" :key="i">
                <span v-if="p === '…'" class="px-1 text-slate-400">…</span>
                <button v-else type="button" :class="['h-8 min-w-[2rem] rounded-lg px-2 text-sm font-medium', p === st.meta.current_page ? 'bg-brand-600 text-white' : 'text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800']" @click="goPage(p)">{{ p }}</button>
              </template>
              <button type="button" :class="B.ghost" :disabled="st.meta.current_page >= st.meta.last_page" :title="t('next')" @click="goPage(st.meta.current_page + 1)"><s-icon name="chevron-right" sm /></button>
            </nav>
          </div>
        </div>
      </template>

      <!-- action with fields -->
      <s-modal v-if="st.modal" :title="st.modal.action.name" @close="st.modal = null">
        <p v-if="st.modal.action.confirm_text" class="mb-4 text-sm text-slate-600 dark:text-slate-300">{{ st.modal.action.confirm_text }}</p>
        <div class="space-y-4">
          <field-input v-for="f in st.modal.action.fields" :key="f.attribute" :field="f" :owner="resource"
                       :modelValue="st.modal.values[f.attribute]" @update:modelValue="st.modal.values[f.attribute] = $event"
                       :error="st.modal.errors && st.modal.errors[f.attribute]" />
        </div>
        <template #footer>
          <button type="button" :class="B.secondary" @click="st.modal = null">{{ t('cancel') }}</button>
          <button type="button" :class="st.modal.action.destructive ? B.danger : B.primary" :disabled="st.modal.busy" @click="submitModal">{{ st.modal.action.confirm_button || st.modal.action.name }}</button>
        </template>
      </s-modal>
    </div>`,
};

// ---- detail ------------------------------------------------------------------------------------
C['view-detail'] = {
  props: { resource: String, id: String },
  setup(props) {
    const st = reactive({ loading: true, error: null, d: null });
    const base = () => '/resources/' + encodeURIComponent(props.resource) + '/' + encodeURIComponent(props.id);

    async function load() {
      st.loading = true; st.error = null;
      try {
        st.d = await api('GET', base());
        document.title = st.d.title + ' · ' + S.boot.app.name;
      } catch (e) { st.error = e.message; }
      st.loading = false;
    }
    onMounted(load);

    async function remove() {
      const ok = await confirmDialog({
        title: t('confirm_delete_title', { resource: st.d.resource.singular }),
        text: t('confirm_delete_text', { resource: st.d.resource.singular.toLowerCase() }), button: t('delete'), danger: true,
      });
      if (!ok) return;
      try { await api('DELETE', base()); toast('success', t('deleted')); navigate(R.index(props.resource)); }
      catch (e) { toast('error', e.message); }
    }
    async function restore() {
      try { await api('POST', base() + '/restore'); toast('success', t('restored')); load(); }
      catch (e) { toast('error', e.message); }
    }
    async function force() {
      const ok = await confirmDialog({
        title: t('force_delete'), text: t('confirm_force_text', { resource: st.d.resource.singular.toLowerCase() }), button: t('force_delete'), danger: true,
      });
      if (!ok) return;
      try { await api('DELETE', base() + '/force'); toast('success', t('deleted')); navigate(R.index(props.resource)); }
      catch (e) { toast('error', e.message); }
    }
    return { st, R, remove, restore, force };
  },
  template: `
    <div>
      <div v-if="st.error" :class="[B.card, 'p-8 text-center']">
        <p class="text-sm text-red-600 dark:text-red-400">{{ st.error }}</p>
        <s-link :to="R.index(resource)" :class="[B.secondary, 'mt-4']">{{ t('back_to_dashboard') }}</s-link>
      </div>
      <div v-else-if="st.loading && !st.d" class="py-20 text-center text-sm text-slate-400">{{ t('loading') }}</div>
      <template v-else-if="st.d">
        <nav class="mb-2 text-sm text-slate-500 dark:text-slate-400"><s-link :to="R.index(resource)" :class="'hover:text-slate-900 dark:hover:text-white'">{{ st.d.resource.label }}</s-link></nav>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="flex items-center gap-3 text-2xl font-semibold text-slate-900 dark:text-white">
            {{ st.d.title }}
            <span v-if="st.d.trashed" class="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">{{ t('trashed') }}</span>
          </h1>
          <div class="flex items-center gap-2">
            <s-link v-if="st.d.abilities.update" :to="R.edit(resource, id)" :class="B.primary"><s-icon name="pencil" sm />{{ t('edit') }}</s-link>
            <button v-if="st.d.abilities.delete" type="button" :class="B.secondary" @click="remove"><s-icon name="trash" sm />{{ t('delete') }}</button>
            <button v-if="st.d.abilities.restore" type="button" :class="B.secondary" @click="restore"><s-icon name="refresh" sm />{{ t('restore') }}</button>
            <button v-if="st.d.abilities.force_delete" type="button" :class="B.danger" @click="force"><s-icon name="trash" sm />{{ t('force_delete') }}</button>
          </div>
        </div>

        <div :class="[B.card, 'mt-6']">
          <dl class="divide-y divide-slate-100 dark:divide-slate-800">
            <div v-for="f in st.d.fields" :key="f.attribute" class="grid gap-1 px-5 py-4 sm:grid-cols-3 sm:gap-4">
              <dt class="text-sm font-medium text-slate-500 dark:text-slate-400">{{ f.label }}</dt>
              <dd class="text-sm text-slate-900 sm:col-span-2 dark:text-slate-100"><field-display :field="f" :value="f.value" large /></dd>
            </div>
          </dl>
        </div>

        <section v-for="p in st.d.panels" :key="p.attribute" :class="[B.card, 'mt-6']">
          <div class="flex items-center justify-between border-b border-slate-200 px-5 py-3 dark:border-slate-800">
            <h2 class="text-sm font-semibold text-slate-900 dark:text-white">{{ p.label }} <span class="ml-1 font-normal text-slate-400">{{ t('related_count', { count: p.total }) }}</span></h2>
            <s-link :to="R.index(p.resource)" :class="[B.link, 'text-xs']">{{ t('view_all') }}</s-link>
          </div>
          <ul class="divide-y divide-slate-100 dark:divide-slate-800">
            <li v-for="r in p.rows" :key="r.id" class="px-5 py-2.5 text-sm"><s-link :to="R.detail(p.resource, r.id)" :class="B.link">{{ r.title }}</s-link></li>
            <li v-if="!p.rows.length" class="px-5 py-4 text-sm text-slate-400">{{ t('no_data') }}</li>
          </ul>
        </section>
      </template>
    </div>`,
};

// ---- create / edit -------------------------------------------------------------------------------
C['view-form'] = {
  props: { resource: String, id: String, mode: String },
  setup(props) {
    const st = reactive({ loading: true, error: null, d: null, values: {}, errors: null, busy: false });
    const isUpload = f => f.type === 'image' || f.type === 'file';

    async function load() {
      st.loading = true; st.error = null;
      const path = '/resources/' + encodeURIComponent(props.resource) +
        (props.mode === 'edit' ? '/' + encodeURIComponent(props.id) + '/update-fields' : '/creation-fields');
      try {
        const d = await api('GET', path);
        const values = {};
        d.fields.forEach(f => {
          let v = f.value;
          if (f.type === 'datetime') v = isoToLocalInput(v);
          else if (f.type === 'boolean') v = !!v;
          else if (isUpload(f)) v = { file: null, clear: false, current: v || null };
          else if (v === null || v === undefined) v = (f.type === 'belongs_to' || f.type === 'select') ? null : '';
          values[f.attribute] = v;
        });
        st.d = d; st.values = values;
        document.title = (props.mode === 'edit' ? d.title : t('create_resource', { resource: d.resource.singular })) + ' · ' + S.boot.app.name;
      } catch (e) { st.error = e.message; }
      st.loading = false;
    }
    onMounted(load);

    function payload() {
      const out = {};
      st.d.fields.forEach(f => {
        if (f.readonly || isUpload(f)) return;
        let v = st.values[f.attribute];
        if (f.type === 'datetime') v = localInputToUtc(v);
        else if (f.type === 'number' || f.type === 'select' || f.type === 'belongs_to') v = (v === '' || v === undefined) ? null : v;
        else if (f.type === 'boolean') v = !!v;
        out[f.attribute] = v;
      });
      return out;
    }

    function formData(obj) {
      const fd = new FormData();
      Object.keys(obj).forEach(k => {
        const v = obj[k];
        fd.append(k, v === null || v === undefined ? '' : (typeof v === 'boolean' ? (v ? 'true' : 'false') : String(v)));
      });
      st.d.fields.filter(isUpload).forEach(f => {
        const u = st.values[f.attribute];
        if (u.file) fd.append(f.attribute, u.file);
        else if (u.clear) fd.append('__clear_' + f.attribute, '1');
      });
      return fd;
    }

    async function submit() {
      st.busy = true; st.errors = null;
      const hasUploads = st.d.fields.some(isUpload);
      const body = hasUploads ? formData(payload()) : payload();
      const base = '/resources/' + encodeURIComponent(props.resource);
      try {
        const r = props.mode === 'edit' ? await api('PUT', base + '/' + encodeURIComponent(props.id), body) : await api('POST', base, body);
        toast('success', t(props.mode === 'edit' ? 'updated' : 'created'));
        navigate(R.detail(props.resource, r.id));
        return;
      } catch (e) {
        if (e.status === 422 && e.errors) {
          st.errors = e.errors;
          toast('error', t('error_validation'));
          nextTick(() => { const el = document.querySelector('[data-skinir-form] .text-red-600'); if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' }); });
        } else toast('error', e.message);
      }
      st.busy = false;
    }
    function cancel() { navigate(props.mode === 'edit' ? R.detail(props.resource, props.id) : R.index(props.resource)); }
    return { st, submit, cancel, R };
  },
  template: `
    <div>
      <div v-if="st.error" :class="[B.card, 'p-8 text-center']">
        <p class="text-sm text-red-600 dark:text-red-400">{{ st.error }}</p>
        <s-link :to="R.index(resource)" :class="[B.secondary, 'mt-4']">{{ t('back_to_dashboard') }}</s-link>
      </div>
      <div v-else-if="st.loading" class="py-20 text-center text-sm text-slate-400">{{ t('loading') }}</div>
      <template v-else-if="st.d">
        <nav class="mb-2 text-sm text-slate-500 dark:text-slate-400"><s-link :to="R.index(resource)" :class="'hover:text-slate-900 dark:hover:text-white'">{{ st.d.resource.label }}</s-link></nav>
        <h1 class="text-2xl font-semibold text-slate-900 dark:text-white">{{ mode === 'edit' ? t('edit_resource', { resource: st.d.resource.singular }) : t('create_resource', { resource: st.d.resource.singular }) }}</h1>

        <form data-skinir-form :class="[B.card, 'mt-6']" novalidate @submit.prevent="submit">
          <div class="space-y-5 p-5 sm:p-6">
            <field-input v-for="f in st.d.fields" :key="f.attribute" :field="f" :owner="resource"
                         :modelValue="st.values[f.attribute]" @update:modelValue="st.values[f.attribute] = $event"
                         :error="st.errors && st.errors[f.attribute]" />
          </div>
          <div class="flex justify-end gap-2 border-t border-slate-200 bg-slate-50/60 px-5 py-3 sm:px-6 dark:border-slate-800 dark:bg-slate-900/50">
            <button type="button" :class="B.secondary" @click="cancel">{{ t('cancel') }}</button>
            <button type="submit" :class="B.primary" :disabled="st.busy">{{ st.busy ? t('saving') : (mode === 'edit' ? t('update_resource', { resource: st.d.resource.singular }) : t('create_and_save', { resource: st.d.resource.singular })) }}</button>
          </div>
        </form>
      </template>
    </div>`,
};


// ---------------------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------------------
C['skinir-app'] = {
  setup() {
    const nonce = ref(0);

    const view = computed(() => {
      const r = S.route;
      switch (r.name) {
        case 'dashboard': return { name: 'view-dashboard', props: {}, key: 'dashboard' };
        case 'index': return { name: 'view-index', props: { resource: r.resource }, key: 'index:' + r.resource };
        case 'detail': return { name: 'view-detail', props: { resource: r.resource, id: r.id }, key: 'detail:' + r.resource + ':' + r.id };
        case 'create': return { name: 'view-form', props: { resource: r.resource, mode: 'create' }, key: 'create:' + r.resource };
        case 'edit': return { name: 'view-form', props: { resource: r.resource, id: r.id, mode: 'edit' }, key: 'edit:' + r.resource + ':' + r.id };
        default: return { name: 'view-notfound', props: {}, key: 'nf' };
      }
    });

    const activeKey = computed(() => S.route.resource || null);
    const initial = computed(() => (S.boot.app.name || '?').charAt(0).toUpperCase());
    const userInitial = computed(() => (S.boot.user.name || '?').charAt(0).toUpperCase());

    function toggleTheme() {
      S.dark = !S.dark;
      document.documentElement.classList.toggle('dark', S.dark);
      try { localStorage.setItem('skinir-theme', S.dark ? 'dark' : 'light'); } catch (e) { /* private mode */ }
    }

    async function setLocale(l) {
      S.menu = false;
      if (l === S.boot.locale) return;
      try {
        await api('POST', '/locale', { locale: l });
        await Skinir._loadBoot();
        nonce.value++;
      } catch (e) { toast('error', e.message); }
    }

    async function logout() {
      try {
        const r = await api('POST', '/logout');
        window.location.href = r.redirect;
      } catch (e) { toast('error', e.message); }
    }

    // close user menu when clicking elsewhere
    const away = e => { if (S.menu && !e.target.closest('[data-skinir-menu]')) S.menu = false; };
    onMounted(() => document.addEventListener('click', away));
    onBeforeUnmount(() => document.removeEventListener('click', away));

    return { S, R, view, nonce, activeKey, initial, userInitial, toggleTheme, setLocale, logout };
  },
  template: `
    <div class="min-h-full">
      <!-- mobile overlay -->
      <div v-if="S.sidebar" class="fixed inset-0 z-30 bg-slate-900/50 lg:hidden" @click="S.sidebar = false"></div>

      <!-- sidebar -->
      <aside :class="['fixed inset-y-0 left-0 z-40 flex w-64 flex-col border-r border-slate-200 bg-white transition-transform dark:border-slate-800 dark:bg-slate-900 lg:translate-x-0', S.sidebar ? 'translate-x-0' : '-translate-x-full']">
        <s-link to="" class="flex h-16 shrink-0 items-center gap-3 border-b border-slate-200 px-5 dark:border-slate-800">
          <img v-if="S.boot.app.logo" :src="S.boot.app.logo" alt="" class="h-8 w-auto">
          <span v-else class="flex h-8 w-8 items-center justify-center rounded-lg bg-brand-600 text-sm font-bold text-white">{{ initial }}</span>
          <span class="truncate text-base font-semibold text-slate-900 dark:text-white">{{ S.boot.app.name }}</span>
        </s-link>
        <nav class="flex-1 space-y-6 overflow-y-auto px-3 py-5">
          <s-link to="" :class="['flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium', S.route.name === 'dashboard' ? 'bg-brand-50 text-brand-700 dark:bg-brand-950 dark:text-brand-300' : 'text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800']">
            <s-icon name="home" />{{ t('dashboard') }}
          </s-link>
          <div v-for="g in S.boot.navigation" :key="g.group">
            <p class="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-slate-400 dark:text-slate-500">{{ g.group }}</p>
            <ul class="space-y-1">
              <li v-for="it in g.items" :key="it.key">
                <s-link :to="R.index(it.key)" :class="['flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium', activeKey === it.key ? 'bg-brand-50 text-brand-700 dark:bg-brand-950 dark:text-brand-300' : 'text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800']">
                  <s-icon :name="it.icon" />{{ it.label }}
                </s-link>
              </li>
            </ul>
          </div>
        </nav>
      </aside>

      <div class="lg:pl-64">
        <!-- topbar -->
        <header class="sticky top-0 z-20 flex h-16 items-center gap-3 border-b border-slate-200 bg-white/80 px-4 backdrop-blur dark:border-slate-800 dark:bg-slate-900/80 sm:px-6 lg:px-8">
          <button type="button" :class="[B.ghost, 'lg:hidden']" :title="t('toggle_menu')" @click="S.sidebar = !S.sidebar"><s-icon name="menu" /></button>
          <div class="ml-auto flex items-center gap-1">
            <button type="button" :class="B.ghost" :title="S.dark ? t('theme_light') : t('theme_dark')" @click="toggleTheme"><s-icon :name="S.dark ? 'sun' : 'moon'" /></button>
            <div class="relative" data-skinir-menu>
              <button type="button" class="ml-1 flex items-center gap-2 rounded-lg py-1 pl-1 pr-2 hover:bg-slate-100 dark:hover:bg-slate-800" @click="S.menu = !S.menu">
                <span class="flex h-8 w-8 items-center justify-center rounded-full bg-brand-100 text-sm font-semibold text-brand-700 dark:bg-brand-900 dark:text-brand-200">{{ userInitial }}</span>
                <span class="hidden max-w-[10rem] truncate text-sm font-medium text-slate-700 dark:text-slate-200 sm:block">{{ S.boot.user.name }}</span>
                <s-icon name="chevron-down" sm class="text-slate-400" />
              </button>
              <div v-if="S.menu" class="absolute right-0 mt-2 w-56 overflow-hidden rounded-xl border border-slate-200 bg-white py-1 shadow-lg dark:border-slate-700 dark:bg-slate-900">
                <div class="border-b border-slate-100 px-4 py-2 dark:border-slate-800">
                  <p class="truncate text-sm font-medium text-slate-900 dark:text-white">{{ S.boot.user.name }}</p>
                  <p class="truncate text-xs text-slate-500">{{ S.boot.user.login }}</p>
                </div>
                <div v-if="S.boot.locales.length > 1" class="border-b border-slate-100 px-4 py-2 dark:border-slate-800">
                  <p class="mb-1 flex items-center gap-1 text-xs text-slate-500"><s-icon name="globe" sm />{{ t('language') }}</p>
                  <div class="flex flex-wrap gap-1">
                    <button v-for="l in S.boot.locales" :key="l" type="button" :class="['rounded-md px-2 py-0.5 text-xs font-medium', l === S.boot.locale ? 'bg-brand-600 text-white' : 'bg-slate-100 text-slate-600 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700']" @click="setLocale(l)">{{ l.toUpperCase() }}</button>
                  </div>
                </div>
                <button type="button" class="flex w-full items-center gap-2 px-4 py-2 text-left text-sm text-slate-700 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-800" @click="logout"><s-icon name="logout" sm />{{ t('sign_out') }}</button>
              </div>
            </div>
          </div>
        </header>

        <main class="px-4 py-6 sm:px-6 lg:px-8">
          <component :is="view.name" v-bind="view.props" :key="view.key + ':' + nonce" />
        </main>
      </div>

      <s-toasts />
      <s-confirm />
    </div>`,
};

// ---------------------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------------------
Skinir._loadBoot = async function () {
  S.boot = await api('GET', '/bootstrap');
  document.documentElement.lang = S.boot.locale;
};

Skinir.boot = async function () {
  const mount = document.getElementById('app');
  try {
    await Skinir._loadBoot();
  } catch (e) {
    const box = document.createElement('div');
    box.style.cssText = 'padding:2rem;font-family:system-ui,sans-serif';
    box.textContent = e.message || 'Could not start the panel.';
    mount.appendChild(box);
    return;
  }

  S.route = parsePath();
  window.addEventListener('popstate', () => { S.route = parsePath(); });

  const app = createApp({ template: '<skinir-app />' });
  Object.keys(C).forEach(k => app.component(k, C[k]));
  Object.keys(Skinir._components).forEach(k => app.component(k, Skinir._components[k]));
  Object.assign(app.config.globalProperties, { t, B, BADGE, R, S, fmtNumber });
  app.mount('#app');
};

Skinir.api = api;
Skinir.t = t;
Skinir.navigate = navigate;
Skinir.toast = toast;
Skinir.confirm = confirmDialog;
Skinir.helpers = { fmtNumber, fmtDate, fmtDateTime, B, BADGE, ICONS };
global.Skinir = Skinir;

})(window);
