// Device CleanUpper - the browser front end.
//
// This page decides nothing about safety. It shows what the host says:
// how far the workflow is open (gate / status), what a run would do (the
// plan), and what happened (events, outcomes). The host re-checks every run,
// so a bug here can make the page confusing, not dangerous.

import { api, initToken, list, ApiError } from './api.js';
import { h, fill, icon } from './dom.js';

const $ = (id) => document.getElementById(id);

const S = {
  steps: [], byKey: {},
  st: null,                       // GET /api/state
  devices: [], safe: new Set(), devicesVersion: -1,
  selected: new Set(),
  page: 'setup',
  seq: 0,
  activity: [], activityLabel: '', progress: null, live: null, showDetail: false,
  filter: 'all', search: '',
  options: {},                    // step -> { option: value }
  plan: null, planFor: null, planSeq: 0,
  input: { tab: 'paste', append: true, text: '', rows: [{ Serial: '', Name: '', Note: '' }],
           file: null, sheet: '', serialColumn: '', nameColumn: '', noteColumn: '' },
};

// the rail: Setup, the list + lookup on one page (they are two halves of one
// job - a list nobody looked up is of no use), then one page per step
function pages() {
  const rest = S.steps.filter((s) => s.Key !== 'DeviceInput' && s.Key !== 'Lookup')
    .map((s) => ({ id: s.Key, number: s.Number, name: s.Name, run: s.Key }));
  return [
    { id: 'setup', number: '0', name: 'Setup and sign in', run: null },
    { id: 'devices', number: '1', name: 'Devices to release and look up', run: 'Lookup' },
    ...rest,
  ];
}
const pageById = (id) => pages().find((p) => p.id === id);
const statusOf = (key) => list(S.st?.status).find((r) => r.Key === key);
const signedIn = () => Boolean(S.st?.signIn?.SignedIn);
const busy = () => S.st?.busy || null;

// ---------------------------------------------------------------------------
// talking to the host
// ---------------------------------------------------------------------------
async function refreshState() {
  S.st = await api('GET', '/api/state');
  renderTopbar(); renderStepper();
  if (S.page === 'setup') renderSetupStatus();
  if (S.page === 'devices') renderSavedList();
  renderCallout(); renderResult();
  if (S.st.devicesVersion !== S.devicesVersion) await refreshDevices();
  schedulePlan();
}

async function refreshDevices() {
  const d = await api('GET', '/api/devices');
  S.devices = list(d.devices);
  S.safe = new Set(list(d.safeKeys));
  if (d.version !== S.devicesVersion) {
    // after an import or a run the host's ticks are the truth
    S.selected = new Set(S.devices.filter((x) => x.Apply).map((x) => x.Key));
    S.devicesVersion = d.version;
  }
  renderTable();
  schedulePlan();
}

let pollTimer = 0;
async function poll() {
  clearTimeout(pollTimer);
  try {
    const r = await api('GET', `/api/events?after=${S.seq}`);
    let refresh = false;
    for (const e of list(r.events)) {
      S.seq = Math.max(S.seq, e.seq);
      if (onEvent(e)) refresh = true;
    }
    if (Boolean(r.busy) !== Boolean(busy())) refresh = true;
    if (refresh) await refreshState();
    renderActivity();
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) return showNoToken();
    toast(err.message, 'danger');
  }
  pollTimer = setTimeout(poll, busy() ? 600 : 2000);
}

function onEvent(e) {
  switch (e.kind) {
    case 'start':
      S.activity = []; S.activityLabel = e.label; S.progress = null; S.live = null;
      return true;
    case 'log':
      S.activity.push(e);
      // where the audit trail goes is worth more than a line in the feed
      if (e.Category === 'Audit' && e.Level === 'Warn') toast(e.Message, 'warning');
      if (S.activity.length > 1500) S.activity.splice(0, S.activity.length - 1500);
      return false;
    case 'progress':
      if (e.Live) S.live = e.Completed ? null : e;
      if (e.Id === 0) S.progress = e.Completed ? null : e;
      return false;
    case 'error':
      S.activity.push({ ...e, Level: 'Error' });
      toast(e.Message, 'danger');
      return true;
    case 'cancelled':
      S.activity.push({ ...e, Level: 'Warn' });
      return true;
    case 'result':
    case 'signin':
    case 'idle':
      if (e.kind === 'idle') { S.progress = null; S.live = null; announce('Finished.'); }
      return true;
    default:
      return false;
  }
}

// the plan for the current page's run step - asked for, never worked out here
let planTimer = 0;
function schedulePlan() {
  clearTimeout(planTimer);
  planTimer = setTimeout(fetchPlan, 120);
}
async function fetchPlan() {
  const page = pageById(S.page);
  if (!page?.run || !S.st) { S.plan = null; renderActionBar(); return; }
  const req = { step: page.run, selection: [...S.selected], options: optionsFor(page.run) };
  const n = ++S.planSeq;
  try {
    const plan = await api('POST', '/api/plan', req);
    if (n !== S.planSeq) return;                    // an older answer
    S.plan = plan; S.planFor = req;
  } catch (err) { S.plan = null; toast(err.message, 'danger'); }
  renderActionBar();
}

function optionsFor(step) {
  if (!S.options[step]) {
    const o = {};
    for (const [name, spec] of Object.entries(S.byKey[step]?.Options || {})) o[name] = spec.Default;
    S.options[step] = o;
  }
  return S.options[step];
}

async function start(method, path, body, label) {
  try {
    await api(method, path, body);
    S.activity = []; S.activityLabel = label;
    announce(`${label}…`);
    await refreshState();
    poll();
  } catch (err) {
    toast(err.message, 'danger');
    await refreshState().catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// top bar, stepper
// ---------------------------------------------------------------------------
function renderTopbar() {
  const st = S.st; if (!st) return;
  const dry = st.dryRun;
  document.body.classList.toggle('live', !dry);

  const mode = $('mode');
  mode.setAttribute('aria-checked', String(dry));
  mode.className = `mode ${dry ? 'mode-dry' : 'mode-live'}`;
  fill(mode, icon(dry ? 'check' : 'alert'),
    h('span', { class: 'mode-title', text: dry ? 'Dry run' : 'LIVE' }),
    h('span', { class: 'mode-text', text: dry ? 'nothing is changed' : 'deletes are permanent' }));
  mode.title = dry ? 'Dry run is on. Click to run for real.' : 'Running for real. Click to go back to a dry run.';
  mode.disabled = Boolean(busy());

  const s = st.signIn;
  fill($('tenant'), s?.SignedIn
    ? [h('span', { class: 'tenant-name', text: st.tenantName || 'signed in' }), h('span', { class: 'tenant-account', text: s.Account })]
    : h('span', { class: 'tenant-none', text: 'Not signed in' }));

  const b = busy(), el = $('busy');
  el.hidden = !b;
  if (!b) fill(el);          // no stale "Signing in" left behind
  else {
    fill(el, h('span', { class: 'spinner', 'aria-hidden': 'true' }), h('span', { text: b.label }),
      h('button', { type: 'button', class: 'btn btn-small', text: 'Cancel', onclick: () => api('POST', '/api/cancel').then(poll) }));
  }
  $('quit').disabled = Boolean(b);
  // buttons whose only condition is "nothing is running" follow the host's
  // state here, not the moment their page was drawn - a page opened while
  // something ran would otherwise keep them disabled after it finished
  for (const el of document.querySelectorAll('[data-idle]')) el.disabled = Boolean(b);
}

const TONE = { Done: 'success', Partial: 'warning', Ready: 'neutral', Blocked: 'blocked', Error: 'danger', Running: 'progress' };
const STATUS_ICON = { Done: 'check', Partial: 'half', Ready: 'circle', Blocked: 'lock', Error: 'alert', Running: 'run' };
const STATUS_WORD = { Done: 'Done', Partial: 'Partly done', Ready: 'Ready', Blocked: 'Not yet', Error: 'Error', Running: 'Running' };

function pageStatus(p) {
  const b = busy();
  if (b && p.run && b.step === p.run) return { Status: 'Running', Detail: b.label, Reachable: true };
  if (p.id === 'setup') {
    return signedIn() ? { Status: 'Done', Detail: S.st.tenantName, Reachable: true }
                      : { Status: 'Ready', Detail: 'sign in first', Reachable: true };
  }
  if (p.id === 'devices') {
    const lookup = statusOf('Lookup'), input = statusOf('DeviceInput');
    const row = S.st?.deviceCount ? lookup : input;
    return { ...row, Reachable: Boolean(lookup?.Reachable) };
  }
  return statusOf(p.id) || { Status: 'Ready', Detail: '', Reachable: false };
}

function renderStepper() {
  if (!S.st) return;
  const items = pages().map((p) => {
    const s = pageStatus(p);
    const current = p.id === S.page;
    return h('li', { class: `step tone-${TONE[s.Status] || 'neutral'}${current ? ' current' : ''}` },
      h('button', {
        type: 'button', class: 'step-link', disabled: !s.Reachable && !current,
        'aria-current': current ? 'step' : null,
        onclick: () => go(p.id),
      },
      h('span', { class: 'step-num', text: p.number }),
      h('span', { class: 'step-body' },
        h('span', { class: 'step-name', text: p.name }),
        h('span', { class: 'step-status' }, icon(STATUS_ICON[s.Status] || 'circle'),
          h('span', { text: `${STATUS_WORD[s.Status] || s.Status}${s.Detail ? ' - ' + s.Detail : ''}` })))));
  });
  const gate = S.st.gate;
  fill($('stepper'), h('ol', { class: 'steps' }, items),
    gate?.Reason ? h('p', { class: 'gate-reason' }, icon('lock'), h('span', { text: gate.Reason })) : null);
}

// each page has its own address (#/IntuneDelete), so Back and a reload work
function pageFromHash() {
  const id = /^#\/([A-Za-z]+)$/.exec(location.hash)?.[1];
  return id && pageById(id) ? id : null;
}
window.addEventListener('hashchange', () => {
  const id = pageFromHash();
  if (!id || id === S.page) return;
  const p = pageById(id);
  if (!pageStatus(p).Reachable) { history.replaceState(null, '', `#/${S.page}`); return; }
  go(id, true);
});

function go(id, fromHash = false) {
  if (S.page === id) return;
  S.page = id; S.plan = null;
  if (!fromHash) history.pushState(null, '', `#/${id}`);
  renderStepper(); renderPage();
  schedulePlan();
  $('main').querySelector('h1')?.focus();
}

// ---------------------------------------------------------------------------
// pages
// ---------------------------------------------------------------------------
function renderPage() {
  const p = pageById(S.page);
  if (p.id === 'setup') return renderSetupPage();
  const main = $('main');
  const runMeta = S.byKey[p.run];
  const introKey = p.id === 'devices' ? 'DeviceInput' : p.run;

  fill(main,
    h('h1', { tabindex: '-1' }, h('span', { class: 'h-num', text: p.number }), p.name),
    h('p', { class: 'lead', text: S.byKey[introKey]?.Summary || '' }),
    h('div', { id: 'callout' }),
    p.id === 'devices' ? devicesInputSection() : null,
    p.id === 'devices' ? h('h2', { class: 'section-title' }, h('span', { class: 'badge', text: '2' }), 'Then - look them up in the tenant') : null,
    runMeta?.Explainer ? explainer(runMeta.Explainer) : null,
    optionsForm(p.run),
    h('section', { class: 'card', 'aria-labelledby': 'list-title' },
      h('h2', { id: 'list-title', text: p.id === 'devices' ? 'The list' : 'Devices' }),
      h('div', { id: 'devtable' })),
    h('div', { id: 'actionbar', class: 'actionbar' }),
    h('div', { id: 'result' }),
    h('div', { id: 'activity' }));

  renderCallout(); renderTable(); renderActionBar(); renderResult(); renderActivity();
  if (p.id === 'devices') renderSavedList();
}

function explainer(text) {
  return h('details', { class: 'explainer' },
    h('summary', { text: 'How this step works' }),
    text.split(/\r?\n\s*\r?\n/).map((para) => h('p', { text: para.trim() })));
}

function renderCallout() {
  const el = $('callout'); const p = pageById(S.page);
  if (!el || !p || !S.st) return;
  const s = pageStatus(p);
  let text = s.Detail || '';
  if (!signedIn()) { s.Status = 'Blocked'; text = 'Not signed in. Go to Setup and sign in to the tenant these devices are leaving.'; }
  const word = { Done: 'Done.', Partial: 'Partly done.', Ready: 'Ready.', Blocked: 'Not available yet.', Error: 'The last run ended with an error.', Running: 'Running…' }[s.Status] || '';
  fill(el, h('div', { class: `callout tone-${TONE[s.Status] || 'neutral'}` },
    icon(STATUS_ICON[s.Status] || 'info'), h('p', {}, h('strong', { text: word }), ' ', text)));
}

// --- options ---------------------------------------------------------------
function optionsForm(step) {
  const specs = Object.entries(S.byKey[step]?.Options || {});
  if (!specs.length) return null;
  const values = optionsFor(step);
  const loose = [], groups = new Map();
  for (const [name, spec] of specs) {
    if (spec.Group) { if (!groups.has(spec.Group)) groups.set(spec.Group, []); groups.get(spec.Group).push([name, spec]); }
    else loose.push([name, spec]);
  }
  const field = ([name, spec]) => {
    const id = `opt-${step}-${name}`, helpId = `${id}-help`;
    const onchange = (e) => {
      const t = e.target;
      values[name] = spec.Type === 'bool' ? t.checked : spec.Type === 'int' ? (parseInt(t.value, 10) || 0) : t.value;
      schedulePlan();
    };
    let input;
    if (spec.Type === 'bool') {
      input = h('input', { type: 'checkbox', id, checked: Boolean(values[name]), 'aria-describedby': spec.Help ? helpId : null, onchange });
      return h('div', { class: 'field field-check' }, input, h('label', { for: id, text: spec.Label }),
        spec.Help ? h('p', { class: 'help', id: helpId, text: spec.Help }) : null);
    }
    if (spec.Type === 'choice') {
      input = h('select', { id, 'aria-describedby': spec.Help ? helpId : null, onchange },
        list(spec.Choices).map((c) => h('option', { value: c, text: c, selected: c === values[name] })));
    } else {
      input = h('input', { type: spec.Type === 'int' ? 'number' : 'text', id, value: values[name] ?? '', min: spec.Type === 'int' ? 0 : null,
        'aria-describedby': spec.Help ? helpId : null, onchange, oninput: spec.Type === 'int' ? null : onchange });
    }
    return h('div', { class: 'field' }, h('label', { for: id, text: spec.Label }),
      spec.Help ? h('p', { class: 'help', id: helpId, text: spec.Help }) : null, input);
  };
  return h('section', { class: 'card options', 'aria-label': 'Options' },
    h('h2', { text: 'Options' }),
    loose.map(field),
    [...groups].map(([g, items]) => h('details', { class: 'option-group', open: items.some(([, s]) => s.GroupOpen) },
      h('summary', { text: g }),
      items[0][1].Sub ? h('p', { class: 'help', text: items[0][1].Sub }) : null,
      items.map(field))));
}

// --- device table ----------------------------------------------------------
const OUTCOME_TONE = { Done: 'success', Simulated: 'info', Skipped: 'neutral', Pending: 'warning', Failed: 'danger', NotReady: 'danger' };
const label = (d) => d.Name || d.IntuneName || d.EntraName || d.Raw || d.Serial;
function lastSeen(d) {
  if (!d.LastActivity) return 'unknown';
  if (d.DaysSinceActivity < 0) return d.LastActivity;
  if (d.DaysSinceActivity === 0) return 'today';
  if (d.DaysSinceActivity === 1) return 'yesterday';
  return `${d.DaysSinceActivity} days ago`;
}
const FILTERS = [
  ['all', 'All', () => true],
  ['safe', 'Safe', (d) => S.safe.has(d.Key)],
  ['flagged', 'Flagged', (d) => d.Warn],
  ['notfound', 'Not found', (d) => d.Match === 'Not found'],
  ['pending', 'Autopilot pending', (d) => d.AutopilotState === 'Deletion pending'],
  ['selected', 'Selected', (d) => S.selected.has(d.Key)],
];

function renderTable() {
  const el = $('devtable'); if (!el) return;
  const page = pageById(S.page);
  const wholeList = S.byKey[page.run]?.Scope === 'WholeList' && page.id !== 'devices';
  const selectable = !wholeList;
  const q = S.search.trim().toLowerCase();
  const test = FILTERS.find((f) => f[0] === S.filter)?.[2] || (() => true);
  const rows = S.devices.filter(test).filter((d) => !q || [label(d), d.Serial, d.Raw, d.Note].some((v) => (v || '').toLowerCase().includes(q)));

  const total = S.devices.length;
  if (!total) { fill(el, h('p', { class: 'empty', text: page.id === 'devices' ? 'The list is empty - add devices above.' : 'The list is empty. Add devices on page 1.' })); return; }

  const toggleAll = (on) => { for (const d of rows) on ? S.selected.add(d.Key) : S.selected.delete(d.Key); renderTable(); schedulePlan(); };
  const busyNow = Boolean(busy());

  fill(el,
    wholeList ? h('p', { class: 'note' }, icon('info'), 'This step always works on the whole list - selecting rows does not narrow it.') : null,
    h('div', { class: 'table-tools' },
      h('div', { class: 'segmented', role: 'group', 'aria-label': 'Show' },
        FILTERS.map(([id, text]) => h('button', { type: 'button', 'aria-pressed': String(S.filter === id), text,
          onclick: () => { S.filter = id; renderTable(); } }))),
      h('input', { type: 'search', class: 'search', placeholder: 'Find a device', 'aria-label': 'Find a device', value: S.search,
        oninput: (e) => { S.search = e.target.value; renderTable(); requestAnimationFrame(() => el.querySelector('.search')?.focus()); } })),
    selectable ? h('div', { class: 'table-tools' },
      h('button', { type: 'button', class: 'btn btn-small', text: 'Select the safe ones', disabled: busyNow,
        onclick: () => { S.selected = new Set(S.safe); renderTable(); schedulePlan(); announce(`${S.safe.size} safe device(s) selected.`); } }),
      h('button', { type: 'button', class: 'btn btn-small', text: 'Select all shown', disabled: busyNow, onclick: () => toggleAll(true) }),
      h('button', { type: 'button', class: 'btn btn-small', text: 'Clear selection', disabled: busyNow, onclick: () => { S.selected.clear(); renderTable(); schedulePlan(); } }),
      page.id === 'devices' ? [
        h('button', { type: 'button', class: 'btn btn-small', text: 'Remove selected from the list', disabled: busyNow || !S.selected.size, onclick: removeSelected }),
        h('button', { type: 'button', class: 'btn btn-small', text: 'Empty the list', disabled: busyNow, onclick: clearList }),
      ] : null) : null,
    tableSummary(h('p', { class: 'table-summary' })),
    h('div', { class: 'table-wrap' },
      h('table', { class: 'devices' },
        h('caption', { class: 'sr-only', text: `Devices, ${rows.length} shown` }),
        h('thead', {}, h('tr', {},
          selectable ? h('th', { scope: 'col', class: 'col-check' }, h('span', { class: 'sr-only', text: 'Selected' })) : null,
          ['Device', 'Serial', 'Match', 'Intune', 'Autopilot', 'Entra ID', 'Last seen', 'Warning', 'Result'].map((t) => h('th', { scope: 'col', text: t })))),
        h('tbody', {}, rows.map((d) => h('tr', { class: d.Warn ? 'row-flagged' : null },
          selectable ? h('td', { class: 'col-check' }, h('input', { type: 'checkbox', checked: S.selected.has(d.Key), disabled: busyNow,
            'aria-label': `Select ${label(d)}`,
            onchange: (e) => { e.target.checked ? S.selected.add(d.Key) : S.selected.delete(d.Key); schedulePlan(); renderTableSummaryOnly(); } })) : null,
          h('td', { class: 'col-device' }, h('span', { text: label(d) }), d.Note ? h('span', { class: 'sub', text: d.Note }) : null),
          h('td', { class: 'mono', text: d.Serial || '' }),
          h('td', { text: d.Match }),
          h('td', { text: d.IntuneState || '' }),
          h('td', { text: d.AutopilotState || '' }),
          h('td', { text: d.EntraState || '' }),
          h('td', { text: lastSeen(d) }),
          h('td', { class: d.Warn ? 'tone-text-warning' : 'muted' }, d.Warn ? icon('alert', 'Flagged') : null, ' ', d.Flag || ''),
          h('td', { class: d.Outcome ? `tone-text-${OUTCOME_TONE[d.Outcome] || 'neutral'}` : 'muted', text: d.Result || '' })))))));
}
function tableSummary(el) {
  const flagged = S.devices.filter((d) => d.Warn).length;
  const selFlagged = S.devices.filter((d) => d.Warn && S.selected.has(d.Key)).length;
  el.textContent = `${S.devices.length} device(s) on the list, ${S.selected.size} selected` +
    (flagged ? `, ${flagged} flagged${selFlagged ? ` - ${selFlagged} of them selected` : ''}` : '') + '.' +
    (selFlagged ? ' A selected flagged device is still acted on - check the Warning column first.' : '');
  el.classList.toggle('tone-text-warning', selFlagged > 0);
  return el;
}
function renderTableSummaryOnly() {
  // a checkbox click: keep focus where it is, only the counts change
  const el = $('devtable')?.querySelector('.table-summary');
  if (el) tableSummary(el);
}

async function removeSelected() {
  const n = S.selected.size;
  if (!await ask({ title: `Remove ${n} device(s) from the list?`, body: [h('p', { text: 'Nothing in the tenant is touched - this only takes them off the list. The saved list is kept as a copy first.' })],
    yes: 'Remove from the list', tone: 'primary' })) return;
  try { await api('POST', '/api/devices/remove', { keys: [...S.selected] }); S.selected.clear(); await refreshState(); await refreshDevices(); announce(`${n} device(s) removed from the list.`); }
  catch (err) { toast(err.message, 'danger'); }
}
async function clearList() {
  if (!await ask({ title: `Empty the list of ${S.devices.length} device(s)?`, body: [h('p', { text: 'Nothing in the tenant is touched. The saved list is kept as a copy in the working folder first.' })],
    yes: 'Empty the list', tone: 'primary' })) return;
  try { await api('POST', '/api/devices/clear'); await refreshState(); await refreshDevices(); announce('The list is empty.'); }
  catch (err) { toast(err.message, 'danger'); }
}

// --- the action bar: what the button will do, in the plan's words -------------
const BLOCKED = { NotSignedIn: 'Sign in on the Setup page first', EmptyList: 'Add devices to the list first', NothingSelected: 'Select at least one device' };

function renderActionBar() {
  const el = $('actionbar'); if (!el) return;
  const plan = S.plan, b = busy();
  if (!plan) { fill(el); el.hidden = true; return; }
  el.hidden = false;
  const destructiveLive = plan.Effect === 'Destructive' && !plan.DryRun;
  const chips = [];
  if (plan.Effect === 'Destructive' && list(plan.Flagged).length) chips.push(h('span', { class: 'chip tone-warning' }, icon('alert'), `${list(plan.Flagged).length} flagged`));
  if (plan.NotBackedUp) chips.push(h('span', { class: 'chip tone-warning' }, icon('alert'), `${plan.NotBackedUp} not exported in step ${S.byKey.Backup?.Number}`));
  if (plan.Effect !== 'ReadOnly') chips.push(plan.DryRun
    ? h('span', { class: 'chip tone-info' }, icon('info'), 'Dry run - nothing is sent')
    : h('span', { class: `chip ${destructiveLive ? 'tone-danger' : 'tone-warning'}` }, icon('alert'), destructiveLive ? 'Runs for real - cannot be undone' : 'Runs for real'));
  if (plan.Effect === 'ReadOnly') chips.push(h('span', { class: 'chip tone-neutral' }, 'Read-only'));

  const disabled = Boolean(b) || !plan.CanRun;
  const text = b ? 'Another operation is running' : plan.CanRun ? plan.Label : BLOCKED[plan.Blocked] || plan.BlockedReason;
  fill(el,
    h('div', { class: 'actionbar-text' },
      h('p', { class: 'actionbar-what', text: plan.CanRun ? `${plan.Label}` : `${plan.Name}: ${BLOCKED[plan.Blocked] || plan.BlockedReason}` }),
      h('div', { class: 'chips' }, chips)),
    h('button', { type: 'button', class: `btn btn-large ${destructiveLive ? 'btn-danger' : 'btn-primary'}`, disabled, text, onclick: () => runPlan(plan) }));
}

async function runPlan(plan) {
  const req = S.planFor;
  let typed = '';
  if (plan.RequiresConfirmation) {
    const answer = await confirmDestructive(plan);
    if (answer === null) { announce('Cancelled - nothing was changed.'); return; }
    typed = answer;
  }
  await start('POST', '/api/run', { ...req, confirmationKey: plan.ConfirmationKey, tenantConfirmation: typed }, plan.Label);
}

// ---------------------------------------------------------------------------
// dialogs
// ---------------------------------------------------------------------------
function openDialog(build) {
  return new Promise((resolve) => {
    const dlg = $('dialog');
    const done = (value) => { dlg.close(); resolve(value); };
    fill(dlg, build(done));
    dlg.onclose = () => resolve(null);
    dlg.onkeydown = (e) => { if (e.key === 'Escape') { e.preventDefault(); done(null); } };
    dlg.showModal();
    dlg.querySelector('[autofocus]')?.focus();
  });
}

function ask({ title, body, yes, no = 'Cancel', tone = 'primary' }) {
  return openDialog((done) => h('form', { method: 'dialog', class: 'dialog-body', onsubmit: (e) => { e.preventDefault(); done(true); } },
    h('h2', { text: title }), body,
    h('div', { class: 'dialog-buttons' },
      h('button', { type: 'button', class: 'btn', text: no, autofocus: true, onclick: () => done(null) }),
      h('button', { type: 'submit', class: `btn btn-${tone}`, text: yes }))))
    .then((v) => v === true);
}

// a real destructive run: what, how many, where; the flagged devices by name;
// the ones never exported; and for a large batch the tenant typed in
function confirmDestructive(plan) {
  const flagged = list(plan.Flagged);
  const tenant = plan.TypedConfirmationText || S.st?.tenantName || 'this tenant';
  return openDialog((done) => {
    const confirmBtn = h('button', { type: 'submit', class: 'btn btn-danger', text: plan.Label, disabled: plan.RequiresTypedConfirmation });
    const typedInput = plan.RequiresTypedConfirmation
      ? h('input', { type: 'text', id: 'typed-tenant', autocomplete: 'off', spellcheck: false,
          oninput: (e) => { confirmBtn.disabled = e.target.value.trim().toLowerCase() !== tenant.toLowerCase(); } })
      : null;
    return h('form', { method: 'dialog', class: 'dialog-body dialog-danger',
      onsubmit: (e) => { e.preventDefault(); if (!confirmBtn.disabled) done(typedInput ? typedInput.value.trim() : ''); } },
      h('h2', {}, icon('alert'), 'This cannot be undone'),
      h('p', {}, 'About to ', h('strong', { text: `${plan.ConfirmAction} ${plan.TargetCount} device(s)` }), ' in ', h('strong', { text: tenant }), '.'),
      flagged.length ? h('div', { class: 'callout tone-warning' }, icon('alert'), h('div', {},
        h('p', { text: `${flagged.length} of them are flagged:` }),
        h('ul', {}, flagged.slice(0, 12).map((f) => h('li', {}, h('strong', { text: f.Label }), ` - ${f.Flag}`))),
        flagged.length > 12 ? h('p', { text: `…and ${flagged.length - 12} more.` }) : null)) : null,
      plan.NotBackedUp ? h('div', { class: 'callout tone-warning' }, icon('alert'),
        h('p', { text: `${plan.NotBackedUp} of them were never exported in step ${S.byKey.Backup?.Number} - their ids cannot be looked up once they are gone.` })) : null,
      typedInput ? h('div', { class: 'field' },
        h('label', { for: 'typed-tenant' }, `This changes ${plan.TargetCount} devices. Type `, h('strong', { class: 'mono', text: tenant }), ' to confirm.'),
        typedInput) : null,
      h('div', { class: 'dialog-buttons' },
        h('button', { type: 'button', class: 'btn', text: 'Cancel', autofocus: true, onclick: () => done(null) }),
        confirmBtn));
  });
}

// ---------------------------------------------------------------------------
// setup page
// ---------------------------------------------------------------------------
function renderSetupPage() {
  const s = S.st.settings;
  const save = debounce(async () => {
    try { S.st = await api('POST', '/api/settings', { settings: s }); renderSetupStatus(); renderTopbar(); }
    catch (err) { toast(err.message, 'danger'); }
  }, 400);
  const bind = (key, type = 'text') => ({
    [type === 'bool' ? 'checked' : 'value']: type === 'bool' ? Boolean(s[key]) : (s[key] ?? ''),
    [type === 'bool' ? 'onchange' : 'oninput']: (e) => { s[key] = type === 'bool' ? e.target.checked : e.target.value; save(); },
  });
  fill($('main'),
    h('h1', { tabindex: '-1' }, h('span', { class: 'h-num', text: '0' }), 'Setup and sign in'),
    h('p', { class: 'lead', text: 'Sign in to the tenant the devices are leaving. You sign in as yourself: the tenant\'s own MFA and Conditional Access apply, and every change lands in its audit log under your name.' }),
    h('section', { class: 'card', 'aria-labelledby': 'signin-title' },
      h('h2', { id: 'signin-title', text: 'Sign in' }),
      h('div', { id: 'signin-status' }),
      h('div', { class: 'field' }, h('label', { for: 'tenant-id', text: 'Tenant (optional)' }),
        h('p', { class: 'help', id: 'tenant-help', text: 'A tenant id or domain, so the sign-in lands in the tenant the devices are leaving.' }),
        h('input', { type: 'text', id: 'tenant-id', 'aria-describedby': 'tenant-help', ...bind('TenantId') })),
      h('div', { class: 'field field-check' }, h('input', { type: 'checkbox', id: 'device-code', ...bind('UseDeviceCode', 'bool') }),
        h('label', { for: 'device-code', text: 'Use a device code instead of the browser (the code appears in the console window)' })),
      h('fieldset', { class: 'field' }, h('legend', { text: 'Extra permissions to ask for' }),
        h('p', { class: 'help', text: 'Only tick what you need. A Global Administrator can tick both once and consent for the whole organisation.' }),
        h('div', { class: 'field-check' }, h('input', { type: 'checkbox', id: 'scope-wipe', ...bind('ScopeWipe', 'bool') }), h('label', { for: 'scope-wipe', text: 'Wiping / retiring devices (step 3)' })),
        h('div', { class: 'field-check' }, h('input', { type: 'checkbox', id: 'scope-bl', ...bind('ScopeBitLocker', 'bool') }), h('label', { for: 'scope-bl', text: 'Reading BitLocker recovery keys (step 2)' }))),
      h('div', { class: 'buttons', id: 'signin-buttons' })),
    h('section', { class: 'card', 'aria-labelledby': 'work-title' },
      h('h2', { id: 'work-title', text: 'Working folder and checks' }),
      h('div', { class: 'field' }, h('label', { for: 'work-folder', text: 'Working folder' }),
        h('p', { class: 'help', id: 'work-help', text: 'The saved list, the exports, the handover report and the audit log go here. Empty = Documents\\DeviceCleanUpper.' }),
        h('div', { class: 'input-row' }, h('input', { type: 'text', id: 'work-folder', 'aria-describedby': 'work-help', ...bind('WorkFolder') }),
          h('button', { type: 'button', class: 'btn', text: 'Open folder', onclick: () => api('POST', '/api/open-folder').catch((e) => toast(e.message, 'danger')) }))),
      h('div', { class: 'field' }, h('label', { for: 'recent-days', text: 'Flag devices seen in the last … days as still in use' }),
        h('p', { class: 'help', id: 'recent-help', text: 'Flagged devices are never selected for you. 0 turns the warning off.' }),
        h('input', { type: 'number', id: 'recent-days', min: 0, max: 3650, class: 'input-short', 'aria-describedby': 'recent-help', ...bind('RecentDays') })),
      h('div', { class: 'field field-check' }, h('input', { type: 'checkbox', id: 'windows-only', ...bind('WindowsOnly', 'bool') }),
        h('label', { for: 'windows-only', text: 'Windows devices only' }))),
    h('section', { class: 'card', 'aria-labelledby': 'mode-title' },
      h('h2', { id: 'mode-title', text: 'Dry run' }),
      h('p', { text: 'Every session starts as a dry run: every step still runs end to end and checks every device, but no delete, wipe or sync is sent. Switch it off in the top bar when the dry run looks right. It is never remembered between sessions.' })),
    h('div', { id: 'activity' }));
  renderSetupStatus(); renderActivity();
}

function renderSetupStatus() {
  const el = $('signin-status'); if (!el || !S.st) return;
  const s = S.st.signIn, missing = list(S.st.missingScopes), b = Boolean(busy());
  fill(el, s.SignedIn
    ? h('div', { class: `callout ${missing.length ? 'tone-warning' : 'tone-success'}` }, icon(missing.length ? 'alert' : 'check'),
        h('div', {}, h('p', {}, 'Signed in as ', h('strong', { text: s.Account }), ` - tenant ${S.st.tenantName}`),
          missing.length ? h('p', { text: `Consent is missing for: ${missing.join(', ')}. Sign in again to ask for it.` }) : null))
    : h('div', { class: 'callout tone-blocked' }, icon('lock'), h('p', { text: s.Message && s.Message !== 'Not signed in.' ? s.Message : 'Not signed in. Nothing can be looked up or deleted until you are.' })));
  fill($('signin-buttons'),
    h('button', { type: 'button', class: 'btn btn-primary', disabled: b, 'data-idle': true, text: s.SignedIn ? 'Sign in again' : 'Sign in',
      onclick: () => start('POST', '/api/signin', {}, 'Signing in - finish it in the window that opens') }),
    s.SignedIn ? h('button', { type: 'button', class: 'btn', disabled: b, 'data-idle': true, text: 'Sign out', onclick: () => start('POST', '/api/signout', {}, 'Signing out') }) : null,
    h('p', { class: 'help', text: `Asks for: ${list(S.st.requestedScopes).join(', ')}` }));
}

// ---------------------------------------------------------------------------
// page 1: putting devices on the list
// ---------------------------------------------------------------------------
function devicesInputSection() {
  const I = S.input;
  const tabs = [['paste', 'Paste'], ['file', 'Read a file'], ['type', 'Type them in'], ['saved', 'Saved list']];
  const panel = h('div', { class: 'tabpanel', role: 'tabpanel', id: 'input-panel', 'aria-labelledby': `tab-${I.tab}` });
  const tablist = h('div', { class: 'tabs', role: 'tablist', 'aria-label': 'How to add devices',
    onkeydown: (e) => {
      const i = tabs.findIndex((t) => t[0] === I.tab);
      const j = e.key === 'ArrowRight' ? (i + 1) % tabs.length : e.key === 'ArrowLeft' ? (i + tabs.length - 1) % tabs.length : -1;
      if (j >= 0) { e.preventDefault(); I.tab = tabs[j][0]; draw(); $(`tab-${I.tab}`).focus(); }
    } });
  const draw = () => {
    fill(tablist, tabs.map(([id, text]) => h('button', { type: 'button', role: 'tab', id: `tab-${id}`, text,
      'aria-selected': String(I.tab === id), 'aria-controls': 'input-panel', tabindex: I.tab === id ? '0' : '-1',
      onclick: () => { I.tab = id; draw(); } })));
    panel.setAttribute('aria-labelledby', `tab-${I.tab}`);
    fill(panel, inputPanel());
  };
  draw();
  return h('section', { class: 'card', 'aria-labelledby': 'input-title' },
    h('h2', { id: 'input-title', class: 'section-title' }, h('span', { class: 'badge', text: '1' }), 'First - put the devices on the list'),
    tablist, panel,
    h('div', { class: 'field field-check' },
      h('input', { type: 'checkbox', id: 'append', checked: I.append, onchange: (e) => { I.append = e.target.checked; } }),
      h('label', { for: 'append', text: 'Add to the list instead of replacing it (a replaced list is kept as a copy)' })));
}

function inputPanel() {
  const I = S.input, b = Boolean(busy());
  const run = (body, what) => start('POST', '/api/devices/import', { ...body, append: I.append }, what);
  switch (I.tab) {
    case 'paste':
      return [
        h('label', { for: 'paste', class: 'help', text: 'One device per line: a serial number, a device name, or both - separated by a tab, semicolon, comma or spaces. A header line is recognised.' }),
        h('textarea', { id: 'paste', rows: 7, spellcheck: false, value: I.text, oninput: (e) => { I.text = e.target.value; } }),
        h('div', { class: 'buttons' },
          h('button', { type: 'button', class: 'btn btn-primary', text: 'Read this text', disabled: b, 'data-idle': true,
            onclick: () => (I.text.trim() ? run({ source: 'text', text: I.text }, 'Reading the pasted text') : toast('Paste something first.', 'warning')) }),
          h('button', { type: 'button', class: 'btn', text: 'Clear', onclick: () => { I.text = ''; $('paste').value = ''; } }))];
    case 'file':
      return [
        h('label', { for: 'file', class: 'help', text: 'A .csv (comma, semicolon or tab separated) or .xlsx file, or a saved list (.json). Excel does not have to be installed. Headers are recognised in Dutch and English.' }),
        h('input', { type: 'file', id: 'file', accept: '.csv,.txt,.xlsx,.xlsm,.json', onchange: (e) => { I.file = e.target.files[0] || null; } }),
        h('details', { class: 'option-group' }, h('summary', { text: 'Column mapping (optional)' }),
          h('p', { class: 'help', text: 'Leave empty to detect them. Recognised: serial, serienummer, serial number, sn - devicename, apparaatnaam, computernaam, hostname, naam, name.' }),
          [['sheet', 'Excel sheet (empty = the first one)'], ['serialColumn', 'Serial number column'], ['nameColumn', 'Device name column'], ['noteColumn', 'Note column']]
            .map(([k, t]) => h('div', { class: 'field' }, h('label', { for: `col-${k}`, text: t }),
              h('input', { type: 'text', id: `col-${k}`, value: I[k], oninput: (e) => { I[k] = e.target.value; } })))),
        h('div', { class: 'buttons' }, h('button', { type: 'button', class: 'btn btn-primary', text: 'Read this file', disabled: b, 'data-idle': true, onclick: readFile }))];
    case 'type':
      return [
        h('div', { class: 'table-wrap' }, h('table', { class: 'typed' },
          h('thead', {}, h('tr', {}, ['Serial number', 'Device name', 'Note'].map((t) => h('th', { scope: 'col', text: t })), h('th', {}, h('span', { class: 'sr-only', text: 'Remove' })))),
          h('tbody', {}, I.rows.map((r, i) => h('tr', {},
            ['Serial', 'Name', 'Note'].map((k) => h('td', {}, h('input', { type: 'text', value: r[k], 'aria-label': `${k} ${i + 1}`, oninput: (e) => { r[k] = e.target.value; } }))),
            h('td', {}, h('button', { type: 'button', class: 'btn btn-small', 'aria-label': `Remove row ${i + 1}`, text: '×',
              onclick: () => { I.rows.splice(i, 1); if (!I.rows.length) I.rows.push({ Serial: '', Name: '', Note: '' }); redrawInput(); } }))))))),
        h('div', { class: 'buttons' },
          h('button', { type: 'button', class: 'btn', text: 'Add a row', onclick: () => { I.rows.push({ Serial: '', Name: '', Note: '' }); redrawInput(); } }),
          h('button', { type: 'button', class: 'btn btn-primary', text: 'Put these on the list', disabled: b, 'data-idle': true,
            onclick: () => run({ source: 'rows', rows: I.rows }, 'Adding the typed devices') }))];
    case 'saved':
      return [h('div', { id: 'saved-list' })];
    default:
      return [];
  }
}
function redrawInput() { const p = $('input-panel'); if (p) { fill(p, inputPanel()); if (S.input.tab === 'saved') renderSavedList(); } }

function renderSavedList() {
  const el = $('saved-list'); if (!el || !S.st) return;
  const sv = S.st.savedList;
  if (!sv) { fill(el, h('p', { class: 'help', text: `There is no saved list in ${S.st.workFolder} yet. The list is saved there after every change.` })); return; }
  fill(el,
    h('p', {}, h('strong', { text: `${sv.count ?? '?'} device(s)` }), ` saved ${sv.saved ? 'on ' + sv.saved.replace('T', ' at ') : ''} in `, h('span', { class: 'mono', text: sv.path })),
    h('p', { class: 'help', text: 'A saved list carries how far every device got (looked up, deleted, pending) - it replaces the current list.' }),
    h('div', { class: 'buttons' }, h('button', { type: 'button', class: 'btn btn-primary', text: 'Pick up the saved list', disabled: Boolean(busy()),
      onclick: () => start('POST', '/api/devices/import', { source: 'saved' }, 'Loading the saved list') })));
}

async function readFile() {
  const I = S.input;
  if (!I.file) return toast('Pick a file first.', 'warning');
  if (I.file.size > 10 * 1024 * 1024) return toast('The file is larger than 10 MB.', 'danger');
  const buf = new Uint8Array(await I.file.arrayBuffer());
  let bin = '';
  for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  await start('POST', '/api/devices/import', { source: 'file', fileName: I.file.name, fileBase64: btoa(bin), append: I.append,
    sheet: I.sheet, serialColumn: I.serialColumn, nameColumn: I.nameColumn, noteColumn: I.noteColumn }, `Reading ${I.file.name}`);
}

// ---------------------------------------------------------------------------
// result + activity
// ---------------------------------------------------------------------------
const RED = ['Failed', 'NotFound', 'NotReady', 'BitLockerErrors'];
const AMBER = ['RecentlyActive', 'HybridJoined', 'Warned', 'NeedsOnPremAd', 'StillPending', 'HybridNeedingOnPrem', 'Duplicates'];
const words = (k) => k.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, (c) => c.toUpperCase());

function renderResult() {
  const el = $('result'); if (!el || !S.st) return;
  const p = pageById(S.page);
  const results = S.st.lastResults || {};
  const shown = [p.id === 'devices' ? 'DeviceInput' : null, p.run].filter((k) => k && results[k]);
  fill(el, shown.map((k) => {
    const r = results[k];
    const rows = Object.entries(r).filter(([n, v]) => !['Step', 'Checklist', 'Columns'].includes(n) && v !== '' && v != null && !(Array.isArray(v) && !v.length));
    return h('section', { class: 'card result', 'aria-label': `Result of ${S.byKey[k]?.Name}` },
      h('h2', { text: `Result - ${S.byKey[k]?.Name}` }),
      h('dl', { class: 'kv' }, rows.map(([n, v]) => {
        const num = typeof v === 'number' ? v : NaN;
        const tone = n === 'WorkingSetError' ? 'danger' : RED.includes(n) && num > 0 ? 'danger' : AMBER.includes(n) && num > 0 ? 'warning'
          : n === 'DryRun' ? (v ? 'info' : 'danger') : '';
        const text = n === 'DryRun' ? (v ? 'yes - nothing was changed' : 'no - this ran for real') : typeof v === 'boolean' ? (v ? 'yes' : 'no') : String(v);
        return [h('dt', { text: words(n) }), h('dd', { class: tone ? `tone-text-${tone}` : null, text })];
      })),
      r.Checklist ? h('details', { class: 'explainer', open: true }, h('summary', { text: 'Handover checklist' }), h('pre', { class: 'checklist', text: r.Checklist })) : null,
      h('div', { class: 'buttons' }, h('button', { type: 'button', class: 'btn btn-small', text: 'Open the working folder',
        onclick: () => api('POST', '/api/open-folder').catch((e) => toast(e.message, 'danger')) })));
  }));
}

const LEVEL_TONE = { Error: 'danger', Warn: 'warning', Success: 'success', Info: 'neutral', Verbose: 'muted' };
function renderActivity() {
  const el = $('activity'); if (!el) return;
  const lines = S.activity.filter((e) => S.showDetail || e.Level !== 'Verbose');
  if (!lines.length && !busy()) { fill(el); return; }
  const pr = S.progress;
  const old = el.querySelector('.log');
  const atBottom = !old || old.scrollTop + old.clientHeight >= old.scrollHeight - 8;
  fill(el, h('section', { class: 'card activity', 'aria-labelledby': 'activity-title' },
    h('div', { class: 'activity-head' },
      h('h2', { id: 'activity-title', text: `Activity${S.activityLabel ? ' - ' + S.activityLabel : ''}` }),
      h('label', { class: 'field-check small' }, h('input', { type: 'checkbox', checked: S.showDetail, onchange: (e) => { S.showDetail = e.target.checked; renderActivity(); } }), 'Show details')),
    pr ? h('div', { class: 'progress' },
      h('label', { for: 'progress-bar', text: `${pr.Activity}${pr.Status && pr.Status.trim() ? ' - ' + pr.Status : ''}` }),
      pr.Percent >= 0 ? h('progress', { id: 'progress-bar', max: 100, value: Math.min(pr.Percent, 100) }) : h('progress', { id: 'progress-bar' })) : null,
    S.live ? h('p', { class: 'live-line tone-text-info' }, h('span', { class: 'spinner', 'aria-hidden': 'true' }), `${S.live.Activity} - ${S.live.Status}`) : null,
    h('ol', { class: 'log', role: 'log', 'aria-live': 'polite' },
      lines.slice(-500).map((e) => h('li', { class: `tone-text-${LEVEL_TONE[e.Level] || 'neutral'}` },
        h('time', { text: new Date(e.time).toLocaleTimeString() }), ' ', e.Category ? h('span', { class: 'cat', text: `[${e.Category}] ` }) : null, e.Message || '')))));
  const log = el.querySelector('.log');
  if (log && atBottom) log.scrollTop = log.scrollHeight;
}

// ---------------------------------------------------------------------------
// small things
// ---------------------------------------------------------------------------
function announce(text) { const a = $('announce'); a.textContent = ''; setTimeout(() => { a.textContent = text; }, 30); }
function toast(text, tone = 'neutral') {
  const t = h('div', { class: `toast tone-${tone}`, role: tone === 'danger' ? 'alert' : 'status' },
    icon(tone === 'danger' || tone === 'warning' ? 'alert' : 'info'), h('p', { text }),
    h('button', { type: 'button', class: 'btn btn-small', 'aria-label': 'Close', text: '×', onclick: () => t.remove() }));
  $('toasts').append(t);
  setTimeout(() => t.remove(), tone === 'danger' ? 12000 : 6000);
}
function debounce(fn, ms) { let t = 0; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }

function showNoToken() {
  clearTimeout(pollTimer);
  document.body.classList.add('no-token');
  fill($('main'), h('h1', { tabindex: '-1', text: 'Open Device CleanUpper from its console window' }),
    h('p', { class: 'lead', text: 'This page only works from the link that Device CleanUpper printed when it started (it opens by itself). Close this tab and use that link, or start Launch-Web.cmd again.' }));
  fill($('stepper'));
}

$('mode').addEventListener('click', async () => {
  const goLive = S.st.dryRun;
  if (goLive && !await ask({ title: 'Turn dry run off?', tone: 'danger', yes: 'Turn dry run off', no: 'Keep the dry run',
    body: [h('p', { text: 'Steps 3 to 7 will then delete Intune devices, Autopilot registrations and Entra ID device objects for real. Deleted Autopilot registrations cannot be restored - the devices have to be re-registered from a hardware hash.' }),
      h('p', { text: 'Every real run still asks you to confirm.' })] })) return;
  try { S.st = await api('POST', '/api/mode', { dryRun: !goLive }); renderTopbar(); renderStepper(); schedulePlan(); announce(goLive ? 'Dry run is off.' : 'Dry run is on.'); }
  catch (err) { toast(err.message, 'danger'); }
});
$('quit').addEventListener('click', async () => {
  if (!await ask({ title: 'Quit Device CleanUpper?', yes: 'Quit', body: [h('p', { text: 'The list is already saved in the working folder. You can close this tab afterwards.' })] })) return;
  try { await api('POST', '/api/shutdown'); clearTimeout(pollTimer); fill($('main'), h('h1', { text: 'Device CleanUpper has stopped' }), h('p', { class: 'lead', text: 'You can close this tab. Start Launch-Web.cmd to use it again.' })); fill($('stepper')); }
  catch (err) { toast(err.message, 'danger'); }
});

async function boot() {
  if (!initToken()) return showNoToken();
  try {
    const steps = await api('GET', '/api/steps');
    S.steps = list(steps.steps);
    S.byKey = Object.fromEntries(S.steps.map((s) => [s.Key, s]));
    S.st = await api('GET', '/api/state');
    S.seq = Math.max(0, S.st.seq - 200);        // a reload mid-run still shows the recent lines
    await refreshDevices();
    const first = pageFromHash();
    if (first && pageStatus(pageById(first)).Reachable) S.page = first;
    renderTopbar(); renderStepper(); renderPage();
    schedulePlan();
    poll();
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) return showNoToken();
    fill($('main'), h('h1', { text: 'Device CleanUpper could not start' }), h('p', { class: 'lead', text: err.message }));
  }
}
boot();
