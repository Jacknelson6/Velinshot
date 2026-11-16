import CoreGraphics
import VelinshotCore

enum NewDocument {
    static func state(source:CGImage,style:CanvasStyle) -> EditState {
        var state = EditState(style:style)
        if style.autoBalance { state.crop = AutoBeautify.contentBounds(source:source) }
        if style.autoColor {
            let colors = AutoBeautify.suggestColors(source:source)
            state.style.color1 = colors.0;state.style.color2 = colors.1;state.style.background = .gradient
        }
        return state
    }
}
