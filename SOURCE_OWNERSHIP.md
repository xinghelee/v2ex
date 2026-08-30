# v2Explore 苹果审核归属说明 / App Store Review Ownership Note

## 审核员快速核验 / Quick Review

**This app is submitted by the same developer who owns and maintains the source repository below. No command-line or cryptographic verification is required for routine review.**

| Item | Value |
| --- | --- |
| App | v2Explore |
| Source repository | [`github.com/xinghelee/v2ex`](https://github.com/xinghelee/v2ex) |
| Repository owner | [Xinghe Lee / `@xinghelee`](https://github.com/xinghelee) |
| Contact | [hi@xinghelee.com](mailto:hi@xinghelee.com) |
| Bundle ID | `com.vibe.v2ex` |
| Apple Developer Team ID | `99LYH6FNPS` |

For routine verification, please confirm that:

1. the source repository is owned by GitHub user `xinghelee`;
2. the repository contains a continuous development history rather than a repackaged template or fork;
3. the version, build and Git commit supplied in App Store Connect Review Notes match the submitted build.

## Verification Flow / 核验流程

```text
Developer's private key (local + 1Password backup)
                         |
                         | signs current Team ID,
                         | version, build and Git commit
                         v
App Store Connect Review Notes --------+
                                       |
SOURCE_OWNERSHIP.md --------------------+--> Apple cross-checks --> VERIFIED
(repository owner + public key)         |
                                       +--> changed/copycat data --> REJECTED
```

If additional ownership evidence is required, please reply in the App Store Connect Resolution Center. The developer can provide a fresh cryptographic signature for a reviewer-provided challenge.

## 原创声明 / Authorship Declaration

本仓库 `xinghelee/v2ex` 及其中的 **v2Explore** iOS 应用由仓库所有者 **Xinghe Lee** 独立设计、开发和维护。项目不是购买的 App 模板，不是其他 App Store 应用的重新打包版本，也不是从其他 V2EX iOS 客户端 Fork 后换皮提交。自初始实现起的功能开发、界面演进、问题修复和构建版本变化均保留在本仓库连续的 Git 提交历史中。

This repository and the **v2Explore** iOS application it contains are independently designed, developed, and maintained by **Xinghe Lee**. The application is not a purchased app template, a repackaged App Store binary, or a re-skinned fork of another V2EX iOS client. Its implementation history is preserved in this repository's continuous Git history.

> This statement confirms source-code authorship only. It does not claim affiliation with or authorization by V2EX.

<details>
<summary><strong>Optional cryptographic verification / 可选密码学核验（仅在需要时使用）</strong></summary>

- Public prefix: `V2EXPLORE-SOURCE-OWNER-XINGHELEE`
- The complete identifier and signature are supplied privately in App Store Connect Review Notes for each submitted build.
- Ed25519 public key:

  ```text
  -----BEGIN PUBLIC KEY-----
  MCowBQYDK2VwAyEA0PXiFqhNMR1Om9BjKVBfyKP8F4g1GsU2B3WpSOX6fME=
  -----END PUBLIC KEY-----
  ```

- Fingerprint: `SHA256:BubZJ7n/quc855TpctLJqeOpJf0xvlUSSKkKYstPzS0=`
- Technical verification procedure: [docs/ownership-verification.md](docs/ownership-verification.md)

</details>
