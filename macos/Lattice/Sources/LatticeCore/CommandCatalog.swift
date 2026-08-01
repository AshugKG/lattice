import Foundation

public struct CommandDescriptor: Equatable, Sendable {
  public let name: String
  public let aliases: [String]
  public let summary: String
  public let shortcut: String?
  public let action: ReaderCommand

  public init(
    name: String,
    aliases: [String] = [],
    summary: String,
    shortcut: String? = nil,
    action: ReaderCommand
  ) {
    self.name = name
    self.aliases = aliases
    self.summary = summary
    self.shortcut = shortcut
    self.action = action
  }
}

public enum CommandCatalog {
  public static let commands: [CommandDescriptor] = [
    .init(name: "marks", summary: "List marks in this PDF", action: .showMarks),
    .init(
      name: "open", aliases: ["edit", "e"], summary: "Open a PDF", shortcut: "o", action: .open),
    .init(
      name: "find", aliases: ["search"], summary: "Search this PDF", shortcut: "⌘F", action: .find),
    .init(
      name: "mark", summary: "Create a mark", shortcut: "m",
      action: .captureMark),
    .init(name: "back", summary: "Jump backward", shortcut: "⌃O", action: .jumpBackward),
    .init(name: "forward", summary: "Jump forward", shortcut: "⌃I", action: .jumpForward),
    .init(
      name: "first", aliases: ["top"], summary: "Go to the first page", shortcut: "gg",
      action: .documentStart),
    .init(
      name: "last", aliases: ["bottom"], summary: "Go to the last page", shortcut: "G",
      action: .documentEnd),
    .init(
      name: "previous", aliases: ["prev"], summary: "Go to the previous page", shortcut: "[",
      action: .previousPage),
    .init(name: "next", summary: "Go to the next page", shortcut: "]", action: .nextPage),
    .init(name: "up", summary: "Scroll up", shortcut: "k", action: .scrollUp),
    .init(name: "down", summary: "Scroll down", shortcut: "j", action: .scrollDown),
    .init(name: "left", summary: "Scroll left", shortcut: "h", action: .scrollLeft),
    .init(name: "right", summary: "Scroll right", shortcut: "l", action: .scrollRight),
    .init(name: "halfup", summary: "Move half a screen up", shortcut: "⌃U", action: .halfUp),
    .init(name: "halfdown", summary: "Move half a screen down", shortcut: "⌃D", action: .halfDown),
    .init(
      name: "fit", aliases: ["fitwidth"], summary: "Fit the PDF to the window", shortcut: "0",
      action: .fitWidth),
    .init(name: "zoomin", summary: "Zoom in", shortcut: "+", action: .zoomIn),
    .init(name: "zoomout", summary: "Zoom out", shortcut: "−", action: .zoomOut),
    .init(name: "help", summary: "Show keyboard shortcuts", shortcut: "?", action: .help),
    .init(name: "cancel", summary: "Cancel mark capture", shortcut: "Esc", action: .cancelMark),
    .init(name: "quit", aliases: ["q"], summary: "Quit Lattice", shortcut: "⌘Q", action: .quit),
  ]

  public static func exact(_ query: String) -> CommandDescriptor? {
    let query = normalized(query)
    return commands.first { command in
      command.name == query || command.aliases.contains(query)
    }
  }

  public static func matches(_ query: String) -> [CommandDescriptor] {
    let query = normalized(query)
    guard !query.isEmpty else { return commands }
    return commands.compactMap { command -> (CommandDescriptor, Int)? in
      let candidates =
        [command.name] + command.aliases + [command.summary]
        + (command.shortcut.map { [$0] } ?? [])
      guard let score = candidates.compactMap({ fuzzyScore(query, in: $0) }).max() else {
        return nil
      }
      return (command, score)
    }.sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      return $0.0.name < $1.0.name
    }.map(\.0)
  }

  private static func normalized(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      .lowercased()
  }

  private static func fuzzyScore(_ query: String, in candidate: String) -> Int? {
    let query = Array(query.lowercased())
    let candidate = Array(candidate.lowercased())
    guard !query.isEmpty else { return 0 }
    if query == candidate { return 10_000 }

    var queryIndex = 0
    var score = 0
    var previousMatch: Int?
    for (index, character) in candidate.enumerated() where queryIndex < query.count {
      guard character == query[queryIndex] else { continue }
      score += 10
      if index == 0 { score += 25 }
      if let previousMatch, index == previousMatch + 1 { score += 18 }
      if index > 0, " -_/".contains(candidate[index - 1]) { score += 12 }
      previousMatch = index
      queryIndex += 1
    }
    guard queryIndex == query.count else { return nil }
    return score - max(0, candidate.count - query.count)
  }
}
