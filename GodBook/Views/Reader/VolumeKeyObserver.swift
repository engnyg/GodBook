import AVFoundation
import MediaPlayer
import UIKit

/// 用音量鍵翻頁：監聽系統音量變化，並把音量重設回基準值（不讓音量真的變動）。
final class VolumeKeyObserver: NSObject {
    private let session = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    private var originalVolume: Float = 0.5
    private let baseline: Float = 0.5
    private var ignoring = false
    private(set) var isRunning = false

    /// `true` 表示按了音量加
    var onPress: ((Bool) -> Void)?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        originalVolume = session.outputVolume

        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        window?.addSubview(volumeView)
        setVolume(baseline)

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, !self.ignoring, let value = change.newValue else { return }
            if abs(value - self.baseline) < 0.001 { return }
            let up = value > self.baseline
            DispatchQueue.main.async {
                self.onPress?(up)
                self.setVolume(self.baseline)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observation?.invalidate()
        observation = nil
        setVolume(originalVolume)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [volumeView] in volumeView.removeFromSuperview() }
    }

    private func setVolume(_ value: Float) {
        ignoring = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            (self.volumeView.subviews.compactMap { $0 as? UISlider }.first)?.value = value
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.ignoring = false }
        }
    }
}
