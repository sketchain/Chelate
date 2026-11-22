# Chelate

Chelate 是一个原生 iOS 版 [Proxmox VE](https://www.proxmox.com/) 客户端（SwiftUI），面向 PVE 9.x，所有请求直连 `https://<host>:<port>/api2/json`（默认端口 8006）。

## 功能（v1）

- 多服务器：增删改、切换；API Token 或账号密码（支持 TOTP / 恢复码二次验证、记住密码、ticket 自动续期）
- 证书：先走系统信任，不受信任时展示 SHA-256 指纹由你确认并固定；指纹变化会明确报警。REST、WebSocket、WKWebView 共用同一套校验
- 总览：`/cluster/resources` 按节点分组展示 VM / CT / 存储，下拉刷新，前台定时刷新
- Guest 详情（qemu / lxc）：状态、只读配置、电源操作（危险操作二次确认）
- 监控图表：节点与 guest 的 CPU / 内存 / 网络 / 磁盘 IO，时 / 天 / 周 / 月 / 年
- 任务：操作后跟踪 UPID 进度，任务列表与任务日志
- 快照：列表、创建、回滚、删除
- Shell：节点 Shell、LXC 控制台（termproxy + SwiftTerm 原生渲染，键盘辅助键，尺寸自适应）
- VM 图形控制台：vncproxy + 原生 WebSocket，桥接给 WKWebView 中的 noVNC
- 403 视为“无权限”（置灰并提示），不当作故障；回到前台时 Shell / 控制台自动重连

## 仓库结构

```
project.yml            XcodeGen 工程描述（.xcodeproj 不入库）
VERSION                发版用的「主.次」版本
App/                   iOS App：SwiftUI 界面、Keychain、证书校验、SwiftTerm、WKWebView
  Resources/VNCWeb/    noVNC v1.7.0（core + vendor，保留其 LICENSE.txt）和桥接页面
Packages/PVEKit/       纯 Swift 包：API client、模型、认证、termproxy 编解码（可在 Linux 上构建测试）
scripts/               CI 构建、版本计算、release notes、字符串目录生成
```

## 生成工程与本地开发

需要最新的 Xcode（CI 用 macOS runner 上的默认 Xcode，目前为 Xcode 26.x，deployment target iOS 26.0）。

```sh
brew install xcodegen
xcodegen generate
open Chelate.xcodeproj
```

- 首次打开时 Xcode 会提示信任 SwiftTerm 的 build plugin，选择信任即可；命令行构建需加 `-skipPackagePluginValidation`。
- 版本号不写在 `project.yml` 里，由 CI 注入。本地命令行构建可以自己传：
  ```sh
  xcodebuild -project Chelate.xcodeproj -scheme Chelate -skipPackagePluginValidation \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    MARKETING_VERSION=0.0.0 CURRENT_PROJECT_VERSION=1 build
  ```
- 在真机上用 Xcode 直接运行时，在 target 的 Signing 里选择你自己的 Team。
- 界面文案是简体中文，集中在 `App/Resources/Localizable.xcstrings`（源语言 zh-Hans）。新增文案后可运行 `python3 scripts/extract-strings.py` 刷新目录（在 Xcode 中构建时也会自动同步）。

### PVEKit（可在 Linux 上测试）

```sh
cd Packages/PVEKit
swift build && swift test
```

测试只用手写的 fixture（照 PVE 9 真实响应的结构），不会连接真实服务器。

## CI 与产物

| 触发 | Workflow | 内容 |
| --- | --- | --- |
| push 到 `dev`、所有 PR | `CI` | PVEKit `swift test`（macOS + Linux）→ `xcodebuild build test`（模拟器）→ 无签名 archive → 打包 ipa |
| push 到 `main` | `Release` | 按 `VERSION` 计算 `vX.Y.Z` → 测试与构建 → 全部成功后才打 tag 并推送 → 创建 GitHub Release |

- **dev 构建**：在 Actions 对应运行的 *Artifacts* 中下载 `Chelate-dev-<short sha>-unsigned.ipa`（保留 30 天）。其 `CFBundleShortVersionString` 为最近一个已发布 tag 的版本（还没有 tag 时为 `0.0.0`）。
- **正式版**：在 GitHub Releases 下载 `Chelate-vX.Y.Z-unsigned.ipa` 和对应的 `.sha256`。补丁号 = 同一「主.次」下已有 tag 的最大补丁号 + 1（没有则为 0）。tag 只在构建和测试全部通过后才创建，构建失败不会留下 tag，也不会跳号；同一 commit 重跑时复用已有 tag；要升主/次版本，修改 `VERSION`。
- 所有构建的 `CFBundleVersion` 为当前 commit 的 `git rev-list --count HEAD`（dev 与正式版同一计数，随提交单调递增，main 上的正式版不会比之前的 dev 包小）；Info.plist 中额外写入 `ChelateGitCommit`（short sha）和 `ChelateChannel`（`dev` / `release`），“关于”页显示「版本 (build) · 渠道 · commit」。

### 分支约定

- 日常开发都进入 `dev`（直接 push 或开指向 `dev` 的 PR）。
- `dev` 合入 `main` 由仓库所有者手动操作（merge commit，不 squash），合入后自动发版。
- commit message 使用 [Conventional Commits](https://www.conventionalcommits.org/)（`feat:` / `fix:` / `refactor:` / `docs:` / `ci:` …），release notes 按 feat / fix / 其他分组。

## 签名与安装

CI 产出的 ipa **没有签名**（`CODE_SIGNING_ALLOWED=NO`），需要在仓库外自行重签后安装，例如：

```sh
shasum -a 256 -c Chelate-vX.Y.Z-unsigned.ipa.sha256
zsign -k your.p12 -p 'p12 密码' -m your.mobileprovision \
  -b org.sketchain.chelate -o Chelate-signed.ipa Chelate-vX.Y.Z-unsigned.ipa
```

注意事项：

- 描述文件的 App ID 需匹配 bundle id `org.sketchain.chelate`（或用 `-b` 改成你自己的；改了之后 Keychain 中已保存的凭据不会迁移）。
- 用个人免费账号签名的描述文件 7 天过期，过期后需要重签。
- App 不需要额外的 entitlement（不用 iCloud、推送、App Group）。Keychain 访问组跟随签名的 Team ID，换 Team 重签后需要重新输入凭据。
- 首次连接局域网服务器时 iOS 会请求“本地网络”权限，必须允许；若误拒，可在“设置 › 隐私与安全性 › 本地网络”中打开。

## 使用提示

- **API Token**：在 PVE “数据中心 › 权限 › API Token” 创建。启用“权限分离”的 Token 需要单独授权（如 `VM.PowerMgmt`、`VM.Console`、`Sys.Console`）。
- **Shell / 控制台与 API Token**：PVE 的 termproxy / vncwebsocket 接受 API Token（浏览器无法在 WebSocket 上带 Token header，原生客户端可以），所以 Token 模式下也能打开节点 Shell、LXC 控制台和 VM 图形控制台。但 PVE 只对 `root@pam` 的账号密码会话提供免登录节点 Shell，Token 会话（包括 `root@pam!xxx`）和其他用户会先看到 `login:` 提示，需要输入节点上的 Linux 账号密码；App 中会给出提示。
- **二次验证**：支持 TOTP 和恢复码；只配置了 WebAuthn / U2F 的账号无法登录，请添加 TOTP 或改用 API Token。

## 第三方组件

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT），通过 SPM 引用
- [noVNC](https://github.com/novnc/noVNC) v1.7.0（MPL-2.0），随仓库附带，许可证见 `App/Resources/VNCWeb/noVNC/LICENSE.txt`
