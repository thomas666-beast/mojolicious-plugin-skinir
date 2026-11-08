
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
