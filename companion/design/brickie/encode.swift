import AVFoundation
import AppKit
import VideoToolbox
// encode <png dir> <out.mov> [fps]  -> HEVC with alpha, 1280x768
let a = CommandLine.arguments
let dir = a[1], outURL = URL(fileURLWithPath: a[2])
let fps = Int32(a.count > 3 ? a[3] : "24")!
let files = try! FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.sorted()
try? FileManager.default.removeItem(at: outURL)
let first = NSImage(contentsOfFile: dir + "/" + files[0])!
let rep0 = first.representations[0]
let W = 1280, H = 768
let writer = try! AVAssetWriter(outputURL: outURL, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: W, AVVideoHeightKey: H,
  AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.75, kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.9] as [String: Any],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
_ = rep0
for (i, f) in files.enumerated() {
  while !input.isReadyForMoreMediaData { usleep(2000) }
  let img = NSImage(contentsOfFile: dir + "/" + f)!
  var pb: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
  CVPixelBufferLockBaseAddress(pb!, [])
  let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
  var r = CGRect(x: 0, y: 0, width: W, height: H)
  ctx.draw(img.cgImage(forProposedRect: &r, context: nil, hints: nil)!, in: r)
  CVPixelBufferUnlockBaseAddress(pb!, [])
  adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print(writer.status == .completed ? "ok \(files.count) frames" : "failed \(String(describing: writer.error))")
