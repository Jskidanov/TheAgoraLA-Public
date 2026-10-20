import AVFoundation
import Combine

extension Notification.Name {
    static let audioDurationUpdated = Notification.Name("AudioDurationUpdated")
}

final class AudioPlayerManager: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var playbackError: String?
    @Published private(set) var loadedURL: URL?

    private var itemFailureObserver: NSObjectProtocol?
    private var playbackEndedObserver: NSObjectProtocol?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    private var systemPausedWhilePlaying = false
    private var loadGeneration = 0
    private var playbackIsHeld = false

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            // Failed to set audio session; playback may be muted by silent switch
        }
        #endif
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    func load(url: URL) {
        loadGeneration += 1
        let generation = loadGeneration

        // Reset any existing state
        pause()
        removeTimeObserver()

        // Detach and release any existing player item and observer
        if let _ = player?.currentItem {
            player?.replaceCurrentItem(with: nil)
        }
        player = nil
        if let token = itemFailureObserver {
            NotificationCenter.default.removeObserver(token)
            itemFailureObserver = nil
        }
        if let token = playbackEndedObserver {
            NotificationCenter.default.removeObserver(token)
            playbackEndedObserver = nil
        }
        bufferEmptyObserver = nil
        likelyToKeepUpObserver = nil
        statusObserver = nil
        timeControlObserver = nil
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
            interruptionObserver = nil
        }
        wasPlayingBeforeInterruption = false
        playbackIsHeld = false

        // Clear published state so UI resets
        isPlaying = false
        currentTime = 0
        duration = 0
        isBuffering = false
        playbackError = nil
        loadedURL = nil

        // Create and assign a new player for the provided URL (simple, stable path)
        let item = AVPlayerItem(url: url)
        isBuffering = true

        // Observe buffering state
        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            let bufferEmpty = change.newValue ?? false
            guard bufferEmpty else { return }
            DispatchQueue.main.async {
                guard self.loadGeneration == generation else { return }
                self.isBuffering = true
            }
        }
        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.loadGeneration == generation else { return }
                self.isBuffering = true != (change.newValue ?? false)
            }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.loadGeneration == generation else { return }
                if item.status == .readyToPlay {
                    self.isBuffering = false
                    self.playbackError = nil
                    let loadedDuration = item.duration.seconds
                    if loadedDuration.isFinite, loadedDuration > 0 {
                        self.duration = loadedDuration
                        NotificationCenter.default.post(
                            name: .audioDurationUpdated,
                            object: nil,
                            userInfo: ["duration": loadedDuration]
                        )
                    }
                } else if item.status == .failed {
                    self.isBuffering = false
                    self.isPlaying = false
                    self.playbackError = item.error?.localizedDescription ?? "This podcast audio could not be loaded."
                }
            }
        }

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.seek(to: .zero)
        // Keep isPlaying truthful when the system pauses audio (route changes, stalls),
        // so the Play button never needs a second tap to recover.
        timeControlObserver = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, self.player === observedPlayer else { return }
                if observedPlayer.timeControlStatus == .paused, self.isPlaying {
                    self.systemPausedWhilePlaying = true
                    self.isPlaying = false
                }
            }
        }
        player = newPlayer
        loadedURL = url

        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = (self.isPlaying || self.systemPausedWhilePlaying) && !self.playbackIsHeld
                self.pause()
            case .ended:
                if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume),
                       self.wasPlayingBeforeInterruption,
                       !self.playbackIsHeld {
                        self.play()
                    }
                }
                self.wasPlayingBeforeInterruption = false
            @unknown default:
                break
            }
        }
        #endif

        // Optional: observe failures to aid debugging
        itemFailureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            if let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                self?.playbackError = err.localizedDescription
            } else {
                self?.playbackError = "Playback stopped before the episode finished."
            }
            self?.isPlaying = false
            self?.isBuffering = false
        }
        playbackEndedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.systemPausedWhilePlaying = false
            self.isBuffering = false
            if self.duration.isFinite, self.duration > 0 {
                self.currentTime = self.duration
            }
        }

        // Start observing time updates for UI
        observeTime()
    }

    func play() {
        guard !playbackIsHeld else { return }
        if player?.currentItem?.status == .failed, let url = loadedURL {
            // A failed item never plays again; reload it at the same position.
            let resumeAt = currentTime
            load(url: url)
            seek(to: resumeAt)
        }
        guard let player else { return }
        configureAudioSession()
        if duration.isFinite, duration > 0, currentTime >= duration - 0.5 {
            player.seek(to: .zero)
            currentTime = 0
        }
        player.play()
        systemPausedWhilePlaying = false
        isPlaying = true
    }

    func pause() {
        player?.pause()
        systemPausedWhilePlaying = false
        isPlaying = false
    }

    func setPlaybackHeld(_ held: Bool) {
        playbackIsHeld = held
        if held {
            wasPlayingBeforeInterruption = false
            pause()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let nonnegativeSeconds = max(seconds, 0)
        let boundedSeconds = duration.isFinite && duration > 0
            ? min(nonnegativeSeconds, duration)
            : nonnegativeSeconds
        let time = CMTime(seconds: boundedSeconds, preferredTimescale: 600)
        currentTime = boundedSeconds
        player?.seek(to: time)
    }

    private func observeTime() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            currentTime = time.seconds
            if let durationSeconds = self.player?.currentItem?.duration.seconds, durationSeconds.isFinite {
                if duration != durationSeconds {
                    duration = durationSeconds
                    NotificationCenter.default.post(name: .audioDurationUpdated, object: nil, userInfo: ["duration": durationSeconds])
                } else {
                    duration = durationSeconds
                }
            }
        }
    }

    deinit {
        bufferEmptyObserver = nil
        likelyToKeepUpObserver = nil
        statusObserver = nil
        if let token = itemFailureObserver { NotificationCenter.default.removeObserver(token) }
        if let token = playbackEndedObserver { NotificationCenter.default.removeObserver(token) }
        if let token = interruptionObserver { NotificationCenter.default.removeObserver(token) }
        removeTimeObserver()
    }
}
