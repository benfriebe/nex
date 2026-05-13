@testable import Nex
import Testing

struct WindowSpacesBindingTests {
    private let bundleID = "com.benfriebe.nex"

    @Test func emptyBindingsReturnsFalse() {
        #expect(!WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: []
        ))
    }

    @Test func bundleAbsentReturnsFalse() {
        #expect(!WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: ["com.apple.dock", "com.example.other"]
        ))
    }

    @Test func exactBundleMatchReturnsTrue() {
        #expect(WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: [bundleID]
        ))
    }

    @Test func bundleWithSpaceSuffixReturnsFalse() {
        #expect(!WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: ["\(bundleID) space:11111111-2222-3333-4444-555555555555"]
        ))
    }

    @Test func bundleWithDisplayOnlySuffixReturnsTrue() {
        // "<bundle> display:UUID" with no space: segment means the user
        // picked "All Desktops" alongside a monitor pin. Still all
        // desktops semantically, so we should apply .canJoinAllSpaces.
        #expect(WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: ["\(bundleID) display:abcdef01-2345-6789-abcd-ef0123456789"]
        ))
    }

    @Test func bundleWithCombinedSuffixReturnsFalse() {
        #expect(!WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: ["\(bundleID) space:aaa display:bbb"]
        ))
    }

    @Test func longerBundleStringPrefixDoesNotMatch() {
        // Regression guard: a different bundle ID like "<our>.helper"
        // must not match. The matcher requires either an exact match
        // or a space separator before any suffix; do not weaken to
        // substring checks.
        #expect(!WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: [
                "\(bundleID).helper",
                "\(bundleID).helper display:abc"
            ]
        ))
    }

    @Test func mixedEntriesWithOurBundlePresentReturnsTrue() {
        #expect(WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: [
                "com.apple.dock",
                "com.example.other space:foo",
                bundleID,
                "com.example.third"
            ]
        ))
    }

    @Test func mixedEntriesWithOnlySuffixedOurBundleReturnsFalse() {
        #expect(!WindowSpacesBinding.isAssignedToAllDesktops(
            bundleID: bundleID,
            bindings: [
                "com.apple.dock",
                "\(bundleID) space:foo",
                "com.example.third"
            ]
        ))
    }
}
