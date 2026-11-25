import Foundation
import PVEKit

/// Fixture data of the demo server: one node `pve`; running, stopped and template VMs and CTs;
/// storages `local` (ISO + CT templates + backups) and `local-zfs`; PVE 9 RRD data including
/// `memavailable` and `arcsize`. Objects use the field names of real PVE 9 responses.
enum DemoData {
    static let node = "pve"
    static let serverID = UUID(uuidString: "C0FFEE00-DEAD-4BEE-8000-000000000001")!
    static let sampleDownloadURL = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.2.0-amd64-netinst.iso"

    static let gib = 1_073_741_824.0
    static let memTotal = 128 * gib

    struct Guest {
        let vmid: Int
        let type: String
        let name: String
        let status: String
        let template: Bool
        let cores: Int
        let maxmem: Double
        let mem: Double
        let maxdisk: Double
        let disk: Double
        let cpu: Double
        let uptime: Int
        var tags: String = ""
    }

    static let guests: [Guest] = [
        Guest(vmid: 100, type: "qemu", name: "debian-web", status: "running", template: false, cores: 4, maxmem: 8 * gib, mem: 3.2 * gib, maxdisk: 32 * gib, disk: 0, cpu: 0.031, uptime: 2_527_200, tags: "web"),
        Guest(vmid: 101, type: "qemu", name: "win11-desktop", status: "stopped", template: false, cores: 8, maxmem: 16 * gib, mem: 0, maxdisk: 128 * gib, disk: 0, cpu: 0, uptime: 0, tags: "desktop;windows"),
        Guest(vmid: 102, type: "qemu", name: "homeassistant", status: "running", template: false, cores: 2, maxmem: 4 * gib, mem: 2.6 * gib, maxdisk: 32 * gib, disk: 0, cpu: 0.012, uptime: 604_800),
        Guest(vmid: 200, type: "lxc", name: "pihole", status: "running", template: false, cores: 1, maxmem: 0.5 * gib, mem: 0.13 * gib, maxdisk: 8 * gib, disk: 1.2 * gib, cpu: 0.004, uptime: 2_527_200),
        Guest(vmid: 201, type: "lxc", name: "build-runner", status: "stopped", template: false, cores: 4, maxmem: 4 * gib, mem: 0, maxdisk: 32 * gib, disk: 6.4 * gib, cpu: 0, uptime: 0),
        Guest(vmid: 9000, type: "qemu", name: "tpl-debian-13", status: "stopped", template: true, cores: 2, maxmem: 2 * gib, mem: 0, maxdisk: 16 * gib, disk: 0, cpu: 0, uptime: 0),
        Guest(vmid: 9001, type: "lxc", name: "tpl-alpine", status: "stopped", template: true, cores: 1, maxmem: 0.5 * gib, mem: 0, maxdisk: 4 * gib, disk: 0, cpu: 0, uptime: 0),
    ]

    struct Store {
        let name: String
        let type: String
        let content: String
        let total: Double
        let used: Double
    }

    static let storages: [Store] = [
        Store(name: "local", type: "dir", content: "iso,vztmpl,backup,snippets", total: 93.9 * gib, used: 21.4 * gib),
        Store(name: "local-zfs", type: "zfspool", content: "images,rootdir", total: 1.72 * 1024 * gib, used: 412 * gib),
    ]

    // MARK: Cluster

    static func clusterResources() -> [[String: Any]] {
        var list: [[String: Any]] = [[
            "id": "node/\(node)", "type": "node", "node": node, "status": "online",
            "cpu": 0.046, "maxcpu": 32, "mem": 61 * gib, "maxmem": memTotal,
            "disk": 21.4 * gib, "maxdisk": 93.9 * gib, "uptime": 2_527_200 + 21_600, "level": "",
            "host-arch": "x86_64", "cgroup-mode": 2,
        ], [
            "id": "node/\(secondNode)", "type": "node", "node": secondNode, "status": "online",
            "cpu": 0.012, "maxcpu": 8, "mem": 6 * gib, "maxmem": 32 * gib,
            "disk": 8.2 * gib, "maxdisk": 58 * gib, "uptime": 864_000, "level": "",
            "host-arch": "x86_64", "cgroup-mode": 2,
        ]]
        for guest in guests {
            var entry: [String: Any] = [
                "id": "\(guest.type)/\(guest.vmid)", "type": guest.type, "vmid": guest.vmid, "name": guest.name,
                "node": node, "status": guest.status, "template": guest.template ? 1 : 0,
                "maxcpu": guest.cores, "maxmem": guest.maxmem, "maxdisk": guest.maxdisk, "disk": guest.disk,
                "cpu": guest.cpu, "mem": guest.mem, "uptime": guest.uptime,
                "netin": 0, "netout": 0, "diskread": 0, "diskwrite": 0,
            ]
            if !guest.tags.isEmpty { entry["tags"] = guest.tags }
            list.append(entry)
        }
        for store in storages {
            list.append([
                "id": "storage/\(node)/\(store.name)", "type": "storage", "storage": store.name, "node": node,
                "status": "available", "plugintype": store.type, "shared": 0, "content": store.content,
                "disk": store.used, "maxdisk": store.total,
            ])
        }
        return list
    }

    /// Like PVE with `?path=`: the effective privileges are keyed by the queried path.
    static func permissions(path: String?) -> [String: Any] {
        let privileges = Privilege.allCases.map(\.rawValue)
        let map = Dictionary(uniqueKeysWithValues: privileges.map { ($0, 1) })
        var result: [String: Any] = ["/": map]
        if let path, !path.isEmpty { result[path] = map }
        return result
    }

    // MARK: Node

    static func nodeStatus(node: String) -> [String: Any] {
        [
            "cpu": 0.046, "wait": 0.0012, "uptime": 2_527_200 + 21_600,
            "loadavg": ["1.12", "0.98", "0.91"],
            "memory": ["used": 61 * gib, "total": memTotal, "free": memTotal - 61 * gib, "available": memTotal - 61 * gib],
            "swap": ["used": 0, "total": 8 * gib, "free": 8 * gib],
            "rootfs": ["used": 21.4 * gib, "total": 93.9 * gib, "free": 72.5 * gib, "avail": 67.7 * gib],
            "cpuinfo": ["model": "AMD RYZEN AI MAX+ 395 w/ Radeon 8060S", "cpus": 32, "sockets": 1, "cores": 16, "mhz": "5187.000"],
            "pveversion": "pve-manager/9.2.21/7a3b6f9c0d1e2f34",
            "kversion": "Linux 7.0.14-25-pve #1 SMP PREEMPT_DYNAMIC PMX 7.0.14-25 (2026-11-02T09:12Z) x86_64",
            "current-kernel": ["sysname": "Linux", "release": "7.0.14-25-pve", "machine": "x86_64", "version": "#1 SMP PREEMPT_DYNAMIC PMX 7.0.14-25 (2026-11-02T09:12Z)"],
            "boot-info": ["mode": "efi", "secureboot": 1],
        ]
    }

    // MARK: RRD

    static func step(_ timeframe: RRDTimeframe) -> TimeInterval {
        switch timeframe {
        case .hour: return 60
        case .day: return 1800
        case .week: return 10800
        case .month: return 43200
        case .year: return 604_800
        }
    }

    /// 70 rows ending now, values from smooth deterministic curves.
    static func rows(_ timeframe: RRDTimeframe, _ make: (Int, Double) -> [String: Any]) -> [[String: Any]] {
        let count = 70
        let step = step(timeframe)
        let end = (Date().timeIntervalSince1970 / step).rounded(.down) * step
        return (0..<count).map { index in
            let phase = Double(index) / Double(count)
            var row = make(index, phase)
            row["time"] = Int(end - Double(count - 1 - index) * step)
            return row
        }
    }

    static func wave(_ phase: Double, _ periods: Double, _ offset: Double = 0) -> Double {
        sin((phase * periods + offset) * 2 * .pi)
    }

    static func nodeRRD(timeframe: RRDTimeframe) -> [[String: Any]] {
        rows(timeframe) { _, phase in
            let used = (58 + 6 * wave(phase, 1.5) + 2 * wave(phase, 7, 0.3)) * gib
            let arc = (21 + 2.5 * wave(phase, 1, 0.2)) * gib
            return [
                "loadavg": 1.0 + 0.4 * wave(phase, 3),
                "maxcpu": 32,
                "cpu": 0.05 + 0.03 * wave(phase, 4) + 0.012 * wave(phase, 13, 0.1),
                "iowait": 0.002 + 0.0015 * wave(phase, 5, 0.4),
                "memtotal": memTotal,
                "memused": used,
                "memavailable": memTotal - used,
                "arcsize": arc,
                "swaptotal": 8 * gib,
                "swapused": 0,
                "roottotal": 93.9 * gib,
                "rootused": 21.4 * gib,
                "netin": (220 + 140 * wave(phase, 3, 0.1) + 60 * wave(phase, 11)) * 1024,
                "netout": (90 + 50 * wave(phase, 2, 0.6) + 20 * wave(phase, 9)) * 1024,
                "pressurecpusome": 0.01, "pressureiosome": 0.002, "pressureiofull": 0.001,
                "pressurememorysome": 0, "pressurememoryfull": 0,
            ]
        }
    }

    static func guestRRD(type: String, vmid: Int, timeframe: RRDTimeframe) -> [[String: Any]] {
        guard let guest = guests.first(where: { $0.vmid == vmid }) else { return [] }
        let seed = Double(vmid % 7) / 7
        return rows(timeframe) { _, phase in
            var row: [String: Any] = ["maxcpu": guest.cores, "maxmem": guest.maxmem, "maxdisk": guest.maxdisk, "disk": guest.disk]
            guard guest.status == "running" else { return row }
            let mem = min(guest.mem * (1 + 0.12 * wave(phase, 2, seed)), guest.maxmem)
            row["cpu"] = max(guest.cpu * (1 + 0.6 * wave(phase, 5, seed)) + 0.01 * wave(phase, 17), 0)
            row["mem"] = mem
            row["netin"] = (40 + 30 * wave(phase, 4, seed)) * 1024
            row["netout"] = (18 + 12 * wave(phase, 3, seed + 0.2)) * 1024
            row["diskread"] = (120 + 110 * wave(phase, 6, seed)) * 1024
            row["diskwrite"] = (260 + 200 * wave(phase, 5, seed + 0.5)) * 1024
            row["pressurecpusome"] = 0
            if type == "qemu" { row["memhost"] = mem + 0.35 * gib }
            return row
        }
    }

    // MARK: Guests

    static func guestStatus(type: String, vmid: Int) -> [String: Any]? {
        guard let guest = guests.first(where: { $0.vmid == vmid && $0.type == type }) else { return nil }
        var status: [String: Any] = [
            "status": guest.status, "name": guest.name, "vmid": guest.vmid, "cpus": guest.cores,
            "cpu": guest.cpu, "mem": guest.mem, "maxmem": guest.maxmem, "disk": guest.disk, "maxdisk": guest.maxdisk,
            "uptime": guest.uptime, "netin": 123_456_789, "netout": 98_765_432, "diskread": 2_147_483_648,
            "diskwrite": 1_073_741_824, "template": guest.template ? 1 : 0, "tags": guest.tags,
        ]
        if type == "qemu" {
            status["qmpstatus"] = guest.status
            status["agent"] = 1
        } else {
            status["swap"] = 0
            status["maxswap"] = 512 * 1_048_576
        }
        return status
    }

    static func guestConfig(type: String, vmid: Int) -> [String: Any] {
        guard let guest = guests.first(where: { $0.vmid == vmid }) else { return [:] }
        let memoryMiB = Int(guest.maxmem / 1_048_576)
        if type == "lxc" {
            return [
                "hostname": guest.name, "arch": "amd64", "ostype": guest.name.contains("alpine") ? "alpine" : "debian",
                "cores": guest.cores, "memory": memoryMiB, "swap": 512,
                "rootfs": "local-zfs:subvol-\(vmid)-disk-0,size=\(Int(guest.maxdisk / gib))G",
                "net0": "name=eth0,bridge=vmbr0,firewall=1,hwaddr=BC:24:11:5E:2A:\(String(format: "%02X", vmid % 256)),ip=dhcp,type=veth",
                "onboot": 1, "unprivileged": 1, "features": "nesting=1", "digest": "0123456789abcdef",
                "description": guestNotes(vmid: vmid),
            ]
        }
        return [
            "name": guest.name, "ostype": guest.name.contains("win") ? "win11" : "l26", "cores": guest.cores, "sockets": 1,
            "cpu": "host", "memory": memoryMiB, "balloon": 0, "boot": "order=scsi0;net0", "onboot": 1,
            "scsihw": "virtio-scsi-single", "machine": "q35", "bios": "ovmf", "agent": "1",
            "scsi0": "local-zfs:vm-\(vmid)-disk-0,iothread=1,size=\(Int(guest.maxdisk / gib))G",
            "efidisk0": "local-zfs:vm-\(vmid)-disk-1,efitype=4m,size=1M",
            "net0": "virtio=BC:24:11:3F:7A:\(String(format: "%02X", vmid % 256)),bridge=vmbr0,firewall=1",
            "ide2": "local:iso/debian-13.2.0-amd64-netinst.iso,media=cdrom,size=754M",
            "description": guestNotes(vmid: vmid),
            "digest": "0123456789abcdef",
        ]
    }

    static func snapshots() -> [[String: Any]] {
        let now = Int(Date().timeIntervalSince1970)
        return [
            ["name": "base", "description": "fresh install", "snaptime": now - 86400 * 40],
            ["name": "before-upgrade", "description": "", "snaptime": now - 86400 * 3, "parent": "base", "vmstate": 1],
            ["name": "current", "description": "You are here!", "parent": "before-upgrade", "running": 1],
        ]
    }

    // MARK: Storage

    static func storageStatus(_ name: String) -> [String: Any]? {
        guard let store = storages.first(where: { $0.name == name }) else { return nil }
        return [
            "type": store.type, "content": store.content, "total": store.total, "used": store.used,
            "avail": store.total - store.used, "active": 1, "enabled": 1, "shared": 0,
        ]
    }

    static func storageContent(_ name: String) -> [[String: Any]] {
        let now = Int(Date().timeIntervalSince1970)
        switch name {
        case "local":
            return [
                ["volid": "local:iso/debian-13.2.0-amd64-netinst.iso", "content": "iso", "format": "iso", "size": 790_626_304, "ctime": now - 86400 * 12],
                ["volid": "local:iso/ubuntu-26.04-live-server-amd64.iso", "content": "iso", "format": "iso", "size": 3_221_225_472, "ctime": now - 86400 * 30],
                ["volid": "local:iso/virtio-win-0.1.285.iso", "content": "iso", "format": "iso", "size": 754_974_720, "ctime": now - 86400 * 64],
                ["volid": "local:iso/Win11_25H2_Chinese_Simplified_x64_and_some_long_suffix.iso", "content": "iso", "format": "iso", "size": 7_784_628_224, "ctime": now - 86400 * 70],
                ["volid": "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst", "content": "vztmpl", "format": "tzst", "size": 131_072_000, "ctime": now - 86400 * 20],
                ["volid": "local:vztmpl/alpine-3.22-default_20250617_amd64.tar.xz", "content": "vztmpl", "format": "txz", "size": 3_145_728, "ctime": now - 86400 * 40],
                ["volid": "local:backup/vzdump-lxc-200-2026_11_22-03_00_01.tar.zst", "content": "backup", "format": "tar.zst", "size": 412_316_860, "ctime": now - 86400, "vmid": 200, "subtype": "lxc"],
                ["volid": "local:backup/vzdump-qemu-100-2026_11_22-03_00_02.vma.zst", "content": "backup", "format": "vma.zst", "size": 2_147_483_648, "ctime": now - 86400 + 120, "vmid": 100, "subtype": "qemu", "protected": 1],
                ["volid": "local:snippets/cloud-init-user.yaml", "content": "snippets", "format": "snippet", "size": 0, "ctime": now - 86400 * 90],
            ]
        case "local-zfs":
            return guests.flatMap { guest -> [[String: Any]] in
                if guest.type == "qemu" {
                    return [["volid": "local-zfs:\(guest.template ? "base" : "vm")-\(guest.vmid)-disk-0", "content": "images", "format": "raw", "size": guest.maxdisk, "used": guest.maxdisk * 0.3, "vmid": guest.vmid]]
                }
                return [["volid": "local-zfs:\(guest.template ? "basevol" : "subvol")-\(guest.vmid)-disk-0", "content": "rootdir", "format": "subvol", "size": guest.maxdisk, "used": guest.disk, "vmid": guest.vmid]]
            }
        default:
            return []
        }
    }

    static func urlMetadata(_ url: String) -> [String: Any] {
        let name = URL(string: url)?.lastPathComponent ?? "download.iso"
        return ["filename": name, "mimetype": name.hasSuffix(".iso") ? "application/x-iso9660-image" : "application/octet-stream", "size": 790_626_304]
    }

    static func applianceTemplates() -> [[String: Any]] {
        func template(_ file: String, _ package: String, _ version: String, _ os: String, _ section: String, _ headline: String, _ description: String, architecture: String = "amd64") -> [String: Any] {
            [
                "template": file, "package": package, "version": version, "os": os, "section": section, "type": "lxc",
                "headline": headline, "description": description, "architecture": architecture,
                "location": "http://download.proxmox.com/images/\(section)/\(file)",
            ]
        }
        return [
            template("debian-13-standard_13.1-2_amd64.tar.zst", "debian-13-standard", "13.1-2", "debian-13", "system", "Debian 13 (standard)", "A small Debian Trixie system including all standard packages."),
            // Same template for two architectures: told apart by the second line.
            template("debian-13-standard_13.1-2_arm64.tar.zst", "debian-13-standard", "13.1-2", "debian-13", "system", "Debian 13 (standard)", "A small Debian Trixie system including all standard packages.", architecture: "arm64"),
            template("debian-12-standard_12.12-1_amd64.tar.zst", "debian-12-standard", "12.12-1", "debian-12", "system", "Debian 12 (standard)", "A small Debian Bookworm system including all standard packages."),
            template("ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst", "ubuntu-25.04-standard", "25.04-1.1", "ubuntu-25.04", "system", "Ubuntu 25.04 (standard)", "A small Ubuntu 25.04 Plucky Puffin system."),
            template("alpine-3.22-default_20250617_amd64.tar.xz", "alpine-3.22-default", "20250617", "alpine", "system", "Alpine Linux 3.22 (default)", "A security-oriented, lightweight Linux distribution."),
            template("alpine-3.22-default_20250617_arm64.tar.xz", "alpine-3.22-default", "20250617", "alpine", "system", "Alpine Linux 3.22 (default)", "A security-oriented, lightweight Linux distribution.", architecture: "arm64"),
            template("archlinux-base_20250705-1_amd64.tar.zst", "archlinux-base", "20250705-1", "archlinux", "system", "Arch Linux (base)", "A lightweight and flexible Linux distribution."),
            template("rockylinux-10-default_20250615_amd64.tar.xz", "rockylinux-10-default", "20250615", "rockylinux", "system", "Rocky Linux 10 (default)", "An enterprise operating system."),
            template("fedora-42-default_20250428_amd64.tar.xz", "fedora-42-default", "20250428", "fedora", "system", "Fedora 42 (default)", "A Linux distribution developed by the Fedora Project."),
            template("proxmox-mailgateway-9.0-standard_9.0-1_amd64.tar.zst", "proxmox-mailgateway-9.0-standard", "9.0-1", "debian-13", "mail", "Proxmox Mail Gateway 9.0", "Full featured mail proxy."),
            template("debian-12-turnkey-nextcloud_18.2-1_amd64.tar.gz", "turnkey-nextcloud", "18.2-1", "debian-12", "turnkeylinux", "TurnKey Nextcloud", "Store, share and access your files."),
            template("debian-12-turnkey-gitea_18.1-1_amd64.tar.gz", "turnkey-gitea", "18.1-1", "debian-12", "turnkeylinux", "TurnKey Gitea", "Lightweight self-hosted Git service."),
            template("debian-12-turnkey-wordpress_18.3-1_amd64.tar.gz", "turnkey-wordpress", "18.3-1", "debian-12", "turnkeylinux", "TurnKey WordPress", "Blog publishing platform and CMS."),
        ]
    }

    // MARK: Tasks

    struct StartedTask {
        let node: String
        let type: String
        let objectID: String
        let start: Date
        let pid: Int

        static let duration: TimeInterval = 4

        var upid: String {
            DemoData.upid(node: node, pid: pid, start: start, type: type, id: objectID)
        }

        func isRunning(now: Date = Date()) -> Bool {
            now.timeIntervalSince(start) < Self.duration
        }

        func progress(now: Date = Date()) -> Double {
            min(max(now.timeIntervalSince(start) / Self.duration, 0), 1)
        }
    }

    static let user = "root@pam!demo"

    static func upid(node: String, pid: Int, start: Date, type: String, id: String) -> String {
        let hex = { (value: Int) in String(format: "%08X", value) }
        return "UPID:\(node):\(hex(pid)):\(hex(pid * 7)):\(hex(Int(start.timeIntervalSince1970))):\(type):\(id):\(user):"
    }

    /// Finished history (relative to now) plus tasks started in this session.
    static func tasks(started: [StartedTask], vmid: Int?, typefilter: String? = nil) -> [[String: Any]] {
        let now = Int(Date().timeIntervalSince1970)
        let history: [(Int, String, String, Int, String)] = [
            (600, "qmstart", "100", 4, "OK"),
            (3_600, "vzdump", "200", 95, "OK"),
            (3_700, "vzdump", "100", 310, "OK"),
            (7_200, "qmsnapshot", "100", 12, "OK"),
            (86_400, "download", "local", 48, "OK"),
            (86_405, "vzdump", "100", 300, "OK"),
            (86_410, "vzdump", "200", 90, "OK"),
            (90_000, "vzstart", "201", 2, "startup for container '201' failed"),
            (172_800, "aptupdate", "", 21, "WARNINGS: 1"),
            (259_200, "qmshutdown", "101", 38, "OK"),
        ]
        var list: [[String: Any]] = history.enumerated().map { index, item in
            let start = now - item.0
            return [
                "upid": upid(node: node, pid: 0x2000 + index, start: Date(timeIntervalSince1970: TimeInterval(start)), type: item.1, id: item.2),
                "node": node, "type": item.1, "id": item.2, "user": user,
                "starttime": start, "endtime": start + item.3, "status": item.4,
            ]
        }
        for task in started {
            var entry: [String: Any] = [
                "upid": task.upid, "node": task.node, "type": task.type, "id": task.objectID, "user": user,
                "starttime": Int(task.start.timeIntervalSince1970),
            ]
            if !task.isRunning() {
                entry["endtime"] = Int(task.start.timeIntervalSince1970 + StartedTask.duration)
                entry["status"] = "OK"
            }
            list.append(entry)
        }
        if let vmid {
            list = list.filter { ($0["id"] as? String) == String(vmid) }
        }
        if let typefilter, !typefilter.isEmpty {
            list = list.filter { ($0["type"] as? String) == typefilter }
        }
        return list.sorted { ($0["starttime"] as? Int ?? 0) > ($1["starttime"] as? Int ?? 0) }
    }

    static func taskStatus(upid: String, started: StartedTask?) -> [String: Any] {
        let parsed = UPID(upid)
        var status: [String: Any] = [
            "upid": upid, "node": parsed?.node ?? node, "type": parsed?.type ?? "", "id": parsed?.objectID ?? "",
            "user": parsed?.user ?? user, "starttime": Int(parsed?.startTime.timeIntervalSince1970 ?? 0), "pid": parsed?.pid ?? 0,
        ]
        if let started, started.isRunning() {
            status["status"] = "running"
        } else {
            status["status"] = "stopped"
            status["exitstatus"] = parsed?.objectID == "201" && parsed?.type == "vzstart" ? "startup for container '201' failed" : "OK"
        }
        return status
    }

    static func taskLog(upid: String, started: StartedTask?) -> [[String: Any]] {
        var lines: [String]
        if let started, started.type == "download" {
            let total = 790.63
            let fraction = started.progress()
            lines = ["downloading \(sampleDownloadURL) to /var/lib/vz/template/iso/debian-13.2.0-amd64-netinst.iso"]
            var step = 0.0
            while step <= fraction {
                lines.append(String(format: "%.2f MiB of %.2f MiB (%.2f%%)", total * step, total, step * 100))
                step += 0.25
            }
            if !started.isRunning() {
                lines.append("download of '\(sampleDownloadURL)' to '/var/lib/vz/template/iso/debian-13.2.0-amd64-netinst.iso' finished")
                lines.append("TASK OK")
            }
        } else if let parsed = UPID(upid), parsed.type == "vzdump", started == nil || started?.isRunning() == false {
            lines = vzdumpLog(objectID: parsed.objectID)
        } else if let started {
            lines = ["starting \(started.type) for \(started.objectID)"]
            if !started.isRunning() { lines.append("TASK OK") }
        } else {
            lines = ["demo task output", "TASK OK"]
        }
        return lines.enumerated().map { ["n": $0.offset + 1, "t": $0.element] }
    }
}
