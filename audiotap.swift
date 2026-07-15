// audiotap — record macOS system audio output (all processes) to a 16kHz mono WAV.
//
// Uses Core Audio process taps (macOS 14.4+), the same mechanism meeting
// recorders like Notion/Granola use: no virtual audio device, no output
// re-routing. First run triggers a one-time System Audio Recording
// permission prompt for the invoking app (e.g. your terminal).
//
// Usage: audiotap <output.wav> [max-seconds]
// Stops cleanly on SIGINT/SIGTERM (finalizes the WAV header).
//
// Build: swiftc -O -o audiotap audiotap.swift

import AVFoundation
import CoreAudio
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("audiotap: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count >= 2 else {
    fail("usage: audiotap <output.wav> [max-seconds]")
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
let maxSeconds: Double? = CommandLine.arguments.count >= 3 ? Double(CommandLine.arguments[2]) : nil

// --- create a global process tap (stereo mixdown of everything) ---

let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDesc.isPrivate = true
tapDesc.muteBehavior = .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard status == noErr, tapID != kAudioObjectUnknown else {
    fail("could not create system audio tap (status \(status)). " +
         "Needs macOS 14.4+ and System Audio Recording permission " +
         "(System Settings → Privacy & Security → Screen & System Audio Recording).")
}

// --- read the tap's stream format ---

var fmtAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var asbd = AudioStreamBasicDescription()
var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
status = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &asbdSize, &asbd)
guard status == noErr, let inFormat = AVAudioFormat(streamDescription: &asbd) else {
    AudioHardwareDestroyProcessTap(tapID)
    fail("could not read tap format (status \(status))")
}

// --- wrap the tap in a private aggregate device so we can run an IO proc ---

let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "audiotap-aggregate",
    kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey as String: true,
    kAudioAggregateDeviceTapAutoStartKey as String: true,
    kAudioAggregateDeviceTapListKey as String: [
        [kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
         kAudioSubTapDriftCompensationKey as String: true]
    ],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard status == noErr, aggID != kAudioObjectUnknown else {
    AudioHardwareDestroyProcessTap(tapID)
    fail("could not create aggregate device (status \(status))")
}

// --- output file + converter to 16 kHz mono s16le (whisper's input format) ---

guard let outFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
else { fail("could not build output format") }

let fileSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 16000,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]
let outFile: AVAudioFile
do {
    outFile = try AVAudioFile(
        forWriting: outURL, settings: fileSettings,
        commonFormat: .pcmFormatInt16, interleaved: true)
} catch {
    fail("could not open \(outURL.path): \(error.localizedDescription)")
}

guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
    fail("could not build converter \(inFormat) -> \(outFormat)")
}

// --- IO proc: convert each input buffer and append to the file ---

var ioProcID: AudioDeviceIOProcID?
let writeQueue = DispatchQueue(label: "audiotap.write")

status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil) {
    _, inInputData, _, _, _ in
    guard let inBuf = AVAudioPCMBuffer(
        pcmFormat: inFormat, bufferListNoCopy: inInputData, deallocator: nil),
        inBuf.frameLength > 0
    else { return }

    let ratio = outFormat.sampleRate / inFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 64
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
    else { return }

    var consumed = false
    var err: NSError?
    converter.convert(to: outBuf, error: &err) { _, outStatus in
        if consumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return inBuf
    }
    if outBuf.frameLength > 0 {
        writeQueue.sync { try? outFile.write(from: outBuf) }
    }
}
guard status == noErr, let procID = ioProcID else {
    fail("could not create IO proc (status \(status))")
}

status = AudioDeviceStart(aggID, procID)
guard status == noErr else { fail("could not start capture (status \(status))") }

// --- run until signaled (or max-seconds) ---

var stopping = false
func stop(_ code: Int32) {
    if stopping { return }
    stopping = true
    AudioDeviceStop(aggID, procID)
    AudioDeviceDestroyIOProcID(aggID, procID)
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    writeQueue.sync {}  // flush pending writes; AVAudioFile finalizes on release
    exit(code)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { stop(0) }
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { stop(0) }
sigterm.resume()

if let maxSeconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds) { stop(0) }
}

FileHandle.standardError.write(
    "audiotap: recording system audio to \(outURL.path)\n".data(using: .utf8)!)
RunLoop.main.run()
