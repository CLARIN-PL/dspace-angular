const {test} = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const cookieParser = require('cookie-parser');
const {setTimeout: delay} = require('node:timers/promises');
const {readFileSync} = require('node:fs');
const yaml = require('js-yaml');
const {RenderGate, SsrPageRuntime, readinessHandler, isScannerPath} = require('../../server/ssr-runtime');

const item = '/items/9333dde5-0cc3-4d5f-a583-028f3a1ca82b';

async function listen(t, app) {
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => {server.closeAllConnections(); server.close();});
  return `http://127.0.0.1:${server.address().port}`;
}

async function fixture(t, overrides = {}) {
  let calls = 0;
  const app = express();
  app.use(cookieParser());
  const options = {
    enabled: true,
    maxConcurrentRenders: 4,
    renderTimeoutMs: 1000,
    excludePathPatterns: [{pattern: '^/browse(?:/|$)'}],
    languages: ['pl', 'en'], defaultLanguage: 'pl', cacheHeaders: ['Link'],
    botCache: {max: 8, timeToLive: 10000, allowStale: true, maxSizeBytes: 32768},
    anonymousCache: {max: 8, timeToLive: 10000, allowStale: true, maxSizeBytes: 32768},
    internalRestUrl: 'http://backend:8080/server', publicRestUrl: 'https://repository.test/server',
    replaceRestUrl: true,
    render: (req, res, done) => {res.set('Link', '<https://repository.test/data>; rel="describedby"'); done(null, `SSR:${req.cookies.dsLanguage || 'pl'}:${req.url}`);},
    renderClient: (_req, res) => res.send('CSR'),
    ...overrides,
  };
  const render = options.render;
  options.render = (...args) => {calls++; return render(...args);};
  const runtime = new SsrPageRuntime(options);
  app.get('/app/live', (_req, res) => res.json({status: 'UP'}));
  app.use('/dspace', runtime.handle);
  const origin = await listen(t, app);
  const request = async (url, options) => {
    const response = await fetch(origin + '/dspace' + url, {
      ...options,
      headers: {
        'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
        ...options?.headers,
      },
    });
    return {status: response.status, text: await response.text(), headers: response.headers};
  };
  return {origin, request, runtime, calls: () => calls};
}

test('browse exclusions cover bare paths, slash and query strings with namespace', async t => {
  const f = await fixture(t);
  for (const url of ['/browse', '/browse/', '/browse?rpp=100&type=author']) {
    assert.equal((await f.request(url)).text, 'CSR');
  }
  assert.equal(f.calls(), 0);
  assert.match((await f.request(item)).text, /^SSR:/);
});

test('the shipped YAML excludes bare browse and enables explicit resource budgets', () => {
  const config = yaml.load(readFileSync('config/config.yml', 'utf8'));
  assert(config.universal.excludePathPatterns.some(p => new RegExp(p.pattern, p.flag).test('/browse')));
  const production = yaml.load(readFileSync('docker/production/config.prod.yml', 'utf8'));
  for (const name of ['botCache', 'anonymousCache']) {
    assert(production.cache.serverSide[name].maxSizeBytes > 0);
    assert(production.cache.serverSide[name].maxEntrySizeBytes > 0);
  }
});

test('scanner roots receive a small 404 without invoking Angular', async t => {
  const f = await fixture(t);
  for (const url of ['/.git/HEAD', '/.env', '/.env.local', '/wp-admin/', '/awstatstotals.php', '/biztalkhttpreceive.dll']) {
    const response = await f.request(url);
    assert.equal(response.status, 404, url);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert(response.text.length < 100);
  }
  assert.equal(f.calls(), 0);
  assert.equal(isScannerPath('/bitstream/handle/11321/592/document.php'), false);
  assert.equal(isScannerPath('/static/terms-of-service'), false);
});

test('PL and EN cached HTML and Link headers remain separate', async t => {
  const f = await fixture(t);
  for (const language of ['pl', 'en', 'pl', 'en']) {
    const response = await f.request(item, {headers: {Cookie: `dsLanguage=${language}`}});
    assert.match(response.text, new RegExp(`^SSR:${language}:`));
    assert.match(response.headers.get('link'), /describedby/);
  }
  assert.equal(f.calls(), 2);
});

test('even a bot with authentication never reads or writes shared cache', async t => {
  const f = await fixture(t, {
    render: (req, _res, done) => done(null, req.cookies.dsAuthInfo || req.get('authorization') || 'PUBLIC'),
  });
  assert.equal((await f.request(item)).text, 'PUBLIC');
  for (const headers of [
    {Cookie: 'dsAuthInfo=PRIVATE-A', 'User-Agent': 'Googlebot'},
    {Authorization: 'Bearer PRIVATE-B', 'User-Agent': 'Googlebot'},
  ]) {
    for (let i = 0; i < 2; i++) {
      assert.match((await f.request(item, {headers})).text, /PRIVATE/);
    }
  }
  assert.equal((await f.request(item)).text, 'PUBLIC');
  assert.equal(f.calls(), 5);
});

test('query variants and private routes never populate shared cache', async t => {
  const f = await fixture(t);
  for (const url of [item + '?token=one', item + '?token=two', '/login', '/mydspace', '/reload/random']) {
    await f.request(url);
    await f.request(url);
  }
  assert.equal(f.calls(), 10);
  assert.equal(f.runtime.statistics().botCache.entries, 0);
  assert.equal(f.runtime.statistics().anonymousCache.entries, 0);
});

test('Set-Cookie, private responses and HTTP errors are not cached', async t => {
  for (const kind of ['cookie', 'private', 'error']) {
    const f = await fixture(t, {render: (_req, res, done) => {
      if (kind === 'cookie') res.set('Set-Cookie', 'session=private');
      if (kind === 'private') res.set('Cache-Control', 'private, no-store');
      if (kind === 'error') res.status(404);
      done(null, 'not shared');
    }});
    await f.request(item);
    await f.request(item);
    assert.equal(f.calls(), 2, kind);
    assert.equal(f.runtime.statistics().botCache.entries, 0);
  }
});

test('expired cache is served once without starting a render with an ended response', async t => {
  const f = await fixture(t, {
    botCache: {max: 8, timeToLive: 20, allowStale: true},
    anonymousCache: {max: 8, timeToLive: 20, allowStale: true},
  });
  await f.request(item);
  await delay(45);
  assert.match((await f.request(item)).text, /^SSR:/);
  assert.equal(f.calls(), 1, 'stale delivery does not reuse req/res for background rendering');
  await f.request(item);
  assert.equal(f.calls(), 2, 'next request refreshes with its own response');
});

test('cache memory stays bounded for many distinct public pages', async t => {
  const f = await fixture(t, {
    botCache: {max: 1000, timeToLive: 10000, allowStale: true, maxSizeBytes: 12000, maxEntrySizeBytes: 6000},
    anonymousCache: {max: 1000, timeToLive: 10000, allowStale: true, maxSizeBytes: 12000, maxEntrySizeBytes: 6000},
    render: (_req, _res, done) => done(null, 'x'.repeat(1600)),
  });
  for (let i = 0; i < 80; i++) await f.request(`/static/page-${i}`);
  const stats = f.runtime.statistics();
  assert(stats.botCache.bytes <= 12000);
  assert(stats.anonymousCache.bytes <= 12000);
  assert(stats.botCache.entries <= 3);
  assert.equal(f.calls(), 80);
});

test('oversized pages are delivered but never cached', async t => {
  const f = await fixture(t, {
    botCache: {max: 8, timeToLive: 10000, allowStale: true, maxSizeBytes: 4096, maxEntrySizeBytes: 2048},
    anonymousCache: {max: 8, timeToLive: 10000, allowStale: true, maxSizeBytes: 4096, maxEntrySizeBytes: 2048},
    render: (_req, _res, done) => done(null, 'x'.repeat(5000)),
  });
  await f.request(item);
  await f.request(item);
  assert.equal(f.calls(), 2);
  assert.equal(f.runtime.statistics().botCache.entries, 0);
});

test('hung work retains its slot after the HTTP deadline and blocks duplicate work', async t => {
  let complete;
  const f = await fixture(t, {maxConcurrentRenders: 1, renderTimeoutMs: 35,
    render: (_req, _res, done) => {complete = done;},
  });
  assert.equal((await f.request(item)).status, 503);
  assert.equal(f.runtime.statistics().render.active, 1);
  assert.equal(f.runtime.isStalled(), true);
  assert.equal((await f.request('/home')).status, 503);
  assert.equal(f.calls(), 1);
  assert.equal((await fetch(f.origin + '/app/live')).status, 200);
  complete(null, 'too late');
  assert.equal(f.runtime.statistics().render.active, 0);
  assert.equal(f.runtime.isStalled(), false);
  assert.equal(f.runtime.statistics().botCache.entries, 0);
});

test('parallel requests cannot start a second render for the same cache key', async t => {
  const f = await fixture(t, {render: (_req, _res, done) => setTimeout(() => done(null, 'OK'), 40)});
  const responses = await Promise.all(Array.from({length: 12}, () => f.request(item)));
  assert.equal(f.calls(), 1);
  assert.equal(responses.filter(r => r.status === 200).length, 1);
  assert(responses.filter(r => r.status === 503).every(r => r.headers.get('retry-after') === '1'));
  assert.equal(f.runtime.statistics().render.active, 0);
});

test('client disconnect does not cache abandoned HTML and late completion releases its slot', async t => {
  let complete;
  let notifyStarted;
  const started = new Promise(resolve => {notifyStarted = resolve;});
  const f = await fixture(t, {render: (_req, _res, done) => {
    complete = done;
    notifyStarted();
  }});
  const controller = new AbortController();
  const pending = fetch(f.origin + '/dspace' + item, {signal: controller.signal}).catch(() => undefined);
  await started;
  controller.abort();
  await pending;
  await delay(20);
  assert.equal(f.runtime.statistics().render.active, 1, 'abandoned work is still running');
  complete(null, 'abandoned HTML');
  assert.equal(f.runtime.statistics().render.active, 0);
  assert.equal(f.runtime.statistics().botCache.entries, 0);
  assert.equal(f.runtime.statistics().anonymousCache.entries, 0);
});

test('renderer errors, synchronous throws and repeated callbacks release exactly one slot', async t => {
  for (const render of [
    (_req, _res, done) => done(new Error('undefined stream')),
    () => {throw new Error('synchronous failure');},
    (_req, _res, done) => {done(null, 'OK'); done(null, 'SECOND');},
  ]) {
    const f = await fixture(t, {render});
    assert.equal((await f.request(item)).status, 200);
    assert.equal(f.runtime.statistics().render.active, 0);
  }
});

test('crawler receives retryable status for renderer error rather than empty indexed HTML', async t => {
  const f = await fixture(t, {render: (_req, _res, done) => done(new Error('failure'))});
  const response = await f.request(item, {headers: {'User-Agent': 'Googlebot'}});
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('cache-control'), 'no-store');
});

test('an Angular redirect already sent by the renderer is not sent or cached again', async t => {
  const f = await fixture(t, {render: (_req, res, done) => {
    res.redirect(301, '/target');
    done(Object.assign(new Error('headers sent'), {code: 'ERR_HTTP_HEADERS_SENT'}));
  }});
  const response = await f.request(item, {redirect: 'manual'});
  assert.equal(response.status, 301);
  assert.equal(response.headers.get('location'), '/target');
  assert.equal(f.runtime.statistics().render.active, 0);
  assert.equal(f.runtime.statistics().botCache.entries, 0);
});

test('REST URL replacement treats hostname punctuation literally', async t => {
  const f = await fixture(t, {render: (_req, _res, done) => done(null,
    'http://backend:8080/server/api http://backend:8080/server/other')});
  assert.equal((await f.request(item)).text,
    'https://repository.test/server/api https://repository.test/server/other');
});

test('readiness handles network errors without assuming an HTTP response exists', async t => {
  const app = express();
  app.get('/health', readinessHandler('http://unused', 30, {get: () => Promise.reject(new Error('network down'))}));
  const response = await fetch(await listen(t, app) + '/health');
  assert.equal(response.status, 503);
  assert.equal((await response.json()).status, 'DOWN');
});

test('readiness has a real upstream timeout, independent of liveness', async t => {
  const backend = express();
  backend.get('/health', () => {});
  const upstream = await listen(t, backend);
  const app = express();
  app.get('/live', (_req, res) => res.json({status: 'UP'}));
  app.get('/health', readinessHandler(upstream + '/health', 30));
  const origin = await listen(t, app);
  const start = Date.now();
  assert.equal((await fetch(origin + '/health')).status, 503);
  assert(Date.now() - start < 1000);
  assert.equal((await fetch(origin + '/live')).status, 200);
});

test('RenderGate rejects invalid resource limits and finishes each job once', () => {
  assert.throws(() => new RenderGate(0));
  const gate = new RenderGate(1);
  const lease = gate.start('one', 1000, () => {});
  assert.equal(gate.start('two', 1000, () => {}), undefined);
  assert.equal(lease.finish(), true);
  assert.equal(lease.finish(), false);
  assert.equal(gate.statistics().active, 0);
});
