import SwiftUI

@main
struct LatticeApp: App {
  @State private var model = ReaderModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      Group {
        if model.isReading {
          ReaderScreen(model: model)
        } else {
          RecentsHomeView(model: model)
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { model.saveReadingPositionNow() }
      }
      .alert("Error", isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
    }
  }
}
