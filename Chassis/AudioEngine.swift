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

    func addFileToMix(_ file: AVAudioFile,
                      at time: AVAudioTime?,
                      isLegacyTrack: Bool,
                      token: UUID?)
    func addTrackToMix(_ track: Track)
    func removeNodeFromMix(_ node: AVAudioPlayerNode)
    func removeTrackFromMix(_ track: Track)
    func play()
    func pause()
    func stop()
    func scrub(to interval: TimeInterval)
    func skipForward()
    func skipBackward()
    func loadAllTracksAndAddToMix(tracks: [Track])
    func unloadNode(_ node: AVAudioPlayerNode)
    func unloadAllTracks()
    func getMixLength() -> TimeInterval
    func getFileLength(for filename: String?) -> Double
    func getTrackLength(for track: Track) -> Double
    func startRecording() -> String?
    func stopRecording()
    func bounceScene(filename: String) -> URL?
    func convertFile(filepath: URL,
                     to format: CommonFormats) -> URL?
    func changeVolume(to value: Float, track: Track)
    func changePan(to value: Float, track: Track)
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
    private var legacyNodes = [AVAudioPlayerNode]()
    private var nodes = [NodeUse]()
    private var tokenizedFiles: [UUID : FileInfo] = [:]
    private var durationTable: [String: Double] = [:]
    private var legacyFiles: [(AVAudioFile, AVAudioTime?)] = []
    private var audioFormat: AVAudioFormat?
    private var recordNode: AVAudioInputNode?
    private var isRecording: Bool = false
    private var sinkNode: AVAudioSinkNode?
    
    private struct FileInfo {
        let file: AVAudioFile
        let node: AVAudioPlayerNode?
        let startTime: AVAudioTime?
    }
    
    private class NodeUse {
        var node: AVAudioPlayerNode
        var inUse: Bool
        
        init(node: AVAudioPlayerNode, inUse: Bool = true) {
            self.node = node
            self.inUse = inUse
        }
    }

    /**
    Allocates and initalizes the audio engine
    */
    public init() {
        setUpEngine()
        setUpDisplayLink()
    }

    /**
    Sets up AVAudioEngine
    */
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
        updater = CADisplayLink(target: self,
                                selector: #selector(updateUI))
        updater?.add(to: .current,
                     forMode: RunLoop.Mode.default)
        updater?.isPaused = true
    }

    @objc private func updateUI() {
        guard let audioFormat = audioFormat else { return }
        progress = (Double(getCurrentPosition()) /
            audioFormat.sampleRate) /
            Double(getMixLength())
        if progress >= 1 && !isRecording {
            stop()
        }
    }
    
    /**
    Gets current mix playhead position

    - Returns: the AVAudioFramePosition of the playhead.

    - This method gets the current playhead position.
    */
    public func getCurrentPosition() -> AVAudioFramePosition {
        if let nodeUse = nodes.first(where: {
            $0.inUse == true
        }),
            let nodeTime = nodeUse.node.lastRenderTime,
            let playerTime = nodeUse.node.playerTime(forNodeTime: nodeTime) {
            return playerTime.sampleTime
        }
        else if let player = legacyNodes.first,
            let nodeTime = player.lastRenderTime,
            let playerTime = player.playerTime(forNodeTime: nodeTime) {
            return playerTime.sampleTime
        }
        return 0
    }

    /**
    Loads an AVAudioFile into AVAudioEngine.

    - Parameter file: an AVAudioFile
     
    - Parameter time: an AVAudioTime interval, or nil for time zero
     
     - Parameter isLegacyTrack: Bool used if attached file is for legacy version
     
     - Parameter token: if file is not legacy, the file's associated track's token UUID

    - Returns: nothing
     
    - This method loads an AVAudioFile into the mix at the specified mix time.
    */
    public func addFileToMix(_ file: AVAudioFile, at time: AVAudioTime? = nil, isLegacyTrack: Bool = false, token: UUID? = nil) {
        if isLegacyTrack {
            let node = AVAudioPlayerNode()
            legacyNodes.append(node)
            engine.attach(node)
            engine.connect(node,
                           to: engine.mainMixerNode,
                           format: audioFormat)
            node.scheduleFile(file,
                              at: time)
        } else {
            guard let token = token else { fatalError() }
            for nodeUse in nodes {
                if nodeUse.inUse == false {
                    nodeUse.inUse = true
                    tokenizedFiles[token] = FileInfo(file: file,
                                                     node: nodeUse.node,
                                                     startTime: time)
                    nodeUse.node.scheduleFile(file,
                                              at: time)
                    return
                }
            }
            let node = AVAudioPlayerNode()
            tokenizedFiles[token] = FileInfo(file: file,
                                             node: node,
                                             startTime: time)
            nodes.append(NodeUse(node: node))
            engine.attach(node)
            engine.connect(node,
                           to: engine.mainMixerNode,
                           format: audioFormat)
            node.scheduleFile(file, at: time)
        }
    }
    
    private func reloadLegacyFiles() {
        legacyFiles.forEach {
            addFileToMix($0.0,
                         at: $0.1,
                         isLegacyTrack: true)
        }
    }
    
    private func reloadFiles() {
        tokenizedFiles.forEach {
            addFileToMix($1.file,
                         at: $1.startTime,
                         isLegacyTrack: false, token: $0)
        }
    }
    
    /**
    Loads a Track into AVAudioEngine.

    - Parameter track: a Track
     
    - Returns: nothing
     
    - This method loads an AVAudioFile into the mix at the specified mix time.
    */
    public func addTrackToMix(_ track: Track) {
        guard let audioFile = try? self.loadTrack(track) else { fatalError("Could not add file to mix.") }
        durationTable[track.fileURLString] = Double(audioFile.length) /
            audioFile.processingFormat.sampleRate
        var audioTime: AVAudioTime?
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if let startTime = track.startTime {
            audioTime = AVAudioTime(sampleTime: Int64(getMixLength() *
                startTime * sampleRate),
                                    atRate: sampleRate)
        } else {
            audioTime = nil
        }
        if let token = track.token {
            // Add tokenized track here
            addFileToMix(audioFile,
                         at: audioTime,
                         token: token)
        } else {
            legacyFiles.append((audioFile, audioTime))
            addFileToMix(audioFile,
                         at: audioTime,
                         isLegacyTrack: true)
        }
    }

    /**
    Removes an AVAudioNode.

    - Parameter node: an AVAudioPlayerNode
     
    - Returns: nothing
     
    - This method removes a node from the mix.
    */
    public func removeNodeFromMix(_ node: AVAudioPlayerNode) {
        DispatchQueue.global(qos: .background).async {
            self.engine.disconnectNodeOutput(node)
        }
    }

    /**
    Removes a Track.

    - Parameter track: a Track
     
    - Returns: nothing
     
    - This method removes a track from the mix. If two tracks are identical, it will remove them both.
    */
    public func removeTrackFromMix(_ track: Track) {
        if let token = track.token {
            // remove track via token
            let fileInfo = tokenizedFiles[token]
            if let node = fileInfo?.node {
                let nodeRef = nodes.first {
                    $0.node == node
                }
                if let nodeRef = nodeRef {
                    nodeRef.inUse = false
                    nodeRef.node.stop()
                    nodeRef.node.reset()
                }
            }
            tokenizedFiles[token] = nil
            tokenizedFiles.removeValue(forKey: token)
        } else {
            guard let file = try? loadTrack(track) else { fatalError("Track is not valid.") }
            let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let audioTime = AVAudioTime(sampleTime: Int64(getMixLength() *
                                                      (track.startTime ?? 0) * sampleRate),
                                    atRate: sampleRate)
        
            let matchingTracks = legacyFiles.filter {
                $0.url == file.url && $1 == audioTime
            }.enumerated()
            
            for trackToRemove in matchingTracks {
                let nodeToRemove = legacyNodes.remove(at: trackToRemove.offset)
                self.engine.disconnectNodeOutput(nodeToRemove)
            }
        }
    }

    /**
    Plays the mix.
    - This method plays the current mix. It is relative to the last time played, unless stop has been called.
    */
    public func play() {
        guard (!self.legacyNodes.isEmpty || !self.tokenizedFiles.isEmpty) else { return }
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
                self.legacyNodes.forEach {
                    $0.play(at: nil)
                }
                self.nodes.forEach {
                    if $0.inUse {
                        $0.node.play(at: nil)
                    }
                }
            } else {
                self.pause()
            }
        }
    }

    /**
    Pauses the mix
    - This method pauses the mix and preserves the current mix time.
    */
    public func pause() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let updater = self.updater else { return }
            self.isPlaying = false
            updater.isPaused = true
            self.legacyNodes.forEach {
                $0.pause()
            }
            self.nodes.forEach {
                if $0.inUse {
                    $0.node.pause()
                }
            }
        }
    }

    /**
    Stops the mix
    - This method stops the mix and resets mix time to zero.
    */
    public func stop() {
        DispatchQueue.global(qos: .userInitiated).sync {
            guard let updater = self.updater else { return }
            isPlaying = false
            updater.isPaused = true
            DispatchQueue.main.async {
                self.progress = 0.0
            }
            legacyNodes.forEach {
                $0.stop()
            }
            nodes.forEach {
                if $0.inUse {
                    $0.node.stop()
                }
            }
            engine.stop()
            engine.reset()
            unloadAllTracks()
            reloadLegacyFiles()
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
        if let token = track.token {
            // retrieve AVAudioFile via token
            if let file = tokenizedFiles[token]?.file {
                return file
            }
            guard let userDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                                          .userDomainMask, true)
            .first else { return nil }
            let documentSearchPathUrl = URL(fileURLWithPath: userDirectory)
            let filePath = documentSearchPathUrl.appendingPathComponent(track.fileURLString)
            let file = try AVAudioFile(forReading: filePath)
            var audioTime: AVAudioTime?
            let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if let startTime = track.startTime {
                audioTime = AVAudioTime(sampleTime: Int64(getMixLength() *
                    startTime * sampleRate),
                                        atRate: sampleRate)
            } else {
                audioTime = nil
            }
            tokenizedFiles[token] = FileInfo(file: file,
                                             node: nil,
                                             startTime: audioTime)
            return file
        } else {
            guard let userDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                                          .userDomainMask, true)
            .first else { return nil }
            let documentSearchPathUrl = URL(fileURLWithPath: userDirectory)
            let filePath = documentSearchPathUrl.appendingPathComponent(track.fileURLString)
            return try AVAudioFile(forReading: filePath)
        }
    }

    /**
    Loads array of tracks into AVAudioEngine.

    - Parameter tracks: a Track array

    - Returns: nothing
     
    - This method loads an array of tracks into memory and calculates time offset.
    */
    public func loadAllTracksAndAddToMix(tracks: [Track]) {
        DispatchQueue.global(qos: .default).sync {
            legacyFiles = [(AVAudioFile, AVAudioTime?)]()
            tracks.forEach {
                if let track = try? self.loadTrack($0) {
                    durationTable[$0.fileURLString] = Double(track.length) /
                        track.processingFormat.sampleRate
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
                    if let token = $0.token {
                        addFileToMix(track,
                                     at: audioTime,
                                     token: token)
                    } else {
                        legacyFiles.append((track, audioTime))
                        addFileToMix(track,
                                     at: audioTime,
                                     isLegacyTrack: true)
                    }
                }
            }
        }
    }

    /**
    Unloads a node.

    - Parameter node: the AVAudioPlayerNode in question.

    - This method unloads a track from the mix.
    */
    public func unloadNode(_ node: AVAudioPlayerNode) {
        DispatchQueue.global(qos: .utility).sync {
            engine.detach(node)
            legacyNodes.removeAll {
                $0 == node
            }
        }
    }

    /**
    Unloads all tracks.
    - This method unloads all tracks from the mix.
    */
    public func unloadAllTracks() {
        legacyNodes.forEach {
            unloadNode($0)
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

    /**
    Returns the length of a file

    - Parameter filename: filename of the track.

    - Returns: Double
     
    - This method returns the length of a file.
    */
    public func getFileLength(for filename: String?) -> Double {
        guard let filename = filename else { return 0 }
        return durationTable[filename] ?? 0
    }

    /**
    Returns the length of a track

    - Parameter track: Track.

    - Returns: Double
     
    - This method returns the length of a track.
    */
    public func getTrackLength(for track: Track) -> Double {
        return durationTable[track.fileURLString] ?? 0
    }

    /**
    Loads array of tracks into AVAudioEngine.

    - Returns: Filename if recording track in documents directory
     
    - This method starts recording.
    */
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

    /**
    Stops recording
    - This method stops recording.
    */
    public func stopRecording() {
        guard let sinkNode = sinkNode else { return }
        engine.stop()
        isRecording = false
        engine.detach(sinkNode)
        self.sinkNode = nil
        engine.reset()
    }

    /**
    Bounces current mix

    - Parameter filename: filename to bounce to in documents directory

    - Returns: URL of mix
     
    - This method loads an array of tracks into memory and calculates time offset.
    */
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

    /**
    Converts file to AIFF or AAC

    - Parameter filepath: a Track URL
     
    - Parameter format: a CommonFormat (see below)

    - Returns: URL to converted file
     
    - This method loads an array of tracks into memory and calculates time offset.
    */
    // swiftlint:disable function_body_length
    // swiftlint:disable cyclomatic_complexity
    public func convertFile(filepath: URL,
                            to format: CommonFormats) -> URL? {
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

            var infoSize: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            
            if CheckError(ExtAudioFileGetProperty(unwrappedInputFile,
                                                  kExtAudioFileProperty_FileDataFormat,
                                                  &infoSize,
                                                  &inputFormat),
                          "ExtAudioFileGetProperty failed") != noErr {
                return nil
            }
            
            fileExtension = "m4a"
            audioFileTypeID = kAudioFileM4AType
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

        guard let unwrappedOutputFile = outputFile else { return nil }
        
        if CheckError(ExtAudioFileSetProperty(unwrappedOutputFile,
                                               kExtAudioFileProperty_ClientDataFormat,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                               &inputFormat),
                       "ExtAudioFileSetProperty failed on output file") != noErr {
            return nil
        }
        
        if CheckError(convert(outputFormat: outputFormat,
                               inputFile: unwrappedInputFile,
                               outputFile: unwrappedOutputFile),
                       "Convert failed") != noErr {
            return nil
        }
        ExtAudioFileDispose(unwrappedInputFile)
        ExtAudioFileDispose(unwrappedOutputFile)
        
        return outputFileURL as URL
    }

    private func convert(outputFormat: AudioStreamBasicDescription,
                         inputFile: ExtAudioFileRef,
                         outputFile: ExtAudioFileRef) -> OSStatus {
        print("Converting to \(outputFormat.mSampleRate)Hz, \(outputFormat.mBitsPerChannel) bits")
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
    
    public func changeVolume(to value: Float, track: Track) {
        if let token = track.token {
            let selectedNode = tokenizedFiles[token]?.node
            selectedNode?.volume = value
        } else {
            guard let file = try? loadTrack(track) else { fatalError("Track is not valid.") }
            let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let audioTime = AVAudioTime(sampleTime: Int64(getMixLength() *
                                                      (track.startTime ?? 0) * sampleRate),
                                    atRate: sampleRate)
        
            let matchingTracks = legacyFiles.filter {
                $0.url == file.url && $1 == audioTime
            }.enumerated()
            
            for trackCandidate in matchingTracks {
                let selectedNode = legacyNodes[trackCandidate.offset]
                selectedNode.volume = value
            }
        }
    }
    
    public func changePan(to value: Float, track: Track) {
        if let token = track.token {
            let selectedNode = tokenizedFiles[token]?.node
            selectedNode?.pan = value
        } else {
            guard let file = try? loadTrack(track) else { fatalError("Track is not valid.") }
            let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let audioTime = AVAudioTime(sampleTime: Int64(getMixLength() *
                                                      (track.startTime ?? 0) * sampleRate),
                                    atRate: sampleRate)
        
            let matchingTracks = legacyFiles.filter {
                $0.url == file.url && $1 == audioTime
            }.enumerated()
            
            for trackCandidate in matchingTracks {
                let selectedNode = legacyNodes[trackCandidate.offset]
                selectedNode.pan = value
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
    public let token: UUID?

    public init(urlString: String, startTime: Double? = nil, token: Int? = nil) {
        self.fileURLString = urlString
        self.startTime = startTime
        self.token = UUID()
    }

     public required init?(coder: NSCoder) {
         guard let urlString = coder.decodeObject(forKey: "fileURLString") as? String,
            let startTime = coder.decodeObject(forKey: "startTime") as? Double? else {
                fatalError()
        }
        if let token = coder.decodeObject(forKey: "token") as? UUID {
            self.token = token
        } else {
            self.token = nil
        }
        self.fileURLString = urlString
        self.startTime = startTime
     }
}

extension Track: NSCoding {
    public func encode(with coder: NSCoder) {
        coder.encode(self.fileURLString, forKey: "fileURLString")
        coder.encode(self.startTime, forKey: "startTime")
        coder.encode(self.token, forKey: "token")
    }
}
