import Foundation
@testable import Nex
import Testing

struct GitServiceTests {
    // MARK: - parseShortstat

    @Test func emptyShortstatReturnsZeros() {
        let (a, d) = parseShortstat("")
        #expect(a == 0)
        #expect(d == 0)
    }

    @Test func shortstatWithBothInsertionsAndDeletions() {
        let (a, d) = parseShortstat(" 3 files changed, 27 insertions(+), 12 deletions(-)")
        #expect(a == 27)
        #expect(d == 12)
    }

    @Test func shortstatWithOnlyInsertions() {
        let (a, d) = parseShortstat(" 1 file changed, 5 insertions(+)")
        #expect(a == 5)
        #expect(d == 0)
    }

    @Test func shortstatWithOnlyDeletions() {
        let (a, d) = parseShortstat(" 1 file changed, 3 deletions(-)")
        #expect(a == 0)
        #expect(d == 3)
    }

    @Test func shortstatPureRenameHasZeroLines() {
        // Pure rename / mode change emits no insertion/deletion clauses.
        let (a, d) = parseShortstat(" 1 file changed")
        #expect(a == 0)
        #expect(d == 0)
    }

    @Test func shortstatSingularInsertionForm() {
        // git uses "1 insertion(+)" (singular) for one-line changes.
        let (a, d) = parseShortstat(" 1 file changed, 1 insertion(+), 1 deletion(-)")
        #expect(a == 1)
        #expect(d == 1)
    }
}
