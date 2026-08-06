import LatticeCore
import SwiftUI

struct ReaderScreen: View {
  @Bindable var model: ReaderModel
  @State private var showPortals = false
  @State private var showGoToPage = false
  @State private var pageText = ""
  @State private var showFindBar = false
  @State private var findText = ""
  @FocusState private var findFocused: Bool

  var body: some View {
    NavigationStack {
      ZStack {
        PDFKitView(
          documentURL: model.openDocumentURL,
          controller: model.pdfController,
          portalOverlay: model.portalOverlay,
          onViewportChanged: { model.viewportChanged() },
          onDocumentReady: { document in
            model.documentDidLoad(document)
            model.applyPendingJumpRestoreIfNeeded()
          }
        )
        .ignoresSafeArea(edges: .bottom)

        if model.captureMode.isActive {
          VStack {
            Text(model.statusMessage ?? "Portal")
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(.ultraThinMaterial, in: Capsule())
            Spacer()
          }
          .padding()
          .allowsHitTesting(false)
        }
      }
      .navigationTitle(model.descriptor?.name ?? "PDF")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            showFindBar = false
            model.closeDocument()
          } label: {
            Label("Home", systemImage: "house")
          }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            model.jumpBack()
          } label: {
            Image(systemName: "chevron.backward")
          }
          .disabled(!model.canGoBack)
          .accessibilityLabel("Jump back")

          Button {
            model.jumpForward()
          } label: {
            Image(systemName: "chevron.forward")
          }
          .disabled(!model.canGoForward)
          .accessibilityLabel("Jump forward")
        }

        ToolbarItemGroup(placement: .bottomBar) {
          Button {
            model.togglePortalCapture()
          } label: {
            PortalPhaseIcon(phase: model.portalIconPhase)
          }
          .accessibilityLabel(portalAccessibilityLabel)
          .accessibilityHint(
            "Press once, drag source, press again, drag destination. Press while dragging to cancel.")

          Button {
            showPortals = true
          } label: {
            Label("Portals", systemImage: "list.bullet")
          }

          Button {
            showFindBar.toggle()
            if showFindBar {
              findFocused = true
            }
          } label: {
            Label("Find", systemImage: "magnifyingglass")
          }

          Spacer()

          Button {
            pageText = ""
            showGoToPage = true
          } label: {
            Text(model.pageLabel.isEmpty ? "—" : model.pageLabel)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .accessibilityLabel("Go to page")
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        if showFindBar {
          findBar
        }
      }
      .sheet(isPresented: $showPortals) {
        PortalsSheet(model: model)
          .presentationDetents([.medium, .large])
      }
      .alert("Go to page", isPresented: $showGoToPage) {
        TextField("Page number", text: $pageText)
          .keyboardType(.numberPad)
        Button("Go") {
          if let page = Int(pageText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            model.goToPage(oneBased: page)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Enter a 1-based page number.")
      }
    }
  }

  private var portalAccessibilityLabel: String {
    switch model.captureMode {
    case .inactive: return "Portal"
    case .source: return "Cancel portal source"
    case .sourcePlaced: return "Start portal destination"
    case .destination: return "Cancel portal destination"
    }
  }

  private var findBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Find", text: $findText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($findFocused)
        .submitLabel(.search)
        .onSubmit { model.find(query: findText) }

      Button {
        model.findAgain(opposite: true)
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(findText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityLabel("Find previous")

      Button {
        if model.hasActiveSearch {
          model.findAgain()
        } else {
          model.find(query: findText)
        }
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(findText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityLabel("Find next")

      Button {
        showFindBar = false
        findFocused = false
        model.clearFind()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .accessibilityLabel("Close find")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
    .onChange(of: findText) { _, newValue in
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        model.clearFind()
      } else {
        model.find(query: trimmed)
      }
    }
  }
}

private struct PortalsSheet: View {
  @Bindable var model: ReaderModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      let entries = model.portalEntriesForCurrentDocument()
      Group {
        if entries.isEmpty {
          ContentUnavailableView(
            "No portals in this PDF",
            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
            description: Text("Create a portal, then jump to it here.")
          )
        } else {
          List(entries) { entry in
            Button {
              model.goToPortal(id: entry.portalID)
              dismiss()
            } label: {
              Text("Page \(entry.anchor.pageIndex + 1)")
                .foregroundStyle(.primary)
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Portals")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
