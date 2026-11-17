import AppKit

enum StudioMetrics {
    static let toolTarget:CGFloat = 44
    static let controlHeight:CGFloat = 40
    static let toolSymbol:CGFloat = 20
    static let toolbarSymbol:CGFloat = 18
}

/// Static native surfaces redraw only when their appearance or content changes.
enum StudioPalette {
    static let surface = NSColor(name:"Studio surface") { appearance in
        appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
            ? NSColor(srgbRed:0.115,green:0.119,blue:0.145,alpha:1)
            : NSColor(srgbRed:0.982,green:0.981,blue:0.987,alpha:1)
    }
    static let canvas = NSColor(name:"Studio canvas") { appearance in
        appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
            ? NSColor(srgbRed:0.077,green:0.081,blue:0.103,alpha:1)
            : NSColor(srgbRed:0.900,green:0.907,blue:0.938,alpha:1)
    }
    static let accent = NSColor(name:"Studio accent") { appearance in
        appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
            ? NSColor(srgbRed:0.70,green:0.65,blue:1,alpha:1) : Brand.iris
    }
    static let field = NSColor(name:"Studio input") { appearance in
        appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
            ? NSColor(srgbRed:0.19,green:0.20,blue:0.24,alpha:1)
            : NSColor(srgbRed:0.93,green:0.93,blue:0.96,alpha:1)
    }
}

final class StudioSurface:NSView {
    var fill:NSColor = StudioPalette.surface
    override func draw(_ dirtyRect:NSRect) {
        fill.setFill();bounds.fill()
    }
}

/// Uses ordinary NSButton targeting, keyboard navigation and accessibility.
/// Hover is event-driven; there are no animations, timers or idle refreshes.
class StudioButton:NSButton {
    enum Kind { case quiet, secondary, primary, tool, footer }
    var kind:Kind = .quiet
    var shortcut:String?
    var imageSpacing:CGFloat = 7
    var symbolSize:CGFloat?
    var showsMenuIndicator = false
    var actionHandler:(()->Void)?
    private var hovered = false
    private var tracking:NSTrackingArea?
    convenience init(_ title:String = "",symbol:String? = nil,kind:Kind = .quiet,shortcut:String? = nil,action:@escaping()->Void) {
        self.init(frame:.zero)
        self.title = title;self.kind = kind;self.shortcut = shortcut;self.actionHandler = action
        if !title.isEmpty { setAccessibilityLabel(title) }
        if let symbol { image = Brand.symbol(symbol,size:kind == .tool ? StudioMetrics.toolSymbol : StudioMetrics.toolbarSymbol) }
        font = .systemFont(ofSize:13,weight:.medium)
        isBordered = false;focusRingType = .exterior;setButtonType(.momentaryPushIn)
        target = self;self.action = #selector(invoke)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant:controlHeight).isActive = true
    }
    private var controlHeight:CGFloat { kind == .tool ? StudioMetrics.toolTarget : StudioMetrics.controlHeight }
    override var alignmentRectInsets:NSEdgeInsets { NSEdgeInsets(top:0,left:0,bottom:0,right:0) }
    @objc private func invoke() { actionHandler?() }
    override var intrinsicContentSize:NSSize {
        let text = (title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:13)])
        let icon = symbolSize ?? (kind == .tool ? StudioMetrics.toolSymbol : StudioMetrics.toolbarSymbol)
        return NSSize(width:max(40,text.width+(image == nil ? 0 : icon+(title.isEmpty ? 0 : imageSpacing))+(shortcut == nil ? 0 : 29)+20),height:controlHeight)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);tracking = area
    }
    override func mouseEntered(with event:NSEvent) { hovered = true;needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovered = false;needsDisplay = true }
    override var state:NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled:Bool { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect:NSRect) {
        let selected = kind == .tool && state == .on
        let active = isHighlighted || hovered
        let shape = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8)
        let foreground:NSColor = kind == .primary ? .white : selected ? StudioPalette.accent : .labelColor
        if kind == .primary {
            (isHighlighted ? Brand.iris.blended(withFraction:0.15,of:.black)! : Brand.iris).setFill();shape.fill()
        } else if selected || active || kind == .secondary {
            (selected ? StudioPalette.accent.withAlphaComponent(0.13) : NSColor.labelColor.withAlphaComponent(active ? 0.08 : 0.035)).setFill();shape.fill()
        }
        let alpha:CGFloat = isEnabled ? 1 : 0.35
        let textFont = NSFont.systemFont(ofSize:13,weight:kind == .primary ? .semibold : .medium)
        let textWidth = (title as NSString).size(withAttributes:[.font:textFont]).width
        let iconBox:CGFloat = symbolSize ?? (kind == .tool ? StudioMetrics.toolSymbol : StudioMetrics.toolbarSymbol)
        let total = textWidth+(image == nil ? 0 : (title.isEmpty ? iconBox : iconBox+imageSpacing))+(shortcut == nil ? 0 : 29)+(showsMenuIndicator ? 13 : 0)
        var x = alignment == .left ? 0 : (bounds.width-total)/2
        if let image {
            let tinted = image.withSymbolConfiguration(.init(paletteColors:[foreground.withAlphaComponent(alpha)])) ?? image
            let factor = min(iconBox/max(1,tinted.size.width),iconBox/max(1,tinted.size.height))
            let size = NSSize(width:tinted.size.width*factor,height:tinted.size.height*factor)
            tinted.draw(in:CGRect(x:x+(iconBox-size.width)/2,y:bounds.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:alpha,respectFlipped:true,hints:nil)
            x += title.isEmpty ? iconBox : iconBox+imageSpacing
        }
        (title as NSString).draw(at:CGPoint(x:x,y:bounds.midY-7.5),withAttributes:[.font:textFont,.foregroundColor:foreground.withAlphaComponent(alpha)])
        if let shortcut {
            let rect = CGRect(x:x+textWidth+9,y:bounds.midY-9,width:20,height:18)
            foreground.withAlphaComponent(kind == .primary ? 0.15 : 0.065).setFill()
            NSBezierPath(roundedRect:rect,xRadius:4,yRadius:4).fill()
            let keyFont = NSFont.monospacedSystemFont(ofSize:10,weight:.medium)
            let width = (shortcut as NSString).size(withAttributes:[.font:keyFont]).width
            (shortcut as NSString).draw(at:CGPoint(x:rect.midX-width/2,y:rect.midY-6.5),withAttributes:[.font:keyFont,.foregroundColor:foreground.withAlphaComponent(alpha*0.85)])
        }
        if showsMenuIndicator {
            Brand.symbol("chevron.down",size:9)?.withSymbolConfiguration(.init(paletteColors:[foreground.withAlphaComponent(alpha)]))?.draw(in:CGRect(x:bounds.maxX-13,y:bounds.midY-2.5,width:8,height:5),from:.zero,operation:.sourceOver,fraction:alpha,respectFlipped:true,hints:nil)
        }
    }
    override var focusRingMaskBounds:NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill() }
}

final class StudioSegments:NSSegmentedControl {
    override var alignmentRectInsets:NSEdgeInsets { NSEdgeInsets(top:0,left:0,bottom:0,right:0) }
    override var intrinsicContentSize:NSSize { var size = super.intrinsicContentSize;size.height = 32;return size }
    override func draw(_ dirtyRect:NSRect) {
        guard segmentCount>0 else { return }
        let width = bounds.width/CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let selected = selectedSegment == index
            let font = NSFont.systemFont(ofSize:12,weight:selected ? .semibold : .regular)
            let title = label(forSegment:index) ?? ""
            let size = (title as NSString).size(withAttributes:[.font:font])
            let x = CGFloat(index)*width
            (title as NSString).draw(at:CGPoint(x:x+(width-size.width)/2,y:bounds.midY-size.height/2),withAttributes:[.font:font,.foregroundColor:selected ? StudioPalette.accent : NSColor.secondaryLabelColor])
            if selected {
                StudioPalette.accent.setFill()
                let y:CGFloat = isFlipped ? bounds.height-3 : 0
                NSBezierPath(roundedRect:CGRect(x:x+8,y:y,width:width-16,height:2.5),xRadius:1.25,yRadius:1.25).fill()
            }
        }
    }
}

final class StudioColorWell:NSColorWell {
    var prominentSample = false
    override var alignmentRectInsets:NSEdgeInsets { NSEdgeInsets(top:0,left:0,bottom:0,right:0) }
    override func draw(_ dirtyRect:NSRect) {
        let sampleSize:CGFloat = prominentSample ? 24 : 16
        let sample = CGRect(x:6,y:bounds.midY-sampleSize/2,width:sampleSize,height:sampleSize)
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
        let outer = prominentSample ? NSBezierPath(roundedRect:sample,xRadius:5,yRadius:5) : NSBezierPath(ovalIn:sample)
        outer.fill()
        let inside = sample.insetBy(dx:1.5,dy:1.5)
        NSGraphicsContext.saveGraphicsState()
        let shape = prominentSample ? NSBezierPath(roundedRect:inside,xRadius:4,yRadius:4) : NSBezierPath(ovalIn:inside)
        shape.addClip()
        if color.alphaComponent < 1 {
            let tiles = Int(ceil(inside.width/4))
            for y in 0..<tiles { for x in 0..<tiles {
                ((x+y).isMultiple(of:2) ? NSColor.lightGray : NSColor.white).setFill()
                CGRect(x:inside.minX+CGFloat(x)*4,y:inside.minY+CGFloat(y)*4,width:4,height:4).fill()
            } }
        }
        color.setFill();inside.fill()
        NSGraphicsContext.restoreGraphicsState()
        let rgb = color.usingColorSpace(.sRGB)
        func channel(_ value:CGFloat) -> Int { value.isFinite ? Int((min(1,max(0,value))*255).rounded()) : 0 }
        let hex = rgb.map { String(format:"#%02X%02X%02X",channel($0.redComponent),channel($0.greenComponent),channel($0.blueComponent)) } ?? "Color"
        (hex as NSString).draw(at:CGPoint(x:sample.maxX+7,y:bounds.midY-7),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:prominentSample ? 12 : 11,weight:.medium),.foregroundColor:prominentSample ? NSColor.labelColor : NSColor.secondaryLabelColor])
        Brand.symbol("chevron.down",size:8)?.withSymbolConfiguration(.init(paletteColors:[.secondaryLabelColor]))?.draw(in:CGRect(x:bounds.maxX-12,y:bounds.midY-3,width:7,height:6),from:.zero,operation:.sourceOver,fraction:0.7,respectFlipped:true,hints:nil)
    }
}

final class GradientSwatch:NSButton {
    let first:NSColor
    let second:NSColor
    var actionHandler:(()->Void)?
    init(name:String,first:NSColor,second:NSColor,action:@escaping()->Void) {
        self.first = first;self.second = second;self.actionHandler = action
        super.init(frame:.zero)
        isBordered = false;title = "";toolTip = name;setAccessibilityLabel("\(name) gradient")
        target = self;self.action = #selector(invoke)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant:32).isActive = true;heightAnchor.constraint(equalToConstant:28).isActive = true
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { actionHandler?() }
    override func draw(_ dirtyRect:NSRect) {
        let path = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:7,yRadius:7)
        NSGradient(starting:first,ending:second)?.draw(in:path,angle:35)
        NSColor.black.withAlphaComponent(0.10).setStroke();path.lineWidth = 0.7;path.stroke()
    }
}
