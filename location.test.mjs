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
    if [ "$url" = https://api64.ipify.org ]; then
        local address="$LOCATION_TEST_EXIT_IPV6"
        [[ " $* " != *" -4 "* ]] || address=$LOCATION_TEST_EXIT_IPV4
        [ -n "$address" ] || return 22
        printf '%s' "$address"
        return 0
    fi
    if [ -n "$LOCATION_TEST_EXIT_IPV6" ] && [ "$url" = https://ipinfo.io/json ] && [[ " $* " = *" -6 "* ]]; then
        printf 'curl: (6) Could not resolve host: ipinfo.io\n' >&2
        return 6
    fi
    case "$RESPONSE_PROVIDER:$url" in
        worker:https://tunel.example/api/location|ipinfo:https://ipinfo.io/*|ip.sb:https://api.ip.sb/*)
            if [ -n "$RESPONSE_FAMILY" ] && [[ " $* " != *" -$RESPONSE_FAMILY "* ]]; then return 28; fi
            if [[ " $* " = *" -4 "* ]] && [ -n "$LOCATION_TEST_IPV4_RESPONSE" ]; then
                printf '%s' "$LOCATION_TEST_IPV4_RESPONSE"
            else
                printf '%s' "$LOCATION_TEST_RESPONSE"
            fi ;;
        *) return 22 ;;
    esac
}
resource_maintenance() { :; }
agent_log() { printf 'LOG %s %s\n' "$1" "$2"; }
nodes_refresh() { :; }
AGENT_ENV="$FIXTURE_DIR/agent.env"
AGENT_LOG="$FIXTURE_DIR/agent.log"
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
  return { stdout: result.stdout, stderr: result.stderr, cache: readFileSync(join(dir, 'agent.env'), 'utf8'),
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

test('IPv6-only containers without ip can use the bound Worker lookup when IPify is unavailable', t => {
  const result = run(t, refreshOutput, { ipv6: ipv6Route(), RESPONSE_PROVIDER: 'worker', LOCATION_TEST_RESPONSE: JSON.stringify(WORKER_LOCATION) });
  assert.match(result.stdout, /location=US\|CA\|California\|1\|interface/);
  assert.match(result.calls, /-6 --interface if!eth0/);
  assert.match(result.cache, /LOCATION_METHOD=interface\n/);
  assert.match(result.calls.trim().split('\n')[0], /-6 --interface if!eth0.*https:\/\/api64.ipify.org$/);
  assert.equal(result.calls.trim().split('\n').length, 6);
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


test('curl errors are logged without leaking the report credential or corrupting JSON output', t => {
  const result = run(t, String.raw`
curl() { printf 'curl: (28) Connection timed out\n' >&2; return 28; }
LOCATION_QUERY_MODE=interface; LOCATION_QUERY_FAMILY=6; LOCATION_QUERY_INTERFACE=eth0
response=$(location_fetch https://tunel.example/api/location -H 'Authorization: Bearer fixture-report-token'); rc=$?
printf 'fetch=%s|%s\n' "$rc" "$response"
`);
  assert.equal(result.stdout.trim(), 'fetch=1|');
  assert.match(result.stderr, /位置查询失败.*curl 28.*Connection timed out/);
  assert.doesNotMatch(result.stderr, /fixture-report-token/);
});

test('rejected response logs identify the mismatched IP', t => {
  const result = run(t, refreshOutput, {
    ...publicRoute, RESPONSE_PROVIDER: 'worker',
    LOCATION_TEST_RESPONSE: JSON.stringify({ ...WORKER_LOCATION, ip: '2001:470:4892:ff69::999' }),
  });
  assert.match(result.stderr, /位置响应 IP 不匹配/);
  assert.match(result.stderr, /2001:470:4892:ff69:0:0:0:230/);
});

const privateDualRoute = {
  ip: true,
  MOCK_IPV4_ROUTE: 'default via 10.233.105.254 dev eth0 proto dhcp src 10.233.105.230 metric 1024',
  MOCK_IPV4_ADDRESS: '2: eth0 inet 10.233.105.230/24 scope global',
  MOCK_IPV6_ROUTE: 'default via fe80::1266:6aff:fe69:2f00 dev eth0 proto ra metric 1024',
  MOCK_IPV6_ADDRESS: '2: eth0 inet6 fde9:105::230/128 scope global',
};

test('dual-stack private addresses fall back to the IPv6 exit when IPv4 lookups fail', t => {
  const result = run(t, refreshOutput + '; printf "family=%s\\n" "$LOCATION_QUERY_FAMILY"', {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ipinfo', RESPONSE_FAMILY: '6', LOCATION_TEST_RESPONSE: JSON.stringify(IPINFO),
  });
  assert.match(result.stdout, /location=US\|\|California\|1\|interface/);
  assert.match(result.stdout, /family=6/);
  const calls = result.calls.trim().split('\n');
  assert.equal(calls.length, 8);
  assert.match(calls[1], /-4 --interface if!eth0.*https:\/\/ipinfo.io\/json$/);
  assert.match(calls.at(-1), /-6 --interface if!eth0.*https:\/\/ipinfo.io\/json$/);
  assert.doesNotMatch(result.calls, /ipinfo.io\/(?:10\.233|fde9:)/);
  assert.match(result.cache, new RegExp('LOCATION_IP=' + KEY + '\n'));
  assert.match(result.cache, /LOCATION_METHOD=interface\n/);
});

test('dual-stack private addresses do not query IPv6 after IPv4 succeeds', t => {
  const result = run(t, refreshOutput, {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ipinfo', RESPONSE_FAMILY: '4', LOCATION_TEST_RESPONSE: JSON.stringify({ ...IPINFO, ip: '8.8.8.8' }),
  });
  assert.match(result.stdout, /location=US\|\|California\|1\|interface/);
  assert.equal(result.calls.trim().split('\n').length, 2);
  assert.match(result.calls, /-4 --interface if!eth0/);
});

test('dual-stack private addresses reject a WARP IPv4 exit and can use a native IPv6 exit', t => {
  const warp = { ip: '104.28.1.2', country: 'DE', region: 'Hesse', org: 'AS13335 Cloudflare, Inc.' };
  const result = run(t, refreshOutput, {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ipinfo', LOCATION_TEST_RESPONSE: JSON.stringify(IPINFO),
    LOCATION_TEST_IPV4_RESPONSE: JSON.stringify(warp),
  });
  assert.match(result.stdout, /location=US\|\|California\|1\|interface/);
  assert.match(result.stderr, /Cloudflare\/WARP/);
  assert.equal(result.calls.trim().split('\n').length, 8);
});

test('dual-stack failed lookups only try each family once and keep the hourly retry limit', t => {
  const result = run(t, 'COUNTRY=JP; REGION=13; REGION_NAME=Tokyo; LOCATION_VERIFIED=1; location_refresh; ' + refreshOutput, privateDualRoute);
  assert.match(result.stdout, /location=JP\|13\|Tokyo\|1\|interface/);
  assert.match(result.cache, /COUNTRY=JP\n/);
  const calls = result.calls.trim().split('\n');
  assert.equal(calls.length, 12);
  assert.equal(calls.filter(call => call.includes('-4 --interface if!eth0')).length, 6);
  assert.equal(calls.filter(call => call.includes('-6 --interface if!eth0')).length, 6);
  assert.equal((result.stdout.match(/国家\/地区识别失败/g) || []).length, 1);
});

test('dual-stack proc routes without ip can fall back to IPv6 and reuse its cached interface', t => {
  const result = run(t, 'location_refresh; LOCATION_ATTEMPT_TS=0; LOCATION_MEMORY_ATTEMPT_TS=0; ' + refreshOutput, {
    ipv4: 'eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n', ipv6: ipv6Route('eth1'),
    deviceTypes: { eth0: '1', eth1: '1' }, RESPONSE_PROVIDER: 'worker', RESPONSE_FAMILY: '6',
    LOCATION_TEST_RESPONSE: JSON.stringify(WORKER_LOCATION),
  });
  assert.match(result.stdout, /location=US\|CA\|California\|1\|interface/);
  assert.equal(result.calls.trim().split('\n').length, 12);
  assert.match(result.calls.trim().split('\n').at(-1), /-6 --interface if!eth1/);
  assert.match(result.cache, /LOCATION_INTERFACE=eth1\n/);
});


test('dual-stack private addresses still reject a WARP IPv6 exit', t => {
  const warp = { ...IPINFO, ip: '2606:4700:110:8123::1', org: 'AS13335 Cloudflare, Inc.' };
  const result = run(t, refreshOutput, {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ipinfo', RESPONSE_FAMILY: '6', LOCATION_TEST_RESPONSE: JSON.stringify(warp),
  });
  assert.match(result.stdout, /location=\|\|\|0\|interface/);
  assert.match(result.cache, /COUNTRY=\n/);
  assert.match(result.stderr, /Cloudflare\/WARP/);
  assert.equal(result.calls.trim().split('\n').length, 12);
});

test('a local public IPv6 address still wins over a private IPv4 default route', t => {
  const result = run(t, refreshOutput, {
    ...privateDualRoute, ...publicRoute, RESPONSE_PROVIDER: 'ipinfo', LOCATION_TEST_RESPONSE: JSON.stringify(IPINFO),
  });
  assert.match(result.stdout, /location=US\|\|California\|1\|ip/);
  assert.equal(result.calls.trim().split('\n').length, 1);
  assert.match(result.calls, new RegExp('https://ipinfo.io/' + KEY + '/json'));
});

test('IPv4-only private routes do not retry an absent IPv6 route', t => {
  const result = run(t, 'location_refresh; location_refresh;', {
    ...privateDualRoute, MOCK_IPV6_ROUTE: '', MOCK_IPV6_ADDRESS: '',
  });
  assert.equal(result.calls.trim().split('\n').length, 6);
  assert.doesNotMatch(result.calls, /-6 --interface/);
  assert.match(result.stdout, /接口 eth0（IPv4/);
});


test('the ct230 WARP IPv4 exit and IPv6 IPInfo DNS failure fall through to native IPv6 IP.SB', t => {
  const result = run(t, String.raw`
curl() {
    printf '%s\n' "$*" >> "$FIXTURE_DIR/curl.log"
    local url
    for url; do :; done
    if [ "$url" = https://ipinfo.io/json ] && [[ " $* " = *" -4 "* ]]; then
        printf '%s' "$LOCATION_TEST_IPV4_RESPONSE"
    elif [ "$url" = https://ipinfo.io/json ] && [[ " $* " = *" -6 "* ]]; then
        printf 'curl: (6) Could not resolve host: ipinfo.io\n' >&2
        return 6
    elif [ "$url" = https://api.ip.sb/geoip ] && [[ " $* " = *" -6 "* ]]; then
        printf '%s' "$LOCATION_TEST_RESPONSE"
    else
        return 22
    fi
}
` + refreshOutput, {
    ...privateDualRoute,
    LOCATION_TEST_IPV4_RESPONSE: JSON.stringify({ ip: '104.28.227.187', country: 'US', region: 'California', org: 'AS13335 Cloudflare, Inc.' }),
    LOCATION_TEST_RESPONSE: JSON.stringify({ ip: IPV6, country_code: 'US', region_code: 'CA', region: 'California', asn: 6939, organization: 'Hurricane Electric LLC' }),
  });
  assert.match(result.stdout, /location=US\|CA\|California\|1\|interface/);
  assert.match(result.stderr, /Cloudflare\/WARP/);
  assert.match(result.stderr, /curl 6.*Could not resolve host: ipinfo.io/);
  assert.equal(result.calls.trim().split('\n').length, 9);
  assert.match(result.calls.trim().split('\n').at(-1), /-6 --interface if!eth0.*https:\/\/api.ip.sb\/geoip$/);
  assert.match(result.cache, /LOCATION_SOURCE=ip.sb\n/);
  assert.match(result.cache, new RegExp('LOCATION_IP=' + KEY + '\n'));
});


const WARP_IPV4_LOCATION = { ip: '104.28.227.187', country: 'US', region: 'California', org: 'AS13335 Cloudflare, Inc.' };

test('ct230 discovers its actual IPv6 exit before querying IPInfo by IP over available connectivity', t => {
  const result = run(t, 'location_refresh; LOCATION_ATTEMPT_TS=0; LOCATION_MEMORY_ATTEMPT_TS=0; ' + refreshOutput, {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ipinfo', LOCATION_TEST_EXIT_IPV6: IPV6,
    LOCATION_TEST_IPV4_RESPONSE: JSON.stringify(WARP_IPV4_LOCATION), LOCATION_TEST_RESPONSE: JSON.stringify(IPINFO),
  });
  assert.match(result.stdout, /location=US\|\|California\|1\|interface/);
  const calls = result.calls.trim().split('\n');
  assert.equal(calls.length, 8);
  assert.match(calls.at(-2), /-6 --interface if!eth0.*https:\/\/api64.ipify.org$/);
  assert.match(calls.at(-1), new RegExp('https://ipinfo.io/' + KEY + '/json$'));
  assert.doesNotMatch(calls.at(-1), /--interface| -6 /);
  assert.doesNotMatch(result.calls, /-6 --interface if!eth0.*https:\/\/ipinfo.io\/json/);
  assert.match(result.cache, /LOCATION_SOURCE=ipinfo\n/);
  assert.match(result.cache, /LOCATION_METHOD=interface\n/);
  assert.match(result.cache, new RegExp('LOCATION_IP=' + KEY + '\n'));
  assert.match(result.cache, /LOCATION_INTERFACE=eth0\n/);
});

test('a country response for another IP cannot overwrite the discovered native IPv6 location', t => {
  const result = run(t, 'COUNTRY=JP; REGION=13; REGION_NAME=Tokyo; LOCATION_VERIFIED=1; ' + refreshOutput, {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ipinfo', LOCATION_TEST_EXIT_IPV6: IPV6,
    LOCATION_TEST_IPV4_RESPONSE: JSON.stringify(WARP_IPV4_LOCATION),
    LOCATION_TEST_RESPONSE: JSON.stringify({ ...IPINFO, ip: '2001:470:4892:ff69::999' }),
  });
  assert.match(result.stdout, /location=JP\|13\|Tokyo\|1\|interface/);
  assert.match(result.cache, /COUNTRY=JP\n/);
  assert.match(result.stderr, /位置响应 IP 不匹配/);
  assert.match(result.stderr, new RegExp(KEY));
});

test('an IP-discovered Cloudflare IPv6 exit is still rejected by ASN ownership verification', t => {
  const warp = { ...IPINFO, ip: '2606:4700:110:8123::1', org: 'AS13335 Cloudflare, Inc.' };
  const result = run(t, refreshOutput, {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ipinfo', LOCATION_TEST_EXIT_IPV6: warp.ip,
    LOCATION_TEST_IPV4_RESPONSE: JSON.stringify(WARP_IPV4_LOCATION), LOCATION_TEST_RESPONSE: JSON.stringify(warp),
  });
  assert.match(result.stdout, /location=\|\|\|0\|interface/);
  assert.match(result.cache, /COUNTRY=\n/);
  assert.match(result.stderr, /Cloudflare\/WARP/);
  assert.match(result.calls, /ipinfo.io\/2606:4700:110:8123:0:0:0:1\/json/);
});

test('invalid private IP discovery data is not used as a public country lookup target', t => {
  const result = run(t, refreshOutput, { ...privateDualRoute, LOCATION_TEST_EXIT_IPV6: 'fde9:105::230' });
  assert.match(result.stdout, /location=\|\|\|0\|interface/);
  assert.match(result.cache, /COUNTRY=\n/);
  assert.doesNotMatch(result.calls, /ipinfo.io\/fde9:|geoip\/fde9:/);
});

test('NAT IPv4 also supports IP discovery followed by an explicit country lookup without querying IPv6', t => {
  const result = run(t, refreshOutput, {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ipinfo', LOCATION_TEST_EXIT_IPV4: '8.8.8.8',
    LOCATION_TEST_RESPONSE: JSON.stringify({ ...IPINFO, ip: '8.8.8.8' }),
  });
  assert.match(result.stdout, /location=US\|\|California\|1\|interface/);
  const calls = result.calls.trim().split('\n');
  assert.equal(calls.length, 2);
  assert.match(calls[0], /-4 --interface if!eth0.*https:\/\/api64.ipify.org$/);
  assert.match(calls[1], /https:\/\/ipinfo.io\/8.8.8.8\/json$/);
  assert.doesNotMatch(calls[1], /--interface/);
  assert.doesNotMatch(result.calls, /-6 --interface/);
  assert.match(result.cache, /LOCATION_METHOD=interface\n/);
});


test('IP.SB remains a country lookup fallback for an IP-discovered IPv6 exit when IPInfo fails', t => {
  const result = run(t, refreshOutput, {
    ...privateDualRoute, RESPONSE_PROVIDER: 'ip.sb', LOCATION_TEST_EXIT_IPV6: IPV6,
    LOCATION_TEST_IPV4_RESPONSE: JSON.stringify(WARP_IPV4_LOCATION),
    LOCATION_TEST_RESPONSE: JSON.stringify({ ip: IPV6, country_code: 'US', region_code: 'CA', region: 'California', asn: 6939, organization: 'Hurricane Electric LLC' }),
  });
  assert.match(result.stdout, /location=US\|CA\|California\|1\|interface/);
  const calls = result.calls.trim().split('\n');
  assert.equal(calls.length, 9);
  assert.match(calls.at(-2), new RegExp('https://ipinfo.io/' + KEY + '/json$'));
  assert.match(calls.at(-1), new RegExp('https://api.ip.sb/geoip/' + KEY + '$'));
  assert.doesNotMatch(calls.at(-1), /--interface/);
  assert.match(result.cache, /LOCATION_SOURCE=ip.sb\n/);
  assert.match(result.cache, /LOCATION_METHOD=interface\n/);
});


test('IPv4-only minimal containers without ip can discover the NAT exit from their proc default route', t => {
  const result = run(t, refreshOutput, {
    ipv4: 'eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n',
    RESPONSE_PROVIDER: 'ipinfo', LOCATION_TEST_EXIT_IPV4: '8.8.8.8',
    LOCATION_TEST_RESPONSE: JSON.stringify({ ...IPINFO, ip: '8.8.8.8' }),
  });
  assert.match(result.stdout, /location=US\|\|California\|1\|interface/);
  const calls = result.calls.trim().split('\n');
  assert.equal(calls.length, 2);
  assert.match(calls[0], /-4 --interface if!eth0.*https:\/\/api64.ipify.org$/);
  assert.doesNotMatch(result.calls, / -6 /);
  assert.match(result.cache, /LOCATION_IP=8.8.8.8\n/);
  assert.match(result.cache, /LOCATION_METHOD=interface\n/);
});

test('IPv6-only minimal containers can retain a bound Worker fallback after discovering their NAT exit', t => {
  const result = run(t, refreshOutput, {
    ipv6: ipv6Route(), RESPONSE_PROVIDER: 'worker', RESPONSE_FAMILY: '6', LOCATION_TEST_EXIT_IPV6: IPV6,
    LOCATION_TEST_RESPONSE: JSON.stringify(WORKER_LOCATION),
  });
  assert.match(result.stdout, /location=US\|CA\|California\|1\|interface/);
  const calls = result.calls.trim().split('\n');
  assert.equal(calls.length, 6);
  assert.match(calls[0], /-6 --interface if!eth0.*https:\/\/api64.ipify.org$/);
  assert.match(calls.at(-1), /-6 --interface if!eth0.*https:\/\/tunel.example\/api\/location$/);
  assert.doesNotMatch(result.calls, / -4 /);
  assert.match(result.cache, /LOCATION_SOURCE=worker\n/);
  assert.match(result.cache, /LOCATION_METHOD=interface\n/);
  assert.match(result.cache, new RegExp('LOCATION_IP=' + KEY + '\n'));
});
