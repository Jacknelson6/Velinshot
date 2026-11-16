import CoreGraphics
import VelinshotCore

struct KnownContentBounds { let bounds:CGRect? }
struct DocumentAnalysis {
    var bounds:KnownContentBounds?
    var colors:(RGBA,RGBA)?
}

enum NewDocument {
    static func state(source:CGImage,style:CanvasStyle) -> EditState {
        prepare(source:source,style:style).state
    }
    static func prepare(source:CGImage,style:CanvasStyle) -> (state:EditState,analysis:DocumentAnalysis) {
        var state = EditState(style:style)
        var analysis = DocumentAnalysis()
        if style.autoBalance { let bounds = AutoBeautify.contentBounds(source:source);state.crop = bounds;analysis.bounds = KnownContentBounds(bounds:bounds) }
        if style.autoColor {
            let colors = AutoBeautify.suggestColors(source:source)
            state.style.color1 = colors.0;state.style.color2 = colors.1;state.style.background = .gradient
            analysis.colors = colors
        }
        return (state,analysis)
    }
}
