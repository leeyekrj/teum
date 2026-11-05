import AppKit
let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
let image = NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
NSColor(calibratedRed:0.055,green:0.067,blue:0.086,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:35,y:35,width:954,height:954),xRadius:215,yRadius:215).fill()
let colors:[NSColor] = [.init(calibratedRed:0.88,green:0.57,blue:0.42,alpha:1),.init(calibratedRed:0.49,green:0.80,blue:0.71,alpha:1),.init(calibratedRed:0.74,green:0.64,blue:0.96,alpha:1),.init(calibratedRed:0.48,green:0.70,blue:0.96,alpha:1)]
let heights:[CGFloat] = [230,350,275,410,300,365,210]
for i in 0..<7 {
 let x:CGFloat = 202+CGFloat(i)*88
 NSColor.white.withAlphaComponent(0.12).setFill()
 NSBezierPath(roundedRect:NSRect(x:x,y:300,width:48,height:425),xRadius:24,yRadius:24).fill()
 colors[i%4].setFill()
 NSBezierPath(roundedRect:NSRect(x:x,y:300,width:48,height:heights[i]),xRadius:24,yRadius:24).fill()
}
image.unlockFocus()
let sizes:[(String,Int)] = [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)]
for (name,size) in sizes {
 let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
 image.draw(in:NSRect(x:0,y:0,width:size,height:size),from:.zero,operation:.copy,fraction:1)
 NSGraphicsContext.restoreGraphicsState()
 try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:out+"/"+name))
}
