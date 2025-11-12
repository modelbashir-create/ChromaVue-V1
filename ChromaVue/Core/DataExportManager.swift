//
//  DataExportManager.swift
//  ChromaVue
//
//  Modern, UIKit-free export manager for research/dev sessions.
//  Writes JSONL (and optional CSV) plus optional PNG heatmap previews.
//

import Foundation
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif


// MARK: - Export record models (Camera 2.0)

enum TorchPhase: String, Codable {
    case on = "ON"
    case off = "OFF"
    case ambient = "AMBIENT"
    case unknown = "UNKNOWN"
}

struct ExportFrameRecord: Codable {
    let type: String
    let captureMS: Int64
    let frameIndex: Int
    let torchPhase: TorchPhase
    let exposureMS: Double?
    let iso: Double?
    let wb_r_gain: Double?
    let wb_g_gain: Double?
    let wb_b_gain: Double?
    let torchOn: Bool?
    let torchLevel: Double?
    let distanceMM: Double?
    let tiltDeg: Double?
    let meanR: Double?
    let meanG: Double?
    let meanB: Double?
    let log10_R_over_G: Double?
    let dI555: Double?
    let dI590: Double?
    let dI640: Double?
    let log_555_590: Double?
    let log_640_590: Double?
    let log_555_640: Double?
    let sto2_min: Double?
    let sto2_mean: Double?
    let sto2_max: Double?
    let inferenceMS: Double?

    // scalar summary and grid path (Tier 2/3)
    let scalarMean: Double?
    let scalarStd: Double?
    var scalarFieldPath: String?

    // Optional per-channel RGB and depth grid paths (Tier 3+)
    var rgbRPath: String?
    var rgbGPath: String?
    var rgbBPath: String?
    var depthFieldPath: String?

    let inDistanceWindow: Bool?
    let inTiltWindow: Bool?
    let notSaturated: Bool?
    let pairedOK: Bool?
    var pngHeatmap: String?

    // Convenience initializer that fixes the `type` and matches call sites
    init(
        captureMS: Int64,
        frameIndex: Int,
        torchPhase: TorchPhase,
        // device/capture telemetry
        exposureMS: Double? = nil,
        iso: Double? = nil,
        wb_r_gain: Double? = nil,
        wb_g_gain: Double? = nil,
        wb_b_gain: Double? = nil,
        // state + geometry
        torchOn: Bool? = nil,
        torchLevel: Double? = nil,
        distanceMM: Double? = nil,
        tiltDeg: Double? = nil,
        // per-frame analysis
        meanR: Double? = nil,
        meanG: Double? = nil,
        meanB: Double? = nil,
        log10_R_over_G: Double? = nil,
        dI555: Double? = nil,
        dI590: Double? = nil,
        dI640: Double? = nil,
        log_555_590: Double? = nil,
        log_640_590: Double? = nil,
        log_555_640: Double? = nil,
        // inference + timing
        sto2_min: Double? = nil,
        sto2_mean: Double? = nil,
        sto2_max: Double? = nil,
        inferenceMS: Double? = nil,
        // scalar summary and grid path (Tier 2/3)
        scalarMean: Double? = nil,
        scalarStd: Double? = nil,
        scalarFieldPath: String? = nil,
        // optional RGB + depth grids (Tier 3+)
        rgbRPath: String? = nil,
        rgbGPath: String? = nil,
        rgbBPath: String? = nil,
        depthFieldPath: String? = nil,
        // QC flags
        inDistanceWindow: Bool? = nil,
        inTiltWindow: Bool? = nil,
        notSaturated: Bool? = nil,
        pairedOK: Bool? = nil,
        // assets
        pngHeatmap: String? = nil
    ) {
        self.type = "frame"
        self.captureMS = captureMS
        self.frameIndex = frameIndex
        self.torchPhase = torchPhase
        self.exposureMS = exposureMS
        self.iso = iso
        self.wb_r_gain = wb_r_gain
        self.wb_g_gain = wb_g_gain
        self.wb_b_gain = wb_b_gain
        self.torchOn = torchOn
        self.torchLevel = torchLevel
        self.distanceMM = distanceMM
        self.tiltDeg = tiltDeg
        self.meanR = meanR
        self.meanG = meanG
        self.meanB = meanB
        self.log10_R_over_G = log10_R_over_G
        self.dI555 = dI555
        self.dI590 = dI590
        self.dI640 = dI640
        self.log_555_590 = log_555_590
        self.log_640_590 = log_640_590
        self.log_555_640 = log_555_640
        self.sto2_min = sto2_min
        self.sto2_mean = sto2_mean
        self.sto2_max = sto2_max
        self.inferenceMS = inferenceMS
        self.scalarMean = scalarMean
        self.scalarStd = scalarStd
        self.scalarFieldPath = scalarFieldPath
        self.rgbRPath = rgbRPath
        self.rgbGPath = rgbGPath
        self.rgbBPath = rgbBPath
        self.depthFieldPath = depthFieldPath
        self.inDistanceWindow = inDistanceWindow
        self.inTiltWindow = inTiltWindow
        self.notSaturated = notSaturated
        self.pairedOK = pairedOK
        self.pngHeatmap = pngHeatmap
    }
}

struct ExportEventRecord: Codable {
    let type: String
    let timestampMS: Int64
    let name: String
    let note: String?

    // Convenience initializer that fixes the `type` for events
    init(timestampMS: Int64, name: String, note: String? = nil) {
        self.type = "event"
        self.timestampMS = timestampMS
        self.name = name
        self.note = note
    }
}

@MainActor
final class DataExportManager: ObservableObject {
    static let shared = DataExportManager()
    private init() {}

    // Schema version for exported data
    private static let schemaVersion: Int = 2

    // Shared CSV header definition (keep in sync with README and appendFrame)
    private static let csvHeaderFields: [String] = [
        "timestamp_ms","frame_index","type","schema_version","torch_phase","exposure_ms","iso",
        "wb_r_gain","wb_g_gain","wb_b_gain",
        "torch_on","torch_level","distance_mm","tilt_deg","orientation_deg","canonical_orientation_deg",
        "mean_r","mean_g","mean_b","log10_r_over_g",
        "dI555","dI590","dI640","log555_590","log640_590","log555_640",
        "sto2_min","sto2_mean","sto2_max","inference_ms",
        "scalar_mean","scalar_std","scalar_field_path",
        "in_distance_window","in_tilt_window","not_saturated","paired_ok",
        "png_heatmap"
    ]

    // MARK: - Dev / research export toggles (wired to Developer Controls sheet)
    /// When true, frame/event export is enabled (research/training mode).
    /// When false, all append calls are no-ops and no files are written.
    @Published var isEnabledDev: Bool = false
    @Published var writeCSV: Bool = false
    @Published var saveHeatmapPNG: Bool = false    // PNG heatmap export (currently disabled in pipeline)
    @Published var savePreviewJPEG: Bool = false   // used by RAW stills delegate

    // MARK: - Session state
    private(set) var sessionFolder: URL? = nil
    private(set) var sessionID: String = ""
    private var jsonURL: URL? = nil
    private var csvURL: URL? = nil
    private var csvHeaderWritten: Bool = false
    private var writer: LineWriter? = nil       // JSONL line writer
    private var csvWriter: LineWriter? = nil    // CSV line writer

    // Session time base: store epoch at start, export relative ms (t0 = 0)
    private(set) var sessionStartEpochMS: Int64 = 0
    @inline(__always) func sessionRelativeMS() -> Int64 {
        guard sessionStartEpochMS > 0 else { return 0 }
        return Int64(Date().timeIntervalSince1970 * 1000) - sessionStartEpochMS
    }

    // Back-compat alias if older code references it
    var currentSessionDirectory: URL? { sessionFolder }

    // MARK: - Public API

    /// Ensure a writable session folder and writer exist (lazy start).
    func ensureSession() {
        guard isEnabledDev else { return }
        if sessionFolder == nil { beginNewSession() }
    }

    /// Append one frame’s JSONL (and CSV if enabled).
    /// Optionally saves:
    /// - heatmapPreview: PNG overlay
    /// - scalarGrid: scalar field (Float32; scalarSide×scalarSide)
    /// - rgbR/G/BGrid: per-channel RGB grids (Float32; rgbSide×rgbSide)
    /// - depthGrid: depth field grid (Float32; depthSide×depthSide, meters)
    func appendFrame(_ rec: ExportFrameRecord,
                     heatmapPreview: Data? = nil,
                     scalarGrid: [Float]? = nil,
                     scalarSide: Int = 64,
                     rgbRGrid: [Float]? = nil,
                     rgbGGrid: [Float]? = nil,
                     rgbBGrid: [Float]? = nil,
                     rgbSide: Int = 64,
                     depthGrid: [Float]? = nil,
                     depthSide: Int = 64) {
        guard isEnabledDev else { return }
        ensureSession()
        guard sessionFolder != nil else { return }

        var record = rec

        // Tier 3: write scalar grid if provided and record the relative path
        if let grid = scalarGrid {
            if let path = saveScalarFieldGrid(scalarGrid: grid,
                                              sideLength: scalarSide,
                                              frameIndex: record.frameIndex) {
                record.scalarFieldPath = path
            }
        }

        // Optional per-channel RGB grids (Tier 3+)
        if let rGrid = rgbRGrid {
            if let path = saveRGBChannelGrid(channel: "R",
                                             grid: rGrid,
                                             sideLength: rgbSide,
                                             frameIndex: record.frameIndex) {
                record.rgbRPath = path
            }
        }
        if let gGrid = rgbGGrid {
            if let path = saveRGBChannelGrid(channel: "G",
                                             grid: gGrid,
                                             sideLength: rgbSide,
                                             frameIndex: record.frameIndex) {
                record.rgbGPath = path
            }
        }
        if let bGrid = rgbBGrid {
            if let path = saveRGBChannelGrid(channel: "B",
                                             grid: bGrid,
                                             sideLength: rgbSide,
                                             frameIndex: record.frameIndex) {
                record.rgbBPath = path
            }
        }

        // Optional depth grid (Tier 3+)
        if let dGrid = depthGrid {
            if let path = saveDepthFieldGrid(depthGrid: dGrid,
                                             sideLength: depthSide,
                                             frameIndex: record.frameIndex) {
                record.depthFieldPath = path
            }
        }

        // Heatmap PNG export is currently disabled for training-focused pipeline.
        // The `heatmapPreview` parameter and `pngHeatmap` field are kept for future use,
        // but we do not write any PNG files in this build.
        if saveHeatmapPNG, heatmapPreview != nil {
            // Intentionally no-op
        }

        // JSONL (line per record) via LineWriter actor (off main-actor)
        if let writer = writer {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            if let data = try? encoder.encode(record),
               let line = String(data: data, encoding: .utf8) {
                let text = line + "\n"
                Task.detached(priority: .background) {
                    await writer.write(text)
                }
            }
        }

        // CSV (compact summary for quick plots) via CSV LineWriter actor
        if writeCSV, let csvWriter = csvWriter {
            if !csvHeaderWritten {
                let header = Self.csvHeaderFields.joined(separator: ",") + "\n"
                Task.detached(priority: .background) {
                    await csvWriter.write(header)
                }
                csvHeaderWritten = true
            }
            func s(_ v: Double?) -> String { v.map { String($0) } ?? "" }
            func sB(_ v: Bool?) -> String { v.map { String($0) } ?? "" }
            let orientationStr: String = {
                if let d = currentOrientationDeg() { return String(d) }
                return ""
            }()
            let parts: [String] = [
                String(record.captureMS),
                String(record.frameIndex),
                "frame",
                String(Self.schemaVersion),
                record.torchPhase.rawValue,
                s(record.exposureMS),
                s(record.iso),
                s(record.wb_r_gain),
                s(record.wb_g_gain),
                s(record.wb_b_gain),
                sB(record.torchOn),
                s(record.torchLevel),
                s(record.distanceMM),
                s(record.tiltDeg),
                orientationStr,
                "90", // canonical_orientation_deg (portrait)
                s(record.meanR),
                s(record.meanG),
                s(record.meanB),
                s(record.log10_R_over_G),
                s(record.dI555),
                s(record.dI590),
                s(record.dI640),
                s(record.log_555_590),
                s(record.log_640_590),
                s(record.log_555_640),
                s(record.sto2_min),
                s(record.sto2_mean),
                s(record.sto2_max),
                s(record.inferenceMS),
                s(record.scalarMean),
                s(record.scalarStd),
                (record.scalarFieldPath ?? ""),
                sB(record.inDistanceWindow),
                sB(record.inTiltWindow),
                sB(record.notSaturated),
                sB(record.pairedOK),
                (record.pngHeatmap ?? "")
            ]
            let row = parts.joined(separator: ",") + "\n"
            Task.detached(priority: .background) {
                await csvWriter.write(row)
            }
        }
    }

    /// Compatibility overload: older call sites passed an explicit session folder.
    /// We manage the session folder internally; this forwards to the canonical API.
    func appendFrame(_ rec: ExportFrameRecord,
                     from folder: URL,
                     heatmapPreview: Data? = nil,
                     scalarGrid: [Float]? = nil,
                     scalarSide: Int = 64,
                     rgbRGrid: [Float]? = nil,
                     rgbGGrid: [Float]? = nil,
                     rgbBGrid: [Float]? = nil,
                     rgbSide: Int = 64,
                     depthGrid: [Float]? = nil,
                     depthSide: Int = 64) {
        self.appendFrame(rec,
                         heatmapPreview: heatmapPreview,
                         scalarGrid: scalarGrid,
                         scalarSide: scalarSide,
                         rgbRGrid: rgbRGrid,
                         rgbGGrid: rgbGGrid,
                         rgbBGrid: rgbBGrid,
                         rgbSide: rgbSide,
                         depthGrid: depthGrid,
                         depthSide: depthSide)
    }

    // Map current UI device orientation to degrees (portrait=90, landscapeRight=0, landscapeLeft=180, upsideDown=270)
    private func currentOrientationDeg() -> Int? {
        #if canImport(UIKit)
        let o = UIDevice.current.orientation
        switch o {
        case .portrait:            return 90
        case .landscapeRight:      return 0
        case .landscapeLeft:       return 180
        case .portraitUpsideDown:  return 270
        default:                   return nil
        }
        #else
        return nil
        #endif
    }

    /// Append a developer event marker into the current JSONL stream using the
    /// export manager's own session-relative clock. Prefer the timestamped
    /// overload when you already have a canonical timeline (e.g. camera session).
    func appendEvent(name: String, note: String? = nil, extra: [String:String]? = nil) {
        let ts = sessionRelativeMS()
        appendEvent(timestampMS: ts, name: name, note: note, extra: extra)
    }

    /// Append a developer event marker with an explicit timestamp in ms.
    /// This is used when another component (such as ChromaCameraManager)
    /// owns the canonical session timeline and we want events to share that
    /// same time base as frame records in frames.jsonl.
    func appendEvent(timestampMS: Int64,
                     name: String,
                     note: String? = nil,
                     extra: [String:String]? = nil) {
        guard isEnabledDev else { return }
        ensureSession()
        guard let writer = writer else { return }

        // Extra key/value metadata is currently ignored but reserved for future use.
        _ = extra

        let rec = ExportEventRecord(
            timestampMS: timestampMS,
            name: name,
            note: note
        )

        HistoryStore.shared.appendEvent(sessionID: sessionID,
                                        timestampMS: timestampMS,
                                        name: name,
                                        note: note)

        let encoder = JSONEncoder()
        if let data = try? encoder.encode(rec),
           let line = String(data: data, encoding: .utf8) {
            let text = line + "\n"
            Task.detached(priority: .background) {
                await writer.write(text)
            }
        }
    }

    // MARK: - Session lifecycle

    /// Starts a fresh session folder under Documents/ChromaVueSessions/.
    func beginNewSession() {
        let root = Self.sessionsRoot()
        let stamp = Self.timestampString()
        let folder = root.appendingPathComponent("Session_\(stamp)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {}

        // Pre-create subfolders
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("imgs", isDirectory: true), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("stills", isDirectory: true), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("scalar", isDirectory: true), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("rgb", isDirectory: true), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("depth", isDirectory: true), withIntermediateDirectories: true)

        sessionFolder = folder
        sessionID = stamp

        // Establish session time base (epoch ms → export relative ms)
        self.sessionStartEpochMS = Int64(Date().timeIntervalSince1970 * 1000)

        HistoryStore.shared.beginSession(id: sessionID, folderPath: folder.path)

        // Auto-drop README.txt with schema + units
        writeReadme(into: folder)

        // Auto-drop a colormap swatch for reproducibility of visualizations
        writeColormapPNG(into: folder)

        csvHeaderWritten = false

        // Prepare JSONL and writer
        let json = folder.appendingPathComponent("frames.jsonl")
        let _ = FileManager.default.createFile(atPath: json.path, contents: nil)
        self.writer = LineWriter(url: json)
        self.jsonURL = json

        // Prepare CSV if enabled
        if writeCSV {
            let csv = folder.appendingPathComponent("summary.csv")
            if !FileManager.default.fileExists(atPath: csv.path) {
                FileManager.default.createFile(atPath: csv.path, contents: nil)
            }
            self.csvURL = csv
            self.csvHeaderWritten = false
            self.csvWriter = LineWriter(url: csv)
        } else {
            self.csvURL = nil
            self.csvWriter = nil
        }
    }

    /// Ends the current session.
    func endSession() {
        if !sessionID.isEmpty {
            HistoryStore.shared.endSession(id: sessionID)
        }
        sessionFolder = nil
        sessionID = ""
        jsonURL = nil
        csvURL = nil
        csvHeaderWritten = false
        writer = nil
        csvWriter = nil
    }

    // Auto-drop a README.txt describing schema, units, and capture context
    private func writeReadme(into folder: URL) {
        // App + device
        let bundle = Bundle.main
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "ChromaVue"
        let appVer  = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build   = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"

        var deviceLine = "iOS"
        #if canImport(UIKit)
        let dev = UIDevice.current
        deviceLine = "\(dev.systemName) \(dev.systemVersion) — \(dev.model)"
        #endif

        // Keep CSV header in sync with appendFrame
        let headerCSV = Self.csvHeaderFields.joined(separator: ",")

        let readme = """
        ChromaVue Research Session
        Date: \(Date())
        App: \(appName) \(appVer) (\(build))
        Device: \(deviceLine)

        Schema: 2  (frames use type="frame"; events use type="event" in JSONL)

        Files:
        - frames.jsonl : one JSON object per line (frames + events)
        - summary.csv  : selected frame fields for quick plots
        - COLORMAP.png : diverging colormap reference (Blue↔Red, clamp −0.30…+0.30)
        - imgs/*.png   : optional 256×256 heatmap previews (feature may be disabled)
        - stills/*.dng : optional RAW stills
        - stills/*.heic: optional processed stills (HEIC sidecar if enabled)
        - scalar/*.bin : optional scalar field grids (Float32; side×side, row-major)
        - rgb/*.bin    : optional per-channel RGB grids (Float32; side×side, row-major)
        - depth/*.bin  : optional depth field grids (Float32; side×side, row-major)

        CSV Columns (summary.csv):
        \(headerCSV)

        Units:
        - timestamp_ms: milliseconds since session start (t0 = 0)
        - session_start_epoch_ms: \(self.sessionStartEpochMS)
        - exposure_ms, inference_ms: milliseconds
        - iso: camera ISO (unitless)
        - torch_on: boolean (0/1); torch_level: 0.0–1.0
        - distance_mm: millimeters; tilt_deg: degrees
        - orientation_deg: degrees (0/90/180/270) — UI/preview orientation metadata
        - canonical_orientation_deg: degrees (fixed 90; saved/analysis canonical portrait)
        - mean_r, mean_g, mean_b: 0–255 channel means (BGRA sampling)
        - log10_r_over_g, log ratios: base-10 logarithm (dimensionless)
        - dI555/590/640: ON–OFF band differences (proxy intensity, 0–1)
        - sto2_min/mean/max: percent [0–100]
        - scalar_mean, scalar_std: mean and standard deviation of the scalar field (unclamped)
        - scalar_field_path: relative path under scalar/ to a Float32 binary grid (side×side, row-major)
        - rgb_r_path / rgb_g_path / rgb_b_path: relative paths under rgb/ to Float32 channel grids (side×side, row-major)
        - depth_field_path: relative path under depth/ to a Float32 depth grid (side×side, row-major, meters)
        - not_saturated: boolean; true when <2% of sampled pixels are ≥ 250 in any RGB channel
        - png_heatmap: relative path under imgs/

        Capture settings (typical):
        - torch alternation: ON/OFF pairing (Δ computed when ON follows recent OFF)
        - scalar clamp: [−0.30, +0.30]; colormap: Blue↔Red diverging
        - QC windows: distance 80–150 mm; |tilt| ≤ 10°; saturation < 1%

        Notes:
        - RGB→(555/590/640) mapping uses provisional weights; calibrate with pigment measurements.
        - JSONL retains full fidelity; CSV is a compact summary for quick plotting.
        - Saved heatmap previews (if any) are rendered in canonical portrait (90°) for consistency.
        """

        let url = folder.appendingPathComponent("README.txt")
        do {
            try readme.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ README write failed: \(error)")
        }
    }

    /// Tier 3: Save a scalar field grid as Float32 binary and return a relative path under the session folder.
    func saveScalarFieldGrid(scalarGrid: [Float],
                             sideLength: Int,
                             frameIndex: Int) -> String? {
        guard let folder = sessionFolder else { return nil }
        guard !scalarGrid.isEmpty,
              scalarGrid.count == sideLength * sideLength else { return nil }

        let scalarDir = folder.appendingPathComponent("scalar", isDirectory: true)
        try? FileManager.default.createDirectory(at: scalarDir, withIntermediateDirectories: true)

        let name = String(format: "scalar_%06d.bin", frameIndex)
        let url = scalarDir.appendingPathComponent(name)

        var data = Data()
        data.reserveCapacity(scalarGrid.count * MemoryLayout<Float>.size)
        scalarGrid.withUnsafeBufferPointer { buf in
            let raw = UnsafeRawBufferPointer(buf)
            data.append(contentsOf: raw)
        }

        // Write asynchronously using the shared appendData helper
        Task.detached(priority: .background) {
            DataExportManager.appendData(data, to: url)
        }

        // Return a path relative to the session folder for portability
        return "scalar/\(name)"
    }

    /// Tier 3: Save a single RGB channel grid as Float32 binary under rgb/ and return a relative path.
    func saveRGBChannelGrid(channel: String,
                            grid: [Float],
                            sideLength: Int,
                            frameIndex: Int) -> String? {
        guard let folder = sessionFolder else { return nil }
        guard !grid.isEmpty,
              grid.count == sideLength * sideLength else { return nil }

        let rgbDir = folder.appendingPathComponent("rgb", isDirectory: true)
        try? FileManager.default.createDirectory(at: rgbDir, withIntermediateDirectories: true)

        let name = String(format: "rgb%@_%06d.bin", channel, frameIndex) // e.g. rgbR_000123.bin
        let url = rgbDir.appendingPathComponent(name)

        var data = Data()
        data.reserveCapacity(grid.count * MemoryLayout<Float>.size)
        grid.withUnsafeBufferPointer { buf in
            let raw = UnsafeRawBufferPointer(buf)
            data.append(contentsOf: raw)
        }

        Task.detached(priority: .background) {
            DataExportManager.appendData(data, to: url)
        }

        return "rgb/\(name)"
    }

    /// Tier 3: Save a depth field grid as Float32 binary under depth/ and return a relative path.
    func saveDepthFieldGrid(depthGrid: [Float],
                            sideLength: Int,
                            frameIndex: Int) -> String? {
        guard let folder = sessionFolder else { return nil }
        guard !depthGrid.isEmpty,
              depthGrid.count == sideLength * sideLength else { return nil }

        let depthDir = folder.appendingPathComponent("depth", isDirectory: true)
        try? FileManager.default.createDirectory(at: depthDir, withIntermediateDirectories: true)

        let name = String(format: "depth_%06d.bin", frameIndex)
        let url = depthDir.appendingPathComponent(name)

        var data = Data()
        data.reserveCapacity(depthGrid.count * MemoryLayout<Float>.size)
        depthGrid.withUnsafeBufferPointer { buf in
            let raw = UnsafeRawBufferPointer(buf)
            data.append(contentsOf: raw)
        }

        Task.detached(priority: .background) {
            DataExportManager.appendData(data, to: url)
        }

        return "depth/\(name)"
    }

    // Render a Blue↔White↔Red diverging colormap swatch with clamp ticks (-0.30, 0, +0.30)
    private func writeColormapPNG(into folder: URL) {
        let size = CGSize(width: 512, height: 84)
        let barRect = CGRect(x: 20, y: 26, width: size.width - 40, height: 18)
        let tickY1 = barRect.maxY + 4
        let tickY2 = tickY1 + 8

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Background
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1.0))
        ctx.fill(CGRect(origin: .zero, size: size))

        // Gradient colors (Blue → White → Red)
        func C(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
            CGColor(colorSpace: cs, components: [r, g, b, 1.0])!
        }
        let colors: [CGColor] = [
            C(0.10, 0.25, 0.80),
            C(0.30, 0.60, 1.00),
            C(1.00, 1.00, 1.00),
            C(1.00, 0.50, 0.20),
            C(0.85, 0.10, 0.10)
        ]
        let locs: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
        guard let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) else { return }

        // Draw gradient bar
        let path = UIBezierPath(roundedRect: barRect, cornerRadius: 6).cgPath
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: barRect.minX, y: barRect.midY),
                               end: CGPoint(x: barRect.maxX, y: barRect.midY),
                               options: [])
        ctx.resetClip()

        // Bar border
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.6))
        ctx.addPath(path)
        ctx.strokePath()

        // Ticks at -0.30, 0, +0.30 (left, center, right)
        let tickXs: [CGFloat] = [barRect.minX, barRect.midX, barRect.maxX]
        ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.8))
        ctx.setLineWidth(1)
        for x in tickXs {
            ctx.move(to: CGPoint(x: x, y: tickY1))
            ctx.addLine(to: CGPoint(x: x, y: tickY2))
            ctx.strokePath()
        }

        // Labels (UIKit when available)
        #if canImport(UIKit)
        let labels = ["−0.30", "0", "+0.30"]
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para
        ]
        for (i, x) in tickXs.enumerated() {
            let w: CGFloat = 56
            let rect = CGRect(x: x - w/2, y: tickY2 + 2, width: w, height: 16)
            (labels[i] as NSString).draw(in: rect, withAttributes: attrs)
        }
        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        ("Blue ↔ Red (scalar clamp −0.30 … +0.30)" as NSString).draw(at: CGPoint(x: 20, y: 6), withAttributes: titleAttrs)
        #endif

        guard let cg = ctx.makeImage() else { return }
        let url = folder.appendingPathComponent("COLORMAP.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Utilities

    private static func sessionsRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = docs.appendingPathComponent("ChromaVueSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// Append bytes to file, creating it if needed (thread-safe from any actor)
    nonisolated static func appendData(_ data: Data, to url: URL) {
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            do {
                try h.write(contentsOf: data)
            } catch {
                print("⚠️ appendData seek/write error: \(error)")
            }
        } else {
            do { try data.write(to: url, options: .atomic) }
            catch { print("⚠️ appendData create/write error: \(error)") }
        }
    }
}

// MARK: - Simple async line writer actor

actor LineWriter {
    let url: URL
    init(url: URL) {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }
    func write(_ line: String) async {
        if let data = line.data(using: .utf8) {
            DataExportManager.appendData(data, to: url)
        }
    }
}
 
