import AppKit
import RealityKit
import SwiftUI
import simd

/// An articulated 3D prototype, constructed as one hierarchy of persistent meshes.
/// Limbs rotate at shoulder/elbow/wrist joints; geometry is never regenerated per frame.
@MainActor final class OrbitAeroRig: OrbitAeroMotionRig {
    let root = Entity()
    let head = Entity()
    let leftShoulder = Entity(), leftElbow = Entity(), leftHand = Entity()
    let rightShoulder = Entity(), rightElbow = Entity(), rightHand = Entity()
    private let leftEye = Entity(), rightEye = Entity()
    private let carbon: PhysicallyBasedMaterial
    private let graphite: PhysicallyBasedMaterial
    private let fabric: PhysicallyBasedMaterial
    private let shell: PhysicallyBasedMaterial
    private let visor: PhysicallyBasedMaterial
    private let lime: UnlitMaterial

    init() {
        carbon = Self.surface(0.035, 0.039, 0.047, metallic: 0.22, roughness: 0.34)
        graphite = Self.surface(0.075, 0.081, 0.093, metallic: 0.30, roughness: 0.40)
        fabric = Self.wovenFabric()
        shell = Self.surface(0.023, 0.027, 0.033, metallic: 0.65, roughness: 0.19)
        visor = Self.surface(0.008, 0.014, 0.02, metallic: 0.8, roughness: 0.12)
        lime = UnlitMaterial(color: NSColor(red: 0.9, green: 1, blue: 0.13, alpha: 1))
        root.name = "OrbitAero_ArticulatedPrototype"
        buildBody()
        buildHelmet()
        buildArm(shoulder: leftShoulder, elbow: leftElbow, hand: leftHand, side: -1)
        buildArm(shoulder: rightShoulder, elbow: rightElbow, hand: rightHand, side: 1)
        apply(elapsed: 0, moving: true)
    }

    func apply(elapsed: TimeInterval, moving: Bool) {
        let pose = OrbitThinkingMotion.sample(at: elapsed, moving: moving)
        applyArm(pose.left, shoulder: leftShoulder, elbow: leftElbow, hand: leftHand,
                 handRotation: simd_quatf(angle: pose.handTurn, axis: [0, 0, 1]))
        applyArm(pose.right, shoulder: rightShoulder, elbow: rightElbow, hand: rightHand,
                 handRotation: simd_quatf(angle: -pose.handTurn * 0.46, axis: [0, 0, 1]))
        head.orientation = simd_quatf(angle: pose.headTilt, axis: [0, 0, 1]) * simd_quatf(angle: -pose.headTilt * 0.7, axis: [0, 1, 0])
        leftEye.position.y = 0.015 + pose.gaze
        rightEye.position.y = 0.015 + pose.gaze
    }

    private func applyArm(_ pose: OrbitThinkingMotion.Arm, shoulder: Entity, elbow: Entity, hand: Entity, handRotation: simd_quatf) {
        shoulder.position = pose.shoulder
        let upper = simd_quatf(from: [0, -1, 0], to: simd_normalize(pose.elbow - pose.shoulder))
        let lower = simd_quatf(from: [0, -1, 0], to: simd_normalize(pose.wrist - pose.elbow))
        shoulder.orientation = upper
        elbow.orientation = upper.inverse * lower
        hand.orientation = lower.inverse * handRotation
    }

    private static func surface(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metallic: Float, roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(red: r, green: g, blue: b, alpha: 1))
        material.metallic = .init(floatLiteral: metallic)
        material.roughness = .init(floatLiteral: roughness)
        material.clearcoat = .init(floatLiteral: metallic > 0.7 ? 0.65 : 0.12)
        return material
    }

    private static func wovenFabric() -> PhysicallyBasedMaterial {
        var material = surface(0.016, 0.018, 0.023, metallic: 0.02, roughness: 0.72)
        // A subtle woven normal map is authored procedurally for the suit material.
        // It does not bake lighting or alter the approved illustration assets.
        let width = 128
        var pixels = [UInt8](repeating: 255, count: width * width * 4)
        for y in 0..<width {
            for x in 0..<width {
                let warp = (x / 8 + y / 8).isMultiple(of: 2)
                let nx = (warp ? Float(0.10) : 0.025) * sin(Float(x) * .pi / 4)
                let ny = (warp ? Float(0.025) : 0.10) * sin(Float(y) * .pi / 4)
                let nz = sqrt(1 - nx * nx - ny * ny)
                let index = (y * width + x) * 4
                pixels[index] = UInt8((nx * 0.5 + 0.5) * 255)
                pixels[index + 1] = UInt8((ny * 0.5 + 0.5) * 255)
                pixels[index + 2] = UInt8((nz * 0.5 + 0.5) * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        if let texture = try? TextureResource.generate(from: image, options: .init(semantic: .normal)) {
            material.normal = .init(texture: .init(texture))
        }
        return material
    }

    @discardableResult private func oval(_ size: SIMD3<Float>, at position: SIMD3<Float>, on parent: Entity,
                                        material: any RealityKit.Material) -> ModelEntity {
        let model = ModelEntity(mesh: .generateSphere(radius: 0.5), materials: [material])
        model.scale = size; model.position = position; parent.addChild(model)
        return model
    }

    private func band(radiusX: Float, radiusY: Float, tube: Float, at position: SIMD3<Float>, on parent: Entity,
                      material: any RealityKit.Material, rotation: simd_quatf = simd_quatf(),
                      start: Float = 0, end: Float = 2 * .pi) {
        let segments = 64, sides = 8
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for i in 0...segments {
            let theta = start + Float(i) * (end - start) / Float(segments)
            let outward = simd_normalize(SIMD3<Float>(cos(theta) / radiusX, sin(theta) / radiusY, 0))
            let center = SIMD3<Float>(radiusX * cos(theta), radiusY * sin(theta), 0)
            for j in 0...sides {
                let phi = Float(j) * 2 * .pi / Float(sides)
                let normal = outward * cos(phi) + SIMD3<Float>(0, 0, 1) * sin(phi)
                positions.append(center + tube * normal); normals.append(normal)
            }
        }
        for i in 0..<segments {
            for j in 0..<sides {
                let a = UInt32(i * (sides + 1) + j), b = a + UInt32(sides + 1)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        var descriptor = MeshDescriptor(name: "Aero trim")
        descriptor.positions = .init(positions); descriptor.normals = .init(normals); descriptor.primitives = .triangles(indices)
        let entity = ModelEntity(mesh: try! .generate(from: [descriptor]), materials: [material])
        entity.position = position; entity.orientation = rotation; parent.addChild(entity)
    }

    /// Smooth suit volumes, shared by torso, sleeves and leg panels.
    private func loft(_ rings: [(Float, Float, Float)], on parent: Entity, material: any RealityKit.Material,
                      name: String) {
        let segments = 64
        var vertices: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        var uv: [SIMD2<Float>] = []
        for (row, ring) in rings.enumerated() {
            let (y, rx, rz) = ring
            let previous = rings[max(0, row - 1)], next = rings[min(rings.count - 1, row + 1)]
            let dx = (next.1 - previous.1) / (next.0 - previous.0)
            let dz = (next.2 - previous.2) / (next.0 - previous.0)
            for i in 0...segments {
                let angle = Float(i) * 2 * .pi / Float(segments)
                vertices.append([rx * cos(angle), y, rz * sin(angle)])
                uv.append([Float(i) / Float(segments) * 2, Float(row) / Float(rings.count - 1) * 2])
                let vertical = -(dx * cos(angle) * cos(angle) / rx + dz * sin(angle) * sin(angle) / rz)
                normals.append(simd_normalize([cos(angle) / rx, vertical, sin(angle) / rz]))
            }
        }
        for row in 0..<(rings.count - 1) {
            for i in 0..<segments {
                let a = UInt32(row * (segments + 1) + i), b = a + UInt32(segments + 1)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = .init(vertices); descriptor.normals = .init(normals)
        descriptor.textureCoordinates = .init(uv)
        descriptor.primitives = .triangles(indices)
        let model = ModelEntity(mesh: try! .generate(from: [descriptor]), materials: [material])
        model.name = name; parent.addChild(model)
    }

    /// Continuous rounded piping over the curved suit and visor, without bead-like segments.
    private func seam(_ anchors: [SIMD3<Float>], radius: Float, on parent: Entity, material: any RealityKit.Material) {
        var points: [SIMD3<Float>] = []
        for i in 0..<(anchors.count - 1) {
            let p0 = anchors[max(0, i - 1)], p1 = anchors[i]
            let p2 = anchors[i + 1], p3 = anchors[min(anchors.count - 1, i + 2)]
            let a: SIMD3<Float> = p1 * 2
            let b: SIMD3<Float> = p2 - p0
            var c: SIMD3<Float> = p0 * 2
            c -= p1 * 5; c += p2 * 4; c -= p3
            var d: SIMD3<Float> = -p0
            d += p1 * 3; d -= p2 * 3; d += p3
            for step in 0..<8 {
                let t = Float(step) / 8
                var point = a + b * t
                point += c * (t * t)
                point += d * (t * t * t)
                points.append(point * 0.5)
            }
        }
        points.append(anchors.last!)
        tube(points, radius: radius, on: parent, material: material)
    }

    private func tube(_ points: [SIMD3<Float>], radius: Float, on parent: Entity, material: any RealityKit.Material) {
        let sides = 10
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for i in points.indices {
            let tangent = simd_normalize(points[min(i + 1, points.count - 1)] - points[max(0, i - 1)])
            let reference: SIMD3<Float> = abs(tangent.z) < 0.95 ? [0, 0, 1] : [0, 1, 0]
            let normal = simd_normalize(simd_cross(tangent, reference))
            let binormal = simd_cross(normal, tangent)
            for side in 0...sides {
                let angle = Float(side) * 2 * .pi / Float(sides)
                let n = normal * cos(angle) + binormal * sin(angle)
                positions.append(points[i] + radius * n); normals.append(n)
            }
        }
        for i in 0..<(points.count - 1) {
            for side in 0..<sides {
                let a = UInt32(i * (sides + 1) + side), b = a + UInt32(sides + 1)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        var descriptor = MeshDescriptor(name: "Aero curved seam")
        descriptor.positions = .init(positions); descriptor.normals = .init(normals); descriptor.primitives = .triangles(indices)
        parent.addChild(ModelEntity(mesh: try! .generate(from: [descriptor]), materials: [material]))
    }

    @discardableResult private func plate(_ size: SIMD3<Float>, at position: SIMD3<Float>, on parent: Entity,
                                         material: any RealityKit.Material, radius: Float = 0.012) -> ModelEntity {
        let model = ModelEntity(mesh: .generateBox(size: size, cornerRadius: radius), materials: [material])
        model.position = position; parent.addChild(model); return model
    }

    private func buildBody() {
        // The hips close into the legs; a fitted waist replaces the prototype's rigid trunk.
        loft([(0.76, 0.055, 0.05), (0.80, 0.13, 0.098), (0.85, 0.16, 0.11),
              (0.90, 0.15, 0.102), (0.96, 0.13, 0.094), (1.02, 0.133, 0.098),
              (1.10, 0.155, 0.116), (1.18, 0.187, 0.13), (1.24, 0.20, 0.132),
              (1.29, 0.19, 0.12), (1.33, 0.14, 0.085), (1.36, 0.077, 0.064)],
             on: root, material: fabric, name: "Aero tailored undersuit")
        oval([0.16, 0.12, 0.14], at: [0, 1.365, 0], on: root, material: fabric)
        band(radiusX: 0.081, radiusY: 0.071, tube: 0.005, at: [0, 1.39, 0], on: root, material: carbon,
             rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        let chest = plate([0.105, 0.135, 0.03], at: [0, 1.21, 0.131], on: root, material: graphite, radius: 0.018)
        chest.orientation = simd_quatf(angle: -0.08, axis: [1, 0, 0])
        for y: Float in [1.177, 1.205, 1.233] {
            plate([0.035, 0.013, 0.008], at: [0, y, 0.151], on: root, material: lime, radius: 0.005)
        }
        for x: Float in [-0.035, 0.035] {
            for y: Float in [1.16, 1.255] {
                oval([0.008, 0.008, 0.004], at: [x, y, 0.15], on: root, material: carbon)
            }
        }
        plate([0.031, 0.008, 0.007], at: [0, 1.315, 0.101], on: root, material: lime, radius: 0.003)
        for side: Float in [-1, 1] {
            // Curved breast plates, flank seams and hip panels follow the approved suit.
            let breast = oval([0.13, 0.22, 0.026], at: [side * 0.102, 1.205, 0.115], on: root, material: carbon)
            breast.orientation = simd_quatf(angle: side * -0.18, axis: [0, 0, 1])
            seam([[side * 0.154, 1.305, 0.091], [side * 0.135, 1.25, 0.135],
                  [side * 0.123, 1.16, 0.141], [side * 0.092, 1.06, 0.107],
                  [side * 0.07, 0.985, 0.101], [side * 0.062, 0.905, 0.106]],
                 radius: 0.005, on: root, material: lime)
            seam([[side * 0.15, 0.913, 0.047], [side * 0.142, 0.865, 0.083],
                  [side * 0.122, 0.823, 0.099], [side * 0.10, 0.785, 0.089]],
                 radius: 0.006, on: root, material: lime)
            let hip: SIMD3<Float> = [side * 0.105, 0.83, 0]
            let knee: SIMD3<Float> = [side * 0.14, 0.46, 0.01]
            let ankle: SIMD3<Float> = [side * 0.16, 0.12, 0]
            // Fuller fabric legs with overlapping guards conceal the old exposed joints.
            segment(from: hip + [0, 0.035, 0], to: knee - [0, 0.035, 0], width: 0.172, depth: 0.164, material: fabric, on: root)
            segment(from: knee + [0, 0.045, 0], to: ankle - [0, 0.005, 0], width: 0.135, depth: 0.137, material: fabric, on: root)
            let thigh = oval([0.14, 0.26, 0.022], at: (hip + knee) / 2 + [side * 0.024, 0.025, 0.068], on: root, material: carbon)
            thigh.orientation = simd_quatf(angle: side * 0.14, axis: [0, 0, 1])
            oval([0.129, 0.134, 0.072], at: knee + [0, 0, 0.067], on: root, material: carbon)
            band(radiusX: 0.058, radiusY: 0.058, tube: 0.005, at: knee + [0, 0, 0.102], on: root, material: lime)
            oval([0.098, 0.11, 0.022], at: knee + [0, 0, 0.107], on: root, material: graphite)
            let shin = oval([0.109, 0.235, 0.049], at: (knee + ankle) / 2 + [0, -0.004, 0.053], on: root, material: carbon)
            shin.orientation = simd_quatf(angle: side * 0.07, axis: [0, 0, 1])
            seam([[side * 0.165, 0.773, 0.06], [side * 0.18, 0.69, 0.072], [side * 0.185, 0.60, 0.068],
                  [side * 0.182, 0.533, 0.065]], radius: 0.004, on: root, material: lime)
            buildBoot(at: ankle, side: side)
        }
    }

    private func buildBoot(at ankle: SIMD3<Float>, side: Float) {
        let boot = Entity(); boot.position = [ankle.x, 0, 0]
        boot.orientation = simd_quatf(angle: side * 0.1, axis: [0, 1, 0]); root.addChild(boot)
        oval([0.178, 0.052, 0.302], at: [0, 0.044, 0.063], on: boot, material: fabric)
        let soleOutline = (0...64).map { i -> SIMD3<Float> in
            let angle = Float(i) * 2 * .pi / 64
            return [0.082 * cos(angle), 0.057, 0.063 + 0.137 * sin(angle)]
        }
        tube(soleOutline, radius: 0.005, on: boot, material: lime)
        oval([0.165, 0.13, 0.264], at: [0, 0.101, 0.068], on: boot, material: carbon)
        oval([0.14, 0.205, 0.155], at: [0, 0.153, -0.012], on: boot, material: carbon)
        oval([0.158, 0.097, 0.145], at: [0, 0.114, 0.147], on: boot, material: graphite)
        for i in 0..<3 {
            let step = Float(i)
            let strap = plate([0.127, 0.023, 0.029], at: [0, 0.174 - step * 0.015, 0.018 + step * 0.036],
                             on: boot, material: carbon, radius: 0.006)
            strap.orientation = simd_quatf(angle: 0.32, axis: [1, 0, 0])
        }
        band(radiusX: 0.068, radiusY: 0.064, tube: 0.005, at: [0, 0.20, -0.012], on: boot, material: lime,
             rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        seam([[side * 0.069, 0.192, -0.013], [side * 0.077, 0.135, 0.043],
              [side * 0.082, 0.089, 0.109]], radius: 0.0035, on: boot, material: lime)
    }

    private func segment(from start: SIMD3<Float>, to end: SIMD3<Float>, width: Float, depth: Float,
                         material: any RealityKit.Material, on parent: Entity) {
        let model = oval([width, simd_distance(start, end), depth], at: (start + end) / 2, on: parent, material: material)
        model.orientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(end - start))
    }

    private func buildHelmet() {
        head.name = "head_joint"; head.position = [0, 1.65, 0]; root.addChild(head)
        oval([0.55, 0.54, 0.49], at: .zero, on: head, material: shell)
        // A curved shield with a tapered chin, not the original flat oval face plate.
        let segments = 96, rows = 24
        var vertices: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        var rim: [SIMD3<Float>] = []
        for row in 0...rows {
            let r = Float(row) / Float(rows)
            for i in 0...segments {
                let theta = Float(i) * 2 * .pi / Float(segments)
                let c = cos(theta), v = sin(theta)
                let x = 0.235 * (c < 0 ? -1 : 1) * pow(abs(c), 0.80) * (1 + 0.10 * min(0, v))
                let y = 0.223 * (v < 0 ? -1 : 1) * pow(abs(v), 0.90)
                let position = SIMD3<Float>(x * r, y * r - 0.016, 0.194 + 0.067 * sqrt(max(0, 1 - r * r)))
                vertices.append(position)
                normals.append(simd_normalize([x * r * 2.2, y * r * 2.2, 0.4]))
                if row == rows { rim.append(position) }
            }
        }
        for row in 0..<rows {
            for i in 0..<segments {
                let a = UInt32(row * (segments + 1) + i), b = a + UInt32(segments + 1)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        var shield = MeshDescriptor(name: "Aero wraparound visor")
        for row in 1...rows {
            for i in 0...segments {
                let index = row * (segments + 1) + i
                let radial = vertices[min(rows, row + 1) * (segments + 1) + i] - vertices[(row - 1) * (segments + 1) + i]
                let angular = vertices[row * (segments + 1) + min(segments, i + 1)] - vertices[row * (segments + 1) + max(0, i - 1)]
                normals[index] = simd_normalize(simd_cross(radial, angular))
            }
        }
        shield.positions = .init(vertices); shield.normals = .init(normals); shield.primitives = .triangles(indices)
        head.addChild(ModelEntity(mesh: try! .generate(from: [shield]), materials: [visor]))
        tube(rim, radius: 0.010, on: head, material: carbon)
        tube(rim.map { $0 + [0, 0, 0.011] }, radius: 0.0055, on: head, material: lime)
        // Twin crown piping stays above the shield, so it never crosses the eyes.
        for side: Float in [-1, 1] {
            seam([[side * 0.13, 0.176, 0.145], [side * 0.119, 0.224, 0.095],
                  [side * 0.10, 0.25, 0.005], [side * 0.085, 0.216, -0.117],
                  [side * 0.085, 0.155, -0.185]], radius: 0.003, on: head, material: lime)
        }
        for side: Float in [-1, 1] {
            let ear = Entity(); ear.position = [side * 0.264, -0.015, -0.012]
            ear.orientation = simd_quatf(angle: side * .pi / 2, axis: [0, 1, 0]); head.addChild(ear)
            oval([0.164, 0.196, 0.065], at: .zero, on: ear, material: carbon)
            band(radiusX: 0.073, radiusY: 0.089, tube: 0.007, at: [0, 0, 0.033], on: ear, material: lime)
            oval([0.115, 0.145, 0.022], at: [0, 0, 0.034], on: ear, material: graphite)
            band(radiusX: 0.04, radiusY: 0.052, tube: 0.004, at: [0, 0, 0.049], on: ear, material: lime)
            oval([0.073, 0.096, 0.014], at: [0, 0, 0.052], on: ear, material: carbon)
        }
        leftEye.position = [-0.077, 0.015, 0.266]; rightEye.position = [0.077, 0.015, 0.266]
        head.addChild(leftEye); head.addChild(rightEye)
        for eye in [leftEye, rightEye] {
            let smile = (0...32).map { i -> SIMD3<Float> in
                let theta = Float(i) * .pi / 32
                return [0.041 * cos(theta), -0.068 + 0.039 * sin(theta), 0]
            }
            tube(smile, radius: 0.010, on: eye, material: lime)
            let core = UnlitMaterial(color: NSColor(red: 1, green: 1, blue: 0.47, alpha: 1))
            tube(smile.map { $0 + [0, 0, 0.007] }, radius: 0.006, on: eye, material: core)
            for point in [smile.first!, smile.last!] { oval([0.018, 0.018, 0.018], at: point, on: eye, material: lime) }
        }
    }

    private func buildArm(shoulder: Entity, elbow: Entity, hand: Entity, side: Float) {
        shoulder.name = side < 0 ? "left_shoulder_joint" : "right_shoulder_joint"
        elbow.name = "elbow_joint"; hand.name = "wrist_joint"
        root.addChild(shoulder); shoulder.addChild(elbow); elbow.addChild(hand)
        elbow.position = [0, -OrbitThinkingMotion.upperArm, 0]
        hand.position = [0, -OrbitThinkingMotion.forearm, 0]
        oval([0.137, 0.14, 0.135], at: [0, -0.01, 0], on: shoulder, material: fabric)
        loft([(-0.30, 0.047, 0.046), (-0.26, 0.05, 0.051), (-0.19, 0.062, 0.06),
              (-0.10, 0.068, 0.065), (-0.035, 0.071, 0.067), (0.018, 0.056, 0.051)],
             on: shoulder, material: fabric, name: "Aero fitted sleeve")
        oval([0.164, 0.133, 0.103], at: [side * 0.012, -0.034, 0.043], on: shoulder, material: carbon)
        band(radiusX: 0.073, radiusY: 0.055, tube: 0.005, at: [side * 0.012, -0.034, 0.088], on: shoulder,
             material: lime, start: .pi * 0.08, end: .pi * 1.23)
        oval([0.11, 0.105, 0.113], at: .zero, on: elbow, material: fabric)
        for y: Float in [-0.033, -0.012, 0.01] {
            band(radiusX: 0.052, radiusY: 0.05, tube: 0.005, at: [0, y, 0], on: elbow, material: carbon,
                 rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        }
        loft([(-0.275, 0.034, 0.034), (-0.24, 0.041, 0.041), (-0.19, 0.052, 0.047),
              (-0.11, 0.058, 0.053), (-0.045, 0.054, 0.049), (0.01, 0.045, 0.043)],
             on: elbow, material: fabric, name: "Aero forearm sleeve")
        let guardPlate = oval([0.097, 0.185, 0.044], at: [0, -0.133, 0.045], on: elbow, material: carbon)
        guardPlate.orientation = simd_quatf(angle: side * -0.09, axis: [0, 0, 1])
        seam([[side * 0.035, -0.055, 0.045], [side * 0.04, -0.12, 0.066],
              [side * 0.028, -0.205, 0.049]], radius: 0.004, on: elbow, material: lime)
        band(radiusX: 0.041, radiusY: 0.039, tube: 0.005, at: [0, -0.238, 0], on: elbow, material: lime,
             rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        oval([0.079, 0.05, 0.063], at: [0, -0.007, 0], on: hand, material: carbon)
        oval([0.085, 0.09, 0.055], at: [0, -0.043, 0], on: hand, material: fabric)
        oval([0.07, 0.062, 0.014], at: [0, -0.041, -0.025], on: hand, material: carbon)
        for finger in 0..<4 {
            let x = Float(finger) * 0.019 - 0.0285
            let length: Float = finger == 0 || finger == 3 ? 0.055 : 0.068
            oval([0.019, length, 0.022], at: [x, -0.095, 0.008], on: hand, material: fabric)
            oval([0.019, 0.025, 0.023], at: [x, -0.092 - length * 0.25, 0.007], on: hand, material: carbon)
            oval([0.018, 0.022, 0.017], at: [x, -0.073, -0.016], on: hand, material: carbon)
        }
        let thumb = oval([0.029, 0.060, 0.026], at: [side * 0.041, -0.052, 0.019], on: hand, material: fabric)
        thumb.orientation = simd_quatf(angle: side * -0.55, axis: [0, 0, 1])
    }

}

struct OrbitAero3DView: NSViewRepresentable {
    var elapsed: TimeInterval
    var moving: Bool

    @MainActor final class Coordinator {
        let rig: any OrbitAeroMotionRig
        init() {
            do { rig = try OrbitBlenderAeroRig() }
            catch {
                NSLog("Orbit: impossibile caricare Aero da Blender: %@", String(describing: error))
                rig = OrbitAeroRig()
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(.clear)
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(context.coordinator.rig.root)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 27
        camera.look(at: [0, 0.94, 0], from: [-0.75, 1.18, 4.65], relativeTo: nil)
        anchor.addChild(camera)
        for (position, intensity): (SIMD3<Float>, Float) in [([-2, 3, 3], 2000), ([2, 1.5, 2], 850), ([1, 2, -2], 1700)] {
            let light = DirectionalLight()
            light.light.color = .white; light.light.intensity = intensity
            light.look(at: [0, 1, 0], from: position, relativeTo: nil); anchor.addChild(light)
        }
        view.scene.addAnchor(anchor)
        context.coordinator.rig.apply(elapsed: elapsed, moving: moving)
        return view
    }
    func updateNSView(_ view: ARView, context: Context) { context.coordinator.rig.apply(elapsed: elapsed, moving: moving) }
    static func dismantleNSView(_ view: ARView, coordinator: Coordinator) { view.scene.anchors.removeAll() }
}
