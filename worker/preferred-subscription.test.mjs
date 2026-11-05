import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

// Load the deployment entry point as ESM without adding a package.json or dependencies.
const source = await readFile(new URL('./_worker.js', import.meta.url), 'utf8');
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

const ORIGIN = 'https://tunel.example';
const ADMIN_TOKEN = 'integration-admin-token';
const REPORT_TOKEN = 'integration-report-token';
const PLACEHOLDER_UUID = '00000000-0000-4000-8000-000000000000';
const OFFICIAL_VERSION = '20261008222327';

const base64 = value => Buffer.from(value, 'utf8').toString('base64');
const vmess = node => `vmess://${base64(JSON.stringify(node))}`;
const decodeVmess = link => JSON.parse(Buffer.from(link.slice('vmess://'.length), 'base64').toString('utf8'));

function originalNode(index) {
  return {
    v: '2', ps: `节点 ${index}`, add: `original-${index}.example`, port: '443',
    id: `11111111-1111-4111-8111-${String(index).padStart(12, '0')}`,
    aid: '0', scy: 'auto', net: 'ws', type: 'none',
    host: `tunnel-${index}.example`, sni: `tls-${index}.example`,
    path: `/vmess/${index}?ed=2048`, tls: 'tls', alpn: 'h2,http/1.1',
  };
}

class MemoryKV {
  constructor(entries = {}) {
    this.values = new Map(Object.entries(entries).map(([key, value]) => [key, typeof value === 'string' ? value : JSON.stringify(value)]));
    this.writes = [];
  }

  async get(key, type) {
    const value = this.values.get(key) ?? null;
    return value !== null && type === 'json' ? JSON.parse(value) : value;
  }

  async put(key, value) {
    this.writes.push({ key, value });
    this.values.set(key, value);
  }

  async delete(key) {
    this.values.delete(key);
  }

  async list({ prefix = '', cursor = '0' } = {}) {
    const keys = [...this.values.keys()].filter(key => key.startsWith(prefix)).sort();
    const offset = Number(cursor);
    const page = keys.slice(offset, offset + 2);
    const next = offset + page.length;
    return { keys: page.map(name => ({ name })), list_complete: next >= keys.length, cursor: String(next) };
  }
}

class MemoryCache {
  constructor(staleBody) {
    this.values = new Map();
    this.staleBody = staleBody;
  }

  async match(request) {
    if (this.staleBody !== undefined) {
      return new Response(this.staleBody);
    }
    return this.values.get(request.url)?.clone();
  }

  async put(request, response) {
    this.values.set(request.url, response.clone());
  }

  async delete(request) {
    return this.values.delete(request.url);
  }
}

function harness(t, { nodes = [], links = [], upstream = [], settings, cfip = '', sub = 'picker.example', remote, converter, cache = new MemoryCache() } = {}) {
  const entries = { sources: { links, upstream } };
  for (const [index, node] of nodes.entries()) {
    entries[`node:local-${String(index).padStart(4, '0')}`] = {
      id: `local-${String(index).padStart(4, '0')}`, name: `本地 ${index}`,
      country: 'CN', regionName: `地区 ${index}`, link: vmess(node),
    };
  }
  if (settings !== undefined) entries.settings = settings;
  const kv = new MemoryKV(entries);
  const env = { ADMIN_TOKEN, REPORT_TOKEN, TUNEL_KV: kv, CFIP: cfip, SUB: sub, SUBAPI: 'https://converter.example', SUBNAME: '测试订阅' };
  const remoteCalls = [];
  const converterCalls = [];
  const cacheDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'caches');
  Object.defineProperty(globalThis, 'caches', { configurable: true, writable: true, value: { default: cache } });
  t.after(() => {
    if (cacheDescriptor) Object.defineProperty(globalThis, 'caches', cacheDescriptor);
    else delete globalThis.caches;
  });

  t.mock.method(globalThis, 'fetch', async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const call = { url, headers: new Headers(init.headers ?? (input instanceof Request ? input.headers : undefined)), init };
    if (url.hostname === 'converter.example') {
      converterCalls.push(call);
      if (!converter) throw new Error('Unexpected converter request');
      return await converter(call, { env, kv, remoteCalls, converterCalls });
    }
    remoteCalls.push(call);
    if (!remote) throw new Error(`Unexpected preferred subscriber request: ${url.origin}`);
    return await remote(call, { env, kv, remoteCalls, converterCalls });
  });

  async function request(path = '/sub?b64', { authorized = true, method = 'GET', payload, headers = {} } = {}) {
    const requestHeaders = new Headers(headers);
    if (authorized) requestHeaders.set('Authorization', `Bearer ${ADMIN_TOKEN}`);
    if (payload !== undefined) requestHeaders.set('Content-Type', 'application/json');
    return await worker.fetch(new Request(new URL(path, ORIGIN), {
      method, headers: requestHeaders, ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
    }), env);
  }

  return { request, env, kv, cache, remoteCalls, converterCalls };
}

async function subscriptionLines(response) {
  assert.equal(response.status, 200, 'subscription should succeed');
  const content = Buffer.from(await response.text(), 'base64').toString('utf8');
  return content ? content.split(/\r?\n/) : [];
}

function assertNodeAddresses(lines, expected) {
  const nodes = lines.filter(link => link.startsWith('vmess://')).map(link => {
    try { return decodeVmess(link); } catch { return null; }
  }).filter(node => node && typeof node.add === 'string' && node.add);
  assert.deepEqual(nodes.map(node => [node.add, Number(node.port)]), expected);
}

test('unauthorized subscriptions and raw callbacks never contact the preferred subscriber', async t => {
  const h = harness(t, { links: [vmess(originalNode(1))], remote: () => new Response('192.0.2.1') });
  for (const method of ['GET', 'HEAD']) {
    for (const path of ['/sub', '/sub?token=wrong']) {
      const response = await h.request(path, { authorized: false, method });
      assert.equal(response.status, 404);
      if (method === 'HEAD') assert.equal(await response.text(), '');
    }
  }
  assert.equal((await h.request('/raw?t=invalid&addresses=invalid', { authorized: false })).status, 401);
  assert.equal((await h.request('/api/settings', { authorized: false })).status, 401);
  assert.equal((await h.request('/sub', { method: 'POST' })).status, 405);
  assert.equal((await h.request('/api/settings')).status, 200);
  assert.equal(h.remoteCalls.length, 0);
  assert.equal(h.converterCalls.length, 0);
});

for (const [label, subscriber] of [
  ['hostname', 'picker.example'],
  ['full URL', 'https://picker.example/custom/list?key=secret&host=old&uuid=old&b64=1#ignored'],
  ['sub scheme', 'sub://picker.example/sub?region=HK'],
]) {
  test(`env.SUB accepts a ${label} and sends the compatible placeholder request`, async t => {
    const h = harness(t, { sub: subscriber, links: [vmess(originalNode(1))], remote: () => new Response('192.0.2.1:8443#优选') });
    assertNodeAddresses(await subscriptionLines(await h.request()), [['192.0.2.1', 8443]]);
    assert.equal(h.remoteCalls.length, 1);
    const { url, headers, init } = h.remoteCalls[0];
    assert.equal(url.origin, 'https://picker.example');
    assert.equal(url.pathname, '/sub');
    assert.equal(url.hash, '');
    assert.equal(url.searchParams.get('host'), 'example.com');
    assert.equal(url.searchParams.get('uuid'), PLACEHOLDER_UUID);
    assert.deepEqual([...url.searchParams], [['host', 'example.com'], ['uuid', PLACEHOLDER_UUID]]);
    assert.deepEqual([...headers.keys()], ['user-agent']);
    assert.equal(headers.get('User-Agent'), `v2rayN/edgetunnel (https://github.com/cmliu/edgetunnel) Uid/0x000000 Version/${OFFICIAL_VERSION}`);
    assert.equal(init.cache, undefined, 'match official fetch options without adding cache request headers');
  });
}

// Mirrors cmliu/edgetunnel's BEST_SUB entry check (_worker.js, 2026-10-08).
test('a restricted BEST_SUB subscriber recognizes the official request instead of forcing CFIP fallback', async t => {
  const h = harness(t, {
    links: [vmess(originalNode(1)), vmess(originalNode(2))], cfip: 'fallback.example:443',
    remote: ({ url, headers }) => {
      const recognized = url.pathname === '/sub' && url.searchParams.get('host') === 'example.com'
        && url.searchParams.get('uuid') === PLACEHOLDER_UUID
        && headers.get('User-Agent').toLowerCase().includes('tunnel (https://github.com/cmliu/edge');
      if (!recognized) return new Response('not recognized', { status: 403 });
      return new Response(base64([
        `vless://${PLACEHOLDER_UUID}@192.0.2.30:2053?host=example.com&sni=example.com#Preferred`,
        `trojan://${PLACEHOLDER_UUID}@[2001:db8::30]:8443?host=example.com&sni=example.com#Preferred-IPv6`,
      ].join('\n')));
    },
  });
  assertNodeAddresses(await subscriptionLines(await h.request()), [['192.0.2.30', 2053], ['2001:db8::30', 8443]]);
  assert.equal(h.remoteCalls.length, 1);
});

test('local and manual VMess nodes consume one address each, then cycle CFIP, preserving other fields', async t => {
  const localNodes = [originalNode(1), originalNode(2)];
  const manualNodes = [3, 4, 5, 6, 7].map(originalNode);
  const untouched = [
    'trojan://real-password@outside.example:443?sni=outside.example#外部节点',
    'vmess://not-valid-base64!',
    `vmess://${base64('{broken json')}`,
    vmess({ ps: 'missing connection address', id: originalNode(99).id }),
  ];
  const manualLinks = [untouched[0], vmess(manualNodes[0]), untouched[1], untouched[2], vmess(manualNodes[1]), untouched[3], ...manualNodes.slice(2).map(vmess)];
  const preferred = [
    `vless://${PLACEHOLDER_UUID}@192.0.2.10:8443?host=example.com#remote name`,
    `trojan://${PLACEHOLDER_UUID}@192.0.2.20:2053?sni=example.com#another remote name`,
  ].join('\n');
  const h = harness(t, { nodes: localNodes, links: manualLinks, cfip: 'cf-one.example:443\ncf-two.example:8443', remote: () => new Response(base64(preferred)) });
  const localBaseline = (await (await h.request('/api/nodes')).json()).nodes.map(node => decodeVmess(node.link));
  const lines = await subscriptionLines(await h.request());
  assert.equal(lines.length, localNodes.length + manualLinks.length, 'address selection must not expand node count');
  assert.deepEqual(lines.filter(link => untouched.includes(link)), untouched);
  const actualNodes = lines.filter(link => !untouched.includes(link)).map(decodeVmess);
  const expectedAddresses = [
    ['192.0.2.10', 8443], ['192.0.2.20', 2053], ['cf-one.example', 443],
    ['cf-two.example', 8443], ['cf-one.example', 443], ['cf-two.example', 8443], ['cf-one.example', 443],
  ];
  assert.deepEqual(actualNodes, [...localBaseline, ...manualNodes].map((node, index) => ({ ...node, add: expectedAddresses[index][0], port: expectedAddresses[index][1] })));
  assert.equal(h.remoteCalls.length, 1);
});

test('matching preferred and CFIP addresses preserve original VMess links without reserializing', async t => {
  const originals = [
    { ...originalNode(1), add: '192.0.2.1' },
    { ...originalNode(2), add: '2001:db8::2', port: '8443' },
    { ...originalNode(3), port: undefined },
    { ...originalNode(4), add: 'fallback.example', port: 2053 },
  ];
  const links = originals.map(vmess);
  const h = harness(t, {
    links, cfip: 'fallback.example:2053',
    remote: () => new Response('192.0.2.1:443\n[2001:db8::2]:8443\noriginal-3.example:443'),
  });
  assert.deepEqual(await subscriptionLines(await h.request()), links);
  assert.equal(h.remoteCalls.length, 1);
});

const mixedPreferred = [
  'invalid text',
  `vless://11111111-1111-4111-8111-111111111111@outside.example:443?host=example.com`,
  `trojan://${PLACEHOLDER_UUID}@outside.example:443?sni=real.example`,
  vmess({ ...originalNode(91), id: PLACEHOLDER_UUID, host: 'real.example', sni: 'real.example' }),
  `vless://${PLACEHOLDER_UUID}@198.51.100.10:8443?host=example.com#VLESS`,
  '198.51.100.10:8443#duplicate',
  `trojan://${PLACEHOLDER_UUID}@preferred.example:2053?sni=example.com#Trojan`,
  vmess({ ...originalNode(92), id: PLACEHOLDER_UUID, host: 'example.com', add: '203.0.113.20' }),
  '203.0.113.20:443#default-port duplicate',
  '[2001:db8::1]:9443#IPv6',
  `vless://${PLACEHOLDER_UUID}@[2001:db8::1]:9443?sni=example.com#IPv6 duplicate`,
  '2001:db8::1#bare IPv6 uses port 443',
  '[2001:db8::1]:443#same IPv6 and port',
  'BARE.Example:443#备注',
  'bare.example#case-insensitive duplicate with default port',
  'bare.example:8443#different port is a distinct address',
  'localhost', '127.0.0.1:443', '[::1]:443', '0.0.0.0',
  'bad.example:0', 'bad.example:65536', 'https://ordinary.example/sub',
  'vmess://broken!',
].join('\n');

for (const [label, content] of [['plaintext', mixedPreferred], ['base64', base64(mixedPreferred)]]) {
  test(`${label} results accept placeholder protocols and bare IPv6, deduplicating host and port`, async t => {
    const h = harness(t, { links: Array.from({ length: 8 }, (_, index) => vmess(originalNode(index + 1))), cfip: 'fallback.example:443', remote: () => new Response(content) });
    assertNodeAddresses(await subscriptionLines(await h.request()), [
      ['198.51.100.10', 8443], ['preferred.example', 2053], ['203.0.113.20', 443],
      ['2001:db8::1', 9443], ['2001:db8::1', 443], ['BARE.Example', 443], ['bare.example', 8443],
      ['fallback.example', 443],
    ]);
  });
}

test('every GET refreshes remote results and ignores stale cache even when the address list repeats', async t => {
  const remoteResults = ['192.0.2.10:443', '192.0.2.11:8443', '192.0.2.11:8443'];
  const staleBody = base64(vmess({ ...originalNode(1), add: 'stale.example' }));
  const h = harness(t, { links: [vmess(originalNode(1))], cache: new MemoryCache(staleBody), remote: () => new Response(remoteResults.shift()) });
  for (const expected of [['192.0.2.10', 443], ['192.0.2.11', 8443]]) {
    const response = await h.request();
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assertNodeAddresses(await subscriptionLines(response), [expected]);
  }
  await h.kv.put('sources', JSON.stringify({ links: [vmess({ ...originalNode(1), ps: '刚更新的节点名称' })], upstream: [] }));
  const refreshed = await subscriptionLines(await h.request());
  assertNodeAddresses(refreshed, [['192.0.2.11', 8443]]);
  assert.equal(decodeVmess(refreshed[0]).ps, '刚更新的节点名称');
  assert.equal(h.remoteCalls.length, 3);
});

for (const [label, failure] of [
  ['network error', () => { throw new Error('network unavailable'); }],
  ['HTTP failure', () => new Response('temporarily unavailable', { status: 503 })],
  ['empty response', () => new Response('')],
  ['invalid lines', () => new Response('not an address\ninvalid.example:65536\nvmess://broken')],
  ['external nodes only', () => new Response(base64(`vless://real-user@outside.example:443?host=real.example\n${vmess(originalNode(50))}`))],
]) {
  test(`a fresh ${label} falls back to CFIP instead of returning previous successful results`, async t => {
    const h = harness(t, {
      links: [1, 2, 3].map(index => vmess(originalNode(index))), cfip: 'cf-one.example:443\ncf-two.example:2053',
      remote: (_call, { remoteCalls }) => remoteCalls.length === 1 ? new Response('192.0.2.10:8443') : failure(),
    });
    assertNodeAddresses(await subscriptionLines(await h.request()), [['192.0.2.10', 8443], ['cf-one.example', 443], ['cf-two.example', 2053]]);
    assertNodeAddresses(await subscriptionLines(await h.request()), [['cf-one.example', 443], ['cf-two.example', 2053], ['cf-one.example', 443]]);
    assert.equal(h.remoteCalls.length, 2);
  });
}

test('without CFIP, exhausted or failed preferred results leave remaining nodes at their original addresses', async t => {
  const originals = [1, 2, 3].map(originalNode);
  const h = harness(t, { links: originals.map(vmess), remote: (_call, { remoteCalls }) => new Response(remoteCalls.length === 1 ? '192.0.2.10:8443' : '') });
  const first = await subscriptionLines(await h.request());
  assert.deepEqual(first.map(decodeVmess), [{ ...originals[0], add: '192.0.2.10', port: 8443 }, originals[1], originals[2]]);
  assert.deepEqual((await subscriptionLines(await h.request())).map(decodeVmess), originals);
  assert.equal(h.remoteCalls.length, 2);
});

test('authenticated HEAD requests refresh the subscriber, return headers, and have no body', async t => {
  const h = harness(t, {
    links: [vmess(originalNode(1))], cfip: 'fallback.example:443',
    remote: (_call, { remoteCalls }) => new Response(remoteCalls.length === 4 ? '' : `192.0.2.${remoteCalls.length}:443`),
  });
  assertNodeAddresses(await subscriptionLines(await h.request()), [['192.0.2.1', 443]]);
  const head = await h.request('/sub?b64', { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
  assert.equal(head.headers.get('Cache-Control'), 'no-store');
  assert.ok(head.headers.get('Content-Type').startsWith('text/plain'));
  assert.equal(h.remoteCalls.length, 2);
  assertNodeAddresses(await subscriptionLines(await h.request()), [['192.0.2.3', 443]]);
  const fallbackHead = await h.request('/sub?b64', { method: 'HEAD' });
  assert.equal(fallbackHead.status, 200);
  assert.equal(await fallbackHead.text(), '');
  assert.equal(h.remoteCalls.length, 4);
});

test('settings persist the subscriber, retain it when omitted, and an empty value overrides env.SUB', async t => {
  const h = harness(t, { links: [vmess(originalNode(1))], cfip: 'initial.example:443', sub: 'env-picker.example', remote: () => new Response('192.0.2.10:443') });
  const initial = await (await h.request('/api/settings')).json();
  assert.equal(initial.preferredSubscriber, 'https://env-picker.example/sub');
  assert.equal(initial.preferredSubscriberSource, 'env');
  assert.equal(h.remoteCalls.length, 0);

  const savedResponse = await h.request('/api/settings', { method: 'PUT', payload: { cfip: 'saved.example:2053', preferredSubscriber: 'sub://saved-picker.example/sub?region=HK' } });
  assert.equal(savedResponse.status, 200);
  const saved = await savedResponse.json();
  assert.equal(saved.preferredSubscriber, 'https://saved-picker.example/sub?region=HK');
  assert.equal(saved.preferredSubscriberSource, 'settings');
  assert.equal((await h.kv.get('settings', 'json')).preferredSubscriber, saved.preferredSubscriber);
  h.env.SUB = 'changed-env-picker.example';
  assert.equal((await (await h.request('/api/settings')).json()).preferredSubscriber, saved.preferredSubscriber);
  assertNodeAddresses(await subscriptionLines(await h.request()), [['192.0.2.10', 443]]);
  assert.equal(h.remoteCalls[0].url.hostname, 'saved-picker.example');
  assert.equal(h.remoteCalls[0].url.searchParams.has('region'), false, 'saved query parameters are not sent to the official subscriber endpoint');

  const updateResponse = await h.request('/api/settings', { method: 'PUT', payload: { cfip: 'updated.example:8443' } });
  assert.equal(updateResponse.status, 200);
  assert.equal((await updateResponse.json()).preferredSubscriber, saved.preferredSubscriber);
  assert.equal((await h.kv.get('settings', 'json')).preferredSubscriber, saved.preferredSubscriber);

  const disabledResponse = await h.request('/api/settings', { method: 'PUT', payload: { cfip: 'updated.example:8443', preferredSubscriber: '' } });
  assert.equal(disabledResponse.status, 200);
  const disabled = await disabledResponse.json();
  assert.equal(disabled.preferredSubscriber, '');
  assert.equal(disabled.preferredSubscriberSource, 'settings');
  assert.equal((await h.kv.get('settings', 'json')).preferredSubscriber, '');
  assert.equal((await (await h.request('/api/settings')).json()).preferredSubscriber, '');
  assertNodeAddresses(await subscriptionLines(await h.request()), [['updated.example', 8443]]);
  assert.equal(h.remoteCalls.length, 1, 'saved empty value must disable the environment subscriber');
});

test('legacy settings containing only CFIP still use env.SUB and preserve it when updated', async t => {
  const h = harness(t, {
    links: [vmess(originalNode(1)), vmess(originalNode(2))], sub: 'legacy-picker.example',
    settings: { cfip: 'legacy-cf.example:2053', updatedAt: 42 }, remote: () => new Response('192.0.2.10:443'),
  });
  const settings = await (await h.request('/api/settings')).json();
  assert.equal(settings.cfip, 'legacy-cf.example:2053');
  assert.equal(settings.source, 'settings');
  assert.equal(settings.preferredSubscriber, 'https://legacy-picker.example/sub');
  assert.equal(settings.preferredSubscriberSource, 'env');
  assertNodeAddresses(await subscriptionLines(await h.request()), [['192.0.2.10', 443], ['legacy-cf.example', 2053]]);
  assert.equal(h.remoteCalls[0].url.hostname, 'legacy-picker.example');
  const updated = await h.request('/api/settings', { method: 'PUT', payload: { cfip: 'new-cf.example:443' } });
  assert.equal(updated.status, 200);
  assert.equal((await updated.json()).preferredSubscriber, 'https://legacy-picker.example/sub');
  assert.equal((await h.kv.get('settings', 'json')).preferredSubscriber, 'https://legacy-picker.example/sub');
});

test('invalid subscriber settings are rejected without replacing the previous saved value', async t => {
  const h = harness(t, { settings: { cfip: 'fallback.example:443', preferredSubscriber: 'https://saved-picker.example/sub' } });
  for (const preferredSubscriber of [42, 'ftp://picker.example', 'https://user:password@picker.example', 'picker example']) {
    const response = await h.request('/api/settings', { method: 'PUT', payload: { cfip: 'new-cf.example:443', preferredSubscriber } });
    assert.equal(response.status, 400);
    assert.equal((await h.kv.get('settings', 'json')).preferredSubscriber, 'https://saved-picker.example/sub');
  }
  assert.equal(h.kv.writes.length, 0);
  assert.equal(h.remoteCalls.length, 0);
});

for (const [label, cfip, expectedRemainder] of [
  ['CFIP fallback', 'cf-one.example:443\ncf-two.example:8443', [['cf-one.example', 443], ['cf-two.example', 8443]]],
  ['original-address fallback', '', [['original-2.example', 443], ['original-3.example', 443]]],
]) {
  test(`converter callbacks use the signed address snapshot with ${label} and do not refetch`, async t => {
    let callbackLines;
    let callbackUrl;
    const upstreamNode = 'trojan://upstream-password@upstream.example:443#Upstream';
    const untouched = 'vmess://invalid-json!';
    const h = harness(t, {
      cfip, links: [vmess(originalNode(1)), untouched, vmess(originalNode(2)), vmess(originalNode(3))], upstream: ['https://upstream.example/sub'],
      remote: (_call, { remoteCalls }) => new Response(`192.0.2.${remoteCalls.length}:2053`),
      converter: async ({ url, headers }, { env, kv }) => {
        assert.equal(headers.get('User-Agent'), `Subconverter for mixed edgetunnel (https://github.com/cmliu/edgetunnel) Uid/0x000000 Version/${OFFICIAL_VERSION}`);
        const sources = url.searchParams.get('url').split('|');
        assert.equal(sources[1], 'https://upstream.example/sub');
        callbackUrl = new URL(sources[0]);
        assert.equal(callbackUrl.pathname, '/raw');
        assert.ok(callbackUrl.searchParams.get('t'));
        assert.ok(callbackUrl.searchParams.get('addresses'));
        // Configuration changes during conversion must not alter the current callback.
        await kv.put('settings', JSON.stringify({ cfip: 'late-cf.example:9443', preferredSubscriber: 'https://different-picker.example/sub' }));
        callbackLines = await subscriptionLines(await worker.fetch(new Request(callbackUrl), env));
        return new Response(base64([upstreamNode, ...callbackLines].join('\n')));
      },
    });
    const output = await subscriptionLines(await h.request());
    assertNodeAddresses(callbackLines, [['192.0.2.1', 2053], ...expectedRemainder]);
    assert.ok(callbackLines.includes(untouched));
    assert.deepEqual(output, [upstreamNode, ...callbackLines], 'converted output and local output must share this request\'s assigned addresses');
    assert.equal(h.remoteCalls.length, 1);
    assert.equal(h.converterCalls.length, 1);
    const repeat = await worker.fetch(new Request(callbackUrl), h.env);
    assert.deepEqual(await subscriptionLines(repeat), callbackLines);
    assert.equal(h.remoteCalls.length, 1);
  });
}

for (const [flag, target] of [['clash', 'clash'], ['sb', 'singbox'], ['surge', 'surge'], ['quanx', 'quanx'], ['loon', 'loon']]) {
  test(`${target} conversion refreshes preferred addresses once per request and reuses them in callbacks`, async t => {
    const h = harness(t, {
      links: [1, 2, 3].map(index => vmess(originalNode(index))), cfip: 'fallback.example:443',
      cache: new MemoryCache('stale converted subscription'),
      remote: (_call, { remoteCalls }) => new Response(`192.0.2.${remoteCalls.length}:8443`),
      converter: async ({ url, headers }, { env, remoteCalls }) => {
        assert.equal(url.searchParams.get('target'), target);
        assert.equal(headers.get('User-Agent'), `Subconverter for ${target} edgetunnel (https://github.com/cmliu/edgetunnel) Uid/0x000000 Version/${OFFICIAL_VERSION}`);
        const callbackUrl = new URL(url.searchParams.get('url'));
        assertNodeAddresses(await subscriptionLines(await worker.fetch(new Request(callbackUrl), env)), [
          [`192.0.2.${remoteCalls.length}`, 8443], ['fallback.example', 443], ['fallback.example', 443],
        ]);
        return new Response(`converted ${target} ${remoteCalls.length}`);
      },
    });
    for (const requestIndex of [1, 2]) {
      const response = await h.request(`/sub?${flag}`, { headers: { 'User-Agent': 'Client/1.0' } });
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('Cache-Control'), 'no-store');
      assert.equal(await response.text(), `converted ${target} ${requestIndex}`);
      assert.equal(h.remoteCalls.length, requestIndex);
      assert.equal(h.converterCalls.length, requestIndex);
    }
  });
}

test('raw callback signatures reject changed, removed, or unsigned address snapshots before any remote fetch', async t => {
  let callbackUrl;
  const h = harness(t, {
    links: [vmess(originalNode(1))], remote: () => new Response('192.0.2.10:8443'),
    converter: async ({ url }, { env }) => {
      callbackUrl = new URL(url.searchParams.get('url').split('|')[0]);
      assertNodeAddresses(await subscriptionLines(await worker.fetch(new Request(callbackUrl), env)), [['192.0.2.10', 8443]]);
      return new Response('proxies: []\n');
    },
  });
  const converted = await h.request('/sub?clash');
  assert.equal(converted.status, 200);
  assert.equal(await converted.text(), 'proxies: []\n');
  const altered = new URL(callbackUrl);
  altered.searchParams.set('addresses', base64(JSON.stringify([['attacker.example', 443]])));
  const removed = new URL(callbackUrl);
  removed.searchParams.delete('addresses');
  const unsigned = new URL(callbackUrl);
  unsigned.searchParams.delete('t');
  const changedSignature = new URL(callbackUrl);
  changedSignature.searchParams.set('t', 'invalid-signature');
  for (const url of [altered, removed, unsigned, changedSignature]) {
    const response = await worker.fetch(new Request(url), h.env);
    assert.equal(response.status, 401);
  }
  assert.equal(h.remoteCalls.length, 1);
});

test('converter failure returns local nodes with the current preferred addresses', async t => {
  const h = harness(t, {
    links: [vmess(originalNode(1)), vmess(originalNode(2))], cfip: 'fallback.example:443',
    remote: () => new Response('192.0.2.10:8443'), converter: () => new Response('unavailable', { status: 502 }),
  });
  const response = await h.request('/sub?clash');
  assert.equal(response.headers.get('X-Tunel-Fallback'), 'subconverter-failed');
  assertNodeAddresses(await subscriptionLines(response), [['192.0.2.10', 8443], ['fallback.example', 443]]);
  assert.equal(h.remoteCalls.length, 1);
  assert.equal(h.converterCalls.length, 1);
});
