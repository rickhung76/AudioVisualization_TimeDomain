//
//  WaveformView.swift
//  WaveformView
//
//  Created by 黃柏叡 on 2017/8/7.
//  Copyright © 2017年 黃柏叡. All rights reserved.
//

import UIKit
import MediaPlayer
import AVFoundation
import Accelerate

open class WaveformView: UIView {
    /// A delegate to accept progress reporting
    open weak var delegate: WaveformViewDelegate?
    
    /// The audio file to render
    open var audioURL: URL? {
        didSet {
            guard let audioURL = audioURL else {
                NSLog("WaveformView received nil audioURL")
                audioContext = nil
                return
            }
            
            loadingInProgress = true
            delegate?.waveformViewWillLoad?(self)
            
            FDAudioContext.load(fromAudioURL: audioURL) { audioContext in
                DispatchQueue.main.async {
                    guard self.audioURL == audioContext?.audioURL else { return }
                    
                    if audioContext == nil {
                        NSLog("WaveformView failed to load URL: \(audioURL)")
                    }
                    
                    self.audioContext = audioContext // This will reset the view and kick off a layout
                    
                    self.loadingInProgress = false
                    self.delegate?.waveformViewDidLoad?(self)
                }
            }
        }
    }
    
    // Set bar width, defalt is 10
    open var barWidth: CGFloat = 10.0
    
    // Set bar interval width, defalt is 10
    open var barIntervalWidth: CGFloat = 20.0
    
    
    public func playAudio() {
        if self.loadingInProgress {
            return
        }
        self.audioContext?.player.play()
    }
    
    public func stopAudio() {
        self.audioContext?.player.pause()
        self.audioContext?.player.seek(to: kCMTimeZero)
    }
    
    public func playerItem() -> AVPlayerItem? {
        if self.audioContext?.player.currentItem != nil {
            return (self.audioContext?.player.currentItem)!
        }
        return nil
    }
    
    /// The total number of audio samples in the file
    open var totalSamples: Int {
        return audioContext?.totalSamples ?? 0
    }
    
    /// The samples to be highlighted in a different color
    open var highlightedSamples: CountableRange<Int>? = nil {
        didSet {
            guard totalSamples > 0 else {
                return
            }
            let highlightStartPortion = CGFloat(highlightedSamples?.startIndex ?? 0) / CGFloat(totalSamples)
            let highlightLastPortion = CGFloat(highlightedSamples?.last ?? 0) / CGFloat(totalSamples)
            let highlightWidthPortion = highlightLastPortion - highlightStartPortion
            clipping.frame = CGRect(x: frame.width * highlightStartPortion, y: 0, width: frame.width * highlightWidthPortion , height: frame.height)
            setNeedsLayout()
        }
    }
    
    /// A portion of the waveform rendering to be highlighted
    @available(*, deprecated, message: "Use `zoomSamples` to set range")
    open var progressSamples: Int {
        get {
            return highlightedSamples?.upperBound ?? 0
        }
        set {
            highlightedSamples = 0 ..< newValue
        }
    }
    
    /// The samples to be displayed
    open var zoomSamples: CountableRange<Int> = 0 ..< 0 {
        didSet {
            setNeedsDisplay()
            setNeedsLayout()
        }
    }
    
    /// The first sample to render
    @available(*, deprecated, message: "Use `zoomSamples` to set range")
    open var zoomStartSamples: Int {
        get {
            return zoomSamples.startIndex
        }
        set(newStart) {
            zoomSamples = newStart ..< zoomSamples.endIndex
        }
    }
    
    /// One plus the last sample to render
    @available(*, deprecated, message: "Use `zoomSamples` to set range")
    open var zoomEndSamples: Int {
        get {
            return zoomSamples.endIndex
        }
        set(newEnd) {
            zoomSamples = zoomSamples.startIndex ..< newEnd
        }
    }
    
    /// Supported waveform types
    //TODO: make this public after reconciling WaveformView.WaveformType and FDWaveformType
    enum WaveformType {
        case linear, logarithmic
    }
    
    // Type of waveform to display
    var waveformType: WaveformType = .logarithmic {
        didSet {
            setNeedsDisplay()
            setNeedsLayout()
        }
    }
    
    /// The color of the waveform
    open var wavesColor = UIColor.darkGray {
        didSet {
            imageView.tintColor = wavesColor
        }
    }
    
    /// The color of the highlighted waveform (see `progressSamples`
    open var progressColor = UIColor.blue {
        didSet {
            highlightedImage.tintColor = progressColor
        }
    }
    
    
    //TODO: MAKE PUBLIC
    
    /// The portion of extra pixels to render left and right of the viewable region
    private var horizontalBleedTarget = 0.5
    
    /// The required portion of extra pixels to render left and right of the viewable region
    /// If this portion is not available then a re-render will be performed
    private var horizontalBleedAllowed = 0.1 ... 3.0
    
    /// The number of horizontal pixels to render per visible pixel on the screen (for antialiasing)
    private var horizontalOverdrawTarget = 3.0
    
    /// The required number of horizontal pixels to render per visible pixel on the screen (for antialiasing)
    /// If this number is not available then a re-render will be performed
    private var horizontalOverdrawAllowed = 1.5 ... 5.0
    
    /// The number of vertical pixels to render per visible pixel on the screen (for antialiasing)
    private var verticalOverdrawTarget = 2.0
    
    /// The required number of vertical pixels to render per visible pixel on the screen (for antialiasing)
    /// If this number is not available then a re-render will be performed
    private var verticalOverdrawAllowed = 1.0 ... 3.0
    
    /// The "zero" level (in dB)
    fileprivate let noiseFloor: CGFloat = -50.0
    
    
    
    // Mark - Private vars
    
    /// Whether rendering for the current asset failed
    private var renderForCurrentAssetFailed = false
    
    /// Current audio context to be used for rendering
    private var audioContext: FDAudioContext? {
        didSet {
            waveformImage = nil
            zoomSamples = 0 ..< self.totalSamples
            highlightedSamples = nil
            inProgressWaveformRenderOperation = nil
            cachedWaveformRenderOperation = nil
            renderForCurrentAssetFailed = false
            
            setNeedsDisplay()
            setNeedsLayout()
        }
    }
    
    /// Currently running renderer
    private var inProgressWaveformRenderOperation: FDWaveformRenderOperation? {
        willSet {
            if newValue !== inProgressWaveformRenderOperation {
                inProgressWaveformRenderOperation?.cancel()
            }
        }
    }
    
    /// The render operation used to render the current waveform image
    private var cachedWaveformRenderOperation: FDWaveformRenderOperation?
    
    /// Image of waveform
    private var waveformImage: UIImage? {
        get { return imageView.image }
        set {
            // This will allow us to apply a tint color to the image
            imageView.image = newValue?.withRenderingMode(.alwaysTemplate)
            highlightedImage.image = imageView.image
        }
    }
    
    /// Desired scale of image based on window's screen scale
    private var desiredImageScale: CGFloat {
        return window?.screen.scale ?? UIScreen.main.scale
    }
    
    /// Waveform type for rending waveforms
    //TODO: make this public after reconciling WaveformView.WaveformType and FDWaveformType
    var waveformRenderType: FDWaveformType {
        get {
            switch waveformType {
            case .linear: return .linear
            case .logarithmic: return .logarithmic(noiseFloor: noiseFloor)
            }
        }
    }
    
    /// Represents the status of the waveform renderings
    fileprivate enum CacheStatus {
        case dirty
        case notDirty(cancelInProgressRenderOperation: Bool)
    }
    
    fileprivate func decibel(_ amplitude: CGFloat) -> CGFloat {
        return 20.0 * log10(abs(amplitude))
    }
    
    /// View for rendered waveform
    lazy fileprivate var imageView: UIImageView = {
        let retval = UIImageView(frame: CGRect.zero)
        retval.contentMode = .scaleToFill
        retval.tintColor = self.wavesColor
        return retval
    }()
    
    /// View for rendered waveform showing progress
    lazy fileprivate var highlightedImage: UIImageView = {
        let retval = UIImageView(frame: CGRect.zero)
        retval.contentMode = .scaleToFill
        retval.tintColor = self.progressColor
        return retval
    }()
    
    /// A view which hides part of the highlighted image
    fileprivate let clipping: UIView = {
        let retval = UIView(frame: CGRect.zero)
        retval.clipsToBounds = true
        return retval
    }()
    
    /// Whether rendering is happening asynchronously
    fileprivate var renderingInProgress = false
    
    /// Whether loading is happening asynchronously
    fileprivate var loadingInProgress = false
    
    func setup() {
        addSubview(imageView)
        clipping.addSubview(highlightedImage)
        addSubview(clipping)
        clipsToBounds = true
        
    }
    
    required public init?(coder aCoder: NSCoder) {
        super.init(coder: aCoder)
        setup()
    }
    
    override init(frame rect: CGRect) {
        super.init(frame: rect)
        setup()
    }
    
    deinit {
        inProgressWaveformRenderOperation?.cancel()
    }
    
    /// If the cached waveform or in progress waveform is insufficient for the current frame
    fileprivate func cacheStatus() -> CacheStatus {
        guard !renderForCurrentAssetFailed else { return .notDirty(cancelInProgressRenderOperation: true) }
        
        let isInProgressRenderOperationDirty = isWaveformRenderOperationDirty(inProgressWaveformRenderOperation)
        let isCachedRenderOperationDirty = isWaveformRenderOperationDirty(cachedWaveformRenderOperation)
        
        if let isInProgressRenderOperationDirty = isInProgressRenderOperationDirty {
            if let isCachedRenderOperationDirty = isCachedRenderOperationDirty {
                if isInProgressRenderOperationDirty {
                    if isCachedRenderOperationDirty {
                        return .dirty
                    } else {
                        return .notDirty(cancelInProgressRenderOperation: true)
                    }
                } else if !isCachedRenderOperationDirty {
                    return .notDirty(cancelInProgressRenderOperation: true)
                }
            } else if isInProgressRenderOperationDirty {
                return .dirty
            }
        } else if let isLastWaveformRenderOperationDirty = isCachedRenderOperationDirty {
            if isLastWaveformRenderOperationDirty {
                return .dirty
            }
        } else {
            return .dirty
        }
        
        return .notDirty(cancelInProgressRenderOperation: false)
    }
    
    func isWaveformRenderOperationDirty(_ renderOperation: FDWaveformRenderOperation?) -> Bool? {
        guard let renderOperation = renderOperation else { return nil }
        
        if renderOperation.format.type != waveformRenderType {
            return true
        }
        if renderOperation.format.scale != desiredImageScale {
            return true
        }
        
        let requiredSamples = zoomSamples.extended(byFactor: horizontalBleedAllowed.lowerBound).clamped(to: 0 ..< totalSamples)
        if requiredSamples.clamped(to: renderOperation.sampleRange) != requiredSamples {
            return true
        }
        
        let allowedSamples = zoomSamples.extended(byFactor: horizontalBleedAllowed.upperBound).clamped(to: 0 ..< totalSamples)
        if renderOperation.sampleRange.clamped(to: allowedSamples) != renderOperation.sampleRange {
            return true
        }
        
        let verticalOverdrawRequested = Double(renderOperation.imageSize.height / frame.height)
        if !verticalOverdrawAllowed.contains(verticalOverdrawRequested) {
            return true
        }
        let horizontalOverdrawRequested = Double(renderOperation.imageSize.height / frame.height)
        if !horizontalOverdrawAllowed.contains(horizontalOverdrawRequested) {
            return true
        }
        
        return false
    }
    
    override open func layoutSubviews() {
        super.layoutSubviews()
        guard audioContext != nil && !zoomSamples.isEmpty else {
            return
        }
        
        switch cacheStatus() {
        case .dirty:
            renderWaveform()
            return
        case .notDirty(let cancelInProgressRenderOperation):
            if cancelInProgressRenderOperation {
                inProgressWaveformRenderOperation = nil
            }
        }
        
        // We need to place the images which have samples in `cachedSampleRange`
        // inside our frame which represents `startSamples..<endSamples`
        // all figures are a portion of our frame width
        var scaledX: CGFloat = 0.0
        var scaledWidth: CGFloat = 1.0
        var scaledHighlightedX: CGFloat = 0.0
        var scaledHighlightedWidth: CGFloat = 0.0
        if let cachedSampleRange = cachedWaveformRenderOperation?.sampleRange, !cachedSampleRange.isEmpty && !zoomSamples.isEmpty {
            scaledX = CGFloat(cachedSampleRange.lowerBound - zoomSamples.lowerBound) / CGFloat(zoomSamples.count)
            scaledWidth = CGFloat(cachedSampleRange.last! - zoomSamples.lowerBound) / CGFloat(zoomSamples.count)    // forced unwrap is safe
            scaledHighlightedX = CGFloat((highlightedSamples?.lowerBound ?? 0) - zoomSamples.lowerBound) / CGFloat(zoomSamples.count)
            scaledHighlightedWidth = CGFloat((highlightedSamples?.last ?? 0) - zoomSamples.lowerBound) / CGFloat(zoomSamples.count)
        }
        let childFrame = CGRect(x: frame.width * scaledX, y: 0, width: frame.width * scaledWidth, height: frame.height)
        imageView.frame = childFrame
        highlightedImage.frame = childFrame
        clipping.frame = CGRect(x: frame.width * scaledHighlightedX, y: 0, width: frame.width * scaledHighlightedWidth, height: frame.height)
        clipping.isHidden = !(highlightedSamples?.overlaps(zoomSamples) ?? false)
        print("\(frame) -- \(imageView.frame)")
    }
    
    func renderWaveform() {
        guard let audioContext = audioContext else { return }
        guard !zoomSamples.isEmpty else { return }
        
        let renderSamples = zoomSamples.extended(byFactor: horizontalBleedTarget).clamped(to: 0 ..< totalSamples)
        let widthInPixels = floor(frame.width * CGFloat(horizontalOverdrawTarget))
        let heightInPixels = frame.height * CGFloat(horizontalOverdrawTarget)
        let imageSize = CGSize(width: widthInPixels, height: heightInPixels)
        let renderFormat = FDWaveformRenderFormat(type: waveformRenderType, wavesColor: .black, scale: desiredImageScale, barWidth: barWidth, barIntervalWidth: barIntervalWidth)
        
        let waveformRenderOperation = FDWaveformRenderOperation(audioContext: audioContext, imageSize: imageSize, sampleRange: renderSamples, format: renderFormat) { [weak self] image in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                
                strongSelf.renderForCurrentAssetFailed = (image == nil)
                strongSelf.waveformImage = image
                strongSelf.renderingInProgress = false
                strongSelf.cachedWaveformRenderOperation = self?.inProgressWaveformRenderOperation
                strongSelf.inProgressWaveformRenderOperation = nil
                strongSelf.setNeedsLayout()
                strongSelf.delegate?.waveformViewDidRender?(strongSelf)
            }
        }
        self.inProgressWaveformRenderOperation = waveformRenderOperation
        
        renderingInProgress = true
        delegate?.waveformViewWillRender?(self)
        
        waveformRenderOperation.start()
    }
}

//TODO: make this public after reconciling WaveformView.WaveformType and FDWaveformType
enum FDWaveformType: Equatable {
    /// Waveform is rendered using a linear scale
    case linear
    
    /// Waveform is rendered using a logarithmic scale
    ///   noiseFloor: The "zero" level (in dB)
    case logarithmic(noiseFloor: CGFloat)
    
    // See http://stackoverflow.com/questions/24339807/how-to-test-equality-of-swift-enums-with-associated-values
    public static func ==(lhs: FDWaveformType, rhs: FDWaveformType) -> Bool {
        switch lhs {
        case .linear:
            if case .linear = rhs {
                return true
            }
        case .logarithmic(let lhsNoiseFloor):
            if case .logarithmic(let rhsNoiseFloor) = rhs {
                return lhsNoiseFloor == rhsNoiseFloor
            }
        }
        return false
    }
    
    public var floorValue: CGFloat {
        switch self {
        case .linear: return 0
        case .logarithmic(let noiseFloor): return noiseFloor
        }
    }
    
    func process(normalizedSamples: inout [Float]) {
        switch self {
        case .linear:
            return
            
        case .logarithmic(let noiseFloor):
            // Convert samples to a log scale
            var zero: Float = 1.0
            vDSP_vdbcon(normalizedSamples, 1, &zero, &normalizedSamples, 1, vDSP_Length(normalizedSamples.count), 1)
            
            //Clip to [noiseFloor, 0]
            var ceil: Float = 0.0
            var noiseFloorFloat = Float(noiseFloor)
            vDSP_vclip(normalizedSamples, 1, &noiseFloorFloat, &ceil, &normalizedSamples, 1, vDSP_Length(normalizedSamples.count))
        }
    }
}

/// To receive progress updates from WaveformView
@objc public protocol WaveformViewDelegate: NSObjectProtocol {
    /// An audio file will be loaded
    @objc optional func waveformViewWillLoad(_ waveformView: WaveformView)
    
    /// An audio file was loaded
    @objc optional func waveformViewDidLoad(_ waveformView: WaveformView)
    
    /// Rendering will begin
    @objc optional func waveformViewWillRender(_ waveformView: WaveformView)
    
    /// Rendering did complete
    @objc optional func waveformViewDidRender(_ waveformView: WaveformView)
}

//MARK -

extension Comparable {
    
    func clamped(from lowerBound: Self, to upperBound: Self) -> Self {
        return min(max(self, lowerBound), upperBound)
    }
    
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Strideable where Self.Stride: SignedInteger
{
    func clamped(to range: CountableClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

extension CountableRange where Bound: Strideable {
    
    // Extend each bound away from midpoint by `factor`, a portion of the distance from begin to end
    func extended(byFactor factor: Double) -> CountableRange<Bound> {
        let theCount: Int = numericCast(count)
        let amountToMove: Bound.Stride = numericCast(Int(Double(theCount) * factor))
        return lowerBound - amountToMove ..< upperBound + amountToMove
    }
}
