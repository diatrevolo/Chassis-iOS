//
//  AudioEngine.swift
//  Chassis
//
//  Created by Roberto Osorio Goenaga on 4/5/20.
//  Copyright © 2020 Roberto Osorio Goenaga.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

// swiftlint:disable file_length
import Foundation
import AVFoundation
import AudioToolbox
import Combine

public protocol EngineConnectable: class {
    var updater: CADisplayLink? { get set }
    var progressObserver: AnyPublisher<Double, Never> { get }
    var isPlaying: Bool { get }

    func addToMix(file: AVAudioFile, at time: AVAudioTime?)
    func removeFromMix(node: AVAudioPlayerNode)
    func play()
    func pause()
    func stop()
    func scrub(to interval: TimeInterval)
    func skipForward()
    func skipBackward()
    func loadAllTracksAndAddToMix(tracks: [Track])
    func unloadTrack(node: AVAudioPlayerNode)
    func unloadAllTracks()
    func getMixLength() -> TimeInterval
    func getLength(for filename: String?) -> Double
    func startRecording() -> String?
    func stopRecording()
    func bounceScene(filename: String) -> URL?
    func convertFile(filepath: URL, to format: CommonFormats) -> URL?
}

// swiftlint:disable type_body_length
public class AudioEngine: EngineConnectable {
    public var isPlaying: Bool = false
    public var updater: CADisplayLink?
    @Published private var progress: Double = 0
    public var progressObserver: AnyPublisher<Double, Never> {
        $progress.eraseToAnyPublisher()
    }
    var skipFrame: AVAudioFramePosition = 0
    var currentPosition: AVAudioFramePosition = 0
    private var engine = AVAudioEngine()
    private var nodes = [AVAudioPlayerNode]()
    private var durationTable: [String: Double] = [:]
    private var files: [(AVAudioFile, AVAudioTime?)] = []
    private var audioFormat: AVAudioFormat?
    private var recordNode: AVAudioInputNode?
    private var isRecording: Bool = false
    private var sinkNode: AVAudioSinkNode?

    public init() {
        setUpEngine()
        setUpDisplayLink()
    }

    private func setUpEngine() {
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance()
                .setPreferredSampleRate(44100)
            try? AVAudioSession.sharedInstance()
                .setCategory(.playAndRecord,
                             options: [.defaultToSpeaker, .allowBluetoothA2DP])
            self.audioFormat = self.engine.mainMixerNode.outputFormat(forBus: 0)
            self.recordNode = self.engine.inputNode
            self.engine.prepare()
        }
    }

    private func setUpDisplayLink() {
        updater = CADisplayLink(target: self, selector: #selector(updateUI))
        updater?.add(to: .current, forMode: RunLoop.Mode.default)
        updater?.isPaused = true
    }

    @objc private func updateUI() {
        guard let audioFormat = audioFormat else { return }
        progress = (Double(getCurrentPosition()) / audioFormat.sampleRate) / Double(getMixLength())
        if progress >= 1 && !isRecording {
            stop()
        }
    }

    public func addToMix(file: AVAudioFile, at time: AVAudioTime? = nil) {
        DispatchQueue.global(qos: .userInitiated).sync {
            let node = AVAudioPlayerNode()
            nodes.append(node)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: audioFormat)
            node.scheduleFile(file, at: time)
        }
    }

    public func removeFromMix(node: AVAudioPlayerNode) {
        DispatchQueue.global(qos: .background).async {
            self.engine.disconnectNodeInput(node)
        }
    }

    public func play() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let updater = self.updater else { return }
            if !self.engine.isRunning {
                do {
                    try self.engine.start()
                } catch {
                    fatalError("Engine could not start.")
                }
            }
            if !self.isPlaying {
                self.isPlaying = true
                updater.isPaused = false
                self.nodes.enumerated().forEach {
                    $0.element.play(at: nil)
                }
            } else {
                self.pause()
            }
        }
    }

    public func pause() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let updater = self.updater else { return }
            self.isPlaying = false
            updater.isPaused = true
            self.nodes.forEach {
                $0.pause()
            }
        }
    }

    public func stop() {
        DispatchQueue.global(qos: .userInitiated).sync {
            guard let updater = self.updater else { return }
            isPlaying = false
            updater.isPaused = true
            DispatchQueue.main.async {
                self.progress = 0.0
            }
            nodes.forEach {
                $0.stop()
            }
            engine.stop()
            engine.reset()
            unloadAllTracks()
            reloadFiles()
        }
    }

    public func scrub(to interval: TimeInterval) {
        //
    }

    public func skipForward() {
        //
    }

    public func skipBackward() {
        if !engine.isRunning { return }
        let wasPlaying = isPlaying
        stop()
        if wasPlaying {
            play()
        }
    }

    private func loadTrack(_ track: Track) throws -> AVAudioFile? {
        guard let userDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                                      .userDomainMask, true)
        .first else { return nil }
        let documentSearchPathUrl = URL(fileURLWithPath: userDirectory)
        let filePath = documentSearchPathUrl.appendingPathComponent(track.fileURLString)
        return try AVAudioFile(forReading: filePath)
    }

    /**
    Loads array of tracks into AVAudioEngine.

    - Parameter tracks: a Track array

    - Returns: nothing
     
    - This method loads an array of tracks into memory and calculates time offset.
    */
    public func loadAllTracksAndAddToMix(tracks: [Track]) {
        DispatchQueue.global(qos: .default).sync {
            files = [(AVAudioFile, AVAudioTime?)]()
            tracks.forEach {
                if let track = try? self.loadTrack($0) {
                    durationTable[$0.fileURLString] = Double(track.length) / track.processingFormat.sampleRate
                }
            }
            tracks.forEach {
                var audioTime: AVAudioTime?
                let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
                if let startTime = $0.startTime {
                    audioTime = AVAudioTime(sampleTime: Int64(getMixLength() *
                        startTime * sampleRate),
                                            atRate: sampleRate)
                } else {
                    audioTime = nil
                }
                if let track = try? self.loadTrack($0) {
                    files.append((track, audioTime))
                }
            }
            reloadFiles()
        }
    }

    private func reloadFiles() {
        files.forEach {
            addToMix(file: $0.0, at: $0.1)
        }
    }

    public func unloadTrack(node: AVAudioPlayerNode) {
        DispatchQueue.global(qos: .utility).sync {
            engine.detach(node)
            nodes.removeAll {
                $0 == node
            }
        }
    }

    public func unloadAllTracks() {
        nodes.forEach {
            unloadTrack(node: $0)
        }
    }

    /**
     This is a naive implementation that only accounts for the longest track.
     We should assume a user can add a track that doesn't start at 0.
     This is a TODO.
     */
    public func getMixLength() -> TimeInterval {
        var maxDuration: Double = 0
        for (_, duration) in durationTable {
            maxDuration = max(maxDuration, duration)
        }
        return maxDuration
    }

    public func getCurrentPosition() -> AVAudioFramePosition {
        guard let player = nodes.first,
            let nodeTime = player.lastRenderTime,
            let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return playerTime.sampleTime
    }

    public func getLength(for filename: String?) -> Double {
        guard let filename = filename else { return 0 }
        return durationTable[filename] ?? 0
    }

    public func startRecording() -> String? {
        guard let recordNode = recordNode else { return nil }
        let format = recordNode.outputFormat(forBus: 0)
        isRecording = true
        engine.stop()
        let filename = UUID().uuidString + ".caf"
        guard let userDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                                      .userDomainMask, true)
            .first else { return nil }
        let documentSearchPathUrl = URL(fileURLWithPath: userDirectory)
        let filePath = documentSearchPathUrl.appendingPathComponent(filename)
        var fileToSaveOptional: ExtAudioFileRef?
        if CheckError(ExtAudioFileCreateWithURL(filePath as CFURL,
                                             kAudioFileCAFType,
                                             format.streamDescription,
                                             nil,
                                             AudioFileFlags.eraseFile.rawValue,
                                             &fileToSaveOptional),
                       "Error with ExtAudioFileCreateWithURL") != noErr {
            return nil
        }

        guard let fileToSave = fileToSaveOptional else {
            return nil
        }

        sinkNode = AVAudioSinkNode { (_, frames, audioBufferList) -> OSStatus in
            ExtAudioFileWrite(fileToSave, frames, audioBufferList)
            return noErr
        }
        if let sinkNode = sinkNode {
            engine.attach(sinkNode)
            engine.connect(recordNode,
                           to: sinkNode,
                           format: recordNode.inputFormat(forBus: 0))
        }
        engine.prepare()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                fatalError("Engine could not start.")
            }
        }
        return filename
    }

    public func stopRecording() {
        guard let sinkNode = sinkNode else { return }
        engine.stop()
        isRecording = false
        engine.detach(sinkNode)
        self.sinkNode = nil
        engine.reset()
    }

    // swiftlint:disable function_body_length
    public func bounceScene(filename: String) -> URL? {
        engine.stop()
        let audioFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        do {
            let maxFrames: AVAudioFrameCount = 4096
            try engine.enableManualRenderingMode(.offline,
                                                 format: audioFormat,
                                                 maximumFrameCount: maxFrames)
        } catch {
            fatalError("Unable to start offline rendering mode. Error: \(error.localizedDescription)")
        }
        play()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount)
            else { return nil }
        let outputFile: AVAudioFile
        let documentsURL = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask)[0]
        let outputURL = documentsURL.appendingPathComponent(filename)
        do {
            outputFile = try AVAudioFile(forWriting: outputURL,
                                         settings: audioFormat.settings)
        } catch {
            return nil
        }

        let mixLengthInSamples = Int64(getMixLength() * audioFormat.sampleRate)
        while engine.manualRenderingSampleTime < mixLengthInSamples {
            let frameCount = mixLengthInSamples - engine.manualRenderingSampleTime
            let framesToRender = min(AVAudioFrameCount(frameCount), buffer.frameCapacity)

            do {
                let status = try engine.renderOffline(framesToRender, to: buffer)

                switch status {
                case .success:
                    try outputFile.write(from: buffer)
                case .insufficientDataFromInputNode:
                    break
                case .cannotDoInCurrentContext:
                    break
                default:
                    print("Error rendering.")
                    return nil
                }
            } catch {
                print("Error rendering.")
                return nil
            }
        }
        stop()
        engine.disableManualRenderingMode()
        return outputURL
    }

    // swiftlint:disable function_body_length
    // swiftlint:disable cyclomatic_complexity
    public func convertFile(filepath: URL, to format: CommonFormats) -> URL? {
        var inputFile: ExtAudioFileRef?
        var outputFile: ExtAudioFileRef?

        let inputFileURL = filepath as CFURL

        if CheckError(ExtAudioFileOpenURL(inputFileURL,
                                       &inputFile),
                       "Error with ExtAudioFileOpenURL") != noErr {
            return nil
        }

        var outputFormat = AudioStreamBasicDescription()
        var inputFormat = AudioStreamBasicDescription()
        var fileExtension: String
        var audioFileTypeID: AudioFileTypeID
        guard let unwrappedInputFile = inputFile else { return nil }
        switch format {
        case .aiff(let sampleRate, let bitRate):
            // Convert to AIFF
            outputFormat.mSampleRate = sampleRate
            outputFormat.mBitsPerChannel = bitRate
            outputFormat.mFormatID = kAudioFormatLinearPCM
            outputFormat.mFormatFlags = kAudioFormatFlagIsPacked |
                kAudioFormatFlagIsBigEndian |
                kAudioFormatFlagIsSignedInteger
            outputFormat.mBytesPerPacket = 2 * bitRate / 8
            outputFormat.mFramesPerPacket = 1
            outputFormat.mBytesPerFrame = 2 * bitRate / 8
            outputFormat.mChannelsPerFrame = 2
            fileExtension = "aif"
            audioFileTypeID = kAudioFileAIFFType
            inputFormat = outputFormat
        case .m4a(let sampleRate):
            // Convert to MPEG4
            outputFormat.mSampleRate = sampleRate
            outputFormat.mBitsPerChannel = 0
            outputFormat.mFormatID = kAudioFormatMPEG4AAC
            outputFormat.mChannelsPerFrame = 2
            var size: UInt32 = UInt32(MemoryLayout.size(ofValue: outputFormat))
            if CheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                              0,
                                              nil,
                                              &size,
                                              &outputFormat),
                           "AudioFormatGetProperty failed") != noErr {
                return nil
            }

            fileExtension = "m4a"
            audioFileTypeID = kAudioFileM4AType
            inputFormat.mFormatID = kAudioFormatLinearPCM
            inputFormat.mSampleRate = outputFormat.mSampleRate
            inputFormat.mFormatFlags = kAudioFormatFlagIsPacked |
                kAudioFormatFlagIsSignedInteger |
                kAudioFormatFlagIsBigEndian
            inputFormat.mBitsPerChannel = UInt32(8 * MemoryLayout<Int16>.size)
            inputFormat.mChannelsPerFrame = outputFormat.mChannelsPerFrame
            inputFormat.mBytesPerPacket = inputFormat.mChannelsPerFrame *
                UInt32(MemoryLayout<Int16>.size)
            inputFormat.mBytesPerFrame = inputFormat.mChannelsPerFrame *
                UInt32(MemoryLayout<Int16>.size)
            inputFormat.mFramesPerPacket = 1
        default:
            return nil
        }
        let outputFileURL = filepath.deletingPathExtension()
            .appendingPathExtension(fileExtension) as CFURL
        if CheckError(ExtAudioFileCreateWithURL(outputFileURL,
                                                 audioFileTypeID,
                                                 &outputFormat,
                                                 nil,
                                                 AudioFileFlags.eraseFile.rawValue,
                                                 &outputFile),
                       "ExtAudioFileCreateWithURL failed") != noErr {
            return nil
        }

        if CheckError(ExtAudioFileSetProperty(unwrappedInputFile,
                                               kExtAudioFileProperty_ClientDataFormat,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                               &inputFormat),
                       "ExtAudioFileSetProperty failed") != noErr {
            return nil
        }

        guard let unwrappedOutputFile = outputFile else { return nil }
        if CheckError(ExtAudioFileSetProperty(unwrappedOutputFile,
                                               kExtAudioFileProperty_ClientDataFormat,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                               &inputFormat),
                       "ExtAudioFileSetProperty failed") != noErr {
            return nil
        }

        if let unwrappedInputFile = inputFile,
            let unwrappedOutputFile = outputFile {
            if CheckError(convert(outputFormat: outputFormat,
                                   inputFile: unwrappedInputFile,
                                   outputFile: unwrappedOutputFile),
                           "Convert failed") != noErr {
                return nil
            }
            ExtAudioFileDispose(unwrappedInputFile)
            ExtAudioFileDispose(unwrappedOutputFile)
        } else {
            return nil
        }
        return outputFileURL as URL
    }

    private func convert(outputFormat: AudioStreamBasicDescription,
                         inputFile: ExtAudioFileRef,
                         outputFile: ExtAudioFileRef) -> OSStatus {
        let outputBufferSize = 32 * 1024
        let framesPerBuffer = UInt32(outputBufferSize / MemoryLayout<UInt32>.size)

        let outputBuffer = UnsafeMutablePointer<UInt8>
            .allocate(capacity: MemoryLayout<UInt8>.size * outputBufferSize)

        while true {
            var convertedData = AudioBufferList()
            let convertedDataBuffer = UnsafeMutableAudioBufferListPointer(&convertedData)
            convertedDataBuffer.count = 1
            convertedDataBuffer[0].mNumberChannels = outputFormat.mChannelsPerFrame
            convertedDataBuffer[0].mDataByteSize = UInt32(outputBufferSize)
            convertedDataBuffer[0].mData = UnsafeMutableRawPointer(outputBuffer)

            var frameCount = framesPerBuffer
            var err = CheckError(ExtAudioFileRead(inputFile,
                                            &frameCount,
                                            &convertedData),
                           "ExtAudioFileRead failed")
            if err != noErr {
                return err
            }

            if frameCount == 0 {
                return noErr
            }

            err = CheckError(ExtAudioFileWrite(outputFile,
                                               frameCount,
                                               &convertedData),
                             "ExtAudioFileWrite failed")
            if err != noErr {
                return err
            }
        }
    }
}

public typealias BitRate = UInt32
public typealias SampleRate = Float64

public enum CommonFormats {
    case m4a(SampleRate)
    case aiff(SampleRate, BitRate)
    case mp3(SampleRate, BitRate)
}

public class Track: NSObject {
    public let fileURLString: String
    public let startTime: Double?

    public init(urlString: String, startTime: Double? = nil) {
        self.fileURLString = urlString
        self.startTime = startTime
    }

     public required init?(coder: NSCoder) {
         guard let urlString = coder.decodeObject(forKey: "fileURLString") as? String,
            let startTime = coder.decodeObject(forKey: "startTime") as? Double? else {
                fatalError()
        }
        self.fileURLString = urlString
        self.startTime = startTime
     }
}

extension Track: NSCoding {
    public func encode(with coder: NSCoder) {
        coder.encode(self.fileURLString, forKey: "fileURLString")
        coder.encode(self.startTime, forKey: "startTime")
    }
}
