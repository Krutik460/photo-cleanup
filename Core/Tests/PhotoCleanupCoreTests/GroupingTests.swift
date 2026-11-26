import XCTest
@testable import PhotoCleanupCore

/// Grouping on small made-up libraries. Capture times are EXIF-style (wall clock stored as UTC), so
/// the results do not depend on the machine's time zone.
final class GroupingTests: XCTestCase {
    let home = (lat: 40.70, lon: -74.00)
    let seattle = (lat: 47.60, lon: -122.33)
    let philly = (lat: 39.95, lon: -75.16)

    /// Seconds since 1970 for a day of October 2026 at a time of day.
    func at(_ day: Int, _ hour: Double = 12) -> Double {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!.timeIntervalSince1970 + hour * 3600
    }

    func photo(_ id: String, _ time: Double, gps: (lat: Double, lon: Double)? = nil, rel: String? = nil, faces: [Double?] = [],
               me: Bool = false, aesthetic: Double = 0.2, sharpness: Double = 400, utility: Bool = false) -> GroupingPhoto {
        GroupingPhoto(id: id, rel: rel ?? "\(id).jpg", time: time, timeKnown: true, width: 4000, height: 3000, size: 2_000_000,
                      faceQualities: faces, meFace: me ? 0 : nil, aesthetic: aesthetic, sharpness: sharpness, utility: utility, gps: gps, me: me)
    }

    /// A library with a home, quiet days, a birthday at home, a trip and a day trip.
    func library() -> [GroupingPhoto] {
        var ps: [GroupingPhoto] = []
        for day in [1, 2, 3, 5, 6, 7, 8] { ps.append(photo("home\(day)", at(day), gps: home)) }
        for i in 0..<22 { ps.append(photo("party\(i)", at(10, 18 + Double(i) / 60), gps: home)) }
        for day in 16...18 { for i in 0..<3 { ps.append(photo("sea\(day)-\(i)", at(day, 10 + Double(i)), gps: seattle)) } }
        for i in 0..<4 { ps.append(photo("phl\(i)", at(24, 11 + Double(i) / 4), gps: philly)) }
        return ps
    }

    func group(_ photos: [GroupingPhoto], _ pairs: [(String, String, Double)] = [], edits: GroupingEdits = GroupingEdits(), knowsYou: Bool = false) -> GroupingResult {
        groupPhotos(photos, neighbors: pairs.map { (a: $0.0, b: $0.1, distance: $0.2) }, edits: edits, knowsYou: knowsYou, timeZone: TimeZone(identifier: "UTC")!)
    }

    func collection(_ r: GroupingResult, holding id: String) -> GroupedCollection {
        r.collections.first { $0.members.contains(id) }!
    }

    func testTimelineBecomesEverydayEventTripAndDayTrip() {
        let r = group(library())
        XCTAssertEqual(r.collections.map(\.kind), [.everyday, .event, .trip, .daytrip])
        XCTAssertEqual(r.collections.map(\.members.count), [7, 22, 9, 4])
        XCTAssertEqual(collection(r, holding: "sea16-0").days, 3)
        XCTAssertEqual(collection(r, holding: "sea16-0").homeKm, 3867)
        XCTAssertEqual(r.home ?? [], [40.7, -74.0])
        XCTAssertEqual(r.order.first, "home1")
        XCTAssertEqual(Set(r.photos.values.map(\.collection)), Set(r.collections.map(\.id)))
    }

    func testAFolderOfYoursIsOneCollectionWhateverItsPhotosLookLike() {
        // Half of the Seattle trip and two quiet days sit in folders; the rest lies loose.
        var ps = library()
        for i in ps.indices {
            if ps[i].id.hasPrefix("sea16") || ps[i].id.hasPrefix("sea17") { ps[i].folder = "Seattle" }
            if ps[i].id == "home2" || ps[i].id == "home7" { ps[i].folder = "Keepsakes" }
        }
        let r = group(ps)
        let seattle = collection(r, holding: "sea16-0"), keepsakes = collection(r, holding: "home2")
        XCTAssertEqual([seattle.sourceFolder, seattle.kind.rawValue, String(seattle.members.count)], ["Seattle", "trip", "6"])
        XCTAssertEqual([keepsakes.sourceFolder, keepsakes.kind.rawValue], ["Keepsakes", "everyday"])
        XCTAssertEqual(Set(keepsakes.members), ["home2", "home7"])
        // The loose photos are grouped as if the folders were not there.
        let loose = r.collections.filter { $0.sourceFolder == nil }
        XCTAssertEqual(loose.map(\.kind), [.everyday, .event, .daytrip, .daytrip])
        XCTAssertEqual(loose.map(\.members.count), [5, 22, 3, 4])
        // An event in that month that is not one folds into the loose month, never into your folder.
        let edited = group(ps, edits: GroupingEdits(notCollections: [["party0", "party1"]]))
        XCTAssertEqual(collection(edited, holding: "party0").members.count, 27)
        XCTAssertEqual(Set(collection(edited, holding: "home2").members), ["home2", "home7"])
        // Without folders nothing changes.
        XCTAssertTrue(group(library()).collections.allSatisfy { $0.sourceFolder == nil })
    }

    func testMergeJoinsCollectionsAndCountsItsParts() {
        let before = group(library())
        let trip = collection(before, holding: "sea16-0").members, day = collection(before, holding: "phl0").members
        let r = group(library(), edits: GroupingEdits(merges: [[trip, day]]))
        let merged = collection(r, holding: "sea16-0")
        XCTAssertEqual(merged.members.count, 13)
        XCTAssertEqual(merged.parts, 2)
        XCTAssertEqual(merged.kind, .trip)
        XCTAssertEqual(r.collections.count, 3)
    }

    func testAMergeSurvivesAPhotoThatDriftedIntoAnotherCollection() {
        // A trip photo lost its GPS on a rescan and now sits in the everyday month: the merge pulls
        // that one photo back without dragging the month along.
        let before = group(library())
        let trip = collection(before, holding: "sea16-0").members, day = collection(before, holding: "phl0").members
        var photos = library()
        let i = photos.firstIndex { $0.id == "sea17-1" }!
        photos[i].gps = nil
        photos[i].time = at(20)
        XCTAssertEqual(collection(group(photos), holding: "sea17-1").kind, .everyday)

        let r = group(photos, edits: GroupingEdits(merges: [[trip, day]]))
        XCTAssertEqual(collection(r, holding: "sea17-1").members.count, 13)
        XCTAssertEqual(collection(r, holding: "home1").members.count, 7)
    }

    func testNotAnEventFoldsIntoItsMonthAndIsRemembered() {
        let before = group(library())
        let party = collection(before, holding: "party0").members
        let r = group(library(), edits: GroupingEdits(notCollections: [party]))
        let month = collection(r, holding: "party0")
        XCTAssertEqual(month.kind, .everyday)
        XCTAssertEqual(month.members.count, 29)
        XCTAssertEqual(month.folded.map(\.kind), [.event])
        XCTAssertEqual(month.folded[0].photos, 22)
        XCTAssertEqual(month.folded[0].anchors, [party[0]])
        XCTAssertEqual(r.collections.map(\.kind), [.everyday, .trip, .daytrip])
    }

    func testEverydayMonthCannotBeMarkedAsNotACollection() {
        let before = group(library())
        let r = group(library(), edits: GroupingEdits(notCollections: [collection(before, holding: "home1").members]))
        XCTAssertEqual(r.collections.map(\.members.count), before.collections.map(\.members.count))
    }

    func testMoveIntoAMonthThatAbsorbedAFoldedEvent() {
        // The move was made on the page after the event was folded, so its target lists the month's
        // photos including the party. It must land in that month, not be sent back by the fold.
        let before = group(library())
        let party = collection(before, holding: "party0").members
        let folded = group(library(), edits: GroupingEdits(notCollections: [party]))
        let month = collection(folded, holding: "party0").members
        let moving = ["phl0", "phl1"]
        let r = group(library(), edits: GroupingEdits(notCollections: [party], moves: [(moving, month)]))
        XCTAssertEqual(collection(r, holding: "phl0").members.count, 31)
        XCTAssertEqual(collection(r, holding: "phl0").kind, .everyday)
        XCTAssertEqual(collection(r, holding: "phl2").members.count, 2)
    }

    func testMoveIntoAMergedCollectionAndOutOfOne() {
        let before = group(library())
        let trip = collection(before, holding: "sea16-0").members, day = collection(before, holding: "phl0").members
        let merged = collection(group(library(), edits: GroupingEdits(merges: [[trip, day]])), holding: "phl0").members
        // Into the merged trip, and one of its photos out to the event.
        let party = collection(before, holding: "party0").members
        let r = group(library(), edits: GroupingEdits(merges: [[trip, day]], moves: [(["home8"], merged), (["phl3"], party)]))
        XCTAssertEqual(collection(r, holding: "home8").members.count, 13)
        XCTAssertEqual(collection(r, holding: "phl3").kind, .event)
        XCTAssertEqual(collection(r, holding: "phl3").members.count, 23)
        XCTAssertEqual(collection(r, holding: "home1").members.count, 6)
    }

    func testMovingEveryPhotoOutRemovesTheCollection() {
        let before = group(library())
        let day = collection(before, holding: "phl0").members
        let r = group(library(), edits: GroupingEdits(moves: [(day, collection(before, holding: "sea16-0").members)]))
        XCTAssertEqual(r.collections.count, 3)
        XCTAssertEqual(collection(r, holding: "phl0").members.count, 13)
    }

    func testEditsOnPhotosThatNoLongerExistAreIgnored() {
        let r = group(library(), edits: GroupingEdits(merges: [[["gone1"], ["gone2"]]], notCollections: [["gone3"]], moves: [(["gone4"], ["gone5"])]))
        XCTAssertEqual(r.collections.map(\.members.count), [7, 22, 9, 4])
    }

    func testExactCopiesKeepTheOriginalFileName() {
        let photos = [photo("b", at(1), rel: "IMG_1 2.JPG"), photo("a", at(1), rel: "IMG_1.JPG"), photo("c", at(1), rel: "IMG_1 copy.JPG")]
        let r = group(photos, [("a", "b", 0.01), ("a", "c", 0.02), ("b", "c", 0.02)])
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertEqual(r.groups[0].kind, .duplicate)
        XCTAssertFalse(r.groups[0].close)
        XCTAssertEqual(r.groups[0].members.first, "a")
        XCTAssertEqual(r.photos["a"]?.auto, .fav)
        XCTAssertEqual(r.photos["b"]?.auto, .remove)
        XCTAssertEqual(r.photos["c"]?.auto, .remove)
    }

    func testAGroupNeverSpreadsFurtherThanAllowed() {
        // a-b and b-c are close, a-c is not: chaining them into one group is refused.
        let photos = [photo("a", at(1)), photo("b", at(1, 12.001)), photo("c", at(1, 12.002))]
        let r = group(photos, [("a", "b", 0.30), ("b", "c", 0.35), ("a", "c", 0.90)])
        XCTAssertEqual(r.groups.map(\.members.count), [2])
        XCTAssertEqual(Set(r.groups[0].members), ["a", "b"])
        XCTAssertNil(r.photos["c"]?.group)
    }

    func testSimilarShotsMinutesApartAreNotGroupedUnlessVeryClose() {
        let photos = [photo("a", at(1)), photo("b", at(1, 13)), photo("c", at(2)), photo("d", at(3))]
        // An hour apart at 0.45: not a burst, not a scene. A day apart at 0.39: the same picture.
        let r = group(photos, [("a", "b", 0.45), ("c", "d", 0.39)])
        XCTAssertEqual(r.groups.map(\.members), [["c", "d"]].map { $0.sorted() })
        XCTAssertEqual(r.groups[0].kind, .nearDuplicate)
    }

    func testYourBestShotWinsAndASecondDifferentOneIsKept() {
        let photos = [
            photo("others", at(1), faces: [0.9, 0.9], aesthetic: 0.6),
            photo("you1", at(1, 12.001), faces: [0.8, 0.7], me: true),
            photo("you2", at(1, 12.002), faces: [0.75, 0.7], me: true),
            photo("you3", at(1, 12.003), faces: [0.74, 0.7], me: true),
        ]
        let r = group(photos, [("others", "you1", 0.2), ("others", "you2", 0.2), ("others", "you3", 0.2),
                               ("you1", "you2", 0.35), ("you1", "you3", 0.10), ("you2", "you3", 0.35)], knowsYou: true)
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertTrue(r.groups[0].you)
        XCTAssertEqual(r.photos["you1"]?.auto, .fav)
        XCTAssertEqual(r.photos["you1"]?.reason, "Best shot of you in this group")
        XCTAssertEqual(r.photos["you2"]?.auto, .keep)  // different enough from the favorite
        XCTAssertEqual(r.photos["you3"]?.auto, .remove)  // a near-copy of the favorite
        XCTAssertEqual(r.photos["others"]?.auto, .remove)
    }

    func testPhotosOfYouAndOfOtherPeopleAreNotTheSameShot() {
        // Further apart than a duplicate: seconds apart would group them, but you are in only one.
        let photos = [photo("you", at(1), faces: [0.8], me: true), photo("friend", at(1, 12.001), faces: [0.8])]
        XCTAssertTrue(group(photos, [("friend", "you", 0.6)], knowsYou: true).groups.isEmpty)
        let without = [photo("a", at(1), faces: [0.8]), photo("b", at(1, 12.001), faces: [0.8])]
        XCTAssertEqual(group(without, [("a", "b", 0.6)], knowsYou: true).groups.count, 1)
    }

    func testSinglesAreJudgedOnTheirOwn() {
        var photos = [
            photo("you", at(1), faces: [0.3], me: true, aesthetic: -0.8, sharpness: 5),
            photo("blurry", at(2), sharpness: 10),
            photo("receipt", at(3), utility: true),
            photo("dull", at(4), aesthetic: -0.9),
        ]
        for i in 0..<10 { photos.append(photo("fine\(i)", at(5 + i), aesthetic: 0.5)) }
        let r = group(photos, knowsYou: true)
        XCTAssertEqual(r.photos["you"]?.auto, .keep)
        XCTAssertEqual(r.photos["blurry"]?.reason, "Blurry")
        XCTAssertEqual(r.photos["receipt"]?.reason, "Looks like a screenshot or document")
        XCTAssertEqual(r.photos["dull"]?.reason, "Below-average quality and you're not in it")
        XCTAssertEqual(r.photos["fine0"]?.auto, .keep)
        // Without a photo of you, nothing is removed for merely being below average.
        XCTAssertEqual(group(photos, knowsYou: false).photos["dull"]?.auto, .keep)
    }

    func testNearRepeatsAcrossATripAreGroupedWithoutYou() {
        var photos = library()
        photos.append(photo("homeA", at(6, 9), gps: home))
        // 0.42 is too far for a duplicate and the shots are a day apart: only "one good version per
        // trip" groups them, and only inside a trip or event.
        let r = group(photos, [("sea16-0", "sea17-0", 0.42), ("home6", "homeA", 0.42)])
        XCTAssertEqual(r.groups.map { Set($0.members) }, [["sea16-0", "sea17-0"]])
        XCTAssertEqual(r.groups[0].collection, collection(r, holding: "sea16-0").id)
        XCTAssertEqual(collection(r, holding: "sea16-0").groups, [r.groups[0].id])
    }

    func testGroupingDoesNotDependOnInputOrder() {
        let pairs = [("sea16-0", "sea17-0", 0.42), ("party0", "party1", 0.2), ("party1", "party2", 0.2), ("party0", "party2", 0.3)]
        let a = group(library(), pairs), b = group(library().reversed(), pairs.reversed())
        XCTAssertEqual(a.groups.map(\.members), b.groups.map(\.members))
        XCTAssertEqual(a.collections.map(\.members), b.collections.map(\.members))
        XCTAssertEqual(a.order, b.order)
    }

    // MARK: - Videos

    func video(_ id: String, _ time: Double, print: String, me: Bool = false, aesthetic: Double = 0.2) -> GroupingPhoto {
        GroupingPhoto(id: id, rel: "\(id).mov", time: time, timeKnown: true, width: 1920, height: 1080, size: 50_000_000,
                      faceQualities: me ? [0.5] : [], meFace: me ? 0 : nil, aesthetic: aesthetic, sharpness: 5, gps: home, me: me,
                      video: true, fingerprint: print)
    }

    func testAVideoIsNeverGroupedWithAPhotoOrAnotherTake() {
        let ps = [photo("still", at(1), gps: home), video("clip", at(1, 12.001), print: "x"), video("take2", at(1, 12.002), print: "y")]
        // As alike as can be, seconds apart: for photos that is a burst.
        let r = group(ps, [("still", "clip", 0.01), ("clip", "take2", 0.01), ("still", "take2", 0.01)])
        XCTAssertEqual(r.groups.count, 0)
        XCTAssertEqual(Set(r.photos.values.map(\.auto)), [.keep])
        XCTAssertEqual(r.collections.map(\.members.count), [3], "but it is part of the same month")
    }

    func testCopiesOfAVideoKeepTheOriginalAndOnlyThat() {
        let ps = [video("clip 2", at(1), print: "x", me: true), video("clip", at(1), print: "x", me: true), video("clip copy", at(1), print: "x", me: true),
                  video("other", at(1, 13), print: "z")]
        let r = group(ps, knowsYou: true)
        XCTAssertEqual(r.groups.map(\.members), [["clip", "clip 2", "clip copy"]])
        XCTAssertEqual(r.groups.first?.kind, .duplicate)
        XCTAssertEqual(r.groups.first?.close, false)
        XCTAssertEqual(r.groups.first?.you, true)
        // You are in all three, and a copy is still only a copy: no "second shot of you" is kept.
        XCTAssertEqual(["clip", "clip 2", "clip copy"].map { r.photos[$0]!.auto }, [.fav, .remove, .remove])
        XCTAssertEqual(r.photos["clip"]?.reason, "The original of these copies")
    }

    func testAVideoOnItsOwnIsNeverSuggestedForRemoval() {
        // A blurry, low-scoring video without you, among good photos, in a library that knows you.
        var ps = (0..<10).map { photo("p\($0)", at(1 + $0), gps: home, aesthetic: 0.8) }
        ps.append(video("dull", at(3), print: "x", aesthetic: -0.9))
        ps.append(video("mine", at(4), print: "y", me: true))
        let r = group(ps, knowsYou: true)
        XCTAssertEqual(r.photos["dull"]?.auto, .keep)
        XCTAssertEqual(r.photos["dull"]?.tags, [], "one frame does not make a video blurry")
        XCTAssertEqual(r.photos["mine"]?.reason, "You're in this video")
        // And it does not drag the photos' quality line down: none of the photos falls under it.
        XCTAssertEqual(Set((0..<10).map { r.photos["p\($0)"]!.auto }), [.keep])
    }
}
