#!/usr/bin/env node
import { appendFile, mkdir, open, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { createHmac } from 'node:crypto';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const rootDir = dirname(fileURLToPath(import.meta.url));
const stateDir = join(rootDir, 'state');
const configPath = join(rootDir, 'config.json');
const exampleConfigPath = join(rootDir, 'config.example.json');
const queuePath = join(stateDir, 'queue.jsonl');
const tokenCachePath = join(stateDir, 'feishu-token.json');
const logPath = join(stateDir, 'agent-notify.log');
const lockPath = join(stateDir, 'queue.lock');
const originalCodexNotifyPath = join(stateDir, 'codex-notify-original.json');

const defaultConfig = {
  enabled: true,
  agents: {
    claude: true,
    codex: true,
  },
  events: {
    claude: {
      Stop: true,
      Notification: true,
      TaskCompleted: true,
    },
    codex: {
      notify: true,
    },
  },
  privacy: {
    includePayloadPreview: false,
    maxPreviewChars: 160,
  },
  message: {
    prefix: '[Agent]',
    timezone: 'Asia/Shanghai',
  },
  feishu: {
    enabled: true,
    mode: 'webhook',
    webhookUrl: '',
    webhookSecret: '',
    appId: '',
    appSecret: '',
    receiverId: '',
    receiverType: 'open_id',
  },
};

function exitOk() {
  process.exitCode = 0;
}

function getArg(name, fallback = '') {
  const long = `--${name}`;
  const hit = process.argv.findIndex((arg) => arg === long || arg.startsWith(`${long}=`));
  if (hit === -1) return fallback;
  const value = process.argv[hit];
  if (value.includes('=')) return value.slice(value.indexOf('=') + 1);
  return process.argv[hit + 1] && !process.argv[hit + 1].startsWith('--')
    ? process.argv[hit + 1]
    : fallback;
}

function hasFlag(name) {
  return process.argv.includes(`--${name}`);
}

async function ensureStateDir() {
  await mkdir(stateDir, { recursive: true });
}

async function logLine(level, message, meta = {}) {
  try {
    await ensureStateDir();
    const item = {
      time: new Date().toISOString(),
      level,
      message,
      ...meta,
    };
    await appendFile(logPath, `${JSON.stringify(item)}\n`, 'utf8');
  } catch {
    // Hook must never disturb the coding agent.
  }
}

async function readJsonIfExists(path, fallback) {
  try {
    const text = await readFile(path, 'utf8');
    return JSON.parse(text.replace(/^\uFEFF/, ''));
  } catch {
    return fallback;
  }
}

function deepMerge(base, patch) {
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) return base;
  const out = { ...base };
  for (const [key, value] of Object.entries(patch)) {
    if (
      value &&
      typeof value === 'object' &&
      !Array.isArray(value) &&
      base[key] &&
      typeof base[key] === 'object' &&
      !Array.isArray(base[key])
    ) {
      out[key] = deepMerge(base[key], value);
    } else {
      out[key] = value;
    }
  }
  return out;
}

function envBool(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(raw).toLowerCase());
}

async function loadConfig() {
  const fileConfig = await readJsonIfExists(configPath, null)
    ?? await readJsonIfExists(exampleConfigPath, {});
  const cfg = deepMerge(defaultConfig, fileConfig);

  cfg.enabled = envBool('AGENT_NOTIFY_ENABLED', cfg.enabled);
  cfg.agents.claude = envBool('AGENT_NOTIFY_CLAUDE', cfg.agents.claude);
  cfg.agents.codex = envBool('AGENT_NOTIFY_CODEX', cfg.agents.codex);
  cfg.feishu.enabled = envBool('AGENT_NOTIFY_FEISHU', cfg.feishu.enabled);

  cfg.feishu.webhookUrl =
    process.env.AGENT_NOTIFY_FEISHU_WEBHOOK_URL ||
    process.env.FEISHU_WEBHOOK_URL ||
    cfg.feishu.webhookUrl;
  cfg.feishu.webhookSecret =
    process.env.AGENT_NOTIFY_FEISHU_WEBHOOK_SECRET ||
    process.env.FEISHU_WEBHOOK_SECRET ||
    cfg.feishu.webhookSecret;
  cfg.feishu.appId =
    process.env.AGENT_NOTIFY_FEISHU_APP_ID ||
    process.env.FEISHU_APP_ID ||
    cfg.feishu.appId;
  cfg.feishu.appSecret =
    process.env.AGENT_NOTIFY_FEISHU_APP_SECRET ||
    process.env.FEISHU_APP_SECRET ||
    cfg.feishu.appSecret;
  cfg.feishu.receiverId =
    process.env.AGENT_NOTIFY_FEISHU_RECEIVER_ID ||
    process.env.FEISHU_RECEIVER_ID ||
    cfg.feishu.receiverId;
  cfg.feishu.receiverType =
    process.env.AGENT_NOTIFY_FEISHU_RECEIVER_TYPE ||
    process.env.FEISHU_RECEIVER_TYPE ||
    cfg.feishu.receiverType;

  return cfg;
}

async function readStdin() {
  if (process.stdin.isTTY) return '';
  return new Promise((resolve) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      data += chunk;
    });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', () => resolve(data));
  });
}

function parsePayload(raw) {
  const candidates = [];
  if (raw && raw.trim()) candidates.push(raw.trim());
  const lastArg = process.argv[process.argv.length - 1];
  if (lastArg && lastArg.trim().startsWith('{')) candidates.push(lastArg.trim());

  for (const item of candidates) {
    try {
      return JSON.parse(item);
    } catch {
      // Try next input source.
    }
  }
  return {};
}

function firstString(...values) {
  for (const value of values) {
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return '';
}

function previewText(text, maxChars) {
  const value = String(text || '').replace(/\s+/g, ' ').trim();
  if (!value) return '';
  return value.length > maxChars ? `${value.slice(0, Math.max(0, maxChars - 3))}...` : value;
}

function inferProjectName(cwd) {
  if (!cwd) return '';
  return cwd.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || cwd;
}

function normalizeEvent({ agent, event, payload, cfg }) {
  const context = payload.context && typeof payload.context === 'object' ? payload.context : {};
  const cwd = firstString(payload.cwd, payload.project_path, context.project_path, process.cwd());
  const hookEvent = firstString(event, payload.hook_event_name, payload.event, payload.type, 'notify');
  const sessionId = firstString(
    payload.session_id,
    payload['session-id'],
    payload.sessionId,
    context.session_id,
  );
  const turnId = firstString(payload.turn_id, payload['turn-id'], payload.turnId, context.turn_id);
  const message = firstString(
    payload.message,
    payload.notification,
    payload['last-assistant-message'],
    payload.last_assistant_message,
    payload.output_preview,
    context.output_preview,
    context.status,
  );

  return {
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    time: new Date().toISOString(),
    agent,
    event: hookEvent,
    cwd,
    project: firstString(payload.project_name, context.project_name, inferProjectName(cwd)),
    sessionId,
    turnId,
    message: cfg.privacy.includePayloadPreview
      ? previewText(message, Number(cfg.privacy.maxPreviewChars || 160))
      : '',
  };
}

function isEventEnabled(cfg, item) {
  if (!cfg.enabled) return false;
  if (!cfg.agents[item.agent]) return false;
  const agentEvents = cfg.events[item.agent] || {};
  if (agentEvents[item.event] === false) return false;
  if (agentEvents[item.event] === true) return true;
  if (item.agent === 'codex' && agentEvents.notify) return true;
  return false;
}

function formatLocalTime(iso, timezone) {
  try {
    return new Intl.DateTimeFormat('zh-CN', {
      timeZone: timezone || 'Asia/Shanghai',
      hour12: false,
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
    }).format(new Date(iso));
  } catch {
    return iso;
  }
}

function formatMessage(cfg, item) {
  const label = item.agent === 'claude' ? 'Claude Code' : 'Codex';
  const lines = [
    `${cfg.message.prefix || '[Agent]'} ${label} ${item.event} 已结束`,
    `项目: ${item.project || '-'}`,
    `目录: ${item.cwd || '-'}`,
    `时间: ${formatLocalTime(item.time, cfg.message.timezone)}`,
  ];
  if (item.message) lines.push(`摘要: ${item.message}`);
  return lines.join('\n');
}

async function enqueue(item) {
  await ensureStateDir();
  await appendFile(queuePath, `${JSON.stringify(item)}\n`, 'utf8');
}

async function withQueueLock(fn) {
  await ensureStateDir();
  let handle;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      handle = await open(lockPath, 'wx');
      break;
    } catch {
      if (attempt === 3) return false;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  try {
    await writeFile(lockPath, String(process.pid), 'utf8').catch(() => {});
    await fn();
  } finally {
    await handle.close().catch(() => {});
    await rm(lockPath, { force: true }).catch(() => {});
  }
  return true;
}

async function takeQueueBatch() {
  if (!existsSync(queuePath)) return null;
  const size = await stat(queuePath).then((s) => s.size).catch(() => 0);
  if (!size) return null;
  const batchPath = join(stateDir, `queue-${Date.now()}-${process.pid}.jsonl`);
  await rename(queuePath, batchPath).catch(() => null);
  return existsSync(batchPath) ? batchPath : null;
}

async function readQueueBatch(path) {
  const raw = await readFile(path, 'utf8').catch(() => '');
  return raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

async function restoreFailed(items) {
  if (!items.length) return;
  await appendFile(queuePath, items.map((item) => JSON.stringify(item)).join('\n') + '\n', 'utf8');
}

async function fetchJson(url, options, timeoutMs = 8000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      ...options,
      signal: controller.signal,
    });
    const text = await res.text();
    let body = {};
    try {
      body = text ? JSON.parse(text) : {};
    } catch {
      body = { raw: text };
    }
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
    }
    return body;
  } finally {
    clearTimeout(timer);
  }
}

function signFeishuWebhook(secret) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const stringToSign = `${timestamp}\n${secret}`;
  const sign = createHmac('sha256', stringToSign).update('').digest('base64');
  return { timestamp, sign };
}

async function sendFeishuWebhook(feishu, text) {
  if (!feishu.webhookUrl) throw new Error('feishu.webhookUrl is empty');

  const payload = {
    msg_type: 'text',
    content: { text },
  };
  if (feishu.webhookSecret) {
    Object.assign(payload, signFeishuWebhook(feishu.webhookSecret));
  }

  const body = await fetchJson(feishu.webhookUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (body.code !== undefined && Number(body.code) !== 0) {
    throw new Error(`Feishu webhook rejected: ${JSON.stringify(body).slice(0, 300)}`);
  }
  return body;
}

async function getFeishuToken(feishu) {
  const cached = await readJsonIfExists(tokenCachePath, null);
  const now = Math.floor(Date.now() / 1000);
  if (cached?.token && Number(cached.expiresAt || 0) > now + 60) return cached.token;

  if (!feishu.appId || !feishu.appSecret) {
    throw new Error('feishu.appId/appSecret are empty');
  }

  const body = await fetchJson('https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      app_id: feishu.appId,
      app_secret: feishu.appSecret,
    }),
  });
  if (!body.tenant_access_token) {
    throw new Error(`Feishu token failed: ${JSON.stringify(body).slice(0, 300)}`);
  }

  const token = body.tenant_access_token;
  const expiresAt = now + Number(body.expire || 7200) - 300;
  await writeFile(tokenCachePath, JSON.stringify({ token, expiresAt }, null, 2), 'utf8');
  return token;
}

async function sendFeishuApp(feishu, text) {
  if (!feishu.receiverId) throw new Error('feishu.receiverId is empty');
  const token = await getFeishuToken(feishu);
  const receiverType = feishu.receiverType || 'open_id';
  const body = await fetchJson(
    `https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=${encodeURIComponent(receiverType)}`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        receive_id: feishu.receiverId,
        msg_type: 'text',
        content: JSON.stringify({ text }),
      }),
    },
  );
  if (Number(body.code) !== 0) {
    throw new Error(`Feishu message failed: ${JSON.stringify(body).slice(0, 300)}`);
  }
  return body;
}

async function sendFeishu(cfg, item) {
  if (!cfg.feishu.enabled) return { skipped: true, reason: 'feishu disabled' };
  const text = formatMessage(cfg, item);
  if ((cfg.feishu.mode || 'webhook') === 'app') {
    return sendFeishuApp(cfg.feishu, text);
  }
  return sendFeishuWebhook(cfg.feishu, text);
}

async function flushQueue({ dryRun = false, verbose = false } = {}) {
  const cfg = await loadConfig();
  await withQueueLock(async () => {
    const batchPath = await takeQueueBatch();
    if (!batchPath) return;

    const items = await readQueueBatch(batchPath);
    const failed = [];
    for (const item of items) {
      if (!isEventEnabled(cfg, item)) continue;
      if (dryRun) {
        if (verbose) console.log(formatMessage(cfg, item));
        continue;
      }
      try {
        await sendFeishu(cfg, item);
        await logLine('info', 'notification sent', { agent: item.agent, event: item.event });
      } catch (error) {
        failed.push(item);
        await logLine('warn', 'notification send failed', {
          agent: item.agent,
          event: item.event,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
    await restoreFailed(failed);
    await rm(batchPath, { force: true }).catch(() => {});
  });
}

async function emitCommand({ agent, event, payload, dryRun = false, verbose = false }) {
  const cfg = await loadConfig();
  const item = normalizeEvent({ agent, event, payload, cfg });
  if (!isEventEnabled(cfg, item)) {
    if (verbose) console.log('disabled');
    return;
  }

  await enqueue(item);
  await flushQueue({ dryRun, verbose });
}

async function codexNotifyCommand() {
  const raw = await readStdin();
  const payload = parsePayload(raw);
  const payloadText = raw && raw.trim() ? raw.trim() : JSON.stringify(payload);

  // 先 fanout 原始 notify，再做自己的发送；原始链路失败也不影响 Codex。
  try {
    const { readFileSync } = await import('node:fs');
    if (existsSync(originalCodexNotifyPath)) {
      const original = JSON.parse(readFileSync(originalCodexNotifyPath, 'utf8').replace(/^\uFEFF/, ''));
      const argv = Array.isArray(original.argv) ? original.argv.filter(Boolean) : [];
      if (argv.length) {
        const child = spawn(argv[0], [...argv.slice(1), payloadText], {
          cwd: process.cwd(),
          env: process.env,
          stdio: ['pipe', 'ignore', 'ignore'],
          windowsHide: true,
        });
        child.stdin.end(payloadText);
      }
    }
  } catch (error) {
    await logLine('warn', 'original codex notify failed', {
      error: error instanceof Error ? error.message : String(error),
    });
  }

  await emitCommand({
    agent: 'codex',
    event: 'notify',
    payload,
    dryRun: hasFlag('dry-run'),
    verbose: hasFlag('verbose'),
  });
}

async function emitCliCommand() {
  const agent = getArg('agent', 'manual');
  const event = getArg('event', 'manual');
  const raw = await readStdin();
  const payload = parsePayload(raw);
  await emitCommand({
    agent,
    event,
    payload,
    dryRun: hasFlag('dry-run'),
    verbose: hasFlag('verbose'),
  });
}

async function testCommand() {
  const agent = getArg('agent', 'manual');
  const event = getArg('event', 'test');
  const cfg = await loadConfig();
  const item = normalizeEvent({
    agent,
    event,
    cfg,
    payload: {
      cwd: process.cwd(),
      message: 'agent-notify 测试消息',
    },
  });
  if (hasFlag('dry-run')) {
    console.log(formatMessage(cfg, item));
    return;
  }
  await sendFeishu(cfg, item);
  console.log('OK');
}

async function doctorCommand() {
  const cfg = await loadConfig();
  const checks = [
    ['config', existsSync(configPath) ? 'ok' : 'missing'],
    ['enabled', cfg.enabled ? 'on' : 'off'],
    ['feishu', cfg.feishu.enabled ? 'on' : 'off'],
    ['feishu.mode', cfg.feishu.mode || 'webhook'],
    ['feishu.webhookUrl', cfg.feishu.webhookUrl ? 'set' : 'empty'],
    ['feishu.appId', cfg.feishu.appId ? 'set' : 'empty'],
    ['feishu.receiverId', cfg.feishu.receiverId ? 'set' : 'empty'],
  ];
  for (const [name, value] of checks) {
    console.log(`${name}: ${value}`);
  }
}

async function main() {
  await ensureStateDir();
  const command = process.argv[2] || 'help';
  try {
    if (command === 'emit') await emitCliCommand();
    else if (command === 'codex-notify') await codexNotifyCommand();
    else if (command === 'flush') await flushQueue({ dryRun: hasFlag('dry-run'), verbose: true });
    else if (command === 'test') await testCommand();
    else if (command === 'doctor') await doctorCommand();
    else {
      console.log(`agent-notify

Usage:
  node notify.mjs emit --agent claude --event Stop
  node notify.mjs codex-notify
  node notify.mjs test --dry-run
  node notify.mjs doctor`);
    }
  } catch (error) {
    await logLine('error', 'command failed', {
      command,
      error: error instanceof Error ? error.message : String(error),
    });
    if (command === 'test' || hasFlag('strict')) {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
      return;
    }
  }
  exitOk();
}

main();
