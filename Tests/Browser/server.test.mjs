import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const runtime = process.env.ORBIT_BROWSER_RUNTIME;
test('Browser MCP authenticates clients and keeps unsafe tools unavailable', { skip: !runtime }, async () => {
  const require = createRequire(path.join(runtime, 'package.json'));
  const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
  const { StreamableHTTPClientTransport } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
  const root = fileURLToPath(new URL('../../', import.meta.url));
  const folder = await mkdtemp(path.join(tmpdir(), 'orbit-browser-test-'));
  const child = spawn(process.execPath, [path.join(root, 'Sources/OrbitDesktop/Resources/Browser/server.mjs'),
    runtime, path.join(folder, 'profile'), path.join(folder, 'output')], {
    env: { ...process.env, ORBIT_BROWSER_TOKEN: 'test-only-token' }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let diagnostics = '';
  child.stderr.on('data', data => { diagnostics += data; });
  let client;
  try {
    const url = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Browser server startup timed out')), 10000);
      child.stdout.once('data', data => { clearTimeout(timeout); resolve(JSON.parse(String(data)).url); });
      child.once('exit', code => { clearTimeout(timeout); reject(new Error(`Server exited ${code}: ${diagnostics}`)); });
    });
    assert.equal(new URL(url).hostname, '127.0.0.1');
    assert.equal((await fetch(url, { method: 'POST', body: '{}' })).status, 403);
    assert.equal((await fetch(url, { method: 'POST', headers: {
      Authorization: 'Bearer test-only-token', Origin: 'https://untrusted.example',
    }, body: '{}' })).status, 403);
    const approvalURL = new URL('/approve', url);
    assert.equal((await fetch(approvalURL, { method: 'POST', body: '{}' })).status, 403);
    assert.equal((await fetch(approvalURL, { method: 'POST', headers: {
      Authorization: 'Bearer test-only-token', 'Content-Type': 'application/json',
    }, body: JSON.stringify({ id: 'expired', allowed: true }) })).status, 404);
    client = new Client({ name: 'OrbitTest', version: '1' });
    const transport = new StreamableHTTPClientTransport(new URL(url), {
      requestInit: { headers: { Authorization: 'Bearer test-only-token' } },
    });
    await client.connect(transport);
    const { tools } = await client.listTools();
    assert.ok(tools.some(tool => tool.name === 'browser_navigate'));
    assert.ok(tools.some(tool => tool.name === 'browser_snapshot'));
    const blocked = await client.callTool({ name: 'browser_evaluate', arguments: { function: '() => 1' } });
    assert.equal(blocked.isError, true);
    assert.match(blocked.content[0].text, /Tool unavailable in Orbit/);
    const batch = await fetch(url, { method: 'POST', headers: {
      Authorization: 'Bearer test-only-token', 'Content-Type': 'application/json',
      'mcp-session-id': transport.sessionId, Accept: 'application/json, text/event-stream',
    }, body: JSON.stringify([{ jsonrpc: '2.0', id: 'batch-test', method: 'tools/call',
      params: { name: 'browser_evaluate', arguments: { function: '() => 1' } } }]) });
    assert.equal(batch.status, 200);
    const blockedBatch = await batch.json();
    assert.equal(blockedBatch[0].id, 'batch-test');
    assert.equal(blockedBatch[0].result.isError, true);
    assert.match(blockedBatch[0].result.content[0].text, /Tool unavailable in Orbit/);
  } finally {
    await client?.close();
    child.kill('SIGTERM');
    await new Promise(resolve => child.once('exit', resolve));
    await rm(folder, { recursive: true, force: true });
  }
});
