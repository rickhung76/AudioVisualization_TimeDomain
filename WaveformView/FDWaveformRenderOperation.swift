//
// Copyright 2013 - 2017, William Entriken and the FDWaveformView contributors.
//
import UIKit
import AVFoundation
import Accelerate

/// Format options for FDWaveformRenderOperation
//MAYBE: Make this public
struct FDWaveformRenderFormat {
    
    /// The type of waveform to render
    //TODO: make this public after reconciling FDWaveformView.WaveformType and FDWaveformType
    var type: FDWaveformType
    
    /// The color of the waveform
    internal var wavesColor: UIColor
    
    /// The scale factor to apply to the rendered image (usually the current screen's scale)
    public var scale: CGFloat
    public var barWidth: CGFloat
    public var barIntervalWidth: CGFloat
    
    /// Whether the resulting image size should be as close as possible to imageSize (approximate)
    /// or whether it should match it exactly. Right now there is no support for matching exactly.
    // TODO: Support rendering operations that always match the desired imageSize passed in.
    //       Right now the imageSize passed in to the render operation might not match the
    //       resulting image's size. This flag is hard coded here to convey that.
    public let constrainImageSizeToExactlyMatch = false
    
    // To make these public, you must implement them
    // See http://stackoverflow.com/questions/26224693/how-can-i-make-public-by-default-the-member-wise-initialiser-for-structs-in-swif
    public init() {
        self.init(type: .linear,
                  wavesColor: .black,
                  scale: UIScreen.main.scale,
                  barWidth: 10.0,
                  barIntervalWidth: 20.0)
    }
    
    init(type: FDWaveformType, wavesColor: UIColor, scale: CGFloat, barWidth: CGFloat, barIntervalWidth:CGFloat) {
        self.type = type
        self.wavesColor = wavesColor
        self.scale = scale
        self.barWidth = barWidth
        self.barIntervalWidth = barIntervalWidth
    }
}

/// Operation used for rendering waveform images
final public class FDWaveformRenderOperation: Operation {
    
    /// The audio context used to build the waveform
    let audioContext: FDAudioContext
    
    /// Size of waveform image to render
    public let imageSize: CGSize
    
    /// Range of samples within audio asset to build waveform for
    public let sampleRange: CountableRange<Int>
    
    /// Format of waveform image
    let format: FDWaveformRenderFormat
    
    // MARK: - NSOperation Overrides
    
    public override var isAsynchronous: Bool { return true }
    
    private var _isExecuting = false
    public override var isExecuting: Bool { return _isExecuting }
    
    private var _isFinished = false
    public override var isFinished: Bool { return _isFinished }
    
    // MARK: - Private
    
    ///  Handler called when the rendering has completed. nil UIImage indicates that there was an error during processing.
    private let completionHandler: (UIImage?) -> ()
    
    /// Final rendered image. Used to hold image for completionHandler.
    private var renderedImage: UIImage?
    
    init(audioContext: FDAudioContext, imageSize: CGSize, sampleRange: CountableRange<Int>? = nil, format: FDWaveformRenderFormat = FDWaveformRenderFormat(), completionHandler: @escaping (_ image: UIImage?) -> ()) {
        self.audioContext = audioContext
        self.imageSize = imageSize
        self.sampleRange = sampleRange ?? 0..<audioContext.totalSamples
        self.format = format
        self.completionHandler = completionHandler
        
        super.init()
        
        self.completionBlock = { [weak self] in
            guard let `self` = self else { return }
            self.completionHandler(self.renderedImage)
            self.renderedImage = nil
        }
    }
    
    public override func start() {
        guard !isExecuting && !isFinished && !isCancelled else { return }
        
        willChangeValue(forKey: "isExecuting")
        _isExecuting = true
        didChangeValue(forKey: "isExecuting")
        
        self.render()   //TODO: Delete
        
//        if #available(iOS 8.0, *) {
//            DispatchQueue.global(qos: .background).async { self.render() }
//        } else {
//            DispatchQueue.global(priority: .background).async { self.render() }
//        }
    }
    
    private func finish(with image: UIImage?) {
        guard !isFinished && !isCancelled else { return }
        
        renderedImage = image
        
        // completionBlock called automatically by NSOperation after these values change
        willChangeValue(forKey: "isExecuting")
        willChangeValue(forKey: "isFinished")
        _isExecuting = false
        _isFinished = true
        didChangeValue(forKey: "isExecuting")
        didChangeValue(forKey: "isFinished")
    }
    
    private func render() {
        guard
            !sampleRange.isEmpty,
            imageSize.width > 0, imageSize.height > 0
            else {
                finish(with: nil)
                return
        }
        
        
//        let targetSamples = Int(imageSize.width * format.scale)
        let totalInterval = format.barWidth + format.barIntervalWidth
        let targetSamples = Int(imageSize.width / totalInterval)
        
        let image: UIImage? = {
            guard
                let (samples, sampleMax) = sliceAsset(withRange: sampleRange, andDownsampleTo: targetSamples),
                let image = plotWaveformGraph(samples, maximumValue: sampleMax, zeroValue: format.type.floorValue)
                else { return nil }
            
            return image
        }()
        
        finish(with: image)
    }
    
    /// Read the asset and create create a lower resolution set of samples
    func sliceAsset(withRange sourceRange: CountableRange<Int>, andDownsampleTo targetSampleCount: Int) -> (samples: [CGFloat], sampleMax: CGFloat)? {
        guard !isCancelled else { return nil }
        
        guard
            !sourceRange.isEmpty,
            targetSampleCount > 0,
            let assetReader = try? AVAssetReader(asset: audioContext.asset)
            else { return nil }
        
        let timeScale = audioContext.asset.duration.timescale
        let timeRange = CMTimeRange(start: CMTime(value: Int64(sourceRange.lowerBound), timescale: timeScale),
                                    duration: CMTime(value: Int64(sourceRange.count), timescale: timeScale))
        
        // 32-bit float samples.
        let outputSettingsDict: [String : Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        assetReader.timeRange = timeRange
        
        let readerOutput = AVAssetReaderTrackOutput(track: audioContext.assetTrack, outputSettings: outputSettingsDict)
        readerOutput.alwaysCopiesSampleData = false
        assetReader.add(readerOutput)
        
        var channelCount = 1
        let formatDescriptions = audioContext.assetTrack.formatDescriptions as! [CMAudioFormatDescription]
        for item in formatDescriptions {
            guard let formatDescription = CMAudioFormatDescriptionGetStreamBasicDescription(item) else { return nil }
            channelCount = Int(formatDescription.pointee.mChannelsPerFrame)
        }
        
        var sampleMax = format.type.floorValue
        let samplesPerPixel = max(1, channelCount * sourceRange.count / targetSampleCount)
        let filter = [Float](repeating: 1.0 / Float(samplesPerPixel), count: samplesPerPixel)
        
        var outputSamples = [CGFloat]()
        var sampleBuffer = Data()
        
        assetReader.startReading()
        defer { assetReader.cancelReading() } // Cancel reading if we exit early if operation is cancelled
        
        while assetReader.status == .reading {
            guard !isCancelled else { return nil }
            
            guard let readSampleBuffer = readerOutput.copyNextSampleBuffer(),
                let readBuffer = CMSampleBufferGetDataBuffer(readSampleBuffer) else {
                    break
            }
            
            // Append audio sample buffer into our current sample buffer
            var readBufferLength = 0
            var readBufferPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(readBuffer, 0, &readBufferLength, nil, &readBufferPointer)
            sampleBuffer.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
            CMSampleBufferInvalidate(readSampleBuffer)
            
            let totalSamples = sampleBuffer.count / MemoryLayout<Float>.size
            let downSampledLength = totalSamples / samplesPerPixel
            let samplesToProcess = downSampledLength * samplesPerPixel
            
            guard samplesToProcess > 0 else { continue }
            
            processSamples(fromData: &sampleBuffer,
                           sampleMax: &sampleMax,
                           outputSamples: &outputSamples,
                           samplesToProcess: samplesToProcess,
                           downSampledLength: downSampledLength,
                           samplesPerPixel: samplesPerPixel,
                           filter: filter)
        }
        
        // Process the remaining samples at the end which didn't fit into samplesPerPixel
        let samplesToProcess = sampleBuffer.count / MemoryLayout<Float>.size
        if samplesToProcess > 0 {
            guard !isCancelled else { return nil }
            
            let downSampledLength = 1
            let samplesPerPixel = samplesToProcess
            let filter = [Float](repeating: 1.0 / Float(samplesPerPixel), count: samplesPerPixel)
            
            processSamples(fromData: &sampleBuffer,
                           sampleMax: &sampleMax,
                           outputSamples: &outputSamples,
                           samplesToProcess: samplesToProcess,
                           downSampledLength: downSampledLength,
                           samplesPerPixel: samplesPerPixel,
                           filter: filter)
        }
        
        // if (reader.status == AVAssetReaderStatusFailed || reader.status == AVAssetReaderStatusUnknown)
        // Something went wrong. Handle it.
        if assetReader.status == .completed {
            return (outputSamples, sampleMax)
        } else {
            print("FDWaveformRenderOperation failed to read audio: \(String(describing: assetReader.error))")
            return nil
        }
    }
    
    // TODO: report progress? (for issue #2)
    func processSamples(fromData sampleBuffer: inout Data, sampleMax: inout CGFloat, outputSamples: inout [CGFloat], samplesToProcess: Int, downSampledLength: Int, samplesPerPixel: Int, filter: [Float]) {
        sampleBuffer.withUnsafeBytes { (samples: UnsafePointer<Float>) in
            
            let sampleCount = vDSP_Length(samplesToProcess)
            
            let buffer = UnsafeBufferPointer(start: samples, count: samplesToProcess);
            var processingBuffer = Array(buffer)
            
            //Take the absolute values to get amplitude
            vDSP_vabs(processingBuffer, 1, &processingBuffer, 1, sampleCount)
            
            //Let current type further process the samples
            format.type.process(normalizedSamples: &processingBuffer)
            
            //Downsample and find maximum value
            var downSampledData = [Float](repeating: 0.0, count: downSampledLength)
            vDSP_desamp(processingBuffer,
                        vDSP_Stride(samplesPerPixel),
                        filter, &downSampledData,
                        vDSP_Length(downSampledLength),
                        vDSP_Length(samplesPerPixel))
            
            var maximum = -Float.infinity;
            vDSP_maxv(downSampledData,
                      1,
                      &maximum,
                      vDSP_Length(downSampledData.count))
            
            sampleMax = max(sampleMax, CGFloat(maximum))

            // TODO: This is not necessary for 32-bit builds and `vDSP_vspdp()` should be faster on 64-bit.
            // I failed to rewrite this, because I couldn’t convince the the Swift compiler that
            // `Double` and `CGFloat` are the same thing on 64-bit with regard to arrays.
            let downSampledDataCG = downSampledData.map { (value: Float) -> CGFloat in
                let element = CGFloat(value)
                return element
            }
            
            // Remove processed samples
            sampleBuffer.removeFirst(samplesToProcess * MemoryLayout<Float>.size)
            
            outputSamples += downSampledDataCG
        }
    }
    
    // TODO: report progress? (for issue #2)
    func plotWaveformGraph(_ samples: [CGFloat], maximumValue max: CGFloat, zeroValue min: CGFloat) -> UIImage? {
        guard !isCancelled else { return nil }
        
//        let imageSize = CGSize(width: CGFloat(samples.count) / format.scale,
//                               height: self.imageSize.height)
        let imageSize = CGSize(width: self.imageSize.width, height: self.imageSize.height)
        
        UIGraphicsBeginImageContextWithOptions(imageSize, false, format.scale)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext() else {
            NSLog("FDWaveformView failed to get graphics context")
            return nil
        }
        context.scaleBy(x: 1, y: 1 / format.scale) // Scale context to account for scaling applied to image
        context.setShouldAntialias(false)
        context.setAlpha(1.0)
//        context.setLineWidth(1.0 / format.scale)
        let totalInterval = format.barWidth + format.barIntervalWidth
        context.setLineWidth(format.barWidth)
        context.setStrokeColor(format.wavesColor.cgColor)
        let xOffset = format.barWidth
        
        let sampleDrawingScale: CGFloat
        if max == min {
            sampleDrawingScale = 0
        } else {
            sampleDrawingScale = (imageSize.height * format.scale) / 2 / (max - min)
        }
        let verticalMiddle = (imageSize.height * format.scale) / 2
        for (x, sample) in samples.enumerated() {
            let height = (sample - min) * sampleDrawingScale
            context.move(to: CGPoint(x: xOffset + CGFloat(x) * totalInterval, y: verticalMiddle - height))
            context.addLine(to: CGPoint(x: xOffset + CGFloat(x) * totalInterval, y: verticalMiddle + height))
            context.strokePath();
        }
        guard let image = UIGraphicsGetImageFromCurrentImageContext() else {
            NSLog("FDWaveformView failed to get waveform image from context")
            return nil
        }
        
        return image
    }
}
