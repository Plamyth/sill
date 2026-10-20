#!/usr/bin/env python3
"""Run catalog admission and direct resolution with inert SCWindow adapters."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
PATH = 'Sources/SillHost/WindowCatalog.swift'
spec = importlib.util.spec_from_file_location('focus_checks', ROOT/'Tests/checks/host-input-focus-fence/run.py')
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', action='store_true')
args = parser.parse_args()
current = (ROOT/PATH).read_text()
source = subprocess.check_output(['git','show','0bd26cc55791d81d29ff3565dfcb15f82dde2ad6:'+PATH],cwd=ROOT,text=True) if args.baseline else current
methods = [focus.function(current, 'nonisolated static func isPrivateApplication('),
           focus.function(current, 'static func isShareableWindow('),
           focus.function(current, 'static func isSystemHelperWindow('),
           focus.function(current, 'static func isOwn('),
           focus.function(source, 'func window(id:'),
           focus.function(source, 'func resolveWindow(id:')]
program = r'''
import Foundation
import CoreGraphics
struct App {var applicationName="Fixture";var bundleIdentifier="com.example.fixture";var processID:Int32=55}
struct SCWindow {var windowID:UInt32;var title:String?="Fixture";var owningApplication:App?=App();var windowLayer=0;var frame=CGRect(x:0,y:0,width:600,height:400)}
struct Content {var windows:[SCWindow]}
final class WindowCatalog {
 static let ownPID:Int32=99
 var windows:[SCWindow]=[]
 static var available:[SCWindow]=[]
 static func shareableContent(excludingDesktopWindows:Bool,onScreenWindowsOnly:Bool,timeout:Double) async -> Content? {Content(windows:available)}
''' + '\n'.join(methods) + r'''
}
var checks=0
func check(_ value:Bool,_ label:String) {guard value else {print("FAIL \(label)");exit(1)};checks+=1}
@main struct Check {
 static func main() async {
 let catalog=WindowCatalog()
 var helper=SCWindow(windowID:4951)
 helper.owningApplication?.bundleIdentifier="com.openai.sky.CUAService"
 helper.title="Enable ChatGPT with Messages Permissions"
 WindowCatalog.available=[helper]
 let direct=await catalog.resolveWindow(id:4951)
 check(direct == nil,"direct ID cannot resolve CUA helper")
 catalog.windows=[helper]
 check(catalog.window(id:4951)==nil,"stale cached CUA helper denied")
 let cached=await catalog.resolveWindow(id:4951)
 check(cached==nil,"cached helper cannot bypass fresh lookup")
 check(!WindowCatalog.isShareableWindow(helper),"permissions helper excluded")
 helper.title="Software Cursor";helper.frame.size=CGSize(width:126,height:126)
 check(!WindowCatalog.isShareableWindow(helper),"126pt software cursor excluded")
 var normal=SCWindow(windowID:4943)
 normal.owningApplication?.bundleIdentifier="com.openai.codex"
 normal.title="Control Room 모바일 전용"
 check(WindowCatalog.isShareableWindow(normal),"actual ordinary ChatGPT workspace retained")
 normal.title="Software Cursor"
 check(WindowCatalog.isShareableWindow(normal),"same title in user app retained")
 normal.owningApplication?.bundleIdentifier="com.openai.sky.CUAService.user"
 check(WindowCatalog.isShareableWindow(normal),"bundle prefix lookalike retained")
 normal.owningApplication?.bundleIdentifier="com.example.fixture"
 WindowCatalog.available=[normal];catalog.windows=[]
 let staged=await catalog.resolveWindow(id:4943)
 check(staged?.windowID==4943,"offscreen staged ordinary window can resolve")
 catalog.windows=[normal]
 check(catalog.window(id:4943)?.windowID==4943,"ordinary cached window retained")
 normal.owningApplication?.processID=99
 check(!WindowCatalog.isShareableWindow(normal),"own pairing window denied")
 normal.owningApplication?.processID=55;normal.title="LayerProbeParent"
 check(!WindowCatalog.isShareableWindow(normal),"layer probe denied")
 WindowCatalog.available=[normal];catalog.windows=[]
 let layer=await catalog.resolveWindow(id:4943)
 check(layer==nil,"direct layer probe denied")
 normal.title="Fixture";normal.windowLayer=3
 check(!WindowCatalog.isShareableWindow(normal),"nonstandard window layer denied")
 normal.windowLayer=0;normal.frame.size.width=100
 check(!WindowCatalog.isShareableWindow(normal),"tiny helper denied")
 normal.frame.size.width=600;normal.owningApplication=nil
 check(!WindowCatalog.isShareableWindow(normal),"unknown owner denied")
 check(!WindowCatalog.isPrivateApplication("com.openai.codex"),"normal app inventory retained")
 check(WindowCatalog.isPrivateApplication("com.openai.sky.CUAService"),"helper app inventory denied")
 print("PASS \(checks) helper admission checks; no capture, app launch, or selection invoked")
 }
}
'''
# Swift stdin uses top-level declarations; schedule async checks without starting an app.
program = program.replace('@main struct Check {','struct Check {') + '\nTask { await Check.main(); exit(0) }\ndispatchMain()\n'
runner = '''import hashlib,subprocess,sys
source=sys.stdin.buffer.read()
print('received_sha256='+hashlib.sha256(source).hexdigest(),flush=True)
result=subprocess.run(['/usr/bin/swift','-'],input=source,timeout=120)
del source
print('RAM input released; no source checkout',flush=True)
raise SystemExit(result.returncode)
'''
original=hashlib.sha256((ROOT/PATH).read_bytes()).hexdigest()
print('sent_sha256='+hashlib.sha256(program.encode()).hexdigest(),flush=True)
result=subprocess.run(['/Users/ambrion/.local/bin/mini','run','--cwd','/Users/sin-wonho','--','python3','-B','-c',runner],input=program,text=True,timeout=180)
assert hashlib.sha256((ROOT/PATH).read_bytes()).hexdigest()==original
print('source_unchanged='+original)
raise SystemExit(result.returncode)
