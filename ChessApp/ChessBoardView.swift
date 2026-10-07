import ChessKit
import SwiftUI

/// An arrow drawn on the board from one square to another (used to show a move).
struct BoardArrow: Hashable {
    let from: Square
    let to: Square
}

/// Draws an 8x8 chessboard with the pieces from a position. White is at the bottom.
struct ChessBoardView: View {
    let position: Position
    /// Show Black at the bottom (used when it's Black's turn in a drill).
    var flipped = false
    var selected: Square?
    /// Squares to tint (for example the squares of a move being shown).
    var highlights: Set<Square> = []
    /// Squares you have picked yourself (shown in yellow).
    var marks: Set<Square> = []
    /// The squares of the opponent's last move (shown in orange).
    var lastMove: Set<Square> = []
    /// Arrows to draw on top of the pieces.
    var arrows: [BoardArrow] = []
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
                                if lastMove.contains(square) {
                                    Rectangle().fill(Color.orange.opacity(0.45))
                                }
                                if square == selected || marks.contains(square) {
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
        .overlay {
            Canvas { context, canvasSize in
                let square = canvasSize.width / 8
                func center(_ s: Square) -> CGPoint {
                    let file = s.file.number - 1
                    let rank = s.rank.value - 1
                    let column = flipped ? 7 - file : file
                    let row = flipped ? rank : 7 - rank
                    return CGPoint(x: (CGFloat(column) + 0.5) * square, y: (CGFloat(row) + 0.5) * square)
                }
                let color = Color(red: 0.1, green: 0.55, blue: 0.2).opacity(0.9)
                for arrow in arrows {
                    let start = center(arrow.from)
                    let end = center(arrow.to)
                    let dx = end.x - start.x, dy = end.y - start.y
                    let length = max((dx * dx + dy * dy).squareRoot(), 1)
                    let ux = dx / length, uy = dy / length
                    let head = square * 0.42
                    let neck = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
                    var line = Path()
                    line.move(to: start)
                    line.addLine(to: neck)
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: square * 0.16, lineCap: .round))
                    var tip = Path()
                    tip.move(to: end)
                    tip.addLine(to: CGPoint(x: neck.x - uy * head * 0.55, y: neck.y + ux * head * 0.55))
                    tip.addLine(to: CGPoint(x: neck.x + uy * head * 0.55, y: neck.y - ux * head * 0.55))
                    tip.closeSubpath()
                    context.fill(tip, with: .color(color))
                }
            }
            .allowsHitTesting(false)
        }
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
