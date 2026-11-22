#if canImport(UIKit)
import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Where the video shows. The `AVPlayerLayer` itself belongs to the engine and lives as long as
/// the engine does; this view is only a slot that the layer moves into. Layout changes, rotation,
/// folding, panels opening, or going from the feed to the player page therefore swap the slot
/// and never rebuild the layer or the player.
///
/// Several slots can exist at once: the feed's stays in place under the player page. The layer
/// sits in the one with the highest `priority`; a slot never takes it from a higher one, and
/// when a slot goes away the layer moves straight to the best one left, in the same pass, so
/// there is no frame without a picture on the way in or out of the player page.
public struct VideoSurface: UIViewRepresentable {
    public init(engine: PlayerEngine, priority: Int = 0, showsWholeOnLargeScreen: Bool = false) {
        self.engine = engine
        self.priority = priority
        self.showsWholeOnLargeScreen = showsWholeOnLargeScreen
    }

    public let engine: PlayerEngine
    /// 0 for the feed, 1 for the player page on top of it.
    public var priority = 0
    /// On a large screen, show an upright video whole (bars beside it) instead of cropping it to
    /// cover. The player page asks for this; the feed keeps covering.
    public var showsWholeOnLargeScreen = false

    public func makeUIView(context: Context) -> SlotView {
        let slot = SlotView()
        slot.backgroundColor = .black
        slot.tag = priority
        slot.engine = engine
        slot.showsWholeOnLargeScreen = showsWholeOnLargeScreen
        engine.surfaceSlots.add(slot)
        return slot
    }

    public func updateUIView(_ slot: SlotView, context: Context) {
        _ = engine.surfaceEpoch
        slot.tag = priority
        slot.showsWholeOnLargeScreen = showsWholeOnLargeScreen
        slot.claimIfEntitled()
        if engine.layerView.superview === slot {
            engine.layerView.showsWholeOnLargeScreen = showsWholeOnLargeScreen
            engine.attachPrerenderHost(slot.prerenderHost)
        }
        engine.layerView.apply(fit: engine.pictureFit, videoSize: engine.videoSize)
        // A new item makes the layer not ready again; report the next first frame too.
        if !engine.hasFirstFrame, engine.layerView.playerLayer.isReadyForDisplay, engine.phase == .ready { engine.layerBecameReady() }
    }

    public static func dismantleUIView(_ slot: SlotView, coordinator: ()) {
        guard let engine = slot.engine else { return }
        engine.surfaceSlots.remove(slot)
        guard engine.layerView.superview === slot else { return }
        let next = engine.surfaceSlots.allObjects.compactMap { $0 as? SlotView }.filter(\.isUsable).max { $0.tag < $1.tag }
        if let next {
            next.take(engine.layerView)
        } else {
            engine.layerView.removeFromSuperview()
            DispatchQueue.main.async { engine.refreshSurface() }
        }
    }

    /// Gives the layer back to the best slot below the one holding it, at once. The player page
    /// calls this as it starts to leave, so the feed underneath already shows the picture while
    /// the page's controls slide away.
    public static func handBack(engine: PlayerEngine) {
        guard let holder = engine.layerView.superview else { return }
        let below = engine.surfaceSlots.allObjects.compactMap { $0 as? SlotView }
            .filter { $0 !== holder && $0.isUsable && $0.tag < holder.tag }.max { $0.tag < $1.tag }
        guard let below else { return }
        holder.tag = Int.min
        below.take(engine.layerView)
    }
}

/// One place the video can show. It takes the layer only once it is on screen with a real size
/// (in `layoutSubviews`, which runs in the same pass that first draws it), so the picture is
/// never put into a view that has no frame yet, and it keeps the layer exactly its own size.
/// Also hosts a hidden 16x16 offscreen prerender container behind the active layer so standby
/// `AVPlayerLayer`s can decode frame #0 in the active window hierarchy (`isReadyForDisplay`).
public final class SlotView: UIView {
    weak var engine: PlayerEngine?
    public var showsWholeOnLargeScreen = false

    public let prerenderHost: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        return view
    }()

    public var isUsable: Bool { window != nil && bounds.width > 0 && bounds.height > 0 }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if prerenderHost.superview !== self {
            insertSubview(prerenderHost, at: 0)
        }
        claimIfEntitled()
        if let layerView = engine?.layerView, layerView.superview === self, layerView.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layerView.frame = bounds
            CATransaction.commit()
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    /// Takes the layer when nobody usable holds it, or when this slot outranks the holder. Two
    /// slots of the same rank never pull it back and forth; the newer one gets it only when the
    /// older one is gone.
    public func claimIfEntitled() {
        guard isUsable, let engine, engine.layerView.superview !== self else { return }
        if let holder = engine.layerView.superview as? SlotView, holder.isUsable, holder.tag >= tag { return }
        take(engine.layerView)
        engine.attachPrerenderHost(prerenderHost)
    }

    public func take(_ layerView: UIView) {
        if prerenderHost.superview !== self {
            insertSubview(prerenderHost, at: 0)
        }
        guard layerView.superview !== self else { return }
        // Moving a layer between views would otherwise animate its frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerView.autoresizingMask = []
        layerView.frame = bounds
        addSubview(layerView)
        (layerView as? PlayerLayerView)?.showsWholeOnLargeScreen = showsWholeOnLargeScreen
        CATransaction.commit()
        engine?.attachPrerenderHost(prerenderHost)
    }
}

/// The one view that hosts the engine's `AVPlayerLayer`.
public final class PlayerLayerView: UIView {
    public override class var layerClass: AnyClass { AVPlayerLayer.self }
    public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    public var onReady: (() -> Void)?
    private var observation: NSKeyValueObservation?
    /// Set by the slot that holds this view (see `VideoSurface.showsWholeOnLargeScreen`).
    public var showsWholeOnLargeScreen = false { didSet { if showsWholeOnLargeScreen != oldValue { updateGravity() } } }
    private var fit: PlayerEngine.PictureFit = .automatic
    private var videoSize: CGSize = .zero

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        observation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.onReady?() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func apply(fit: PlayerEngine.PictureFit, videoSize: CGSize) {
        self.fit = fit
        self.videoSize = videoSize
        updateGravity()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateGravity()
    }

    /// Whether the picture covers the whole view (cropped) rather than showing whole inside it.
    public static func fills(fit: PlayerEngine.PictureFit, videoSize: CGSize, in bounds: CGSize, largeWindow: Bool, showsWholeOnLargeScreen: Bool) -> Bool {
        switch fit {
        case .fill: return true
        case .fit: return false
        case .automatic:
            guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return false }
            // On a large screen (iPhone Duo's inner display) the player page shows an upright video
            // whole, with bars beside it, rather than cropped to cover.
            return !(largeWindow && showsWholeOnLargeScreen) && (videoSize.height >= videoSize.width) == (bounds.height >= bounds.width)
        }
    }

    /// Where the picture is drawn inside a view of `bounds` size: the whole view when it covers,
    /// otherwise the aspect-fit rectangle. The whole view while the video's size is not known.
    public static func pictureRect(fit: PlayerEngine.PictureFit, videoSize: CGSize, in bounds: CGSize, largeWindow: Bool, showsWholeOnLargeScreen: Bool) -> CGRect {
        let whole = CGRect(origin: .zero, size: bounds)
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0,
              !fills(fit: fit, videoSize: videoSize, in: bounds, largeWindow: largeWindow, showsWholeOnLargeScreen: showsWholeOnLargeScreen)
        else { return whole }
        return AVMakeRect(aspectRatio: videoSize, insideRect: whole)
    }

    /// Automatic: cover the whole view when the video is upright in an upright view (or wide in
    /// a wide one), so a portrait clip fills a portrait screen that is not exactly 9:16.
    /// A wide video in a tall view, or the reverse, is shown whole instead of being cropped hard.
    private func updateGravity() {
        let large = window.map { min($0.bounds.width, $0.bounds.height) >= 600 } ?? false
        let fill = Self.fills(fit: fit, videoSize: videoSize, in: bounds.size, largeWindow: large, showsWholeOnLargeScreen: showsWholeOnLargeScreen)
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if playerLayer.videoGravity != gravity { playerLayer.videoGravity = gravity }
    }
}
#endif
