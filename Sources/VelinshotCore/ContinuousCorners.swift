import CoreGraphics
import SwiftUI

/// One native curve for screenshot clipping and every treatment of its edge.
enum ContinuousCorners {
    static func path(in rect:CGRect,radius:CGFloat) -> CGPath {
        let bounded = max(0,min(radius,min(rect.width,rect.height)/2))
        guard bounded > 0 else {
            return CGPath(roundedRect:rect,cornerWidth:0,cornerHeight:0,transform:nil)
        }
        return SwiftUI.Path(roundedRect:rect,cornerRadius:bounded,style:.continuous).cgPath
    }
}
