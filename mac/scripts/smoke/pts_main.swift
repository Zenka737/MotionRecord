import AVFoundation
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let a = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let tr = a.tracks(withMediaType: .video)[0]
let r = try AVAssetReader(asset: a)
let o = AVAssetReaderTrackOutput(track: tr, outputSettings: nil)
r.add(o); r.startReading()
var secBytes = [Int: Int](), keys = 0, n = 0, maxSize = 0
var keyTimes: [Double] = []
while let s = o.copyNextSampleBuffer() {
    let t = CMSampleBufferGetPresentationTimeStamp(s).seconds
    let sz = CMSampleBufferGetTotalSampleSize(s)
    if t.isFinite { secBytes[Int(t), default: 0] += sz }
    maxSize = max(maxSize, sz); n += 1
    let att = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
    let notSync = (att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    if !notSync { keys += 1; if t.isFinite { keyTimes.append(t) } }
}
print("frames", n, "keyframes", keys, "max frame bytes", maxSize)
print("first keyframes:", keyTimes.sorted().prefix(8).map { String(format: "%.2f", $0) })
let rates = secBytes.keys.sorted().map { (Double(secBytes[$0]!) * 8 / 1e6) }
print("Mbps min/avg/max:", rates.min()!, rates.reduce(0,+)/Double(rates.count), rates.max()!)
for k in secBytes.keys.sorted() { print(k, String(format: "%.0f", Double(secBytes[k]!) * 8 / 1e6), terminator: " | ") }
print()
