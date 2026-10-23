import CoreGraphics
import Foundation
import Testing
@testable import myBrowser

@MainActor
struct FavoriteGridLayoutTests {
    @Test func rowsAreBalanced() {
        #expect(FavoriteGridLayout.rowCounts(itemCount: 0, maxPerRow: 4) == [])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 1, maxPerRow: 4) == [1])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 4, maxPerRow: 4) == [4])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 5, maxPerRow: 4) == [3, 2])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 6, maxPerRow: 4) == [3, 3])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 7, maxPerRow: 4) == [4, 3])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 8, maxPerRow: 4) == [4, 4])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 9, maxPerRow: 4) == [3, 3, 3])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 10, maxPerRow: 4) == [4, 3, 3])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 3, maxPerRow: 1) == [1, 1, 1])
        #expect(FavoriteGridLayout.rowCounts(itemCount: 5, maxPerRow: 0) == [1, 1, 1, 1, 1])
    }

    @Test func rowLengthsDifferByAtMostOneAndStayWithinTheCap() {
        for count in 0...24 {
            for maxPerRow in 1...6 {
                let rows = FavoriteGridLayout.rowCounts(itemCount: count, maxPerRow: maxPerRow)
                #expect(rows.reduce(0, +) == count)
                #expect(rows.allSatisfy { $0 >= 1 && $0 <= maxPerRow })
                if let longest = rows.max(), let shortest = rows.min() {
                    #expect(longest - shortest <= 1)
                }
                let expectedRows = count == 0 ? 0 : (count + maxPerRow - 1) / maxPerRow
                #expect(rows.count == expectedRows)
            }
        }
    }

    @Test func widthCapsAtFourAndStillFitsFourAtTheSidebarMinimum() {
        #expect(FavoriteGridLayout.maxPerRow(for: 10_000) == FavoriteGridLayout.columnCap)
        #expect(FavoriteGridLayout.maxPerRow(for: 0) == 1)
        #expect(FavoriteGridLayout.maxPerRow(for: .nan) == 1)

        let four = FavoriteGridLayout.minimumTileWidth * 4 + FavoriteGridLayout.spacing * 3
        #expect(FavoriteGridLayout.maxPerRow(for: four) == 4)
        let two = FavoriteGridLayout.minimumTileWidth * 2 + FavoriteGridLayout.spacing
        #expect(FavoriteGridLayout.maxPerRow(for: two) == 2)

        // Scroll column pads 6pt on each side, plus the leading inset. The narrowest sidebar still holds four.
        let sidebarContent = SidebarMetrics.minWidth - 12 - SidebarMetrics.leadingInset
        #expect(FavoriteGridLayout.maxPerRow(for: sidebarContent) == 4)
    }
}
