# MotionRecord для macOS

Swift-пакет: SwiftUI, ScreenCaptureKit, Core Image, AVFoundation. Интерфейс на русском.

```bash
./scripts/build_app.sh     # build/MotionRecord.app (release + ad-hoc подпись)
./scripts/run.sh           # собрать и открыть
```

Не запускайте через `swift run`: разрешения привязываются к подписанному приложению.
Разрешения при первом запуске: запись экрана, камера (по желанию), мониторинг ввода (звуки клавиатуры).

Записи: `~/Movies/MotionRecord/<дата>/{raw.mov, cam.mov, meta.json, project.json}`.
