const VERSION = '0.0.1';
const DEFAULT_SUBAPI = 'https://clawsub.7979.pp.ua';
const DEFAULT_SUBCONFIG = 'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Mini_MultiMode.ini';
const SECURITY_HEADERS = Object.freeze({ 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff' });
const NGINX_WELCOME_HTML = `<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
body {
    width: 35em;
    margin: 0 auto;
    font-family: Tahoma, Verdana, Arial, sans-serif;
}
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>
<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>
<p><em>Thank you for using nginx.</em></p>
</body>
</html>`;

class HttpError extends Error {
  constructor(status, message, headers = {}) {
    super(message);
    this.status = status;
    this.headers = headers;
  }
}

function json(value, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { ...SECURITY_HEADERS, 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...extraHeaders },
  });
}

function plain(value, status = 200, extraHeaders = {}) {
  return new Response(value, {
    status,
    headers: { ...SECURITY_HEADERS, 'Content-Type': 'text/plain; charset=utf-8', ...extraHeaders },
  });
}

function equalToken(left, right) {
  const encoder = new TextEncoder();
  const a = encoder.encode(String(left ?? ''));
  const b = encoder.encode(String(right ?? ''));
  let difference = a.length ^ b.length;
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    difference |= (a[index] ?? 0) ^ (b[index] ?? 0);
  }
  return difference === 0;
}

function encodeBase64(value) {
  const bytes = new TextEncoder().encode(value);
  const parts = [];
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    parts.push(String.fromCharCode(...bytes.subarray(offset, offset + 8192)));
  }
  return btoa(parts.join(''));
}

function decodeBase64(value) {
  let encoded = value.replace(/\s/g, '').replace(/-/g, '+').replace(/_/g, '/');
  if (encoded.length % 4 === 1 || /[^A-Za-z0-9+/=]/.test(encoded)) {
    throw new Error('invalid base64');
  }
  encoded += '='.repeat((4 - encoded.length % 4) % 4);
  const binary = atob(encoded);
  return new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(binary, char => char.charCodeAt(0)));
}

function uniqueLines(values) {
  return [...new Set(values.map(value => value.trim()).filter(Boolean))];
}

function splitVariable(value) {
  return uniqueLines(String(value ?? '').split(/[\r\n,]+/));
}

function parseCfip(value, status = 500) {
  return splitVariable(value).map(label => {
    let host;
    let port = 443;
    const bracketed = label.match(/^\[([0-9a-fA-F:.]+)\](?::([0-9]+))?$/);
    const ordinary = label.match(/^([A-Za-z0-9.-]+)(?::([0-9]+))?$/);
    if (bracketed) {
      host = bracketed[1];
      port = bracketed[2] === undefined ? 443 : Number(bracketed[2]);
    } else if (ordinary) {
      host = ordinary[1];
      port = ordinary[2] === undefined ? 443 : Number(ordinary[2]);
    } else if (/^[0-9a-fA-F:]+$/.test(label) && label.includes(':')) {
      host = label;
    } else {
      throw new HttpError(status, 'CFIP 配置无效');
    }
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new HttpError(status, 'CFIP 端口无效');
    }
    return { host, port, label };
  });
}

function readConfig(env) {
  if (!env.ADMIN_TOKEN || !env.REPORT_TOKEN) {
    throw new HttpError(500, 'ADMIN_TOKEN/REPORT_TOKEN 未配置');
  }
  if (!env.TUNEL_KV) {
    throw new HttpError(500, 'TUNEL_KV 未配置');
  }
  return {
    kv: env.TUNEL_KV,
    adminToken: String(env.ADMIN_TOKEN),
    reportToken: String(env.REPORT_TOKEN),
    subapi: String(env.SUBAPI || DEFAULT_SUBAPI).trim(),
    subconfig: String(env.SUBCONFIG || DEFAULT_SUBCONFIG).trim(),
    subname: String(env.SUBNAME || 'tunel'),
    initialCfip: String(env.CFIP ?? ''),
    initialUpstream: splitVariable(env.UPSTREAM),
  };
}

function bearerToken(request) {
  return request.headers.get('Authorization')?.match(/^Bearer (.+)$/i)?.[1] ?? '';
}

function resolveRoute(request, url, config) {
  const firstSegment = url.pathname.split('/')[1] ?? '';
  let pathCredential = '';
  let path = url.pathname;
  let decodedSegment = '';
  try {
    decodedSegment = decodeURIComponent(firstSegment);
  } catch {
    decodedSegment = '';
  }
  if (!['/ui', '/ui/login', '/ui/logout'].includes(url.pathname) && decodedSegment && equalToken(decodedSegment, config.adminToken)) {
    pathCredential = decodedSegment;
    path = url.pathname.slice(firstSegment.length + 1) || '/sub';
    if (path === '/') {
      path = '/sub';
    }
  }
  const adminCandidates = [bearerToken(request), request.headers.get('X-Admin-Token') ?? '', url.searchParams.get('token') ?? '', pathCredential];
  const reportCandidates = [bearerToken(request), request.headers.get('X-Report-Token') ?? ''];
  return {
    path,
    adminCredential: adminCandidates.find(candidate => candidate && equalToken(candidate, config.adminToken)) ?? '',
    reportAuthorized: reportCandidates.some(candidate => candidate && equalToken(candidate, config.reportToken)),
    pathCredential,
  };
}

function requireMethod(request, methods) {
  if (!methods.includes(request.method)) {
    throw new HttpError(405, '方法不允许', { Allow: methods.join(', ') });
  }
}

async function readJson(request, limit) {
  const length = request.headers.get('Content-Length');
  if (length !== null && Number(length) > limit) {
    throw new HttpError(413, '请求体过大');
  }
  const reader = request.body?.getReader();
  if (!reader) {
    throw new HttpError(400, 'JSON 解析失败');
  }
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel().catch(() => {   });
        throw new HttpError(413, '请求体过大');
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    const payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      throw new Error('not an object');
    }
    return payload;
  } catch {
    throw new HttpError(400, 'JSON 解析失败');
  }
}

const UI_COOKIE_NAME = '__Secure-tunel_ui';
const UI_SESSION_TTL = 604800;

function requireUiOrigin(request, url) {
  if (request.headers.get('Origin') !== url.origin) {
    throw new HttpError(403, '请从本站页面操作');
  }
}

function readUiCookie(request) {
  const name = `${UI_COOKIE_NAME}=`;
  return (request.headers.get('Cookie') ?? '').split(';').map(value => value.trim()).find(value => value.startsWith(name))?.slice(name.length) ?? '';
}

async function uiSessionSignature(config, origin, expires, nonce) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', encoder.encode(config.adminToken), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signed = await crypto.subtle.sign('HMAC', key, encoder.encode(`ui-session:v1:${origin}:${expires}:${nonce}`));
  return Array.from(new Uint8Array(signed), byte => byte.toString(16).padStart(2, '0')).join('');
}

async function issueUiSession(config, origin, now) {
  const expires = now + UI_SESSION_TTL;
  const nonce = crypto.randomUUID().replace(/-/g, '');
  const signature = await uiSessionSignature(config, origin, expires, nonce);
  const value = `1.${expires}.${nonce}.${signature}`;
  return `${UI_COOKIE_NAME}=${value}; Max-Age=${UI_SESSION_TTL}; Expires=${new Date(expires * 1000).toUTCString()}; Path=/ui; HttpOnly; Secure; SameSite=Strict`;
}

function clearUiSession() {
  return `${UI_COOKIE_NAME}=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/ui; HttpOnly; Secure; SameSite=Strict`;
}

async function validUiSession(request, config, origin, now) {
  const value = readUiCookie(request);
  const match = value.match(/^1\.([0-9]{1,12})\.([0-9a-f]{32})\.([0-9a-f]{64})$/);
  if (!match) {
    return false;
  }
  const expires = Number(match[1]);
  if (!Number.isSafeInteger(expires) || expires <= now || expires > now + UI_SESSION_TTL) {
    return false;
  }
  const signature = await uiSessionSignature(config, origin, match[1], match[2]);
  return equalToken(match[3], signature);
}

function uiHtmlResponse(html, nonce) {
  return new Response(html, { headers: {
    ...SECURITY_HEADERS, 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store',
    'Content-Security-Policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; img-src 'none'; font-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`,
  } });
}

function loginPanel() {
  const nonce = crypto.randomUUID().replace(/-/g, '');
  const html = String.raw`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><meta name="referrer" content="no-referrer"><title>管理中心 · 登录</title>
<style nonce="${nonce}">
:root{color-scheme:light dark;--bg:#f3f5f7;--surface:#fff;--ink:#18222e;--muted:#687482;--line:#dde3e8;--accent:#2457d6;--error:#b93838}@media(prefers-color-scheme:dark){:root{--bg:#10151c;--surface:#19212b;--ink:#e5ebf2;--muted:#a1adba;--line:#303c49;--accent:#89a9ff;--error:#ff9898}}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:var(--bg);color:var(--ink);font:15px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}main{width:100%;max-width:390px;padding:30px;border:1px solid var(--line);border-radius:14px;background:var(--surface)}h1{margin:0;font-size:24px}p{margin:6px 0 24px;color:var(--muted)}label{display:block;margin-bottom:8px;font-weight:600}input,button{width:100%;padding:11px 12px;font:inherit;border:1px solid var(--line);border-radius:8px}input{background:var(--bg);color:var(--ink)}button{margin-top:18px;background:var(--accent);color:var(--surface);border-color:var(--accent);cursor:pointer;font-weight:600}input:focus-visible,button:focus-visible{outline:2px solid var(--accent);outline-offset:3px}button:disabled{opacity:.6;cursor:wait}#login-error{margin:12px 0 0;color:var(--error)}#login-error[hidden]{display:none}small{display:block;color:var(--muted);margin-top:18px}
</style></head><body><main><h1>管理中心</h1><p>请输入管理密码继续。</p><form id="login-form"><label for="password">管理密码</label><input id="password" name="password" type="password" autocomplete="current-password" required autofocus><p id="login-error" role="alert" hidden></p><button id="login-submit" type="submit">登录</button></form><small>登录状态保留 7 天。</small></main>
<script nonce="${nonce}">
'use strict';
history.replaceState(null, '', '/ui');
document.getElementById('login-form').addEventListener('submit', async event => {
  event.preventDefault();
  const button = document.getElementById('login-submit');
  const message = document.getElementById('login-error');
  button.disabled = true; button.textContent = '登录中…'; message.hidden = true;
  try {
    const response = await fetch('/ui/login', { method: 'POST', credentials: 'same-origin', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: document.getElementById('password').value }) });
    const data = await response.json();
    if (!response.ok) { throw new Error(data.error || '登录失败，请重试'); }
    location.replace('/ui');
  } catch (error) {
    message.textContent = error.message || '登录失败，请重试'; message.hidden = false;
    document.getElementById('password').focus();
  } finally { button.disabled = false; button.textContent = '登录'; }
});
</script></body></html>`;
  return uiHtmlResponse(html, nonce);
}

function validateId(id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{4,64}$/.test(id)) {
    throw new HttpError(400, 'id 无效');
  }
  return id;
}

const COUNTRY_CODES = new Set('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW'.split(' '));

function normalizeCountry(value) {
  const country = typeof value === 'string' ? value.trim().toUpperCase() : '';
  return COUNTRY_CODES.has(country) ? country : '';
}

function normalizeRegion(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,16}$/.test(value) ? value.toUpperCase() : '';
}

function countryLabel(country) {
  if (!country) {
    return '';
  }
  try {
    return new Intl.DisplayNames(['zh-CN'], { type: 'region', fallback: 'none' }).of(country) || country;
  } catch {
    return country;
  }
}

function requestLocation(request, reported = {}) {
  const cf = request.cf && typeof request.cf === 'object' ? request.cf : null;
  const cfCountry = normalizeCountry(cf?.country);
  const reportedCountry = normalizeCountry(reported.country);
  const country = reportedCountry || cfCountry;
  const reportedRegion = reportedCountry ? normalizeRegion(reported.region) : '';
  const reportedRegionName = reportedCountry && typeof reported.regionName === 'string' ? reported.regionName.trim() : '';
  const cfRegion = country && cfCountry === country ? normalizeRegion(cf?.regionCode) : '';
  const cfRegionName = country && cfCountry === country && typeof cf?.region === 'string' ? Array.from(cf.region.trim().replace(/[\u0000-\u001f\u007f-\u009f]/g, '')).slice(0, 128).join('') : '';
  const region = reportedRegion || (reportedRegionName ? '' : cfRegion);
  const regionName = reportedRegionName || (!reportedRegion || reportedRegion === cfRegion ? cfRegionName : '');
  return { country, region, countryName: countryLabel(country), regionName };
}

function verifiedLocation(value) {
  const country = normalizeCountry(value.country);
  const region = country ? normalizeRegion(value.region) : '';
  const regionName = country && typeof value.regionName === 'string' && Array.from(value.regionName).length <= 128 && !/[\u0000-\u001f\u007f-\u009f]/.test(value.regionName) ? value.regionName.trim() : '';
  return { country, region, countryName: countryLabel(country), regionName };
}

function locationName(location) {
  return [location.countryName || countryLabel(normalizeCountry(location.country)), location.regionName || location.region].filter(Boolean).join(' · ') || '未识别地区';
}

function renameVmessLink(link, name) {
  try {
    const node = JSON.parse(decodeBase64(link.slice('vmess://'.length)));
    if (!node || typeof node !== 'object' || Array.isArray(node)) {
      throw new Error('invalid vmess object');
    }
    return `vmess://${encodeBase64(JSON.stringify({ ...node, ps: name }))}`;
  } catch {
    return link;
  }
}

function quickHostValid(host) {
  return typeof host === 'string' && /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.trycloudflare\.com$/i.test(host) && !/^(?:api|www)\.trycloudflare\.com$/i.test(host);
}

function validateReport(payload) {
  validateId(payload.id);
  const checks = [
    ['name', typeof payload.name === 'string' && Array.from(payload.name).length <= 64],
    ['mode', payload.mode === 'quick' || payload.mode === 'fixed'],
    ['host', typeof payload.host === 'string' && /^[A-Za-z0-9.-]{1,253}$/.test(payload.host) && (payload.mode !== 'quick' || quickHostValid(payload.host))],
    ['path', typeof payload.path === 'string' && payload.path.startsWith('/') && payload.path.length <= 128],
    ['uuid', typeof payload.uuid === 'string' && /^[0-9a-fA-F-]{36}$/.test(payload.uuid)],
    ['link', typeof payload.link === 'string' && payload.link.startsWith('vmess://') && payload.link.length <= 2048],
    ['country', payload.country === undefined || payload.country === '' || typeof payload.country === 'string' && /^[A-Za-z]{2}$/.test(payload.country)],
    ['region', payload.region === undefined || payload.region === '' || typeof payload.region === 'string' && /^[A-Za-z0-9_-]{1,16}$/.test(payload.region)],
    ['regionName', payload.regionName === undefined || typeof payload.regionName === 'string' && Array.from(payload.regionName).length <= 128 && !/[\u0000-\u001f\u007f-\u009f]/.test(payload.regionName)],
    ['locationVerified', payload.locationVerified === undefined || typeof payload.locationVerified === 'boolean'],
  ];
  for (const [field, valid] of checks) {
    if (!valid) {
      throw new HttpError(400, `${field} 无效`);
    }
  }
  if (payload.locationVerified === true && !normalizeCountry(payload.country)) {
    throw new HttpError(400, 'country 无效');
  }
  const port = payload.port === undefined ? 443 : payload.port;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new HttpError(400, 'port 无效');
  }
  const addr = payload.addr ?? payload.host;
  if (typeof addr !== 'string' || !addr || addr.length > 253) {
    throw new HttpError(400, 'addr 无效');
  }
  return { ...payload, port, addr };
}

async function reportNode(request, config, now, cache, origin) {
  const payload = validateReport(await readJson(request, 8192));
  const key = `node:${payload.id}`;
  const old = await config.kv.get(key, 'json');
  let location;
  let locationVerified = payload.locationVerified;
  if (locationVerified === true) {
    location = verifiedLocation(payload);
  } else if (locationVerified === false) {
    locationVerified = old?.locationVerified === true;
    location = verifiedLocation(locationVerified ? old : {});
  } else {
    location = requestLocation(request, payload);
  }
  const baseName = payload.name;
  const displayName = locationName(location);
  const next = { ...payload, ...location, locationVerified, baseName, name: baseName, displayName, link: renameVmessLink(payload.link, displayName) };
  if (old && ['host', 'path', 'uuid', 'link', 'addr', 'name', 'baseName', 'displayName', 'mode', 'port', 'country', 'region', 'countryName', 'regionName', 'locationVerified'].every(field => old[field] === next[field])) {
    return json({ ok: true, id: payload.id, skipped: true });
  }
  await config.kv.put(key, JSON.stringify({ ...next, firstSeen: old?.firstSeen ?? now, lastReport: now }));
  await purgeCache(cache, origin, config);
  return json({ ok: true, id: payload.id });
}

async function listNodeKeys(kv) {
  const keys = [];
  let cursor;
  const cursors = new Set();
  while (true) {
    const page = await kv.list({ prefix: 'node:', ...(cursor ? { cursor } : {}) });
    keys.push(...page.keys.map(key => key.name));
    if (page.list_complete) {
      break;
    }
    if (!page.cursor || cursors.has(page.cursor)) {
      throw new HttpError(500, 'KV 分页异常');
    }
    cursors.add(page.cursor);
    cursor = page.cursor;
  }
  return keys;
}

async function readNodes(kv) {
  const keys = await listNodeKeys(kv);
  const nodes = new Array(keys.length);
  let index = 0;
  async function readNext() {
    while (index < keys.length) {
      const current = index;
      index += 1;
      nodes[current] = await kv.get(keys[current], 'json');
    }
  }
  await Promise.all(Array.from({ length: Math.min(6, keys.length) }, () => readNext()));
  return nodes.filter(node => node && typeof node === 'object').map(node => {
    const record = { country: '', region: '', countryName: '', regionName: '', baseName: node.name ?? '', ...node };
    const name = typeof record.baseName === 'string' ? record.baseName || record.id : record.name || record.id;
    const displayName = locationName(record);
    return { ...record, name, displayName, link: renameVmessLink(record.link, displayName) };
  });
}

async function readSources(config) {
  const stored = await config.kv.get('sources', 'json');
  const links = Array.isArray(stored?.links) ? uniqueLines(stored.links.filter(value => typeof value === 'string')) : [];
  const savedUpstream = Array.isArray(stored?.upstream) ? uniqueLines(stored.upstream.filter(value => typeof value === 'string')) : [];
  const upstream = savedUpstream.length ? savedUpstream : config.initialUpstream;
  return { links, upstream, updatedAt: stored?.updatedAt ?? 0 };
}

function sourceValues(value, field) {
  if (value === undefined) {
    return [];
  }
  const lines = typeof value === 'string' ? value.split(/\r?\n/) : value;
  if (!Array.isArray(lines) || lines.some(line => typeof line !== 'string')) {
    throw new HttpError(400, `${field} 无效`);
  }
  const values = uniqueLines(lines.flatMap(line => line.split(/\r?\n/)));
  if (values.some(line => field === 'upstream' ? !/^https?:\/\//i.test(line) : !line.includes('://'))) {
    throw new HttpError(400, `${field} 无效`);
  }
  return values;
}

async function saveSources(request, config, now, cache, origin) {
  const payload = await readJson(request, 65536);
  const links = sourceValues(payload.links, 'links');
  const upstream = sourceValues(payload.upstream, 'upstream');
  const next = { links, upstream, updatedAt: now };
  if (new TextEncoder().encode(JSON.stringify(next)).byteLength > 65536) {
    throw new HttpError(413, '数据源超过 64KB');
  }
  const old = await config.kv.get('sources', 'json');
  const changed = !old || JSON.stringify(old.links ?? []) !== JSON.stringify(links) || JSON.stringify(old.upstream ?? []) !== JSON.stringify(upstream);
  if (changed) {
    await config.kv.put('sources', JSON.stringify(next));
    await purgeCache(cache, origin, config);
  }
  return json({ links, upstream: upstream.length ? upstream : config.initialUpstream, updatedAt: changed ? now : old.updatedAt ?? 0 });
}

async function readSettings(config) {
  const raw = await config.kv.get('settings');
  let stored;
  if (raw !== null && raw !== undefined) {
    if (typeof raw !== 'string' || new TextEncoder().encode(raw).byteLength > 8192) {
      return { cfip: '', source: 'settings', updatedAt: 0, valid: false, validationError: 'CFIP 设置数据超过 8KB 或格式无效，请重新保存' };
    }
    try {
      stored = JSON.parse(raw);
    } catch {
      return { cfip: '', source: 'settings', updatedAt: 0, valid: false, validationError: 'CFIP 设置数据无效，请重新保存' };
    }
    if (!stored || typeof stored.cfip !== 'string') {
      return { cfip: '', source: 'settings', updatedAt: 0, valid: false, validationError: 'CFIP 设置数据无效，请重新保存' };
    }
  }
  const cfip = splitVariable(stored ? stored.cfip : config.initialCfip).join('\n');
  const settings = { cfip, source: stored ? 'settings' : 'env', updatedAt: stored?.updatedAt ?? 0, valid: true };
  try {
    if (new TextEncoder().encode(cfip).byteLength > 8192) {
      throw new HttpError(500, 'CFIP 配置超过 8KB');
    }
    parseCfip(cfip);
  } catch (error) {
    return { ...settings, valid: false, validationError: error instanceof HttpError ? error.message : 'CFIP 配置无效' };
  }
  return settings;
}

async function saveSettings(request, config, now) {
  const payload = await readJson(request, 8192);
  if (typeof payload.cfip !== 'string') {
    throw new HttpError(400, 'cfip 必须是字符串');
  }
  const cfip = parseCfip(payload.cfip, 400).map(address => address.label).join('\n');
  const next = { cfip, updatedAt: now };
  if (new TextEncoder().encode(JSON.stringify(next)).byteLength > 8192) {
    throw new HttpError(413, 'CFIP 配置超过 8KB');
  }
  const raw = await config.kv.get('settings');
  let old;
  if (typeof raw === 'string' && new TextEncoder().encode(raw).byteLength <= 8192) {
    try {
      old = JSON.parse(raw);
    } catch {
    }
  }
  if (old && old.cfip === cfip) {
    return json({ cfip, source: 'settings', updatedAt: old.updatedAt ?? 0, valid: true, skipped: true });
  }
  await config.kv.put('settings', JSON.stringify(next));
  return json({ cfip, source: 'settings', updatedAt: now, valid: true });
}

async function effectiveConfig(config) {
  const settings = await readSettings(config);
  if (!settings.valid) {
    throw new HttpError(500, settings.validationError);
  }
  const cfip = parseCfip(settings.cfip);
  const bytes = new TextEncoder().encode(JSON.stringify(cfip.map(address => [address.host, address.port])));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const cfipCacheTag = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
  return { ...config, cfip, cfipCacheTag };
}

function utcDate(timestamp) {
  return new Date(timestamp).toISOString().slice(0, 10).replace(/-/g, '');
}

async function deriveRawToken(reportToken, date) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', encoder.encode(reportToken), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(`raw:${date}`));
  return Array.from(new Uint8Array(signature), byte => byte.toString(16).padStart(2, '0')).join('').slice(0, 16);
}

async function authorizeRaw(token, config, timestamp) {
  const today = await deriveRawToken(config.reportToken, utcDate(timestamp));
  const yesterday = await deriveRawToken(config.reportToken, utcDate(timestamp - 86400000));
  const currentMatch = equalToken(token, today);
  const previousMatch = equalToken(token, yesterday);
  return currentMatch || previousMatch;
}

function expandLinks(links, cfip) {
  if (!cfip.length) {
    return uniqueLines(links);
  }
  const expanded = [];
  for (const link of links) {
    if (!link.startsWith('vmess://')) {
      expanded.push(link);
      continue;
    }
    try {
      const node = JSON.parse(decodeBase64(link.slice('vmess://'.length)));
      if (!node || typeof node !== 'object' || Array.isArray(node)) {
        throw new Error('invalid vmess object');
      }
      for (const address of cfip) {
        expanded.push(`vmess://${encodeBase64(JSON.stringify({ ...node, add: address.host, port: address.port }))}`);
      }
    } catch {
      expanded.push(link);
    }
  }
  return uniqueLines(expanded);
}

async function cachedResponse(cache, key) {
  if (!cache) {
    return undefined;
  }
  try {
    return await cache.match(new Request(key));
  } catch {
    return undefined;
  }
}

async function storeResponse(cache, key, body, headers = {}) {
  if (!cache) {
    return;
  }
  try {
    await cache.put(new Request(key), plain(body, 200, { 'Cache-Control': 'public, max-age=60', ...headers }));
  } catch {
  }
}

async function purgeCache(cache, origin, config) {
  if (!cache) {
    return;
  }
  try {
    const { cfipCacheTag } = await effectiveConfig(config);
    const keys = [`${origin}/raw?cfip=${cfipCacheTag}`, ...['base64', 'clash', 'singbox', 'surge', 'quanx', 'loon'].map(format => `${origin}/sub?fmt=${format}&cfip=${cfipCacheTag}`)];
    await Promise.allSettled(keys.map(key => cache.delete(new Request(key))));
  } catch {
  }
}

async function rawContent(config, origin, cache) {
  const key = `${origin}/raw?cfip=${config.cfipCacheTag}`;
  const cached = await cachedResponse(cache, key);
  if (cached) {
    return await cached.text();
  }
  const nodes = await readNodes(config.kv);
  const sources = await readSources(config);
  const links = uniqueLines([...nodes.map(node => node.link).filter(link => typeof link === 'string'), ...sources.links]);
  const content = encodeBase64(expandLinks(links, config.cfip).join('\n'));
  await storeResponse(cache, key, content);
  return content;
}

function subscriptionFormat(request, url) {
  const params = url.searchParams;
  const formats = [['base64', ['b64', 'base64']], ['clash', ['clash']], ['singbox', ['sb', 'singbox']], ['surge', ['surge']], ['quanx', ['quanx']], ['loon', ['loon']]];
  for (const [format, flags] of formats) {
    if (flags.some(flag => params.has(flag))) {
      return format;
    }
  }
  const ua = (request.headers.get('User-Agent') ?? '').toLowerCase();
  const matches = [['clash', /clash|mihomo|meta/], ['singbox', /sing-box|singbox/], ['surge', /surge/], ['quanx', /quantumult/], ['loon', /loon/]];
  for (const [format, match] of matches) {
    if (match.test(ua)) {
      return format;
    }
  }
  if (ua.includes('subconverter') || request.headers.has('SubConverter-Request')) {
    return 'base64';
  }
  return 'base64';
}

function conversionUrl(config, format, sources) {
  const backend = new URL(config.subapi);
  if (!/^https?:$/.test(backend.protocol)) {
    throw new Error('invalid SUBAPI');
  }
  backend.pathname = `${backend.pathname.replace(/\/+$/, '')}${backend.pathname.replace(/\/+$/, '').endsWith('/sub') ? '' : '/sub'}`;
  backend.search = '';
  backend.hash = '';
  const params = new URLSearchParams({
    target: format === 'base64' ? 'mixed' : format,
    url: sources.join('|'),
    insert: 'false', config: config.subconfig, emoji: 'false', append_type: 'false', list: 'false', tfo: 'false',
    scv: 'true', fdn: 'false', sort: 'false', new_name: 'true',
  });
  if (format === 'surge') {
    params.set('ver', '4');
  }
  if (format === 'quanx') {
    params.set('udp', 'true');
  }
  backend.search = params.toString();
  return backend;
}

function subscriptionHeaders(request, config, fallback) {
  const headers = { 'Profile-Update-Interval': '6', 'Cache-Control': 'private, max-age=60' };
  if (!(request.headers.get('User-Agent') ?? '').toLowerCase().includes('mozilla')) {
    const filename = encodeURIComponent(config.subname).replace(/[!'()*]/g, char => `%${char.charCodeAt(0).toString(16).toUpperCase()}`);
    headers['Content-Disposition'] = `attachment; filename*=utf-8''${filename}`;
  }
  if (fallback) {
    headers['X-Tunel-Fallback'] = 'subconverter-failed';
  }
  return headers;
}

async function subscription(request, url, config, timestamp, cache) {
  const format = subscriptionFormat(request, url);
  const key = `${url.origin}/sub?fmt=${format}&cfip=${config.cfipCacheTag}`;
  const cached = await cachedResponse(cache, key);
  if (cached) {
    return plain(await cached.text(), 200, subscriptionHeaders(request, config, cached.headers.has('X-Tunel-Fallback')));
  }
  const local = await rawContent(config, url.origin, cache);
  const sources = await readSources(config);
  let output = local;
  let fallback = false;
  if (format !== 'base64' || sources.upstream.length) {
    try {
      const token = await deriveRawToken(config.reportToken, utcDate(timestamp));
      const rawUrl = `${url.origin}/raw?t=${token}`;
      const backend = conversionUrl(config, format, [rawUrl, ...sources.upstream]);
      const response = await fetch(backend, { headers: { 'User-Agent': request.headers.get('User-Agent') || 'tunel' }, signal: AbortSignal.timeout(12000) });
      if (!response.ok) {
        await response.body?.cancel();
        throw new Error('subconverter response failed');
      }
      const converted = await response.text();
      if (format === 'base64') {
        output = encodeBase64(uniqueLines([...decodeBase64(converted).split(/\r?\n/), ...decodeBase64(local).split(/\r?\n/)]).join('\n'));
      } else {
        output = converted;
      }
    } catch {
      output = local;
      fallback = true;
    }
  }
  await storeResponse(cache, key, output, fallback ? { 'X-Tunel-Fallback': 'subconverter-failed' } : {});
  return plain(output, 200, subscriptionHeaders(request, config, fallback));
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
}

function scriptJson(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
}

function panel(config, credential, pathCredential) {
  const nonce = crypto.randomUUID().replace(/-/g, '');
  const html = String.raw`<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><meta name="referrer" content="no-referrer">
<title>管理中心</title>
<style nonce="${nonce}">
:root{color-scheme:light dark;--bg:#f3f5f7;--surface:#fff;--ink:#18222e;--muted:#687482;--line:#dde3e8;--accent:#2457d6;--danger:#b93838;--soft:#e9efff;--shadow:0 5px 24px #19283b08}
@media(prefers-color-scheme:dark){:root{--bg:#10151c;--surface:#19212b;--ink:#e5ebf2;--muted:#a1adba;--line:#303c49;--accent:#89a9ff;--danger:#ff9898;--soft:#263653;--shadow:none}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}main{max-width:1180px;margin:auto;padding:30px 24px 70px}header{display:flex;gap:16px;align-items:center;justify-content:space-between;margin-bottom:26px}h1{font-size:23px;line-height:1.4;margin:0;letter-spacing:-.5px}.version{font-size:12px;color:var(--muted);margin-top:5px}button{font:inherit;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--ink);padding:8px 14px;cursor:pointer;white-space:nowrap}button:hover{border-color:var(--accent)}button:focus-visible,input:focus-visible,textarea:focus-visible{outline:2px solid var(--accent);outline-offset:3px}button:disabled{opacity:.5;cursor:wait}.primary{background:var(--accent);border-color:var(--accent);color:var(--surface)}.danger{color:var(--danger)}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:26px}.card,.content{background:var(--surface);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow)}.card{padding:20px}.card span{display:block;color:var(--muted);font-size:13px}.card strong{display:block;font-size:30px;font-weight:650;margin-top:6px}.card strong.backend{font-size:17px;overflow-wrap:anywhere;padding-top:9px}nav{display:flex;gap:6px;overflow-x:auto;margin-bottom:14px}nav button{border-color:transparent;background:transparent}nav button[aria-selected=true]{background:var(--soft);color:var(--accent);font-weight:600}.content{padding:22px}.panel[hidden]{display:none}h2{font-size:18px;margin:0 0 14px}p{margin:10px 0;color:var(--muted)}.table-wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;text-align:left}th,td{padding:12px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{font-size:12px;font-weight:600;color:var(--muted);white-space:nowrap}td{font-size:14px;overflow-wrap:anywhere}.actions{display:flex;gap:7px;flex-wrap:wrap}.actions button{font-size:12px;padding:5px 10px}.empty{padding:35px 16px;text-align:center;color:var(--muted)}label{display:block;font-weight:600;margin:18px 0 8px}textarea,input{font:13px/1.7 ui-monospace,SFMono-Regular,Consolas,monospace;background:var(--bg);color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:11px;width:100%;resize:vertical}textarea{min-height:150px}small{display:block;color:var(--muted);margin-top:5px}.subscription-row{display:grid;grid-template-columns:125px minmax(0,1fr) auto;gap:12px;align-items:center;padding:12px 0;border-bottom:1px solid var(--line)}.subscription-row:last-child{border-bottom:0}.setting{display:grid;grid-template-columns:120px minmax(0,1fr);gap:15px;padding:11px 0;border-bottom:1px solid var(--line)}.setting dt{font-weight:600}.setting dd{margin:0;overflow-wrap:anywhere;white-space:pre-wrap;color:var(--muted)}#install-command{min-height:118px}#notice{position:fixed;right:24px;bottom:24px;max-width:min(440px,calc(100% - 48px));padding:12px 18px;border-radius:10px;border:1px solid var(--line);background:var(--surface);box-shadow:0 8px 28px #0002}#notice[hidden]{display:none}#notice.error{color:var(--danger)}.footer-actions{display:flex;gap:12px;align-items:center;margin-top:14px}.muted{color:var(--muted)}@media(max-width:760px){main{padding:20px 14px 60px}h1{font-size:19px}.cards{gap:8px}.card{padding:13px}.card strong{font-size:25px}.card strong.backend{font-size:13px}.content{padding:14px}.subscription-row{grid-template-columns:1fr auto;gap:8px}.subscription-row label{grid-column:1/-1;margin:0}.setting{grid-template-columns:1fr;gap:3px}.table-wrap{margin:0 -5px}.cards span{font-size:11px}}
</style>
</head>
<body><main>
<header><div><h1>管理中心</h1><div class="version">版本 ${escapeHtml(VERSION)}</div></div><div class="actions"><button id="refresh">刷新</button><button id="logout">退出</button></div></header>
<section class="cards" aria-label="概览"><div class="card"><span>记录总数</span><strong id="node-count">—</strong></div><div class="card"><span>数据源</span><strong id="source-count">—</strong></div><div class="card"><span>处理服务</span><strong class="backend" id="backend">—</strong></div></section>
<nav role="tablist" aria-label="管理页"><button role="tab" id="tab-nodes" aria-controls="nodes" aria-selected="true" data-tab="nodes">记录</button><button role="tab" id="tab-sources" aria-controls="sources" aria-selected="false" data-tab="sources">数据源</button><button role="tab" id="tab-subscriptions" aria-controls="subscriptions" aria-selected="false" data-tab="subscriptions">访问链接</button><button role="tab" id="tab-settings" aria-controls="settings" aria-selected="false" data-tab="settings">设置</button></nav>
<div class="content">
<section id="nodes" class="panel" role="tabpanel" aria-labelledby="tab-nodes"><h2>记录列表</h2><div id="node-table" class="table-wrap"><p class="empty">正在读取记录…</p></div></section>
<section id="sources" class="panel" role="tabpanel" aria-labelledby="tab-sources" hidden><h2>数据源</h2><label for="links">手工链接</label><textarea id="links" spellcheck="false" placeholder="一行一个链接"></textarea><small>支持包含 :// 的链接，保存时自动去除空行与重复项。</small><label for="upstream">远程数据 URL</label><textarea id="upstream" spellcheck="false" placeholder="一行一个 https:// 或 http:// URL"></textarea><div class="footer-actions"><button id="save-sources" class="primary">保存</button></div></section>
<section id="subscriptions" class="panel" role="tabpanel" aria-labelledby="tab-subscriptions" hidden><h2>访问链接</h2><p>这些地址包含访问凭据，请妥善保管。</p><div id="subscription-list"></div></section>
<section id="settings" class="panel" role="tabpanel" aria-labelledby="tab-settings" hidden><h2>设置</h2><dl><div class="setting"><dt>处理服务</dt><dd id="subapi"></dd></div><div class="setting"><dt>配置地址</dt><dd id="subconfig"></dd></div><div class="setting"><dt>接收地址</dt><dd id="report-endpoint"></dd></div></dl><label for="cfip">CFIP 连接地址</label><textarea id="cfip" spellcheck="false" placeholder="一行一个 IP:端口或域名，例如 162.159.1.1:443 或 cf.example.com"></textarea><small>支持换行或逗号分隔，端口省略时为 443；IPv6 指定端口请使用 [IPv6]:端口。保存空内容会关闭自定义地址，使用原始地址。</small><small id="cfip-source"></small><p id="cfip-error" class="danger" hidden></p><div class="footer-actions"><button id="save-cfip" class="primary" disabled>保存 CFIP</button></div><label for="report-token">REPORT_TOKEN</label><input id="report-token" type="text" readonly autocomplete="off" spellcheck="false"><div class="footer-actions"><button id="copy-report-token">复制凭据</button></div><p>此凭据用于服务器同步，请妥善保管。</p><label for="install-command">一键安装并启动服务</label><textarea id="install-command" readonly spellcheck="false"></textarea><div class="footer-actions"><button id="copy-install">复制命令</button></div><p>安装命令已包含同步凭据，复制后可在服务器执行。</p>
<label for="uninstall-system-command">系统目录卸载</label><input id="uninstall-system-command" type="text" readonly autocomplete="off" spellcheck="false" value="/usr/local/bin/tunel uninstall -y"><div class="footer-actions"><button id="copy-uninstall-system">复制卸载命令</button></div>
<label for="uninstall-user-command">用户目录卸载</label><input id="uninstall-user-command" type="text" readonly autocomplete="off" spellcheck="false" value="&quot;$HOME/.local/share/tunel/bin/tunel&quot; uninstall -y"><div class="footer-actions"><button id="copy-uninstall-user">复制卸载命令</button></div><small>按安装时输出的目录选择，并使用安装时的账户执行。自定义目录请调用其 bin/tunel。卸载会读取本机配置注销记录并清理服务。</small>
<p>记录在服务器同步变化时更新；服务器停止运行后不会自动移除记录，需在「记录」页手动删除或在服务器执行卸载命令。</p></section>
</div></main><div id="notice" role="status" aria-live="polite" hidden></div>
<script nonce="${nonce}">
'use strict';
const bootstrap = ${scriptJson({ credential, pathCredential, reportToken: config.reportToken })};
const locationUrl = new URL(location.href);
const adminToken = bootstrap.credential;
locationUrl.searchParams.delete('token');
if (bootstrap.pathCredential) { locationUrl.pathname = '/ui'; }
history.replaceState(null, '', locationUrl.pathname + locationUrl.search + locationUrl.hash);
let noticeTimer;
function notify(message, error = false) {
  const notice = document.getElementById('notice');
  notice.textContent = message;
  notice.classList.toggle('error', error);
  notice.hidden = false;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => { notice.hidden = true; }, 4200);
}
async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { 'X-Admin-Token': adminToken, ...(options.body ? { 'Content-Type': 'application/json' } : {}), ...(options.headers || {}) }, cache: 'no-store' });
  if (response.status === 401) { location.replace('/ui'); throw new Error('登录已失效，请重新登录'); }
  const data = await response.json();
  if (!response.ok) { throw new Error(data.error || '请求失败'); }
  return data;
}
async function copy(value, button) {
  try {
    try { await navigator.clipboard.writeText(value); }
    catch {
      const textarea = document.createElement('textarea');
      textarea.value = value;
      textarea.setAttribute('aria-hidden', 'true');
      textarea.style.position = 'fixed';
      textarea.style.opacity = '0';
      document.body.appendChild(textarea);
      textarea.select();
      const copied = document.execCommand('copy');
      textarea.remove();
      if (!copied) { throw new Error('复制失败，请选中内容手动复制'); }
    }
    const previous = button.textContent;
    button.textContent = '已复制';
    setTimeout(() => { button.textContent = previous; }, 1500);
  } catch (error) { notify(error.message, true); }
}
function relativeTime(timestamp, now) {
  const seconds = Math.max(0, now - Number(timestamp || 0));
  if (seconds < 60) { return '刚刚'; }
  if (seconds < 3600) { return Math.floor(seconds / 60) + ' 分钟前'; }
  if (seconds < 86400) { return Math.floor(seconds / 3600) + ' 小时前'; }
  return Math.floor(seconds / 86400) + ' 天前';
}
function cell(row, value) {
  const td = document.createElement('td');
  td.textContent = value;
  row.appendChild(td);
  return td;
}
function renderNodes(data) {
  const container = document.getElementById('node-table');
  container.replaceChildren();
  if (!data.nodes.length) {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = '暂无记录。到「设置」页复制一键安装命令到服务器执行。';
    container.appendChild(empty);
    return;
  }
  const table = document.createElement('table');
  const head = document.createElement('thead');
  const header = document.createElement('tr');
  for (const label of ['机器名称', '国家/地区', '模式', '主机', '连接地址', '最后上报', '操作']) {
    const th = document.createElement('th'); th.textContent = label; header.appendChild(th);
  }
  head.appendChild(header); table.appendChild(head);
  const body = document.createElement('tbody');
  for (const node of data.nodes) {
    const row = document.createElement('tr');
    cell(row, node.name || node.id);
    cell(row, [node.countryName || node.country, node.regionName || node.region].filter(Boolean).join(' · ') || '未识别');
    cell(row, node.mode === 'quick' ? '临时' : '固定');
    cell(row, node.host); cell(row, node.addr || node.host);
    const time = cell(row, relativeTime(node.lastReport, data.now));
    time.title = new Date(Number(node.lastReport) * 1000).toLocaleString();
    const actions = cell(row, ''); actions.className = 'actions';
    const copyButton = document.createElement('button'); copyButton.textContent = '复制链接';
    copyButton.addEventListener('click', () => copy(node.link, copyButton));
    const deleteButton = document.createElement('button'); deleteButton.textContent = '删除'; deleteButton.className = 'danger';
    deleteButton.addEventListener('click', async () => {
      if (!confirm('确认删除记录「' + (node.name || node.id) + '」？')) { return; }
      deleteButton.disabled = true;
      try { await api('/api/node?id=' + encodeURIComponent(node.id), { method: 'DELETE' }); notify('记录已删除，订阅同步可能稍有延迟'); await refresh(); }
      catch (error) { notify(error.message, true); }
      finally { deleteButton.disabled = false; }
    });
    actions.append(copyButton, deleteButton); body.appendChild(row);
  }
  table.appendChild(body); container.appendChild(table);
}
function renderSubscriptions() {
  const container = document.getElementById('subscription-list');
  const formats = [['通用格式', ''], ['Clash', 'clash'], ['sing-box', 'sb'], ['Surge', 'surge'], ['Quantumult X', 'quanx'], ['Loon', 'loon']];
  for (const [label, flag] of formats) {
    const row = document.createElement('div'); row.className = 'subscription-row';
    const caption = document.createElement('label'); caption.textContent = label;
    const input = document.createElement('input'); input.readOnly = true;
    input.value = location.origin + '/sub?token=' + encodeURIComponent(adminToken) + (flag ? '&' + flag : '');
    input.id = 'sub-' + (flag || 'base64'); caption.htmlFor = input.id;
    const button = document.createElement('button'); button.textContent = '复制';
    button.addEventListener('click', () => copy(input.value, button)); row.append(caption, input, button); container.appendChild(row);
  }
}
function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\"'\"'") + "'";
}
function renderInstallCommand() {
  const endpoint = location.origin + '/api/report';
  document.getElementById('report-endpoint').textContent = endpoint;
  document.getElementById('report-token').value = bootstrap.reportToken;
  document.getElementById('install-command').value = 'curl -fsSL https://raw.githubusercontent.com/bitscr/tunel/main/tunel.sh \\\n  | bash -s -- quick --report-url ' + shellQuote(endpoint) + ' --report-token ' + shellQuote(bootstrap.reportToken) + ' -y';
}
function renderSettings(status) {
  for (const name of ['subapi', 'subconfig']) { document.getElementById(name).textContent = status[name]; }
}
function renderCfipSettings(settings) {
  document.getElementById('cfip').value = settings.cfip;
  document.getElementById('cfip-source').textContent = settings.source === 'env' ? '当前使用 Worker 的 CFIP 变量；保存后由面板配置覆盖。' : settings.cfip ? '当前使用面板保存的连接地址。' : '自定义地址已关闭，使用原始地址。';
  const error = document.getElementById('cfip-error');
  error.textContent = settings.validationError || '';
  error.hidden = !settings.validationError;
  document.getElementById('save-cfip').disabled = false;
}
async function refresh() {
  const button = document.getElementById('refresh'); button.disabled = true;
  try {
    const settingsRequest = api('/api/settings').then(settings => {
      renderCfipSettings(settings);
      return settings;
    }, failure => {
      const error = document.getElementById('cfip-error'); error.textContent = failure.message; error.hidden = false;
      document.getElementById('save-cfip').disabled = false;
      throw failure;
    });
    const results = await Promise.allSettled([settingsRequest, api('/api/nodes'), api('/api/sources'), api('/api/status?counts=0')]);
    const [, nodes, sources, status] = results;
    if (nodes.status === 'fulfilled') {
      renderNodes(nodes.value);
      document.getElementById('node-count').textContent = nodes.value.nodes.length;
    }
    if (sources.status === 'fulfilled') {
      document.getElementById('links').value = sources.value.links.join('\n');
      document.getElementById('upstream').value = sources.value.upstream.join('\n');
      document.getElementById('source-count').textContent = sources.value.links.length + sources.value.upstream.length;
    }
    if (status.status === 'fulfilled') {
      try { document.getElementById('backend').textContent = new URL(status.value.subapi).host; }
      catch { document.getElementById('backend').textContent = status.value.subapi; }
      renderSettings(status.value);
    }
    const failure = results.find(result => result.status === 'rejected');
    if (failure) { notify(failure.reason.message, true); }
  } catch (error) { notify(error.message, true); }
  finally { button.disabled = false; }
}
for (const button of document.querySelectorAll('[data-tab]')) {
  button.addEventListener('click', () => {
    for (const tab of document.querySelectorAll('[data-tab]')) { tab.setAttribute('aria-selected', String(tab === button)); }
    for (const pane of document.querySelectorAll('.panel')) { pane.hidden = pane.id !== button.dataset.tab; }
  });
}
document.getElementById('refresh').addEventListener('click', refresh);
document.getElementById('logout').addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try {
    const response = await fetch('/ui/logout', { method: 'POST', credentials: 'same-origin', cache: 'no-store' });
    const data = await response.json();
    if (!response.ok) { throw new Error(data.error || '退出失败，请重试'); }
    location.replace('/ui');
  } catch (error) { notify(error.message, true); }
  finally { button.disabled = false; }
});
document.getElementById('copy-install').addEventListener('click', event => copy(document.getElementById('install-command').value, event.currentTarget));
document.getElementById('copy-uninstall-system').addEventListener('click', event => copy(document.getElementById('uninstall-system-command').value, event.currentTarget));
document.getElementById('copy-uninstall-user').addEventListener('click', event => copy(document.getElementById('uninstall-user-command').value, event.currentTarget));
document.getElementById('copy-report-token').addEventListener('click', event => copy(document.getElementById('report-token').value, event.currentTarget));
document.getElementById('save-cfip').addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try {
    const settings = await api('/api/settings', { method: 'PUT', body: JSON.stringify({ cfip: document.getElementById('cfip').value }) });
    renderCfipSettings(settings);
    notify('CFIP 已保存，后续输出将使用新配置；KV 跨区同步可能需要约 60 秒。');
  } catch (error) {
    const message = document.getElementById('cfip-error'); message.textContent = error.message; message.hidden = false;
    notify(error.message, true);
  } finally { button.disabled = false; }
});
document.getElementById('save-sources').addEventListener('click', async event => {
  const button = event.currentTarget; button.disabled = true;
  try {
    const sources = await api('/api/sources', { method: 'PUT', body: JSON.stringify({ links: document.getElementById('links').value.split(/\r?\n/), upstream: document.getElementById('upstream').value.split(/\r?\n/) }) });
    document.getElementById('links').value = sources.links.join('\n'); document.getElementById('upstream').value = sources.upstream.join('\n');
    document.getElementById('source-count').textContent = sources.links.length + sources.upstream.length;
    notify('已保存，订阅同步可能稍有延迟');
  } catch (error) { notify(error.message, true); }
  finally { button.disabled = false; }
});
renderInstallCommand(); renderSubscriptions(); refresh();
</script></body></html>`;
  return uiHtmlResponse(html, nonce);
}

async function handleRequest(request, env) {
  const url = new URL(request.url);
  if (url.pathname === '/') {
    requireMethod(request, ['GET', 'HEAD']);
    return new Response(request.method === 'HEAD' ? null : NGINX_WELCOME_HTML, { headers: {
      ...SECURITY_HEADERS, 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store',
    } });
  }
  const config = readConfig(env);
  const route = resolveRoute(request, url, config);
  const timestamp = Date.now();
  const now = Math.floor(timestamp / 1000);
  const cache = globalThis.caches?.default;
  const path = ['/ui', '/ui/login', '/ui/logout'].includes(url.pathname) ? url.pathname : route.path;
  if (path === '/favicon.ico') {
    return new Response(null, { status: 204, headers: SECURITY_HEADERS });
  }
  if (path === '/ui/login') {
    requireMethod(request, ['POST']);
    requireUiOrigin(request, url);
    const payload = await readJson(request, 8192);
    if (typeof payload.password !== 'string') {
      throw new HttpError(400, '请输入管理密码');
    }
    if (!equalToken(payload.password, config.adminToken)) {
      throw new HttpError(401, '密码不正确，请重试');
    }
    return json({ ok: true }, 200, { 'Set-Cookie': await issueUiSession(config, url.origin, now) });
  }
  if (path === '/ui/logout') {
    requireMethod(request, ['POST']);
    requireUiOrigin(request, url);
    return json({ ok: true }, 200, { 'Set-Cookie': clearUiSession() });
  }
  if (path === '/ui') {
    requireMethod(request, ['GET']);
    if (!route.adminCredential && !await validUiSession(request, config, url.origin, now)) {
      const response = loginPanel();
      if (readUiCookie(request)) {
        response.headers.set('Set-Cookie', clearUiSession());
      }
      return response;
    }
    const response = panel(config, config.adminToken, route.pathCredential);
    if (route.adminCredential) {
      response.headers.set('Set-Cookie', await issueUiSession(config, url.origin, now));
    }
    return response;
  }
  if (path === '/api/location') {
    requireMethod(request, ['GET']);
    if (!route.reportAuthorized) {
      throw new HttpError(401, '位置鉴权失败');
    }
    const organizationValue = request.cf?.asOrganization;
    const organization = typeof organizationValue === 'string' && Array.from(organizationValue).length <= 128 && !/[\u0000-\u001f\u007f-\u009f]/.test(organizationValue) ? organizationValue.trim() : '';
    const asnValue = request.cf?.asn;
    const asn = Number.isInteger(asnValue) && asnValue > 0 && asnValue <= 4294967295 ? asnValue : 0;
    return json({ ...requestLocation(request), ip: request.headers.get('CF-Connecting-IP') ?? '', organization, asn });
  }
  if (path === '/api/report' || path === '/api/node/delete') {
    requireMethod(request, ['POST']);
    if (!route.reportAuthorized) {
      throw new HttpError(401, '写入鉴权失败');
    }
    if (path === '/api/report') {
      return await reportNode(request, config, now, cache, url.origin);
    }
    const payload = await readJson(request, 8192);
    await config.kv.delete(`node:${validateId(payload.id)}`);
    await purgeCache(cache, url.origin, config);
    return json({ ok: true });
  }
  if (path === '/raw') {
    requireMethod(request, ['GET', 'HEAD']);
    if (!await authorizeRaw(url.searchParams.get('t') ?? '', config, timestamp)) {
      throw new HttpError(401, '只读鉴权失败');
    }
    return plain(await rawContent(await effectiveConfig(config), url.origin, cache), 200, { 'Cache-Control': 'no-store' });
  }
  const adminMethods = { '/api/nodes': ['GET'], '/api/node': ['DELETE'], '/api/sources': ['GET', 'PUT'], '/api/settings': ['GET', 'PUT'], '/api/status': ['GET'], '/sub': ['GET', 'HEAD'] };
  if (!Object.hasOwn(adminMethods, path)) {
    return plain('not found', 404, { 'Cache-Control': 'no-store' });
  }
  requireMethod(request, adminMethods[path]);
  if (!route.adminCredential) {
    if (path === '/sub') {
      return plain('not found', 404, { 'Cache-Control': 'no-store' });
    }
    throw new HttpError(401, '管理鉴权失败');
  }
  if (path === '/api/settings') {
    if (request.method === 'GET') {
      return json(await readSettings(config));
    }
    return await saveSettings(request, config, now);
  }
  if (path === '/api/nodes') {
    return json({ nodes: await readNodes(config.kv), now });
  }
  if (path === '/api/node') {
    await config.kv.delete(`node:${validateId(url.searchParams.get('id'))}`);
    await purgeCache(cache, url.origin, config);
    return json({ ok: true });
  }
  if (path === '/api/sources') {
    if (request.method === 'GET') {
      return json(await readSources(config));
    }
    return await saveSources(request, config, now, cache, url.origin);
  }
  if (path === '/api/status') {
    const settings = await readSettings(config);
    const cfip = settings.valid ? parseCfip(settings.cfip).map(address => address.label) : [];
    const includeCounts = url.searchParams.get('counts') !== '0';
    const nodeCount = includeCounts ? (await listNodeKeys(config.kv)).length : undefined;
    const sources = includeCounts ? await readSources(config) : undefined;
    return json({ version: VERSION, subapi: config.subapi, subconfig: config.subconfig, cfip, ...(includeCounts ? { nodeCount, sourceCount: sources.links.length + sources.upstream.length } : {}), ...(!settings.valid ? { cfipValidationError: settings.validationError } : {}) });
  }
  return await subscription(request, url, await effectiveConfig(config), timestamp, cache);
}

export default {
  async fetch(request, env) {
    let response;
    try {
      response = await handleRequest(request, env);
    } catch (error) {
      if (error instanceof HttpError) {
        response = json({ error: error.message }, error.status, error.headers);
      } else {
        response = json({ error: '内部错误' }, 500);
      }
    }
    if (request.method === 'HEAD') {
      await response.body?.cancel().catch(() => {});
      return new Response(null, { status: response.status, statusText: response.statusText, headers: response.headers });
    }
    return response;
  },
};
