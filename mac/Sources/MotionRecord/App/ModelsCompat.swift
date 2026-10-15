import Foundation

/// Tolerant decoding of meta.json written by older versions (new fields missing).
extension RecordingMetadata {
    enum CodingKeys: String, CodingKey {
        case videoFileName, width, height, pointWidth, pointHeight, fps, duration, startedAt, cursor, clicks, cameraFileName, cameraOffset, micFileName, micOffset, keys, windows, cursorShapes, cursorChanges
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoFileName = try c.decodeIfPresent(String.self, forKey: .videoFileName) ?? "raw.mov"
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        pointWidth = try c.decode(Double.self, forKey: .pointWidth)
        pointHeight = try c.decode(Double.self, forKey: .pointHeight)
        fps = try c.decode(Int.self, forKey: .fps)
        duration = try c.decode(Double.self, forKey: .duration)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        cursor = try c.decodeIfPresent([CursorSample].self, forKey: .cursor) ?? []
        clicks = try c.decodeIfPresent([ClickEvent].self, forKey: .clicks) ?? []
        cameraFileName = try c.decodeIfPresent(String.self, forKey: .cameraFileName)
        cameraOffset = try c.decodeIfPresent(Double.self, forKey: .cameraOffset) ?? 0
        micFileName = try c.decodeIfPresent(String.self, forKey: .micFileName)
        micOffset = try c.decodeIfPresent(Double.self, forKey: .micOffset) ?? 0
        keys = try c.decodeIfPresent([KeyPress].self, forKey: .keys) ?? []
        windows = try c.decodeIfPresent([WindowTrack].self, forKey: .windows) ?? []
        cursorShapes = try c.decodeIfPresent([CursorShapeDef].self, forKey: .cursorShapes) ?? []
        cursorChanges = try c.decodeIfPresent([CursorChange].self, forKey: .cursorChanges) ?? []
    }
}

/// Decodes old JSON that lacks newer keys: missing dictionary keys fall back to the defaults.
enum LenientDecode {
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) -> T? {
        if let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        guard let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              let def = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return nil }
        let merged = merge(def, old)
        guard let md = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(T.self, from: md)
    }

    private static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let bd = base[k] as? [String: Any], let od = v as? [String: Any] { out[k] = merge(bd, od) }
            else { out[k] = v }
        }
        return out
    }
}
