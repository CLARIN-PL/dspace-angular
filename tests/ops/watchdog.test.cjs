const {test} = require('node:test');
const assert = require('node:assert/strict');
const {mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync} = require('node:fs');
const {tmpdir} = require('node:os');
const {join, resolve} = require('node:path');
const {spawnSync} = require('node:child_process');

test('host watchdog recovers only failed liveness and enforces cooldown and restart budget', t => {
  const folder = mkdtempSync(join(tmpdir(), 'ssr-watchdog-test-'));
  t.after(() => rmSync(folder, {recursive: true, force: true}));
  const actions = join(folder, 'actions');
  const state = join(folder, 'state');
  // Fake Docker CLI: this test never connects to the Docker daemon.
  writeFileSync(join(folder, 'docker'), `#!/bin/sh
case "$1" in
  ps) printf '%s\\n' "fixture-frontend" ;;
  inspect)
    case "$3" in
      *Config.Healthcheck*) printf '%s\\n' "$FAKE_PROBE" ;;
      *) printf '%s\\n' "$FAKE_STATUS" ;;
    esac ;;
  exec) exit "$FAKE_LIVE_EXIT" ;;
  restart) printf '%s\\n' "$3" >> "$FAKE_ACTIONS" ;;
  *) exit 97 ;;
esac
`, {mode: 0o700});
  const run = (overrides = {}) => spawnSync('bash', [resolve('docker/production/frontend-watchdog.sh')], {
    encoding: 'utf8',
    env: {...process.env, PATH: `${folder}:${process.env.PATH}`,
      WATCHDOG_STATE_DIR: state,
      FAKE_ACTIONS: actions,
      FAKE_STATUS: 'unhealthy',
      FAKE_PROBE: '["CMD-SHELL","wget /app/live"]',
      FAKE_LIVE_EXIT: '1',
      ...overrides,
    },
  });
  assert.equal(run({FAKE_STATUS: 'healthy'}).status, 0);
  assert.equal(existsSync(actions), false);
  assert.equal(run({FAKE_PROBE: '["CMD-SHELL","wget /app/health"]'}).status, 1);
  assert.equal(existsSync(actions), false, 'backend-dependent probes must not cause restarts');
  assert.equal(run({FAKE_LIVE_EXIT: '0'}).status, 0);
  assert.equal(existsSync(actions), false, 'recovered frontend must not restart');
  assert.equal(run().status, 0);
  assert.equal(readFileSync(actions, 'utf8').trim().split('\n').length, 1);
  assert.equal(run().status, 0);
  assert.equal(readFileSync(actions, 'utf8').trim().split('\n').length, 1, 'cooldown enforced');
  const now = Math.floor(Date.now() / 1000);
  writeFileSync(join(state, 'restarts'), `${now - 600}\n${now - 400}\n${now - 200}\n`);
  const exhausted = run();
  assert.equal(exhausted.status, 1);
  assert.match(exhausted.stderr, /budget exhausted/);
  assert.equal(readFileSync(actions, 'utf8').trim().split('\n').length, 1);
});
