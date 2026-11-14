//
//  SLSpoofRemote.swift
//  SL_Spoof add-on for StikDebug
//
//  Licence: AGPL-3.0, the same as StikDebug (this file is part of a modified StikDebug).
//
//  What it does
//  ------------
//  Polls the SL_Spoof website (GET <site>/wp-json/loc/v1/current, header X-Loc-Token) and applies
//  the location the user picked on the web page, using StikDebug's own on-device location
//  simulation (simulate_location / clear_simulated_location). A stock iPhone can then be its
//  own worker: no computer is needed after the one-time pairing-file setup.
//
//  It relies only on things that exist in StikDebug's source:
//    simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32
//    clear_simulated_location() -> Int32
//    LocationSimulationCommandQueue.shared            (serial DispatchQueue)
//    DeviceConnectionContext.defaultTargetIPAddress   (the LocalDevVPN address)
//    BackgroundLocationManager.shared                 (keeps the app alive in the background)
//
//  NOT compiled or run by its author. See SL_Spoof_Stock_iPhone_Guide.md for how to build and test.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
