import SwiftUI

@main
struct LatticeApp: App {
  @State private var model = ReaderModel()

  var body: some Scene {
    WindowGroup {
      Group {
        if model.isReading {
          ReaderScreen(model: model)
        } else {
          RecentsHomeView(model: model)
        }
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
