import SwiftUI
import RealityKit
import QuickLook

/// Single-object scans: Apple's guided Object Capture orbit, reconstructed on device.
/// Separate from houses (no house.json, no house-capture/5 bundle):
///
///     Documents/Objects/<name yyyy-MM-dd HH.mm.ss>/
///       object.json      name, createdAt
///       Images/          the capture's HEIC photos (depth + gravity embedded); feed this folder
///                        to PhotogrammetrySession on a Mac for .full or .raw detail
///       model.usdz       textured model reconstructed on the phone
///
/// The capture checkpoint (speeds up on-device reconstruction) lives in
/// Application Support/ObjectCheckpoints/<folder>, out of the Files app.
struct ObjectScan: Identifiable, Hashable {
  struct Info: Codable, Hashable {
    var name: String
    var createdAt: Date
  }

  let url: URL
  var info: Info
  var id: String { url.lastPathComponent }
  var name: String { info.name }
  var images: URL { url.appendingPathComponent("Images", isDirectory: true) }
  var model: URL { url.appendingPathComponent("model.usdz") }
  var checkpoint: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ObjectCheckpoints", isDirectory: true)
      .appendingPathComponent(id, isDirectory: true)
  }
  var hasModel: Bool { FileManager.default.fileExists(atPath: model.path) }

  var imageFiles: [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? []
    return files.filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  static var root: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Objects", isDirectory: true)
  }

  static func all() -> [ObjectScan] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.compactMap { load($0) }.sorted { $0.info.createdAt > $1.info.createdAt }
  }

  static func load(_ url: URL) -> ObjectScan? {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: url.appendingPathComponent("object.json")),
          let info = try? decoder.decode(Info.self, from: data) else { return nil }
    return ObjectScan(url: url, info: info)
  }

  static func create(name: String) throws -> ObjectScan {
    let fm = FileManager.default
    let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let now = Date()
    let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let scan = ObjectScan(url: root.appendingPathComponent("\(safe) \(stamp.string(from: now))", isDirectory: true),
                          info: Info(name: name, createdAt: now))
    try fm.createDirectory(at: scan.images, withIntermediateDirectories: true)
    try fm.createDirectory(at: scan.checkpoint, withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(scan.info).write(to: scan.url.appendingPathComponent("object.json"), options: .atomic)
    return scan
  }

  func delete() throws {
    try? FileManager.default.removeItem(at: checkpoint)
    try FileManager.default.removeItem(at: url)
  }

  func thumbnail() async -> UIImage? {
    guard let first = imageFiles.first else { return nil }
    return await UIImage(contentsOfFile: first.path)?.byPreparingThumbnail(ofSize: CGSize(width: 240, height: 240))
  }
}

// MARK: - Library

struct ObjectsScreen: View {
  @State private var scans: [ObjectScan] = []
  @State private var opened: ObjectScan?
  @State private var reconstructOnOpen = false
  @State private var capturing: ObjectCaptureModel?
  @State private var naming = false
  @State private var newName = ""
  @State private var error: String?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          FieldworkEyebrow(text: "Single objects")
          Text("Objects").font(.largeTitle.weight(.bold)).tracking(-1)
          Text("Walk around one thing. Get a textured model.").foregroundStyle(Fieldwork.secondary)
        }.padding(.top, 12).padding(.bottom, 28)
        FieldworkRule()
        if scans.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "cube.transparent").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(Fieldwork.orange)
            Text("Put the object on a plain surface with room to walk all the way around it, in even light.")
              .foregroundStyle(Fieldwork.secondary)
          }.padding(.vertical, 32)
        }
        ForEach(scans) { scan in
          Button { reconstructOnOpen = false; opened = scan } label: { ObjectRow(scan: scan) }.buttonStyle(.plain)
          FieldworkRule()
        }
        if !ObjectCaptureSession.isSupported {
          Text("Object Capture needs an iPhone or iPad with LiDAR on iOS 17 or later.")
            .font(.footnote).foregroundStyle(Fieldwork.secondary).padding(.vertical, 24)
        }
      }.padding(.horizontal, 24).padding(.bottom, 24)
    }
    .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      Button { newName = ""; naming = true } label: { Label("Scan an object", systemImage: "viewfinder") }
        .buttonStyle(FieldworkButtonStyle()).disabled(!ObjectCaptureSession.isSupported)
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10).background(Fieldwork.paper)
    }
    .navigationDestination(item: $opened) { scan in
      ObjectDetailScreen(scan: scan, reconstructOnAppear: reconstructOnOpen, onDeleted: { opened = nil; reload() })
    }
    .onAppear(perform: reload)
    .alert("Scan an object", isPresented: $naming) {
      TextField("Name", text: $newName)
      Button("Start", action: start)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Name what you're scanning.")
    }
    .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") { error = nil }
    } message: { Text(error ?? "") }
    .fullScreenCover(item: $capturing, onDismiss: reload) { model in
      ObjectCaptureScreen(model: model) { finished in
        capturing = nil
        if finished {
          reload()
          reconstructOnOpen = true
          opened = ObjectScan.load(model.scan.url)
        }
      }
    }
  }

  private func reload() { scans = ObjectScan.all() }

  private func start() {
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    Task {
      do {
        try await CaptureReadiness.prepare()
        let scan = try ObjectScan.create(name: name.isEmpty ? "Object" : name)
        capturing = ObjectCaptureModel(scan: scan)
      } catch { self.error = error.localizedDescription }
    }
  }
}

private struct ObjectRow: View {
  let scan: ObjectScan
  @State private var image: UIImage?
  var body: some View {
    HStack(spacing: 16) {
      ZStack {
        Fieldwork.rule.opacity(0.3)
        if let image { Image(uiImage: image).resizable().scaledToFill() }
        else { Image(systemName: "cube.transparent").foregroundStyle(Fieldwork.secondary) }
      }.frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 4) {
        Text(scan.name).font(.title3.bold())
        Text("\(scan.imageFiles.count) photos · \(scan.hasModel ? "model ready" : "not reconstructed")")
          .font(.footnote).foregroundStyle(Fieldwork.secondary)
        Text(scan.info.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.footnote).foregroundStyle(Fieldwork.secondary)
      }
      Spacer()
      Image(systemName: "arrow.up.right").foregroundStyle(Fieldwork.orange)
    }
    .padding(.vertical, 18).contentShape(Rectangle())
    .task(id: scan.id) { image = await scan.thumbnail() }
  }
}

// MARK: - Detail, reconstruction and sharing

struct ObjectDetailScreen: View {
  let scan: ObjectScan
  var reconstructOnAppear = false
  var onDeleted: () -> Void
  @StateObject private var reconstruction = ObjectReconstruction()
  @State private var preview: URL?
  @State private var sharing: [Any]?
  @State private var zipping = false
  @State private var deleting = false
  @State private var started = false
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        FieldworkEyebrow(text: "Object")
        Text(scan.name).font(.largeTitle.weight(.bold)).tracking(-1)
        Text("\(scan.imageFiles.count) photos · \(scan.info.createdAt.formatted(date: .abbreviated, time: .shortened))")
          .foregroundStyle(Fieldwork.secondary)
        FieldworkRule()
        if reconstruction.running {
          VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: reconstruction.progress).tint(Fieldwork.orange)
            Text("Building the model… \(Int(reconstruction.progress * 100))%").font(.headline)
            Text("Keep this screen open and the phone unlocked. This takes a few minutes.")
              .font(.footnote).foregroundStyle(Fieldwork.secondary)
            Button("Cancel", role: .cancel) { reconstruction.cancel() }.buttonStyle(FieldworkButtonStyle(filled: false))
          }
        } else if hasModel {
          Button { preview = scan.model } label: { Label("View 3D model", systemImage: "cube") }.buttonStyle(FieldworkButtonStyle())
          Button { sharing = [scan.model] } label: { Label("Share model (.usdz)", systemImage: "square.and.arrow.up") }
            .buttonStyle(FieldworkButtonStyle(filled: false))
        } else {
          Text("No model yet.").font(.headline)
          Button { reconstruct() } label: { Label("Build model on this iPhone", systemImage: "cube.transparent") }
            .buttonStyle(FieldworkButtonStyle()).disabled(scan.imageFiles.isEmpty)
        }
        Button { sharePhotos() } label: {
          if zipping { ProgressView() } else { Label("Share photos (.zip)", systemImage: "photo.stack") }
        }.buttonStyle(FieldworkButtonStyle(filled: false)).disabled(zipping || reconstruction.running || scan.imageFiles.isEmpty)
        Text("The phone builds a lighter model. For the most detail, send the photos to a Mac and reconstruct the Images folder there (Reality Composer Pro or PhotogrammetrySession, Full or Raw detail). Both are also in the Files app under 3D Model Anything › Objects.")
          .font(.footnote).foregroundStyle(Fieldwork.secondary)
        if hasModel && !reconstruction.running {
          Button("Rebuild model") { reconstruct() }.font(.footnote).tint(Fieldwork.orange)
        }
        FieldworkRule()
        Button("Delete object", role: .destructive) { deleting = true }.disabled(reconstruction.running)
      }.padding(24)
    }
    .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    .quickLookPreview($preview)
    .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
      ShareSheet(items: sharing ?? [])
    }
    .confirmationDialog("Delete \(scan.name)?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Delete photos and model", role: .destructive) {
        do { try scan.delete(); onDeleted() } catch { self.error = error.localizedDescription }
      }
    }
    .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") { error = nil }
    } message: { Text(error ?? "") }
    .onAppear {
      if reconstructOnAppear && !started && !scan.hasModel { reconstruct() }
    }
    .onDisappear { reconstruction.cancel() }
  }

  private var hasModel: Bool { reconstruction.finished || scan.hasModel }

  private func reconstruct() {
    started = true
    Task {
      do { try await reconstruction.run(scan) } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }

  private func sharePhotos() {
    zipping = true
    let folder = scan.images, name = "\(scan.id) photos"
    Task {
      let result = await Task.detached(priority: .userInitiated) { Result { try FolderZipper.zip(folder, name: name) } }.value
      zipping = false
      switch result {
      case .success(let url): sharing = [url]
      case .failure(let e): error = e.localizedDescription
      }
    }
  }
}

@MainActor final class ObjectReconstruction: ObservableObject {
  @Published var running = false
  @Published var progress = 0.0
  @Published var finished = false
  private var session: PhotogrammetrySession?

  func run(_ scan: ObjectScan) async throws {
    guard !running else { return }
    guard PhotogrammetrySession.isSupported else {
      throw CaptureReadinessError(message: "This device can't build models. Share the photos and reconstruct them on a Mac.")
    }
    running = true; progress = 0; finished = false
    UIApplication.shared.isIdleTimerDisabled = true
    defer { running = false; session = nil; UIApplication.shared.isIdleTimerDisabled = false }
    var config = PhotogrammetrySession.Configuration()
    if FileManager.default.fileExists(atPath: scan.checkpoint.path) { config.checkpointDirectory = scan.checkpoint }
    let session = try PhotogrammetrySession(input: scan.images, configuration: config)
    self.session = session
    // Write next to the final file and swap in, so a cancelled rebuild keeps the old model.
    let partial = scan.url.appendingPathComponent("model-building.usdz")
    try? FileManager.default.removeItem(at: partial)
    // iOS reconstructs at .reduced detail; .full/.raw are Mac-only.
    try session.process(requests: [.modelFile(url: partial, detail: .reduced)])
    for try await output in session.outputs {
      switch output {
      case .requestProgress(_, let fraction): progress = fraction
      case .requestError(_, let error): throw error
      case .processingCancelled: throw CancellationError()
      case .processingComplete:
        let fm = FileManager.default
        guard fm.fileExists(atPath: partial.path) else {
          throw CaptureReadinessError(message: "Reconstruction finished without a model. Try capturing more photos all the way around the object.")
        }
        try? fm.removeItem(at: scan.model)
        try fm.moveItem(at: partial, to: scan.model)
        progress = 1; finished = true
        return
      default: break
      }
    }
  }

  func cancel() { session?.cancel() }
}

// MARK: - Guided capture

@MainActor final class ObjectCaptureModel: ObservableObject, Identifiable {
  let scan: ObjectScan
  @Published private(set) var session: ObjectCaptureSession?
  @Published private(set) var state: ObjectCaptureSession.CaptureState = .initializing
  @Published private(set) var shots = 0
  @Published private(set) var passCompleted = false
  @Published private(set) var passes = 1
  @Published private(set) var hint: String?
  private var poll: Timer?

  init(scan: ObjectScan) { self.scan = scan }

  func start() {
    guard session == nil else { return }
    let session = ObjectCaptureSession()
    self.session = session
    var config = ObjectCaptureSession.Configuration()
    config.checkpointDirectory = scan.checkpoint
    do { try session.start(imagesDirectory: scan.images, configuration: config) } catch { state = .failed(error) }
    poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  private func refresh() {
    guard let session else { return }
    state = session.state
    shots = session.numberOfShotsTaken
    passCompleted = session.userCompletedScanPass
    hint = Self.hint(for: session.feedback)
    if case .completed = state { stopPolling(); self.session = nil } // free the camera before reconstruction
    if case .failed = state { stopPolling() }
  }

  private static func hint(for feedback: Set<ObjectCaptureSession.Feedback>) -> String? {
    for item in feedback {
      switch item {
      case .objectTooClose: return "Move back"
      case .objectTooFar: return "Move closer"
      case .movingTooFast: return "Slow down"
      case .environmentTooDark: return "More light needed"
      case .outOfFieldOfView: return "Aim at the object"
      default: continue
      }
    }
    return nil
  }

  func detect() { _ = session?.startDetecting() }
  func resetDetection() { session?.resetDetection() }
  func capture() { session?.startCapturing() }
  func newPass(flipped: Bool) {
    if flipped { session?.beginNewScanPassAfterFlip() } else { session?.beginNewScanPass() }
    passes += 1
  }
  func finish() { session?.finish() }
  func cancel() {
    stopPolling()
    session?.cancel()
    session = nil
  }
  private func stopPolling() { poll?.invalidate(); poll = nil }
}

struct ObjectCaptureScreen: View {
  @ObservedObject var model: ObjectCaptureModel
  /// true when photos were captured and the scan should be reconstructed
  var onClose: (Bool) -> Void

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if let session = model.session {
        ObjectCaptureView(session: session).ignoresSafeArea()
      }
      VStack(spacing: 12) {
        HStack {
          Button("Cancel") { cancel() }.foregroundStyle(.white).padding(.horizontal, 16).frame(height: 44)
            .background(.black.opacity(0.4), in: Capsule())
          Spacer()
          if case .capturing = model.state {
            Text("\(model.shots) photos · pass \(model.passes)").font(.system(.footnote, design: .monospaced))
              .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 44).background(.black.opacity(0.4), in: Capsule())
          }
        }
        if let hint = model.hint {
          Text(hint).font(.headline).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
            .background(Fieldwork.orange, in: Capsule())
        }
        Spacer()
        controls
      }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    .preferredColorScheme(.dark)
    .onAppear { model.start() }
    .onChange(of: isCompleted) { _, done in if done { onClose(true) } }
  }

  private var isCompleted: Bool { if case .completed = model.state { return true }; return false }

  @ViewBuilder private var controls: some View {
    switch model.state {
    case .initializing:
      ProgressView("Starting camera…").tint(.white).foregroundStyle(.white)
    case .ready:
      instruction("Point at the object, centered in the frame.")
      Button("Find object") { model.detect() }.buttonStyle(FieldworkButtonStyle())
    case .detecting:
      instruction("Drag the box edges to fit the object, then start.")
      HStack {
        Button("Reset") { model.resetDetection() }.buttonStyle(FieldworkButtonStyle(filled: false))
        Button("Start capture") { model.capture() }.buttonStyle(FieldworkButtonStyle())
      }
    case .capturing:
      if model.passCompleted {
        instruction("Pass complete. Another pass at a different height, or flip the object to capture its bottom.")
        HStack {
          Button("Another pass") { model.newPass(flipped: false) }.buttonStyle(FieldworkButtonStyle(filled: false))
          Button("Flip object") { model.newPass(flipped: true) }.buttonStyle(FieldworkButtonStyle(filled: false))
        }
        Button("Finish") { model.finish() }.buttonStyle(FieldworkButtonStyle())
      } else {
        instruction("Walk slowly all the way around the object. Photos are taken automatically.")
        if model.shots >= 20 {
          Button("Finish early") { model.finish() }.buttonStyle(FieldworkButtonStyle(filled: false))
        }
      }
    case .finishing:
      ProgressView("Saving photos…").tint(.white).foregroundStyle(.white)
    case .completed:
      ProgressView().tint(.white)
    case .failed(let error):
      instruction("Capture stopped: \(error.localizedDescription)")
      Button("Close") { cancel() }.buttonStyle(FieldworkButtonStyle())
    @unknown default:
      EmptyView()
    }
  }

  private func instruction(_ text: String) -> some View {
    Text(text).multilineTextAlignment(.center).foregroundStyle(.white).padding(12).frame(maxWidth: .infinity)
      .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
  }

  private func cancel() {
    model.cancel()
    // keep a partial capture only if it has photos to reconstruct
    let keep = !model.scan.imageFiles.isEmpty
    if !keep { try? model.scan.delete() }
    onClose(false)
  }
}
