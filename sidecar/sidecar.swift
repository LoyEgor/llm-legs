import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    var msg = message
    msg.append("\n")
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(code)
}

// SidecarCore.framework has no on-disk file on this macOS version (broken symlink),
// but the dyld shared cache still resolves this path, so dlopen succeeds and registers
// the ObjC classes below.
guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW) != nil else {
    fail("SidecarCore framework failed to load", 5)
}

guard let managerClass = NSClassFromString("SidecarDisplayManager"), managerClass is NSObject.Type else {
    fail("SidecarDisplayManager class not found (framework internals changed)", 5)
}

guard let manager = (managerClass as AnyObject).perform(Selector(("sharedManager")))?.takeUnretainedValue() as? NSObject else {
    fail("sharedManager returned nil", 5)
}

func deviceName(_ device: AnyObject) -> String {
    guard let name = device.perform(Selector(("name")))?.takeUnretainedValue() as? String else {
        return "<unnamed>"
    }
    return name
}

func devices() -> [NSObject] {
    manager.perform(Selector(("devices")))?.takeUnretainedValue() as? [NSObject] ?? []
}

func connectedDevices() -> [NSObject] {
    manager.perform(Selector(("connectedDevices")))?.takeUnretainedValue() as? [NSObject] ?? []
}

func runCompletion(_ selector: Selector, _ device: NSObject, verb: String) {
    guard manager.responds(to: selector) else {
        fail("\(verb) not supported: SidecarDisplayManager does not respond to \(selector) (framework internals changed)", 5)
    }
    let group = DispatchGroup()
    var completionError: NSError?
    group.enter()
    let block: @convention(block) (NSError?) -> Void = { error in
        completionError = error
        group.leave()
    }
    _ = manager.perform(selector, with: device, with: block)
    if group.wait(timeout: .now() + 20) == .timedOut {
        fail("\(verb) timed out after 20s (completion never fired)", 6)
    }
    if let error = completionError {
        fail("\(verb) failed: \(error.description)", 4)
    }
}

let args = CommandLine.arguments
guard args.count > 1 else {
    fail("usage: sidecar list | connect <name-substring> | disconnect | refresh", 1)
}

switch args[1] {
case "list":
    for device in devices() {
        print(deviceName(device))
    }
    exit(0)

case "connect":
    guard args.count >= 3, !args[2].isEmpty else {
        fail("usage: sidecar connect <name-substring>", 1)
    }
    let needle = args[2].lowercased()
    let all = devices()
    for device in all {
        if deviceName(device).lowercased().contains(needle) {
            runCompletion(Selector(("connectToDevice:completion:")), device, verb: "connect")
            exit(0)
        }
    }
    let available = all.map { deviceName($0) }.joined(separator: ", ")
    fail("no reachable device matching '\(needle)'. Available: \(available)", all.isEmpty ? 2 : 3)

case "disconnect":
    let connected = connectedDevices()
    guard !connected.isEmpty else {
        fail("no connected sidecar devices", 2)
    }
    for device in connected {
        runCompletion(Selector(("disconnectFromDevice:completion:")), device, verb: "disconnect")
    }
    exit(0)

case "refresh":
    guard let deviceClass = NSClassFromString("SidecarDevice"), deviceClass is NSObject.Type else {
        fail("SidecarDevice class not found", 5)
    }
    guard (deviceClass as AnyObject).responds(to: Selector(("allDevicesByForcingFetchFromRelay:"))) else {
        fail("allDevicesByForcingFetchFromRelay: not available", 5)
    }
    let result = (deviceClass as AnyObject).perform(Selector(("allDevicesByForcingFetchFromRelay:")), with: true)?.takeUnretainedValue() as? [NSObject] ?? []
    if result.isEmpty {
        print("(relay refresh returned no devices)")
        exit(0)
    }
    for device in result {
        print(deviceName(device))
    }
    exit(0)

default:
    fail("unknown command '\(args[1])'. usage: sidecar list | connect <name-substring> | disconnect | refresh", 1)
}
