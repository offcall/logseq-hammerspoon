(function () {
'use strict';

/* ======================================================== */
/* DOM / STATE                                              */
/* ======================================================== */

const $ = id => document.getElementById(id);
const capture = $('capture');
const input = $('input');
const listEl = $('list');
const footEl = $('foot');
const toastEl = $('toast');
const dotEl = $('dot');
const dateEl = $('date');
const progEl = $('prog');
const progBar = $('progBar');
const progTxt = $('progTxt');
const taskTools = $('taskTools');
const sortMenu = $('sortMenu');
const pickerEl = $('picker');
const daysEl = $('days');
const viewBtn = $('viewBtn');
const dateBtn = $('dateBtn');
const searchEl = $('search');
const searchInput = $('searchInput');

const DAY = 86400000;

const st = {
    tasks: [],
    temps: [],
    done: [],
    bounds: null,
    loaded: false,
    loading: false,
    error: null,
    sel: null,
    menu: null,
    picker: null,
    view: 'list',
    calDay: null,
    sort: 'modified-asc',
    query: '',
    collapsed: { tomorrow: true, done: true },
    undo: null,
    closing: false,
    lastHeight: 0,
    req: 0,
    order: [],
    secOf: {},
    toastTimer: 0,
    set: null
};

function post(message) {
    try {
        window.webkit.messageHandlers.logseqCapture.postMessage(message);
    } catch (error) {
        console.error(error);
    }
}

const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ======================================================== */
/* DATES                                                    */
/* ======================================================== */

function dayStart(ms) {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}
function addDays(ms, n) {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n).getTime();
}
function bounds() {
    if (st.bounds && st.bounds.start) return st.bounds;
    const s = dayStart(Date.now());
    return { start: s, end: addDays(s, 1), end2: addDays(s, 2), until: addDays(weekStart(s), 14) };
}
// Monday of the week that contains ms.
function weekStart(ms) {
    return addDays(dayStart(ms), -((new Date(ms).getDay() + 6) % 7));
}
function todayStart() { return bounds().start; }
function fmtDay(ms) {
    return new Date(ms).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
}
function isoDate(ms) {
    const d = new Date(ms);
    const p = n => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}
function monthStart(ms) {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), 1).getTime();
}
function dayLabel(ms) {
    const s = todayStart();
    if (ms === s) return 'Today';
    if (ms === addDays(s, 1)) return 'Tomorrow';
    return fmtDay(ms);
}

/* ======================================================== */
/* NORMALIZATION                                            */
/* ======================================================== */

function g(o, k) {
    if (!o || typeof o !== 'object') return undefined;
    if (k in o) return o[k];
    if ((':' + k) in o) return o[':' + k];
    return undefined;
}
function identTail(v) {
    if (v && typeof v === 'object') v = g(v, 'db/ident');
    if (!v) return '';
    v = String(v).replace(/^:/, '');
    const i = v.lastIndexOf('.');
    return i >= 0 ? v.slice(i + 1) : v;
}
function num(v) {
    if (typeof v === 'number' && isFinite(v)) return v;
    if (typeof v === 'string' && /^\d+$/.test(v)) return Number(v);
    return null;
}

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

function parseTitle(raw, refs) {
    let text = String(raw || '');
    const map = {};
    (Array.isArray(refs) ? refs : []).forEach(r => {
        const u = g(r, 'block/uuid') || r.uuid;
        const t = g(r, 'block/title') || r.title;
        if (u && t) map[String(u).toLowerCase()] = String(t);
    });
    const links = [];
    text = text.replace(new RegExp('\\[\\[(' + UUID + ')\\]\\]', 'gi'), (m, u) => map[u.toLowerCase()] || '…');
    text = text.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, (m, label, url) => { links.push(url); return label; });
    text = text.replace(/\[\[([^\]]+)\]\]/g, '$1');
    text = text.replace(/https?:\/\/[^\s<>()\[\]]+/g, url => { links.push(url.replace(/[.,;:!?'"]+$/, '')); return ' '; });
    text = text.replace(/\s+/g, ' ').replace(/^[\s\-–—:·|]+|[\s\-–—:·|]+$/g, '').trim();
    const parsed = [];
    links.forEach(url => {
        try { parsed.push({ url: url, host: new URL(url).hostname.replace(/^www\./, '') }); } catch (e) { /* skip */ }
    });
    if (!text) text = parsed.length ? parsed[0].host : 'Untitled';
    return { text: text, links: parsed };
}

function normTask(p) {
    const t = {
        id: g(p, 'db/id'),
        uuid: g(p, 'block/uuid') ? String(g(p, 'block/uuid')) : '',
        status: identTail(g(p, 'logseq.property/status')),
        priority: identTail(g(p, 'logseq.property/priority')),
        modifiedAt: num(g(p, 'block/updated-at')),
        deadline: num(g(p, 'logseq.property/deadline')),
        scheduled: num(g(p, 'logseq.property/scheduled'))
    };
    const pt = parseTitle(g(p, 'block/title'), g(p, 'block/refs'));
    t.title = pt.text;
    t.links = pt.links;
    return t;
}

/* ======================================================== */
/* BUCKETS                                                  */
/* ======================================================== */

function datesOf(t) { return [t.deadline, t.scheduled].filter(v => v != null); }
function minDate(t) { const d = datesOf(t); return d.length ? Math.min.apply(null, d) : Infinity; }

function bucketOf(t) {
    const b = bounds();
    const ds = datesOf(t);
    if (t.status === 'done') return null;
    if (t.status === 'doing') return 'doing';
    if (ds.some(d => d >= b.start && d < b.end)) return 'today';
    if (ds.some(d => d < b.start)) return 'expired';
    if (ds.some(d => d >= b.end && d < b.end2)) return 'tomorrow';
    return null;
}

function sortTasks(a, b) {
    const title = String(a.title).localeCompare(String(b.title), undefined, { sensitivity: 'base' });
    if (st.sort.startsWith('title-')) return st.sort === 'title-desc' ? -title : title;
    const da = num(a.modifiedAt), db = num(b.modifiedAt);
    if (da == null && db != null) return 1;
    if (db == null && da != null) return -1;
    if (da != null && db != null && da !== db) return st.sort === 'modified-desc' ? db - da : da - db;
    return title;
}

function groups() {
    const gr = { expired: [], doing: [], today: [], tomorrow: [] };
    st.tasks.concat(st.temps).forEach(t => {
        const b = bucketOf(t);
        if (b && gr[b]) gr[b].push(t);
    });
    Object.keys(gr).forEach(k => gr[k].sort(sortTasks));
    return gr;
}

/* calendar: Monday-first grid of this week and the next */
const CAL_DAYS = 14;
function calStart() { return weekStart(todayStart()); }
function calDay() {
    const d = st.calDay;
    return d != null && d >= calStart() && d < addDays(calStart(), CAL_DAYS) ? d : todayStart();
}
// A task belongs to the day of its earliest date (deadline or scheduled).
function dayOfTask(t) {
    const m = minDate(t);
    return m === Infinity ? null : dayStart(m);
}
function openOn(ms) {
    return st.tasks.concat(st.temps).filter(t => t.status !== 'done' && dayOfTask(t) === ms).sort(sortTasks);
}

// Every word of the query must appear in the title (case-insensitive).
function matchesQuery(t) {
    const words = st.query.toLowerCase().split(/\s+/).filter(Boolean);
    const title = String(t.title).toLowerCase();
    return words.every(w => title.indexOf(w) >= 0);
}

function findTask(id) {
    id = String(id);
    return st.tasks.concat(st.temps).find(t => String(t.id) === id) || null;
}
function findDone(id) {
    id = String(id);
    return st.done.find(d => String(d.id) === id) || null;
}

/* ======================================================== */
/* ICONS                                                    */
/* ======================================================== */

const I = {
    todo: '<svg width="16" height="16" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="7.25" stroke="currentColor" stroke-width="1.5"/></svg>',
    review: '<svg width="16" height="16" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="7.25" stroke="currentColor" stroke-width="1.5" stroke-dasharray="2.5 2.5"/></svg>',
    doing: '<svg width="16" height="16" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="7.25" stroke="currentColor" stroke-width="1.5"/><path d="M9 1.75a7.25 7.25 0 0 1 0 14.5z" fill="currentColor"/></svg>',
    done: '<svg width="16" height="16" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="8" fill="#0a84ff"/><path d="M5.5 9.3l2.3 2.3 4.7-5" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    play: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="M5 3.5l7 4.5-7 4.5z"/></svg>',
    pause: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M5.5 3.5v9M10.5 3.5v9"/></svg>',
    check: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>',
    next: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8h9M8.5 4.5L12 8l-3.5 3.5"/></svg>',
    back: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M13 8H4M7.5 4.5L4 8l3.5 3.5"/></svg>',
    cal: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><rect x="2.5" y="3.5" width="11" height="10" rx="2"/><path d="M2.5 6.5h11M5.5 2v3M10.5 2v3"/></svg>'
};

/* ======================================================== */
/* RENDER                                                   */
/* ======================================================== */

function circleFor(t, sec) {
    if (sec === 'done') return I.done;
    if (t.status === 'doing') return I.doing;
    if (t.status === 'in-review') return I.review;
    return I.todo;
}

function chipsFor(t, sec) {
    const c = [];
    if (sec === 'expired') {
        const days = Math.max(1, Math.round((todayStart() - dayStart(minDate(t))) / DAY));
        c.push('<span class="chip red">' + (days === 1 ? 'yesterday' : days + 'd overdue') + '</span>');
    }
    if (sec === 'doing') {
        const m = minDate(t);
        if (m !== Infinity) c.push('<span class="chip' + (m < todayStart() ? ' red' : '') + '">' + esc(dayLabel(dayStart(m))) + '</span>');
    }
    if (t.priority === 'urgent') c.push('<span class="chip red">Urgent</span>');
    else if (t.priority === 'high') c.push('<span class="chip orange">High</span>');
    if (t.status === 'in-review') c.push('<span class="chip blue">In review</span>');
    if (t.status === 'backlog' && sec !== 'done') c.push('<span class="chip">Backlog</span>');
    if (t.pending) c.push('<span class="chip">saving…</span>');
    (t.links || []).slice(0, 2).forEach(l => {
        c.push('<button class="chip" data-act="link" data-url="' + esc(l.url) + '" title="' + esc(l.url) + '">↗ ' + esc(l.host) + '</button>');
    });
    return c.length ? '<div class="meta">' + c.join('') + '</div>' : '';
}

function actsFor(t, sec) {
    if (t.pending || sec === 'done') return '';
    const b = (act, icon, label, cls) =>
        '<button class="ib' + (cls ? ' ' + cls : '') + '" data-act="' + act + '" title="' + label + '" aria-label="' + label + '">' + icon + '</button>';
    const out = [];
    if (sec === 'doing') out.push(b('pause', I.pause, 'Pause (s)'));
    else out.push(b('start', I.play, 'Start (s)', 'go'));
    out.push(b('done', I.check, 'Done (space)', 'ok'));
    if (sec === 'tomorrow') out.push(b('today', I.back, 'Back to today (t)'));
    else if (sec !== 'doing') out.push(b('tomorrow', I.next, 'Tomorrow (t)'));
    out.push(b('menu', I.cal, 'Reschedule (d)'));
    return '<div class="acts">' + out.join('') + '</div>';
}

function moveOptions(t) {
    const s = todayStart();
    const dow = new Date(s).getDay();
    const toMonday = ((8 - dow) % 7) || 7;
    const opts = [];
    if (bucketOf(t) !== 'today') opts.push({ act: 'move', ms: s, label: 'Today', hint: fmtDay(s) });
    if (bucketOf(t) !== 'tomorrow') opts.push({ act: 'move', ms: addDays(s, 1), label: 'Tomorrow', hint: fmtDay(addDays(s, 1)) });
    if (toMonday > 1) opts.push({ act: 'move', ms: addDays(s, toMonday), label: 'Monday', hint: fmtDay(addDays(s, toMonday)) });
    opts.push({ act: 'move', ms: addDays(s, 7), label: 'Next week', hint: fmtDay(addDays(s, 7)) });
    opts.push({ act: 'backlog', label: 'Backlog', hint: 'no date' });
    return opts;
}

function menuFor(t) {
    const opts = moveOptions(t);
    const html = opts.map((o, i) =>
        '<button class="opt" data-act="' + o.act + '" data-ms="' + (o.ms || '') + '">' +
        '<span>' + esc(o.label) + '</span><span class="hint">' + (i + 1) + ' · ' + esc(o.hint) + '</span></button>'
    ).join('');
    const pick =
        '<label class="opt"><span>Pick date…</span><span class="hint">' + (opts.length + 1) + ' · calendar</span>' +
        '<input type="date" data-act="pick" value="' + isoDate(addDays(todayStart(), 1)) + '" min="' + isoDate(todayStart()) + '"></label>';
    return '<div class="menu" data-for="' + esc(t.id) + '">' + html + pick + '</div>';
}

function rowFor(t, sec) {
    const id = String(t.id);
    st.order.push(id);
    st.secOf[id] = sec;
    const cls = ['row', 'st-' + (t.status || 'todo')];
    if (sec === 'expired') cls.push('exp');
    if (sec === 'done') cls.push('is-done');
    if (t.pending) cls.push('pending');
    if (st.sel === id) cls.push('sel');
    const circleAct = sec === 'done' ? 'undone' : 'cycle';
    const circleLabel = sec === 'done' ? 'Mark not done' : (t.status === 'doing' ? 'Mark done' : 'Start');
    let html =
        '<div class="' + cls.join(' ') + '" data-id="' + esc(id) + '">' +
        '<button class="circ" data-act="' + circleAct + '" title="' + circleLabel + '" aria-label="' + circleLabel + '">' + circleFor(t, sec) + '</button>' +
        '<div class="body" data-act="select" title="Double-click to open in Logseq"><div class="ttl">' + esc(t.title) + '</div>' + chipsFor(t, sec) + '</div>' +
        actsFor(t, sec) +
        '</div>';
    if (st.menu === id && sec !== 'done' && !t.pending) html += menuFor(t);
    return html;
}

function section(key, label, items, opts) {
    opts = opts || {};
    if (!items.length && !opts.always) return '';
    const collapsible = key in st.collapsed;
    // While searching, every section with matches is shown expanded.
    const collapsed = collapsible && st.collapsed[key] && !st.query;
    const head =
        (collapsible ? '<button class="sec ' + (opts.cls || '') + '" data-act="section" data-sec="' + key + '">' : '<div class="sec ' + (opts.cls || '') + '">') +
        (collapsible ? '<span class="chev">' + (collapsed ? '▸' : '▾') + '</span>' : '') +
        (opts.dot ? '<span class="pdot"></span>' : '') +
        esc(label) + ' <span class="n">' + items.length + '</span>' +
        (collapsible ? '</button>' : '</div>');
    if (collapsed) return head;
    if (!items.length) return head + '<div class="empty">' + (opts.empty || 'Nothing here.') + '</div>';
    return head + items.map(t => rowFor(t, key)).join('');
}

function renderDays() {
    const on = st.view === 'calendar' && st.loaded;
    daysEl.hidden = !on;
    viewBtn.classList.toggle('on', st.view === 'calendar');
    if (!on) { daysEl.innerHTML = ''; return; }
    const s = todayStart();
    const start = calStart();
    const sel = calDay();
    let cells = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map(d => '<span class="days-dw">' + d + '</span>').join('');
    for (let i = 0; i < CAL_DAYS; i++) {
        const ms = addDays(start, i);
        const n = openOn(ms).length;
        const cls = ['day'];
        if (i % 7 >= 5) cls.push('we');
        if (ms < s) cls.push('past');
        if (ms === s) cls.push('today');
        if (ms === sel) cls.push('sel');
        let inner = '<b>' + new Date(ms).getDate() + '</b>';
        if (ms < s) {
            if (n) inner += '<span class="late">' + n + '</span>';
        } else if (n) {
            inner += n + '<span class="load"><i' + (n >= 5 ? ' class="full"' : '') + ' style="width:' + Math.min(100, n * 20) + '%"></i></span>';
        }
        cells += '<button class="' + cls.join(' ') + '" data-day="' + ms + '" title="' + esc(fmtDay(ms)) + '">' + inner + '</button>';
    }
    daysEl.innerHTML = '<div class="days-grid">' + cells + '</div>';
}

function daySection(day, items, earlier) {
    const head = '<div class="sec' + (day < todayStart() && items.length ? ' red' : '') + '">' +
        esc(dayLabel(day)) + ' <span class="n">' + items.length + '</span>' +
        (earlier ? '<button class="earlier" data-act="list">' + earlier + ' earlier →</button>' : '') +
        '</div>';
    if (!items.length) return head + '<div class="empty">Nothing on this day.</div>';
    return head + items.map(t => rowFor(t, bucketOf(t) || 'later')).join('');
}

function render(opts) {
    opts = opts || {};
    const scrollTop = listEl.scrollTop;
    st.order = [];
    st.secOf = {};
    taskTools.style.display = st.loaded ? '' : 'none';

    const b = bounds();
    dateEl.textContent = new Date(b.start).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
    dotEl.className = 'dot' + (st.loading ? ' loading' : '') + (st.error ? ' error' : '');

    if (!st.loaded) {
        listEl.innerHTML = st.error
            ? '<div class="empty">Couldn’t load tasks: ' + esc(st.error) + ' <button data-act="retry">Retry</button></div>'
            : '<div class="empty">Loading tasks…</div>';
        progEl.style.display = 'none';
    } else {
        const gr = groups();
        const doneItems = st.done.map(d => ({ id: d.id, uuid: d.uuid, title: d.title, links: d.links || [], modifiedAt: d.modifiedAt, status: 'done' })).sort(sortTasks);

        const total = gr.expired.length + gr.doing.length + gr.today.length + doneItems.length;
        progEl.style.display = total ? '' : 'none';
        progBar.style.width = total ? Math.round(doneItems.length / total * 100) + '%' : '0';
        progTxt.textContent = doneItems.length + ' / ' + total + ' done';

        const searching = !!st.query.trim();
        const shown = items => searching ? items.filter(matchesQuery) : items;

        let html = '';
        if (st.error) html += '<div class="empty">Refresh failed: ' + esc(st.error) + ' <button data-act="retry">Retry</button></div>';
        if (st.view === 'calendar') {
            const day = calDay();
            const earlier = gr.expired.filter(t => dayOfTask(t) < calStart()).length;
            html += daySection(day, shown(openOn(day)), earlier);
            if (day === todayStart()) html += section('done', 'Done today', shown(doneItems));
        } else {
            html += section('expired', 'Expired', shown(gr.expired), { cls: 'red' });
            html += section('doing', 'In progress', shown(gr.doing), { cls: 'orange', dot: true });
            html += section('today', 'Today', shown(gr.today), {
                always: !searching,
                empty: gr.expired.length || gr.doing.length ? 'Nothing else for today.' : 'Nothing for today. Add one with ⌘T.'
            });
            html += section('tomorrow', 'Tomorrow', shown(gr.tomorrow));
            html += section('done', 'Done today', shown(doneItems));
        }
        if (searching && !st.order.length) html += '<div class="empty">No tasks match “' + esc(st.query.trim()) + '”.</div>';
        listEl.innerHTML = html;
    }

    if (st.sel != null && st.order.indexOf(st.sel) < 0) st.sel = null;
    if (st.menu != null && st.order.indexOf(st.menu) < 0) st.menu = null;

    renderDays();
    listEl.scrollTop = scrollTop;

    if (opts.scroll && st.sel != null) {
        const el = listEl.querySelector('.row[data-id="' + cssEsc(st.sel) + '"]');
        if (el) {
            const menu = el.nextElementSibling && el.nextElementSibling.classList.contains('menu') ? el.nextElementSibling : null;
            (menu || el).scrollIntoView({ block: 'nearest' });
            el.scrollIntoView({ block: 'nearest' });
        }
    }

    renderFoot();
    requestAnimationFrame(reportHeight);
}

function cssEsc(s) {
    return window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/"/g, '\\"');
}

function renderFoot() {
    const h = (k, label) => '<span class="h"><span class="key">' + k + '</span>' + label + '</span>';
    let html;
    if (st.set) {
        html = h('⌘↩', 'test') + h('⌘S', 'save') + h('esc', 'back');
    } else if (st.picker) {
        html = h('1–6', 'quick') + h('←→↑↓', 'day') + h('↩', 'create') + h('esc', 'back to text');
    } else if (document.activeElement === input) {
        html = h('↩', 'note') + h('⌘T', 'today') + h('⌘⇧T', 'tmrw') + h('⌘B', 'backlog') + h('⌘P', 'page') + h('↓', 'tasks');
    } else if (document.activeElement === searchInput) {
        html = h('↓', 'tasks') + h('esc', 'clear') + h('⌘F', 'search');
    } else if (st.menu != null) {
        html = h('1–6', 'pick') + h('esc', 'cancel');
    } else if (st.view === 'calendar') {
        html = h('↑↓', 'move') + h('←→', 'day') + h('⇧←→', 'week') + h('␣', 'done') + h('D', 'date') + h('↩', 'open') + h('C', 'list');
    } else {
        html = h('↑↓', 'move') + h('␣', 'done') + h('S', 'start') + h('T', 'tmrw') + h('D', 'date') + h('B', 'backlog') + h('↩', 'open') + h('C', 'cal');
    }
    footEl.innerHTML = html;
}

/* ======================================================== */
/* HEIGHT                                                   */
/* ======================================================== */

function reportHeight() {
    const rect = capture.getBoundingClientRect();
    // In settings the list is hidden and the settings body may overflow instead.
    const overflow = st.set ? setBody.scrollHeight - setBody.clientHeight : 0;
    const natural = Math.ceil(rect.height - listEl.clientHeight + listEl.scrollHeight + overflow + 16);
    if (Math.abs(natural - st.lastHeight) >= 1) {
        st.lastHeight = natural;
        post({ action: 'resize', height: natural });
    }
}

function resizeInput() {
    input.style.height = '46px';
    input.style.height = Math.min(160, Math.max(46, input.scrollHeight)) + 'px';
    input.style.overflowY = input.scrollHeight > 160 ? 'auto' : 'hidden';
    requestAnimationFrame(reportHeight);
}

/* ======================================================== */
/* TOAST                                                    */
/* ======================================================== */

function toast(message, opts) {
    opts = opts || {};
    clearTimeout(st.toastTimer);
    toastEl.className = 'toast show' + (opts.error ? ' err' : '');
    toastEl.innerHTML = '<span class="msg">' + esc(message) + '</span>' +
        (opts.undo ? '<button data-act="undo">Undo ⌘Z</button>' : '') +
        (opts.retry ? '<button data-act="retry">Refresh</button>' : '');
    st.toastTimer = setTimeout(() => { toastEl.className = 'toast'; }, opts.error ? 6000 : 4000);
}

/* ======================================================== */
/* TASK ACTIONS                                             */
/* ======================================================== */

function sendUpdate(t, patch) {
    const m = {
        action: 'update',
        req: ++st.req,
        id: typeof t.id === 'number' ? t.id : Number(t.id),
        uuid: t.uuid || '',
        title: t.title || ''
    };
    if (patch.status) m.status = patch.status;
    ['deadline', 'scheduled'].forEach(f => {
        if (f in patch) {
            if (patch[f] == null) m[f + 'Mode'] = 'clear';
            else { m[f + 'Mode'] = 'set'; m[f] = patch[f]; }
        }
    });
    post(m);
}

// Move the task so its earliest date becomes `target` (local midnight).
function computeMove(t, target) {
    const present = ['deadline', 'scheduled'].filter(f => t[f] != null);
    if (!present.length) return { deadline: target };
    const cur = { deadline: t.deadline, scheduled: t.scheduled };
    present.forEach(f => { if (dayStart(cur[f]) < target) cur[f] = target; });
    let minF = present[0];
    present.forEach(f => { if (cur[f] < cur[minF]) minF = f; });
    if (dayStart(cur[minF]) > target) cur[minF] = target;
    const patch = {};
    present.forEach(f => { if (cur[f] !== t[f]) patch[f] = cur[f]; });
    return patch;
}

function keepSelectionNear(prevIndex) {
    if (st.sel != null && st.order.indexOf(st.sel) >= 0) return;
    if (!st.order.length) { st.sel = null; return; }
    st.sel = st.order[Math.min(Math.max(prevIndex, 0), st.order.length - 1)];
}

function act(id, kind, ms) {
    const t = findTask(id);
    if (!t || t.pending) return;

    const prevIndex = st.order.indexOf(String(id));
    const item = Object.assign({}, t);
    let patch, label;

    if (kind === 'start') { patch = { status: 'doing' }; label = 'Started'; }
    else if (kind === 'pause') { patch = { status: 'todo' }; label = 'Paused'; }
    else if (kind === 'done') { patch = { status: 'done' }; label = 'Done ✓'; }
    else if (kind === 'backlog') { patch = { status: 'backlog', deadline: null, scheduled: null }; label = 'Moved to Backlog'; }
    else if (kind === 'move') {
        if (!isFinite(ms)) return;
        patch = computeMove(t, ms);
        // moving an in-progress task to a later day pauses it
        if (t.status === 'doing' && ms > todayStart()) patch.status = 'todo';
        label = 'Moved to ' + dayLabel(ms);
        if (!Object.keys(patch).length) {
            st.menu = null;
            toast('Already on ' + dayLabel(ms));
            render();
            return;
        }
    } else return;

    const restore = {};
    Object.keys(patch).forEach(k => { restore[k] = item[k] == null ? null : item[k]; });
    t.modifiedAt = Date.now();

    if (patch.status === 'done') {
        st.tasks = st.tasks.filter(x => x !== t);
        st.done.unshift({ id: t.id, uuid: t.uuid, title: t.title, links: t.links, modifiedAt: t.modifiedAt });
    } else {
        Object.keys(patch).forEach(k => { t[k] = patch[k]; });
    }

    sendUpdate(t, patch);
    st.undo = { id: t.id, item: item, restore: restore };
    st.menu = null;
    render();
    keepSelectionNear(prevIndex);
    render({ scroll: true });
    toast(label, { undo: true });
}

function undone(id) {
    const d = findDone(id);
    if (!d) return;
    st.done = st.done.filter(x => x !== d);
    sendUpdate(d, { status: 'todo' });
    st.undo = { id: d.id, item: Object.assign({ status: 'done' }, d), restore: { status: 'done' } };
    render();
    toast('Back to todo — will reappear on refresh', { undo: true });
}

function cycle(id) {
    const t = findTask(id);
    if (!t) return;
    if (t.status === 'doing') act(id, 'done');
    else act(id, 'start');
}

function undo() {
    const u = st.undo;
    if (!u) { toast('Nothing to undo'); return; }
    st.undo = null;

    if (u.restore.status === 'done') {
        st.tasks = st.tasks.filter(x => String(x.id) !== String(u.id));
        if (!findDone(u.id)) st.done.unshift({ id: u.item.id, uuid: u.item.uuid, title: u.item.title, links: u.item.links, modifiedAt: Date.now() });
    } else {
        st.done = st.done.filter(x => String(x.id) !== String(u.id));
        let t = findTask(u.id);
        if (!t) { t = Object.assign({}, u.item); st.tasks.push(t); }
        Object.keys(u.restore).forEach(k => { t[k] = u.restore[k]; });
        t.modifiedAt = Date.now();
    }

    sendUpdate(u.item, u.restore);
    st.sel = String(u.id);
    render({ scroll: true });
    toast('Undone');
}

function toggleMenu(id) {
    id = String(id);
    st.sel = id;
    st.menu = st.menu === id ? null : id;
    render({ scroll: true });
}

function pickMenu(index) {
    const t = findTask(st.menu);
    if (!t) return;
    const opts = moveOptions(t);
    if (index < opts.length) {
        const o = opts[index];
        if (o.act === 'backlog') act(t.id, 'backlog');
        else act(t.id, 'move', o.ms);
    } else if (index === opts.length) {
        const dateInput = listEl.querySelector('.menu input[type=date]');
        if (dateInput) {
            dateInput.focus();
            try { dateInput.showPicker && dateInput.showPicker(); } catch (e) { /* not supported */ }
        }
    }
}

function openTask(id) {
    const t = findTask(id) || findDone(id);
    if (t && t.uuid) post({ action: 'openBlock', uuid: t.uuid });
}

// Selection only toggles a class. Rebuilding the list here would replace the
// row mid-gesture, so the second click never becomes a dblclick.
function paintSelection() {
    listEl.querySelectorAll('.row.sel').forEach(el => el.classList.remove('sel'));
    if (st.sel != null) {
        const el = listEl.querySelector('.row[data-id="' + cssEsc(st.sel) + '"]');
        if (el) el.classList.add('sel');
    }
    renderFoot();
}

function setView(view) {
    st.view = view;
    st.calDay = null;
    st.sel = null;
    st.menu = null;
    render();
    listEl.focus({ preventScroll: true });
}

function moveCalDay(delta) {
    const start = calStart();
    st.calDay = Math.min(addDays(start, CAL_DAYS - 1), Math.max(start, addDays(calDay(), delta)));
    st.sel = null;
    st.menu = null;
    render();
}

function select(id) {
    st.sel = id == null ? null : String(id);
    if (document.activeElement === input) input.blur();
    listEl.focus({ preventScroll: true });
    paintSelection();
}

function focusInput() {
    st.menu = null;
    input.focus();
    render();
}

/* ======================================================== */
/* CAPTURE                                                  */
/* ======================================================== */

function submit(kind, dateMs) {
    const text = input.value.trim();
    if (!text || st.closing) { input.focus(); return; }

    if (kind === 'today' || kind === 'tomorrow' || kind === 'date') {
        const tomorrow = addDays(todayStart(), 1);
        const ms = kind === 'date' ? dateMs : (kind === 'today' ? todayStart() : tomorrow);
        const req = ++st.req;
        const pt = parseTitle(text);
        // Tasks past the calendar window get just the toast.
        if (ms < bounds().until) {
            st.temps.push({ id: 'tmp' + req, req: req, pending: true, status: 'todo', priority: '', modifiedAt: Date.now(), deadline: ms, scheduled: null, title: pt.text, links: pt.links });
        }
        post({ action: 'capture', kind: kind, text: text, ms: ms, req: req });
        input.value = '';
        resizeInput();
        if (ms === tomorrow) st.collapsed.tomorrow = false;
        setPicker(null);
        render();
        toast(ms === todayStart() ? 'Added to Today' : (ms === tomorrow ? 'Added to Tomorrow' : 'Added for ' + fmtDay(ms)));
        return;
    }

    animateClose(() => {
        input.value = '';
        resizeInput();
        post({ action: 'capture', kind: kind, text: text });
    });
}

/* ======================================================== */
/* DATE PICKER                                              */
/* ======================================================== */

function nextWeekday(from, dow) {
    return addDays(from, ((dow - new Date(from).getDay() + 7) % 7) || 7);
}

function inAMonth(from) {
    const d = new Date(from);
    const lastDay = new Date(d.getFullYear(), d.getMonth() + 2, 0).getDate();
    return new Date(d.getFullYear(), d.getMonth() + 1, Math.min(d.getDate(), lastDay)).getTime();
}

function quickDates() {
    const s = todayStart();
    const opts = [
        { label: 'Today', ms: s },
        { label: 'Tomorrow', ms: addDays(s, 1) },
        { label: 'Friday', ms: nextWeekday(s, 5) },
        { label: 'Weekend', ms: nextWeekday(s, 6) },
        { label: 'Next week', ms: nextWeekday(s, 1) },
        { label: 'In a month', ms: inAMonth(s) }
    ];
    const seen = {};
    return opts.filter(o => !seen[o.ms] && (seen[o.ms] = true));
}

function calendarHtml(p) {
    const s = todayStart();
    const m = new Date(p.month);
    const title = m.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
    const lead = (m.getDay() + 6) % 7;
    const days = new Date(m.getFullYear(), m.getMonth() + 1, 0).getDate();
    let cells = ['M', 'T', 'W', 'T', 'F', 'S', 'S'].map(d => '<span class="cal-dw">' + d + '</span>').join('');
    for (let i = 0; i < lead; i++) cells += '<span></span>';
    for (let d = 1; d <= days; d++) {
        const ms = new Date(m.getFullYear(), m.getMonth(), d).getTime();
        const cls = ['cal-day'];
        if (ms === s) cls.push('today');
        if (ms === p.ms) cls.push('cur');
        cells += '<button class="' + cls.join(' ') + '" data-ms="' + ms + '"' + (ms < s ? ' disabled' : '') + '>' + d + '</button>';
    }
    const atFirst = p.month <= monthStart(s);
    return '<div class="cal"><div class="cal-head"><span>' + esc(title) + '</span><span>' +
        '<button class="cal-nav" data-month="-1" aria-label="Previous month"' + (atFirst ? ' disabled' : '') + '>‹</button>' +
        '<button class="cal-nav" data-month="1" aria-label="Next month">›</button>' +
        '</span></div><div class="cal-grid">' + cells + '</div></div>';
}

function renderPicker() {
    pickerEl.hidden = !st.picker;
    dateBtn.classList.toggle('on', !!st.picker);
    if (!st.picker) { pickerEl.innerHTML = ''; return; }
    const opts = quickDates().map((o, i) =>
        '<button class="opt' + (o.ms === st.picker.ms ? ' sel' : '') + '" data-ms="' + o.ms + '">' +
        '<span>' + esc(o.label) + '</span><span class="hint">' + (i + 1) + ' · ' + esc(fmtShortDay(o.ms)) + '</span></button>'
    ).join('');
    pickerEl.innerHTML = '<div class="picker-opts">' + opts + '</div>' + calendarHtml(st.picker);
}

function fmtShortDay(ms) {
    return new Date(ms).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
}

function setPicker(p) {
    st.picker = p;
    renderPicker();
    renderFoot();
    requestAnimationFrame(reportHeight);
}

// Opens with no day selected; the first arrow press puts the cursor on today.
function togglePicker() {
    setPicker(st.picker ? null : { ms: null, month: monthStart(todayStart()) });
    input.focus();
}

function movePickerDay(days) {
    const ms = st.picker.ms == null ? todayStart() : Math.max(todayStart(), addDays(st.picker.ms, days));
    setPicker({ ms: ms, month: monthStart(ms) });
}

function movePickerMonth(delta) {
    const m = new Date(st.picker.month);
    const month = Math.max(monthStart(todayStart()), new Date(m.getFullYear(), m.getMonth() + delta, 1).getTime());
    setPicker({ ms: st.picker.ms, month: month });
}

/* ======================================================== */
/* OPEN / CLOSE                                             */
/* ======================================================== */

function resetCapture() {
    st.closing = false;
    capture.getAnimations().forEach(a => a.cancel());
    capture.classList.remove('closing');
    capture.style.opacity = '';
    capture.style.transform = '';
    st.set = null;
    capture.classList.remove('in-settings');
    st.menu = null;
    st.sel = null;
    st.calDay = null;
    st.picker = null;
    renderPicker();
    sortMenu.open = false;
    closeSearch();
    st.lastHeight = 0;
    resizeInput();
    render();
    capture.animate(
        [{ opacity: 0, transform: 'translate3d(0, 14px, 0)' }, { opacity: 1, transform: 'translate3d(0, 0, 0)' }],
        { duration: 170, easing: 'cubic-bezier(.22, .61, .36, 1)' }
    );
    setTimeout(() => { input.focus(); renderFoot(); }, 20);
}

function animateClose(done) {
    if (st.closing) return;
    st.closing = true;
    capture.classList.add('closing');
    const animation = capture.animate(
        [{ opacity: 1, transform: 'translate3d(0, 0, 0)' }, { opacity: 0, transform: 'translate3d(0, 18px, 0)' }],
        { duration: 180, easing: 'cubic-bezier(.22, .61, .36, 1)', fill: 'forwards' }
    );
    animation.onfinish = () => { if (done) done(); };
}

function closePanel() {
    animateClose(() => post({ action: 'close' }));
}

/* ======================================================== */
/* EVENTS                                                   */
/* ======================================================== */

document.documentElement.addEventListener('mouseleave', () => {
    // Let an in-flight submission finish before hiding its webview.
    if (!st.closing) post({ action: 'close' });
});

input.addEventListener('input', resizeInput);
input.addEventListener('focus', () => { st.menu = null; renderFoot(); });
input.addEventListener('blur', renderFoot);

document.querySelectorAll('[data-kind]').forEach(button => {
    button.addEventListener('mousedown', e => e.preventDefault());
    button.addEventListener('click', () => {
        if (button.dataset.kind === 'date') togglePicker(); else submit(button.dataset.kind);
    });
});

// Keep focus (and the caret) in the input while using the picker.
pickerEl.addEventListener('mousedown', e => e.preventDefault());
pickerEl.addEventListener('click', e => {
    const nav = e.target.closest('[data-month]');
    if (nav) { movePickerMonth(Number(nav.dataset.month)); return; }
    const day = e.target.closest('[data-ms]');
    if (day) submit('date', Number(day.dataset.ms));
});

$('closeBtn').addEventListener('click', closePanel);
$('dashBtn').addEventListener('click', () => post({ action: 'openPage' }));

/* search */

// Filtering shrinks the list; pin the panel height while searching so the
// window doesn't shrink out from under the mouse (mouseleave closes it).
function openSearch() {
    if (!searchEl.classList.contains('open')) capture.style.minHeight = capture.offsetHeight + 'px';
    searchEl.classList.add('open');
    searchInput.focus();
    searchInput.select();
    renderFoot();
}

function closeSearch() {
    st.query = '';
    searchInput.value = '';
    searchEl.classList.remove('open');
    capture.style.minHeight = '';
}

$('searchBtn').addEventListener('click', openSearch);
searchInput.addEventListener('input', () => {
    st.query = searchInput.value;
    st.menu = null;
    render();
});
searchInput.addEventListener('focus', renderFoot);
searchInput.addEventListener('blur', () => {
    if (!searchInput.value) closeSearch();
    renderFoot();
});

sortMenu.addEventListener('click', e => {
    const option = e.target.closest('[data-sort]');
    if (!option) return;
    st.sort = option.dataset.sort;
    sortMenu.querySelectorAll('[data-sort]').forEach(button => {
        button.setAttribute('aria-checked', String(button === option));
    });
    sortMenu.open = false;
    listEl.focus({ preventScroll: true });
    render();
});
document.addEventListener('click', e => {
    if (!sortMenu.contains(e.target)) sortMenu.open = false;
});

function onClick(e) {
    const target = e.target.closest('[data-act]');
    const row = e.target.closest('.row');
    const menu = e.target.closest('.menu');
    const id = row ? row.dataset.id : (menu ? menu.dataset.for : null);

    if (!target) {
        if (row) select(id);
        return;
    }

    const action = target.dataset.act;

    switch (action) {
        case 'select': select(id); break;
        case 'cycle': cycle(id); break;
        case 'start': case 'pause': case 'done': act(id, action); break;
        case 'tomorrow': act(id, 'move', addDays(todayStart(), 1)); break;
        case 'today': act(id, 'move', todayStart()); break;
        case 'menu': toggleMenu(id); break;
        case 'move': act(id, 'move', Number(target.dataset.ms)); break;
        case 'backlog': act(id, 'backlog'); break;
        case 'undone': undone(id); break;
        case 'link': post({ action: 'openUrl', url: target.dataset.url }); break;
        case 'section':
            st.collapsed[target.dataset.sec] = !st.collapsed[target.dataset.sec];
            render();
            break;
        case 'undo': undo(); break;
        case 'retry': post({ action: 'refresh' }); break;
        case 'list': setView('list'); break;
        case 'dashboard': post({ action: 'openPage' }); break;
        case 'pick': break;
    }
}

listEl.addEventListener('click', onClick);
viewBtn.addEventListener('click', () => setView(st.view === 'calendar' ? 'list' : 'calendar'));
daysEl.addEventListener('click', e => {
    const cell = e.target.closest('[data-day]');
    if (!cell) return;
    st.calDay = Number(cell.dataset.day);
    st.sel = null;
    st.menu = null;
    render();
    listEl.focus({ preventScroll: true });
});
footEl.addEventListener('click', onClick);
toastEl.addEventListener('click', onClick);

// The native date picker opens its own window: don't treat that as "click away".
listEl.addEventListener('focusin', e => {
    if (e.target.matches('input[type=date]')) post({ action: 'pinBlur', on: true });
});
listEl.addEventListener('focusout', e => {
    if (e.target.matches('input[type=date]')) post({ action: 'pinBlur', on: false });
});

listEl.addEventListener('dblclick', e => {
    const row = e.target.closest('.row');
    if (row && !e.target.closest('button')) openTask(row.dataset.id);
});

listEl.addEventListener('change', e => {
    if (!e.target.matches('input[type=date]')) return;
    const value = e.target.value;
    const menu = e.target.closest('.menu');
    if (!value || !menu) return;
    const parts = value.split('-').map(Number);
    act(menu.dataset.for, 'move', new Date(parts[0], parts[1] - 1, parts[2]).getTime());
    listEl.focus({ preventScroll: true });
});

function moveSel(delta) {
    const o = st.order;
    if (!o.length) return;
    let i = o.indexOf(st.sel);
    if (i < 0) i = delta > 0 ? -1 : o.length;
    const next = i + delta;
    if (next < 0) { focusInput(); return; }
    st.sel = o[Math.min(next, o.length - 1)];
    st.menu = null;
    render({ scroll: true });
}

document.addEventListener('keydown', e => {
    if (st.closing) return;

    if (st.set) { onSettingsKey(e); return; }
    if (e.metaKey && e.key === ',') { e.preventDefault(); openSettings(); return; }

    const k = e.key;
    const lower = k.length === 1 ? k.toLowerCase() : k;
    const inInput = e.target === input;
    const inDate = e.target.matches && e.target.matches('input[type=date]');
    const meta = e.metaKey;

    if (meta && lower === 'f') { e.preventDefault(); openSearch(); return; }

    if (e.target === searchInput) {
        if (k === 'Escape') {
            e.preventDefault();
            closeSearch();
            render();
            listEl.focus({ preventScroll: true });
            return;
        }
        if ((k === 'ArrowDown' || (k === 'Enter' && !e.isComposing)) && st.order.length) {
            e.preventDefault();
            listEl.focus({ preventScroll: true });
            st.sel = st.order[0];
            render({ scroll: true });
        }
        return;
    }

    if (k === 'Escape') {
        e.preventDefault();
        if (sortMenu.open) {
            sortMenu.open = false;
            sortMenu.querySelector('summary').focus({ preventScroll: true });
            return;
        }
        if (st.picker) {
            setPicker(null);
            return;
        }
        if (st.menu != null) {
            st.menu = null;
            listEl.focus({ preventScroll: true });
            render();
            return;
        }
        if (st.query) {
            closeSearch();
            render();
            return;
        }
        closePanel();
        return;
    }

    if (meta && lower === 'r') { e.preventDefault(); post({ action: 'refresh' }); return; }

    if (meta && !e.shiftKey && lower === 'z' && !(inInput && input.value)) {
        e.preventDefault();
        undo();
        return;
    }

    if (inInput) {
        if (meta && lower === 'd') { e.preventDefault(); togglePicker(); return; }
        if (st.picker && !meta && !e.isComposing) {
            const quick = quickDates();
            if (/^[1-9]$/.test(k) && Number(k) <= quick.length) { e.preventDefault(); submit('date', quick[Number(k) - 1].ms); return; }
            const step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }[k];
            if (step) { e.preventDefault(); movePickerDay(step); return; }
            if (k === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                if (st.picker.ms != null) submit('date', st.picker.ms);
                return;
            }
        }
        if (meta && lower === 'b') { e.preventDefault(); submit('backlog'); return; }
        if (meta && lower === 'p') { e.preventDefault(); submit('page'); return; }
        if (meta && lower === 't') { e.preventDefault(); submit(e.shiftKey ? 'tomorrow' : 'today'); return; }
        if (k === 'Enter' && !e.shiftKey && !meta && !e.isComposing) { e.preventDefault(); submit('note'); return; }
        const atEnd = input.selectionStart === input.value.length && input.selectionEnd === input.value.length;
        if ((k === 'ArrowDown' && atEnd) || (k === 'Tab' && !e.shiftKey)) {
            if (st.order.length) {
                e.preventDefault();
                input.blur();
                listEl.focus({ preventScroll: true });
                st.sel = st.order[0];
                render({ scroll: true });
            }
        }
        return;
    }

    if (inDate || sortMenu.contains(e.target)) return;
    if (meta || e.ctrlKey || e.altKey) return;

    if (st.menu != null && /^[1-9]$/.test(k)) {
        e.preventDefault();
        pickMenu(Number(k) - 1);
        return;
    }

    if (lower === 'c') { e.preventDefault(); setView(st.view === 'calendar' ? 'list' : 'calendar'); return; }
    if (st.view === 'calendar' && (k === 'ArrowLeft' || k === 'ArrowRight')) {
        e.preventDefault();
        moveCalDay((k === 'ArrowLeft' ? -1 : 1) * (e.shiftKey ? 7 : 1));
        return;
    }

    const sel = st.sel;
    const sec = sel != null ? st.secOf[sel] : null;

    switch (lower) {
        case 'ArrowDown': case 'j': e.preventDefault(); moveSel(1); break;
        case 'ArrowUp': case 'k': e.preventDefault(); moveSel(-1); break;
        case ' ': case 'x':
            e.preventDefault();
            if (sel == null) break;
            if (sec === 'done') undone(sel); else act(sel, 'done');
            break;
        case 's':
            e.preventDefault();
            if (sel == null || sec === 'done') break;
            act(sel, sec === 'doing' ? 'pause' : 'start');
            break;
        case 't':
            e.preventDefault();
            if (sel == null || sec === 'done') break;
            act(sel, 'move', sec === 'tomorrow' ? todayStart() : addDays(todayStart(), 1));
            break;
        case 'd':
            e.preventDefault();
            if (sel != null && sec !== 'done') toggleMenu(sel);
            break;
        case 'b':
            e.preventDefault();
            if (sel != null && sec !== 'done') act(sel, 'backlog');
            break;
        case 'Enter': case 'o':
            e.preventDefault();
            if (sel != null) openTask(sel);
            break;
        case '/': case 'n': case 'Tab':
            e.preventDefault();
            focusInput();
            break;
    }
});

/* ======================================================== */
/* SETTINGS: which tasks the panel shows (filter.lua)       */
/* ======================================================== */

const settingsEl = $('settings');
const setBody = $('setBody');
const setRes = $('setRes');
const setMode = $('setMode');
const setTestBtn = $('setTest');
const setSaveBtn = $('setSave');

const arr = v => (Array.isArray(v) ? v : []);

function readFilter(f) {
    f = f || {};
    return {
        mode: f.mode === 'custom' ? 'custom' : 'statuses',
        statuses: arr(f.statuses).map(String),
        noStatusAsTodo: f.noStatusAsTodo !== false,
        query: typeof f.query === 'string' ? f.query : ''
    };
}

// Save needs a passing test of exactly this filter.
function filterSig(f) {
    return JSON.stringify(f.mode === 'custom'
        ? { mode: 'custom', query: f.query }
        : { mode: 'statuses', statuses: f.statuses.slice().sort(), noStatusAsTodo: f.noStatusAsTodo });
}

function openSettings() {
    st.menu = null;
    setPicker(null);
    sortMenu.open = false;
    st.set = { filter: null, graph: '', statuses: null, statusError: null, req: 0, testing: false, testSig: null, okSig: null, test: null };
    capture.classList.add('in-settings');
    renderSettings();
    settingsEl.focus({ preventScroll: true });
    post({ action: 'settingsOpen' });
}

function closeSettings() {
    if (!st.set) return;
    st.set = null;
    capture.classList.remove('in-settings');
    focusInput();
}

function statusRows() {
    const s = st.set;
    const f = s.filter;
    if (!s.statuses && !s.statusError) return '<div class="set-opt off">Loading statuses…</div>';
    const items = arr(s.statuses).slice();
    f.statuses.forEach(id => {
        if (!items.some(it => it.ident === id)) items.push({ ident: id, title: identTail(id) });
    });
    let html = s.statusError ? '<div class="set-opt off">Couldn’t load statuses: ' + esc(s.statusError) + '</div>' : '';
    html += items.map(it =>
        '<label class="set-opt' + (it.closed ? ' off' : '') + '">' +
        '<input type="checkbox" data-status="' + esc(it.ident) + '"' +
        (f.statuses.indexOf(it.ident) >= 0 ? ' checked' : '') + (it.closed ? ' disabled' : '') + '>' +
        esc(it.title) + '<span class="sub">' + (it.closed ? 'closed · not shown' : esc(identTail(it.ident))) + '</span></label>'
    ).join('');
    return html;
}

function renderSettings() {
    const s = st.set;
    if (!s) return;
    const f = s.filter;
    setMode.querySelectorAll('button').forEach(b => b.classList.toggle('on', !!f && b.dataset.mode === f.mode));
    if (!f) {
        setBody.innerHTML = '<div class="empty">Loading settings…</div>';
    } else if (f.mode === 'custom') {
        setBody.innerHTML = '<h4>Datalog · input ?until (epoch ms)</h4>' +
            '<textarea class="set-query" id="setQuery" spellcheck="false"></textarea>' +
            '<p class="set-note">Keep the pull pattern and <code>:in $ ?until</code> of the default query.</p>';
        $('setQuery').value = f.query;
    } else {
        setBody.innerHTML = '<h4>Open statuses' + (s.graph ? ' · graph “' + esc(s.graph) + '”' : '') + '</h4>' +
            '<div class="set-box">' + statusRows() + '</div>' +
            '<div class="set-box"><label class="set-opt"><input type="checkbox" data-nostatus' +
            (f.noStatusAsTodo ? ' checked' : '') + '>#Task without a status counts as Todo</label></div>' +
            '<p class="set-note">Doing tasks show without a date; others need a deadline or scheduled date.</p>';
    }
    renderSettingsResult();
}

function renderSettingsResult() {
    const s = st.set;
    if (!s) return;
    const r = s.test;
    if (s.testing) {
        setRes.className = 'set-res';
        setRes.textContent = 'Testing…';
    } else if (!r) {
        setRes.className = 'set-res';
        setRes.innerHTML = '';
    } else if (r.ok) {
        setRes.className = 'set-res ok';
        setRes.innerHTML = '<div class="h">✓ ' + r.count + (r.count === 1 ? ' task' : ' tasks') +
            ' · ' + (Number(r.seconds) || 0).toFixed(1) + ' s</div>' +
            (r.sample.length ? '<ul>' + r.sample.map(p => '<li>' + esc(parseTitle(p.title, p.refs).text) + '</li>').join('') + '</ul>' : '');
    } else {
        setRes.className = 'set-res err';
        setRes.innerHTML = '<div class="h">✕ Test failed</div><code>' + esc(r.message || 'unknown error') + '</code>';
    }
    setTestBtn.disabled = !s.filter || s.testing;
    setSaveBtn.disabled = !s.filter || s.testing || s.okSig !== filterSig(s.filter);
    renderFoot();
    requestAnimationFrame(reportHeight);
}

function filterChanged() {
    st.set.test = null;
    renderSettingsResult();
}

function testSettings() {
    const s = st.set;
    if (!s || !s.filter || s.testing) return;
    s.req += 1;
    s.testing = true;
    s.test = null;
    s.testSig = filterSig(s.filter);
    renderSettingsResult();
    post({ action: 'settingsTest', req: s.req, filter: s.filter });
}

function saveSettings() {
    if (!st.set || setSaveBtn.disabled) return;
    post({ action: 'settingsSave', filter: st.set.filter });
}

function onSettingsKey(e) {
    const lower = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (e.key === 'Escape' || (e.metaKey && e.key === ',')) { e.preventDefault(); closeSettings(); return; }
    if (e.metaKey && e.key === 'Enter') { e.preventDefault(); testSettings(); return; }
    if (e.metaKey && lower === 's') { e.preventDefault(); saveSettings(); }
}

$('settingsBtn').addEventListener('click', openSettings);
$('settingsBack').addEventListener('click', closeSettings);
$('settingsClose').addEventListener('click', closePanel);
setTestBtn.addEventListener('click', testSettings);
setSaveBtn.addEventListener('click', saveSettings);
$('setReset').addEventListener('click', () => { if (st.set) post({ action: 'settingsReset' }); });

setMode.addEventListener('click', e => {
    const b = e.target.closest('button[data-mode]');
    const s = st.set;
    if (!b || !s || !s.filter || s.filter.mode === b.dataset.mode) return;
    s.filter.mode = b.dataset.mode;
    s.test = null;
    renderSettings();
    if (s.filter.mode === 'custom' && !s.filter.query.trim()) post({ action: 'settingsBuild', filter: s.filter });
});

setBody.addEventListener('change', e => {
    const s = st.set;
    const t = e.target;
    if (!s || !s.filter) return;
    if (t.dataset.status != null) {
        s.filter.statuses = s.filter.statuses.filter(id => id !== t.dataset.status);
        if (t.checked) s.filter.statuses.push(t.dataset.status);
    } else if (t.hasAttribute('data-nostatus')) {
        s.filter.noStatusAsTodo = t.checked;
    } else {
        return;
    }
    filterChanged();
});

setBody.addEventListener('input', e => {
    if (e.target.id !== 'setQuery' || !st.set || !st.set.filter) return;
    st.set.filter.query = e.target.value;
    filterChanged();
});

/* ======================================================== */
/* API FOR LUA                                              */
/* ======================================================== */

window.app = {
    setData(raw, meta) {
        const res = raw && raw.data ? raw.data.result : null;
        const rows = Array.isArray(res) ? res : [];
        st.tasks = rows
            .map(r => (Array.isArray(r) ? r[0] : r))
            .filter(p => p && typeof p === 'object')
            .map(normTask)
            .filter(t => t.id != null);
        meta = meta || {};
        if (meta.start) st.bounds = { start: meta.start, end: meta.end, end2: meta.end2, until: meta.until || addDays(weekStart(meta.start), 14) };
        st.done = (Array.isArray(meta.done) ? meta.done : []).map(d => ({
            id: d.id, uuid: d.uuid || '', title: d.title || '', links: [], modifiedAt: num(d.modifiedAt)
        }));
        st.temps = [];
        st.loaded = true;
        st.error = null;
        render();
    },
    setDashboard(info) {
        const page = (info && info.page) || '';
        const btn = $('dashBtn');
        btn.hidden = !page;
        btn.nextElementSibling.hidden = !page;
        btn.textContent = page + ' ↗';
        btn.title = 'Open ' + page + ' in Logseq';
    },
    setLoading(on) {
        st.loading = !!on;
        dotEl.className = 'dot' + (st.loading ? ' loading' : '') + (st.error ? ' error' : '');
    },
    setError(info) {
        st.error = (info && info.message) || 'unknown error';
        st.loading = false;
        render();
    },
    result(info) {
        if (!info || info.ok) return;
        st.temps = st.temps.filter(t => t.req !== info.req);
        render();
        toast('Logseq: ' + (info.message || 'error'), { error: true, retry: true });
    },
    settingsLoaded(info) {
        const s = st.set;
        if (!s) return;
        s.filter = readFilter(info && info.filter);
        s.graph = (info && info.graph) || '';
        s.test = null;
        s.okSig = null;
        renderSettings();
        if (s.filter.mode === 'custom' && !s.filter.query.trim()) post({ action: 'settingsBuild', filter: s.filter });
        if (info && info.reset) toast('Reset to default');
    },
    settingsStatuses(info) {
        const s = st.set;
        if (!s) return;
        if (info && info.ok) {
            s.statuses = arr(info.items);
            s.statusError = null;
        } else {
            s.statusError = (info && info.message) || 'unknown error';
        }
        if (s.filter && s.filter.mode === 'statuses') renderSettings();
    },
    settingsBuilt(info) {
        const s = st.set;
        if (!s || !s.filter || s.filter.mode !== 'custom' || s.filter.query.trim()) return;
        s.filter.query = (info && info.query) || '';
        const q = $('setQuery');
        if (q) q.value = s.filter.query;
    },
    settingsTested(info) {
        const s = st.set;
        if (!s || !info || info.req !== s.req) return;
        s.testing = false;
        s.test = { ok: !!info.ok, count: info.count || 0, sample: arr(info.sample), seconds: info.seconds, message: info.message };
        s.okSig = info.ok && s.testSig === filterSig(s.filter) ? s.testSig : null;
        if (s.okSig == null && info.ok) s.test = null;
        renderSettingsResult();
    },
    settingsSaved() {
        if (!st.set) return;
        closeSettings();
        toast('Settings saved');
    },
    reset: resetCapture
};

window.logseqCaptureReset = resetCapture;

document.addEventListener('DOMContentLoaded', () => {
    resizeInput();
    render();
    post({ action: 'ready' });
});

})();
