# Chassis-iOS
A wrapper for AVAudioEngine to help create basic and prosumer multi-track audio applications on iOS.

Chassis is written to abstract away some of the gritty parts of CoreAudio present in multi-track AVAudioEngine usage.

AVAudioEngine works on the basis of AVAudioNodes connected to a mixer node, and then to an output node, much like a recording studio would connect sources to destinations.
![AVAudioEngine network](images/AVAudioEngine_nodes.png)

Chassis abstracts this away by using a `Track` model and a simple `loadAllTracksAndAddToMix` method to add an array of audio files to a node, then to the mixer, and the output.
![Chassis network](images/Chassis_nodes.png)

This saves the end user the trouble of managing audio files, urls, and nodes separately.

Similarly, AVAudioEngine's `AVAudioSinkNode` provides a way to record input into a file that utilizes Core Audio's ring buffer pattern to populate a new file with the incoming data.
![AVAudioEngine Recording](images/AVAudioEngine_recording.png)

Chassis attempts to abstract this away as well by providing a single `startRecording` and `stopRecording` function pair to connect the sink node and populate a file.
![Chassis Recording](images/Chassis_recording.png)

To create an instance of Chassis' engine, simply instantiate AudioEngine.
```swift
import Chassis

...
private var engine: AudioEngine = AudioEngine()
...
```

To add a file to a mix, create a `Track` object, and call `loadAllTracksAndAddToMix`.

```swift
import Chassis

...
let newTrack = Track(urlString: Bundle.main.url(forResource: "M1F1-int16s-AFsp",
                                                withExtension: "aif")!.lastPathComponent,
                     startTime: nil)
engine.loadAllTracksAndAddToMix(tracks: [newTrack])
...
```

Chassis is not meant to be a pro-audio framework, as it abstracts away certain sample-locked parts from the user.
Having said that, its main purpose is to facilitate the entry-point to multi-track audio for consumer applications on iOS.

Chassis relies on Combine, so I have decided to make it iOS 13 +. 

I have begun updating Issues with a list of issues I'd like to address...collaborators are welcome! There will be many more issues to come; Chassis was ripped out of an ongoing project and packaged up, so a lot of the missing features just haven't been necessary up to now.

I will also be continuing to update this readme with notes about how Chassis is written, and some of its shortcomings.

If something is a mystery, or missing, or confusing, please feel free to write me directly at rawbirdtoe --(at)-- g mail dot com. This is a labor of love to try to make multi-track audio more accessible, but I am fully aware that in its current state it only serves a very narrow set of requirements. I promise not to give up or abandon it, so please add any issues or feature requests!
