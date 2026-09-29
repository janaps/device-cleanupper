// Small DOM helpers. Everything goes in as text (textContent), never as HTML:
// device names and notes come from spreadsheets and pasted text.

export function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null) continue;
    if (v === false) { if (k in el && !k.startsWith('on')) el[k] = false; continue; }
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k in el && !k.startsWith('aria') && k !== 'role' && k !== 'for') el[k] = v;
    else el.setAttribute(k === 'for' ? 'for' : k, v === true ? '' : String(v));
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

export function fill(el, ...children) {
  el.replaceChildren();
  append(el, children);
  return el;
}

const PATHS = {
  check:  ['M5 12.5l4.5 4.5L19 7.5'],
  circle: [],
  half:   ['M12 4a8 8 0 0 1 0 16z'],
  lock:   ['M7 11V8a5 5 0 0 1 10 0v3', 'M6 11h12v9H6z'],
  alert:  ['M12 3.5l9.5 17h-19z', 'M12 10v4.5', 'M12 17.5v.5'],
  x:      ['M7 7l10 10', 'M17 7L7 17'],
  info:   ['M12 11v6', 'M12 7.5v.5'],
  run:    ['M12 4a8 8 0 0 1 8 8'],
};

export function icon(name, label) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('class', `icon icon-${name}`);
  if (label) { svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', label); }
  else svg.setAttribute('aria-hidden', 'true');
  if (['circle', 'half', 'info'].includes(name)) {
    const c = document.createElementNS(ns, 'circle');
    c.setAttribute('cx', '12'); c.setAttribute('cy', '12'); c.setAttribute('r', '8');
    svg.append(c);
  }
  for (const d of PATHS[name] || []) {
    const p = document.createElementNS(ns, 'path');
    p.setAttribute('d', d);
    if (name === 'half' && d.startsWith('M12 4a')) p.setAttribute('class', 'fill');
    svg.append(p);
  }
  return svg;
}
