// Talking to the local host. Every /api call carries the per-launch token,
// which arrives in the URL fragment (never sent to a server, never in a
// Referer) and is kept for this tab only.

let token = '';

export function initToken() {
  const m = /(?:^|[#&])token=([0-9a-f]{64})/.exec(location.hash);
  if (m) {
    token = m[1];
    try { sessionStorage.setItem('dcu-token', token); } catch { /* private mode: keep it in memory */ }
    // take it out of the address bar, keep the page if the link named one
    const page = /(?:^|[#&])page=([A-Za-z]+)/.exec(location.hash);
    history.replaceState(null, '', location.pathname + (page ? `#/${page[1]}` : ''));
  } else {
    try { token = sessionStorage.getItem('dcu-token') || ''; } catch { token = ''; }
  }
  return Boolean(token);
}

export class ApiError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

export async function api(method, path, body) {
  let res;
  try {
    res = await fetch(path, {
      method,
      headers: { 'X-DCU-Token': token, 'Content-Type': 'application/json' },
      body: method === 'POST' ? JSON.stringify(body ?? {}) : undefined,
      cache: 'no-store',
    });
  } catch {
    throw new ApiError('Device CleanUpper is not reachable. Is its console window still open?', 0);
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError(data.error || `${res.status} ${res.statusText}`, res.status);
  return data;
}

// PowerShell's JSON sometimes turns a one-item list into a single value
export const list = (x) => (Array.isArray(x) ? x : x == null ? [] : [x]);
