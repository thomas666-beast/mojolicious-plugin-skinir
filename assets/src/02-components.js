
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
