(function () {
'use strict';
let tasks = [];
let hoverAnimation = null;
let elapsedTimer = null;
const pill = document.getElementById('pill');
const RING = '<svg width="14" height="14" viewBox="0 0 18 18" fill="none"><circle cx="9" cy="9" r="7.25" stroke="currentColor" stroke-width="1.5"/><path d="M9 1.75a7.25 7.25 0 0 1 0 14.5z" fill="currentColor"/></svg>';
function formatElapsed(startedAt) {
    if (!Number.isFinite(startedAt)) return '';
    const seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor(seconds / 60) % 60;
    const pad = n => String(n).padStart(2, '0');
    return (hours ? hours + ':' : '') + pad(minutes) + ':' + pad(seconds % 60);
}
function renderElapsed() {
    pill.querySelectorAll('.elapsed').forEach((el, i) => {
        el.textContent = formatElapsed(tasks[i] && tasks[i].startedAt);
    });
}
function post(m) {
    try { window.webkit.messageHandlers.logseqPeek.postMessage(m); } catch (e) { console.error(e); }
}
function cleanTitle(raw, refs) {
    const map = {};
    (refs || []).forEach(r => { if (r.uuid) map[String(r.uuid).toLowerCase()] = r.title; });
    let t = String(raw || '')
        .replace(/\[\[([0-9a-f-]{36})\]\]/gi, (m, u) => map[u.toLowerCase()] || '…')
        .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '$1')
        .replace(/\[\[([^\]]+)\]\]/g, '$1');
    let host = '';
    t = t.replace(/https?:\/\/[^\s<>()\[\]]+/g, u => { if (!host) { try { host = new URL(u).hostname.replace(/^www\./, ''); } catch (e) {} } return ' '; });
    t = t.replace(/\s+/g, ' ').replace(/^[\s\-–—:·|]+|[\s\-–—:·|]+$/g, '').trim();
    return t || host || 'Untitled';
}
window.peek = {
    setHovered(on) {
        if (hoverAnimation) hoverAnimation.cancel();
        hoverAnimation = pill.animate(
            on
                ? [{ transform: 'translateX(0)' }, { transform: 'translateX(110%)' }]
                : [{ transform: 'translateX(110%)' }, { transform: 'translateX(0)' }],
            { duration: 150, easing: 'ease-out', fill: 'forwards' }
        );
        if (on) hoverAnimation.onfinish = () => post({ action: 'hoverHidden' });
    },
    set(list) {
        tasks = Array.isArray(list) ? list.slice(0, 5) : [];
        pill.textContent = '';
        tasks.forEach(t => {
            const row = document.createElement('button');
            row.className = 'row';
            row.dataset.act = 'expand';
            row.title = 'Open panel';
            row.innerHTML = '<span class="ring">' + RING + '</span>' +
                '<span class="ttl"></span>' +
                '<span class="elapsed" title="Elapsed since starting in this panel"></span>';
            row.querySelector('.ttl').textContent = cleanTitle(t.title, t.refs);
            pill.appendChild(row);
        });
        if (elapsedTimer) clearInterval(elapsedTimer);
        elapsedTimer = null;
        renderElapsed();
        if (tasks.some(t => Number.isFinite(t.startedAt))) elapsedTimer = setInterval(renderElapsed, 1000);
    }
};
document.addEventListener('click', e => {
    const b = e.target.closest('[data-act]');
    if (!b || !tasks.length) return;
    const act = b.dataset.act;
    if (act === 'expand') post({ action: 'expand' });
});
document.addEventListener('DOMContentLoaded', () => post({ action: 'ready' }));
})();
