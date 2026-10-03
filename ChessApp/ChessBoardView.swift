import ChessKit
import SwiftUI

/// Draws an 8x8 chessboard with the pieces from a position. White is at the bottom.
struct ChessBoardView: View {
    let position: Position

    private let lightSquare = Color(red: 0.93, green: 0.85, blue: 0.71)
    private let darkSquare = Color(red: 0.71, green: 0.53, blue: 0.39)

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height) / 8
            VStack(spacing: 0) {
                ForEach((1...8).reversed(), id: \.self) { rank in
                    HStack(spacing: 0) {
                        ForEach(Square.File.allCases, id: \.self) { file in
                            let square = Square("\(file.rawValue)\(rank)")
                            ZStack {
                                Rectangle()
                                    .fill(square.color == .light ? lightSquare : darkSquare)
                                if let piece = position.piece(at: square) {
                                    Text(Self.symbol(for: piece))
                                        .font(.system(size: size * 0.8))
                                        .foregroundStyle(.black)
                                }
                            }
                            .frame(width: size, height: size)
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
