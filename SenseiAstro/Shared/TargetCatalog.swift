import Foundation

enum TargetCatalog {
    static let all: [AstroTarget] = [
        t("M31", "Andromeda Galaxy", 0.7123, 41.2692, "Galaxy", false, 75, "Tele 1x", "Single frame", "Bright, large galaxy; keep Duo-band off."),
        t("M33", "Triangulum Galaxy", 1.5641, 30.6602, "Galaxy", false, 100, "Tele 1x", "Single frame", "Low surface brightness; prioritize a moonless clear window."),
        t("M42", "Orion Nebula", 5.5881, -5.3911, "Emission nebula", true, 45, "Tele 1x", "Single frame", "Duo-band improves city-sky contrast around the nebula."),
        t("M45", "Pleiades", 3.7900, 24.1167, "Open cluster", false, 30, "Tele 1x", "Single frame", "Use UV/IR-cut for natural star color and blue reflection nebulosity."),
        t("M1", "Crab Nebula", 5.5755, 22.0145, "Supernova remnant", true, 75, "Tele 1x", "Single frame", "Compact target; Duo-band helps isolate nebular signal."),
        t("NGC 2237", "Rosette Nebula", 6.5319, 5.0500, "Emission nebula", true, 90, "Tele 1x", "Single frame", "A strong Duo-band target for an urban sky."),
        t("NGC 1499", "California Nebula", 4.0550, 36.4217, "Emission nebula", true, 100, "Tele 1x", "Mosaic", "Large emission target; use mosaic framing and Duo-band."),
        t("NGC 7000", "North America Nebula", 20.9817, 44.3167, "Emission nebula", true, 90, "Tele 1x", "Mosaic", "Large H-alpha region; use Duo-band and mosaic framing."),
        t("NGC 6992", "Eastern Veil Nebula", 20.9389, 31.7167, "Supernova remnant", true, 100, "Tele 1x", "Mosaic", "Faint filaments benefit from Duo-band and long stacking."),
        t("M8", "Lagoon Nebula", 18.0603, -24.3867, "Emission nebula", true, 60, "Tele 1x", "Single frame", "Capture near culmination because it remains low from Los Angeles."),
        t("M20", "Trifid Nebula", 18.0397, -22.9717, "Mixed nebula", true, 75, "Tele 1x", "Single frame", "Duo-band emphasizes emission; add unfiltered data for reflection color."),
        t("M16", "Eagle Nebula", 18.3133, -13.8067, "Emission nebula", true, 75, "Tele 1x", "Single frame", "Use Duo-band and capture close to its highest altitude."),
        t("M17", "Omega Nebula", 18.3406, -16.1767, "Emission nebula", true, 60, "Tele 1x", "Single frame", "Bright emission target that responds well to Duo-band."),
        t("M27", "Dumbbell Nebula", 19.9933, 22.7211, "Planetary nebula", true, 60, "Tele 1x", "Single frame", "Duo-band boosts OIII and H-alpha contrast."),
        t("M57", "Ring Nebula", 18.8931, 33.0289, "Planetary nebula", true, 50, "Tele 2x", "Single frame", "2x is a digital crop; preserve the original 1x stack too."),
        t("M13", "Hercules Cluster", 16.6947, 36.4613, "Globular cluster", false, 40, "Tele 1x", "Single frame", "Leave Duo-band off for natural star color."),
        t("Double", "Double Cluster", 2.3167, 57.1333, "Open cluster", false, 35, "Tele 1x", "Single frame", "Normal UV/IR-cut gives the best star color."),
        t("M44", "Beehive Cluster", 8.6733, 19.6667, "Open cluster", false, 25, "Tele 1x", "Single frame", "Bright wide cluster; a shorter integration is sufficient."),
        t("M51", "Whirlpool Galaxy", 13.4979, 47.1953, "Galaxy", false, 100, "Tele 1x", "Single frame", "Spiral structure needs clear skies, low Moon and long stacking."),
        t("M81", "Bode's Galaxy", 9.9259, 69.0653, "Galaxy", false, 90, "Tele 1x", "Single frame", "High northern target with good altitude from Southern California."),
        t("M101", "Pinwheel Galaxy", 14.0535, 54.3492, "Galaxy", false, 110, "Tele 1x", "Single frame", "Very low surface brightness; reserve for the clearest moonless hours."),
        t("M106", "M106 Galaxy", 12.3159, 47.3037, "Galaxy", false, 100, "Tele 1x", "Single frame", "Long integration and low Moon matter more than filter use."),
        t("M104", "Sombrero Galaxy", 12.6665, -11.6231, "Galaxy", false, 80, "Tele 1x", "Single frame", "Capture close to culmination because it remains fairly low.")
    ]

    private static func t(_ id: String, _ name: String, _ ra: Double, _ dec: Double, _ type: String, _ filter: Bool, _ minutes: Int, _ lens: String, _ framing: String, _ note: String) -> AstroTarget {
        AstroTarget(id: id, name: name, rightAscensionHours: ra, declinationDegrees: dec, type: type, filterEnabled: filter, recommendedMinutes: minutes, lens: lens, framing: framing, note: note)
    }
}
