import XCTest
@testable import MinutesCore

/// Proactive intelligence (stuck detection, break coaching) and emotional intelligence (mood).
final class IntuitionTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Stuck

    func testErrorThatStaysUpIsOfferedOnce() {
        var detector = StuckDetector(errorPersistence: 150)
        detector.observe(app: "Xcode", title: "Build Failed — MyApp", idleSeconds: 5, at: t0)
        XCTAssertNil(detector.assess(at: t0.addingTimeInterval(60)), "a quick fix shouldn't trigger her")
        detector.observe(app: "Xcode", title: "Build Failed — MyApp", idleSeconds: 5, at: t0.addingTimeInterval(160))
        guard case .error(let app, let detail, _)? = detector.assess(at: t0.addingTimeInterval(160)) else {
            return XCTFail("expected an error finding")
        }
        XCTAssertEqual(app, "Xcode")
        XCTAssertTrue(detail.contains("Build Failed"))
        XCTAssertNil(detector.assess(at: t0.addingTimeInterval(400)), "same error isn't repeated")
    }

    func testErrorFromScreenNoteAndResolution() {
        var detector = StuckDetector(errorPersistence: 120)
        detector.observe(app: "Terminal", title: "zsh", note: "Running npm test; 3 tests failed in auth.spec.ts", idleSeconds: 1, at: t0)
        detector.observe(app: "Terminal", title: "zsh", note: "All tests pass now", idleSeconds: 1, at: t0.addingTimeInterval(60))
        XCTAssertNil(detector.assess(at: t0.addingTimeInterval(200)), "a fresh look with no error clears it")
    }

    func testSwitchingWindowsOrStepppingAwayResetsTheClock() {
        var detector = StuckDetector(errorPersistence: 120, dwellThreshold: 600)
        detector.observe(app: "Safari", title: "TypeError: x is undefined - Google Search", idleSeconds: 1, at: t0)
        detector.observe(app: "Safari", title: "Swift docs", idleSeconds: 1, at: t0.addingTimeInterval(100))
        XCTAssertNil(detector.assess(at: t0.addingTimeInterval(200)))
        detector.observe(app: "Notes", title: "Draft", idleSeconds: 1, at: t0.addingTimeInterval(300))
        detector.observe(app: "Notes", title: "Draft", idleSeconds: 900, at: t0.addingTimeInterval(800))
        XCTAssertNil(detector.assess(at: t0.addingTimeInterval(950)), "away time isn't dwelling")
    }

    func testLongDwellIsAGentleCheckIn() {
        var detector = StuckDetector(dwellThreshold: 600)
        detector.observe(app: "Figma", title: "Onboarding v3", idleSeconds: 2, at: t0)
        detector.observe(app: "Figma", title: "Onboarding v3", idleSeconds: 2, at: t0.addingTimeInterval(650))
        XCTAssertEqual(detector.assess(at: t0.addingTimeInterval(650)), .dwelling(app: "Figma", title: "Onboarding v3", minutes: 10))
        XCTAssertNil(detector.assess(at: t0.addingTimeInterval(700)))
    }

    func testErrorDetailIgnoresOrdinaryTitles() {
        XCTAssertNil(StuckDetector.errorDetail(in: "Quarterly report.docx"))
        XCTAssertNotNil(StuckDetector.errorDetail(in: "Segmentation fault (core dumped)"))
        XCTAssertNotNil(StuckDetector.errorDetail(in: "404 Not Found"))
    }

    // MARK: - Breaks

    func testBreakNudgesEscalateAndComeSoonerWhenStressed() {
        XCTAssertEqual(BreakCoach.threshold(base: 90, stressed: false, lateNight: false), 90)
        XCTAssertEqual(BreakCoach.threshold(base: 90, stressed: true, lateNight: false), 72)
        XCTAssertEqual(BreakCoach.threshold(base: 25, stressed: true, lateNight: true), 20, "never absurdly short")

        XCTAssertFalse(BreakCoach.shouldNudge(activeMinutes: 80, threshold: 90, nudgesThisStretch: 0, lastNudgeAt: nil, now: t0))
        XCTAssertTrue(BreakCoach.shouldNudge(activeMinutes: 90, threshold: 90, nudgesThisStretch: 0, lastNudgeAt: nil, now: t0))
        XCTAssertFalse(BreakCoach.shouldNudge(activeMinutes: 120, threshold: 90, nudgesThisStretch: 1, lastNudgeAt: t0, now: t0.addingTimeInterval(30 * 60)))
        XCTAssertTrue(BreakCoach.shouldNudge(activeMinutes: 130, threshold: 90, nudgesThisStretch: 1, lastNudgeAt: t0, now: t0.addingTimeInterval(40 * 60)))
        XCTAssertLessThan(BreakCoach.followUpGap(afterNudges: 3), BreakCoach.followUpGap(afterNudges: 1))
        XCTAssertNotEqual(BreakCoach.line(activeMinutes: 90, nudgesThisStretch: 0, index: 0),
                          BreakCoach.line(activeMinutes: 90, nudgesThisStretch: 0, index: 1), "suggestions vary")
    }

    // MARK: - Mood

    func testFrustrationMakesHerGentle() {
        var mood = MoodTracker(now: t0)
        mood.observeUserText("ugh the build is STILL BROKEN, why won't it work??", at: t0)
        XCTAssertEqual(mood.tone(at: t0), .gentle)
        XCTAssertTrue(mood.isStressed(at: t0))
        XCTAssertNotNil(MoodTone.gentle.guidance)
        XCTAssertLessThan(MoodTone.gentle.sass, MoodTone.steady.sass)
    }

    func testWinsMakeHerBubblyAndSoftenStress() {
        var mood = MoodTracker(now: t0)
        mood.observeUserText("this is so annoying, nothing works", at: t0)
        mood.observeUserText("YES it works now!! finally, thank you", at: t0.addingTimeInterval(60))
        XCTAssertEqual(mood.tone(at: t0.addingTimeInterval(60)), .upbeat)
        XCTAssertGreaterThan(MoodTone.upbeat.prosodyBias.pitch, 1)
    }

    func testMoodFadesBackToSteady() {
        var mood = MoodTracker(now: t0)
        mood.observeUserText("I'm so stressed, this deadline is a nightmare", at: t0)
        XCTAssertEqual(mood.tone(at: t0), .gentle)
        XCTAssertEqual(mood.tone(at: t0.addingTimeInterval(90 * 60)), .steady)
    }

    func testNeutralTextAndFatigue() {
        var mood = MoodTracker(now: t0)
        mood.observeUserText("what's on my calendar tomorrow", at: t0)
        XCTAssertEqual(mood.tone(at: t0), .steady)
        XCTAssertEqual(MoodTracker.fatigue(activeMinutes: 30, hour: 14), 0)
        XCTAssertGreaterThanOrEqual(MoodTracker.fatigue(activeMinutes: 200, hour: 14), 0.6)
        XCTAssertGreaterThanOrEqual(MoodTracker.fatigue(activeMinutes: 60, hour: 1), 0.6)
    }

    func testSignalsMoveTheMood() {
        var mood = MoodTracker(now: t0)
        mood.observe(.stuck, at: t0)
        mood.observe(.stuck, at: t0)
        XCTAssertEqual(mood.tone(at: t0), .gentle)
        mood.observe(.breakTaken, at: t0)
        mood.observe(.taskCompleted, at: t0)
        mood.observe(.taskCompleted, at: t0)
        XCTAssertEqual(mood.tone(at: t0), .upbeat)
    }

    func testContextCarriesMoodGuidance() {
        let context = AgentContext(moodNote: MoodTone.gentle.guidance).render()
        XCTAssertTrue(context.contains("Their mood: They seem stressed"))
        XCTAssertFalse(AgentContext().render().contains("Their mood"))
    }
}
