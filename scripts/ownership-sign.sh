#!/usr/bin/env bash
# 生成「源码归属核验」审核备注负载。
# 用法: scripts/ownership-sign.sh [后缀]   （后缀缺省时随机生成 6 位十六进制）
# 自检: scripts/ownership-sign.sh --self-test
# 每次提交审核运行一次，把输出整段粘贴到 App Store Connect 审核备注。
set -euo pipefail

KEY="${V2EX_OWNER_KEY:-$HOME/.ssh/v2explore-owner.pem}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_YML="$ROOT_DIR/project.yml"
OWNERSHIP_DOC="$ROOT_DIR/SOURCE_OWNERSHIP.md"
REPO="https://github.com/xinghelee/v2ex"
APP_ID="com.vibe.v2ex"
TEAM_ID="99LYH6FNPS"
PREFIX="V2EXPLORE-SOURCE-OWNER-XINGHELEE"
FINGERPRINT="SHA256:BubZJ7n/quc855TpctLJqeOpJf0xvlUSSKkKYstPzS0="

[ -f "$KEY" ] || { echo "私钥不存在: $KEY" >&2; exit 1; }
[ -f "$PROJECT_YML" ] || { echo "项目配置不存在: $PROJECT_YML" >&2; exit 1; }
[ -f "$OWNERSHIP_DOC" ] || { echo "核验文件不存在: $OWNERSHIP_DOC" >&2; exit 1; }

self_test() {
  local tmp expected actual leaks
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  openssl pkey -in "$KEY" -pubout -out "$tmp/pub.pem" 2>/dev/null

  expected="${FINGERPRINT#SHA256:}"
  actual="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null | openssl sha256 -binary | base64 | tr -d '\n')"
  [ "$actual" = "$expected" ] || { echo "FAIL: 私钥与公开核验指纹不一致"; return 1; }
  grep -Fq "$FINGERPRINT" "$OWNERSHIP_DOC" || { echo "FAIL: SOURCE_OWNERSHIP.md 指纹不一致"; return 1; }
  echo "PASS: 私钥、公钥指纹与 SOURCE_OWNERSHIP.md 一致"

  printf '%s' 'v2explore ownership self-test' > "$tmp/msg.txt"
  openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$tmp/msg.txt" -out "$tmp/sig.bin" 2>/dev/null
  openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -in "$tmp/msg.txt" -sigfile "$tmp/sig.bin" >/dev/null 2>&1 \
    || { echo "FAIL: 真签名无法验证"; return 1; }
  echo "PASS: 真签名验证成功"

  printf '%s' 'v2explore ownership tampered' > "$tmp/tampered.txt"
  if openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -in "$tmp/tampered.txt" -sigfile "$tmp/sig.bin" >/dev/null 2>&1; then
    echo "FAIL: 篡改内容仍能通过验签"; return 1
  fi
  echo "PASS: 篡改内容被拒绝"

  openssl genpkey -algorithm ed25519 -out "$tmp/attacker.pem" 2>/dev/null
  openssl pkeyutl -sign -inkey "$tmp/attacker.pem" -rawin -in "$tmp/msg.txt" -out "$tmp/forged.bin" 2>/dev/null
  if openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -in "$tmp/msg.txt" -sigfile "$tmp/forged.bin" >/dev/null 2>&1; then
    echo "FAIL: 其它私钥的签名仍能通过"; return 1
  fi
  echo "PASS: 其它私钥的伪造签名被拒绝"

  leaks="$(grep -RIl --exclude-dir=.git --exclude-dir=node_modules -- '^-----BEGIN .*PRIVATE KEY-----$' "$ROOT_DIR" 2>/dev/null || true)"
  [ -z "$leaks" ] || { echo "FAIL: 仓库疑似包含私钥: $leaks"; return 1; }
  echo "PASS: 仓库未发现私钥内容"
  echo "ALL TESTS PASSED"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit
fi

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")"
BUILD="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")"
COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unavailable')"
GIT_STATE="clean"
[ -z "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ] || GIT_STATE="dirty"
SUFFIX="${1:-$(openssl rand -hex 3)}"
IDENTIFIER="${PREFIX}-${SUFFIX}"

MSG="$(printf '%s\n' \
  "proof: v2explore-source-owner/v1" \
  "identifier: $IDENTIFIER" \
  "repo: $REPO" \
  "bundle-id: $APP_ID" \
  "team-id: $TEAM_ID" \
  "app-version: $VERSION" \
  "build: $BUILD" \
  "git-commit: $COMMIT" \
  "git-state: $GIT_STATE" \
  "nonce: $(openssl rand -hex 16)" \
  "issued-at: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s' "$MSG" > "$TMP/msg.txt"
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$TMP/msg.txt" -out "$TMP/sig.bin"
SIG="$(base64 < "$TMP/sig.bin")"

cat <<EOF
============================================================
APP REVIEW — SOURCE OWNERSHIP
（整段粘贴到 App Store Connect -> Review Notes）
============================================================

v2Explore is independently developed and maintained by Xinghe Lee,
the owner of the source repository below. For routine review, no
command-line or cryptographic verification is required.

Please cross-check:
- Repository: $REPO (owner: GitHub @xinghelee)
- Bundle ID / Team ID: $APP_ID / $TEAM_ID
- App version / build: $VERSION ($BUILD)
- Git commit / state: $COMMIT ($GIT_STATE)
- Human-readable ownership note: $REPO/blob/main/SOURCE_OWNERSHIP.md

If additional evidence is required, please reply in the Resolution
Center. I can sign a fresh reviewer-provided challenge with the same
ownership key.

OPTIONAL TECHNICAL PROOF / 可选技术证明
Identifier: $IDENTIFIER
Public prefix: $PREFIX
Public-key fingerprint: $FINGERPRINT
Verification procedure: $REPO/blob/main/docs/ownership-verification.md

Signed message:
$MSG

Signature (base64):
$SIG
============================================================
EOF
