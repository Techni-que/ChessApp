import ChessKit
import SwiftUI

/// Draws an 8x8 chessboard with the pieces from a position. White is at the bottom.
struct ChessBoardView: View {
    let position: Position
    /// Show Black at the bottom (used when it's Black's turn in a drill).
    var flipped = false
    var selected: Square?
    /// Squares to tint (for example the squares of a move being shown).
    var highlights: Set<Square> = []
    /// If set, tapping a square calls this (used by drills).
    var onTap: ((Square) -> Void)?

    private let lightSquare = Color(red: 0.93, green: 0.85, blue: 0.71)
    private let darkSquare = Color(red: 0.71, green: 0.53, blue: 0.39)

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height) / 8
            VStack(spacing: 0) {
                ForEach(flipped ? Array(1...8) : Array((1...8).reversed()), id: \.self) { rank in
                    HStack(spacing: 0) {
                        ForEach(flipped ? Array(Square.File.allCases.reversed()) : Array(Square.File.allCases), id: \.self) { file in
                            let square = Square("\(file.rawValue)\(rank)")
                            ZStack {
                                Rectangle()
                                    .fill(square.color == .light ? lightSquare : darkSquare)
                                if square == selected {
                                    Rectangle().fill(Color.yellow.opacity(0.55))
                                } else if highlights.contains(square) {
                                    Rectangle().fill(Color.green.opacity(0.4))
                                }
                                if let piece = position.piece(at: square) {
                                    Text(Self.symbol(for: piece))
                                        .font(.system(size: size * 0.8))
                                        .foregroundStyle(.black)
                                }
                            }
                            .frame(width: size, height: size)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap?(square) }
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Unicode chess symbols, e.g. ♔ for a white king and ♚ for a black king.
    static func symbol(for piece: Piece) -> String {
        switch (piece.color, piece.kind) {
        case (.white, .king): "♔"
        case (.white, .queen): "♕"
        case (.white, .rook): "♖"
        case (.white, .bishop): "♗"
        case (.white, .knight): "♘"
        case (.white, .pawn): "♙"
        case (.black, .king): "♚"
        case (.black, .queen): "♛"
        case (.black, .rook): "♜"
        case (.black, .bishop): "♝"
        case (.black, .knight): "♞"
        case (.black, .pawn): "♟\u{FE0E}"
        }
    }
}
