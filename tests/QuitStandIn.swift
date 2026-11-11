// A stand-in for the app, for the quit tests in run-tests.sh. Built from the
// app's own ChildCleanup.swift and BridgeCheck.swift, so the stopping and the
// signal handling under test are the shipped code, not a copy of it.
//
//   quit-standin <mode> <folder> <seconds> <stubborn|polite> <pid file>
//
// The fake probe is <folder>/wtprobe.exe. Its path is NOT an argument here:
// this process's own command line would then match as a probe.
//
// It starts the fake probe the way BridgeProbeStream starts wtprobe.exe (stdout
// into a pipe read on a thread of its own, stderr nowhere), writes the probe's
// pid to <pid file> once the probe is ticking, and then leaves by <mode>:
//
//   quit       stop children as stopChildrenBeforeExit does, then exit(0)
//   bare-exit  exit(0) with no cleanup: the leak, kept as the control
//   signals    install the app's signal handling and wait to be signalled
//   no-handler wait to be signalled with the default signal handling: the leak
//   nothing    no probe at all; time a cleanup with nothing to stop
//
// Only probes under the fake's own folder are ever stopped, so running the
// tests never touches a real Test pen probe on this Mac.

import Foundation

/// The real matcher (BridgeCheck.strayProbePIDs) on the real `ps` listing,
/// narrowed to the fake probe's folder.
func ours(under dir: String) -> (String) -> [Int32] {
    return { ps in
        BridgeCheck.strayProbePIDs(inPS: ps.components(separatedBy: "\n")
            .filter { $0.contains(dir) }.joined(separator: "\n"))
    }
}

@main
struct QuitStandIn {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 6 || (args.count >= 2 && args[1] == "nothing") else {
            FileHandle.standardError.write("usage: quit-standin mode folder seconds stubborn|polite pidfile\n".data(using: .utf8)!)
            exit(2)
        }
        let mode = args[1]

        if mode == "nothing" {
            let dir = "/nonexistent-\(UUID().uuidString)/"
            let t0 = Date()
            let (found, left) = ChildCleanup.stop(find: ours(under: dir))
            print("found=\(found.count) left=\(left.count) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            exit(0)
        }

        let dir = args[2] + "/", seconds = args[3], stubborn = args[4], pidFile = args[5]
        let probePath = dir + "wtprobe.exe"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: probePath)
        p.arguments = [seconds] + (stubborn == "stubborn" ? ["stubborn"] : [])
        let out = Pipe(); p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { print("could not start the fake probe: \(error)"); exit(3) }

        // Read it as the app does, and say when the first tick arrives.
        let ticking = DispatchSemaphore(value: 0)
        let fh = out.fileHandleForReading
        Thread.detachNewThread {
            var signalled = false
            while true {
                let data = fh.availableData
                if data.isEmpty { break }
                if !signalled { signalled = true; ticking.signal() }
            }
        }
        guard ticking.wait(timeout: .now() + 5) == .success else { print("the fake probe never ticked"); exit(4) }

        // The cleanup under test: what stopChildrenBeforeExit does for the probe.
        func stopChildren() {
            let (found, left) = ChildCleanup.stop(find: ours(under: dir))
            print("cleanup: found \(found.count), left \(left.count)")
        }

        func ready() {
            try? "\(p.processIdentifier)".write(toFile: pidFile, atomically: true, encoding: .utf8)
        }

        switch mode {
        case "quit":
            ready()
            stopChildren()
            exit(0)
        case "bare-exit":
            ready()
            exit(0)
        case "signals":
            ChildCleanup.exitCleanlyOnSignals { stopChildren(); exit(0) }
            ready()
            dispatchMain()
        case "no-handler":
            ready()
            dispatchMain()
        default:
            print("unknown mode \(mode)"); exit(2)
        }
    }
}
