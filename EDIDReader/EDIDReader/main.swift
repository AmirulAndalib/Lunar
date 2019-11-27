//
//  main.swift
//  EDIDReader
//
//  Created by Alin on 29/03/2019.
//  Copyright © 2019 Alin. All rights reserved.
//

import Foundation

let log = Logger.self

func sha256(data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
        _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return Data(hash)
}

func getSerialNumberHash() -> String? {
    let platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))

    guard platformExpert > 0 else {
        return nil
    }

    guard let serialNumber = (IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0).takeUnretainedValue() as? String)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) else {
        return nil
    }

    IOObjectRelease(platformExpert)

    guard let serialNumberData = serialNumber.data(using: .utf8, allowLossyConversion: true) else { return nil }
    return sha256(data: serialNumberData).str(hex: true, separator: "")
}

print("Serial Number Hash: \(getSerialNumberHash())")

func printEdid(_ data: Data) {
    let edid = data.map { $0 }.str()
    let id = data[77 ..< 90].map { $0 }.str()
    print("      EDID: \(edid)")
    print("      ID: \(id)\n")
}

func printDetails(_ id: CGDirectDisplayID) {
    print("    CGDirectDisplayID: \(id)")
    _ = DDC.setBrightness(for: id, brightness: 30)

    if let edid = DDC.getEdidData(displayID: id) {
        printEdid(edid)
    }

    if let uuid = CGDisplayCreateUUIDFromDisplayID(id), let str = CFUUIDCreateString(nil, uuid.takeUnretainedValue()) {
        print("    UUID: \(str)\n")
        let newID = CGDisplayGetDisplayIDFromUUID(uuid.takeUnretainedValue())
        print("    IDFromUUID: \(newID)\n")
    }

    let sn = CGDisplaySerialNumber(id)
    let model = CGDisplayModelNumber(id)
    let vendor = CGDisplayVendorNumber(id)

    print("    S/N: \(sn)")
    print("    Model Number: \(model))")
    print("    Vendor: \(vendor)\n")

    let idData = DDC.getDisplayIdentificationData(displayID: id)
    let name = DDC.getDisplayName(for: id)
    let serial = DDC.getDisplaySerial(for: id)
    let brightness = DDC.getBrightness(for: id)

    print("    Name: \(name ?? "UNKNOWN")")
    print("    Serial: \(serial ?? "UNKNOWN")\n")
    print("    Brightness: \(brightness)\n")

    print("    Display unique ID: \(idData)\n")
    print("    Display unit number: \(CGDisplayUnitNumber(id))\n")
}

if let id = DDC.getBuiltinDisplay() {
    print("Built-in display:")
    printDetails(id)
}

DDC.findExternalDisplays().forEach { id in
    print("External displays:")
    printDetails(id)
}

print("Raw data:")
DDC.getEdidData().forEach { data in
    printEdid(data)
}
