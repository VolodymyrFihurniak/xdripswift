//
//  xDripWidgetBundle.swift
//  XDripWidget
//
//  Created by Paul Plant on 30/12/23.
//  Copyright © 2023 Johan Degraeve. All rights reserved.
//

import WidgetKit
import SwiftUI

@main
struct XDripWidgetBundle: WidgetBundle {
    var body: some Widget {
        XDripWidget()
        if #available(iOSApplicationExtension 17.0, *) {
            AdaptiveStatusWidget()
        }
        XDripWidgetLiveActivity()
    }
}
