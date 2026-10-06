import http from 'node:http';
import crypto from 'node:crypto';
import path from 'node:path';
import { createRequire } from 'node:module';
import fs from 'node:fs/promises';

// Dependencies are installed in Orbit's private data directory, never in a user repository.
const [runtime, profile, output] = process.argv.slice(2);
const require = createRequire(path.join(runtime, 'package.json'));
const { createConnection } = require('@playwright/mcp');
const { chromium } = require('playwright');
const { StreamableHTTPServerTransport } = require('@modelcontextprotocol/sdk/server/streamableHttp.js');
const token = process.env.ORBIT_BROWSER_TOKEN;
if (!token || !profile || !output) throw new Error('Missing Orbit browser configuration');
const tools = new Set(['browser_navigate', 'browser_navigate_back', 'browser_snapshot',
  'browser_click', 'browser_hover', 'browser_type', 'browser_press_key', 'browser_select_option',
  'browser_fill_form', 'browser_tabs', 'browser_wait_for', 'browser_resize']);
const sessions = new Map();
const approvals = new Map();
let contextPromise;
async function context() {
  if (!contextPromise) {
    contextPromise = chromium.launchPersistentContext(profile, {
      channel: 'chrome', headless: false, viewport: { width: 1280, height: 800 },
      acceptDownloads: false, chromiumSandbox: true,
    }).catch(error => { contextPromise = undefined; throw error; });
    (await contextPromise).on('close', () => { contextPromise = undefined; });
  }
  return contextPromise;
}
function authorized(req) {
  if (req.headers.origin || !['127.0.0.1', 'localhost'].includes((req.headers.host || '').split(':')[0])) return false;
  const actual = Buffer.from(req.headers.authorization || '');
  const expected = Buffer.from(`Bearer ${token}`);
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}
async function body(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 1024 * 1024) throw new Error('Request too large');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
function toolError(res, message, text) {
  const messages = Array.isArray(message) ? message : [message];
  const errors = messages.filter(item => item.id !== undefined).map(item => ({
    jsonrpc: '2.0', id: item.id,
    result: { isError: true, content: [{ type: 'text', text }] },
  }));
  res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(
    Array.isArray(message) ? errors : errors[0]));
}
async function confirm(page, description, preview) {
  const id = crypto.randomUUID();
  await page.bringToFront();
  const allowed = await new Promise(resolve => {
    const timeout = setTimeout(() => { approvals.delete(id); resolve(false); }, 90000);
    approvals.set(id, answer => { clearTimeout(timeout); approvals.delete(id); resolve(answer); });
    process.stdout.write(JSON.stringify({ approval: { id, description,
      url: page.url(), preview: String(preview || '').slice(0, 1500) } }) + '\n');
  });
  if (!allowed) throw new Error('Azione non confermata nell’app Orbit. Lascia il browser aperto e chiedi all’utente come continuare.');
}
// This guard supplements the agent instructions for recognizable form submissions.
// Web applications can implement arbitrary side effects, so it is not a universal site policy.
async function reviewInteraction(message, session) {
  const name = message.params.name;
  if (!['browser_click', 'browser_type', 'browser_fill_form', 'browser_press_key', 'browser_select_option'].includes(name)) return;
  const browser = await context();
  const page = session.page && !session.page.isClosed() ? session.page : browser.pages()[0];
  if (!page) throw new Error('Leggi prima la pagina con browser_snapshot.');
  const args = message.params.arguments || {};
  const fields = name === 'browser_fill_form' ? args.fields || [] : [args];
  for (const field of fields) {
    const target = field.target || field.ref;
    if (name !== 'browser_press_key' && !/^(f\d+)?e\d+$/.test(target || '')) {
      throw new Error('Usa il riferimento esatto dell’elemento restituito da browser_snapshot.');
    }
    const locator = page.locator(target ? `aria-ref=${target}` : ':focus');
    if (await locator.count() !== 1) throw new Error('Elemento non univoco: aggiorna browser_snapshot prima di interagire.');
    const info = await locator.evaluate(element => {
      const control = element.closest('button, input, textarea, select, [role="button"], [contenteditable="true"]') || element;
      return { tag: control.tagName.toLowerCase(), type: control.getAttribute('type') || '',
        role: control.getAttribute('role') || '', name: control.getAttribute('name') || '',
        autocomplete: control.getAttribute('autocomplete') || '', form: !!control.closest('form'),
        label: [control.getAttribute('aria-label'), control.getAttribute('placeholder'),
          control.labels?.[0]?.innerText, control.innerText].filter(Boolean).join(' ').slice(0, 300) };
    });
    if (info.type === 'password' || /password|one-time-code|cc-number|cc-csc/i.test(info.autocomplete)
      || /password|passcode|captcha|codice di (verifica|accesso)/i.test(info.label)) {
      throw new Error('Accesso e credenziali richiedono l’intervento manuale dell’utente. Usa ORBIT_INPUT_REQUIRED: e lascia il browser aperto.');
    }
    const search = info.type === 'search' || /search|ricerca|cerca|query/i.test(info.label + ' ' + info.name) || info.name === 'q';
    const button = info.tag === 'button' || info.role === 'button' || ['submit', 'image'].includes(info.type);
    const consequential = /publish|pubblica|send|invia|submit|delete|elimina|rimuovi|purchase|checkout|acquista|paga|authorize|autorizza|accept terms|accetta.*termini|^post$/i.test(info.label.trim());
    const submits = name === 'browser_click' && !search && (consequential || (button && info.form && info.type !== 'button'))
      || !search && (name === 'browser_type' && args.submit || name === 'browser_press_key' && /(^|\+)Enter$/.test(args.key || ''))
        && (info.form || info.tag === 'textarea' || info.role === 'textbox');
    if (submits) {
      const preview = name === 'browser_type' ? args.text : await page.locator('textarea, [contenteditable="true"]').evaluateAll(
        elements => elements.map(element => element.value || element.innerText || '').join('\n').slice(0, 1500));
      await confirm(page, `Eseguire «${info.label || args.key || name}»?`, preview);
      if (page.isClosed()) throw new Error('La pagina è stata chiusa durante la conferma.');
    }
  }
}
const server = http.createServer(async (req, res) => {
  try {
    if (!authorized(req)) { res.writeHead(403).end(); return; }
    if (req.url === '/approve' && req.method === 'POST') {
      const answer = await body(req);
      const pending = approvals.get(answer.id);
      if (!pending || typeof answer.allowed !== 'boolean') { res.writeHead(404).end(); return; }
      pending(answer.allowed);
      res.writeHead(200, { 'Content-Type': 'application/json' }).end('{}');
      return;
    }
    if (req.url === '/open' && req.method === 'POST') {
      const browser = await context();
      const page = browser.pages()[0] || await browser.newPage();
      await page.bringToFront();
      res.writeHead(200, { 'Content-Type': 'application/json' }).end('{}');
      return;
    }
    if (req.url !== '/mcp') { res.writeHead(404).end(); return; }
    const message = req.method === 'POST' ? await body(req) : undefined;
    const calls = (Array.isArray(message) ? message : [message]).filter(item => item?.method === 'tools/call');
    if (calls.some(call => !tools.has(call.params?.name))) {
      toolError(res, message, 'Tool unavailable in Orbit. Use navigation and page interaction tools.');
      return;
    }
    if (calls.length > 1) {
      toolError(res, message, 'Orbit esegue una sola interazione per richiesta. Invia separatamente gli strumenti.');
      return;
    }
    const id = req.headers['mcp-session-id'];
    let session = sessions.get(id);
    if (!session && !id && message?.method === 'initialize') {
      const connection = await createConnection({
        browser: { browserName: 'chromium' }, capabilities: [],
        outputDir: output, webMCP: false,
      }, context);
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => crypto.randomUUID(), enableJsonResponse: true,
        onsessioninitialized: id => sessions.set(id, { connection, transport }),
      });
      transport.onclose = () => sessions.delete(transport.sessionId);
      await connection.connect(transport);
      session = { connection, transport };
    }
    if (!session) { res.writeHead(id ? 404 : 400).end('Initialize the MCP session'); return; }
    if (calls.length) {
      try { await reviewInteraction(calls[0], session); }
      catch (error) { toolError(res, message, error.message); return; }
    }
    await session.transport.handleRequest(req, res, message);
    if (calls[0]?.params?.name === 'browser_tabs' && contextPromise) {
      const pages = (await contextPromise).pages();
      const args = calls[0].params.arguments || {};
      if (args.action === 'new') session.page = pages.at(-1);
      if (args.action === 'select' && pages[args.index]) session.page = pages[args.index];
      if (session.page?.isClosed()) session.page = pages[Math.min(args.index || 0, pages.length - 1)];
    }
  } catch (error) {
    console.error(error.message);
    if (!res.headersSent) res.writeHead(500).end('Orbit browser request failed');
    else res.end();
  }
});
await fs.mkdir(profile, { recursive: true, mode: 0o700 });
await fs.mkdir(output, { recursive: true, mode: 0o700 });
server.listen(0, '127.0.0.1', () => {
  process.stdout.write(JSON.stringify({ url: `http://127.0.0.1:${server.address().port}/mcp` }) + '\n');
});
async function close() {
  server.close();
  for (const session of sessions.values()) await session.connection.close().catch(() => {});
  if (contextPromise) await (await contextPromise).close().catch(() => {});
  process.exit(0);
}
process.on('SIGTERM', close);
process.on('SIGINT', close);
const parent = process.ppid;
setInterval(() => {
  try { process.kill(parent, 0); } catch { void close(); }
}, 3000).unref();
