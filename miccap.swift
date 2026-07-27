// miccap.swift — record the system default input device to 16 kHz mono WAV.
//
// Exists for the case ffmpeg's avfoundation handles poorly: reading a Bluetooth
// (HFP) microphone that a call app also holds — ffmpeg's capture fragments
// badly there. This uses AVAudioEngine at the device's native format, converts
// to 16 kHz mono, pads timestamp gaps with silence (so the track stays in sync
// with the system-audio capture), and survives input-device format changes.
//
// Build:  swiftc -O -o miccap miccap.swift
// Usage:  miccap <out.wav> [seconds]     (no duration: records until SIGINT/SIGTERM)

import AVFoundation
import Foundation

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

guard CommandLine.arguments.count >= 2 else {
    err("usage: miccap <out.wav> [seconds]")
    exit(2)
}
let outPath = CommandLine.arguments[1]
let duration: Double? = CommandLine.arguments.count >= 3 ? Double(CommandLine.arguments[2]) : nil

final class WavWriter {
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private let lock = NSLock()

    init?(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        handle.write(Data(count: 44))  // header placeholder, patched on finalize
    }

    func append(_ samples: UnsafePointer<Int16>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        handle.write(Data(bytes: samples, count: count * 2))
        dataBytes += UInt32(count * 2)
    }

    func appendSilence(frames: Int) {
        lock.lock(); defer { lock.unlock() }
        handle.write(Data(count: frames * 2))
        dataBytes += UInt32(frames * 2)
    }

    func finalize(sampleRate: UInt32) {
        lock.lock(); defer { lock.unlock() }
        var h = Data()
        func str(_ s: String) { h.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        str("RIFF"); u32(36 + dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(sampleRate)
        u32(sampleRate * 2); u16(2); u16(16)
        str("data"); u32(dataBytes)
        handle.seek(toFileOffset: 0)
        handle.write(h)
        handle.closeFile()
    }
}

final class Recorder {
    let writer: WavWriter
    let engine = AVAudioEngine()
    let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                               channels: 1, interleaved: true)!
    var inFmt: AVAudioFormat!
    var conv: AVAudioConverter!
    var expectedNext: AVAudioFramePosition = -1
    var gapSeconds: Double = 0
    var stopped = false

    init(writer: WavWriter) { self.writer = writer }

    func start() throws {
        inFmt = engine.inputNode.inputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            throw NSError(domain: "miccap", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no usable input device (missing mic permission?)"])
        }
        guard let c = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw NSError(domain: "miccap", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot convert \(inFmt.sampleRate) Hz input"])
        }
        conv = c
        expectedNext = -1
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, when in
            self?.handle(buf, when)
        }
        try engine.start()
        err("miccap: recording default input (\(Int(inFmt.sampleRate)) Hz, \(inFmt.channelCount) ch)")
    }

    func handle(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime) {
        if stopped { return }
        if when.isSampleTimeValid {
            if expectedNext >= 0 {
                let delta = when.sampleTime - expectedNext
                // > ~100 ms of missing samples = a real capture gap: pad it so the
                // track can't drift out of sync with the system-audio channel
                if Double(delta) > inFmt.sampleRate * 0.1 {
                    let frames = Int(Double(delta) * outFmt.sampleRate / inFmt.sampleRate)
                    writer.appendSilence(frames: frames)
                    gapSeconds += Double(delta) / inFmt.sampleRate
                }
            }
            expectedNext = when.sampleTime + AVAudioFramePosition(buf.frameLength)
        }
        let ratio = outFmt.sampleRate / inFmt.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var served = false
        var convErr: NSError?
        conv.convert(to: outBuf, error: &convErr) { _, status in
            if served { status.pointee = .noDataNow; return nil }
            served = true
            status.pointee = .haveData
            return buf
        }
        if let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 {
            writer.append(ch[0], count: Int(outBuf.frameLength))
        }
    }

    func restart() {
        guard !stopped else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try start()
            err("miccap: input configuration changed — capture restarted")
        } catch {
            err("miccap: restart after configuration change failed: \(error.localizedDescription)")
            stop()
            exit(1)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if gapSeconds > 0.5 {
            err(String(format: "miccap: ⚠️  %.1fs of capture gaps were padded with silence", gapSeconds))
        }
        writer.finalize(sampleRate: 16000)
    }
}

guard let writer = WavWriter(path: outPath) else {
    err("miccap: cannot open \(outPath) for writing")
    exit(1)
}
let rec = Recorder(writer: writer)
do { try rec.start() } catch {
    err("miccap: \(error.localizedDescription)")
    exit(1)
}

NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                       object: rec.engine, queue: .main) { _ in rec.restart() }

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
for sig in [SIGINT, SIGTERM] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { rec.stop(); exit(0) }
    src.resume()
    _ = Unmanaged.passRetained(src as AnyObject)  // keep the source alive
}

if let d = duration {
    DispatchQueue.main.asyncAfter(deadline: .now() + d) { rec.stop(); exit(0) }
}
RunLoop.main.run()
