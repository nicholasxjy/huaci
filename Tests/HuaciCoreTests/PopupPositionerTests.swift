import CoreGraphics
import Testing
@testable import HuaciCore

struct PopupPositionerTests {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    /// Secondary display to the left and slightly lower.
    let left = CGRect(x: -1920, y: -200, width: 1920, height: 1055)
    let size = CGSize(width: 380, height: 300)

    func isInside(_ frame: CGRect, _ screen: CGRect) -> Bool {
        screen.contains(frame) || screen == frame
    }

    @Test func opensBelowAndRightOfMouse() {
        let frame = PopupPositioner.frame(size: size, mouse: CGPoint(x: 400, y: 600), screens: [main, left])
        #expect(frame == CGRect(x: 412, y: 284, width: 380, height: 300))
    }

    @Test func flipsLeftNearRightEdge() {
        let frame = PopupPositioner.frame(size: size, mouse: CGPoint(x: 1430, y: 600), screens: [main])
        #expect(frame.maxX <= main.maxX)
        #expect(frame.maxX == 1418)
    }

    @Test func flipsAboveNearBottomEdge() {
        let frame = PopupPositioner.frame(size: size, mouse: CGPoint(x: 400, y: 50), screens: [main])
        #expect(frame.minY == 66)
        #expect(isInside(frame, main))
    }

    @Test func staysInsideInCorners() {
        for mouse in [CGPoint(x: 0, y: 0), CGPoint(x: 1440, y: 875), CGPoint(x: 1440, y: 0), CGPoint(x: 0, y: 875)] {
            #expect(isInside(PopupPositioner.frame(size: size, mouse: mouse, screens: [main]), main))
        }
    }

    @Test func usesScreenUnderMouseWithNegativeCoordinates() {
        let frame = PopupPositioner.frame(size: size, mouse: CGPoint(x: -10, y: -150), screens: [main, left])
        #expect(isInside(frame, left))
    }

    @Test func shrinksToFitSmallScreen() {
        let small = CGRect(x: 0, y: 0, width: 300, height: 200)
        let frame = PopupPositioner.frame(size: size, mouse: CGPoint(x: 150, y: 100), screens: [small])
        #expect(frame == small)
    }

    @Test func mouseBetweenScreensUsesNearest() {
        let frame = PopupPositioner.frame(size: size, mouse: CGPoint(x: 1500, y: 400), screens: [main, left])
        #expect(isInside(frame, main))
    }
}
