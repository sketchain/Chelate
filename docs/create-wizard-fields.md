# Proxmox VE 9 WebUI「创建虚拟机 / 创建 CT」向导字段规范

> 用途：供 iOS 客户端 1:1 复刻 PVE WebUI 的 **Create VM**（`PVE.qemu.CreateWizard`）与 **Create CT**（`PVE.lxc.CreateWizard`）向导。
> 本文所有结论均直接来自源码阅读（不是文档转述）。字段标识 / API 参数名保持原样，其余为简体中文。

## 0. 来源与版本

| 仓库 | commit | 说明 |
|---|---|---|
| `proxmox/pve-manager`（GitHub 镜像） | `a788a4bcf902acd317a437d97eacef30b0780c16`（2026-11-24） | 向导与全部面板/表单组件，`www/manager6/**` |
| `proxmox/proxmox-widget-toolkit`（GitHub 镜像） | `997a01a7bbdd4ac9ce8d624fcdc76c47421dbba7` | `KVComboBox`、`Checkbox`、`InputPanel`、`ComboGrid`、`Textfield`、`IntegerField`、VTypes/正则 |
| `git.proxmox.com/git/qemu-server.git` | `65f679cd2c77a7be50cc872ab5e25fcdbd795754` | `POST /nodes/{node}/qemu` 参数模式（用于核对取值范围） |
| `git.proxmox.com/git/pve-container.git` | `ae86a25d9f58daa0f2fa316d134d88f66f804d0d` | `POST /nodes/{node}/lxc` 参数模式 |
| `git.proxmox.com/git/pve-storage.git` | `1b20a75442cd0f335ffc950fc5ac95bf260eab45` | 各存储类型支持的磁盘格式 |
| `git.proxmox.com/git/proxmox-i18n.git`（`zh_CN.po`） | `ffc063283f79c9b47544de8cc889cb78377a198a` | 中文标签。标「模糊」的条目在 po 文件中带 `#, fuzzy`（官方未审核或译错），我给出了建议译名 |

主要源码文件（相对 `www/manager6/`）：`window/Wizard.js`、`qemu/CreateWizard.js`、`qemu/OSPanel.js`、`qemu/OSTypeEdit.js`、`qemu/OSDefaults.js`、`qemu/Architecture.js`、`qemu/CDEdit.js`、`qemu/SystemEdit.js`、`qemu/HDEfi.js`、`qemu/HDTPM.js`、`qemu/MultiHDEdit.js`、`panel/MultiDiskEdit.js`、`qemu/HDEdit.js`、`qemu/ProcessorEdit.js`、`qemu/MemoryEdit.js`、`qemu/NetworkEdit.js`、`lxc/CreateWizard.js`、`lxc/MultiMPEdit.js`、`lxc/MPEdit.js`、`lxc/IdMapField.js`、`lxc/ResourceEdit.js`（CPU/内存）、`lxc/Network.js`、`lxc/DNS.js`、`form/*`（NodeSelector、GuestIDSelector、PoolSelector、TagFieldSet、StorageSelector、DiskStorageSelector、DiskFormatSelector、FileSelector、IsoSelector、ControllerSelector、BusTypeSelector、CacheTypeSelector、ScsiHwSelector、QemuMachineSelector、QemuBiosSelector、CPUModelSelector、VMCPUFlagSelector、MemoryField、NetworkCardSelector、BridgeSelector、VLanField、FilteredKVComboBox）、`Utils.js`、`Parser.js`、`UIOptions.js`。

> 注：任务描述里提到的 `lxc/CPUEdit.js`、`lxc/MemoryEdit.js` 在当前代码中不存在，对应面板在 `lxc/ResourceEdit.js`；`qemu/MachineEdit.js` 不被创建向导使用（向导使用 `form/QemuMachineSelector.js`，**只提供「默认 / q35」两项，没有具体版本号**，因此创建向导不调用 `/nodes/{node}/capabilities/qemu/machines`）。

---

## 1. 通用机制（两个向导共享，`window/Wizard.js` + widget-toolkit）

### 1.1 选项卡流转与校验

- 窗口 760×570，模态。底部按钮：帮助、`Advanced`（高级）复选框、`Back`（返回）、`Next`（下一步）、`Finish`（完成，仅在确认页显示，替代 Next）。
- 初始只有第 1 个选项卡可用，其余禁用。
- 某选项卡的有效性 = 该卡内所有 `field`/`fieldcontainer` 的 `isValid()` 全部为真（若卡片定义了 `validator()` 则以其为准）。
- 当前卡有效 → `Next` 可点，并自动启用下一张卡；任一已访问卡变为无效 → 该卡之后的所有卡被禁用。任何字段 `change`/`validitychange` 都会从当前卡到「已到达的最大卡号」重新校验。
- 用户可以通过点击已启用的选项卡标题跳转。
- **字段收集（`getValues`）**：遍历所有 `inputpanel` 调用其 `getValues()`（包括其 `onGetValues` 改写）+ 不属于任何 inputpanel 的表单字段（实际只有确认页的 `start` 复选框）。**隐藏的「高级」字段同样会被收集提交**（只是隐藏，不是禁用）；**禁用（disabled）的字段不提交**。
- 多个面板输出同名键时会合并为数组（实际只会发生在 `delete` 上）；提交前 `delete` 键被整体丢弃（创建时没有可删除项）。

### 1.2 「Advanced / 高级」复选框

- 位于底部工具栏，标签 `Advanced`（高级）。状态持久化到浏览器状态键 `proxmox-advanced-cb`（全局，下次打开向导沿用）。iOS 建议用 `UserDefaults` 同名键。
- 勾选后，所有 inputpanel 的 `advancedContainer`（`advancedColumn1/2/B`、`advancedItems`）显示；未勾选时隐藏但**仍提交其当前值/默认值**。

### 1.3 各类控件的提交语义（决定「默认时是否省略参数」）

| 控件 | 规则 |
|---|---|
| `proxmoxKVComboBox`（`deleteEmpty` 默认 true） | 值为 `''`/`null`/`'__default__'` 时：`deleteEmpty=true` → 输出 `delete=<name>`（创建时被丢弃 = **省略**）；`deleteEmpty=false` → 不输出。其他值原样输出。 |
| `proxmoxcheckbox` | 勾选 → 输出 `inputValue`（默认 `'1'`）；未勾选 → 输出 `uncheckedValue`（未设置则不输出）；若值等于 `defaultValue` 且 `deleteDefaultValue=true` → 输出 `delete`（=省略）。`clearOnDisable=true` 时禁用会把值重置为 false。禁用的复选框不提交。 |
| 普通 `checkbox`（Ext） | 勾选 → `inputValue`；未勾选 → 不输出。 |
| `proxmoxtextfield`（`skipEmptyText` 默认 true） | 空串 → 不输出（`deleteEmpty=true` 时输出 delete）。 |
| 普通 `textfield` / `textarea`（Ext） | 空串也会输出 `name=''`。 |
| `proxmoxintegerfield` | 空 → 不输出（`deleteEmpty=true` 时输出 delete）。 |
| 普通 `numberfield`（Ext） | 空 → 输出 `''`（各面板的 `onGetValues` 会再处理）。 |
| `ComboGrid`（节点/存储/池/网桥/CPU 型号等） | 默认 `autoSelect=true`：store 加载后若当前无值，自动选中**第一条**记录（排序后）。`FileSelector`、`PoolSelector`、`CPUModelSelector` 显式 `autoSelect=false`。 |

### 1.4 校验正则（widget-toolkit `Utils.js` / `Toolkit.js`）

| VType | 规则 |
|---|---|
| `DnsName` | `^(?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]*[a-zA-Z0-9])?)\.)*(?:[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)$`；错误文案 `This is not a valid hostname`（该主机名无效） |
| `IPAddress` | 标准 IPv4（每段 0–255，不允许前导 0 的多位数） |
| `IPCIDRAddress` | IPv4 + `/` + 1–2 位数字，且掩码 **8–32** |
| `IP6Address` | 完整 RFC 4291 IPv6 正则（含压缩形式、内嵌 IPv4） |
| `IP6CIDRAddress` | IPv6 + `/` + 1–3 位数字，且掩码 **8–128** |
| `MacAddress` | `^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$` |
| `CpuSet` | `^[0-9]+(?:-[0-9]+)?(?:,[0-9]+(?:-[0-9]+)?)*$` |
| `IP64AddressWithSuffixList`（PVE） | 以 `/[ ,;]+/` 分隔，每项为 IPv4 或 IPv6；允许 `%iface` 后缀但**仅当地址以 `fe80:` 开头**，且最多一个 `%` |
| 标签字符 | `PVE.Utils.tagCharRegex = /^[a-z0-9+_.-]+$/i` |

---

## 2. 向导数据来源（需要调用的 API）

| 用途 | 请求 | 关键返回字段 / 处理 |
|---|---|---|
| 节点列表 | `GET /nodes` | `node,status,cpu,maxcpu,mem,maxmem,uptime`；按 `node` 升序（次序 `mem` 降序）。`status !== 'online'` 的节点视为无效（错误 `Node X seems to be offline!`）。默认值：当前在资源树中选中的节点（`preferredValue`），否则第一个节点。 |
| 节点 CPU 架构、cgroup 版本 | `GET /cluster/resources`（WebUI 的 ResourceStore） | 节点条目的 `host-arch`（缺省按 `x86_64`）与 `cgroup-mode`（缺省 2）。 |
| 下一个空闲 ID | `GET /cluster/nextid` | `data` 为整数（字符串），作为 VMID 初值。 |
| ID 是否可用 | `GET /cluster/nextid?vmid=<id>` | 成功 = 可用；失败（HTTP 400）= 已被占用/无效，错误优先显示 `This VM ID is already in use`（若 UI 已知该 ID），否则用响应 `errors.vmid` 文本。 |
| 资源池 | `GET /pools` | `poolid,comment`，按 `poolid` 排序（可能含 `/` 嵌套池）。 |
| 标签候选 | `GET /cluster/options` | `allowed-tags`（候选列表）、`tag-style`（颜色/排序）。 |
| 存储列表 | `GET /nodes/{node}/storage?format=1&content=<ct>` | `storage,type,active,avail,total,enabled,shared,content,formats{supported[],default},select_existing`。`<ct>` 取 `iso`/`images`/`import`/`vztmpl`/`rootdir`。客户端再按 `content` 过滤：`images` 要求存储允许 `vm-vol`（或 `images`），`rootdir` 要求允许 `ct-vol`（或 `rootdir`），其他要求包含该类型。判定函数：`contentAllows(content, t) = content.split(',').some(ct => ct===t \|\| ct===generic[t] \|\| generic[ct]===t)`，`generic = {'vm-vol':'images','vm-state':'images','ct-vol':'rootdir'}`。按 `storage` 升序。 |
| 存储内容（ISO / 模板 / 导入镜像 / 已有卷） | `GET /nodes/{node}/storage/{storage}/content?content=<ct>` | `volid,format,size,ctime,...`；显示名为 volid 冒号后的文件部分。 |
| 网桥 | `GET /nodes/{node}/network?type=any_bridge` | `iface,active,type,comments`；按 `iface` 升序，默认自动选第一个。`any_bridge` 包含 Linux bridge、OVS bridge（以及启用 SDN 时的 VNet）。 |
| CPU 型号（仅 VM） | `GET /nodes/localhost/capabilities/qemu/cpu?arch=<arch>` | 注意 URL 中节点名固定为 `localhost`。`name,vendor,custom,abstract`。显示名 = `name` 去掉 `custom-` 前缀；vendor 映射 `AuthenticAMD→AMD`、`GenuineIntel→Intel`、`default→QEMU`、`name==='host'→Host`，custom 型号显示 `Custom (<vendor>)`。排序：AMD(1) < Intel(2) < QEMU(3) < Host(4) < 其他/自定义(5)，组内按 name 字母序。 |
| CPU 标志（仅 VM，高级） | `GET /nodes/localhost/capabilities/qemu/cpu-flags?arch=<arch>`（编辑现有 VM 时还会带 `accel=kvm\|tcg`；创建向导未调用 `setKvm`，所以不带 `accel`） | `name,description,supported-on[]`。默认只显示「至少一个节点支持」的标志（`supported-on` 非空，或 `name==='nested-virt'`，或已设置）。 |

---

## 3. 创建虚拟机向导（`PVE.qemu.CreateWizard`）

窗口标题：`Create: Virtual Machine`（创建：虚拟机）。选项卡顺序：常规 → 操作系统 → 系统 → 磁盘 → CPU → 内存 → 网络 → 确认。

### 3.0 架构（arch）全局联动（`qemu/Architecture.js`）

向导视图模型 `current.architecture` = `getGuestArchitecture(arch, node)`：若「vCPU 架构」为默认则取节点 `host-arch`（缺省 `x86_64`），否则取所选值。节点或架构变化时重新计算，并级联影响：

| 项 | `x86_64` | `aarch64` |
|---|---|---|
| 可选 OS 大类（osbase） | 全部 | `Linux`、`Other` |
| 可选 ostype | 全部 | `l26`、`other` |
| 默认 CPU 型号（空值时提交 / 显示） | `x86-64-v2-AES` | `host`（空值时不提交 `cpu`，由后端决定） |
| 默认机型显示 | `Default (i440fx)`（后端 `pc`） | `Default (virt)` |
| 默认安装光驱槽位 | `ide2` | `scsi2` |
| 允许的 SCSI 控制器 | `__default__`、`lsi`、`lsi53c810`、`megasas`、`virtio-scsi-pci`、`virtio-scsi-single`、`pvscsi` | `virtio-scsi-pci`、`virtio-scsi-single` |
| 允许的机型 | `__default__`(i440fx)、`q35` | `__default__`(virt) |
| 允许的磁盘总线 | `ide`、`sata`、`virtio`、`scsi` | `sata`、`virtio`、`scsi`（无 IDE） |
| 允许的固件 | `__default__`(SeaBIOS)、`seabios`、`ovmf` | 仅 `ovmf` |
| 允许的 TPM 版本 | `v1.2`、`v2.0` | `v2.0` |
| 默认 BIOS 显示 | `Default (SeaBIOS)` | `Default (OVMF (UEFI))` |

若显式选择的 `arch` 不是节点的宿主架构，确认页与提交时追加 `kvm=0`（软件模拟）。

### 3.0.1 OS 默认值表（`qemu/OSDefaults.js`）

`getDefaults(ostype, arch)`：未登记的 ostype 回落到 `generic`；未登记的架构回落到 `x86_64`。

| ostype | arch | busType（默认磁盘总线） | networkCard | scsihw | machine | bios | busPriority（用于选择新磁盘总线，数值大者优先） |
|---|---|---|---|---|---|---|---|
| generic（含 win10/win8/win7/w2k8/l24/solaris/other 等） | x86_64 | `ide` | `e1000` | `virtio-scsi-single` | – | – | ide 4, sata 3, scsi 2, virtio 1 |
| generic | aarch64 | `scsi` | `e1000` | `virtio-scsi-single` | – | `ovmf` | scsi 4, sata 3, virtio 2, ide 1 |
| `l26` | x86_64 | `scsi` | `virtio` | `virtio-scsi-single` | – | – | scsi 4, virtio 3, sata 2, ide 1 |
| `l26` | aarch64 | `scsi` | `virtio` | `virtio-scsi-single` | – | `ovmf` | scsi 4, virtio 2, sata 2, ide 1 |
| `w2k` | x86_64 | `ide` | `rtl8139` | `''`（= 默认 LSI） | – | – | 同 generic |
| `wxp` | x86_64 | 继承 w2k | `rtl8139` | `''` | – | – | 同 generic |
| `win11` | x86_64 | `ide` | `e1000` | `virtio-scsi-single` | `q35` | `ovmf` | 同 generic |

`cputype` 未在任何条目中定义（见 §3.2 关于 CPU 类型被重置的说明）。

---

### 3.1 选项卡「General / 常规」（`onlineHelp: qm_general_settings`）

| # | 字段 ID（name） | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 | 提交映射 |
|---|---|---|---|---|---|---|
| 1 | `nodename` | Node / 节点 | NodeSelector（ComboGrid） | 资源树当前节点；否则排序后第一个 | 必填；节点必须 `online` | **不作为参数**；用作 URL：`POST /nodes/{nodename}/qemu` |
| 2 | `vmid` | VM ID（标签由 `'{0} ID'` 拼接，未翻译） | 数字框 | `GET /cluster/nextid` 的结果 | 必填，整数 100–999999999；每次变更调用 `GET /cluster/nextid?vmid=X`，失败则无效（`This VM ID is already in use` / 该 VM ID 已被使用） | `vmid=<int>` |
| 3 | `name` | Name / 名称 | textfield | 空 | 可空；VType `DnsName` | 空则省略；否则 `name=<str>` |
| 4 | `ha-managed` | Add to HA / 添加到高可用 | checkbox | 未勾选 | – | 勾选：`ha-managed=1`；否则省略 |
| 5 | `pool` | Resource Pool / 资源池 | PoolSelector（可输入过滤，forceSelection） | 空 | 可空；必须是列表中的池 | 空则省略；否则 `pool=<poolid>` |
| 6 | `onboot` **[高级]** | Start at boot / 开机自启动 | checkbox | 未勾选 | – | 勾选：`onboot=1`；否则省略 |
| 7 | `order` **[高级]** | Start/Shutdown order / 启动/关机顺序 | textfield，占位 `any` | 空 | 前端无校验（后端要求非负整数） | 与 8、9 合并为 `startup`（见下） |
| 8 | `up` **[高级]** | Startup delay / 启动延时 | textfield，占位 `default` | 空 | 前端无校验（后端：整数秒） | 合并入 `startup` |
| 9 | `down` **[高级]** | Shutdown timeout / 关机超时 | textfield，占位 `default` | 空 | 前端无校验（后端：整数秒） | 合并入 `startup` |
| 10 | `arch` **[高级]** | vCPU Architecture / vCPU 架构（po 中为模糊条目「架构」） | KVComboBox | `__default__` | `__default__` = `Default (Host Architecture)`（默认（宿主架构））、`x86_64` = `x86 (64-bit)`、`aarch64` = `ARM (64-bit)` | `__default__` 省略；否则 `arch=<值>`；若非宿主架构，另加 `kvm=0` |
| 11 | `tags` **[高级]** | Tags / 标签 | TagFieldSet（标签编辑器，候选来自 `/cluster/options` 的 `allowed-tags`） | 空 | 每个标签匹配 `/^[a-z0-9+_.-]+$/i`，否则 `Tags contain invalid characters.`（标签包含无效字符。）；后端还会按数据中心 `user-tag-access` 策略检查权限 | 空省略；否则以 `;` 连接：`tags=a;b;c` |

`startup` 生成规则（`PVE.Parser.printStartup`）：按 `order`、`up`、`down` 顺序，非空项输出 `order=<v>` / `up=<v>` / `down=<v>`，以逗号连接；三者都空则不提交。例：`startup=order=2,up=30,down=60`。

`onGetValues` 还会删除值为假的 `name`、`pool`、`onboot`、`agent`。

---

### 3.2 选项卡「OS / 操作系统」（`pveQemuOSPanel`，左右两栏）

左栏：安装介质（`CDInputPanel`，confid 固定为 `ide2`；aarch64 时改为 `scsi2`；向导中不显示总线/设备选择器）。右栏：`Guest OS`（客户机操作系统）。

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 / 显隐 | 提交映射 |
|---|---|---|---|---|---|---|
| 1 | `mediaType` | 三选一单选：`Use CD/DVD disc image file (iso)`（使用 CD/DVD 光盘镜像文件（ISO））/ `Use physical CD/DVD Drive`（使用物理 CD/DVD 驱动器）/ `Do not use any media`（不使用任何介质） | radio | `iso` | `iso`/`cdrom`/`none`；选非 iso 时 ISO 选择器被禁用并清空 | 见 `ide2` 行 |
| 2 | `cdimage` 的存储部分 | Storage / 存储 | StorageSelector（`content=iso`，自动选第一个） | 第一个支持 iso 的存储 | `mediaType=iso` 时必填 | 不单独提交 |
| 3 | `cdimage` | ISO image / ISO 镜像 | FileSelector（`/storage/{s}/content?content=iso`，可输入过滤，不自动选） | 空 | `mediaType=iso` 时必填（为空则本选项卡无效） | 见下 |
| → | **`ide2`**（aarch64：**`scsi2`**） | – | – | – | – | `iso`：`ide2=<volid>,media=cdrom`（如 `local:iso/debian-13.iso,media=cdrom`）；`cdrom`：`ide2=cdrom,media=cdrom`；`none`：`ide2=none,media=cdrom`。**始终提交**。 |
| 4 | `osbase` | Type / 类型 | combobox（不提交） | `Linux` | `Linux`、`Microsoft Windows`、`Solaris Kernel`、`Other`（aarch64 仅 Linux/Other）。切换时 `ostype` 列表替换并自动选中**该大类第一项** | 不提交 |
| 5 | `ostype` | Version / 版本 | combobox | `l26` | 见下表 | `ostype=<val>`（始终提交） |
| 6 | （无 name，reference `enableSecondCD`） | Add additional drive for VirtIO drivers / 为 VirtIO 驱动程序添加额外驱动器 | checkbox（不提交） | 未勾选、隐藏 | **仅当 osbase = `Microsoft Windows` 时可见**；切到其他大类时自动取消勾选 | 不提交；控制 7/8 |
| 7 | `ide0` 的存储部分 | Storage / 存储 | StorageSelector（iso） | 第一个 iso 存储 | 仅在 6 勾选时显示且启用；必填 | – |
| 8 | `ide0` | ISO image / ISO 镜像 | FileSelector（iso） | 空 | 6 勾选时必填 | `ide0=<volid>,media=cdrom`（如 `local:iso/virtio-win.iso,media=cdrom`）；未勾选则省略 |

`ostype` 完整枚举（`PVE.Utils.kvm_ostypes`，显示为 `<大类> <desc>`）：

| osbase | desc（显示） | val |
|---|---|---|
| Linux | `7.x - 2.6 Kernel` | `l26` |
| Linux | `2.4 Kernel` | `l24` |
| Microsoft Windows | `11/2022/2025` | `win11` |
| Microsoft Windows | `10/2016/2019` | `win10` |
| Microsoft Windows | `8.x/2012/2012r2` | `win8` |
| Microsoft Windows | `7/2008r2` | `win7` |
| Microsoft Windows | `Vista/2008` | `w2k8` |
| Microsoft Windows | `XP/2003` | `wxp` |
| Microsoft Windows | `2000` | `w2k` |
| Solaris Kernel | `-` | `solaris` |
| Other | `-` | `other` |

（后端枚举还有 `w2k3`、`wvista`，向导不提供。）

**联动（`OSPanel` 控制器）**

- `ostype` 变化（以及 OS 页首次渲染）时，按 `OSDefaults.getDefaults(ostype, arch)`：
  - 若磁盘页**恰好只有一块磁盘**（只有一个总线选择器），把其总线设为 `busType`（随后设备号自动跳到该总线第一个空闲号）。多块磁盘时不改。
  - 把网络页网卡型号设为 `networkCard`。
  - 把 CPU 型号设为 `cputype`（所有条目均未定义 → 被重置为空 = 默认型号）。
  - `current.scsihw = scsihw || '__default__'`（与系统页 SCSI 控制器双向绑定，所以即使已访问过系统页也会被覆盖）。
  - `current.ostype = ostype`。
- 勾选「额外 VirtIO 驱动光驱」：视为 `ide0` 已占用（磁盘页 IDE 0 不可用），磁盘总线设为 `scsi`，网卡设为 `virtio`。取消勾选：释放 `ide0`，磁盘总线恢复为该 OS 的 `busType`。
- **引导顺序**（`calculateBootOrder`）：仅当 `ide0` 含 `media=cdrom`（即勾选了第二光驱）时生成：按 `ide0..3, scsi0..30, virtio0..15, sata0..5` 顺序找到第一块非光驱磁盘 D，`boot=order=D;ide2;ide0[;net0]`（有 `net0` 才追加）。例：`boot=order=scsi0;ide2;ide0;net0`。否则不提交 `boot`（用后端默认）。

---

### 3.3 选项卡「System / 系统」（`pveQemuSystemPanel`，`onlineHelp: qm_system_settings`，无高级字段）

**首次渲染时**（`afterrender` → `setDefaults`，只执行一次）：`machine = defaults.machine ?? '__default__'`、`bios = defaults.bios ?? '__default__'`；若 `ostype === 'win11'` 自动勾选「Add TPM」。之后再回到 OS 页修改 ostype **不会**再更新 machine/bios/TPM（但 scsihw 会更新）。iOS 实现若想完全一致，需要记录「系统页是否已首次显示」。

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 / 显隐 | 提交映射 |
|---|---|---|---|---|---|---|
| 1 | `vga` | Graphic card / 显卡 | KVComboBox（`deleteEmpty:false`） | `__default__` | `__default__`=Default（默认）、`std`=Standard VGA（标准 VGA）、`vmware`=VMware compatible（VMWare 兼容）、`qxl`=SPICE、`qxl2`=SPICE dual monitor、`qxl3`=SPICE three monitors、`qxl4`=SPICE four monitors、`serial0`…`serial3`=Serial terminal 0…3（串行终端 0…3）、`virtio`=VirtIO-GPU、`virtio-gl`=VirGL GPU、`none`=none（无） | `__default__` 省略；否则 `vga=<值>`；若为 `serialN` 还额外提交 `serialN=socket` |
| 2 | `machine` | Machine / 机型 | QemuMachineSelector | 由 OSDefaults（win11→`q35`，其余 `__default__`） | x86_64：`__default__`（显示 `Default (i440fx)`）、`q35`；aarch64：仅 `__default__`（`Default (virt)`）。**不提供版本号** | `__default__` 省略；`q35` → `machine=q35` |
| – | （显示） | Firmware / 固件 | 分组标题 | – | – | – |
| 3 | `bios` | BIOS | QemuBiosSelector | OSDefaults（win11 与 aarch64→`ovmf`，其余 `__default__`） | x86_64：`__default__`（`Default (SeaBIOS)`）、`seabios`（SeaBIOS）、`ovmf`（OVMF (UEFI)）；aarch64：仅 `ovmf` | `__default__` 省略；否则 `bios=<值>` |
| 4 | （无 name，绑定 `addefi`） | Add EFI Disk / 添加 EFI 磁盘 | checkbox（不提交） | 勾选 | **仅 bios=`ovmf` 时可见可用** | 控制 5–7 是否启用 |
| 5 | EFI 存储（`hdstorage`） | EFI Storage / EFI 存储 | StorageSelector（`content=images`，自动选第一个） | 第一个支持 VM 磁盘的存储 | bios=ovmf 时可见；ovmf 且 4 勾选时启用且必填 | 组成 `efidisk0` |
| 5a | EFI 已有卷（`hdimage`） | Disk image / 磁盘映像 | FileSelector | 空 | 仅当所选存储 `select_existing=1`（iSCSI、iSCSI direct、NVMe-oF）时出现并必选，此时不分配新卷 | 替代 `<storage>:1` |
| 6 | EFI 格式（`diskformat`） | Format / 格式 | DiskFormatSelector | 见 §3.4.3 格式规则 | 存储支持格式 ≤1 种时禁用（不提交） | `format=<fmt>` |
| 7 | `preEnrolledKeys` | Pre-Enroll keys / 预注册密钥（提示：Use EFIvars image with standard distribution and Microsoft secure boot keys enrolled.） | checkbox | 勾选 | – | 勾选 → `pre-enrolled-keys=1`；未勾选 → 省略 |
| → | **`efidisk0`** | – | – | – | 仅 bios=ovmf 且「Add EFI Disk」勾选时提交 | `efidisk0=<file>,efitype=4m[,pre-enrolled-keys=1][,format=<fmt>]`，其中 `<file>` = `<storage>:1`（大小固定写 1，后端覆盖）或已有卷 volid。例：`local-lvm:1,efitype=4m,pre-enrolled-keys=1`；目录存储：`local:1,efitype=4m,pre-enrolled-keys=1,format=qcow2`。`efitype=4m` 总是写入。 |
| 8 | `scsihw` | SCSI Controller / SCSI 控制器 | ScsiHwSelector | 由 OS（`virtio-scsi-single`；w2k/wxp 为 `__default__`） | 选项（按架构过滤见 §3.0）：`__default__`=`Default (LSI 53C895A)`、`lsi`=LSI 53C895A、`lsi53c810`=LSI 53C810、`megasas`=MegaRAID SAS 8708EM2、`virtio-scsi-pci`=VirtIO SCSI、`virtio-scsi-single`=VirtIO SCSI single、`pvscsi`=VMware PVSCSI | `__default__` 省略；否则 `scsihw=<值>`。变化同步到所有 SCSI 磁盘的「SCSI 控制器」只读显示与 IO thread 默认值 |
| 9 | `agent` | Qemu Agent / Qemu 代理 | checkbox | 未勾选 | – | 勾选 → `agent=1`；未勾选省略 |
| 10 | （无 name，`addtpm`） | Add TPM / 添加 TPM | checkbox（不提交） | 未勾选（win11 首次显示时自动勾选） | – | 控制 11–13 |
| 11 | TPM 存储（`hdstorage`） | TPM Storage / TPM 存储 | StorageSelector（images，自动选第一个） | 第一个 | 10 勾选时显示且必填 | 组成 `tpmstate0` |
| 11a | TPM 已有卷（`hdimage`） | Disk image | FileSelector | – | 仅 `select_existing` 存储 | 替代 `<storage>:1` |
| 12 | TPM 格式（`diskformat`） | Format / 格式 | DiskFormatSelector | 同格式规则 | ≤1 种格式时禁用 | `format=<fmt>` |
| 13 | `version` | Version / 版本 | FilteredKVComboBox（`deleteEmpty:false`） | `v2.0` | x86_64：`v1.2`、`v2.0`；aarch64：`v2.0` | `version=<v>` |
| → | **`tpmstate0`** | – | – | – | 仅 10 勾选时提交 | `tpmstate0=<file>[,format=<fmt>],version=<v>`。例：`local-lvm:1,version=v2.0`；目录存储：`local:1,format=qcow2,version=v2.0` |

---

### 3.4 选项卡「Disks / 磁盘」（`pveMultiHDPanel`，`onlineHelp: qm_hard_disk`）

#### 3.4.1 列表与增删

- 左侧为磁盘列表（显示 confid，如 `scsi0`；有无效字段时显示警告图标），按总线名字母序、再按编号排序；按钮 `Add`（新增）、`Import`（导入）；右侧为选中磁盘的编辑卡片。列表为空时显示 `No Disks`（没有磁盘）。
- **节点首次确定后自动添加第一块磁盘**并选中。
- **允许删除所有磁盘**（0 块磁盘合法，提交时就不带磁盘参数）。
- `Add`：新增「新建磁盘」卡片；`Import`：新增「导入磁盘」卡片（§3.4.4）。上限 `maxCount = 4+6+31+16+256 − 1 = 312`（代码如此计算，实际受各总线空闲槽位限制，`nextFreeDisk` 找不到空槽时不添加）。
- 新磁盘槽位选择：以「已占用配置」（安装光驱 `ide2`/`scsi2` 记为已占用，勾选第二光驱时 `ide0` 也占用，再加上其他磁盘卡片）调用 `sortByPreviousUsage`：按各总线**已有非光驱磁盘数**降序排序，数量相同按当前 OS 的 `busPriority` 降序；然后按架构过滤允许的总线；在第一个有空位的总线上取最小空闲编号。
- 每块磁盘的「总线/设备」组合必须唯一（重复时 `This device is already in use.`）。

总线与编号范围（`diskControllerMaxIDs`）：

| 总线 | 显示名 | 编号范围 | 备注 |
|---|---|---|---|
| `ide` | IDE | 0–3 | aarch64 不可用；`ide2` 被安装光驱占用（x86）；`ide0` 可能被第二光驱占用 |
| `sata` | SATA | 0–5 | |
| `virtio` | VirtIO Block | 0–15 | |
| `scsi` | SCSI | 0–30 | aarch64 下 `scsi2` 被安装光驱占用 |

#### 3.4.2 单块磁盘字段（`pveQemuHDInputPanel`，含 `Disk`（磁盘）与 `Bandwidth`（带宽）两个子选项卡）

**子选项卡「Disk / 磁盘」**

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 / 显隐 | 提交映射（进入磁盘串） |
|---|---|---|---|---|---|---|
| 1 | `controller` | Bus/Device / 总线/设备（左半） | BusTypeSelector | 按上述槽位算法（单盘时随 OS 的 `busType`） | `ide`(IDE)、`sata`(SATA)、`virtio`(VirtIO Block)、`scsi`(SCSI)，按架构过滤；切换总线时设备号跳到该总线最小空闲号，并更新最大值 | 参数名 = `controller + deviceid` |
| 2 | `deviceid` | Bus/Device（右半） | 整数框 | 最小空闲号 | 0 ~ (总线上限−1)；必填；不得与已占用槽位冲突 | 同上 |
| 3 | `scsiController` | SCSI Controller / SCSI 控制器 | 只读显示 | 系统页的 `scsihw` | 仅总线为 scsi 时显示，显示 `render_scsihw` 文本 | 不提交 |
| 4 | 存储（`hdstorage`） | Storage / 存储 | StorageSelector（`content=images`，自动选第一个） | 第一个 | 必填 | 磁盘串首段 `<storage>:<size>` |
| 4a | `hdimage` | Disk image / 磁盘映像 | FileSelector | 空 | 仅当存储 `select_existing=1`（iscsi、iscsidirect、nvmeof）时显示且必选；此时大小字段隐藏禁用 | 首段改为该卷的 volid |
| 5 | `disksize` | Disk size (GiB) / 磁盘大小 (GiB) | 数字框（3 位小数） | `32` | 必填；0.001–131072（128×1024） | `<storage>:<disksize>`，如 `local-lvm:32` |
| 6 | `diskformat` | Format / 格式 | DiskFormatSelector | 见 §3.4.3 | `raw`（Raw disk image (raw) / 原始磁盘映像）、`qcow2`（QEMU image format (qcow2) / QEMU 映像格式）、`vmdk`（VMware image format (vmdk) / VMware 映像格式）；按存储过滤 | 启用时 `format=<fmt>`；禁用时省略 |
| 7 | `cache` | Cache / 缓存 | CacheTypeSelector | `__default__` | `__default__`=`Default (No cache)`（默认（无缓存））、`directsync`=Direct sync、`writethrough`=Write through、`writeback`=Write back、`unsafe`=Write back (unsafe)（不安全）、`none`=No cache（无缓存） | `__default__` 省略；否则 `cache=<值>` |
| 8 | `discard` | Discard / 丢弃 | checkbox | 未勾选 | – | 勾选 → `discard=on` |
| 9 | `iothread` | IO thread / IO 线程 | checkbox | **自动**：总线为 virtio 时勾选；总线为 scsi 且 scsihw=`virtio-scsi-single` 时勾选；否则不勾选（随总线/控制器变化重新计算，会覆盖用户手动值） | 仅 virtio 或 scsi 总线时可用；其他总线禁用并清空 | 勾选 → `iothread=on` |
| 10 | `ssd` **[高级]** | SSD emulation / SSD 仿真 | checkbox | 未勾选 | virtio 总线时禁用并清空 | 勾选 → `ssd=on`（注意是 `on` 不是 `1`） |
| 11 | `readOnly` **[高级]** | Read-only / 只读 | checkbox | 未勾选 | 仅 virtio/scsi 可用 | 勾选 → `ro=on` |
| 12 | `backup` **[高级]** | Backup / 备份（提示：Include volume in backup job / 在备份作业中包括卷） | checkbox | **勾选** | – | 未勾选 → `backup=0`；勾选时省略 |
| 13 | `noreplicate` **[高级]** | Skip replication / 跳过复制 | checkbox | 未勾选 | – | 勾选 → `replicate=no` |
| 14 | `aio` **[高级]** | Async IO / 异步 IO | KVComboBox | `__default__` | `__default__`=`Default (io_uring)`、`io_uring`、`native`、`threads` | `__default__` 省略；否则 `aio=<值>` |

**子选项卡「Bandwidth / 带宽」**（全部非高级，留空 = 不限制）

| # | 字段 ID | 标签 | 控件 | 范围 | 提交 |
|---|---|---|---|---|---|
| 15 | `mbps_rd` | Read limit (MB/s) / 读取限制 | 数字（可小数），占位 `unlimited` | ≥1 | `mbps_rd=<v>` |
| 16 | `mbps_wr` | Write limit (MB/s) / 写入限制 | 数字 | ≥1 | `mbps_wr=<v>` |
| 17 | `iops_rd` | Read limit (ops/s) | 整数，步长 10 | ≥10 | `iops_rd=<v>` |
| 18 | `iops_wr` | Write limit (ops/s) | 整数 | ≥10 | `iops_wr=<v>` |
| 19 | `mbps_rd_max` | Read max burst (MB) / 最大突发读取，占位 `default` | 数字 | ≥1 | `mbps_rd_max=<v>` |
| 20 | `mbps_wr_max` | Write max burst (MB) / 写入最大突发 | 数字 | ≥1 | `mbps_wr_max=<v>` |
| 21 | `iops_rd_max` | Read max burst (ops) | 整数 | ≥10 | `iops_rd_max=<v>` |
| 22 | `iops_wr_max` | Write max burst (ops) | 整数 | ≥10 | `iops_wr_max=<v>` |

**磁盘串拼接顺序**（`printQemuDrive` 按插入顺序）：

```
<file>[,import-from=<volid>][,format=<fmt>][,backup=0][,replicate=no][,discard=on][,ssd=on][,iothread=on][,ro=on][,cache=<c>][,aio=<a>]
      [,mbps_rd=..][,mbps_rd_max=..][,mbps_wr=..][,mbps_wr_max=..][,iops_rd=..][,iops_rd_max=..][,iops_wr=..][,iops_wr_max=..]
```

示例：
- l26 + LVM-thin（单格式）：`scsi0=local-lvm:32,iothread=on`
- 目录存储：`scsi0=local:32,format=qcow2,iothread=on`
- 全选高级项：`scsi0=local-lvm:64,backup=0,replicate=no,discard=on,ssd=on,iothread=on,ro=on,cache=writeback,aio=native,mbps_rd=100`
- Windows（generic，busType ide）：`ide0=local-lvm:32`（IDE 不可设 iothread/ro）
- 已有 iSCSI LUN：`scsi0=iscsi-store:0.0.1.scsi-36001405...`（volid）

#### 3.4.3 磁盘格式规则（`DiskStorageSelector.changeStorage`，适用于普通磁盘、EFI、TPM）

1. 取所选存储的 `formats.supported`（新 API）或 `format[0]`（旧 API），删除 `subvol`。
2. 选中值：支持 `qcow2` → `qcow2`；否则支持 `raw` → `raw`；否则用 `formats.default`。
3. 支持格式数 ≤ 1 → 格式下拉**禁用（不提交 `format`）**；>1 → 启用并提交。
4. `select_existing=1` → 显示「Disk image」卷选择器，隐藏大小。

各存储类型（pve-storage 当前代码）：

| 存储类型 | 支持格式（去掉 subvol 后） | 默认选中 | 是否提交 format |
|---|---|---|---|
| `dir`、`nfs`、`cifs`、（`glusterfs` 等文件型） | raw、qcow2、vmdk | qcow2 | 是 |
| `btrfs` | raw | raw | 否（禁用） |
| `zfspool`、`zfs`（ZFS over iSCSI） | raw | raw | 否 |
| `lvmthin` | raw | raw | 否 |
| `lvm` | 普通：raw；启用 `snapshot-as-volume-chain` 时：qcow2、raw | qcow2（卷链）/ raw | 卷链时是，否则否 |
| `rbd` | raw | raw | 否 |
| `iscsi`、`iscsidirect`、`nvmeof` | raw，且 `select_existing` | – | 否（选择已有卷） |

（以 API 返回的 `formats` 为准，不要硬编码。）

#### 3.4.4 导入磁盘卡片（`Import` 按钮，`importDisk:true`）

| # | 字段 ID | 标签 | 控件 | 默认 | 校验 | 提交 |
|---|---|---|---|---|---|---|
| I1 | `import-source-storage` | Import Storage / 导入存储 | StorageSelector（`content=import`，自动选第一个） | 第一个 | 必填 | 不提交 |
| I2 | `import-from` | Select Image / 选择镜像 | FileSelector（`/storage/{s}/content?content=import`，只显示 `format ∈ {qcow2, vmdk, raw}` 的条目） | 空 | 必填 | `import-from=<volid>` |
| I3 | 目标存储 `hdstorage` | Target Storage / 目标存储 | StorageSelector（images） | 第一个 | 必填；**无大小字段** | `<storage>:0` |
| I4 | `diskformat` | Format / 格式 | 同 §3.4.3 | | | `format=<fmt>` |

总线/设备、Cache、Discard、IO thread、高级项、带宽同 §3.4.2。示例：`scsi1=local-lvm:0,import-from=local:import/disk.qcow2,iothread=on`。

---

### 3.5 选项卡「CPU」（`pveQemuProcessorPanel`，`onlineHelp: qm_cpu`）

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 / 联动 | 提交映射 |
|---|---|---|---|---|---|---|
| 1 | `sockets` | Sockets / CPU 插槽数 | 整数 | `1` | 必填，≥1（无上限） | `sockets=<n>`（始终提交） |
| 2 | `cores` | Cores / 核心 | 整数 | `1` | 必填，1–256 | `cores=<n>`（始终提交） |
| 3 | `cputype` | Type / 类型 | CPUModelSelector（可输入过滤，forceSelection） | 空，占位 `Default (x86-64-v2-AES)`（aarch64：`Default (host)`） | 列表来自 `/nodes/localhost/capabilities/qemu/cpu?arch=<arch>`（含 custom- 自定义型号与 x86-64-vN 抽象型号）。aarch64 且 KVM 时只允许 `host`、`max`、`cortex-a53`、`cortex-a57` 或 `custom-*`，否则报错 `The CPU model '{0}' is not usable with KVM on ARM; choose 'host' or 'max', or disable KVM.`。每次 OS 改变会被清空 | 见下 `cpu` |
| 4 | `totalcores` | Total cores / 核心总数 | 只读显示 | sockets×cores | – | 不提交 |
| 5 | `vcpus` **[高级]** | VCPUs | 整数，占位 = 核心总数 | 空 | 1 ~ sockets×cores | 空省略；否则 `vcpus=<n>` |
| 6 | `cpulimit` **[高级]** | CPU limit / CPU 限制 | 数字（可小数），占位 `unlimited`（无限制） | 空 | 0–128 | 空或 `0` 省略；否则 `cpulimit=<v>` |
| 7 | `affinity` **[高级]** | CPU Affinity / CPU 绑定 | 文本，占位 `All Cores`（所有核心） | 空 | VType `CpuSet`；**仅 `root@pam` 可编辑**（其他用户禁用 = 不提交） | 空省略；否则 `affinity=<cpuset>`，如 `0-3,8` |
| 8 | `cpuunits` **[高级]** | CPU units / CPU 权重 | 整数，占位 = 默认值 | 空 | cgroup v2：1–10000，默认 100；cgroup v1：2–262144，默认 1024（按节点 `cgroup-mode`） | 空或等于默认值则省略；否则 `cpuunits=<n>` |
| 9 | `numa` **[高级]** | Enable NUMA / 启用 NUMA | checkbox（`uncheckedValue:0`） | 未勾选 | – | **始终提交**：`numa=0` 或 `numa=1` |
| 10 | `flags` **[高级]** | Extra CPU Flags: / CPU 扩展标志（po 模糊） | 标志表格，每行三态分段按钮 `Off`(关闭,`-`) / `Default`(默认,`=`) / `On`(启用,`+`)；底部复选框「Only show flags supported by at least one node」（默认勾选，未翻译）；右下提示 `Showing flags for KVM` | 全部 `=` | 列表见 §2 | 非 `=` 的标志按 `<sign><name>` 以 `;` 连接，进入 `cpu` |
| – | （提示） | `WARNING: You do not have permission to configure custom CPU types...` | 仅编辑时出现，创建时不会出现 | | | |

**`cpu` 参数生成**（`printQemuCpu`）：
- `cputype` 为空：x86_64 → 提交值改为 `x86-64-v2-AES`；aarch64 → 不提交 cputype。
- `cpu = <cputype>[,flags=<flags>]`；若无 cputype 但有 flags → `kvm64,flags=...`；两者都无 → 不提交 `cpu`。
- 例：`cpu=x86-64-v2-AES`；`cpu=host`；`cpu=x86-64-v3,flags=+aes;-pcid`。

---

### 3.6 选项卡「Memory / 内存」（`pveQemuMemoryPanel`，`onlineHelp: qm_memory`）

**首次渲染时**：`memory` 设为 `4096`（若 `current.ostype === 'win11'`）否则 `2048`；`balloon` 随之跟随（见联动）。只执行一次。

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 / 联动 | 提交 |
|---|---|---|---|---|---|---|
| 1 | `memory` | Memory (MiB) / 内存 (MiB) | MemoryField（整数，步长 32） | 2048（win11：4096） | 必填，1–4178944（后端最小 16）。变化时：`balloon` 的最大值设为新值；若 balloon 原值等于旧 memory，则 balloon 同步为新值 | `memory=<n>`（始终提交，纯整数；后端格式 `[current=]<int>` 兼容纯数字） |
| 2 | `balloon` **[高级]** | Minimum memory (MiB) / 最小内存 | MemoryField | 跟随 memory（即等于 memory） | 必填，1 ~ memory；`ballooning` 未勾选时禁用 | 见下 |
| 3 | `shares` **[高级]** | Shares / 共享 | 整数，占位 `Default (1000)` | 空、**禁用** | 0–50000；仅当 ballooning 勾选且 balloon ≠ memory 时启用 | 见下 |
| 4 | `ballooning` **[高级]** | Ballooning Device / Ballooning 设备 | checkbox | 勾选 | 取消勾选 → 禁用 balloon、shares | 见下 |
| 5 | `allow-ksm` **[高级]** | Allow KSM / 允许 KSM（提示：允许内核的 Samepage Merging 守护进程合并此虚拟机的内存页。） | checkbox | 勾选 | – | 勾选（默认）省略；未勾选 → `allow-ksm=0` |

balloon/shares 规则（`onGetValues`）：
- `ballooning` 未勾选 → `balloon=0`（不提交 shares）。
- 勾选且 `balloon == memory` → 不提交 balloon、shares（默认情况）。
- 勾选且 `balloon < memory` → `balloon=<n>`，且 shares 非空时 `shares=<n>`。

---

### 3.7 选项卡「Network / 网络」（`pveQemuNetworkInputPanel`，`onlineHelp: qm_network_device`，confid 固定 `net0`）

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 / 联动 | 提交 |
|---|---|---|---|---|---|---|
| 1 | `nonetwork` | No network device / 无网络设备 | checkbox（`inputValue:'none'`） | 未勾选 | 勾选 → 禁用 2–10 所有字段 | 勾选时**不提交 `net0`** |
| 2 | `bridge` | Bridge / 桥接 | BridgeSelector（`/nodes/{node}/network?type=any_bridge`，自动选第一个） | 第一个网桥（按 iface 升序，通常 `vmbr0`） | 必填 | `bridge=<iface>` |
| 3 | `tag` | VLAN Tag / VLAN 标签 | 数字，占位 `no VLAN`（无 VLAN） | 空 | 1–4094；空=不打标签 | 非空且有 bridge → `tag=<n>` |
| 4 | `firewall` | Firewall / 防火墙 | checkbox | **勾选** | – | 勾选 → `firewall=1`；否则省略 |
| 5 | `model` | Model / 型号 | NetworkCardSelector | 初始 `e1000`，随 OS 改为 OSDefaults.networkCard（l26→`virtio`，w2k/wxp→`rtl8139`，其他→`e1000`；勾选第二光驱→`virtio`） | `e1000`=Intel E1000、`e1000e`=Intel E1000E、`virtio`=VirtIO (paravirtualized)（半虚拟化）、`rtl8139`=Realtek RTL8139、`vmxnet3`=VMware vmxnet3；必填 | 串首段 |
| 6 | `macaddr` | MAC address / MAC 地址 | textfield，占位 `auto` | 空 | VType `MacAddress` | 非空 → `<model>=<mac>` |
| 7 | `disconnect` **[高级]** | Disconnect / 断开 | checkbox | 未勾选 | – | 勾选 → `link_down=1` |
| 8 | `mtu` **[高级]** | MTU，占位 `Same as bridge`（与网桥相同） | 整数 | 空 | 1–65520，且值必须为空、`1` 或 ≥576（错误：`MTU needs to be >= 576 or 1 to inherit the MTU from the underlying bridge.`）；**仅 model=virtio 时可用**；值为 1 时显示提示 `Use the special value '1' to inherit the MTU value from the underlying bridge` | `mtu=<n>` |
| 9 | `rate` **[高级]** | Rate limit (MB/s) / 速率限制，占位 `unlimited` | 数字（可小数） | 空 | 0–10240 | 非空 → `rate=<v>`（WebUI 中数字框值是字符串，`'0'` 也为真，会提交 `rate=0`） |
| 10 | `queues` **[高级]** | Multiqueue | 整数 | 空 | 1–64 | `queues=<n>` |

`net0` 串拼接顺序（`printQemuNetwork`）：`<model>[=<mac>][,bridge=<b>[,tag=<t>][,firewall=1]][,rate=<r>][,queues=<q>][,link_down=1][,mtu=<m>]`。
例：`net0=virtio,bridge=vmbr0,firewall=1`；`net0=virtio=BC:24:11:12:34:56,bridge=vmbr1,tag=10,firewall=1,rate=12.5,queues=4,link_down=1,mtu=1`。

---

### 3.8 选项卡「Confirm / 确认」

- 表格两列 `Key`（键）/ `Value`（值），按 key 升序。内容 = 提交参数集合（含 `nodename`、`vmid`、`ostype`、`ide2`、各磁盘、`cpu`、`sockets`、`cores`、`numa`、`memory`、`net0`…），不显示 `delete`；若需要也会显示计算出的 `boot`、`kvm=0`。数据在**每次进入该页时**重新计算（此时 `start` 一般还未勾选，故通常不出现在表中）。
- 底部复选框 `start`：`Start after created`（创建后启动），默认未勾选；勾选 → `start=1`，否则省略。
- `Finish`（完成）：`POST /nodes/{nodename}/qemu`，参数为上述集合去掉 `nodename`、`delete`，加上 `boot`/`kvm`（如适用）。成功后直接关闭窗口（返回 UPID，WebUI 创建 VM 时不弹任务查看器）；失败弹出 `Error` 对话框显示 `response.htmlStatus`。

### 3.9 VM 提交参数总表（`POST /nodes/{node}/qemu`）

| 参数 | 来源 | 何时提交 | 值格式 |
|---|---|---|---|
| `vmid` | 常规 | 总是 | 整数 |
| `name` | 常规 | 非空 | DNS 名 |
| `ha-managed` | 常规 | 勾选 | `1` |
| `pool` | 常规 | 非空 | poolid |
| `onboot` | 常规[高级] | 勾选 | `1` |
| `startup` | 常规[高级] | 任一非空 | `order=N,up=N,down=N` |
| `arch` | 常规[高级] | 非默认 | `x86_64`/`aarch64` |
| `kvm` | 计算 | arch 非宿主 | `0` |
| `tags` | 常规[高级] | 非空 | `a;b` |
| `ide2`（或 `scsi2`） | OS | 总是 | `<volid>,media=cdrom` / `cdrom,media=cdrom` / `none,media=cdrom` |
| `ide0` | OS | 勾选第二光驱 | `<volid>,media=cdrom` |
| `boot` | 计算 | 有第二光驱 | `order=<disk>;ide2;ide0;net0` |
| `ostype` | OS | 总是 | 枚举 |
| `vga`、`serialN` | 系统 | 非默认 | 枚举；`serialN=socket` |
| `machine` | 系统 | q35 | `q35` |
| `bios` | 系统 | 非默认 | `seabios`/`ovmf` |
| `efidisk0` | 系统 | ovmf+添加 EFI 盘 | `<st>:1,efitype=4m[,pre-enrolled-keys=1][,format=f]` |
| `scsihw` | 系统 | 非默认 | 枚举 |
| `agent` | 系统 | 勾选 | `1` |
| `tpmstate0` | 系统 | 添加 TPM | `<st>:1[,format=f],version=v2.0` |
| `ideN`/`sataN`/`scsiN`/`virtioN` | 磁盘 | 每块磁盘 | 见 §3.4.2 |
| `sockets`、`cores` | CPU | 总是 | 整数 |
| `cpu` | CPU | x86 总是；aarch64 仅选择了型号/标志 | `<type>[,flags=+a;-b]` |
| `vcpus`、`cpulimit`、`affinity`、`cpuunits` | CPU[高级] | 非空/非默认 | |
| `numa` | CPU[高级] | **总是** | `0`/`1` |
| `memory` | 内存 | 总是 | 整数 MiB |
| `balloon` | 内存[高级] | ballooning 关（=0）或 balloon<memory | 整数 |
| `shares` | 内存[高级] | 条件见 §3.6 | 整数 |
| `allow-ksm` | 内存[高级] | 未勾选 | `0` |
| `net0` | 网络 | 未勾选「无网络设备」 | 见 §3.7 |
| `start` | 确认 | 勾选 | `1` |

---

## 4. 创建 CT 向导（`PVE.lxc.CreateWizard`）

窗口标题：`Create: LXC Container`（创建：LXC 容器）。选项卡：常规 → 模板 → 磁盘 → CPU → 内存 → 网络 → DNS → 确认。视图模型：`nodename`、`storage`（模板存储）、`unprivileged`（默认 true）、`cgroupMode`（节点 `cgroup-mode`，缺省 2）。

### 4.1 选项卡「General / 常规」（`onlineHelp: pct_general`）

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 / 联动 | 提交 |
|---|---|---|---|---|---|---|
| 1 | `nodename` | Node / 节点 | NodeSelector | 同 VM | 必填，必须 online | URL：`POST /nodes/{nodename}/lxc` |
| 2 | `vmid` | CT ID | 数字 | `/cluster/nextid` | 同 VM（100–999999999，空闲检查，错误 `This CT ID is already in use`） | `vmid=<int>` |
| 3 | `hostname` | Hostname / 主机名 | proxmoxtextfield | 空 | 可空；VType `DnsName` | 空省略；否则 `hostname=<str>` |
| 4 | `unprivileged` | Unprivileged container / 无特权的容器 | checkbox（`uncheckedValue:0`） | **勾选** | 联动：Nesting 可用性、磁盘页 quota 可用性 | **始终提交**：`unprivileged=1` 或 `unprivileged=0` |
| 5 | `features` | Nesting / 嵌套 | checkbox（`inputValue:'nesting=1'`，`clearOnDisable`） | **勾选** | 仅 unprivileged 勾选时可用；取消无特权 → 禁用并清空（重新勾选无特权时**不会**自动恢复勾选） | 勾选 → `features=nesting=1`；否则省略 |
| 6 | `ha-managed` | Add to HA / 添加到高可用 | checkbox | 未勾选 | – | 勾选 → `ha-managed=1` |
| 7 | `pool` | Resource Pool / 资源池 | PoolSelector | 空 | 可空 | 空省略；否则 `pool=<id>` |
| 8 | `password` | Password / 密码 | 密码框 | 空 | 最少 5 字符；**当 SSH 公钥为空时必填**，有公钥时可空 | 非空 → `password=<pw>`；为空且有公钥时省略 |
| 9 | `confirmpw` | Confirm password / 确认密码 | 密码框（不提交） | 空 | 必须与 password 完全相等，否则 `Passwords do not match!`（密码不匹配！） | 不提交 |
| 10 | `ssh-public-keys` | SSH public key(s) / SSH 公钥 | 多行文本（支持拖放文件） | 空 | 按 `\n` 分行，非空行都必须能被 `parseSSHKey` 识别，否则 `Failed to recognize ssh key`。识别规则：行匹配 `^(?:((?:[^\s"]\|"(?:\\.\|[^"\\])*")+)\s+)?(\S+)\s+(\S+)(?:\s+(.*))?$`，且类型字段（第 1 或第 2 段）匹配 `^(?:(?:sk-)?(?:ssh-(?:dss\|rsa\|ed25519)\|ecdsa-sha2-nistp\d+)(?:@(?:[a-z0-9_-]+\.)+[a-z]{2,})?)$` | `ssh-public-keys=<原文>`（WebUI **即使为空也会提交空串**；iOS 可在为空时省略，效果相同） |
| 11 | （按钮 `file`） | Load SSH Key File / 加载 SSH 密钥文件 | 多文件选择 | – | 每个文件 ≤ 8192 字节（否则 `Invalid file size`）；内容 trim 后追加到 10（换行分隔） | 不提交 |
| 12 | `tags` **[高级]** | Tags / 标签 | TagFieldSet | 空 | 同 VM | `tags=a;b` |

### 4.2 选项卡「Template / 模板」（`onlineHelp: pct_container_images`）

| # | 字段 ID | 标签 | 控件 | 默认值 | 校验 | 提交 |
|---|---|---|---|---|---|---|
| 1 | `tmplstorage` | Storage / 存储 | StorageSelector（`content=vztmpl`，自动选第一个） | 第一个支持 vztmpl 的存储 | 必填 | **不提交**（确认页也不显示） |
| 2 | `ostemplate` | Template / 模板 | FileSelector（`/storage/{s}/content?content=vztmpl`，`archFilter:true`） | 空（不自动选） | 必填 | `ostemplate=<volid>`，如 `local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst` |
| – | （列表底部复选框） | Show all architectures（未翻译，po 中为模糊条目） | checkbox | 未勾选 | 未勾选时隐藏「文件名架构 ≠ 本节点架构」的模板：从 volid 用 `/_([a-z][a-z0-9]*)\.tar(?:\.\w+)?$/` 取架构，仅识别 `amd64`、`arm64`、`i386`、`riscv64`（未识别的不隐藏）；与 `Proxmox.NodeArch` 比较。全部被隐藏时显示 `No templates for this architecture. Use "Show all architectures" below.` | 不提交 |

### 4.3 选项卡「Disks / 磁盘」（`pveMultiMPPanel`，`onlineHelp: pct_container_storage`）

- 与 VM 磁盘页同样的左右布局（列表 + `Add`，**没有 Import 按钮**）。
- 自动创建 `rootfs` 卡片，**rootfs 不可删除**；`Add` 追加挂载点 `mpN`（N 取最小空闲 0–255），最多 rootfs + 256 个。排序：rootfs 在前，mp 按编号。
- 每个卡片为 `pveLxcMountPointInputPanel`，绑定 `unprivileged`。

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 适用 | 取值 / 校验 / 联动 | 提交 |
|---|---|---|---|---|---|---|---|
| 1 | `mpid` | Mount Point ID / 挂载点ID | 整数 | 最小空闲编号 | 仅 mp（rootfs 隐藏禁用） | 0–255；不能与已有 mpN 冲突（`Mount point is already in use.`）；修改即改变参数名 | 参数名 `mp<mpid>` |
| 2 | 存储 `hdstorage` | Storage / 存储 | StorageSelector（`content=rootdir`，自动选第一个） | 第一个支持 CT 卷的存储 | 全部 | 必填；切换时记录存储类型（影响 quota） | 串首段 `<storage>:<size>` |
| 3 | `disksize` | Disk size (GiB) / 磁盘大小 | 数字（3 位小数） | `8` | 全部 | 必填，0.001–131072 | 同上，如 `local-lvm:8` |
| – | `diskformat` | Format | 隐藏 | – | – | rootdir 时永远隐藏，**不进入串**（被删除） | – |
| 4 | `mp` | Path / 路径，占位 `/some/path` | textfield | 空 | 仅 mp（rootfs 隐藏禁用） | 必填；前端无格式校验（后端要求绝对路径） | `mp=<path>` |
| 5 | `backup` | Backup / 备份（提示：在备份作业中包括卷） | checkbox | 勾选 | 仅 mp（rootfs 隐藏禁用，rootfs 总是备份） | – | 勾选 → `backup=1`；否则省略 |
| 6 | `quota` **[高级]** | Enable quota / 启用配额 | checkbox | 未勾选 | 全部 | **禁用条件**：存储类型为 `zfs`/`zfspool`，或无特权容器，或 bind 挂载；禁用时重置 | 勾选 → `quota=1` |
| 7 | `ro` **[高级]** | Read-only / 只读 | checkbox | 未勾选 | 仅 mp | – | 勾选 → `ro=1` |
| 8 | `mountoptions` **[高级]** | Mount options / 挂载选项 | 多选下拉 | 空 | 全部 | mp：`discard`、`lazytime`、`noatime`、`nodev`、`noexec`、`nosuid`；**rootfs 去掉 `nodev`、`noexec`** | 非空 → `mountoptions=a;b`（按选中顺序 `;` 连接） |
| 9 | `acl` **[高级]** | ACLs | KVComboBox（`deleteEmpty:false`） | `__default__` | 全部 | `__default__`=Default（默认）、`1`=Enabled、`0`=Disabled | 非默认 → `acl=1`/`acl=0` |
| 10 | `replicate` **[高级]** | Skip replication / 跳过复制 | checkbox（`inputValue:'0'`，逻辑反转） | 未勾选 | 全部 | – | 勾选 → `replicate=0` |
| 11 | `keepattrs` **[高级]** | Keep Attributes / 保留属性（提示：保留挂载点目录的所有权和权限） | checkbox | 未勾选 | 仅 mp | – | 勾选 → `keepattrs=1` |
| 12 | `idmap` **[高级]** | ID Mapping（建议「ID 映射」；po 中为模糊条目） | 复合控件：`Passthrough`（直通）复选框 + 表格（列：ID Type（ID 类型）= `u`(UID)/`g`(GID)；Container ID（容器 ID，≥0）；Host ID（主机 ID，≥0）；Range Size（范围大小，≥1）；删除按钮）+ `Add`/`Clear` 按钮 | 空 | 全部 | 勾选 Passthrough → 值为 `passthrough` 并隐藏表格；否则把**完整的行**（四列都非空）拼成 `type:ct:host:length`，以 `;` 连接 | 非空 → `idmap=u:0:100000:65536;g:0:100000:65536` 或 `idmap=passthrough` |

挂载点串顺序（`printLxcMountPoint`）：`<storage>:<size>[,mp=<path>][,mountoptions=..][,backup=1][,quota=1][,ro=1][,acl=0|1][,replicate=0][,keepattrs=1][,idmap=..]`。
例：`rootfs=local-lvm:8`；`rootfs=local-lvm:16,mountoptions=noatime;discard`；`mp0=local-lvm:32,mp=/data,backup=1`。

### 4.4 选项卡「CPU」（`pveLxcCPUInputPanel`，`onlineHelp: pct_cpu`）

| # | 字段 ID | 标签 | 控件 | 默认值 | 取值 / 校验 | 提交 |
|---|---|---|---|---|---|---|
| 1 | `cores` | Cores / 核心，占位 `unlimited`（无限制） | 整数 | `1` | 可空；1–8192 | 空省略（= 不限）；否则 `cores=<n>` |
| 2 | `cpulimit` **[高级]** | CPU limit / CPU 限制，占位 `unlimited` | 数字（可小数） | 空 | ≥0（前端无上限；后端 0–8192） | 空或 `0` 省略 |
| 3 | `cpuunits` **[高级]** | CPU units / CPU 权重，占位 = 默认 | 整数 | 空 | 最小 8；最大：cgroup v2 10000 / v1 500000；默认 100（v2）/1024（v1） | 空或等于默认值省略 |

### 4.5 选项卡「Memory / 内存」（`pveLxcMemoryInputPanel`，`onlineHelp: pct_memory`，无高级字段）

| # | 字段 ID | 标签 | 控件 | 默认值 | 校验 | 提交 |
|---|---|---|---|---|---|---|
| 1 | `memory` | Memory (MiB) / 内存 (MiB) | 整数，步长 32 | `512` | 必填，≥16 | `memory=<n>`（总是） |
| 2 | `swap` | Swap (MiB) | 整数，步长 32 | `512` | 必填，≥0 | `swap=<n>`（总是） |

### 4.6 选项卡「Network / 网络」（`pveLxcNetworkInputPanel`，`onlineHelp: pct_container_network`，固定 `net0`，**不能选择「无网络」**）

| # | 字段 ID | 标签（英文 / 中文） | 控件 | 默认值 | 取值 / 校验 / 联动 | 提交（进入 `net0` 串） |
|---|---|---|---|---|---|---|
| – | `id` | （隐藏） | hidden | `net0` | – | 决定参数名 `net0`，不进入串 |
| 1 | `name` | Name / 名称，占位 `(e.g., eth0)` | textfield | `eth0` | 必填；与其他 netX 的 name 不可重复（向导中只有 net0） | `name=<n>` |
| 2 | `hwaddr` | MAC address / MAC 地址，占位 `auto` | textfield | 空 | VType `MacAddress` | 非空 → `hwaddr=<mac>` |
| 3 | `bridge` | Bridge / 桥接 | BridgeSelector（自动选第一个） | 第一个网桥 | 必填 | `bridge=<b>` |
| 4 | `tag` | VLAN Tag / VLAN 标签 | 数字 | 空 | 1–4094 | `tag=<n>` |
| 5 | `firewall` | Firewall / 防火墙 | checkbox | **勾选** | – | 勾选 → `firewall=1` |
| 6 | `ipv4mode` | IPv4: 单选 `Static`（静态）/ `DHCP` | radio | `static` | `static`、`dhcp`；选 dhcp 禁用 7、8 | dhcp → `ip=dhcp` |
| 7 | `ip` | IPv4/CIDR | textfield，静态时占位 `None`（无） | 空 | 可空；VType `IPCIDRAddress`（掩码 8–32） | 静态且非空 → `ip=<addr/mask>`；静态且空 → 省略 |
| 8 | `gw` | Gateway (IPv4) / 网关 (IPv4) | textfield | 空 | 可空；VType `IPAddress` | 非空 → `gw=<ip>` |
| 9 | `ipv6mode` | IPv6: 单选 `Static`（静态）/ `DHCP` / `SLAAC` | radio | `static` | `static`、`dhcp`、`auto`（SLAAC）；非 static 禁用 10、11 | dhcp → `ip6=dhcp`；SLAAC → `ip6=auto` |
| 10 | `ip6` | IPv6/CIDR | textfield | 空 | 可空；VType `IP6CIDRAddress`（掩码 8–128） | 静态且非空 → `ip6=<addr/prefix>` |
| 11 | `gw6` | Gateway (IPv6) / 网关 (IPv6) | textfield | 空 | 可空；VType `IP6Address` | 非空 → `gw6=<ip6>` |
| 12 | `link_down` **[高级]** | Disconnect / 断开 | checkbox | 未勾选 | – | 勾选 → `link_down=1` |
| 13 | `mtu` **[高级]** | MTU，占位 `Same as bridge`（与网桥相同） | 整数 | 空 | 576–65535（**无「1=继承」特殊值**） | `mtu=<n>` |
| 14 | `rate` **[高级]** | Rate limit (MB/s) / 速率限制，占位 `unlimited` | 数字 | 空 | 0–10240 | 非空 → `rate=<v>` |
| 15 | `host-managed` **[高级]** | Host-Managed / 主机管理 | checkbox | 未勾选 | – | 勾选 → `host-managed=1` |

`net0` 生成（`printLxcNetwork`）：只输出白名单键 `bridge, firewall, gw6, gw, hwaddr, ip6, ip, mtu, name, rate, tag, link_down, host-managed`，跳过空值，`k=v` 以逗号连接（顺序不影响后端）。例：
- 默认（静态但未填）：`net0=name=eth0,bridge=vmbr0,firewall=1`
- DHCP + SLAAC：`net0=name=eth0,bridge=vmbr0,firewall=1,ip6=auto,ip=dhcp`
- 静态：`net0=name=eth0,hwaddr=BC:24:11:AA:BB:CC,bridge=vmbr0,tag=20,firewall=1,ip=192.168.1.50/24,gw=192.168.1.1,ip6=2001:db8::50/64,gw6=2001:db8::1,link_down=1,mtu=9000,rate=50,host-managed=1`

### 4.7 选项卡「DNS」（`pveLxcDNSInputPanel`，无高级字段）

| # | 字段 ID | 标签 | 控件 | 默认值 | 校验 | 提交 |
|---|---|---|---|---|---|---|
| 1 | `searchdomain` | DNS domain / DNS 域，占位 `use host settings`（使用主机设置） | proxmoxtextfield | 空 | 前端无校验（后端 `dns-name-list`） | 空省略；否则 `searchdomain=<v>` |
| 2 | `nameserver` | DNS servers / DNS 服务器，占位 `use host settings` | proxmoxtextfield | 空 | VType `IP64AddressWithSuffixList`（错误示例文案 `Example: 192.168.1.1,192.168.1.2`） | 空省略；否则按 `/[ ,;]+/` 拆分后**以空格连接**：`nameserver=1.1.1.1 2606:4700:4700::1111` |

### 4.8 选项卡「Confirm / 确认」

- 同 VM：Key/Value 表按 key 升序；**不显示** `delete`、`tmplstorage`、`password`；会显示 `nodename`、`ssh-public-keys`（含空串）等其余键。
- 底部 `start`：`Start after created`（创建后启动），勾选 → `start=1`。
- `Finish`：参数去掉 `delete`、`nodename`、`tmplstorage`；`pool` 为空则删除；若 `password` 为空且 `ssh-public-keys` 非空则删除 `password`。`POST /nodes/{nodename}/lxc`。成功后**打开任务查看器**（`Proxmox.window.TaskViewer`，UPID = `response.data`）并关闭向导；失败弹出错误。

### 4.9 CT 提交参数总表（`POST /nodes/{node}/lxc`）

| 参数 | 来源 | 何时提交 | 值格式 |
|---|---|---|---|
| `vmid` | 常规 | 总是 | 整数 |
| `hostname` | 常规 | 非空 | DNS 名 |
| `unprivileged` | 常规 | **总是** | `1`/`0` |
| `features` | 常规 | 无特权且勾选嵌套 | `nesting=1` |
| `ha-managed` | 常规 | 勾选 | `1` |
| `pool` | 常规 | 非空 | poolid |
| `password` | 常规 | 非空 | 明文（≥5） |
| `ssh-public-keys` | 常规 | WebUI 总是（可为空串） | 多行 OpenSSH 公钥 |
| `tags` | 常规[高级] | 非空 | `a;b` |
| `ostemplate` | 模板 | 总是 | volid |
| `rootfs` | 磁盘 | 总是 | `<st>:<GiB>[,opts]` |
| `mp0`…`mp255` | 磁盘 | 每个添加的挂载点 | `<st>:<GiB>,mp=<path>[,opts]` |
| `cores` | CPU | 非空 | 整数 |
| `cpulimit`、`cpuunits` | CPU[高级] | 非空/非默认 | |
| `memory`、`swap` | 内存 | 总是 | 整数 MiB |
| `net0` | 网络 | 总是 | 见 §4.6 |
| `searchdomain`、`nameserver` | DNS | 非空 | |
| `start` | 确认 | 勾选 | `1` |

（后端还支持 `storage`、`force`、`restore`、`unique`、`ignore-unpack-errors`、`bwlimit` 等，向导不使用。）

---

## 5. 关键联动汇总（实现时最容易遗漏的点）

1. **节点变化** → 重新加载：存储（所有选择器）、ISO/模板列表、网桥、CPU 架构（`host-arch`）、cgroup 版本（cpuunits 默认/范围）。
2. **VM 架构**（节点 host-arch 或高级里的 vCPU 架构）→ OS 选项、光驱槽位 `ide2`/`scsi2`、总线、SCSI 控制器、机型、固件、TPM 版本、CPU 型号列表与默认、`kvm=0`。
3. **ostype** → 单磁盘总线、网卡型号、CPU 型号重置、scsihw（始终）；machine/bios/TPM（仅系统页首次显示前）；内存 2048/4096（仅内存页首次显示前）。
4. **Windows 大类** → 显示「VirtIO 驱动额外光驱」；勾选后占用 `ide0`、磁盘总线改 scsi、网卡改 virtio、生成 `boot`。
5. **bios = ovmf** → 显示「添加 EFI 磁盘」及 EFI 存储/格式/预注册密钥；`efidisk0` 仅在勾选时提交。
6. **SCSI 控制器 = virtio-scsi-single** → SCSI 磁盘 IO thread 默认勾选；VirtIO Block 磁盘总是默认勾选；IDE/SATA 禁用 IO thread；VirtIO Block 禁用 SSD 仿真；只读仅 VirtIO/SCSI。
7. **存储类型** → 格式选项（§3.4.3），`select_existing` 存储改为选择已有卷。
8. **CD 介质** → `iso` 才需要选择 ISO；`cdrom`/`none` 直接生成 `cdrom,media=cdrom` / `none,media=cdrom`。
9. **内存** → balloon 跟随 memory 且 ≤ memory；balloon==memory 时 shares 禁用、balloon 不提交；关闭 ballooning → `balloon=0`。
10. **CPU** → vcpus ≤ sockets×cores；总核心实时显示。
11. **CT 无特权** → Nesting 可用（默认勾选；关闭无特权会清空 Nesting）；quota 被禁用。
12. **CT 密码 / SSH 公钥** → 二者至少其一；密码 ≥5 且与确认一致。
13. **CT IPv4**：静态 / DHCP；**IPv6**：静态 / DHCP / SLAAC(`auto`)。静态但留空 = 不配置该族地址。
14. **VM 网络「无网络设备」** → 不提交 `net0`。

---

## 6. 不确定点 / 需注意的源码行为

1. **`ha-managed`**：两个向导都有，后端（qemu-server / pve-container 当前 master）已支持该创建参数；旧版本 PVE 9.x 可能不认识此参数，iOS 端可按服务器版本决定是否显示。
2. **CPU 型号随 OS 被清空**：`OSDefaults` 没有 `cputype`，`setWidget('CPUModelSelector', undefined)` 会把用户已选的 CPU 型号清空（实际效果：每次在 OS 页改 ostype 都回到默认型号）。这是源码行为，是否复刻由产品决定。
3. **machine / bios / TPM / 内存默认只在对应选项卡首次渲染时设置**：先访问系统页再回去改 ostype，不会更新这些值（scsihw 会更新）。
4. **VM 第一块磁盘的创建时机**：节点确定时即创建（此时 `current.ostype` 尚未设定，按 generic 计算槽位，x86 上为 `ide0`）；访问 OS 页后再被改为该 OS 的 busType。最终效果等价于「按所选 OS 的 busType 取首个空闲槽位」。
5. **LXC `ssh-public-keys` 空串**：WebUI 会提交 `ssh-public-keys=`（空），后端可接受；客户端省略亦可。
6. **LXC `pool` 为 null 时**：源码 `kv.pool.length` 理论上可能抛错（ComboGrid 清空后值为 null），属于 WebUI 缺陷，iOS 只需「空则省略」。
7. **VM `startup` 子字段**：前端无校验，非法值由后端报错（`pve-startup-order`：`[[order=]\d+][,up=\d+][,down=\d+]`）。
8. **CPU 标志表在创建向导中**：未调用 `setKvm`，请求不带 `accel` 参数；当选择非宿主架构（实际会以 TCG 运行）时，显示的仍是 KVM 视角的标志。
9. **`maxCount = 312`**（VM 磁盘）包含 `unused` 总线的 256，属源码计算方式；实际可用槽位：IDE 4 + SATA 6 + VirtIO 16 + SCSI 31 减去光驱占用。
10. **中文标签**：`vCPU Architecture`、`Host Architecture`、`Extra CPU Flags:`、`ID Mapping`、`Passthrough`、`ID Type`、`Container ID`、`Host ID`、`Range Size`、`Show all architectures` 在 zh_CN.po 中为 fuzzy（有的明显译错，如 ID Mapping→「DHCP 映射」），`x86 (64-bit)`、`ARM (64-bit)`、`Only show flags supported by at least one node` 未翻译。本文对这些给出了建议译名（vCPU 架构 / 宿主架构 / 额外 CPU 标志 / ID 映射 / 直通 / ID 类型 / 容器 ID / 主机 ID / 范围大小 / 显示所有架构）。`VM ID` / `CT ID` 标签由 `'{0} ID'` 拼接，不经过翻译。

---

## 7. 实现检查清单（每个字段 ID 只列一次）

说明：`[A]` = 高级字段；`(UI)` = 仅 UI 控件不提交；`→param` = 最终参数名。

### 7.1 通用
- [ ] `advanced`（UI，持久化键 `proxmox-advanced-cb`）
- [ ] 选项卡有效性门控 / Back / Next / Finish

### 7.2 VM · 常规
- [ ] `nodename`（URL）
- [ ] `vmid`
- [ ] `name`
- [ ] `ha-managed`
- [ ] `pool`
- [ ] `onboot` [A]
- [ ] `order` [A] →`startup`
- [ ] `up` [A] →`startup`
- [ ] `down` [A] →`startup`
- [ ] `arch` [A]（含 `kvm=0` 计算）
- [ ] `tags` [A]

### 7.3 VM · 操作系统
- [ ] `mediaType`（UI）
- [ ] `cdimage`（存储 + ISO 文件）→`ide2`/`scsi2`
- [ ] `osbase`（UI）
- [ ] `ostype`
- [ ] `enableSecondCD`（UI）
- [ ] `ide0`（存储 + ISO 文件）
- [ ] `boot`（计算）

### 7.4 VM · 系统
- [ ] `vga`（含 `serialN=socket`）
- [ ] `machine`
- [ ] `bios`
- [ ] `addefi`（UI）
- [ ] `efidisk0`：`hdstorage` / `hdimage` / `diskformat` / `preEnrolledKeys`
- [ ] `scsihw`
- [ ] `agent`
- [ ] `addtpm`（UI）
- [ ] `tpmstate0`：`hdstorage` / `hdimage` / `diskformat` / `version`

### 7.5 VM · 磁盘（每块）
- [ ] 磁盘列表增删（Add / Import / 删除）
- [ ] `controller` + `deviceid` →`<bus><id>`
- [ ] `scsiController`（UI 显示）
- [ ] `hdstorage`
- [ ] `hdimage`
- [ ] `disksize`
- [ ] `diskformat` →`format`
- [ ] `cache`
- [ ] `discard`
- [ ] `iothread`
- [ ] `ssd` [A]
- [ ] `readOnly` [A] →`ro`
- [ ] `backup` [A]
- [ ] `noreplicate` [A] →`replicate=no`
- [ ] `aio` [A]
- [ ] `mbps_rd`
- [ ] `mbps_wr`
- [ ] `iops_rd`
- [ ] `iops_wr`
- [ ] `mbps_rd_max`
- [ ] `mbps_wr_max`
- [ ] `iops_rd_max`
- [ ] `iops_wr_max`
- [ ] `import-source-storage`（UI，导入卡片）
- [ ] `import-from`（导入卡片）

### 7.6 VM · CPU
- [ ] `sockets`
- [ ] `cores`
- [ ] `cputype` →`cpu`
- [ ] `totalcores`（UI）
- [ ] `vcpus` [A]
- [ ] `cpulimit` [A]
- [ ] `affinity` [A]
- [ ] `cpuunits` [A]
- [ ] `numa` [A]
- [ ] `flags` [A] →`cpu`

### 7.7 VM · 内存
- [ ] `memory`
- [ ] `balloon` [A]
- [ ] `shares` [A]
- [ ] `ballooning` [A]（UI，影响 `balloon=0`）
- [ ] `allow-ksm` [A]

### 7.8 VM · 网络
- [ ] `nonetwork`（UI）
- [ ] `bridge` →`net0`
- [ ] `tag` →`net0`
- [ ] `firewall` →`net0`
- [ ] `model` →`net0`
- [ ] `macaddr` →`net0`
- [ ] `disconnect` [A] →`net0 link_down`
- [ ] `mtu` [A] →`net0`
- [ ] `rate` [A] →`net0`
- [ ] `queues` [A] →`net0`

### 7.9 VM · 确认
- [ ] 摘要表（Key/Value，按 key 排序）
- [ ] `start`

### 7.10 CT · 常规
- [ ] `nodename`（URL；同 VM 实现可复用）
- [ ] `vmid`（CT ID）
- [ ] `hostname`
- [ ] `unprivileged`
- [ ] `features`（nesting）
- [ ] `ha-managed`（CT）
- [ ] `pool`（CT）
- [ ] `password`
- [ ] `confirmpw`（UI）
- [ ] `ssh-public-keys`
- [ ] `file`（UI，加载公钥文件）
- [ ] `tags`（CT）[A]

### 7.11 CT · 模板
- [ ] `tmplstorage`（UI）
- [ ] `ostemplate`
- [ ] 「显示所有架构」开关（UI）

### 7.12 CT · 磁盘（rootfs + 每个 mp）
- [ ] 挂载点列表增删（rootfs 不可删）
- [ ] `mpid` →`mp<N>`
- [ ] `hdstorage`（rootdir）
- [ ] `disksize`（默认 8）
- [ ] `mp`（路径）
- [ ] `backup`（mp）
- [ ] `quota` [A]
- [ ] `ro` [A]
- [ ] `mountoptions` [A]
- [ ] `acl` [A]
- [ ] `replicate` [A]
- [ ] `keepattrs` [A]
- [ ] `idmap` [A]

### 7.13 CT · CPU
- [ ] `cores`（CT）
- [ ] `cpulimit`（CT）[A]
- [ ] `cpuunits`（CT）[A]

### 7.14 CT · 内存
- [ ] `memory`（CT）
- [ ] `swap`

### 7.15 CT · 网络
- [ ] `id`（隐藏，`net0`）
- [ ] `name`（接口名）
- [ ] `hwaddr`
- [ ] `bridge`（CT）
- [ ] `tag`（CT）
- [ ] `firewall`（CT）
- [ ] `ipv4mode`
- [ ] `ip`
- [ ] `gw`
- [ ] `ipv6mode`
- [ ] `ip6`
- [ ] `gw6`
- [ ] `link_down` [A]
- [ ] `mtu`（CT）[A]
- [ ] `rate`（CT）[A]
- [ ] `host-managed` [A]

### 7.16 CT · DNS
- [ ] `searchdomain`
- [ ] `nameserver`

### 7.17 CT · 确认
- [ ] 摘要表（隐藏 `password`、`tmplstorage`）
- [ ] `start`（CT）
- [ ] 成功后打开任务查看器（UPID）
