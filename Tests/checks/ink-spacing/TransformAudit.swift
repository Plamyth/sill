import Foundation
import PencilKit
import AppKit
@main struct TransformAudit {
 static func main() throws {
  setbuf(stdout,nil)
  let p=[CGPoint(x:80,y:20),CGPoint(x:80,y:50)].enumerated().map { i,v in PKStrokePoint(location:v,timeOffset:Double(i)/10,size:CGSize(width:3,height:3),opacity:0.8,force:0.5,azimuth:0.2,altitude:1) }
  let a=PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:p,creationDate:Date(timeIntervalSince1970:1)))
  let before=try PKDrawing(data:PKDrawing(strokes:[a]).dataRepresentation()).strokes[0]
  var changed=before;changed.transform=before.transform.concatenating(CGAffineTransform(translationX:20,y:0))
  let after=try PKDrawing(data:PKDrawing(strokes:[changed]).dataRepresentation()).strokes[0]
  print("ID",before.id==after.id,"ink",before.ink.inkType==after.ink.inkType,before.ink.color.isEqual(after.ink.color),"seed",before.randomSeed==after.randomSeed,"group",before.renderGroupID==after.renderGroupID,"state",before.renderState==after.renderState,"transform",after.transform==before.transform.concatenating(CGAffineTransform(translationX:20,y:0)))
  for (x,y) in zip(before.path,after.path) { print("point",x.location==y.location,x.force==y.force,x.timeOffset==y.timeOffset,x.size==y.size,x.opacity==y.opacity,x.azimuth==y.azimuth,x.altitude==y.altitude) }
  print("UNSELECTED_WRAPPER_EQUAL",PKDrawing(strokes:[before]) == PKDrawing(strokes:[before]))
 }
}
