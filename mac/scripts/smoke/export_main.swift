import Foundation
import AppKit
_ = NSApplication.shared
setvbuf(stdout, nil, _IONBF, 0)
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let sem = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let session = try RecordingSession.load(from: dir)
        let data = try Data(contentsOf: dir.appendingPathComponent("project.json"))
        guard let project = LenientDecode.decode(EditProject.self, from: data, defaults: EditProject()) else { print("ERR cannot read project.json"); sem.signal(); return }
        print("project: segments", project.segments.count, "texts", project.texts.count, "audio", project.audioClips.count, "zooms", project.zoomRegions.count)
        let t0 = Date()
        var last = -1
        try await VideoRenderer.export(session: session, project: project, to: out) { p in let v = Int(p*10); if v != last { last = v; print("progress", v*10) } }
        print("done in", Date().timeIntervalSince(t0))
    } catch { print("ERR", error) }
    sem.signal()
}
sem.wait()
