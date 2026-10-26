import XCTest
@testable import MinutesCore

final class AvatarLookTests: XCTestCase {
    func testMatchesCasualNames() {
        XCTAssertEqual(AvatarLook.matching("tvaFormal"), .tvaFormal)
        XCTAssertEqual(AvatarLook.matching("TVA Formal"), .tvaFormal)
        XCTAssertEqual(AvatarLook.matching("change into your night look"), .night)
        XCTAssertEqual(AvatarLook.matching("go professional"), .tvaFormal)
        XCTAssertEqual(AvatarLook.matching("something sunny please"), .sunny)
        XCTAssertEqual(AvatarLook.matching("back to normal"), .signature)
        XCTAssertEqual(AvatarLook.matching("Loki green and gold"), .variant)
        XCTAssertNil(AvatarLook.matching("a pirate hat"))
    }

    func testSettledLookDoesNotAnimate() {
        let look = LookTransition(settledOn: .night)
        XCTAssertFalse(look.isAnimating(at: 100))
        XCTAssertEqual(look.weight(of: .night, at: 100), 1)
        XCTAssertEqual(look.weight(of: .signature, at: 100), 0)
    }

    func testCrossFadeIsSmoothAndAddsUp() {
        var look = LookTransition(settledOn: .signature)
        XCTAssertTrue(look.retarget(to: .sunny, at: 10))
        XCTAssertFalse(look.retarget(to: .sunny, at: 10.1), "already heading there")
        var last = -1.0
        for step in 0...28 {
            let t = 10 + Double(step) * 0.05
            let to = look.weight(of: .sunny, at: t), from = look.weight(of: .signature, at: t)
            XCTAssertEqual(to + from, 1, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(to, last)
            // Eased: no frame jumps more than a smoothstep's steepest slope allows.
            if last >= 0 { XCTAssertLessThan(to - last, 0.06) }
            last = to
        }
        XCTAssertEqual(look.weight(of: .sunny, at: 10 + LookTransition.defaultDuration), 1)
        XCTAssertFalse(look.isAnimating(at: 10 + LookTransition.defaultDuration))
    }

    func testChangingMindMidwayReversesWithoutAJump() {
        var look = LookTransition(settledOn: .signature)
        look.retarget(to: .night, at: 0)
        let t = 0.4
        let before = look.weight(of: .night, at: t)
        look.retarget(to: .signature, at: t)
        XCTAssertEqual(look.weight(of: .night, at: t), before, accuracy: 1e-9)
        XCTAssertLessThan(look.weight(of: .night, at: t + 0.2), before)
    }

    func testInstantChange() {
        var look = LookTransition(settledOn: .signature)
        look.retarget(to: .variant, at: 5, animated: false)
        XCTAssertFalse(look.isAnimating(at: 5))
        XCTAssertEqual(look.weight(of: .variant, at: 5), 1)
    }

    func testLookChangeTwirlsAndSunnySparkles() {
        let director = BodyDirector()
        let cue = director.cue(for: .lookChanged(to: .sunny))
        XCTAssertEqual(cue?.gesture, .twirl)
        XCTAssertEqual(cue?.aura, .celebrating)
        XCTAssertNil(director.cue(for: .lookChanged(to: .night))?.aura)
        XCTAssertNil(cue?.destination, "changing clothes happens on the spot")
        XCTAssertLessThan(BodyDirector.twirlSeconds, LookTransition.defaultDuration)
    }

    func testMeaningfulGlowsReadTheSameInEveryLook() {
        for look in AvatarLook.allCases {
            XCTAssertEqual(BodyDirector.auraColor(.alert, look: look), 0xFF4D3A)
            XCTAssertEqual(BodyDirector.auraColor(.focused, look: look), 0x7FE7FF)
            XCTAssertNotNil(BodyDirector.auraColor(.processing, look: look))
        }
    }

    @MainActor
    func testChangeLookTool() async throws {
        var wearing = AvatarLook.signature
        let tool = try XCTUnwrap(AppearanceTools.all(current: { wearing }, apply: { wearing = $0 }).first)
        _ = try await tool.run(["look": "night"])
        XCTAssertEqual(wearing, .night)
        _ = try await tool.run(["look": "night"])
        XCTAssertEqual(wearing, .night)
        do {
            _ = try await tool.run(["look": "pirate"])
            XCTFail("unknown look should throw")
        } catch {}
    }

    func testSettingsKeepTheLookAndToleratesUnknownOnes() throws {
        var settings = AppSettings.default
        settings.avatarLook = .tvaFormal
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).avatarLook, .tvaFormal)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["avatarLook"] = "retiredLook"
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: old).avatarLook, .signature)
    }
}
