//
//  IdeviceFFIBridge.swift
//  StikDebug
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import UIKit
import idevice
import SwiftUI
import UniformTypeIdentifiers

private enum IdeviceBridge {
    static let processQueue = DispatchQueue(label: "com.stikdebug.processInspector", qos: .userInitiated)

    static func makeError(
        domain: String = "StikDebug",
        code: Int = -1,
        message: String
    ) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func string(from cString: UnsafePointer<CChar>?) -> String? {
        guard let cString else { return nil }
        return String(validatingUTF8: cString)
    }

    static func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String,
        domain: String = "StikDebug"
    ) -> NSError {
        guard let ffiError else {
            return makeError(domain: domain, message: fallback)
        }

        let code = Int(ffiError.pointee.code)
        let detail = string(from: ffiError.pointee.message) ?? fallback
        let message = detail == fallback ? fallback : "\(fallback): \(detail)"
        idevice_error_free(ffiError)
        return makeError(domain: domain, code: code, message: message)
    }

    static func mappedFileData(atPath path: String, description: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw makeError(message: "\(description) is empty")
            }
            return data
        } catch let error as NSError {
            throw makeError(code: error.code, message: "Failed to read \(description): \(error.localizedDescription)")
        }
    }

    static func uint64Value(from plist: plist_t?, fieldName: String) throws -> UInt64 {
        guard let plist else {
            throw makeError(message: "\(fieldName) was not returned by lockdownd")
        }

        var value: UInt64 = 0
        plist_get_uint_val(plist, &value)

        guard value != 0 else {
            throw makeError(message: "Failed to decode \(fieldName)")
        }

        return value
    }

    static func withTunnelHandles<T>(
        for context: JITEnableContext,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        let handles = try activeTunnelHandles(for: context)
        return try body(handles.adapter, handles.handshake)
    }

    static func connectClient(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> OpaquePointer {
        var client: OpaquePointer?
        if let ffiError = connect(&client) {
            throw consumeFFIError(ffiError, fallback: fallback, domain: domain)
        }

        guard let client else {
            throw makeError(domain: domain, message: missingClientMessage)
        }

        return client
    }

    static func withConnectedClient<T>(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: (OpaquePointer) -> Void,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try connectClient(
            fallback: fallback,
            missingClientMessage: missingClientMessage,
            domain: domain,
            connect: connect
        )
        defer { cleanup(client) }
        return try body(client)
    }

    static func plistDictionaries(adapter: OpaquePointer, handshake: OpaquePointer, applicationType: String? = nil) throws -> [[String: Any]] {
        try withConnectedClient(
            fallback: "Failed to connect to installation proxy",
            missingClientMessage: "Installation proxy client was not created",
            connect: { installation_proxy_connect_rsd(adapter, handshake, $0) },
            cleanup: { installation_proxy_client_free($0) }
        ) { client in
            var rawApps: UnsafeMutableRawPointer?
            var count = 0
            let ffiError: UnsafeMutablePointer<IdeviceFfiError>?
            if let applicationType {
                ffiError = applicationType.withCString {
                    installation_proxy_get_apps(client, $0, nil, 0, &rawApps, &count)
                }
            } else {
                ffiError = installation_proxy_get_apps(client, nil, nil, 0, &rawApps, &count)
            }
            if let ffiError {
                throw consumeFFIError(ffiError, fallback: "Failed to fetch installed apps")
            }

            guard let rawApps, count > 0 else { return [] }

            let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
            defer {
                for index in 0..<count {
                    plist_free(apps[index])
                }
                idevice_data_free(
                    rawApps.assumingMemoryBound(to: UInt8.self),
                    UInt(count * MemoryLayout<plist_t?>.stride)
                )
            }

            var dictionaries: [[String: Any]] = []
            dictionaries.reserveCapacity(count)

            for index in 0..<count {
                var binaryPlist: UnsafeMutablePointer<CChar>?
                var binaryLength: UInt32 = 0
                let app = apps[index]

                guard plist_to_bin(app, &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                      let binaryPlist,
                      binaryLength > 0 else {
                    continue
                }

                let data = Data(bytes: binaryPlist, count: Int(binaryLength))
                plist_mem_free(binaryPlist)

                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dictionary = plist as? [String: Any] else {
                    continue
                }

                dictionaries.append(dictionary)
            }

            return dictionaries
        }
    }

    static func appName(from dictionary: [String: Any]) -> String {
        if let displayName = dictionary["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let name = dictionary["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return "Unknown"
    }

    static func hasGetTaskAllow(_ dictionary: [String: Any]) -> Bool {
        guard let entitlements = dictionary["Entitlements"] as? [String: Any] else {
            return false
        }

        if let flag = entitlements["get-task-allow"] as? Bool {
            return flag
        }

        if let flag = entitlements["get-task-allow"] as? NSNumber {
            return flag.boolValue
        }

        return false
    }

    static func isHiddenSystemApp(_ dictionary: [String: Any]) -> Bool {
        guard let applicationType = dictionary["ApplicationType"] as? String,
              applicationType == "System" || applicationType == "HiddenSystemApp" else {
            return false
        }

        if let isHidden = dictionary["IsHidden"] as? Bool, isHidden {
            return true
        }

        if let isHidden = dictionary["IsHidden"] as? NSNumber, isHidden.boolValue {
            return true
        }

        guard let tags = dictionary["SBAppTags"] as? [String] else {
            return false
        }

        return tags.contains("hidden") || tags.contains("hidden-system-app")
    }

    static func appDictionary(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        requireGetTaskAllow: Bool,
        filter: (([String: Any]) -> Bool)? = nil
    ) throws -> [String: String] {
        let dictionaries = try plistDictionaries(adapter: adapter, handshake: handshake)
        var result: [String: String] = [:]
        result.reserveCapacity(dictionaries.count)

        for dictionary in dictionaries {
            if requireGetTaskAllow && !hasGetTaskAllow(dictionary) {
                continue
            }

            if let filter, !filter(dictionary) {
                continue
            }

            guard let bundleID = dictionary["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else {
                continue
            }

            result[bundleID] = appName(from: dictionary)
        }

        return result
    }

    static func activeTunnelHandles(for context: JITEnableContext) throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        try context.ensureTunnel()

        guard let adapterHandle = context.adapterHandle,
              let handshakeHandle = context.handshakeHandle else {
            throw makeError(message: "Tunnel is not connected")
        }

        return (adapterHandle, handshakeHandle)
    }
}

extension JITEnableContext {
    func isDeveloperDiskImageMounted() throws -> Bool {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            var cryptexQuerySucceeded = false
            var cryptexQueryError: NSError?
            if DeveloperDiskImageService.usesCryptexDDI {
                var installed: UnsafeMutablePointer<InstalledCryptexC>?
                defer { cryptexd_free_installed_cryptex(installed) }
                if let ffiError = cryptexd_installed_ddi(adapter, handshake, &installed) {
                    cryptexQueryError = IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query installed DDI cryptex")
                } else {
                    cryptexQuerySucceeded = true
                    if installed != nil {
                        return true
                    }
                }
            }

            do {
                return try IdeviceBridge.withConnectedClient(
                    fallback: "Failed to connect to image mounter",
                    missingClientMessage: "Image mounter client was not created",
                    connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                    cleanup: { image_mounter_free($0) }
                ) { client in
                    var devices: UnsafeMutablePointer<plist_t?>?
                    var deviceCount = 0
                    if let error = image_mounter_copy_devices(client, &devices, &deviceCount) {
                        throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to fetch mounted devices")
                    }
                    if let devices {
                        for index in 0..<deviceCount {
                            plist_free(devices[index])
                        }
                        idevice_data_free(
                            UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                            UInt(deviceCount * MemoryLayout<plist_t?>.stride)
                        )
                    }
                    return deviceCount > 0
                }
            } catch {
                if cryptexQuerySucceeded {
                    return false
                }
                throw cryptexQueryError ?? (error as NSError)
            }
        }
    }

    func installCryptexDDI(from directoryPath: String) throws {
        var assets: OpaquePointer?
        if let ffiError = cryptex1_assets_load(directoryPath, &assets) {
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to load DDI cryptex assets")
        }

        guard let assets else {
            throw IdeviceBridge.makeError(message: "DDI cryptex assets were not loaded")
        }
        defer { cryptex1_assets_free(assets) }

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            if let ffiError = cryptexd_install_ddi(adapter, handshake, assets, nil) {
                throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to install DDI cryptex")
            }
        }
    }

    func mountPersonalDDI(withImagePath imagePath: String, trustcachePath: String, manifestPath: String) throws {
        let imageData = try IdeviceBridge.mappedFileData(atPath: imagePath, description: "developer disk image")
        let trustcacheData = try IdeviceBridge.mappedFileData(atPath: trustcachePath, description: "developer disk image trust cache")
        let manifestData = try IdeviceBridge.mappedFileData(atPath: manifestPath, description: "developer disk image manifest")

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            let uniqueChipID = try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { lockdownClient in
                var uniqueChipIDPlist: plist_t?
                if let ffiError = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &uniqueChipIDPlist) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query UniqueChipID")
                }
                defer { plist_free(uniqueChipIDPlist) }
                return try IdeviceBridge.uint64Value(from: uniqueChipIDPlist, fieldName: "UniqueChipID")
            }

            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { imageMounterClient in
                let ffiError = imageData.withUnsafeBytes { imageBuffer in
                    trustcacheData.withUnsafeBytes { trustcacheBuffer in
                        manifestData.withUnsafeBytes { manifestBuffer in
                            image_mounter_mount_personalized_rsd(
                                imageMounterClient,
                                adapter,
                                handshake,
                                imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                                imageData.count,
                                trustcacheBuffer.bindMemory(to: UInt8.self).baseAddress,
                                trustcacheData.count,
                                manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                manifestData.count,
                                nil,
                                uniqueChipID
                            )
                        }
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to mount personalized DDI")
                }
            }
        }
    }

    func fetchAllProfiles() throws -> [Data] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                var profilePointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
                var profileLengths: UnsafeMutablePointer<Int>?
                var profileCount = 0

                if let ffiError = misagent_copy_all(misagentClient, &profilePointers, &profileLengths, &profileCount) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to fetch provisioning profiles",
                        domain: "profiles"
                    )
                }

                defer {
                    if let profilePointers, let profileLengths {
                        misagent_free_profiles(profilePointers, profileLengths, profileCount)
                    }
                }

                guard let profilePointers, let profileLengths else { return [] }

                var result: [Data] = []
                result.reserveCapacity(profileCount)

                for index in 0..<profileCount {
                    guard let bytes = profilePointers[index] else { continue }
                    result.append(Data(bytes: bytes, count: profileLengths[index]))
                }

                return result
            }
        }
    }

    func removeProfile(withUUID uuid: String) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                if let ffiError = misagent_remove(misagentClient, uuid) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to remove provisioning profile",
                        domain: "profiles"
                    )
                }
            }
        }
    }

    func addProfile(_ profile: Data) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                let ffiError = profile.withUnsafeBytes { rawBuffer in
                    misagent_install(
                        misagentClient,
                        rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                        profile.count
                    )
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to add provisioning profile",
                        domain: "profiles"
                    )
                }
            }
        }
    }

    func fetchProcessList() throws -> [NSDictionary] {
        try IdeviceBridge.processQueue.sync {
            try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
                try IdeviceBridge.withConnectedClient(
                    fallback: "Unable to open AppService",
                    missingClientMessage: "AppService client was not created",
                    connect: { app_service_connect_rsd(adapter, handshake, $0) },
                    cleanup: { app_service_free($0) }
                ) { appService in
                    var processes: UnsafeMutablePointer<ProcessTokenC>?
                    var count = UInt(0)
                    if let ffiError = app_service_list_processes(appService, &processes, &count) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to list processes")
                    }

                    defer {
                        if let processes {
                            app_service_free_process_list(processes, count)
                        }
                    }

                    guard let processes else { return [] }

                    var result: [NSDictionary] = []
                    result.reserveCapacity(Int(count))

                    for index in 0..<Int(count) {
                        let process = processes[index]
                        var dictionary: [String: Any] = ["pid": NSNumber(value: process.pid)]
                        if let executableURL = IdeviceBridge.string(from: process.executable_url) {
                            dictionary["path"] = executableURL
                        }
                        result.append(dictionary as NSDictionary)
                    }

                    return result
                }
            }
        }
    }

    func sendSignal(_ signal: Int32, toProcessWithPID pid: Int32) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Unable to open AppService",
                missingClientMessage: "AppService client was not created",
                connect: { app_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { app_service_free($0) }
            ) { appService in
                var response: UnsafeMutablePointer<SignalResponseC>?
                let ffiError = app_service_send_signal(appService, UInt32(pid), UInt32(signal), &response)
                defer {
                    if let response {
                        app_service_free_signal_response(response)
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to send signal \(signal) to process")
                }
            }
        }
    }

    func killProcess(withPID pid: Int32) throws {
        try sendSignal(Int32(SIGKILL), toProcessWithPID: pid)
    }

    func killProcess(withName name: String) throws {
        let entries = try fetchProcessList().compactMap(ProcessInfoEntry.init(dictionary:))
        let pid = try ProcessInfoEntry.pid(named: name, in: entries)
        try killProcess(withPID: pid)
    }

    func getAppList() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: true
            )
        }
    }

    func getAllApps() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: false
            )
        }
    }

    func getHiddenSystemApps() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: false,
                filter: IdeviceBridge.isHiddenSystemApp
            )
        }
    }

    func getSideloadedApps() throws -> [NSDictionary] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.plistDictionaries(adapter: adapter, handshake: handshake)
                .filter { $0["ProfileValidated"] != nil }
                .map { $0 as NSDictionary }
        }
    }

    func getAppIcon(withBundleId bundleId: String) throws -> UIImage {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to SpringBoard Services",
                missingClientMessage: "SpringBoard Services client was not created",
                connect: { springboard_services_connect_rsd(adapter, handshake, $0) },
                cleanup: { springboard_services_free($0) }
            ) { client in
                var rawIconData: UnsafeMutableRawPointer?
                var rawIconLength = 0
                if let ffiError = springboard_services_get_icon(client, bundleId, &rawIconData, &rawIconLength) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to get app icon")
                }

                guard let rawIconData, rawIconLength > 0 else {
                    throw IdeviceBridge.makeError(message: "App icon data was empty")
                }

                defer { free(rawIconData) }

                let data = Data(bytes: rawIconData, count: rawIconLength)
                guard let image = UIImage(data: data) else {
                    throw IdeviceBridge.makeError(message: "Failed to decode app icon image")
                }

                return image
            }
        }
    }

    func ideviceInfoInit() throws -> OpaquePointer {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.connectClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                domain: "profiles",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) }
            )
        }
    }

    func ideviceInfoGetXML(withLockdownClient lockdownClient: OpaquePointer?) throws -> UnsafeMutablePointer<CChar>? {
        guard let lockdownClient else { return nil }

        var plistObject: plist_t?
        if let ffiError = lockdownd_get_value(lockdownClient, nil, nil, &plistObject) {
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch device info")
        }

        guard let plistObject else {
            return nil
        }

        defer { plist_free(plistObject) }

        var xml: UnsafeMutablePointer<CChar>?
        var xmlLength: UInt32 = 0
        guard plist_to_xml(plistObject, &xml, &xmlLength) == PLIST_ERR_SUCCESS,
              let xml,
              xmlLength > 0 else {
            throw IdeviceBridge.makeError(message: "Failed to serialize device info plist")
        }

        return xml
    }
}

func FetchDeviceProcessList(_ error: NSErrorPointer) -> [NSDictionary]? {
    do {
        return try JITEnableContext.shared.fetchProcessList()
    } catch let nsError as NSError {
        error?.pointee = nsError
        return nil
    }
}

func KillDeviceProcess(_ pid: Int32, _ error: NSErrorPointer) -> Bool {
    do {
        try JITEnableContext.shared.killProcess(withPID: pid)
        return true
    } catch let nsError as NSError {
        error?.pointee = nsError
        return false
    }
}

struct ProcessInfoEntry: Identifiable {
    let pid: Int
    private let rawPath: String
    let bundleID: String?
    let name: String?

    init?(dictionary: NSDictionary) {
        guard let pidNumber = dictionary["pid"] as? NSNumber else { return nil }
        pid = pidNumber.intValue
        rawPath = dictionary["path"] as? String ?? "Unknown"
        bundleID = dictionary["bundleID"] as? String
        name = dictionary["name"] as? String
    }

    static func currentEntries(_ error: NSErrorPointer = nil) -> [ProcessInfoEntry] {
        let entries = FetchDeviceProcessList(error) ?? []
        return entries.compactMap(Self.init(dictionary:))
    }

    static func pid(named name: String, in entries: [ProcessInfoEntry]) throws -> Int32 {
        guard !name.isEmpty else {
            throw IdeviceBridge.makeError(message: "A process name is required.")
        }
        let matches = entries.filter { $0.processName == name }
        guard let match = matches.first else {
            throw IdeviceBridge.makeError(message: "No running process named \(name) was found.")
        }
        guard matches.count == 1 else {
            throw IdeviceBridge.makeError(message: "More than one process is named \(name). Use a PID to select the process.")
        }
        guard let pid = Int32(exactly: match.pid), pid > 0 else {
            throw IdeviceBridge.makeError(message: "The process has an invalid PID.")
        }
        return pid
    }

    var processName: String {
        URL(string: rawPath)?.lastPathComponent ?? (executablePath as NSString).lastPathComponent
    }

    var id: Int { pid }

    var executablePath: String {
        rawPath.replacingOccurrences(of: "file://", with: "")
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let component = executablePath.split(separator: "/").last {
            return String(component)
        }
        return "Process \(pid)"
    }

    var stableIdentifier: String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        return displayName
    }
}

@objcMembers
final class CMSDecoderHelper: NSObject {
    static func decodeCMSData(_ cmsData: Data) throws -> Data {
        guard !cmsData.isEmpty else {
            throw IdeviceBridge.makeError(
                domain: NSCocoaErrorDomain,
                code: NSURLErrorBadURL,
                message: "Invalid or empty CMS payload"
            )
        }

        let xmlStart = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        let binaryMagic = Data("bplist00".utf8)

        if let startRange = cmsData.range(of: xmlStart),
           let endRange = cmsData.range(of: plistEnd, options: [], in: startRange.lowerBound..<cmsData.endIndex) {
            return cmsData[startRange.lowerBound..<endRange.upperBound]
        }

        if let binaryRange = cmsData.range(of: binaryMagic) {
            return cmsData[binaryRange.lowerBound..<cmsData.endIndex]
        }

        throw IdeviceBridge.makeError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            message: "Unable to extract plist from CMS payload"
        )
    }
}

private enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12
}

private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?

    static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "com.stik.location-sim", qos: .userInitiated)
}

func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    if let locationSimulation = LocationSimulationState.locationSimulation {
        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(ffiError)
            LocationSimulationState.cleanup()
        } else {
            return LocationSimulationStatus.ok
        }
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(RemotePairingPortResolver.resolve(targetIPAddress: deviceIP)).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        return LocationSimulationStatus.invalidIP
    }

    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { rp_pairing_file_read($0, &pairingHandle) }
    if let pairingError {
        idevice_error_free(pairingError)
        return LocationSimulationStatus.pairingRead
    }

    guard let pairingHandle else {
        return LocationSimulationStatus.pairingRead
    }

    defer { rp_pairing_file_free(pairingHandle) }

    let providerError = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing(
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.stride),
                "StikDebugLocation",
                pairingHandle,
                nil,
                nil,
                &LocationSimulationState.adapter,
                &LocationSimulationState.handshake
            )
        }
    }

    if let providerError {
        idevice_error_free(providerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.providerCreate
    }

    let remoteServerError = remote_server_connect_rsd(
        LocationSimulationState.adapter,
        LocationSimulationState.handshake,
        &LocationSimulationState.remoteServer
    )
    if let remoteServerError {
        idevice_error_free(remoteServerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.remoteServer
    }

    let locationSimulationError = location_simulation_new(
        LocationSimulationState.remoteServer,
        &LocationSimulationState.locationSimulation
    )
    if let locationSimulationError {
        idevice_error_free(locationSimulationError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSimulation
    }

    LocationSimulationState.remoteServer = nil

    let locationSetError = location_simulation_set(
        LocationSimulationState.locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        idevice_error_free(locationSetError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSet
    }

    let conditions = deviceIP == DeviceConnectionContext.defaultTargetIPAddress ? ConnectionDiagnostics.networkConditions() : nil
    let notice = ConnectionDiagnostics.connectedNotice(targetIP: deviceIP, conditions: conditions)
    NotificationCenter.default.post(name: .locationTunnelConnected, object: notice)
    return LocationSimulationStatus.ok
}

func clear_simulated_location() -> Int32 {
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        return LocationSimulationStatus.locationClear
    }

    let ffiError = location_simulation_clear(locationSimulation)
    LocationSimulationState.cleanup()

    if let ffiError {
        idevice_error_free(ffiError)
        return LocationSimulationStatus.locationClear
    }

    return LocationSimulationStatus.ok
}

struct PairingDestinationApp: Identifiable, Sendable {
    let bundleID: String
    let name: String
    let path: String
    var id: String { bundleID }

    static func isLiveContainer(bundleID: String, names: [String]) -> Bool {
        if bundleID.lowercased().hasPrefix("com.kdt.livecontainer") {
            return true
        }
        return names.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: "^LiveContainer(?:[0-9]+|[ ]+[0-9]+|[ ]*\\([^)]*\\))?$", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

extension JITEnableContext {
    func pairingDestinationApps(target: PairingPlacementTarget? = nil) throws -> [PairingDestinationApp] {
        try withFreshDebugTunnel(hostname: "StikDebugPairingApps", target: target) { adapter, handshake in
            let paths = [
                "Antrag": "pairingFile.plist",
                "Auto Capture": "rpPairingFile.plist",
                "Feather": "pairingFile.plist",
                "Ksign": "pairingFile.plist",
                "LiveContainer": "SideStore/Documents/ALTPairingFile.mobiledevicepairing",
                "Protokolle": "pairingFile.plist",
                "Reynard": "pairingFile.plist",
                "SideStore": "ALTPairingFile.mobiledevicepairing",
                "StikDebug": "pairingFile.plist",
                "StosDebug": "pairingFile.plist"
            ]
            let installed = try IdeviceBridge.plistDictionaries(adapter: adapter, handshake: handshake)
            let supported = installed.compactMap { app -> PairingDestinationApp? in
                guard let bundleID = app["CFBundleIdentifier"] as? String else { return nil }
                let name = IdeviceBridge.appName(from: app)
                let names = [name, app["CFBundleName"] as? String ?? ""]
                let isLiveContainer = PairingDestinationApp.isLiveContainer(bundleID: bundleID, names: names)
                let path = isLiveContainer ? paths["LiveContainer"] : paths.first { entry in
                    names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveCompare(entry.key) == .orderedSame }
                }?.value
                guard let path, bundleID != "com.stik.sj",
                      target != nil || isLiveContainer || bundleID != Bundle.main.bundleIdentifier else { return nil }
                return PairingDestinationApp(bundleID: bundleID, name: name, path: path)
            }
            LogManager.shared.addInfoLog("Pairing destinations: \(installed.count) installed app records, \(supported.count) supported apps")
            return supported.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func placePairingFile(_ data: Data, in app: PairingDestinationApp, target: PairingPlacementTarget? = nil) throws {
        try withFreshDebugTunnel(hostname: "StikDebugPairingPlacement", target: target) { adapter, handshake in
            let client = try IdeviceBridge.connectClient(
                fallback: "Failed to connect to app Documents",
                missingClientMessage: "House Arrest client was not created",
                connect: { house_arrest_client_connect_rsd(adapter, handshake, $0) }
            )
            var afc: OpaquePointer?
            // Vend consumes the House Arrest handle, including when it fails.
            if let error = house_arrest_vend_documents(client, app.bundleID, &afc) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to open \(app.name)'s Documents folder")
            }
            guard let afc else {
                throw IdeviceBridge.makeError(message: "App Documents connection was not created")
            }
            defer { afc_client_free(afc) }
            var file: OpaquePointer?
            if let error = afc_file_open(afc, "/Documents/\(app.path)", AfcWr, &file) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to open the pairing file in \(app.name)")
            }
            guard let file else {
                throw IdeviceBridge.makeError(message: "Pairing file handle was not created")
            }
            let writeError = data.withUnsafeBytes {
                afc_file_write(file, $0.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
            let closeError = afc_file_close(file)
            if let writeError {
                if let closeError { idevice_error_free(closeError) }
                throw IdeviceBridge.consumeFFIError(writeError, fallback: "Failed to write the pairing file to \(app.name)")
            }
            if let closeError {
                throw IdeviceBridge.consumeFFIError(closeError, fallback: "Failed to close the pairing file in \(app.name)")
            }
        }
    }
}
// MARK: - Settings keys
 
private enum SLKey {
    static let url = "slspoof.apiURL"
    static let token = "slspoof.token"
    static let ip = "slspoof.deviceIP"
    static let pairing = "slspoof.pairingFileName"
}
 
// MARK: - Errors and the site's reply
 
private enum SLWorkerError: LocalizedError {
    case rejected(Int)
    case badReply
    case http(Int)
 
    var errorDescription: String? {
        switch self {
        case .rejected(let code):
            return "The site rejected the token (HTTP \(code))."
        case .badReply:
            return "The site sent a reply the app could not read."
        case .http(let code):
            return "The site answered with HTTP \(code)."
        }
    }
}
 
/// {"active":true,"lat":42.357,"lon":-71.057,"poll":5,"label":"Boston"}  or  {"active":false,"poll":5}
private struct SLReply: Decodable {
    let active: Bool
    let lat: Double?
    let lon: Double?
    let poll: Int?
    let label: String?
}
 
// MARK: - The worker
 
@MainActor
final class SLSpoofWorker: ObservableObject {
    static let shared = SLSpoofWorker()
 
    @Published var apiURL: String {
        didSet { UserDefaults.standard.set(apiURL, forKey: SLKey.url) }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: SLKey.token) }
    }
    @Published var deviceIP: String {
        didSet { UserDefaults.standard.set(deviceIP, forKey: SLKey.ip) }
    }
    /// File name (not a full path) of an imported pairing file inside Documents. Empty = auto-detect.
    @Published var pairingFileName: String {
        didSet { UserDefaults.standard.set(pairingFileName, forKey: SLKey.pairing) }
    }
 
    @Published private(set) var running = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var lines: [String] = []
 
    private var task: Task<Void, Never>?
    private var keepAliveRequested = false
    private var appliedLat: Double?
    private var appliedLon: Double?
 
    private init() {
        let defaults = UserDefaults.standard
        apiURL = defaults.string(forKey: SLKey.url) ?? "https://sailorsloot.xyz/wp-json/loc/v1/current"
        token = defaults.string(forKey: SLKey.token) ?? ""
        deviceIP = defaults.string(forKey: SLKey.ip) ?? DeviceConnectionContext.defaultTargetIPAddress
        pairingFileName = defaults.string(forKey: SLKey.pairing) ?? ""
    }
 
    // MARK: Pairing file
 
    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
 
    /// Full path of the pairing file that will be used.
    var pairingFilePath: String {
        if !pairingFileName.isEmpty {
            return documentsURL.appendingPathComponent(pairingFileName).path
        }
        for name in ["rpPairingFile.plist", "pairingFile.plist"] {
            let candidate = documentsURL.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return documentsURL.appendingPathComponent("rpPairingFile.plist").path
    }
 
    var pairingFileExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }
 
    var pairingFileDisplayName: String {
        (pairingFilePath as NSString).lastPathComponent
    }
 
    func importPairingFile(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let name = "slspoof_rpPairingFile.plist"
        let destination = documentsURL.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            pairingFileName = name
            log("Pairing file imported.")
        } catch {
            log("Could not import the pairing file: \(error.localizedDescription)")
        }
    }
 
    // MARK: Start / stop
 
    func start() {
        guard task == nil else { return }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            status = "Enter your token first"
            return
        }
        running = true
        status = "Starting"
        log("Worker started.")
 
        // Keep the app alive in the background using StikDebug's own keep-alive.
        UserDefaults.standard.set(true, forKey: "keepAliveLocation")
        BackgroundLocationManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
        BackgroundLocationManager.shared.requestStart()
        keepAliveRequested = true
 
        task = Task { [weak self] in
            await self?.loop()
        }
    }
 
    func stop() {
        task?.cancel()
        status = "Stopping"
        Task { [weak self] in
            await self?.clearLocation()
            self?.status = "Stopped"
        }
    }
 
    private func finishLoop() {
        if keepAliveRequested {
            BackgroundLocationManager.shared.requestStop()
            keepAliveRequested = false
        }
        task = nil
        running = false
    }
 
    // MARK: The polling loop
 
    private func loop() async {
        while !Task.isCancelled {
            var wait = 5
            do {
                let reply = try await fetchCurrent()
                wait = max(2, min(60, reply.poll ?? 5))
                status = "Connected to site"
 
                if reply.active, let lat = reply.lat, let lon = reply.lon {
                    if appliedLat != lat || appliedLon != lon {
                        await apply(lat: lat, lon: lon, label: reply.label)
                        if appliedLat == nil {
                            wait = 15 // it failed; try again a little later
                        }
                    }
                } else if appliedLat != nil {
                    await clearLocation()
                    log("Back to the real location.")
                    status = "Using real location"
                }
            } catch let error as SLWorkerError {
                if case .rejected = error {
                    status = "Token rejected"
                    log(error.localizedDescription + " Check it, then press Start again.")
                    break
                }
                status = "Site error"
                log(error.localizedDescription)
                wait = 15
            } catch {
                if Task.isCancelled { break }
                status = "Can't reach the site"
                log("Network problem: \(error.localizedDescription)")
                wait = 15
            }
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
        }
        finishLoop()
    }
 
    private func fetchCurrent() async throws -> SLReply {
        let urlText = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlText) else {
            throw SLWorkerError.badReply
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Loc-Token")
        request.setValue("SL_Spoof-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
 
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SLWorkerError.badReply
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SLWorkerError.rejected(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SLWorkerError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(SLReply.self, from: data)
        } catch {
            throw SLWorkerError.badReply
        }
    }
 
    // MARK: Talking to StikDebug's location engine
 
    private func apply(lat: Double, lon: Double, label: String?) async {
        status = "Moving phone"
        let ip = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = pairingFilePath
 
        let code: Int32 = await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: simulate_location(ip, lat, lon, path))
            }
        }
 
        let coords = String(format: "%.5f, %.5f", lat, lon)
        if code == 0 {
            appliedLat = lat
            appliedLon = lon
            status = "Active: " + coords
            if let label = label, !label.isEmpty {
                log("Moved to " + label + " (" + coords + ")")
            } else {
                log("Moved to " + coords)
            }
        } else {
            appliedLat = nil
            appliedLon = nil
            status = "Phone not reachable"
            log(SLSpoofWorker.explain(code))
        }
    }
 
    private func clearLocation() async {
        let code: Int32 = await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: clear_simulated_location())
            }
        }
        if code != 0 && appliedLat != nil {
            log("Clearing the location returned code \(code).")
        }
        appliedLat = nil
        appliedLon = nil
    }
 
    /// The numbers are StikDebug's own status codes from simulate_location.
    static func explain(_ code: Int32) -> String {
        switch code {
        case 1:
            return "Code 1: the device IP is not valid. It should be the LocalDevVPN address."
        case 2:
            return "Code 2: the pairing file could not be read. Choose it again (see the guide)."
        case 3:
            return "Code 3: could not open the tunnel. Is LocalDevVPN connected, and are you on Wi-Fi or in Airplane Mode?"
        case 9:
            return "Code 9: could not reach the developer services. Is Developer Mode on and the screen unlocked?"
        case 10:
            return "Code 10: the location service is not available. The developer disk image may not be mounted."
        case 11:
            return "Code 11: the phone refused the location."
        case 12:
            return "Code 12: there was no active simulation to clear."
        default:
            return "Location error code \(code)."
        }
    }
 
    // MARK: Log
 
    private func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        lines.append(formatter.string(from: Date()) + "  " + text)
        if lines.count > 60 {
            lines.removeFirst(lines.count - 60)
        }
    }
}
 
// MARK: - Settings screen
 
@MainActor
struct SLSpoofRemoteView: View {
    @ObservedObject private var worker = SLSpoofWorker.shared
    @State private var showImporter = false
 
    private let accent = Color(red: 0.96, green: 0.51, blue: 0.13)
 
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Website")) {
                    TextField("Site API URL", text: $worker.apiURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Your token", text: $worker.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
 
                Section(
                    header: Text("This iPhone"),
                    footer: Text("Needs LocalDevVPN connected, Developer Mode on, and the phone on Wi-Fi or in Airplane Mode.")
                ) {
                    TextField("Device IP (LocalDevVPN)", text: $worker.deviceIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    HStack {
                        Text("Pairing file")
                        Spacer()
                        Text(worker.pairingFileExists ? "Found" : "Missing")
                            .foregroundColor(worker.pairingFileExists ? .green : .red)
                    }
                    Text(worker.pairingFileDisplayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Choose pairing file...") {
                        showImporter = true
                    }
                }
 
                Section(header: Text("Worker")) {
                    Button(action: toggle) {
                        Text(worker.running ? "Stop" : "Start").bold()
                    }
                    Text(worker.status)
                }
 
                Section(header: Text("Activity")) {
                    if worker.lines.isEmpty {
                        Text("Nothing yet.").foregroundColor(.secondary)
                    }
                    ForEach(Array(worker.lines.reversed().enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationTitle("SL_Spoof")
            .tint(accent)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType.item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    worker.importPairingFile(from: url)
                }
            }
        }
    }
 
    private func toggle() {
        if worker.running {
            worker.stop()
        } else {
            worker.start()
        }
    }
}
