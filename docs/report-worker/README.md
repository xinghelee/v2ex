# 举报收件端点

App Store 审核指南 1.2 要求 UGC App 的举报能真正到达开发者，并在 24 小时内
得到处理。App 侧的隐藏是即时且离线可用的，这个 Worker 负责把举报送到人眼前。

线上地址：`https://reports.xinghelee.com`

## 部署

```bash
npx wrangler login
cd docs/report-worker

npx wrangler kv namespace create REPORTS    # 把返回的 id 填进 wrangler.toml
npx wrangler secret put ADMIN_KEY           # 读取接口的口令，别写进 toml
npx wrangler secret put RESEND_API_KEY      # 可选：配了才发邮件
npx wrangler deploy
```

部署完把 `https://reports.xinghelee.com/report` 填进
`V2EX/Features/Moderation/ReportService.swift` 的 `endpointString`。

## 接口

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| POST | `/report` | 无（见下） | App 提交举报或屏蔽通知 |
| GET | `/reports` | `Authorization: Bearer <ADMIN_KEY>` 或 `?key=` | 最近 200 条 |

读取接口优先用请求头。`?key=` 只为浏览器直接访问保留 —— 它会进浏览器历史，
也可能出现在 referrer 里。

## 威胁模型

**POST 端点必须对全世界开放。** 调用方是一个装在用户设备上的 App，任何塞进
二进制的密钥都能被逆向掏出来，所以「客户端认证」在这里是幻觉。防线建在别处：

| 风险 | 处理 |
|---|---|
| 任意 JSON 原样落库 | 字段白名单，表外的键一律丢弃 |
| 超大 payload 撑爆存储 | 请求体上限 8KB，超出返 413 |
| 单字段超长 | 每个字段独立长度上限（摘录 500、说明 1000 等） |
| 知道 UUID 就能覆盖真实举报 | 同 key 只写一次，重复到达返回 `duplicate: true` 且不覆盖 |
| 伪造链接投放到通知邮件 | `url` 只接受 `https://v2ex.com/` 与 `https://www.v2ex.com/` |
| 任意网页从浏览器打这个端点 | 不发 `Access-Control-Allow-Origin`，原生 App 不需要 CORS |
| 口令被时序攻击 | 常数时间比较 |
| 自动化刷量耗尽配额 | 见下 —— **需要手动在面板上加一条规则** |

### 限流（已配置）

Workers 的 `[[ratelimits]]` 绑定在本账号上**实测不生效**：同一个 key 连打 15
次，`limit()` 全部返回 `success: true`。代码里保留了调用，等它可用时会自动
生效，但**当前真正起作用的是 zone 上的 WAF 规则**：

| 项 | 值 |
|---|---|
| 规则名 | `v2ex-report-endpoint-limit` |
| 表达式 | `(http.host eq "reports.xinghelee.com" and http.request.uri.path eq "/report")` |
| 计数特征 | IP |
| 速率 | 10 请求 / 10 秒 |
| 操作 | Block，持续 10 秒 |

面板位置：`xinghelee.com` → 安全性 → 安全规则 → 速率限制规则。

周期只有 10 秒这一档 —— 免费版就给这一个选项（也只给 1 条规则）。实测 25
连发在第 13 条开始返回 429，规则确实在拦。

**它挡得住什么、挡不住什么**：能挡住脚本化的突发刷量；挡不住有耐心的攻击者
——每秒 1 条请求就能绕过这条规则，一天足以打满 KV 的 1000 次写配额。免费版
的限流粒度做不到更细。真出现这种情况，升级到 Pro 换更长的计数周期，或者把
存储从 KV 换成 D1。

### 配额打满的后果

不是数据泄露，也不会产生账单（免费额度超了就停止服务）。真正的瓶颈是
**KV 免费额度每天 1000 次写入**。写不进去时 App 侧的举报会留在 outbox 里，
下次启动或回前台自动重试，隔天补上。可用性问题，不是保密性问题。

## 隐私

**不记 IP、不记地理位置、不设 cookie、不接统计。** 举报内容本身不含举报人
身份，只有被举报对象的 ID、发布者用户名、理由和可选说明。IP 仅用于限流的
即时判断，不写入任何存储。这与 App Store Connect 里「不收集数据」的声明和
App 的隐私政策一致。

## 没部署会怎样

`endpointString` 为空时 App 不会报错：举报照样立即在本机生效并落盘，记录停在
「待发送」，用户可以在「内容与屏蔽」里点那条记录用邮件直接发给开发者。填好
URL 后，下次启动或回前台会自动补发所有积压的举报。
