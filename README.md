# Chelate

Chelate 是一个原生 iOS 版 [Proxmox VE](https://www.proxmox.com/) 客户端（SwiftUI），面向 PVE 9.x，所有请求直连 `https://<host>:<port>/api2/json`（默认端口 8006）。

## 功能（v0.2）

- 多服务器：增删改、切换；API Token 或账号密码（支持 TOTP / 恢复码二次验证、记住密码、ticket 自动续期）
- 证书：先走系统信任，不受信任时展示 SHA-256 指纹由你确认并固定；指纹变化会明确报警。REST、WebSocket、WKWebView 共用同一套校验
- 总览：`/cluster/resources` 按节点分组展示 VM / CT / 存储（两行固定布局：状态点、类型图标 + VMID、名称 + CPU / 内存 / 运行时间），下拉刷新，前台定时刷新
- 存储：用量、按类型分组的内容列表（ISO、CT 模板、备份、磁盘…）；「从 URL 下载」（自动查询文件名和大小，可填校验和）和「官方模板」（aplinfo，分类筛选 + 搜索），下载任务接入任务跟踪
- Guest 详情（qemu / lxc）：状态、只读配置、电源操作（危险操作二次确认）
- 监控图表：节点与 guest 的 CPU / 内存 / 网络 / 磁盘 IO，时 / 天 / 周 / 月 / 年；长按后左右拖动查看任意时间点的数值。节点内存为总计 / 可用 / 已用 / ZFS ARC 四条线（PVE 9 RRD 的 `memtotal` / `memavailable` / `memused` / `arcsize`，没有的字段不画）
- 容量统一用二进制单位（KiB / MiB / GiB / TiB，与 PVE 网页一致）
- 任务：操作后跟踪 UPID 进度，任务列表与任务日志
- 快照：列表、创建、回滚、删除
- Shell：节点 Shell、LXC 控制台（termproxy + SwiftTerm 原生渲染，键盘辅助键，尺寸自适应）
- VM 图形控制台：vncproxy + 原生 WebSocket，桥接给 WKWebView 中的 noVNC
- 403 视为“无权限”（置灰并提示），不当作故障；回到前台时 Shell / 控制台自动重连
- 设置：服务器（编辑、查看 / 复制 / 忘记证书指纹、删除）、自动刷新间隔、图表默认时间范围、主题、五种强调色、Face ID 解锁（含多任务界面遮罩）、危险操作二次确认、导出脱敏日志
- 小组件（小组件版）：小号、中号、锁屏圆形、锁屏长条，可选服务器和节点，约 15 分钟刷新，离线时显示缓存；点击进入节点 / guest 详情（`chelate://`）
- 接口层由 PVE 9.2 API schema 生成（全部 716 个接口的带类型请求），见 `Schema/README.md`

## 仓库结构

```
project.yml            XcodeGen 工程描述（.xcodeproj 不入库）
VERSION                发版用的「主.次」版本
App/
  Sources/             iOS App：SwiftUI 界面、设置、日志、Face ID、SwiftTerm、WKWebView
  Shared/              App 与小组件扩展共用：服务器配置、Keychain、证书校验、App Group 镜像、小组件视图
  Widget/              小组件扩展（只在小组件版中嵌入）
  Resources/VNCWeb/    noVNC v1.7.0（core + vendor，保留其 LICENSE.txt）和桥接页面
Packages/PVEKit/       纯 Swift 包：API client、模型、认证、termproxy 编解码（可在 Linux 上构建测试）
  Sources/PVEKit/Generated/  由 schema 生成的请求类型（勿手改）
Schema/                PVE API schema（pve-docs apidata.js 转成的 JSON）及来源 commit
scripts/               CI 构建、版本计算、release notes、字符串目录生成、API 生成器
```

## 生成工程与本地开发

需要最新的 Xcode（CI 用 macOS runner 上的默认 Xcode，目前为 Xcode 26.x，deployment target iOS 26.0）。

```sh
brew install xcodegen
xcodegen generate
open Chelate.xcodeproj
```

工程里有两个 App target，共用全部源码和 bundle id `org.sketchain.chelate`，用编译开关 `CHELATE_WIDGETS` 区分：

| Scheme | Target | 内容 |
| --- | --- | --- |
| `Chelate` | `Chelate` | 标准版：不含小组件扩展，不使用 App Group |
| `Chelate-Widget` | `ChelateWidgets` + `ChelateWidgetExtension` | 小组件版：内嵌小组件扩展 `org.sketchain.chelate.widget`，使用 App Group `group.org.sketchain.chelate`；单元测试和 UI 测试都在这个 scheme 里 |

两个 target 产物都叫 `Chelate.app`，请分别构建（不同 scheme，或不同 DerivedData）。

- 首次打开时 Xcode 会提示信任 SwiftTerm 的 build plugin，选择信任即可；命令行构建需加 `-skipPackagePluginValidation`。
- 版本号不写在 `project.yml` 里，由 CI 注入。本地命令行构建可以自己传：
  ```sh
  xcodebuild -project Chelate.xcodeproj -scheme Chelate-Widget -skipPackagePluginValidation \
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

### 接口层生成

`Packages/PVEKit/Sources/PVEKit/Generated/` 由 `scripts/generate-pvekit-api.py` 从 `Schema/pve-api-9.2.json` 生成并提交入库（构建时不联网、不生成）。修改生成器或更新 schema 后：

```sh
python3 scripts/generate-pvekit-api.py              # 重新生成
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
(cd Packages/PVEKit && swift test)
```

每个「路径 + 方法」对应一个 `PVEAPI.<名字>` 请求类型（如 `PVEAPI.GetNodesQemuStatusCurrent`），用 `client.send(request)` 发送。手写的 `PVEClient` 方法都改为调用生成层，返回值在手写模型更精确的地方（宽松数字解析、派生字段）仍解码到手写模型。CI 的 Linux job 会重新运行生成器，产物与提交的代码不一致即失败。schema 来源和更新方法见 `Schema/README.md`。

### 演示模式与截图

启动参数 `-ChelateDemo` 打开演示模式：App 只显示一台内置的假服务器（节点 `pve`，运行中 / 已停止 / 模板三种状态的 VM 和 CT，`local` 和 `local-zfs` 两个存储，带 ARC 的 RRD 数据），所有 API 请求都由 `App/Sources/Demo` 里的 fixture 应答，不发网络请求，也不读写钥匙串和服务器列表。在 Xcode 里可以在 scheme 的 *Arguments Passed On Launch* 中加上它；再加 `-ChelateDemoChartSelection` 会在 CPU 图上预置一个选中点（用于截图浮层）。

演示模式下设置里多一个「小组件展示」页，用假数据按真实尺寸渲染四种小组件（以及小号的离线状态）；不会改动真实设置、App Group 和钥匙串。

UI 测试 `ChelateUITests`（只在小组件版上跑）在演示模式下依次截取首页（并检查标题位置）、总览、节点详情、节点监控（含长按浮层）、guest 详情、存储详情、从 URL 下载表单、官方模板列表、任务列表、设置、服务器详情和小组件展示页，浅色、深色各一套，用 `XCTAttachment` 保存截图。

## CI 与产物

| 触发 | Workflow | 内容 |
| --- | --- | --- |
| push 到 `dev`、所有 PR | `CI` | Linux：生成器测试 + 检查生成代码是否最新 + PVEKit `swift build && swift test`；macOS 小组件版：PVEKit `swift test` → `xcodebuild build test`（模拟器，单元测试和截图 UI 测试）→ 无签名 archive → 打包 ipa，导出截图；macOS 标准版：只 build + 无签名 archive + 打包 |
| push 到 `main` | `Release` | 按 `VERSION` 计算 `vX.Y.Z` → 两个变体测试与构建 → 全部成功后才打 tag 并推送 → 创建 GitHub Release |

- **dev 构建**：在 Actions 对应运行的 *Artifacts* 中下载 `Chelate-dev-<short sha>-unsigned.ipa`（标准版）和 `Chelate-dev-<short sha>-widget-unsigned.ipa`（小组件版），保留 30 天。其 `CFBundleShortVersionString` 为最近一个已发布 tag 的版本（还没有 tag 时为 `0.0.0`）。
- **截图**：同一运行的 *Artifacts* 中的 `Chelate-screenshots-<short sha>`，内含 `01-overview-<short sha>.png` 等 PNG（保留 30 天，由 `scripts/export-screenshots.sh` 从 xcresult 导出）。
- **正式版**：在 GitHub Releases 下载 `Chelate-vX.Y.Z-unsigned.ipa`（标准版）或 `Chelate-vX.Y.Z-widget-unsigned.ipa`（小组件版），各附一份 `.sha256`；release notes 末尾写明两个包的区别。补丁号 = 同一「主.次」下已有 tag 的最大补丁号 + 1（没有则为 0）。tag 只在构建和测试全部通过后才创建，构建失败不会留下 tag，也不会跳号；同一 commit 重跑时复用已有 tag；要升主/次版本，修改 `VERSION`。
- 所有构建的 `CFBundleVersion` 为当前 commit 的 `git rev-list --count HEAD`（dev 与正式版同一计数，随提交单调递增，main 上的正式版不会比之前的 dev 包小）；Info.plist 中额外写入 `ChelateGitCommit`（short sha）和 `ChelateChannel`（`dev` / `release`），“设置 › 关于”显示「版本 (build) · 渠道 · commit」。

### 分支约定

- 日常开发都进入 `dev`（直接 push 或开指向 `dev` 的 PR）。
- `dev` 合入 `main` 由仓库所有者手动操作（merge commit，不 squash），合入后自动发版。
- commit message 使用 [Conventional Commits](https://www.conventionalcommits.org/)（`feat:` / `fix:` / `refactor:` / `docs:` / `ci:` …），release notes 按 feat / fix / 其他分组。

## 签名与安装

CI 产出的 ipa **没有签名**（`CODE_SIGNING_ALLOWED=NO`），需要在仓库外自行重签后安装。两个变体：

| 安装包 | 内含 bundle | 需要 |
| --- | --- | --- |
| `Chelate-…-unsigned.ipa`（标准版） | `org.sketchain.chelate` | 1 个 App ID、1 份描述文件，不需要 App Group |
| `Chelate-…-widget-unsigned.ipa`（小组件版） | `org.sketchain.chelate` + `PlugIns/ChelateWidgetExtension.appex`（`org.sketchain.chelate.widget`） | 2 个 App ID、App Group、2 份描述文件 |

### 1. 在开发者后台创建

在 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/) 中：

1. **App Group**：Identifiers › App Groups › 新建 `group.org.sketchain.chelate`。
2. **App ID**（Identifiers › App IDs，类型 App）：
   - `org.sketchain.chelate`（主 App）
   - `org.sketchain.chelate.widget`（小组件扩展，只有小组件版需要）

   两个 App ID 都在 Capabilities 里勾选 **App Groups**，再点 Configure 选中 `group.org.sketchain.chelate`。标准版不用这个能力，但主 App ID 勾上也没有影响，两个变体可以共用同一个 App ID 和描述文件。
3. **描述文件**（Profiles）：用同一个证书分别为两个 App ID 各生成一份（Development 或 Ad Hoc，包含你的设备），例如 `chelate.mobileprovision` 和 `chelate-widget.mobileprovision`。勾选 App Group 之后再生成，描述文件里才会带 `com.apple.security.application-groups`。

### 2. 用 zsign 签名

[zsign](https://github.com/zhlynn/zsign) 从 **v0.9.2** 起支持多次传 `-m` 给扩展指定各自的描述文件（旧版本只接受一个 `-m`，会把同一份描述文件和 entitlements 用在所有 bundle 上，小组件版必须升级）。它按描述文件的 `application-identifier`（`TEAMID.<bundle id>`）与每个 bundle 的 `CFBundleIdentifier` 匹配，签名时把匹配到的描述文件写进对应 bundle 并使用其中的 entitlements；没有匹配到的 bundle 用第一个 `-m`，所以**主 App 的描述文件放在第一个**。

```sh
# 校验
shasum -a 256 -c Chelate-vX.Y.Z-widget-unsigned.ipa.sha256

# 小组件版：主 App 和扩展各用自己的描述文件
zsign -k cert.p12 -p 'p12 密码' \
  -m chelate.mobileprovision \
  -m chelate-widget.mobileprovision \
  -o Chelate-widget-signed.ipa Chelate-vX.Y.Z-widget-unsigned.ipa

# 标准版：一份描述文件
zsign -k cert.p12 -p 'p12 密码' -m chelate.mobileprovision \
  -o Chelate-signed.ipa Chelate-vX.Y.Z-unsigned.ipa
```

签完可以解包核对：`Payload/Chelate.app/embedded.mobileprovision` 与 `Payload/Chelate.app/PlugIns/ChelateWidgetExtension.appex/embedded.mobileprovision` 应分别是两份描述文件，`codesign -d --entitlements - <bundle>`（macOS）里两个 bundle 都应包含 `group.org.sketchain.chelate`。

**zsign 不可用时的替代方案**（旧版本、或需要更细的控制）：在 macOS 上用 `codesign` 由内向外手动签名：

```sh
unzip -q Chelate-vX.Y.Z-widget-unsigned.ipa -d work && cd work/Payload
APPEX=Chelate.app/PlugIns/ChelateWidgetExtension.appex
cp ~/chelate-widget.mobileprovision "$APPEX/embedded.mobileprovision"
cp ~/chelate.mobileprovision Chelate.app/embedded.mobileprovision
security cms -D -i "$APPEX/embedded.mobileprovision" | plutil -extract Entitlements xml1 -o widget.entitlements -
security cms -D -i Chelate.app/embedded.mobileprovision | plutil -extract Entitlements xml1 -o app.entitlements -
codesign -f -s "Apple Development: 你的名字 (XXXXXXXXXX)" --entitlements widget.entitlements "$APPEX"
codesign -f -s "Apple Development: 你的名字 (XXXXXXXXXX)" --entitlements app.entitlements Chelate.app
rm widget.entitlements app.entitlements && cd .. && zip -qry ../Chelate-widget-signed.ipa Payload
```

（先签扩展再签主 App；Frameworks 目录里如果有 dylib / framework 也要先签。）

### 3. 互相换装与数据

- 两个变体的主 App bundle id 相同。用**同一个证书 / Team** 签名时，系统把标准版和小组件版之间的覆盖安装视为升级，服务器列表、设置和钥匙串里的凭据都会保留，不需要迁移：两个变体都把配置和设置存在 App 自己的容器、凭据存在默认钥匙串访问组。
- 小组件版另外把小组件需要的数据（服务器配置、证书 pin、强调色、凭据、小组件缓存）镜像到 App Group，启动时和数据变动时同步；从小组件版换回标准版后这份镜像不再更新，也不会影响 App 本身。换回小组件版后启动一次即重新同步，也可以在“设置 › 数据 › 重新同步小组件数据”手动同步。
- 小组件版如果签名时没带上 App Group（描述文件没勾选，或用 `-b` 改了 bundle id 而没有对应的 App Group），App 其他功能照常，设置里会提示“App Group 不可用，请检查签名”，小组件显示同样的提示。

### 注意事项

- 用 `-b` 改 bundle id 时，zsign 会把扩展的 bundle id 按前缀一起替换；两个 App ID 和描述文件也要按新 id 创建。改了 bundle id 后 Keychain 中已保存的凭据不会迁移。
- 用个人免费账号签名的描述文件 7 天过期，过期后需要重签；免费账号能否使用 App Group 取决于 Apple 当前的限制，不行就用标准版。
- Keychain 访问组跟随签名的 Team ID，换 Team 重签后需要重新输入凭据。
- 首次连接局域网服务器时 iOS 会请求“本地网络”权限，必须允许；若误拒，可在“设置 › 隐私与安全性 › 本地网络”中打开。
- “Face ID 解锁”使用 `NSFaceIDUsageDescription`，无需额外 entitlement。

## 使用提示

- **API Token**：在 PVE “数据中心 › 权限 › API Token” 创建。启用“权限分离”的 Token 需要单独授权（如 `VM.PowerMgmt`、`VM.Console`、`Sys.Console`）。
- **Shell / 控制台与 API Token**：PVE 的 termproxy / vncwebsocket 接受 API Token（浏览器无法在 WebSocket 上带 Token header，原生客户端可以），所以 Token 模式下也能打开节点 Shell、LXC 控制台和 VM 图形控制台。但 PVE 只对 `root@pam` 的账号密码会话提供免登录节点 Shell，Token 会话（包括 `root@pam!xxx`）和其他用户会先看到 `login:` 提示，需要输入节点上的 Linux 账号密码；App 中会给出提示。
- **二次验证**：支持 TOTP 和恢复码；只配置了 WebAuthn / U2F 的账号无法登录，请添加 TOTP 或改用 API Token。

## 第三方组件

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT），通过 SPM 引用
- [noVNC](https://github.com/novnc/noVNC) v1.7.0（MPL-2.0），随仓库附带，许可证见 `App/Resources/VNCWeb/noVNC/LICENSE.txt`
