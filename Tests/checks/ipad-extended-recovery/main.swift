import Foundation
@main struct Checks {
 @MainActor static func main() async {
  var count = 0
  func check(_ ok: Bool, _ label: String) { precondition(ok,label); count += 1; print("PASS \(label)") }
  func settle() async { for _ in 0..<100 { await Task.yield() } }
  let main = DisplayInfo(id:1,name:"main",width:1920,height:1080,isMain:true)
  let owned = DisplayInfo(id:42,name:"owned",width:1366,height:1024,isMain:false,role:"ipadExtendedDesktop")
  let stableInventory=UUID()
  func catalog(_ ds:[DisplayInfo], active:StreamSource = .none, id:UInt32? = nil, revision:String = "r0", epoch:VideoEpoch? = nil, inventory:UUID? = nil) -> WindowList {
   WindowList(macName:"test",windows:[],active:active,launchID:"host",selectionRevision:revision,inputGeneration:epoch?.generation,videoEpoch:epoch,displaySelection:1,displays:ds,displayInventoryID:inventory ?? stableInventory,activeDisplayID:id,sourceSelectionAdmission:.init(generation:1,ready:true),extendedDesktopControl:1)
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
  func move(_ client: Client, kind: Client.MoveKind = .toCable) -> (NWConnection, NWConnection) {
   let old=client.connection!, next=NWConnection()
   client.finishMoveAfterInputDrain(next,kind:kind,kept:[])
   return (old,next)
  }
  func messages<T: Decodable>(_ peer: NWConnection, kind: StreamMessageKind, type: T.Type) -> [T] {
   peer.packets.compactMap { packet in
    guard let header=StreamMessage.parseHeader(Data(packet.prefix(StreamMessage.headerLength))),header.kind==kind else { return nil }
    return Wire.decode(type,from:Data(packet.dropFirst(StreamMessage.headerLength)))
   }
  }
  func ownRequests(_ peer: NWConnection) -> Int {
   messages(peer,kind:.viewport,type:Viewport.self).filter { $0.extendedDesktopIntent == .request }.count
  }
  let moving=Client();moving.prepareAutomaticTicketCatalog(catalog([main,owned]));moving.sendViewport(viewport())
  let oldRequest=moving.pendingExtendedDesktop!, oldSelection=oldRequest.selection!
  let (oldPeer,newPeer)=move(moving)
  check(moving.connection === newPeer && moving.sourceSelectionObservation == nil && !moving.automaticDisplayCatalogObserved,
        "fenced finishMove clears old peer admission and catalog opportunity")
  check(moving.selectionRevision == nil && moving.sourceCatalogEpoch == nil && moving.displays.isEmpty && moving.displayCatalogPeer == nil,
        "fenced move invalidates old display inventory and epoch")
  check(ownRequests(newPeer)==0,"new peer waits for its admitted catalog before requesting")
  _ = moving.link.release(oldPeer);await settle()
  moving.prepareAutomaticTicketCatalog(catalog([main]));await settle()
  check(ownRequests(newPeer)==1 && moving.pendingExtendedDesktop?.peer === newPeer,
        "new peer submits its own request after old requester retirement")
  check(moving.pendingExtendedDesktop?.deadline==oldRequest.deadline && moving.extendedDesktopAttempts==1,
        "fenced pending move preserves original deadline and attempt budget")
  let newRequest=moving.pendingExtendedDesktop!.requestID
  moving.link.cancel(oldRequest.request);moving.link.cancel(oldSelection);await settle()
  moving.expireExtendedDesktopRequest(now:oldRequest.deadline-1)
  check(moving.pendingExtendedDesktop?.requestID==newRequest && !viewports(moving).contains { $0.extendedDesktopIntent == .release },
        "late old request and selection callbacks cannot release new requester")
  let recreated=DisplayInfo(id:71,name:"recreated",width:1366,height:1024,isMain:false,role:"ipadExtendedDesktop")
  moving.prepareAutomaticTicketCatalog(catalog([main,recreated],revision:"new-created"));await settle()
  let picked=messages(newPeer,kind:.selectDisplay,type:DisplaySelection.self)
  check(picked.count==1 && picked.first?.displayID==71 && picked.first?.inventoryID==moving.displayInventoryID,
        "new inventory selects recreated extended identity with changed display ID")
  let beforeRevision=moving.selectionRevision
  moving.observeSourceSelectionAdmission(catalog([owned],revision:"late-old"),peer:oldPeer)
  moving.observeExtendedDesktopCatalog(catalog([owned],revision:"late-old"),peer:oldPeer)
  check(moving.selectionRevision==beforeRevision && moving.pendingExtendedDesktop?.requestID==newRequest,
        "late old catalog cannot rebind selection or epoch")
  let newEpoch=VideoEpoch(generation:"g2",source:.desktop,geometry:.init(x:0,y:0,width:1366,height:1024),width:1366,height:1024)
  moving.prepareAutomaticTicketCatalog(catalog([main,recreated],active:.desktop,id:71,revision:"new-selected",epoch:newEpoch))
  check(!moving.extendedDesktopRequestPending,"new selection still requires fresh revision and video epoch acknowledgement")
  let video=Client();video.prepareAutomaticTicketCatalog(catalog([main,owned]));video.sendViewport(viewport())
  video.prepareAutomaticTicketCatalog(catalog([main,owned],active:.desktop,id:42,revision:"old-selected",epoch:epoch))
  video.startupVideoRecorded=true
  let (videoOld,videoNew)=move(video);_ = video.link.release(videoOld)
  check(!video.startupVideoRecorded,"old video success cannot satisfy new peer startup observation")
  video.prepareAutomaticTicketCatalog(catalog([main,owned],active:.desktop,id:42,revision:"same-active",epoch:epoch));await settle()
  check(ownRequests(videoNew)==1,"old successful display does not confer requester ownership to new peer")
  video.prepareAutomaticTicketCatalog(catalog([main,owned],active:.desktop,id:42,revision:"same-epoch",epoch:epoch))
  check(video.extendedDesktopRequestPending,"old video epoch cannot acknowledge the rebound selection")
  video.prepareAutomaticTicketCatalog(catalog([main,owned],active:.desktop,id:42,revision:"fresh-epoch",epoch:newEpoch))
  check(!video.extendedDesktopRequestPending,"fresh current-peer epoch acknowledges after old video success")
  let heldMove=Client();heldMove.prepareAutomaticTicketCatalog(catalog([main,owned]));_ = heldMove.link.hold(heldMove.connection!)
  heldMove.sendViewport(viewport())
  let (_,heldNew)=move(heldMove,kind:.toWifi)
  check(heldMove.connection === heldNew && ownRequests(heldNew)==0,"nonfenced adopt drops old peer queued request and release")
  heldMove.prepareAutomaticTicketCatalog(catalog([main,recreated]));await settle()
  check(ownRequests(heldNew)==1 && heldMove.pendingExtendedDesktop?.peer === heldNew,"nonfenced move also rebinds through new catalog")
  check(messages(heldNew,kind:.viewport,type:Viewport.self).allSatisfy { $0.extendedDesktopIntent != .release },
        "old requester release never migrates across SessionLink adopt")
  let exhausted=Client();exhausted.prepareAutomaticTicketCatalog(catalog([main]));exhausted.sendViewport(viewport())
  exhausted.extendedDesktopAttempts=3;let exhaustedDeadline=exhausted.pendingExtendedDesktop!.deadline
  let (exhaustedOld,exhaustedNew)=move(exhausted);_ = exhausted.link.release(exhaustedOld)
  exhausted.prepareAutomaticTicketCatalog(catalog([main]));await settle()
  check(ownRequests(exhaustedNew)==1 && exhausted.extendedDesktopAttempts==3 && exhausted.pendingExtendedDesktop?.deadline==exhaustedDeadline,
        "third in-flight attempt is rebound without granting another attempt")
  exhausted.expireExtendedDesktopRequest(now:exhaustedDeadline);await settle()
  check(!exhausted.extendedDesktopRequestPending && !exhausted.extendedDesktopRetryScheduled,"new peer failure respects exhausted retry budget")
  let retained=Client();retained.prepareAutomaticTicketCatalog(catalog([main]));retained.sendViewport(viewport())
  retained.extendedDesktopAttempts=3
  let retainedDeadline=retained.pendingExtendedDesktop!.deadline
  let (retainedOld,retainedNew)=move(retained)
  retained.prepareAutomaticTicketCatalog(catalog([main,owned]));await settle()
  let oldInventorySelection=retained.pendingExtendedDesktop!.selection!
  let oldSelectionID=retained.pendingExtendedDesktop!.selectionID
  _ = retained.link.release(retainedOld);await settle()
  let newInventory=UUID()
  retained.prepareAutomaticTicketCatalog(catalog([main,recreated],revision:"recreated-after-fence",inventory:newInventory));await settle()
  let reboundChoices=messages(retainedNew,kind:.selectDisplay,type:DisplaySelection.self)
  check(reboundChoices.map(\.displayID)==[42,71] && reboundChoices.last?.inventoryID==newInventory,
        "retained stale catalog selection is replaced by recreated current inventory")
  check(retained.extendedDesktopAttempts==3 && retained.pendingExtendedDesktop?.deadline==retainedDeadline,
        "inventory replacement preserves exhausted in-flight attempt and deadline")
  check(retained.pendingExtendedDesktop?.selectionID != oldSelectionID && ownRequests(retainedNew)==1,
        "selection replacement uses a fresh selection token without another requester attempt")
  retained.link.cancel(oldInventorySelection);await settle()
  check(retained.extendedDesktopRequestPending && messages(retainedNew,kind:.viewport,type:Viewport.self).allSatisfy { $0.extendedDesktopIntent != .release },
        "retired selection callback cannot release current requester")
  retained.prepareAutomaticTicketCatalog(catalog([main,recreated],active:.desktop,id:71,revision:"recreated-selected",epoch:newEpoch,inventory:newInventory))
  check(!retained.extendedDesktopRequestPending,"recreated identity requires and accepts its fresh epoch acknowledgement")
  let sameID=Client();sameID.prepareAutomaticTicketCatalog(catalog([main]));sameID.sendViewport(viewport())
  sameID.prepareAutomaticTicketCatalog(catalog([main,owned]));await settle()
  let changedInventory=UUID()
  sameID.prepareAutomaticTicketCatalog(catalog([main,owned],revision:"inventory-replaced",inventory:changedInventory));await settle()
  check(selections(sameID)==2 && sameID.pendingExtendedDesktop?.selectionInventory==changedInventory,
        "same display ID with replaced inventory also rebinds selection")
  let queued=Client();queued.prepareAutomaticTicketCatalog(catalog([main]));queued.sendViewport(viewport())
  let (queuedOld,queuedNew)=move(queued)
  queued.prepareAutomaticTicketCatalog(catalog([main,owned]))
  let queuedOldSelection=queued.pendingExtendedDesktop!.selection!
  queued.prepareAutomaticTicketCatalog(catalog([main,recreated],revision:"recreated-before-fence",inventory:UUID()))
  let queuedCurrentSelectionID=queued.pendingExtendedDesktop!.selectionID
  await settle()
  check(queued.extendedDesktopRequestPending && queued.pendingExtendedDesktop?.selectionID==queuedCurrentSelectionID,
        "cancelled queued selection callback cannot cancel its current replacement")
  _ = queued.link.release(queuedOld);queued.link.cancel(queuedOldSelection);await settle()
  let queuedChoices=messages(queuedNew,kind:.selectDisplay,type:DisplaySelection.self)
  check(queuedChoices.map(\.displayID)==[71] && ownRequests(queuedNew)==1,
        "fence sends only the latest inventory selection and one requester")
  let stale=Client();stale.prepareAutomaticTicketCatalog(catalog([main]));stale.sendViewport(viewport())
  let stalePending=stale.pendingExtendedDesktop!
  stale.pendingExtendedDesktop = .init(peer:stalePending.peer,macID:stalePending.macID,host:stalePending.host,
      intent:stalePending.intent,deadline:ProcessInfo.processInfo.systemUptime-1,request:stalePending.request,
      requestID:stalePending.requestID,revision:stalePending.revision,epoch:stalePending.epoch)
  stale.extendedDesktopAttempts=3
  let (staleOld,staleNew)=move(stale);_ = stale.link.release(staleOld)
  stale.prepareAutomaticTicketCatalog(catalog([main]));await settle()
  check(ownRequests(staleNew)==0 && !stale.extendedDesktopRequestPending && !stale.extendedDesktopRetryScheduled,
        "deadline elapsed while awaiting new catalog cannot create a fresh attempt")
  let trusted=Client();trusted.prepareAutomaticTicketCatalog(catalog([main]));trusted.sendViewport(viewport())
  let (trustedOld,trustedNew)=move(trusted);_ = trusted.link.release(trustedOld)
  trusted.session?.home = .plain
  trusted.prepareAutomaticTicketCatalog(catalog([main,recreated]));await settle()
  check(ownRequests(trustedNew)==0 && selections(trusted)==0,"new catalog without saved trust cannot request or select")
  trusted.session?.home = .saved(pin:Data([1]))
  trusted.prepareAutomaticTicketCatalog(catalog([main,recreated]));await settle()
  check(ownRequests(trustedNew)==1 && selections(trusted)==1,"retained trust and fresh catalog admit own request before selection")
  for chooseDisplay in [false,true] {
   let explicit=Client();explicit.prepareAutomaticTicketCatalog(catalog([main,owned]));explicit.sendViewport(viewport())
   if chooseDisplay { explicit.selectDisplay(main) } else { explicit.select(.none) }
   let intent=explicit.explicitSourceIntent
   let (explicitOld,explicitNew)=move(explicit);_ = explicit.link.release(explicitOld)
   explicit.prepareAutomaticTicketCatalog(catalog([main,recreated]));await settle()
   check(!explicit.wantsExtendedDesktop && ownRequests(explicitNew)==0 && explicit.explicitSourceIntent==intent,
         chooseDisplay ? "handoff preserves explicit alternate display choice" : "handoff cannot revive explicit stop")
   let waiting=Client();waiting.prepareAutomaticTicketCatalog(catalog([main,owned]));waiting.sendViewport(viewport())
   let (waitingOld,waitingNew)=move(waiting)
   if chooseDisplay { waiting.selectDisplay(main) } else { waiting.select(.none) }
   _ = waiting.link.release(waitingOld)
   waiting.prepareAutomaticTicketCatalog(catalog([main,recreated]));await settle()
   check(!waiting.wantsExtendedDesktop && ownRequests(waitingNew)==0,
         chooseDisplay ? "alternate display chosen during handoff cancels rebind" : "stop during handoff cancels rebind")
  }
  let chained=Client();chained.prepareAutomaticTicketCatalog(catalog([main]));chained.sendViewport(viewport())
  let chainedDeadline=chained.pendingExtendedDesktop!.deadline
  let (firstPeer,middlePeer)=move(chained)
  let (_,lastPeer)=move(chained)
  chained.prepareAutomaticTicketCatalog(catalog([main,recreated]));await settle()
  check(chained.pendingExtendedDesktop?.deadline==chainedDeadline && chained.extendedDesktopAttempts==1,
        "back-to-back handoffs retain the first pending deadline and attempt")
  _ = chained.link.release(firstPeer);_ = chained.link.release(middlePeer);await settle()
  check(ownRequests(lastPeer)==1 && ownRequests(middlePeer)==0,
        "only final peer owns the request after both transport fences drain")
  print("TOTAL \(count)")
 }
}
