import OrbitCore
import RealityKit
import SwiftUI
import simd

struct MotionLibrary: Decodable {
  struct Clip: Decodable {
    struct Framing: Decodable {
      var verticalTan: Double
      var horizontalTan: Double
    }
    let duration: Double
    let frames: [[[Float]]]
    let framing: Framing?
  }
  let fps: Double
  let jointNames: [String]
  let clips: [String: Clip]
  @MainActor static let shared: MotionLibrary? = {
    guard
      let url = Bundle.module.url(
        forResource: "AeroMeshyMotion", withExtension: "json", subdirectory: "Resources"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(MotionLibrary.self, from: data)
  }()
  func clip(for state: MascotState, settings: OrbitCore.Settings) -> String {
    if let name = settings.clips[state.rawValue], clips[name] != nil { return name }
    switch state {
    case .greeting: return "Big_Wave_Hello"
    case .listening: return "Stand_to_Sit_Transition_M"
    case .thinking: return "Sit_Cross_Legged_on_Floor"
    case .working: return "Walking"
    case .success: return "FunnyDancing_03"
    default: return "Wave_One_Hand"
    }
  }
}
@MainActor struct AeroView: NSViewRepresentable {
  let state: MascotState
  let epoch: Date
  let settings: OrbitCore.Settings
  var previewClip: String? = nil
  var scrub: Double? = nil
  func makeNSView(context: Context) -> ARView {
    let view = ARView(frame: .zero)
    view.environment.background = .color(.clear)
    context.coordinator.install(view)
    context.coordinator.update(self)
    return view
  }
  func updateNSView(_ view: ARView, context: Context) { context.coordinator.update(self) }
  func makeCoordinator() -> Animator { Animator() }
  static func dismantleNSView(_ view: ARView, coordinator: Animator) { coordinator.stop() }
  @MainActor final class Animator {
    static var asset: Entity?
    weak var view: ARView?
    var model: ModelEntity?
    var camera = PerspectiveCamera()
    var timer: Timer?
    var input: AeroView?
    var order: [Int] = []
    var current: [Transform] = []
    var source: [Transform] = []
    var transition = Date.distantPast
    var clipName = ""
    var epoch = Date.distantPast
    func install(_ view: ARView) {
      self.view = view
      let anchor = AnchorEntity(world: .zero)
      view.scene.addAnchor(anchor)
      if Self.asset == nil,
        let url = Bundle.module.url(
          forResource: "AeroMeshy", withExtension: "usdz", subdirectory: "Resources")
      {
        Self.asset = try? Entity.load(contentsOf: url)
      }
      if let entity = Self.asset?.clone(recursive: true) {
        anchor.addChild(entity)
        func find(_ entity: Entity) -> ModelEntity? {
          if let model = entity as? ModelEntity, !model.jointNames.isEmpty { return model }
          for child in entity.children { if let result = find(child) { return result } }
          return nil
        }
        model = find(entity)
        if let model, let library = MotionLibrary.shared {
          order = model.jointNames.map { library.jointNames.firstIndex(of: $0) ?? -1 }
          current = model.jointTransforms
        }
      }
      camera.look(
        at: SIMD3<Float>(0, 0.97, 0), from: SIMD3<Float>(-0.65, 1.05, 4.7), relativeTo: nil)
      camera.camera.fieldOfViewInDegrees = 30
      anchor.addChild(camera)
      let key = DirectionalLight()
      key.light.intensity = 2500
      key.look(at: .zero, from: SIMD3<Float>(-3, 5, 5), relativeTo: nil)
      anchor.addChild(key)
      let rim = PointLight()
      rim.light.color = NSColor(calibratedRed: 0.72, green: 1, blue: 0.25, alpha: 1)
      rim.light.intensity = 600
      rim.position = [2, 2, -2]
      anchor.addChild(rim)
      timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }
    }
    func update(_ input: AeroView) {
      self.input = input
      guard let library = MotionLibrary.shared else { return }
      let name = input.previewClip ?? library.clip(for: input.state, settings: input.settings)
      if name != clipName || epoch != input.epoch {
        source = current
        transition = Date()
        clipName = name
        epoch = input.epoch
      }
      tick()
    }
    func tick() {
      guard let input, let library = MotionLibrary.shared, let clip = library.clips[clipName],
        !clip.frames.isEmpty, let model
      else { return }
      let motion =
        input.settings.mascotMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      let elapsed = max(0, Date().timeIntervalSince(input.epoch))
      let standing =
        input.previewClip == nil
        && library.clips[input.settings.clips[input.state.rawValue] ?? ""] == nil
        && [.ready, .responding, .question, .problem].contains(input.state)
      let looping = input.previewClip == nil && input.state == .working
      let time: Double
      if !motion {
        time = standing || looping ? 0 : clip.duration
      } else if let scrub = input.scrub {
        time = min(clip.duration, max(0, scrub))
      } else if standing {
        time = 0
      } else {
        time =
          looping && clip.duration > 0
          ? elapsed.truncatingRemainder(dividingBy: clip.duration) : min(elapsed, clip.duration)
      }
      let frame = min(Double(clip.frames.count - 1), time * library.fps)
      let a = Int(frame)
      let b = min(a + 1, clip.frames.count - 1)
      let fraction = Float(frame - Double(a))
      func transform(_ numbers: [Float]) -> Transform {
        guard numbers.count == 10 else { return Transform() }
        return Transform(
          scale: SIMD3(numbers[7], numbers[8], numbers[9]),
          rotation: simd_quatf(ix: numbers[3], iy: numbers[4], iz: numbers[5], r: numbers[6]),
          translation: SIMD3(numbers[0], numbers[1], numbers[2]))
      }
      func mix(_ a: Transform, _ b: Transform, _ weight: Float) -> Transform {
        Transform(
          scale: a.scale + (b.scale - a.scale) * weight,
          rotation: simd_slerp(a.rotation, b.rotation, weight),
          translation: a.translation + (b.translation - a.translation) * weight)
      }
      let blend = motion ? Float(min(1, Date().timeIntervalSince(transition) / 0.18)) : 1
      current = order.enumerated().map { index, joint in
        guard joint >= 0, joint < clip.frames[a].count else {
          return index < current.count ? current[index] : Transform()
        }
        let target = mix(
          transform(clip.frames[a][joint]), transform(clip.frames[b][joint]), fraction)
        return blend < 1 && index < source.count ? mix(source[index], target, blend) : target
      }
      model.jointTransforms = current
      if let framing = clip.framing, let view, view.bounds.height > 0 {
        let aspect = max(0.4, view.bounds.width / view.bounds.height)
        let fov =
          2 * atan(max(framing.verticalTan, framing.horizontalTan / aspect)) * 180 / Double.pi
        camera.camera.fieldOfViewInDegrees = Float(min(75, max(24, fov)))
      }
    }
    func stop() {
      timer?.invalidate()
      timer = nil
    }
  }
}
struct MascotView: View {
  @Bindable var controller: OrbitController
  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        if let symbol = controller.phase.symbol {
          Image(systemName: symbol).font(.system(size: 27, weight: .bold)).foregroundStyle(
            controller.phase == .problem ? .orange : Palette.accent
          ).shadow(color: .black.opacity(0.5), radius: 5)
        }
      }.frame(height: 38)
      AeroView(
        state: controller.phase, epoch: controller.animationEpoch, settings: controller.settings
      ).frame(height: controller.settings.mascotHeight)
      if controller.settings.mascotCaption
        || [.listening, .question, .problem].contains(controller.phase)
      {
        Text(controller.phase.message).font(.system(size: 12, weight: .semibold))
          .multilineTextAlignment(.center).padding(.horizontal, 12).padding(.vertical, 7)
          .background(.black.opacity(0.86), in: Capsule()).foregroundStyle(.white).frame(height: 40)
      } else {
        Color.clear.frame(height: 40)
      }
    }.frame(width: max(190, controller.settings.mascotHeight * 0.9)).contentShape(Rectangle())
      .onTapGesture { controller.beginListening() }
      .accessibilityLabel("Aero, \(controller.phase.title). Premi per parlare con Orbit.")
  }
}
