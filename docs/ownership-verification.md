# 源码归属核验方案 / Source Ownership Verification

本文件说明 v2Explore（仓库 `xinghelee/v2ex`）如何在**不公开完整标识**的前提下，让 App Store Review 能够核验源码归属。

## 日常使用（每次提审，就一条命令）

```bash
scripts/ownership-sign.sh   # 自动生成随机后缀
```

把输出的整段 `OWNERSHIP VERIFICATION` 粘贴到 App Store Connect → 版本 → **审核备注**。签名会自动绑定仓库、Bundle ID、Team ID、版本号、build、Git commit、时间与随机 nonce；完整标识不会出现在任何公开地方。

## 原理

公开字符串必然可复制，所以验证不依赖字符串本身，而依赖**只有仓库所有者持有的私钥**：

| 侧 | 内容 | 谁可见 |
| --- | --- | --- |
| 公开 | 前缀 `V2EXPLORE-SOURCE-OWNER-XINGHELEE` + Ed25519 公钥 + 公钥指纹 | 所有人（公开无妨） |
| 私密 | 完整标识（公开前缀 + 随机后缀）+ 每次审核的签名 | 仅 App Store Connect 审核备注 |
| 密码学 | 私钥签名 → 公钥验签 | 只有私钥持有者能产生有效签名 |

第三方即使完整复制 `SOURCE_OWNERSHIP.md` 和审核备注内容，也**无法伪造签名**，因为签名需要私钥。旧负载即使泄露，也绑定了原 Team ID、版本、build 和 Git commit，无法作为其它开发者或其它审核版本的新证明。随机 nonce 用于区分每次签名，但真正的抗重放依赖核验方同时检查上述上下文字段。

## 密钥

- 私钥：`~/.ssh/v2explore-owner.pem`（权限 600，**绝不提交仓库、绝不进 iCloud**）
- 公钥：`~/.ssh/v2explore-owner.pub.pem`（内容已发布在 `SOURCE_OWNERSHIP.md`）

生成命令（如已生成可跳过）：

```bash
openssl genpkey -algorithm ed25519 -out ~/.ssh/v2explore-owner.pem
chmod 600 ~/.ssh/v2explore-owner.pem
openssl pkey -in ~/.ssh/v2explore-owner.pem -pubout -out ~/.ssh/v2explore-owner.pub.pem

# 校验公钥与 SOURCE_OWNERSHIP.md 一致
openssl pkey -pubin -in ~/.ssh/v2explore-owner.pub.pem -outform DER 2>/dev/null \
  | openssl sha256 -binary | base64
# 预期输出：BubZJ7n/quc855TpctLJqeOpJf0xvlUSSKkKYstPzS0=
```

> 建议：把私钥再备份到离线介质，或导入 YubiKey / 系统钥匙串。丢失私钥 = 核验体系失效，需重新生成并更新 `SOURCE_OWNERSHIP.md`（见「密钥轮换」）。

## 核验方操作（Apple 或任何第三方）

以 `SOURCE_OWNERSHIP.md` 中的公钥验证签名：

```bash
# 1. 把「Signed message」原文存为 msg.txt（逐字保存）
printf '%s' '<Signed message 原文>' > msg.txt

# 2. 把「Signature (base64)」解码为 sig.bin
printf '%s' '<Signature base64>' | base64 -d > sig.bin

# 3. 用 SOURCE_OWNERSHIP.md 里的公钥验签
cat > v2explore-owner.pub.pem <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA0PXiFqhNMR1Om9BjKVBfyKP8F4g1GsU2B3WpSOX6fME=
-----END PUBLIC KEY-----
EOF
openssl pkeyutl -verify -pubin -inkey v2explore-owner.pub.pem \
  -rawin -in msg.txt -sigfile sig.bin
# → Signature Verified Successfully 即核验通过
```

## 审核备注模板

```
OWNERSHIP VERIFICATION / 源码归属核验

Identifier: V2EXPLORE-SOURCE-OWNER-XINGHELEE-<随机后缀>
Bundle ID: com.vibe.v2ex
Team ID: 99LYH6FNPS
App version / build: <版本> (<build>)
Git commit / state: <commit> (clean)
Repo: https://github.com/xinghelee/v2ex
  - SOURCE_OWNERSHIP.md 公开前缀 V2EXPLORE-SOURCE-OWNER-XINGHELEE（完整串仅此处提供）
  - 公钥指纹 SHA256:BubZJ7n/quc855TpctLJqeOpJf0xvlUSSKkKYstPzS0= 对应 tag v1.2.0-owner-proof
  - 公钥验签命令见 docs/ownership-verification.md

Signed message:
<脚本输出的 Signed message 原文>

Signature (base64):
<脚本输出的 Signature>
```

## 绑定 GitHub 账号（交叉核验）

```bash
git add README.md SOURCE_OWNERSHIP.md docs/ownership-verification.md scripts/ownership-sign.sh
git commit -S -m "Add ownership verification public key"
git tag -s v1.2.0-owner-proof
git push --tags
```

GPG 签名提交在 GitHub 显示 Verified 徽章，把「公钥 ↔ 仓库账号 ↔ 审核版本」三方锁死。

## 密钥轮换

```bash
# 重新生成密钥对
openssl genpkey -algorithm ed25519 -out ~/.ssh/v2explore-owner.pem
chmod 600 ~/.ssh/v2explore-owner.pem
openssl pkey -in ~/.ssh/v2explore-owner.pem -pubout -out ~/.ssh/v2explore-owner.pub.pem
# 更新 SOURCE_OWNERSHIP.md 中的公钥与指纹，重新打 tag，旧私钥彻底销毁
```

## 注意事项

- **审核备注不是机密**：它不公开，但 Apple 审核团队可见；防的是「被公开复制冒充」，不是「Apple 内部可见」。不要在其中放置真正的凭据。
- **抗重放**：核验时必须检查 Team ID、版本、build、Git commit 与当前提交一致；nonce 和时间戳只提供新鲜性标记，不能单独阻止重放。正式提审前建议在干净工作区生成，输出应显示 `git-state: clean`。
- **私钥管理**：不提交仓库、不进 iCloud/网盘、不通过聊天工具传输。
- **Apple Review 不验证源码作者**：审核主要检查二进制行为与合规。此标识用于应对「是否原创 / 是否有权使用源码」的追问，以及被抄袭、下架纠纷时的交叉核验；正式版权主张走法律渠道。
