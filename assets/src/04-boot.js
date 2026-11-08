
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
