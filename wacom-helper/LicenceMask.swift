// LicenceMask.swift — how the licence file is named on screen.
//
// SYSTEMAX names a certificate after its licence number: sai-<number>.slc.
// That number is private, and the app is screenshotted (README, issues, help
// requests). So every place the app SHOWS the file name, it shows the masked
// form below. The real name is only used to read and copy the file.
//
// The dots are a fixed count on purpose: matching the digit count would leak
// how long the number is.

import Foundation

func maskedLicenseName(_ name: String) -> String {
    let ns = name as NSString
    let ext = ns.pathExtension
    let base = ns.deletingPathExtension
    let dots = "••••••"
    // Keep a leading word like "sai-" so the user still sees which file it is.
    let prefix: String
    if let dash = base.firstIndex(of: "-"),
       !base[..<dash].contains(where: { $0.isNumber }) {
        prefix = String(base[...dash])
    } else {
        prefix = ""
    }
    return prefix + dots + (ext.isEmpty ? "" : "." + ext)
}
