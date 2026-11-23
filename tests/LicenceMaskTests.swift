// LicenceMaskTests.swift — the licence number never reaches the screen.
//
// The trap: the .slc file is named after the licence number, and the app used
// to print that name in the setup window, dialogs and reports, so it ended up
// in screenshots. If any of these fail, the number is visible again.
// The numbers below are made up. Never put a real one here: this repo is public.

import Foundation

nonisolated(unsafe) var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("  ok   \(name)") } else { print("  FAIL \(name)"); failures += 1 }
}

@main
struct LicenceMaskTests {
    static func main() {
        let m = maskedLicenseName("sai-123456789012.slc")
        expect(m == "sai-••••••.slc", "sai-<number>.slc shows as sai-••••••.slc (got \(m))")
        expect(!m.contains(where: { $0.isNumber }), "no digit of the number survives")
        expect(maskedLicenseName("sai-1.slc") == maskedLicenseName("sai-123456789012345.slc"),
               "the dot count does not give away the number's length")
        expect(maskedLicenseName("1234567.slc") == "••••••.slc", "a bare number is hidden whole")
        expect(maskedLicenseName("12-34.slc") == "••••••.slc", "a numeric part before a dash is not kept")
        expect(maskedLicenseName("SAI-ABC123.SLC") == "SAI-••••••.SLC", "case and extension are kept")

        // Every place that SHOWS a licence name must go through the mask.
        let repo = CommandLine.arguments.dropFirst().first ?? "."
        for f in ["main.swift", "SetupUI.swift", "Diagnostics.swift"] {
            let src = (try? String(contentsOfFile: "\(repo)/wacom-helper/\(f)", encoding: .utf8)) ?? ""
            expect(!src.isEmpty, "\(f) was read")
            for (i, line) in src.components(separatedBy: "\n").enumerated() {
                let shows = line.contains("installedLicenseName().map")
                    || line.contains("installedLicenseName() ??")
                    || line.contains("slcFiles(in: licenseStashDir()).joined")
                    || line.contains("\\(lic) was")
                    || (line.contains("if let n = installedLicenseName()") && line.contains("return"))
                if shows && !line.contains("maskedLicenseName") {
                    expect(false, "\(f):\(i + 1) shows a licence name without the mask")
                }
            }
        }

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
    }
}
