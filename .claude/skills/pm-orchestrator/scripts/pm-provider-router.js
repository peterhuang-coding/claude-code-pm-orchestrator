#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const SERVICE = 'claude-pm-provider-router';
const MAX_INBOUND = 32 * 1024 * 1024;
const MAX_ERROR = 64 * 1024;
const MAX_RETRY_AFTER = 24 * 60 * 60;
const MAX_RETRIES = 3;
const COOLDOWN_CATEGORIES = ['network', 'auth', 'quota', 'rate_limit', 'server', 'stream'];
const HOME = path.resolve((process.env.PM_PROVIDER_HOME || '~/.claude/provider-router').replace(/^~/, os.homedir()));
const CONFIG_PATH = path.join(HOME, 'config.json');
const STATE_PATH = path.join(HOME, 'state.json');
const DEFAULT_STATE = { active: false, mode: 'auto', cooldowns: {}, current_provider: null, last_transition: null };

function fatal(message) {
  console.error(`pm-provider-router: ${message}`);
  process.exit(1);
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    fatal(`could not read ${label}`);
  }
}

function validListenHost(host) {
  return host === '127.0.0.1' || host === '::1' || host === 'localhost';
}

const config = readJson(CONFIG_PATH, 'config');
function invalidConfig(detail) {
  fatal(`invalid config: ${detail}`);
}

function validateConfig(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalidConfig('root must be an object');
  if (value.version !== 1) invalidConfig('unsupported version');
  if (!value.listen || typeof value.listen !== 'object' || Array.isArray(value.listen)) invalidConfig('listen must be an object');
  if (!validListenHost(value.listen.host)) invalidConfig('listen.host must be loopback');
  if (!Number.isInteger(value.listen.port) || value.listen.port < 1 || value.listen.port > 65535) {
    invalidConfig('listen.port must be an integer from 1 to 65535');
  }
  if (!Array.isArray(value.providers) || value.providers.length === 0 || value.providers.length > 32) {
    invalidConfig('providers must contain 1 to 32 entries');
  }
  const providerIds = new Set();
  for (const provider of value.providers) {
    if (!provider || typeof provider !== 'object' || Array.isArray(provider)) invalidConfig('provider must be an object');
    if (typeof provider.id !== 'string' || !/^[A-Za-z0-9._-]{1,64}$/.test(provider.id) || providerIds.has(provider.id)) {
      invalidConfig('provider id must be unique and safe');
    }
    providerIds.add(provider.id);
    if (typeof provider.model !== 'string' || provider.model.length < 1 || provider.model.length > 256) {
      invalidConfig(`provider ${provider.id} has invalid model`);
    }
    let base;
    try {
      base = new URL(provider.base_url);
    } catch {
      invalidConfig(`provider ${provider.id} has invalid base_url`);
    }
    if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password) {
      invalidConfig(`provider ${provider.id} has invalid base_url`);
    }
    if (provider.auth_scheme !== 'bearer') invalidConfig(`provider ${provider.id} has invalid auth_scheme`);
  }
  if (!value.retry || typeof value.retry !== 'object' || Array.isArray(value.retry)) invalidConfig('retry must be an object');
  for (const category of ['network', 'server']) {
    const retries = value.retry[category];
    if (!Number.isInteger(retries) || retries < 0 || retries > MAX_RETRIES) {
      invalidConfig(`retry.${category} must be an integer from 0 to ${MAX_RETRIES}`);
    }
  }
  if (!value.cooldown_seconds || typeof value.cooldown_seconds !== 'object' || Array.isArray(value.cooldown_seconds)) {
    invalidConfig('cooldown_seconds must be an object');
  }
  for (const category of COOLDOWN_CATEGORIES) {
    const seconds = value.cooldown_seconds[category];
    if (!Number.isInteger(seconds) || seconds < 0 || seconds > MAX_RETRY_AFTER) {
      invalidConfig(`cooldown_seconds.${category} must be an integer from 0 to ${MAX_RETRY_AFTER}`);
    }
  }
}

validateConfig(config);

function readState() {
  let value = {};
  try {
    value = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8'));
  } catch {}
  const state = { ...DEFAULT_STATE, ...(value && typeof value === 'object' ? value : {}) };
  if (!state.cooldowns || typeof state.cooldowns !== 'object' || Array.isArray(state.cooldowns)) state.cooldowns = {};
  return state;
}

function atomicWriteState(state) {
  const temporary = path.join(HOME, `.state.json.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  let descriptor = null;
  const safe = {
    active: Boolean(state.active),
    mode: typeof state.mode === 'string' ? state.mode : 'auto',
    cooldowns: state.cooldowns && typeof state.cooldowns === 'object' ? state.cooldowns : {},
    current_provider: typeof state.current_provider === 'string' ? state.current_provider : null,
    last_transition: state.last_transition && typeof state.last_transition === 'object' ? state.last_transition : null,
  };
  try {
    fs.mkdirSync(HOME, { recursive: true, mode: 0o700 });
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    fs.fchmodSync(descriptor, 0o600);
    fs.writeFileSync(descriptor, `${JSON.stringify(safe, null, 2)}\n`);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = null;
    fs.chmodSync(temporary, 0o600);
    fs.renameSync(temporary, STATE_PATH);
    fs.chmodSync(STATE_PATH, 0o600);
    try {
      const directory = fs.openSync(HOME, 'r');
      try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
    } catch {}
  } catch {
    if (descriptor !== null) {
      try { fs.closeSync(descriptor); } catch {}
    }
    try { fs.unlinkSync(temporary); } catch {}
    fatal('could not write state');
  }
}

function credential(account) {
  const fakeDir = process.env.PM_PROVIDER_KEYCHAIN_DIR;
  if (fakeDir) {
    try {
      return fs.readFileSync(path.join(fakeDir, account), 'utf8').replace(/\r?\n$/, '');
    } catch {
      return null;
    }
  }
  try {
    return execFileSync('/usr/bin/security', [
      'find-generic-password', '-w', '-s', SERVICE, '-a', account,
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).replace(/\r?\n$/, '');
  } catch {
    return null;
  }
}

const localToken = credential('router-local');
if (!localToken) fatal('router-local credential unavailable');

function timingSafeToken(value) {
  const prefix = 'Bearer ';
  if (typeof value !== 'string' || !value.startsWith(prefix)) return false;
  const supplied = Buffer.from(value.slice(prefix.length));
  const expected = Buffer.from(localToken);
  if (supplied.length !== expected.length) {
    crypto.timingSafeEqual(expected, expected);
    return false;
  }
  return crypto.timingSafeEqual(supplied, expected);
}

function jsonResponse(response, status, value, extraHeaders = {}) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    ...extraHeaders,
    'content-type': 'application/json',
    'content-length': body.length,
  });
  response.end(body);
}

function safeResponseHeaders(headers) {
  const safe = {};
  for (const name of ['content-type', 'retry-after', 'request-id', 'x-request-id']) {
    if (headers[name] !== undefined) safe[name] = headers[name];
  }
  return safe;
}

function upstreamHeaders(inbound, key, authScheme) {
  const result = {};
  for (const name of ['content-type', 'accept', 'anthropic-version', 'anthropic-beta', 'user-agent', 'x-request-id']) {
    if (inbound[name] !== undefined) result[name] = inbound[name];
  }
  result.authorization = `${authScheme === 'bearer' ? 'Bearer' : authScheme} ${key}`;
  return result;
}

function joinedUrl(base, inboundUrl) {
  const source = new URL(inboundUrl, 'http://router.invalid');
  const target = new URL(base);
  target.pathname = `${target.pathname.replace(/\/$/, '')}/${source.pathname.replace(/^\//, '')}`;
  target.search = source.search;
  return target;
}

function boundedBody(chunks) {
  const body = Buffer.concat(chunks);
  return body.length > MAX_ERROR ? body.subarray(0, MAX_ERROR) : body;
}

function classify(status, body) {
  if (status >= 200 && status < 300) return 'success';
  if (status === 401 || status === 403) return 'auth';
  if (status === 402) return 'quota';
  if (status === 429) return 'rate_limit';
  if (status >= 500) return 'server';
  if (status >= 400 && status < 500) {
    const text = body.subarray(0, MAX_ERROR).toString('utf8').toLowerCase();
    if (text.includes('context_window') || text.includes('model_context_window_exceeded')) return 'context';
    return 'request';
  }
  return 'request';
}

function retryAfterSeconds(headers) {
  const raw = headers['retry-after'];
  if (!raw) return 0;
  const numeric = Number(raw);
  if (Number.isFinite(numeric) && numeric >= 0) return Math.min(MAX_RETRY_AFTER, Math.ceil(numeric));
  const date = Date.parse(raw);
  return Number.isFinite(date) ? Math.min(MAX_RETRY_AFTER, Math.max(0, Math.ceil((date - Date.now()) / 1000))) : 0;
}

function requestId(headers) {
  const value = String(headers['x-request-id'] || headers['request-id'] || '');
  return value.replace(/[^A-Za-z0-9._:-]/g, '').slice(0, 256) || null;
}

function upstreamErrorType(body) {
  try {
    const value = JSON.parse(body.toString('utf8'));
    const type = value && value.error && value.error.type;
    if (typeof type === 'string') return type.replace(/[^A-Za-z0-9._:-]/g, '').slice(0, 128) || null;
  } catch {}
  const match = body.toString('utf8').match(/"type"\s*:\s*"([A-Za-z0-9._:-]{1,128})"/);
  return match ? match[1] : null;
}

function transition(state, provider, category, status, headers) {
  const now = Math.floor(Date.now() / 1000);
  const configured = Number(config.cooldown_seconds && config.cooldown_seconds[category]) || 0;
  const duration = category === 'rate_limit' ? Math.max(configured, retryAfterSeconds(headers)) : configured;
  if (category !== 'success' && duration > 0) {
    state.cooldowns[provider] = { reason: category, until: now + Math.min(MAX_RETRY_AFTER, duration) };
  } else if (category === 'success') {
    delete state.cooldowns[provider];
    state.current_provider = provider;
  }
  state.last_transition = {
    provider,
    category,
    status: Number.isInteger(status) ? status : null,
    cooldown_until: state.cooldowns[provider] ? state.cooldowns[provider].until : null,
    timestamp: now,
    request_id: requestId(headers),
  };
  atomicWriteState(state);
}

function backoff(attempt) {
  const override = Number(process.env.PM_PROVIDER_BACKOFF_MS);
  const delays = Number.isFinite(override) && override >= 0 ? [override, override] : [250, 750];
  return new Promise((resolve) => setTimeout(resolve, delays[Math.min(attempt, delays.length - 1)]));
}

function upstreamOnce(profile, key, inbound, body) {
  return new Promise((resolve) => {
    let target;
    try {
      target = joinedUrl(profile.base_url, inbound.url);
    } catch {
      resolve({ category: 'network', status: null, headers: {}, body: Buffer.alloc(0) });
      return;
    }
    const transport = target.protocol === 'https:' ? https : http;
    const request = transport.request(target, {
      method: inbound.method,
      headers: upstreamHeaders(inbound.headers, key, profile.auth_scheme),
    }, (response) => {
      const chunks = [];
      let captured = 0;
      response.on('data', (chunk) => {
        if (response.statusCode < 400) {
          chunks.push(chunk);
        } else if (captured < MAX_ERROR) {
          const part = chunk.subarray(0, MAX_ERROR - captured);
          chunks.push(part);
          captured += part.length;
        }
      });
      response.on('end', () => {
        const responseBody = response.statusCode >= 400 ? boundedBody(chunks) : Buffer.concat(chunks);
        resolve({
          category: classify(response.statusCode, responseBody),
          status: response.statusCode,
          headers: response.headers,
          body: responseBody,
        });
      });
    });
    request.on('error', () => resolve({ category: 'network', status: null, headers: {}, body: Buffer.alloc(0) }));
    const timeout = Math.max(1, Math.min(120000, Number(process.env.PM_PROVIDER_UPSTREAM_TIMEOUT_MS) || 30000));
    request.setTimeout(timeout, () => request.destroy());
    request.end(body);
  });
}

async function tryProvider(profile, key, inbound, body) {
  let attempt = 0;
  while (true) {
    const result = await upstreamOnce(profile, key, inbound, body);
    const limit = Number(config.retry && config.retry[result.category]) || 0;
    if ((result.category === 'network' || result.category === 'server') && attempt < limit) {
      await backoff(attempt++);
      continue;
    }
    return result;
  }
}

function candidates(state) {
  if (state.mode !== 'auto') return config.providers.filter((item) => item.id === state.mode).slice(0, 1);
  const now = Math.floor(Date.now() / 1000);
  return config.providers.filter((item) => {
    const cooldown = state.cooldowns[item.id];
    return !cooldown || !Number.isFinite(Number(cooldown.until)) || Number(cooldown.until) <= now;
  });
}

async function routeMessages(inbound, response, rawBody) {
  let parsed;
  try {
    parsed = JSON.parse(rawBody.toString('utf8'));
  } catch {
    jsonResponse(response, 400, { error: { type: 'invalid_request', message: 'request body must be JSON' } });
    return;
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    jsonResponse(response, 400, { error: { type: 'invalid_request', message: 'request body must be a JSON object' } });
    return;
  }

  const state = readState();
  const attempted = [];
  let lastFailure = null;
  for (const profile of candidates(state)) {
    const key = credential(profile.id);
    if (!key) continue;
    attempted.push(profile.id);
    const body = Buffer.from(JSON.stringify({ ...parsed, model: profile.model }));
    const result = await tryProvider(profile, key, inbound, body);
    if (result.category === 'success') {
      transition(state, profile.id, 'success', result.status, result.headers);
      response.writeHead(result.status, safeResponseHeaders(result.headers));
      response.end(result.body);
      return;
    }
    if (result.category === 'context' || result.category === 'request') {
      transition(state, profile.id, result.category, result.status, result.headers);
      response.writeHead(result.status, safeResponseHeaders(result.headers));
      response.end(result.body);
      return;
    }
    lastFailure = result;
    transition(state, profile.id, result.category, result.status, result.headers);
    if (state.mode !== 'auto') break;
  }
  const finalStatus = lastFailure && Number.isInteger(lastFailure.status) ? lastFailure.status : 503;
  const finalHeaders = lastFailure ? safeResponseHeaders(lastFailure.headers) : {};
  jsonResponse(response, finalStatus, {
    error: {
      type: 'providers_unavailable',
      message: 'All eligible providers failed before the response started',
      category: lastFailure ? lastFailure.category : 'unavailable',
      upstream_status: lastFailure ? lastFailure.status : null,
      upstream_error_type: lastFailure ? upstreamErrorType(lastFailure.body) : null,
      request_id: lastFailure ? requestId(lastFailure.headers) : null,
      attempted_providers: attempted.slice(0, config.providers.length),
      router: {
        mode: state.mode === 'auto' ? 'auto' : 'manual',
        exhausted: true,
      },
    },
  }, finalHeaders);
}

const server = http.createServer((request, response) => {
  if (request.method === 'GET' && request.url.split('?')[0] === '/_pm/health') {
    jsonResponse(response, 200, { status: 'ok' });
    return;
  }
  if (!timingSafeToken(request.headers.authorization)) {
    request.resume();
    jsonResponse(response, 401, { error: { type: 'unauthorized' } });
    return;
  }
  const pathname = new URL(request.url, 'http://router.invalid').pathname;
  if (request.method !== 'POST' || (pathname !== '/v1/messages' && pathname !== '/v1/messages/count_tokens')) {
    request.resume();
    jsonResponse(response, 404, { error: { type: 'not_found' } });
    return;
  }
  const chunks = [];
  let size = 0;
  let rejected = false;
  request.on('data', (chunk) => {
    size += chunk.length;
    if (size > MAX_INBOUND) {
      rejected = true;
      chunks.length = 0;
      if (!response.headersSent) jsonResponse(response, 413, { error: { type: 'request_too_large' } });
      return;
    }
    chunks.push(chunk);
  });
  request.on('end', () => {
    if (!rejected) routeMessages(request, response, Buffer.concat(chunks)).catch(() => {
      if (!response.headersSent) jsonResponse(response, 500, { error: { type: 'router_error' } });
      else response.end();
    });
  });
});

server.on('error', () => fatal('could not listen on configured loopback address'));
server.listen(config.listen.port, config.listen.host);
