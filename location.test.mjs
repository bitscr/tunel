import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

// Run with node --test location.test.mjs; set BASH_BIN when bash is not on PATH.
const script = readFileSync(new URL('./tunel.sh', import.meta.url), 'utf8');
const functions = script.slice(script.indexOf('location_ip_key() {'), script.indexOf('# 每轮上报只发送一次'))
  .replaceAll('/proc/net/route', '"$FIXTURE_DIR/route"')
  .replaceAll('/proc/net/ipv6_route', '"$FIXTURE_DIR/ipv6_route"')
  .replaceAll('/sys/class/net', '$FIXTURE_DIR/net');
const IPV6 = '2001:470:4892:ff69::230';
const KEY = '2001:470:4892:ff69:0:0:0:230';
const IPINFO = { ip: IPV6, country: 'US', region: 'California', org: 'AS6939 Hurricane Electric LLC' };
const WORKER_LOCATION = { ip: IPV6, country: 'US', region: 'CA', regionName: 'California', organization: 'Hurricane Electric LLC', asn: 6939 };
const zero = '00000000000000000000000000000000';
const ipv6Route = (device = 'eth0', metric = '00000064', flags = '00000003') =>
  [zero, '00', zero, '00', 'fe800000000000000000000000000001', metric, '00000000', '00000000', flags, device].join(' ');

function run(t, body, { ipv4 = '', ipv6 = '', ip = false, deviceTypes = { eth0: '1' }, ...env } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'tunel-location-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(join(dir, 'route'), 'Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n' + ipv4);
  writeFileSync(join(dir, 'ipv6_route'), ipv6);
  writeFileSync(join(dir, 'agent.env'), '');
  writeFileSync(join(dir, 'curl.log'), '');
  for (const [device, type] of Object.entries(deviceTypes)) {
    mkdirSync(join(dir, 'net', device), { recursive: true });
    writeFileSync(join(dir, 'net', device, 'type'), type);
  }
  const setup = String.raw`
has() { [ "$1" = ip ] && [ "$MOCK_HAS_IP" = 1 ]; }
ip() {
    case "$*" in
        '-4 route show table main default') printf '%s\n' "$MOCK_IPV4_ROUTE" ;;
        '-6 route show table main default') printf '%s\n' "$MOCK_IPV6_ROUTE" ;;
        '-4 -o address show dev eth0 scope global') printf '%s\n' "$MOCK_IPV4_ADDRESS" ;;
        '-6 -o address show dev eth0 scope global') printf '%s\n' "$MOCK_IPV6_ADDRESS" ;;
        *) return 1 ;;
    esac
}
curl() {
    printf '%s\n' "$*" >> "$FIXTURE_DIR/curl.log"
    local url
    for url; do :; done
    case "$RESPONSE_PROVIDER:$url" in
        worker:https://tunel.example/api/location|ipinfo:https://ipinfo.io/*)
            printf '%s' "$LOCATION_TEST_RESPONSE" ;;
        *) return 22 ;;
    esac
}
resource_maintenance() { :; }
agent_log() { printf 'LOG %s %s\n' "$1" "$2"; }
nodes_refresh() { :; }
AGENT_ENV="$FIXTURE_DIR/agent.env"
TUNEL_VERSION=test
AUTOMATIC_INTERVAL=3600
LOCATION_MEMORY_ATTEMPT_TS=0
REPORT_URL=https://tunel.example/api/report
REPORT_TOKEN=fixture-report-token
COUNTRY=''; REGION=''; REGION_NAME=''; LOCATION_TS=0; LOCATION_ATTEMPT_TS=0
LOCATION_VERIFIED=0; LOCATION_NEEDS_REPORT=0
`;
  const result = spawnSync(process.env.BASH_BIN || 'bash', ['--noprofile', '--norc', '-s'], {
    input: functions + setup + '\n' + body,
    encoding: 'utf8', timeout: 20000,
    env: { ...process.env, FIXTURE_DIR: dir.replaceAll('\\', '/'), MOCK_HAS_IP: ip ? '1' : '0', ...env },
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return { stdout: result.stdout, cache: readFileSync(join(dir, 'agent.env'), 'utf8'),
    calls: readFileSync(join(dir, 'curl.log'), 'utf8') };
}

const publicRoute = {
  ip: true,
  MOCK_IPV6_ROUTE: 'default via fe80::1 dev eth0 metric 100',
  MOCK_IPV6_ADDRESS: '2: eth0 inet6 2001:470:4892:ff69::230/64 scope global',
};
const routeOutput = 'location_select_route; printf "route=%s|%s|%s|%s|%s\\n" "$?" "$LOCATION_QUERY_MODE" "$LOCATION_QUERY_FAMILY" "$LOCATION_QUERY_INTERFACE" "$LOCATION_QUERY_IP"';
const refreshOutput = 'location_refresh; printf "location=%s|%s|%s|%s|%s\\n" "$COUNTRY" "$REGION" "$REGION_NAME" "$LOCATION_VERIFIED" "$LOCATION_QUERY_MODE"';

test('the reported Hurricane Electric IPv6 and IPInfo location parse successfully', t => {
  const result = run(t, String.raw`
LOCATION_QUERY_MODE=ip; LOCATION_QUERY_IP=$(location_ip_key '2001:470:4892:ff69::230')
location_verify_response "$LOCATION_TEST_RESPONSE" ip || exit 1
location_parse "$LOCATION_TEST_RESPONSE" country '' region || exit 1
printf '%s|%s|%s\n' "$LOCATION_NEXT_IP" "$LOCATION_NEXT_COUNTRY" "$LOCATION_NEXT_REGION_NAME"
`, { LOCATION_TEST_RESPONSE: JSON.stringify(IPINFO) });
  assert.equal(result.stdout.trim(), KEY + '|US|California');
});

test('IPv6-only containers without ip discover their native default interface from proc', t => {
  assert.match(run(t, routeOutput, { ipv6: ipv6Route() }).stdout, /route=0\|interface\|6\|eth0\|/);
});

test('proc IPv6 metrics sort numerically even when hex digits include letters', t => {
  const result = run(t, routeOutput, {
    ipv6: [ipv6Route('eth1', '00000100'), ipv6Route('eth0', '000000ff')].join('\n'),
    deviceTypes: { eth0: '1', eth1: '1' },
  });
  assert.match(result.stdout, /route=0\|interface\|6\|eth0\|/);
});

test('the existing IPv4 proc fallback still works without ip', t => {
  const ipv4 = 'eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n';
  assert.match(run(t, routeOutput, { ipv4 }).stdout, /route=0\|interface\|4\|eth0\|/);
});

test('iproute still selects and normalizes the public IPv6 address', t => {
  assert.match(run(t, routeOutput, publicRoute).stdout, new RegExp('route=0\\|ip\\|6\\|eth0\\|' + KEY));
});

test('WARP and WireGuard default interfaces are not used for native location', t => {
  const result = run(t, routeOutput, {
    ipv6: [ipv6Route('warp'), ipv6Route('wg0'), ipv6Route('lo')].join('\n'),
    deviceTypes: { warp: '1', wg0: '1', lo: '772' },
  });
  assert.match(result.stdout, /route=1\|\|\|\|/);
});

test('a successful third-party IPv6 lookup does not call the Worker fallback', t => {
  const result = run(t, refreshOutput, { ...publicRoute, RESPONSE_PROVIDER: 'ipinfo', LOCATION_TEST_RESPONSE: JSON.stringify(IPINFO) });
  assert.match(result.stdout, /location=US\|\|California\|1\|ip/);
  assert.equal(result.calls.trim().split('\n').length, 1);
  assert.match(result.calls, new RegExp('https://ipinfo.io/' + KEY + '/json'));
});

test('public IPv6 uses an interface-bound Worker fallback when third-party providers fail', t => {
  const result = run(t, refreshOutput, { ...publicRoute, RESPONSE_PROVIDER: 'worker', LOCATION_TEST_RESPONSE: JSON.stringify(WORKER_LOCATION) });
  assert.match(result.stdout, /location=US\|CA\|California\|1\|ip/);
  const workerCall = result.calls.trim().split('\n').at(-1);
  assert.match(workerCall, /-6 --interface if!eth0/);
  assert.match(workerCall, /Authorization: Bearer fixture-report-token/);
  assert.match(workerCall, /https:\/\/tunel\.example\/api\/location$/);
  assert.match(result.cache, new RegExp('LOCATION_IP=' + KEY + '\n'));
  assert.match(result.cache, /LOCATION_METHOD=ip\n/);
  assert.match(result.cache, /LOCATION_SOURCE=worker\n/);
});

test('a Worker response for another IP cannot overwrite a previously verified native location', t => {
  const body = 'COUNTRY=JP; REGION=13; REGION_NAME=Tokyo; LOCATION_VERIFIED=1;\n' + refreshOutput;
  const result = run(t, body, { ...publicRoute, RESPONSE_PROVIDER: 'worker', LOCATION_TEST_RESPONSE: JSON.stringify({ ...WORKER_LOCATION, ip: '2001:470:4892:ff69::999' }) });
  assert.match(result.stdout, /location=JP\|13\|Tokyo\|1\|ip/);
  assert.match(result.stdout, /LOG WARN 国家\/地区识别失败/);
  assert.match(result.cache, /COUNTRY=JP\n/);
});

test('Cloudflare/WARP ownership is still rejected even when the response IP matches', t => {
  const result = run(t, refreshOutput, { ...publicRoute, RESPONSE_PROVIDER: 'worker', LOCATION_TEST_RESPONSE: JSON.stringify({ ...WORKER_LOCATION, organization: 'Cloudflare, Inc.', asn: 13335 }) });
  assert.match(result.stdout, /location=\|\|\|0\|ip/);
  assert.match(result.stdout, /LOG WARN 国家\/地区识别失败/);
});

test('IPv6-only containers without ip can complete the bound Worker lookup', t => {
  const result = run(t, refreshOutput, { ipv6: ipv6Route(), RESPONSE_PROVIDER: 'worker', LOCATION_TEST_RESPONSE: JSON.stringify(WORKER_LOCATION) });
  assert.match(result.stdout, /location=US\|CA\|California\|1\|interface/);
  assert.match(result.calls, /-6 --interface if!eth0/);
  assert.match(result.cache, /LOCATION_METHOD=interface\n/);
});

test('a missing native route is logged once and does not trigger network calls or rapid retries', t => {
  const result = run(t, 'location_refresh; location_refresh;');
  assert.match(result.stdout, /未找到可用的原生 IPv4\/IPv6 默认接口/);
  assert.equal(result.stdout.trim().split('\n').length, 1);
  assert.equal(result.calls, '');
});

const workerSource = readFileSync(new URL('./worker/_worker.js', import.meta.url), 'utf8');
const { default: worker } = await import('data:text/javascript;base64,' + Buffer.from(workerSource).toString('base64'));
const env = { ADMIN_TOKEN: 'fixture-admin-token', REPORT_TOKEN: 'fixture-report-token', TUNEL_KV: { get: async () => null } };

test('Worker /api/location returns native IPv6, country and region metadata', async () => {
  const request = new Request('https://tunel.example/api/location', { headers: { Authorization: 'Bearer fixture-report-token', 'CF-Connecting-IP': IPV6 } });
  request.cf = { country: 'US', regionCode: 'CA', region: 'California', asOrganization: 'Hurricane Electric LLC', asn: 6939 };
  const response = await worker.fetch(request, env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ...WORKER_LOCATION, countryName: '美国' });
});

for (const [label, verified, old, expectedCountry] of [
  ['verified script location wins over the reporting request location', true, null, 'US'],
  ['unverified script reports do not silently trust a potentially proxied request', false, null, ''],
  ['unverified script reports retain an existing verified location', false, { country: 'JP', region: '13', regionName: 'Tokyo', locationVerified: true }, 'JP'],
]) {
  test(`Worker report: ${label}`, async () => {
    let stored;
    const node = { v: '2', ps: 'ct230', add: 'tunnel.example', port: '443', id: '11111111-1111-4111-8111-111111111111', net: 'ws', path: '/vmess', tls: 'tls' };
    const payload = {
      id: 'ct230', name: 'ct230', mode: 'fixed', host: 'tunnel.example', path: '/vmess', uuid: node.id,
      link: 'vmess://' + Buffer.from(JSON.stringify(node)).toString('base64'),
      country: verified ? 'US' : '', region: verified ? 'CA' : '', regionName: verified ? 'California' : '', locationVerified: verified,
    };
    const reportEnv = { ...env, TUNEL_KV: { get: async () => old, put: async (key, value) => { stored = JSON.parse(value); } } };
    const request = new Request('https://tunel.example/api/report', {
      method: 'POST', headers: { Authorization: 'Bearer fixture-report-token', 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
    });
    request.cf = { country: 'DE', regionCode: 'BE', region: 'Berlin' };
    const response = await worker.fetch(request, reportEnv);
    assert.equal(response.status, 200, await response.text());
    assert.equal(stored.country, expectedCountry);
    assert.equal(stored.locationVerified, verified || old?.locationVerified === true);
  });
}
