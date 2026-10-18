import Foundation
import CoreGraphics

@main struct ArrangementChecks {
    @MainActor static func main() {
        var failed = [String]()
        var checked = 0
        func expect(_ actual: Bool, _ wanted: Bool, _ label: String) {
            checked += 1
            if actual != wanted { failed.append(label); print("FAIL \(label): expected \(wanted), actual \(actual)") }
        }
        let display = VirtualDisplay()
        expect(AdapterFixture.valid(display),true,"initial right arrangement")
        for (name,x,y) in [("left",-1350.0,0.0),("above",0.0,-976.0),
            ("below",0.0,982.0),("above LG",1512.0,-1074.0)] {
            display.bounds.origin = CGPoint(x:x,y:y)
            expect(AdapterFixture.valid(display),true,"native \(name) position remains valid")
        }
        display.bounds.origin = CGPoint(x:200,y:100)
        expect(AdapterFixture.valid(display),false,"physical overlap remains refused")
        display.bounds.origin = CGPoint(x:3432,y:-98)
        CoreGraphicsFixture.mirror = 1
        expect(AdapterFixture.valid(display),false,"mirror remains refused")
        CoreGraphicsFixture.mirror = 0
        display.pixelSize.width = 1350
        expect(AdapterFixture.valid(display),false,"wrong HiDPI mode remains refused")
        display.pixelSize.width = 2700
        CoreGraphicsFixture.active = 0
        expect(AdapterFixture.valid(display),false,"inactive display remains refused")
        CoreGraphicsFixture.active = 1
        display.isAlive = false
        expect(AdapterFixture.valid(display),false,"destroyed display remains refused")
        print("ARRANGEMENT_CHECKS total=\(checked) failed=\(failed.count)")
        if !failed.isEmpty { exit(1) }
    }
}
