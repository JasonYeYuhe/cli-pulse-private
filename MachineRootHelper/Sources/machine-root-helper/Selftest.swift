import Foundation
import RootHelperCore

// On-hardware self-test for the REAL FanController + RealSMC (no XPC, no launchd).
// Drives the exact production safety logic through every layer, always ending in
// auto. Invoked as `machine-root-helper selftest [read|write]`:
//   read  — SMC READ only, no root needed (validates RealSMC decode vs a trusted
//           reader like Macs Fan Control / the M0 spike).
//   write — the full boost → revert → heartbeat-lapse → crash-recovery run;
//           needs root. Refuses if a fan is already MANUAL (something else —
//           e.g. Macs Fan Control — is forcing it; don't fight).
func runSelftest(mode: String) -> Int32 {
    guard let smc = RealSMC() else {
        print("could not open AppleSMC"); return 1
    }
    func snap() -> [FanState] { (0..<smc.fanCount()).compactMap { smc.readFan($0) } }
    func show(_ label: String) {
        for f in snap() {
            print(String(format: "  %-12@ F%d: actual=%4d  min=%4d  max=%4d  target=%4d  mode=%@",
                         label as NSString, f.index, Int(f.actualRPM), Int(f.minRPM), Int(f.maxRPM),
                         Int(f.targetRPM), f.mode == 1 ? "MANUAL" : "auto"))
        }
    }

    print("== RealSMC read (\(smc.fanCount()) fans) — cross-check vs Macs Fan Control ==")
    show("read")
    if mode == "read" { return 0 }

    // ── root test hooks (for the launchd KeepAlive / crash-recovery test) ──
    // leavestuck: force every fan MANUAL and EXIT WITHOUT reverting — simulates a
    //   controller kill -9'd mid-boost, leaving the fan stuck (the M0 hazard). Sets
    //   up the "a launchd relaunch must recover it" test.
    // revert: force every fan back to auto (safety cleanup; == revert-on-startup).
    if mode == "leavestuck" || mode == "revert" {
        guard geteuid() == 0 else { print("\n\(mode) needs root (sudo)."); return 2 }
        if mode == "leavestuck" {
            for i in 0..<smc.fanCount() { _ = smc.writeManualMode(i, manual: true); _ = smc.writeTargetRPM(i, rpm: 3000) }
            print("\nleft fans MANUAL@3000 (stuck; NO revert) — simulating a kill -9'd controller")
        } else {
            _ = FanController(smc: smc, heartbeatTimeout: 3, now: { ProcessInfo.processInfo.systemUptime }, revertOnInit: true)
            print("\nforced all fans back to auto")
        }
        show(mode); return 0
    }

    // ── write mode ──
    guard geteuid() == 0 else { print("\nwrite selftest needs root (sudo)."); return 2 }
    if snap().contains(where: { $0.mode == 1 }) {
        print("\nA fan is already MANUAL — something (Macs Fan Control?) is forcing it. "
              + "Aborting so we don't fight it. Set Macs Fan Control to Auto and retry.")
        return 3
    }

    let clock = { ProcessInfo.processInfo.systemUptime }
    let fc = FanController(smc: smc, heartbeatTimeout: 3, now: clock, revertOnInit: true)
    // HARD safety net: whatever happens, end in auto (retry a few times).
    defer {
        var ok = false
        for _ in 0..<5 { if fc.revertToAuto().ok { ok = true; break }; usleep(200_000) }
        print("\n== FINAL — reverted to auto: \(ok ? "yes" : "NO") ==")
        show("final")
    }

    print("\n== T1: boost to 3000 rpm, hold ~6s (expect actual to climb) ==")
    print("  applyBoost ->", fc.applyBoost(targetRPM: 3000))
    for t in 1...6 { sleep(1); print("  t+\(t)s"); show("boost") }

    print("\n== T2: explicit revert to auto (expect mode->auto, actual falls) ==")
    print("  revertToAuto ->", fc.revertToAuto().ok)
    sleep(2); show("after-revert")

    print("\n== T3: heartbeat lapse (3s timeout) — dead-man reverts without being told ==")
    print("  applyBoost ->", fc.applyBoost(targetRPM: 3000).ok, "(now NOT heart-beating)")
    for t in 1...6 { sleep(1); let reverted = fc.tick(); print("  t+\(t)s  tick.reverted=\(reverted)"); show("lapse"); if reverted { break } }

    print("\n== T4: crash recovery — a FRESH controller (revert-on-startup) clears a stuck fan ==")
    print("  applyBoost then abandon (simulates the daemon being kill -9'd):", fc.applyBoost(targetRPM: 3000).ok)
    sleep(1); show("stuck")
    print("  new FanController(revertOnInit:true)  [= what launchd relaunch does]:")
    _ = FanController(smc: smc, heartbeatTimeout: 3, now: clock, revertOnInit: true)
    sleep(1); show("recovered")
    return 0
}
