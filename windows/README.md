# MotionRecord для Windows (MVP)

Порт macOS-приложения MotionRecord (`../MotionRecord`, оригинал не тронут). Запись экрана без вшитого курсора → метаданные курсора и кликов → плавный курсор, авто-зум → простой монтаж → экспорт MP4.

## Стек и почему
- **C# / .NET 8 + WPF**: самый короткий путь к нативному Windows-приложению с русским интерфейсом; логика (сглаживание, камера) переносится почти построчно.
- **SkiaSharp** для композиции кадра (фон, скругления, тень, зум, курсор, текст) — один и тот же код рисует превью и экспорт и работает на любой ОС, поэтому его можно тестировать на Mac.
- **ffmpeg.exe** для кодирования/декодирования mp4 (вместо Media Foundation) и **GDI-захват** (вместо Windows.Graphics.Capture) — осознанное упрощение MVP: оба слота за узким интерфейсом (`ScreenRecorder`, `Ffmpeg`/`FrameSource`), заменяются без правки логики и форматов. WGC + Media Foundation — следующий этап.

## Что перенесено
| macOS | Windows |
|---|---|
| `Models.swift`, `EditProject.swift`, `ModelsCompat.swift` | `Models.cs`, `EditProject.cs`, `Json.cs` — те же ключи JSON; неизвестные поля project.json (камера, аудио, Mochi…) сохраняются как есть |
| `CursorSmoother`, `ClickTimeline` | `CursorSmoother.cs` (240 Гц, двойной forward/backward, «прилипание» к кликам) |
| `CameraPlanner` | `CameraPlanner.cs` (периоды зума, ручные регионы побеждают авто, пружинная камера) |
| `FrameCompositor`, `VideoRenderer` | `FrameRenderer.cs` (Skia), `Ffmpeg.cs` (экспорт, до 60 fps) |
| `InputTracker`, `ScreenCaptureRecorder` | `ScreenRecorder.cs` (GetCursorPos/GetAsyncKeyState 240 Гц + захват экрана) |
| Редактор, таймлайн | `MainWindow`, `TimelineControl`, `EditorModel` (разрез, удаление, скорость, зум, текст, trim/move, Ctrl+Z) |

Время: source time = секунды от первого кадра, output time — после вырезок/скорости (`SourceTime`/`OutputTime`). Координаты: левый верхний угол, y вниз. На Windows приложение DPI-aware (PerMonitorV2), поэтому «точки» = физические пиксели (`pointWidth == width`).

Папка записи: `%USERPROFILE%\Videos\MotionRecord\<дата_время>\{raw.mp4, meta.json, project.json}`. `meta.json` читается и пишется в формате macOS (`videoFileName` = `raw.mp4`).

## Не входит в MVP
Веб-камера, микрофон/системный звук, звуки клавиатуры и генерация музыки, окна-вырезы (cut-outs), блюр, Mochi, формы курсора системы (рисуется стрелка), свой фон-картинка, GIF/MOV-экспорт, выбор монитора/окна (пишется основной монитор), WGC, Media Foundation, установщик.

## Сборка и тесты (Windows, PowerShell)
Нужен .NET 8 SDK. `.\build.ps1` — тесты + publish в `publish\`; `.\fetch-ffmpeg.ps1` — положить ffmpeg.exe (скачивание — только когда вы сами запустите скрипт).
Тесты ядра запускаются и на Mac/Linux: `dotnet test tests/MotionRecord.Core.Tests`.

`tools/gen_golden.sh` (только Mac) пересоздаёт `golden.json` из **оригинального Swift-кода** — тесты проверяют, что C# даёт те же числа.

## Как протестировать на Windows
1. Windows 10 2004+/11, .NET 8 SDK. Откройте PowerShell в этой папке: `.\build.ps1`, затем `.\fetch-ffmpeg.ps1`.
2. Все unit-тесты должны быть зелёными (`dotnet test` в build.ps1).
3. Запустите `publish\MotionRecord.exe`. Если внизу/сверху статус «Не найден ffmpeg.exe» — шаг 1 не выполнен.
4. **Запись**: «● Запись» (или Ctrl+Shift+R) → отсчёт 3 с, окно сворачивается. Подвигайте мышью, сделайте 3–5 кликов в разных углах экрана 10–15 секунд, остановите тем же хоткеем. Должна появиться папка в `Видео\MotionRecord`.
5. **Проверьте файлы**: `raw.mp4` играет и в нём НЕТ курсора; `meta.json` содержит `cursor` (сотни точек), `clicks` (пары isDown true/false), `width/height` = разрешение экрана.
6. **Редактор**: запись выбирается слева. Проверьте: перемотка по таймлайну; Play; на дорожке зума бледные блоки = авто-зум по кликам, в превью камера приближается к месту клика; курсор плавный и «попадает» в клик; S — разрез, выбрать кусок → скорость 2×, Del — удалить, Z — добавить ручной зум, T — текст, Ctrl+Z; ползунки сглаживания, поля, скругления; формат 9:16.
7. **Экспорт**: «Экспорт в MP4…» → файл открывается в плеере, длительность = длительность в редакторе после вырезок, зум/курсор/текст на месте.
8. **Совместимость**: скопируйте папку записи на Mac (копию!) — приложение MotionRecord открывает её; и наоборот, копию записи с Mac — в Windows (раскодирование `raw.mov` HEVC зависит от ffmpeg и работает, но `videoFileName` должен быть `raw.mov`).
9. Если что-то не так — пришлите текст ошибки из диалога и `meta.json`.

## Известные ограничения / риски
- GDI-захват: 30 fps реалистично на 1080p, на 4K может не держать 60; защищённый (DRM) контент и некоторые полноэкранные игры не захватываются.
- Несколько мониторов: пишется только основной; курсор на втором мониторе даст координаты вне кадра.
- Превью использует ffmpeg-перемотку (при быстром скрабинге может запаздывать — показывается последний запрошенный кадр).

## Что проверено (Mac, .NET 8.0.131 из brew `dotnet@8`)
- `MotionRecord.Core` собирается; **18 из 18 unit-тестов зелёные**: сглаживание курсора, анимация клика, периоды/план зума, камера, конвертация времени, печать текста — совпадают с оригинальным Swift (golden, 1e-6); JSON-совместимость с macOS; рендер кадра в Skia.
- `EditorModel`, `ScreenRecorder`, `Native` компилируются (проверено во временном проекте).
- Весь C#-код приложения (`MainWindow.xaml.cs`, `TimelineControl`, `PreviewService`, `App.xaml.cs`) **компилируется без ошибок** против настоящих WPF-сборок (reference pack Microsoft.WindowsDesktop.App.Ref), XAML-разметка корректна как XML, все обработчики событий существуют.
- **Не проверено**: компиляция самой XAML-разметки (MSBuild-задача WPF есть только на Windows); запуск GUI, захват экрана, ffmpeg-экспорт (ffmpeg на Mac нет) — только на Windows.
- На Mac тесты: `export DOTNET_ROOT=/opt/homebrew/opt/dotnet@8/libexec PATH=/opt/homebrew/opt/dotnet@8/bin:$PATH; dotnet test tests/MotionRecord.Core.Tests`
