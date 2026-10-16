import XCTest
@testable import PhotoLab

/// Lightroom `.xmp` presets read into a recipe (D-471 (a)). Every fixture is
/// hand-written XMP text saved into a temp directory and read back as the
/// import sheet will read a file the user picked; no Adobe file is used.
final class XMPPresetTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-xmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes `text` to `<dir>/<name>` and parses it back from disk.
    private func importFile(_ name: String, _ text: String) throws -> XMPImport {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let bytes = try Data(contentsOf: url)
        return try XMPPreset.parse(bytes, fileName: url.lastPathComponent)
    }

    /// An XMP packet around one `rdf:Description`.
    private func xmp(attributes: String = "", body: String = "", prefix: String = "crs") -> String {
        """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Hand-written">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:\(prefix)="http://ns.adobe.com/camera-raw-settings/1.0/"
            \(attributes)>
           \(body)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    func testAttributeAndElementFormsGiveOneRecipe() throws {
        let attr = try importFile("Warm Fade.xmp", xmp(attributes: """
            crs:Version="15.0" crs:ProcessVersion="11.0"
            crs:Exposure2012="+0.50" crs:Contrast2012="-20" crs:Shadows2012="+35"
            crs:IncrementalTemperature="+12" crs:Vibrance="+10" crs:Sharpness="60"
            crs:ColorGradeShadowHue="210" crs:ColorGradeShadowSat="18" crs:PostCropVignetteAmount="-15"
            """))
        let element = try importFile("Warm Fade copy.xmp", xmp(body: """
            <crs:Version>15.0</crs:Version>
            <crs:ProcessVersion>11.0</crs:ProcessVersion>
            <crs:Exposure2012>+0.50</crs:Exposure2012>
            <crs:Contrast2012>-20</crs:Contrast2012>
            <crs:Shadows2012>+35</crs:Shadows2012>
            <crs:IncrementalTemperature>+12</crs:IncrementalTemperature>
            <crs:Vibrance>+10</crs:Vibrance>
            <crs:Sharpness>60</crs:Sharpness>
            <crs:ColorGradeShadowHue>210</crs:ColorGradeShadowHue>
            <crs:ColorGradeShadowSat>18</crs:ColorGradeShadowSat>
            <crs:PostCropVignetteAmount>-15</crs:PostCropVignetteAmount>
            """))
        XCTAssertEqual(attr.recipe, element.recipe)
        XCTAssertEqual(attr.mapped, element.mapped)
        XCTAssertEqual(attr.recipe.value(of: .exposure), 0.5)
        XCTAssertEqual(attr.recipe.value(of: .contrast), -20)
        XCTAssertEqual(attr.recipe.value(of: .shadows), 35)
        XCTAssertEqual(attr.recipe.value(of: .temperature), 12)
        XCTAssertEqual(attr.recipe.value(of: .sharpening), 40, accuracy: 1e-9, "Sharpness 0...150 rescaled onto 0...100")
        XCTAssertEqual(attr.recipe.value(of: .gradeShadowHue), 210)
        XCTAssertEqual(attr.recipe.value(of: .vignette), -15)
        XCTAssertEqual(attr.mapped.count, 9)
        XCTAssertEqual(attr.unsupported, [])
        XCTAssertEqual(attr.clamped, [])
        // No PresetName or Name: the file's stem.
        XCTAssertEqual(attr.name, "Warm Fade")
    }

    func testNameFromPresetNameOrAltText() throws {
        let alt = try importFile("file.xmp", xmp(attributes: #"crs:Exposure2012="+0.10""#, body: """
            <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Golden Hour</rdf:li></rdf:Alt></crs:Name>
            """))
        XCTAssertEqual(alt.name, "Golden Hour")
        let named = try importFile("file2.xmp", xmp(attributes: #"crs:PresetName="Blue Hour" crs:Exposure2012="+0.10""#))
        XCTAssertEqual(named.name, "Blue Hour")
    }

    func testHSLAquaAndBlueLandOnTheirOwnBands() throws {
        let r = try importFile("bands.xmp", xmp(attributes: """
            crs:HueAdjustmentAqua="+25" crs:HueAdjustmentBlue="-40"
            crs:SaturationAdjustmentAqua="+11" crs:SaturationAdjustmentBlue="-22"
            crs:LuminanceAdjustmentAqua="+7" crs:LuminanceAdjustmentBlue="-9"
            """))
        XCTAssertEqual(r.recipe.value(of: .hueAqua), 25, "Aqua hue")
        XCTAssertEqual(r.recipe.value(of: .hueBlue), -40, "Blue hue")
        XCTAssertEqual(r.recipe.value(of: .satAqua), 11, "Aqua saturation")
        XCTAssertEqual(r.recipe.value(of: .satBlue), -22, "Blue saturation")
        XCTAssertEqual(r.recipe.value(of: .lumAqua), 7, "Aqua luminance")
        XCTAssertEqual(r.recipe.value(of: .lumBlue), -9, "Blue luminance")
        for band in AdjustmentKind.HSLBand.allCases where band != .aqua && band != .blue {
            for channel in AdjustmentKind.HSLChannel.allCases {
                XCTAssertEqual(r.recipe.value(of: .hsl(channel, band)), 0, "\(band.label) untouched")
            }
        }
    }

    func testEveryHSLRowNamesItsOwnBand() {
        let channels: [(String, AdjustmentKind.HSLChannel)] =
            [("HueAdjustment", .hue), ("SaturationAdjustment", .saturation), ("LuminanceAdjustment", .luminance)]
        for (prefix, channel) in channels {
            for band in AdjustmentKind.HSLBand.allCases {
                let row = XMPPreset.mapping.first { $0.setting == prefix + band.label }
                XCTAssertEqual(row?.kind, .hsl(channel, band), prefix + band.label)
            }
        }
    }

    func testOutOfRangeValueIsClampedAndListed() throws {
        let r = try importFile("hot.xmp", xmp(attributes: #"crs:Exposure2012="+7.00" crs:Whites2012="+140" crs:Blacks2012="-10""#))
        XCTAssertEqual(r.recipe.value(of: .exposure), 5)
        XCTAssertEqual(r.recipe.value(of: .whites), 100)
        XCTAssertEqual(r.recipe.value(of: .blacks), -10)
        XCTAssertEqual(r.clamped, ["Exposure2012", "Whites2012"])
    }

    func testDehazeAndMaskGroupAreUnsupportedAZeroDehazeIsNot() throws {
        let r = try importFile("haze.xmp", xmp(attributes: #"crs:Dehaze="+20" crs:Texture="0" crs:Exposure2012="+0.20""#, body: """
            <crs:MaskGroupBasedCorrections>
             <rdf:Seq>
              <rdf:li>
               <rdf:Description crs:What="Correction" crs:CorrectionAmount="1" crs:LocalExposure2012="+1.00">
                <crs:CorrectionMasks><rdf:Seq><rdf:li><rdf:Description crs:What="Mask/Image" crs:MaskSubType="1"/></rdf:li></rdf:Seq></crs:CorrectionMasks>
               </rdf:Description>
              </rdf:li>
             </rdf:Seq>
            </crs:MaskGroupBasedCorrections>
            """))
        XCTAssertEqual(r.unsupported, [
            XMPImport.Unsupported(setting: "Dehaze", label: "Dehaze"),
            XMPImport.Unsupported(setting: "MaskGroupBasedCorrections", label: "Masks"),
        ])
        // A mask's own crs: keys are never read as global settings.
        XCTAssertEqual(r.recipe.value(of: .exposure), 0.2)
        XCTAssertTrue(r.recipe.masks.isEmpty)

        let zero = try importFile("nohaze.xmp", xmp(attributes: #"crs:Dehaze="0" crs:Exposure2012="+0.20""#))
        XCTAssertEqual(zero.unsupported, [])
    }

    func testKeyOutsideBothTablesIsListedAtItsDefaultItIsNot() throws {
        let r = try importFile("pv2010.xmp", xmp(attributes: """
            crs:ProcessVersion="5.7" crs:Exposure="+0.50" crs:Brightness="+50" crs:Clarity="+40"
            crs:GrainSize="40" crs:GrainFrequency="50" crs:SharpenRadius="+1.0" crs:ParametricShadowSplit="40"
            crs:SomeFutureSlider="+12" crs:EnableCalibration="True"
            """))
        XCTAssertEqual(r.unsupported, [
            XMPImport.Unsupported(setting: "Exposure", label: "Process 2010 tone"),
            XMPImport.Unsupported(setting: "Clarity", label: "Process 2010 tone"),
            XMPImport.Unsupported(setting: "GrainSize", label: "Grain size"),
            XMPImport.Unsupported(setting: "SomeFutureSlider", label: "Some future slider"),
        ])
        XCTAssertTrue(r.recipe.isDefault)
    }

    func testKelvinWhiteBalanceIsListedUnlessAsShot() throws {
        let bare = try importFile("k.xmp", xmp(attributes: #"crs:Temperature="5200" crs:Tint="+12""#))
        XCTAssertEqual(bare.unsupported.map(\.setting), ["Temperature", "Tint"])
        let custom = try importFile("k2.xmp", xmp(attributes: #"crs:WhiteBalance="Custom" crs:Temperature="5200" crs:Tint="+12""#))
        XCTAssertEqual(custom.unsupported.map(\.setting), ["WhiteBalance", "Temperature", "Tint"])
        let asShot = try importFile("k3.xmp", xmp(attributes: #"crs:WhiteBalance="As Shot" crs:Temperature="5200" crs:Tint="+12""#))
        XCTAssertEqual(asShot.unsupported, [])
    }

    func testDefaultLookIsNotListedACreativeOneIs() throws {
        func look(_ name: String) -> String {
            xmp(attributes: #"crs:Exposure2012="+0.20""#, body: """
                <crs:Look><rdf:Description crs:Name="\(name)" crs:Amount="1">
                  <crs:Parameters><rdf:Description crs:Version="15.0" crs:ProcessVersion="11.0" crs:Saturation="-30"/></crs:Parameters>
                </rdf:Description></crs:Look>
                """)
        }
        let standard = try importFile("a.xmp", look("Adobe Color"))
        XCTAssertEqual(standard.unsupported, [])
        XCTAssertEqual(standard.recipe.value(of: .saturation), 0, "a Look's parameters are not global settings")
        let creative = try importFile("b.xmp", look("Vintage 07"))
        XCTAssertEqual(creative.unsupported.map(\.label), ["Look"])
    }

    func testSplitToningMapsWhenColorGradeIsAbsentAndYieldsWhenPresent() throws {
        let old = try importFile("old.xmp", xmp(attributes: """
            crs:SplitToningShadowHue="220" crs:SplitToningShadowSaturation="15"
            crs:SplitToningHighlightHue="45" crs:SplitToningHighlightSaturation="25" crs:SplitToningBalance="-10"
            """))
        XCTAssertEqual(old.recipe.value(of: .gradeShadowHue), 220)
        XCTAssertEqual(old.recipe.value(of: .gradeHighlightSat), 25)
        XCTAssertEqual(old.recipe.value(of: .gradeBalance), -10)
        let both = try importFile("new.xmp", xmp(attributes: """
            crs:ColorGradeShadowHue="200" crs:SplitToningShadowHue="220"
            """))
        XCTAssertEqual(both.recipe.value(of: .gradeShadowHue), 200)
    }

    func testToneCurvesAreApproximatedOntoTheFivePoints() throws {
        let r = try importFile("curve.xmp", xmp(attributes: #"crs:ParametricShadows="+50""#, body: """
            <crs:ToneCurvePV2012><rdf:Seq>
             <rdf:li>0, 32</rdf:li><rdf:li>128, 128</rdf:li><rdf:li>255, 230</rdf:li>
            </rdf:Seq></crs:ToneCurvePV2012>
            <crs:ToneCurvePV2012Red><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012Red>
            """))
        XCTAssertEqual(r.approximated, ["ToneCurvePV2012", "ParametricShadows"])
        // The lifted black point: 32 / 255 of a quarter-per-100 offset.
        XCTAssertEqual(r.recipe.value(of: .curveBlacks), 32.0 / 255 * 400, accuracy: 1e-9)
        XCTAssertLessThan(r.recipe.value(of: .curveWhites), 0, "the lowered white point")
        XCTAssertGreaterThan(r.recipe.value(of: .curveShadows), 0, "the faded shadows and the parametric lift")
        XCTAssertEqual(r.unsupported, [], "an identity per-channel curve is neutral")
    }

    func testMalformedXMLAndNoCameraRawSettingsThrowByName() throws {
        XCTAssertThrowsError(try importFile("broken.xmp", "<x:xmpmeta><rdf:RDF>")) {
            XCTAssertEqual($0 as? XMPImportError, .notXML)
        }
        XCTAssertThrowsError(try importFile("empty.xmp", "")) {
            XCTAssertEqual($0 as? XMPImportError, .notXML)
        }
        let dcOnly = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:format="image/jpeg"/>
            </rdf:RDF></x:xmpmeta>
            """
        XCTAssertThrowsError(try importFile("dc.xmp", dcOnly)) {
            XCTAssertEqual($0 as? XMPImportError, .noCameraRawSettings)
        }
    }

    func testAnotherPrefixForTheNamespaceReadsToo() throws {
        let r = try importFile("p.xmp", xmp(attributes: #"cr:Exposure2012="+1.00""#, prefix: "cr"))
        XCTAssertEqual(r.recipe.value(of: .exposure), 1)
    }

    func testRecipeThroughPresetCarriesNoGeometry() throws {
        let r = try importFile("crop.xmp", xmp(attributes: """
            crs:HasCrop="True" crs:CropTop="0.1" crs:CropLeft="0.1" crs:CropBottom="0.9" crs:CropRight="0.9"
            crs:CropAngle="3.5" crs:Exposure2012="+0.30"
            """))
        XCTAssertEqual(r.unsupported.map(\.setting), ["HasCrop", "CropAngle", "CropTop", "CropLeft", "CropBottom", "CropRight"])
        XCTAssertEqual(Set(r.unsupported.map(\.label)), ["Crop"])
        let preset = Preset(name: r.name, from: r.recipe)
        for kind in AdjustmentKind.geometryKinds {
            XCTAssertEqual(preset.recipe.value(of: kind), kind.neutral, kind.label)
        }
        for kind in [AdjustmentKind.lensDistortion, .lensVignette] {
            XCTAssertEqual(preset.recipe.value(of: kind), 0, kind.label)
        }
        XCTAssertEqual(preset.recipe.value(of: .exposure), 0.3)
        XCTAssertTrue(preset.recipe.masks.isEmpty)
    }

    func testTheTableHoldsNoGeometryOrLensKind() {
        let forbidden = Set(AdjustmentKind.geometryKinds + [.lensDistortion, .lensVignette])
        XCTAssertTrue(XMPPreset.mapping.allSatisfy { !forbidden.contains($0.kind) })
    }
}
