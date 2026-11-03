import Foundation
@main struct Checks {
 @MainActor static func main() async {
  var count = 0
  func check(_ ok: Bool, _ label: String) { precondition(ok,label); count += 1; print("PASS \(label)") }
  func settle() async { for _ in 0..<100 { await Task.yield() } }
  let main = DisplayInfo(id:1,name:"main",width:1920,height:1080,isMain:true)
  let owned = DisplayInfo(id:42,name:"owned",width:1366,height:1024,isMain:false,role:"ipadExtendedDesktop")
  func catalog(_ ds:[DisplayInfo], active:StreamSource = .none, id:UInt32? = nil, revision:String = "r0", epoch:VideoEpoch? = nil) -> WindowList {
   WindowList(macName:"test",windows:[],active:active,launchID:"host",selectionRevision:revision,inputGeneration:epoch?.generation,videoEpoch:epoch,displaySelection:1,displays:ds,displayInventoryID:UUID(),activeDisplayID:id,extendedDesktopControl:1)
  }
  func viewports(_ c:Client) -> [Viewport] { c.allSent.compactMap { kind,data in kind == .viewport ? Wire.decode(Viewport.self,from:data) : nil } }
  func requests(_ c:Client) -> Int { viewports(c).filter { $0.extendedDesktopIntent == .request }.count }
  func selections(_ c:Client) -> Int { c.allSent.filter { $0.0 == .selectDisplay }.count }
  func viewport() -> Viewport { Viewport(width:900,height:600,scale:1,extendedDesktop:.init(width:1366,height:1024)) }
  UIDevice.current.userInterfaceIdiom = .phone
  let phone=Client();check(!phone.wantsExtendedDesktop,"phone unchanged")
  UIDevice.current.userInterfaceIdiom = .pad
  let c=Client(); check(c.wantsExtendedDesktop,"iPad defaults extended")
  c.prepareAutomaticTicketCatalog(catalog([main]));check(requests(c)==0,"wait for valid viewport")
  c.sendViewport(viewport());check(requests(c)==1,"viewport starts default extended request")
  let requestID=c.pendingExtendedDesktop!.requestID
  for _ in 0..<10 { c.selectIPadExtendedDesktop(); c.prepareAutomaticTicketCatalog(catalog([main])) }
  check(requests(c)==1 && c.pendingExtendedDesktop?.requestID==requestID,"duplicate user/catalog requests suppressed")
  c.prepareAutomaticTicketCatalog(catalog([main,owned]));await settle()
  check(selections(c)==1 && c.extendedDesktopRequestPending,"submission is not acknowledgement")
  c.prepareAutomaticTicketCatalog(catalog([main,owned]));await settle();check(selections(c)==1,"duplicate catalog cannot resend selection")
  c.select(.window(22));await settle();check(!c.wantsExtendedDesktop && !c.extendedDesktopRequestPending,"explicit window cancels intent and pending")
  c.prepareAutomaticTicketCatalog(catalog([owned]));check(requests(c)==1,"late catalog cannot revive explicit cancellation")
  let restarted=Client();check(restarted.wantsExtendedDesktop,"new client resets explicit mode to extended")
  restarted.prepareAutomaticTicketCatalog(catalog([main]));restarted.sendViewport(viewport())
  let deadline=restarted.pendingExtendedDesktop!.deadline
  restarted.expireExtendedDesktopRequest(now:deadline);check(!restarted.extendedDesktopRequestPending && restarted.extendedDesktopRetryScheduled,"deadline releases and schedules recovery")
  try? await Task.sleep(nanoseconds:2_200_000_000)
  check(requests(restarted)==2 && restarted.pendingExtendedDesktop?.requestID != requestID,"retry creates fresh request token")
  restarted.select(.none);await settle();check(!restarted.wantsExtendedDesktop,"explicit stop cancels retries")
  let ack=Client();ack.prepareAutomaticTicketCatalog(catalog([main]));ack.sendViewport(viewport())
  ack.prepareAutomaticTicketCatalog(catalog([main,owned],revision:"created"));await settle()
  ack.prepareAutomaticTicketCatalog(catalog([main,owned],active:.desktop,id:42,revision:"created"))
  check(ack.extendedDesktopRequestPending,"same selection revision cannot acknowledge")
  let epoch=VideoEpoch(generation:"g1",source:.desktop,geometry:.init(x:0,y:0,width:1366,height:1024),width:1366,height:1024)
  let accepted=catalog([main,owned],active:.desktop,id:42,revision:"selected",epoch:epoch)
  ack.prepareAutomaticTicketCatalog(accepted);await settle()
  check(!ack.extendedDesktopRequestPending && ack.extendedDesktopAttempts==0,"fresh revision and video epoch acknowledge and reset budget")
  for _ in 0..<10 { ack.prepareAutomaticTicketCatalog(accepted) }
  check(requests(ack)==1,"success catalogs do not reallocate")
  let stableRequests=requests(ack);let stableSelections=selections(ack)
  ack.selectIPadExtendedDesktop();await settle()
  check(requests(ack)==stableRequests && selections(ack)==stableSelections && !ack.extendedDesktopRequestPending,
        "already active extended display reselection is idempotent without a fresh epoch")
  ack.resumeExtendedDesktopIntent();check(!ack.extendedDesktopRetryScheduled,"foreground keeps active extended display")
  _ = ack.link.hold(ack.connection!)
  ack.selectDisplay(main)
  ack.selectIPadExtendedDesktop()
  check(ack.extendedDesktopRequestPending && ack.wantsExtendedDesktop,
        "extended reselection supersedes an outstanding alternate display choice")
  _ = ack.link.unhold(ack.connection!);await settle()
  let fg=Client();fg.extendedDesktopAttempts=3;fg.resumeExtendedDesktopIntent()
  check(fg.extendedDesktopAttempts==0 && fg.extendedDesktopRetryScheduled,"foreground with nil IDs resets exhausted budget")
  fg.select(.none);await settle()
  let held=Client();held.prepareAutomaticTicketCatalog(catalog([main,owned]));let hp=held.connection!
  _ = held.link.hold(hp);held.sendViewport(viewport());held.select(.window(10));_ = held.link.unhold(hp);await settle()
  check(requests(held)==0 && selections(held)==0,"held request and selection cancelled before network submission")
  check(Client.noAutoDesktop,"legacy SillNoAutoDesktop preference loaded by production initializer")
  let migrated=Client()
  migrated.prepareAutomaticTicketCatalog(catalog([main]));migrated.sendViewport(viewport())
  check(requests(migrated)==1,"legacy no-auto-desktop preference does not override iPad extended default")
  migrated.selectDisplay(main);await settle();check(!migrated.wantsExtendedDesktop,"explicit main display remains chosen for current process")
  let cancelled=Client();cancelled.prepareAutomaticTicketCatalog(catalog([main]));cancelled.sendViewport(viewport())
  cancelled.expireExtendedDesktopRequest(now:cancelled.pendingExtendedDesktop!.deadline)
  cancelled.select(.none);try? await Task.sleep(nanoseconds:2_200_000_000)
  check(requests(cancelled)==1,"scheduled retry cannot revive explicit stop")
  let reconnect=Client();reconnect.prepareAutomaticTicketCatalog(catalog([main]));reconnect.sendViewport(viewport())
  reconnect.beginAutomaticConnectionOpportunity(peer:reconnect.connection)
  check(!reconnect.extendedDesktopRequestPending && reconnect.extendedDesktopAttempts==0,"connection opportunity clears pending without stale release")
  reconnect.prepareAutomaticTicketCatalog(catalog([main]));check(requests(reconnect)==2,"fresh admitted catalog restarts retained extended intent")
  let late=Client();late.prepareAutomaticTicketCatalog(catalog([main]));late.sendViewport(viewport())
  late.expireExtendedDesktopRequest(now:late.pendingExtendedDesktop!.deadline)
  late.prepareAutomaticTicketCatalog(catalog([main,owned],active:.desktop,id:42,revision:"late",epoch:epoch))
  try? await Task.sleep(nanoseconds:2_200_000_000)
  check(requests(late)==1,"late active catalog during backoff suppresses queued retry")
  let bg=Client();bg.prepareAutomaticTicketCatalog(catalog([main]));bg.sendViewport(viewport())
  bg.expireExtendedDesktopRequest(now:bg.pendingExtendedDesktop!.deadline);bg.suspendExtendedDesktopIntent()
  try? await Task.sleep(nanoseconds:2_200_000_000)
  check(requests(bg)==1,"background cannot send scheduled retry")
  bg.resumeExtendedDesktopIntent();try? await Task.sleep(nanoseconds:2_200_000_000)
  check(requests(bg)==2,"foreground resumes desired extended request")
  bg.select(.none);bg.suspendExtendedDesktopIntent();bg.resumeExtendedDesktopIntent()
  check(!bg.extendedDesktopRetryScheduled,"foreground preserves explicit stop")
  print("TOTAL \(count)")
 }
}
