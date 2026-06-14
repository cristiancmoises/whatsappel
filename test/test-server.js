'use strict';

/**
 * WhatsApp.el server endpoint tests.
 *
 * Run: node test/test-server.js
 *
 * Requires the server to be running (node server.js).
 * Tests API shape and error handling — does NOT require
 * an active WhatsApp connection for most tests.
 */

const http = require('http');

const HOST = process.env.WAEL_HOST || 'localhost';
const PORT = parseInt(process.env.WAEL_PORT || '3000', 10);
const WS_PORT = parseInt(process.env.WAEL_WS_PORT || '3001', 10);

let passed = 0;
let failed = 0;
const errors = [];

function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const opts = {
      hostname: HOST,
      port: PORT,
      path: `/api/v1${path}`,
      method,
      headers: { 'Content-Type': 'application/json' },
      timeout: 5000,
    };
    const req = http.request(opts, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

function assert(name, condition) {
  if (condition) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    errors.push(name);
    console.log(`  ✗ ${name}`);
  }
}

async function testHealth() {
  console.log('\n─── Health ───');
  const r = await request('GET', '/health');
  assert('GET /health returns 200', r.status === 200);
  assert('health response has ok=true', r.body.ok === true);
  assert('health has uptime', typeof r.body.uptime === 'number');
  assert('health has state', typeof r.body.state === 'string');
}

async function testSession() {
  console.log('\n─── Session ───');
  const r = await request('GET', '/session/status');
  assert('GET /session/status returns 200', r.status === 200);
  assert('status has ok', r.body.ok === true);
  assert('status data has state', typeof r.body.data?.state === 'string');
}

async function testChats() {
  console.log('\n─── Chats ───');
  const r = await request('GET', '/chats');
  if (r.status === 503) {
    assert('GET /chats returns 503 when disconnected', true);
  } else {
    assert('GET /chats returns 200', r.status === 200);
    assert('chats data is array', Array.isArray(r.body.data));
  }
}

async function testContacts() {
  console.log('\n─── Contacts ───');
  const r = await request('GET', '/contacts');
  if (r.status === 503) {
    assert('GET /contacts returns 503 when disconnected', true);
  } else {
    assert('GET /contacts returns 200', r.status === 200);
    assert('contacts data is array', Array.isArray(r.body.data));
  }
}

async function testSendValidation() {
  console.log('\n─── Send Validation ───');
  // Missing fields should return 400 (or 503 if disconnected)
  const r = await request('POST', '/messages/send/text', {});
  assert('POST /send/text with empty body returns error', r.status === 400 || r.status === 503);

  const r2 = await request('POST', '/messages/send/text', { jid: '1234@s.whatsapp.net' });
  assert('POST /send/text without text returns error', r2.status === 400 || r2.status === 503);
}

async function testReactValidation() {
  console.log('\n─── React Validation ───');
  const r = await request('POST', '/messages/react', {});
  assert('POST /react with empty body returns error', r.status === 400 || r.status === 503);
}

async function testSearch() {
  console.log('\n─── Search ───');
  const r = await request('GET', '/messages/search?q=test&limit=5');
  if (r.status === 503) {
    assert('GET /search returns 503 when disconnected', true);
  } else {
    assert('GET /search returns 200', r.status === 200);
    assert('search data is array', Array.isArray(r.body.data));
  }

  const r2 = await request('GET', '/messages/search');
  assert('GET /search without q returns 400 or 503', r2.status === 400 || r2.status === 503);
}

async function testHistory() {
  console.log('\n─── History ───');
  const r = await request('GET', '/messages/history/0@s.whatsapp.net?limit=10');
  if (r.status === 503) {
    assert('GET /history returns 503 when disconnected', true);
  } else {
    assert('GET /history returns 200', r.status === 200);
    assert('history data is array', Array.isArray(r.body.data));
  }
}

async function testStarred() {
  console.log('\n─── Starred ───');
  const r = await request('GET', '/messages/starred');
  if (r.status === 503) {
    assert('GET /starred returns 503 when disconnected', true);
  } else {
    assert('GET /starred returns 200', r.status === 200);
    assert('starred data is array', Array.isArray(r.body.data));
  }
}

async function testStatus() {
  console.log('\n─── Status ───');
  const r = await request('GET', '/status');
  if (r.status === 503) {
    assert('GET /status returns 503 when disconnected', true);
  } else {
    assert('GET /status returns 200', r.status === 200);
    assert('status data is array', Array.isArray(r.body.data));
  }
}

async function testGroupValidation() {
  console.log('\n─── Group Validation ───');
  const r = await request('POST', '/groups/create', {});
  assert('POST /groups/create with empty body returns error', r.status === 400 || r.status === 503);

  const r2 = await request('POST', '/groups/create', { name: 'Test' });
  assert('POST /groups/create without participants returns error', r2.status === 400 || r2.status === 503);
}

async function testPollValidation() {
  console.log('\n─── Poll Validation ───');
  const r = await request('POST', '/messages/send/poll', { jid: '1@s.whatsapp.net', name: 'Q', values: ['a'] });
  assert('POST /send/poll with <2 options returns error', r.status === 400 || r.status === 503);
}

async function testWebSocket() {
  console.log('\n─── WebSocket ───');
  return new Promise((resolve) => {
    const ws = new (require('ws'))(`ws://${HOST}:${WS_PORT}`);
    let gotMessage = false;
    ws.on('open', () => { assert('WebSocket connects', true); });
    ws.on('message', (data) => {
      if (!gotMessage) {
        gotMessage = true;
        try {
          const msg = JSON.parse(data.toString());
          assert('WS sends JSON with event field', typeof msg.event === 'string');
          assert('WS sends JSON with data field', msg.data !== undefined);
          assert('WS sends JSON with ts field', typeof msg.ts === 'number');
        } catch {
          assert('WS sends valid JSON', false);
        }
        ws.close();
      }
    });
    ws.on('error', (err) => {
      assert('WebSocket connects', false);
      resolve();
    });
    ws.on('close', () => { resolve(); });
    setTimeout(() => { ws.close(); resolve(); }, 3000);
  });
}

async function main() {
  console.log(`\nWhatsApp.el Server Tests — ${HOST}:${PORT}\n${'═'.repeat(50)}`);

  try {
    await testHealth();
    await testSession();
    await testChats();
    await testContacts();
    await testSendValidation();
    await testReactValidation();
    await testSearch();
    await testHistory();
    await testStarred();
    await testStatus();
    await testGroupValidation();
    await testPollValidation();
    await testWebSocket();
  } catch (err) {
    console.error('\n✗ Server not reachable:', err.message);
    console.error('  Make sure `node server.js` is running.');
    process.exit(1);
  }

  console.log(`\n${'═'.repeat(50)}`);
  console.log(`Results: ${passed} passed, ${failed} failed`);
  if (errors.length > 0) {
    console.log('Failed tests:');
    errors.forEach(e => console.log(`  ✗ ${e}`));
  }
  process.exit(failed > 0 ? 1 : 0);
}

main();
