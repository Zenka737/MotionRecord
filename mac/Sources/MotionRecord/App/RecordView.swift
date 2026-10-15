import SwiftUI
import AVFoundation

struct RecordView: View {
    @EnvironmentObject var app: AppState

    private let fpsOptions = [15, 24, 30, 60, 120]

    var body: some View {
        VStack(spacing: 18) {
            if !app.hasPermission { permissionBanner }
            HStack(alignment: .center, spacing: 22) {
                hero.frame(maxWidth: .infinity)
                settingsCard.frame(width: 360)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(24)
    }

    // MARK: Permission

    private var permissionBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 24)).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Нужен доступ к записи экрана").font(.system(size: 14, weight: .semibold))
                Text("Разрешите MotionRecord запись экрана в Системных настройках, затем перезапустите приложение.")
                    .font(.system(size: 12)).foregroundColor(Theme.textDim)
            }
            Spacer()
            Button("Запросить доступ") { app.requestPermission() }
                .buttonStyle(PrimaryButtonStyle())
            Button("Открыть настройки") { app.openScreenRecordingSettings() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            RecordButton()
            VStack(spacing: 6) {
                Text(title).font(.system(size: 20, weight: .semibold))
                HStack(spacing: 6) {
                    Text("Горячая клавиша").foregroundColor(Theme.textDim)
                    Text("⌘⇧R")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                }
                .font(.system(size: 12.5))
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch app.phase {
        case .idle: return "Готов к записи"
        case .countdown(let n): return "Старт через \(n)…"
        case .starting: return "Подготовка…"
        case .recording: return "Идёт запись"
        case .stopping: return "Сохранение…"
        }
    }

    // MARK: Camera

    @State private var cameras: [(id: String, name: String)] = []

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Камера")
            Toggle("Записывать камеру", isOn: Binding(get: { app.recordingSettings.recordCamera }, set: { on in
                app.recordingSettings.recordCamera = on
                if on {
                    cameras = CameraBridge.availableCameras()
                    if !CameraBridge.isAuthorized { Task { _ = await CameraBridge.requestPermission() } }
                }
            }))
            .toggleStyle(.switch).tint(Theme.accent)
            if app.recordingSettings.recordCamera {
                Picker("", selection: Binding(get: { app.recordingSettings.cameraDeviceID ?? "" },
                                              set: { app.recordingSettings.cameraDeviceID = $0.isEmpty ? nil : $0 })) {
                    Text("Камера по умолчанию").tag("")
                    ForEach(cameras, id: \.id) { c in Text(c.name).tag(c.id) }
                }
                .labelsHidden().pickerStyle(.menu)
                if CameraBridge.isDenied {
                    Text("Нет доступа к камере. Разрешите его в Системных настройках → Конфиденциальность → Камера.")
                        .font(.system(size: 11)).foregroundColor(.orange)
                } else {
                    Text("Камера записывается отдельным файлом; в редакторе её можно двигать, менять форму и размер.")
                        .font(.system(size: 11)).foregroundColor(Theme.textDim)
                }
            }
        }
        .onAppear { cameras = CameraBridge.availableCameras() }
    }

    // MARK: Microphone

    @State private var mics: [(id: String, name: String)] = []
    @State private var micStatus = RecordingEngine.micPermissionStatus()

    private var micSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Микрофон")
            Toggle("Записывать микрофон", isOn: Binding(get: { app.recordingSettings.recordMic }, set: { on in
                app.recordingSettings.recordMic = on
                if on {
                    mics = RecordingEngine.availableMics()
                    Task { _ = await RecordingEngine.requestMicPermission(); micStatus = RecordingEngine.micPermissionStatus() }
                }
            }))
            .toggleStyle(.switch).tint(Theme.accent)
            if app.recordingSettings.recordMic {
                Picker("", selection: Binding(get: { app.recordingSettings.micDeviceID ?? "" },
                                              set: { app.recordingSettings.micDeviceID = $0.isEmpty ? nil : $0 })) {
                    Text("Микрофон по умолчанию").tag("")
                    ForEach(mics, id: \.id) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden().pickerStyle(.menu)
                if app.isRecording {
                    ProgressView(value: Double(app.micLevel)).tint(Theme.accent)
                }
                if micStatus == .denied || micStatus == .restricted {
                    Text("Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность → Микрофон.")
                        .font(.system(size: 11)).foregroundColor(.orange)
                } else {
                    Text("Голос пишется отдельной дорожкой. В редакторе его можно приглушить, а Моти внизу кадра будет подпрыгивать, пока вы говорите.")
                        .font(.system(size: 11)).foregroundColor(Theme.textDim)
                }
            }
        }
        .onAppear { mics = RecordingEngine.availableMics(); micStatus = RecordingEngine.micPermissionStatus() }
    }

    private var keysAllowed: Bool { RecordingEngine.hasKeyboardPermission() }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Клавиатура")
            Toggle("Записывать нажатия клавиш", isOn: Binding(get: { app.recordingSettings.recordKeys }, set: { on in
                app.recordingSettings.recordKeys = on
                if on && !RecordingEngine.hasKeyboardPermission() { RecordingEngine.requestKeyboardPermission() }
            }))
            .toggleStyle(.switch).tint(Theme.accent)
            if app.recordingSettings.recordKeys && !keysAllowed {
                Text("Нет разрешения «Мониторинг ввода» — без него нажатия клавиш не записываются (в вашей записи их будет 0).")
                    .font(.system(size: 11)).foregroundColor(.orange)
                Button("Открыть настройки: Мониторинг ввода") {
                    RecordingEngine.requestKeyboardPermission()
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(u) }
                }.buttonStyle(SecondaryButtonStyle())
                Text("Включите MotionRecord в списке, затем полностью перезапустите приложение (⌘Q).")
                    .font(.system(size: 11)).foregroundColor(Theme.textDim)
            } else {
                Text("Запоминаются только моменты нажатий (не буквы). В редакторе на их основе добавляется приятный звук набора.")
                    .font(.system(size: 11)).foregroundColor(Theme.textDim)
            }
        }
    }

    // MARK: Settings

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Дисплей")
                Picker("", selection: Binding(get: { app.recordingSettings.displayID },
                                              set: { app.recordingSettings.displayID = $0 })) {
                    Text("Основной дисплей").tag(UInt32(0))
                    ForEach(app.displays) { d in
                        Text("\(d.name) — \(d.pointWidth)×\(d.pointHeight)\(d.isMain ? " (основной)" : "")").tag(d.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Частота кадров")
                Picker("", selection: Binding(get: { app.recordingSettings.fps },
                                              set: { app.recordingSettings.fps = $0 })) {
                    ForEach(fpsOptions, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Выше FPS — плавнее курсор и зум, но больше файл.")
                    .font(.system(size: 11)).foregroundColor(Theme.textDim)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Опции")
                Toggle("Индикатор в чёлке", isOn: Binding(get: { app.recordingSettings.showNotchIndicator },
                                                          set: { app.recordingSettings.showNotchIndicator = $0 }))
                Toggle("Обратный отсчёт 3-2-1", isOn: $app.countdownEnabled)
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            cameraSection
            micSection
            keysSection
        }
        .disabled(app.isBusy)
        .card(padding: 20)
        .task { app.refreshDisplays() }
    }
}

struct RecordButton: View {
    @EnvironmentObject var app: AppState
    @State private var hover = false

    var body: some View {
        Button { app.toggleRecording() } label: {
            ZStack {
                Circle().fill(Theme.record.opacity(0.12)).frame(width: 190, height: 190)
                Circle().strokeBorder(Theme.record.opacity(0.5), lineWidth: 3).frame(width: 164, height: 164)
                RoundedRectangle(cornerRadius: app.isRecording ? 14 : 60, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#FF5468"), Theme.record], startPoint: .top, endPoint: .bottom))
                    .frame(width: app.isRecording ? 60 : 130, height: app.isRecording ? 60 : 130)
                    .shadow(color: Theme.record.opacity(0.6), radius: hover ? 26 : 16)
                if app.phase == .stopping || app.phase == .starting {
                    ProgressView().controlSize(.large)
                } else if case .countdown(let n) = app.phase {
                    Text("\(n)").font(.system(size: 56, weight: .bold, design: .rounded)).foregroundColor(.white)
                }
                if !app.isBusy {
                    Text("Запись").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                } else if app.isRecording {
                    Text("Остановить").font(.system(size: 13, weight: .semibold)).foregroundColor(.white).offset(y: 52)
                }
            }
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: app.phase)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(app.phase == .stopping)
        .help(app.isRecording ? "Остановить" : "Начать запись")
    }
}
