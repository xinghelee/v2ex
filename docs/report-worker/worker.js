/**
 * V2EX 举报收件端点（Cloudflare Worker）。
 *
 * App 里的举报和屏蔽会 POST 到这里。Worker 把每条举报存进 KV 并（可选）推一封
 * 邮件，好让开发者在 24 小时内看到 —— 这是 App Store 审核指南 1.2 对 UGC App
 * 的硬性要求。
 *
 * 威胁模型：POST 端点必须对全世界开放（客户端是 App，任何密钥都能从二进制里
 * 掏出来，所以「认证」在这里是幻觉）。防线因此建在别处：
 *   - 按 IP 限流，挡自动化刷量
 *   - 严格字段白名单 + 长度上限，挡垃圾灌注和超大 payload
 *   - 同 key 只写一次，挡「知道 UUID 就能覆盖真实举报」
 *   - 不发 CORS 通配头，原生 App 不需要，浏览器端也就打不进来
 *
 * 部署见 README.md。
 */

const NOTIFY_TO = "hi@xinghelee.com";
const NOTIFY_FROM = "V2EX Reports <reports@resend.dev>";

const MAX_BODY_BYTES = 8 * 1024;

const KINDS = new Set(["report", "block"]);
const TARGET_TYPES = new Set(["topic", "reply", "member"]);
const REASONS = new Set([
  "spam", "harassment", "hate", "sexual",
  "violence", "illegal", "privacy", "other",
]);
const UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/reports") {
      return handleList(request, url, env);
    }
    if (request.method === "POST" && url.pathname === "/report") {
      return handleReport(request, env, ctx);
    }
    return json({ error: "not found" }, 404);
  },
};

// MARK: 写入

async function handleReport(request, env, ctx) {
  // 限流只用 IP 做即时判断，不落库、不记日志 —— 举报本身不含举报人身份，
  // 存了 IP 就把匿名上报变成可关联的数据收集，与 App 的隐私政策冲突。
  //
  // 注意：Workers 的 ratelimit 绑定在本账号上实测不生效（同 key 连打 15 次
  // 全部返回 success:true）。这里保留调用，等它可用时自动生效；**当前真正
  // 起作用的限流是 zone 上的 WAF Rate limiting rule**，见 README。
  if (env.REPORT_RL) {
    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    const { success } = await env.REPORT_RL.limit({ key: ip });
    if (!success) return json({ error: "rate limited" }, 429);
  }

  const declared = Number(request.headers.get("content-length") || 0);
  if (declared > MAX_BODY_BYTES) return json({ error: "payload too large" }, 413);

  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) return json({ error: "payload too large" }, 413);

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  const record = validate(body);
  if (!record) return json({ error: "invalid payload" }, 400);

  const key = `report:${record.id}`;

  // 同一个 id 只接受一次写入。App 的 outbox 会重发未送达的举报，所以重复
  // 到达是正常的 —— 直接当成功返回，但绝不覆盖已有内容。少了这一条，
  // 任何知道举报 UUID 的人都能把真实举报改写成空记录。
  const existing = await env.REPORTS.get(key);
  if (existing !== null) return json({ ok: true, duplicate: true });

  record.receivedAt = new Date().toISOString();
  await env.REPORTS.put(key, JSON.stringify(record));

  if (env.RESEND_API_KEY) ctx.waitUntil(notify(record, env));

  return json({ ok: true });
}

/**
 * 字段白名单。只有这张表里的键会被存下来 —— 原来那版是 `{...body}`，
 * 等于把攻击者的任意 JSON 原样落库。
 */
function validate(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;

  const str = (v, max) =>
    typeof v === "string" && v.length <= max ? v : null;

  const id = str(body.id, 36);
  if (!id || !UUID_RE.test(id)) return null;

  const kind = str(body.kind, 16);
  if (!kind || !KINDS.has(kind)) return null;

  const targetType = str(body.targetType, 16);
  if (!targetType || !TARGET_TYPES.has(targetType)) return null;

  const targetID = str(body.targetID, 32);
  if (!targetID) return null;

  const reason = str(body.reason, 16);
  if (!reason || !REASONS.has(reason)) return null;

  const author = str(body.author, 64);
  if (author === null) return null;

  const createdAt = str(body.createdAt, 40);
  if (!createdAt) return null;

  let topicID = null;
  if (body.topicID !== null && body.topicID !== undefined) {
    if (!Number.isInteger(body.topicID) || body.topicID < 0) return null;
    topicID = body.topicID;
  }

  // 只认 v2ex.com 的链接，别的一律丢掉 —— 这个字段最后会出现在邮件里，
  // 不该变成任意链接的投放位。
  let link = null;
  const candidate = str(body.url, 200);
  if (candidate && /^https:\/\/(www\.)?v2ex\.com\//.test(candidate)) link = candidate;

  return {
    id,
    kind,
    targetType,
    targetID,
    topicID,
    author,
    excerpt: str(body.excerpt, 500) ?? "",
    reason,
    reasonTitle: str(body.reasonTitle, 64) ?? "",
    note: str(body.note, 1000) ?? "",
    createdAt,
    url: link,
    appVersion: str(body.appVersion, 32) ?? "",
    platform: str(body.platform, 16) ?? "",
  };
}

// MARK: 读取

async function handleList(request, url, env) {
  if (!env.ADMIN_KEY || !authorized(request, url, env.ADMIN_KEY)) {
    return json({ error: "unauthorized" }, 401);
  }
  const list = await env.REPORTS.list({ prefix: "report:", limit: 200 });
  const items = await Promise.all(
    list.keys.map(async (k) => JSON.parse((await env.REPORTS.get(k.name)) || "null"))
  );
  return json({ count: items.length, items: items.filter(Boolean) });
}

/** Authorization 头优先；query 参数保留给浏览器直接访问，但会进历史记录。 */
function authorized(request, url, expected) {
  const header = request.headers.get("authorization") || "";
  const bearer = header.startsWith("Bearer ") ? header.slice(7) : "";
  return timingSafeEqual(bearer, expected) ||
    timingSafeEqual(url.searchParams.get("key") || "", expected);
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// MARK: 通知

async function notify(record, env) {
  const isBlock = record.kind === "block";
  const subject = isBlock
    ? `[V2EX] 用户屏蔽 @${record.author}`
    : `[V2EX] 举报 ${record.targetType} ${record.targetID} · ${record.reasonTitle}`;

  const lines = [
    `类型：${isBlock ? "屏蔽通知" : "内容举报"}`,
    `对象：${record.targetType} ${record.targetID}`,
    `作者：@${record.author}`,
    `理由：${record.reasonTitle || record.reason}`,
    `说明：${record.note || "（无）"}`,
    `链接：${record.url || "（无）"}`,
    `时间：${record.createdAt}`,
    `版本：${record.appVersion} / ${record.platform}`,
    "",
    "内容摘录：",
    record.excerpt || "（无）",
  ];

  await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: NOTIFY_FROM,
      to: [NOTIFY_TO],
      subject,
      text: lines.join("\n"),
    }),
  });
}

// 刻意不发 Access-Control-Allow-Origin：调用方是原生 App，不受同源策略约束；
// 发了通配头等于额外允许任意网页从浏览器里往这个端点打。
function json(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
