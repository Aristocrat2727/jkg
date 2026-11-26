import SwiftUI
import PhotosUI
import AVFoundation
import UserNotifications

@main
struct BurnerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let username: String
    let text: String
    let type: String
    let mine: Bool
}

struct ContentView: View {
    @AppStorage("server") private var serverHost = "48.102.161.53:3000"

    @State private var screen: Screen = .login
    @State private var roomCode = ""
    @State private var myNick = ""
    @State private var messages: [ChatMessage] = []
    @State private var online = 0
    @State private var inputText = ""
    @State private var showPhotoPicker = false
    @State private var pickedItem: PhotosPickerItem? = nil
    @State private var isRecording = false
    @State private var recordTime = 0
    @State private var status = ""
    @State private var playingMsgId: UUID? = nil
    @State private var showSettings = false
    @State private var serverInput = ""
    @State private var fullscreenImage: UIImage? = nil

    @State private var socket: WSClient? = nil

    private let recorder = RecorderHelper()
    private let player = PlayerHelper()

    enum Screen { case login, chat }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if screen == .login { loginView } else { chatView }
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(recorder.$elapsed) { t in recordTime = t }
        .onReceive(recorder.$finishedData) { data in
            guard let data = data else { return }
            recorder.finishedData = nil
            sendVoice(data)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { item in
            guard let item = item else { return }
            pickedItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data),
                   let jpeg = img.jpegData(compressionQuality: 0.3) {
                    sendImage(jpeg)
                }
            }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .fullScreenCover(isPresented: Binding(
            get: { fullscreenImage != nil },
            set: { if !$0 { fullscreenImage = nil } }
        )) {
            if let img = fullscreenImage {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack {
                        Image(uiImage: img).resizable().scaledToFit()
                        Button("ЗАКРЫТЬ") { fullscreenImage = nil }
                            .font(.system(size: 14, design: .monospaced)).foregroundColor(.green)
                            .padding()
                    }
                }
            }
        }
    }

    var loginView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("BURNER")
                .font(.system(size: 40, weight: .heavy, design: .monospaced))
                .foregroundColor(.green)
            Text("анонимный чат по коду комнаты")
                .font(.system(size: 12, design: .monospaced)).foregroundColor(.gray)

            TextField("КОД КОМНАТЫ", text: $roomCode)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .keyboardType(.asciiCapable)
                .padding(14)
                .overlay(Rectangle().stroke(Color.green, lineWidth: 1))
                .padding(.horizontal, 40)
                .onChange(of: roomCode) { v in
                    roomCode = String(v.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10))
                }

            Button("ВОЙТИ / СОЗДАТЬ") { join() }
                .buttonStyle(Btn())
                .disabled(roomCode.count < 4)

            Button("НАСТРОЙКИ СЕРВЕРА") { serverInput = serverHost; showSettings = true }
                .font(.system(size: 12, design: .monospaced)).foregroundColor(.gray)
            Spacer()
            Text(status).font(.system(size: 11, design: .monospaced)).foregroundColor(.yellow).padding(.bottom, 20)
        }
    }

    var settingsSheet: some View {
        VStack(spacing: 16) {
            Text("Сервер (host:port)").font(.system(size: 14, design: .monospaced)).foregroundColor(.green)
            TextField("48.102.161.53:3000", text: $serverInput)
                .font(.system(size: 14, design: .monospaced)).foregroundColor(.green)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .padding(10).overlay(Rectangle().stroke(Color.green, lineWidth: 1))
            Button("СОХРАНИТЬ") {
                serverHost = serverInput
                showSettings = false
            }.buttonStyle(Btn())
            Spacer()
        }.padding().presentationDetents([.medium])
    }

    var chatView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(roomCode).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(.green)
                    Text("онлайн: \(online) · я: \(myNick)").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                }
                Spacer()
                Button("ВЫЙТИ") { leave() }
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.red)
            }.padding()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { m in row(m) }
                    }.padding(10)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                Button { showPhotoPicker = true } label: { Image(systemName: "paperclip") }
                    .foregroundColor(.green)
                TextField("сообщение...", text: $inputText)
                    .font(.system(size: 14, design: .monospaced)).foregroundColor(.green)
                    .padding(10)
                    .overlay(Rectangle().stroke(Color.green.opacity(0.5), lineWidth: 1))
                if inputText.isEmpty {
                    Button { toggleRecord() } label: {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 26)).foregroundColor(isRecording ? .red : .green)
                    }
                } else {
                    Button("→") { sendText() }.foregroundColor(.green)
                }
            }.padding(8)
            if isRecording {
                Text("запись... \(recordTime)с (до 30)")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.red)
            }
        }
    }

    @ViewBuilder func row(_ m: ChatMessage) -> some View {
        HStack {
            if m.mine { Spacer() }
            VStack(alignment: .leading, spacing: 4) {
                Text(m.username + (m.mine ? " (я)" : ""))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                switch m.type {
                case "image":
                    if let d = Data(base64Encoded: m.text), let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: 220)
                            .onTapGesture { fullscreenImage = img }
                            .contextMenu {
                                Button("Сохранить в галерею") {
                                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                                }
                            }
                    }
                case "voice":
                    Button {
                        player.play(base64: m.text)
                        playingMsgId = m.id
                    } label: {
                        HStack {
                            Image(systemName: playingMsgId == m.id && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            Text("ГС").font(.system(size: 12, design: .monospaced))
                        }
                    }.foregroundColor(.green)
                default:
                    Text(m.text).font(.system(size: 14, design: .monospaced)).foregroundColor(.white)
                }
            }
            .padding(10)
            .background(m.mine ? Color.green.opacity(0.15) : Color.white.opacity(0.08))
            .overlay(Rectangle().stroke(m.mine ? Color.green.opacity(0.4) : Color.gray.opacity(0.3), lineWidth: 1))
            if !m.mine { Spacer() }
        }
    }

    // MARK: Connection
    func join() {
        status = "подключение..."
        let ws = WSClient(host: serverHost)
        socket = ws
        ws.onEvent = { event, data in
            DispatchQueue.main.async { handle(event: event, data: data) }
        }
        ws.connect()
        ws.send(event: "join", data: ["roomCode": roomCode, "username": ""])
        startPing()
    }

    func handle(event: String, data: [String: Any]) {
        switch event {
        case "history":
            myNick = data["username"] as? String ?? myNick
            if let arr = data["messages"] as? [[String: Any]] {
                messages = arr.compactMap { parse($0) }
            }
            status = ""
            screen = .chat
        case "newMessage":
            if let m = parse(data) { messages.append(m) }
        case "userJoined":
            online = data["count"] as? Int ?? online
        case "error":
            status = data["msg"] as? String ?? "ошибка"
        case "closed":
            if screen == .chat { status = "связь потеряна" }
        default: break
        }
    }

    func parse(_ d: [String: Any]) -> ChatMessage? {
        guard let text = d["text"] as? String, let type = d["type"] as? String else { return nil }
        let user = d["username"] as? String ?? "?"
        return ChatMessage(username: user, text: text, type: type, mine: user == myNick)
    }

    func startPing() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            socket?.send(event: "ping", data: [:])
        }
    }

    func leave() {
        socket?.send(event: "leave", data: [:])
        socket?.close()
        socket = nil
        messages = []
        online = 0
        screen = .login
    }

    func sendText() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        socket?.send(event: "send", data: ["text": t, "type": "text"])
        inputText = ""
    }
    func sendImage(_ data: Data) {
        socket?.send(event: "send", data: ["text": data.base64EncodedString(), "type": "image"])
    }
    func sendVoice(_ data: Data) {
        socket?.send(event: "send", data: ["text": data.base64EncodedString(), "type": "voice"])
    }
    func toggleRecord() {
        if isRecording { recorder.stop() } else { recorder.start() }
        isRecording.toggle()
    }
}

// MARK: - Нативный WebSocket клиент (без зависимостей)
class WSClient: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    var onEvent: ((String, [String: Any]) -> Void)?
    private var connected = false

    init(host: String) {
        super.init()
        let h = host.hasPrefix("http") ? host : "http://\(host)"
        let url = URL(string: h)!
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        session = URLSession(configuration: .default)
        task = session?.webSocketTask(with: comps.url!)
    }

    func connect() {
        task?.resume()
        receiveLoop()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg,
                   let d = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let ev = obj["event"] as? String {
                    self.onEvent?(ev, obj["data"] as? [String: Any] ?? [:])
                }
                if !self.connected {
                    self.connected = true
                }
                self.receiveLoop()
            case .failure(let err):
                self.connected = false
                self.onEvent?("closed", ["err": err.localizedDescription])
            }
        }
    }

    func send(event: String, data: [String: Any]) {
        let payload: [String: Any] = ["event": event, "data": data]
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { err in
            if let err = err { self.onEvent?("closed", ["err": err.localizedDescription]) }
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        connected = false
    }
}

// MARK: - Styles
struct Btn: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(.black)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(Color.green)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Recorder
class RecorderHelper: ObservableObject {
    @Published var elapsed = 0
    @Published var finishedData: Data? = nil
    private var rec: AVAudioRecorder?
    private var timer: Timer?
    private let maxSeconds = 30

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)
        session.requestRecordPermission { ok in
            guard ok else { return }
            DispatchQueue.main.async { self._start() }
        }
    }
    private func _start() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        rec = try? AVAudioRecorder(url: url, settings: settings)
        rec?.record()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.elapsed += 1
            if self.elapsed >= self.maxSeconds { self.stop() }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        rec?.stop()
        if let url = rec?.url, let d = try? Data(contentsOf: url) {
            finishedData = d
        }
        try? FileManager.default.removeItem(at: (rec?.url) ?? URL(fileURLWithPath: "/dev/null"))
        rec = nil
    }
}

// MARK: - Player
class PlayerHelper: ObservableObject {
    @Published var isPlaying = false
    private var p: AVAudioPlayer?

    func play(base64: String) {
        if isPlaying, let p = p { p.stop(); isPlaying = false; return }
        guard let d = Data(base64Encoded: base64) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p.m4a")
        try? d.write(to: url)
        p = try? AVAudioPlayer(contentsOf: url)
        p?.play()
        isPlaying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (p?.duration ?? 0)) {
            self.isPlaying = false
        }
    }
}
