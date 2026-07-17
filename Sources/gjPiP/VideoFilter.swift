import CoreImage

/// One selectable video filter, from the set BetterDisplay Pro ships for its PiP
/// windows (v3.5's basic adjustments, sharpen/blur, and special effects).
///
/// Each case carries fixed parameters rather than a slider: a menu can show a
/// checkmark, and a filter whose default is its neutral value would toggle to no
/// visible change at all. The labels state the baked-in direction for the same
/// reason — "明るさ +" is a promise the toggle can keep.
enum VideoFilter: String, CaseIterable {
    // 基本調整
    case brightness, contrast, saturation, hueAngle, temperature, gamma
    // シャープ・ぼかし
    case sharpenLuminance, unsharpMask, gaussianBlur, boxBlur
    // 特殊効果
    case colorInvert, sepiaTone, monochrome, vignette, edges, crystallize, hexPixellate

    var label: String {
        switch self {
        case .brightness: return "明るさ +"
        case .contrast: return "コントラスト +"
        case .saturation: return "彩度 +"
        case .hueAngle: return "色相 90°"
        case .temperature: return "色温度（暖色）"
        case .gamma: return "ガンマ（明るく）"
        case .sharpenLuminance: return "シャープ（輝度）"
        case .unsharpMask: return "アンシャープマスク"
        case .gaussianBlur: return "ガウスぼかし"
        case .boxBlur: return "ボックスぼかし"
        case .colorInvert: return "色反転"
        case .sepiaTone: return "セピア"
        case .monochrome: return "モノクロ"
        case .vignette: return "ビネット"
        case .edges: return "エッジ検出"
        case .crystallize: return "クリスタライズ"
        case .hexPixellate: return "六角形ピクセレート"
        }
    }

    /// Menu sections, in menu order.
    static let groups: [(title: String, filters: [VideoFilter])] = [
        ("基本調整", [.brightness, .contrast, .saturation, .hueAngle, .temperature, .gamma]),
        ("シャープ・ぼかし", [.sharpenLuminance, .unsharpMask, .gaussianBlur, .boxBlur]),
        ("特殊効果", [.colorInvert, .sepiaTone, .monochrome, .vignette, .edges, .crystallize, .hexPixellate]),
    ]

    /// A configured instance for `CALayer.filters`, which applies it on the GPU
    /// to whatever the layer displays — the zero-copy IOSurface path stays as it is.
    func make() -> CIFilter? {
        let f: CIFilter?
        switch self {
        case .brightness:
            f = CIFilter(name: "CIColorControls")
            f?.setValue(0.15, forKey: "inputBrightness")
        case .contrast:
            f = CIFilter(name: "CIColorControls")
            f?.setValue(1.35, forKey: "inputContrast")
        case .saturation:
            f = CIFilter(name: "CIColorControls")
            f?.setValue(1.6, forKey: "inputSaturation")
        case .hueAngle:
            f = CIFilter(name: "CIHueAdjust")
            f?.setValue(Double.pi / 2, forKey: "inputAngle")
        case .temperature:
            f = CIFilter(name: "CITemperatureAndTint")
            f?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f?.setValue(CIVector(x: 4500, y: 0), forKey: "inputTargetNeutral")
        case .gamma:
            f = CIFilter(name: "CIGammaAdjust")
            f?.setValue(0.75, forKey: "inputPower")
        case .sharpenLuminance:
            f = CIFilter(name: "CISharpenLuminance")
            f?.setValue(0.9, forKey: "inputSharpness")
        case .unsharpMask:
            f = CIFilter(name: "CIUnsharpMask")
            f?.setValue(2.5, forKey: "inputRadius")
            f?.setValue(1.5, forKey: "inputIntensity")
        case .gaussianBlur:
            f = CIFilter(name: "CIGaussianBlur")
            f?.setValue(8.0, forKey: "inputRadius")
        case .boxBlur:
            f = CIFilter(name: "CIBoxBlur")
            f?.setValue(8.0, forKey: "inputRadius")
        case .colorInvert:
            f = CIFilter(name: "CIColorInvert")
        case .sepiaTone:
            f = CIFilter(name: "CISepiaTone")
            f?.setValue(1.0, forKey: "inputIntensity")
        case .monochrome:
            f = CIFilter(name: "CIColorMonochrome")
            f?.setValue(CIColor(red: 0.75, green: 0.75, blue: 0.75), forKey: "inputColor")
            f?.setValue(1.0, forKey: "inputIntensity")
        case .vignette:
            f = CIFilter(name: "CIVignette")
            f?.setValue(1.4, forKey: "inputIntensity")
            f?.setValue(2.0, forKey: "inputRadius")
        case .edges:
            f = CIFilter(name: "CIEdges")
            f?.setValue(3.0, forKey: "inputIntensity")
        case .crystallize:
            f = CIFilter(name: "CICrystallize")
            f?.setValue(24.0, forKey: "inputRadius")
        case .hexPixellate:
            f = CIFilter(name: "CIHexagonalPixellate")
            f?.setValue(24.0, forKey: "inputScale")
        }
        return f
    }
}
