# FABLE.md — AI Agent Guide for Chassis-iOS

This guide was written by Claude Fable after a full scan of the repository, its open
issues, and its git history. It is intended for AI coding agents (Claude Opus, Codex,
or others) and human contributors continuing work on this repository when Fable is
unavailable. Read this file **before** touching any code.

**The overarching goal: modernize Chassis so it builds cleanly and runs correctly on
iOS 18 and above**, without abandoning its purpose — a small, approachable wrapper
around `AVAudioEngine` for basic multi-track audio apps.

---

## 1. What this repository is

Chassis is a tiny iOS framework (Apache 2.0) wrapping `AVAudioEngine` for multi-track
playback, microphone recording, offline bounce, and file conversion. It was extracted
from a larger app in 2020 and has not been meaningfully updated since (last upgrade
check: Xcode 11.5, deployment target iOS 13.0, Swift 5.0, marketing version 0.4).

### Layout

| Path | Contents |
|---|---|
| `Chassis/AudioEngine.swift` | **~99% of the code.** `EngineConnectable` protocol, `AudioEngine` class, `Track` model, `CommonFormats` enum. |
| `Chassis/CheckError.h` | C helper that prints Core Audio `OSStatus` errors as 4-char codes (from the *Learning Core Audio* book). Exposed via the umbrella header. |
| `Chassis/Chassis.h` | Umbrella header importing `CheckError.h`. |
| `ChassisTests/ChassisTests.swift` | Xcode template stub only — **there are no real tests.** |
| `Chassis.xcodeproj` | Framework project. No SPM manifest, no CocoaPods, no CI, no SwiftLint config (despite CONTRIBUTING.md asking for SwiftLint). |

### Core design (understand this before editing)

- `AudioEngine` owns one `AVAudioEngine`. Each audio file plays through its own
  `AVAudioPlayerNode` connected to `mainMixerNode`.
- There are **two parallel code paths everywhere**: a "legacy" path (`legacyNodes`,
  `legacyFiles` — tracks without a token) and a "tokenized" path (`nodes: [NodeUse]`,
  `tokenizedFiles: [UUID: FileInfo]` — tracks identified by UUID, with node reuse via
  the `inUse` flag, added in PR #12/#15). The legacy path is effectively dead — see
  the `Track.init` bug below — but its code still dominates the file.
- Files are resolved by *filename inside the app's Documents directory*
  (`Track.fileURLString` is a last-path-component, not a full URL).
- Playback progress is published via Combine (`progressObserver`), driven by a
  `CADisplayLink` polling `playerTime(forNodeTime:)`.
- Recording taps `engine.inputNode` through an `AVAudioSinkNode` writing a `.caf`
  via `ExtAudioFile` C APIs. Conversion (`convertFile`) is a straight port of C-style
  `ExtAudioFile` conversion code.

---

## 2. Modernization roadmap (the actual task list)

Work through these in order. Each item should be its own branch/PR. Numbers in
parentheses reference open GitHub issues — read the issue before starting.

### Phase 1 — Structural

1. **Convert to a Swift Package (issue #10).** Add `Package.swift` (swift-tools 5.9+),
   move sources to `Sources/Chassis/`, tests to `Tests/ChassisTests/`. `CheckError.h`
   is a C header: either give it its own C target that the Swift target depends on, or
   (better) reimplement the ~20 lines of `CheckError` in Swift and delete the header,
   the umbrella header dance, and the Objective-C interop entirely. Keep the
   `.xcodeproj` working until the package is proven, then remove it in a follow-up.
2. **Raise the deployment target to iOS 15 or 16 minimum** (the README's iOS 13
   floor existed only for Combine; nothing else requires it) and set
   `SWIFT_VERSION` to 5.10+. Compile with `-strict-concurrency=complete` to surface
   the concurrency work in Phase 2. Full Swift 6 language mode is the end state, but
   don't flip it on until Phase 2 is done.
3. **Add CI** (GitHub Actions, `macos-15`/Xcode 16+): build + test on an iOS 18
   simulator, plus SwiftLint. Without CI, nothing else on this list is verifiable.

### Phase 2 — Correctness on modern iOS (this is the "works on iOS 18" core)

4. **Fix concurrency.** The current threading is the single biggest source of
   latent breakage on modern iOS:
   - `stop()` does `DispatchQueue.global(qos:).sync { ... }` and, inside it, touches
     state also mutated from other queues; `play()`/`pause()` hop to global queues;
     `setUpEngine()` mutates `audioFormat`/`recordNode` on a background queue with
     no synchronization against `init` returning. Nothing is actually thread-safe.
   - `@Published private var progress` is mutated from the display link and from
     background queues; SwiftUI/Combine subscribers will assert off-main-thread
     updates.
   - Recommended shape: make `AudioEngine` `@MainActor` (its API is UI-facing;
     `AVAudioEngine` calls are cheap enough), keep the render-thread-adjacent parts
     (the `AVAudioSinkNode` tap block) free of locks and allocation, and expose
     progress as both the existing Combine publisher and an `AsyncStream<Double>`.
     Adopt `Sendable` where required. Do **not** sprinkle `nonisolated(unsafe)` to
     silence the compiler.
5. **Replace `fatalError` with thrown errors.** `play()` crashes the host app if
   `engine.start()` throws (which legitimately happens on session interruption,
   route change, or missing mic permission). Define a small `ChassisError: Error`
   enum; make `addTrackToMix`, `loadAllTracksAndAddToMix`, `play`,
   `startRecording`, `bounceScene`, `convertFile` throwing. This is a breaking API
   change — bump the major version and note it in the README.
6. **Modernize the audio session lifecycle.**
   - The session category is set but `setActive(true)` is never called, and errors
     are swallowed with `try?`.
   - No handling of `AVAudioSession.interruptionNotification`,
     `routeChangeNotification`, or `AVAudioEngineConfigurationChange` — on iOS 18 a
     phone call or AirPods disconnect leaves the engine silently dead.
   - Microphone permission is never requested. Use `AVAudioApplication
     .requestRecordPermission` (iOS 17+ replacement for the deprecated
     `AVAudioSession.requestRecordPermission`) before `startRecording()`, and
     document that host apps need `NSMicrophoneUsageDescription`.
7. **Fix the known bugs** (section 3 below). Several are one-liners; fix them with
   tests attached.

### Phase 3 — Features and tests

8. **Unit tests (issue #6).** The current test file is an empty template. Priorities:
   `getMixLength` math, `Track` round-tripping, add/remove/reuse of nodes
   (`inUse` bookkeeping), and offline `bounceScene` output length. Prefer the
   Swift Testing framework (`import Testing`, Xcode 16+) for new tests. Audio-session
   tests can't run on Linux or without an audio host — design the engine so the
   math (mix length, start-time offsets) is testable without starting `AVAudioEngine`.
9. **`getMixLength` correctness (issue #5).** It currently returns the longest file
   duration, ignoring `startTime` offsets. Note the circularity you must untangle:
   `startTime` is interpreted as a *fraction* multiplied by `getMixLength()` itself
   (see `addTrackToMix`), so track placement depends on mix length and vice versa.
   Decide on an absolute-seconds semantics for `startTime`, document it, and migrate.
10. **Implement `scrub(to:)` and `skipForward()` (issue #3).** They are empty stubs
    today (`skipBackward` only restarts from zero). Implementation sketch: stop nodes,
    then `scheduleSegment(_:startingFrame:frameCount:at:)` from the frame
    corresponding to the target time, tracking `skipFrame`/`currentPosition` (fields
    already exist, unused). This makes the progress calculation offset-aware too.

### Phase 4 — API polish (breaking, batch together)

- `EngineConnectable: class` → `: AnyObject` (the `class` spelling is an error in
  Swift 6). Consider whether the protocol should exist at all — it has one conformer;
  its only plausible purpose is test mocking for host apps.
- `Track`: drop `NSObject`/`NSCoding` in favor of `Codable` + `Sendable` struct.
- Remove the legacy (non-token) path entirely once `Track.init` is fixed — it is
  unreachable for any `Track` created through the public initializer (see bug list).
- `CommonFormats.mp3` should be deleted: Core Audio **cannot encode MP3**; the case
  silently falls through to `return nil` today.
- `CADisplayLink` is UIKit-only and a per-frame poll; consider
  `AVAudioPlayerNode`-time computed on demand plus a timer, or keep the display link
  but fix its retain cycle (see bugs) and add it on the main run loop explicitly.

---

## 3. Known bugs and gotchas (verified against the source — do not rediscover these)

1. **`Track.init` ignores its `token` parameter and always assigns `UUID()`**
   (`AudioEngine.swift`, `Track.init(urlString:startTime:token:)` — the parameter is
   even typed `Int?` while the property is `UUID?`). Consequence: every track created
   through the public initializer is tokenized, so all the `else` branches for
   legacy tracks in `removeTrackFromMix`, `changeVolume`, `changePan`, `getVolume`,
   `getPan` are dead code — only `init?(coder:)` can produce a nil token.
2. **`filter { ... }.enumerated()` index bug** in `removeTrackFromMix`,
   `changeVolume`, `changePan`, `getVolume`, `getPan` (legacy paths): `enumerated()`
   yields offsets into the *filtered* array, which are then used to index
   `legacyNodes` — the wrong node gets removed/adjusted whenever the match isn't at
   the front. Also `$0.url == file.url && $1 == audioTime` compares `AVAudioTime`
   references, not times. If you delete the legacy path (Phase 4), these die with it.
3. **`CADisplayLink` retain cycle**: the display link retains `self` as its target
   and `AudioEngine` retains the link; `invalidate()` is never called, so no
   `AudioEngine` ever deallocates.
4. **Division by zero / NaN in `updateUI`** when `getMixLength()` is 0 (no tracks
   loaded) — `progress` becomes NaN and the `progress >= 1` auto-stop never fires.
5. **`stop()` uses `.sync` on a global queue** — deadlock-prone if ever reached from
   a queue in the same pool, and `updateUI` calls `stop()` from the display link
   (main thread) while `play()`'s async block may be mid-flight on another queue.
6. **`getPan` returns 0.5 as its tokenized fallback** — `AVAudioPlayerNode.pan`
   ranges -1…1 with 0 = center (PR #12's stated default is 0). The fallback should
   be 0.
7. **`startRecording` leaks the `ExtAudioFileRef`**: `ExtAudioFileDispose` is never
   called in `stopRecording`, so the `.caf` header may never be finalized and the
   file handle leaks. The sink-node closure captures `fileToSave` forever.
8. **`bounceScene` calls `play()` which hops to a background queue** while manual
   rendering proceeds synchronously on the caller's thread — the render loop can
   start before the nodes have been told to play. Under manual rendering you should
   start the engine and nodes synchronously.
9. **`setPreferredSampleRate(44100)` + hardcoded assumptions**: modern iPhone
   hardware runs at 48 kHz; the preference is a request, not a guarantee. Never
   hardcode a sample rate in new code — always read it from the format/output node.
10. **Doc comments lie in places** (copy-paste artifacts): e.g. `startRecording`'s
    summary says "Loads array of tracks…", `convertFile` says the same. Do not trust
    a doc comment over the code body anywhere in this file.

---

## 4. Build and verification

- **This is an iOS-only Xcode project — it cannot be built or tested on Linux.**
  If you are an agent running in a Linux container (as Fable was), you can still
  edit with confidence but must say clearly in the PR that changes are not
  compiler-verified. Syntax-sanity aids: `swiftc -parse` of a standalone Swift file
  works only after removing UIKit/AVFoundation imports, so it is rarely worth it;
  prefer careful reading plus CI (Phase 1, item 3) as the real gate.
- On macOS:
  ```sh
  xcodebuild -project Chassis.xcodeproj -scheme Chassis \
    -destination 'generic/platform=iOS' build
  xcodebuild -project Chassis.xcodeproj -scheme Chassis \
    -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  After SPM conversion: `swift build` still won't work on macOS for an
  iOS-only AVFoundation surface without `-sdk`/destination flags — use
  `xcodebuild -scheme Chassis-Package -destination 'platform=iOS Simulator,...' test`.
- **Style**: CONTRIBUTING.md mandates SwiftLint (default rules) and the
  Ray Wenderlich (now Kodeco) Swift style guide. The source already carries
  `swiftlint:disable` markers for `file_length`, `type_body_length`,
  `function_body_length`, `cyclomatic_complexity` — treat these as debt to reduce,
  not a license to grow the file.

---

## 5. Prompting and working tips for Opus, Codex, and other agents

These are tuned to *this* repository's failure modes:

1. **Read `Chassis/AudioEngine.swift` end-to-end before any edit.** It is under
   1,000 lines and contains the entire framework. Most wrong changes here come from
   pattern-matching on one method while an almost-identical twin method (legacy vs.
   tokenized path) goes unfixed or diverges further.
2. **Don't trust doc comments or the README's API examples over the code.** Several
   doc comments are copy-paste artifacts (section 3.10), and the README omits the
   token behavior entirely.
3. **One issue, one branch, one PR.** The maintainer's history (PRs #11, #12, #15)
   shows small, focused PRs with the issue number in the description ("Closes #N").
   Match that. Do not bundle the SPM conversion with behavior changes.
4. **Preserve public API unless the task is explicitly a breaking change** — and
   when you do break it, bump `MARKETING_VERSION` (the maintainer bumps it in the
   PR that changes behavior) and update the README's code samples in the same PR.
5. **Never invent Core Audio / AVFoundation API.** Everything in `convertFile` and
   `startRecording` is C-interop with exact-width types and inout pointers; a
   hallucinated parameter compiles as a type error at best and corrupts audio at
   worst. When touching these, check the real signatures in Apple's docs, and check
   `@available` annotations against the deployment target you're building for.
6. **Beware the audio render thread.** Code inside the `AVAudioSinkNode` closure
   runs on a real-time thread: no allocation, no locks, no Swift runtime surprises
   (avoid bridging, `print`, Combine). Keep it to the existing
   `ExtAudioFileWrite` call or a lock-free ring buffer.
7. **When fixing concurrency, fix the model, not the warning.** The goal is a
   coherent isolation story (`@MainActor` engine + real-time-safe tap), not the
   minimum set of `@unchecked Sendable` / `nonisolated(unsafe)` annotations that
   silences Swift 6.
8. **Attach a test to every bug fix** (once the test target is real). The absence of
   tests is issue #6; every PR should shrink that gap, not preserve it.
9. **State your verification level honestly in the PR body**: "built and tested on
   iOS 18 simulator" vs. "edited on Linux, not compiler-verified". The maintainer is
   responsive and can run what you cannot.
10. **If a change touches file formats or the Documents-directory convention**
    (`Track.fileURLString` is a filename, not a URL), call it out loudly — host apps
    depend on it for persistence, and `Track` objects are archived via NSCoding in
    the wild.

---

## 6. Quick reference

- **Maintainer**: Roberto Osorio Goenaga (@diatrevolo) — welcomes issues and direct
  contact per the README.
- **License**: Apache 2.0 (header required on new source files — copy the block from
  `AudioEngine.swift`).
- **Open issues at time of writing**: #3 (scrub), #5 (getMixLength), #6 (tests),
  #10 (Swift Package).
- **Current versions**: marketing 0.4, Swift 5.0, iOS 13.0 target, Xcode project
  format 11.x — all of which Phase 1 exists to change.
