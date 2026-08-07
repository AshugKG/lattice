import LatticeCore
import PDFKit
import SwiftUI

struct RecentsHomeView: View {
  @Bindable var model: ReaderModel
  @State private var showImporter = false

  private let columns = [
    GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)
  ]

  var body: some View {
    NavigationStack {
      ZStack(alignment: .bottomTrailing) {
        Group {
          if model.recents.isEmpty {
            ContentUnavailableView {
              Label("Recent PDFs", systemImage: "doc.richtext")
            } description: {
              Text("Open a PDF to start reading. Lattice remembers where you left off.")
            } actions: {
              Button("Open PDF") { showImporter = true }
                .buttonStyle(.borderedProminent)
            }
          } else {
            ScrollView {
              LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.recents) { recent in
                  Button {
                    model.openRecent(recent)
                  } label: {
                    RecentCard(recent: recent)
                  }
                  .buttonStyle(.plain)
                }
              }
              .padding()
              .padding(.bottom, 88)
            }
          }
        }

        if !model.recents.isEmpty {
          Button {
            showImporter = true
          } label: {
            Image(systemName: "folder")
              .font(.title2.weight(.semibold))
              .foregroundStyle(.white)
              .frame(width: 56, height: 56)
              .background(Color.accentColor, in: Circle())
              .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
          }
          .accessibilityLabel("Open PDF")
          .padding(.trailing, 20)
          .padding(.bottom, 20)
        }
      }
      .navigationTitle("Lattice")
      .fileImporter(
        isPresented: $showImporter,
        allowedContentTypes: [.pdf],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          if let url = urls.first {
            model.importAndOpen(from: url)
          }
        case .failure(let error):
          model.errorMessage = error.localizedDescription
        }
      }
      .onAppear { model.reloadHomeData() }
    }
  }
}

private struct RecentCard: View {
  let recent: RecentDocument
  @State private var thumbnail: UIImage?

  private var previewAspect: CGFloat {
    guard let thumbnail, thumbnail.size.height > 0 else { return 3.0 / 4.0 }
    return thumbnail.size.width / thumbnail.size.height
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if let thumbnail {
          Image(uiImage: thumbnail)
            .resizable()
            .scaledToFill()
        } else {
          ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(.secondarySystemBackground))
            Image(systemName: "doc.richtext")
              .font(.largeTitle)
              .foregroundStyle(.secondary)
          }
        }
      }
      .aspectRatio(previewAspect, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color(.separator), lineWidth: 0.5)
      )

      Text(recent.name)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)

      Text("\(recent.pageCount) pages")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .task(id: recent.path) {
      thumbnail = await Self.makeThumbnail(url: recent.url)
    }
  }

  private static func makeThumbnail(url: URL) async -> UIImage? {
    await Task.detached(priority: .utility) {
      guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
        return nil
      }
      let bounds = page.bounds(for: .cropBox)
      guard bounds.height > 0 else { return nil }
      let height: CGFloat = 320
      let width = height * (bounds.width / bounds.height)
      return page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
    }.value
  }
}
