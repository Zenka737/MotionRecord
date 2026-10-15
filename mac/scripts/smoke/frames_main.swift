import AVFoundation
import AppKit
let a = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let g = AVAssetImageGenerator(asset: a)
g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
g.maximumSize = CGSize(width: 960, height: 540)
for t in CommandLine.arguments.dropFirst(3) {
    let sec = Double(t)!
    if let img = try? g.copyCGImage(at: CMTime(seconds: sec, preferredTimescale: 600), actualTime: nil) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(CommandLine.arguments[2])_\(t).png"))
    } else { print("fail", t) }
}
