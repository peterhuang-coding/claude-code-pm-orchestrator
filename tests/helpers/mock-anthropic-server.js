#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const crypto = require('crypto');

const [portText, scenarioPath, recordsPath, readyPath] = process.argv.slice(2);
if (!readyPath) {
  console.error('usage: mock-anthropic-server PORT SCENARIO RECORDS READY');
  process.exit(2);
}

let scenarioSource = null;
function scenarios() {
  const text = fs.readFileSync(scenarioPath, 'utf8').trim();
  scenarioSource = text;
  if (!text) return [];
  try {
    const value = JSON.parse(text);
    return Array.isArray(value) ? value : [value];
  } catch {
    return text.split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
  }
}

let queue = scenarios();
const server = http.createServer((request, response) => {
  const currentSource = fs.readFileSync(scenarioPath, 'utf8').trim();
  if (currentSource !== scenarioSource || !fs.existsSync(recordsPath) || fs.statSync(recordsPath).size === 0) {
    queue = scenarios();
  }
  const chunks = [];
  request.on('data', (chunk) => chunks.push(chunk));
  request.on('end', () => {
    const rawBody = Buffer.concat(chunks);
    const item = queue.length ? queue.shift() : { status: 500, body: { error: { type: 'scenario_exhausted' } } };
    let model = null;
    let payloadValid = false;
    try {
      const payload = JSON.parse(rawBody.toString('utf8'));
      model = payload.model ?? null;
      payloadValid =
        Array.isArray(payload.messages) &&
        payload.messages.length === 1 &&
        payload.messages[0].role === 'user' &&
        payload.messages[0].content === 'PROMPT_MARKER_DO_NOT_LEAK' &&
        payload.max_tokens === 17 &&
        payload.stream === false &&
        payload.tools?.[0]?.name === 'weather' &&
        payload.tools?.[0]?.input_schema?.properties?.city?.type === 'string' &&
        payload.metadata?.user_id === 'test-user' &&
        payload.extra?.keep === true &&
        Object.keys(payload).sort().join(',') === 'extra,max_tokens,messages,metadata,model,stream,tools';
    } catch {}
    const safeHeaders = {};
    for (const name of ['anthropic-version', 'anthropic-beta', 'content-type', 'accept', 'user-agent', 'x-request-id']) {
      if (request.headers[name] !== undefined) safeHeaders[name] = request.headers[name];
    }
    const authDigest = crypto.createHash('sha256').update(request.headers.authorization || '').digest('hex');
    fs.appendFileSync(recordsPath, JSON.stringify({
      path: request.url,
      model,
      headers: safeHeaders,
      payload_valid: payloadValid,
      auth_valid: item.expectedAuthSha256 ? authDigest === item.expectedAuthSha256 : null,
      host_valid: request.headers.host === `127.0.0.1:${server.address().port}`,
      content_length_valid: Number(request.headers['content-length']) === rawBody.length,
    }) + '\n', { mode: 0o600 });

    if (item.disconnect) {
      request.socket.destroy();
      return;
    }
    if (item.expectedAuthSha256) {
      const actual = crypto.createHash('sha256').update(request.headers.authorization || '').digest('hex');
      if (actual !== item.expectedAuthSha256) {
        response.writeHead(401, { 'content-type': 'application/json' });
        response.end('{"error":{"type":"unexpected_upstream_auth"}}');
        return;
      }
    }
    const body = item.largeErrorBytes
      ? JSON.stringify({ error: { type: item.errorType || 'large_error', message: 'X'.repeat(item.largeErrorBytes) } })
      : typeof item.body === 'string' ? item.body : JSON.stringify(item.body ?? {});
    response.writeHead(item.status ?? 200, {
      'content-type': item.contentType ?? 'application/json',
      'x-request-id': item.requestId ?? 'mock-request',
      ...(item.headers ?? {}),
    });
    response.end(body);
  });
});

server.listen(Number(portText), '127.0.0.1', () => {
  fs.writeFileSync(readyPath, String(server.address().port), { mode: 0o600 });
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
