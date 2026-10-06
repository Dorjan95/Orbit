import Foundation

enum OrbitResources {
  // SwiftPM's generated accessor can fall back to an absolute development path.
  // Prefer the resources packaged inside the distributed macOS app.
  static let bundle = packaged(in: Bundle.main) ?? Bundle.module
  static func packaged(in application: Bundle) -> Bundle? {
    guard let root = application.resourceURL else { return nil }
    return Bundle(url: root.appendingPathComponent("Orbit_OrbitDesktop.bundle"))
  }
}
