#!/usr/bin/env python3
"""Generate the native Vision target without changing the iPad project."""
from pathlib import Path
import hashlib
import plistlib

ROOT = Path(__file__).resolve().parent.parent
CLIENT = ['StreamClient', 'MockCatalog', 'AwayCopy', 'MacAudioRouteSession', 'MacAudioRouteTransport', 'StreamClient+Home', 'StreamClient+Remote', 'StreamClient+Viewport', 'DeviceIdentity', 'RemoteConnector', 'RemoteDialPolicy', 'SessionLink', 'MessageReader', 'SavedMacs', 'DiscoveryPolicy', 'GoodbyePolicy', 'HEVCDisplayView', 'DiagnosticsHUD', 'HostSettingsLedger', 'MacMenuState', 'MacMenuHub', 'PointerPresence', 'TrackpadGestures', 'TourPolicy', 'DuoPosture', 'InputOverlay', 'KeyChords', 'IPadMicrophoneCapture', 'IPadMicrophonePCM', 'IPadMicrophonePolicy', 'IPadMicrophoneFrameGate']
files = ['iOSClient/' + n + '.swift' for n in CLIENT] + ['visionOSClient/' + n + '.swift' for n in ['SillVisionApp', 'VisionAppSession', 'VisionReleaseTestContext', 'VisionCableBootstrap', 'VisionAutoConnectStatus', 'StreamClient+VisionAutoConnect', 'VisionPointer', 'VisionSpatialInput', 'VisionInputSession', 'VisionInputDebt', 'VisionPresentation', 'VisionRemoteKey', 'VisionKeyPalette', 'HIDKey', 'VisionInputFence', 'VisionTransition', 'VisionRemoteAudioIntent', 'VisionRemoteAudioAuthority', 'VisionAudioState', 'VisionAudioController', 'VisionAudioRoute', 'VisionAudioPlayer', 'VisionAudioHardware', 'VisionAudioNativeGraph', 'VisionMicrophoneCapture', 'StreamClient+VisionMicrophone', 'VisionAudioBuffer', 'VisionTextDraft', 'VisionDraftEditor', 'VisionMacAudioTransport', 'VisionMacAudioController', 'VisionMacAudioChooser', 'VisionMacAudioStatus', 'VisionDisplaySelection', 'StreamClient+VisionDisplaySelection', 'VisionDisplayChooser', 'VisionSentryController', 'StreamClient+VisionSentry', 'VisionTestDestinations', 'VisionTestDestinationsView', 'StreamClient+VisionTestDestinations']]
objects = {}

def obj(key, isa, **fields):
    identifier = hashlib.sha1(key.encode()).hexdigest().upper()[:24]
    objects[identifier] = {'isa': isa, **fields}
    return identifier

refs, builds = [], []
for path in files:
    ref = obj(path, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=path, sourceTree='SOURCE_ROOT')
    refs.append(ref)
    builds.append(obj(path + '.build', 'PBXBuildFile', fileRef=ref))
privacy = obj('privacy', 'PBXFileReference', lastKnownFileType='text.xml', path='iOSClient/PrivacyInfo.xcprivacy', sourceTree='SOURCE_ROOT')
resource = obj('privacy.build', 'PBXBuildFile', fileRef=privacy)
product = obj('product', 'PBXFileReference', explicitFileType='wrapper.application', path='SillVision.app', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex=0)
products = obj('products', 'PBXGroup', children=[product], name='Products', sourceTree='<group>')
group = obj('group', 'PBXGroup', children=refs + [privacy, products], sourceTree='<group>')
phases = []
for key, isa, values in [('sources', 'PBXSourcesBuildPhase', builds), ('resources', 'PBXResourcesBuildPhase', [resource])]:
    phases.append(obj(key, isa, buildActionMask=2147483647, files=values, runOnlyForDeploymentPostprocessing=0))
package = obj('package', 'XCLocalSwiftPackageReference', relativePath='.')
protocol = obj('protocol', 'XCSwiftPackageProductDependency', productName='StreamProtocol')
framework = obj('protocol.build', 'PBXBuildFile', productRef=protocol)
phases.append(obj('frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[framework], runOnlyForDeploymentPostprocessing=0))
project_configs, target_configs = [], []
for mode in ['Debug', 'Release']:
    project_configs.append(obj(mode + '.project', 'XCBuildConfiguration', name=mode, buildSettings={'SDKROOT': 'xros', 'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_MODULES': 'YES', 'SWIFT_STRICT_CONCURRENCY': 'minimal'}))
    settings = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'dev.ambrion.SillVision', 'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_KEY_CFBundleDisplayName': 'CCR Sill', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES', 'INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents': 'YES', 'INFOPLIST_KEY_NSLocalNetworkUsageDescription': 'Mac에 연결하여 암호화된 연결로 화면을 표시하고 제어합니다.', 'INFOPLIST_FILE': 'visionOSClient/Info.plist', 'TARGETED_DEVICE_FAMILY': '7', 'SUPPORTED_PLATFORMS': 'xros xrsimulator', 'XROS_DEPLOYMENT_TARGET': '2.5', 'CURRENT_PROJECT_VERSION': '14', 'MARKETING_VERSION': '0.5.1', 'CODE_SIGN_STYLE': 'Automatic', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'VISION_CLIENT', 'SWIFT_OPTIMIZATION_LEVEL': '-O' if mode == 'Release' else '-Onone', 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'], 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES'}
    target_configs.append(obj(mode + '.target', 'XCBuildConfiguration', name=mode, buildSettings=settings))
pc = obj('project.configs', 'XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
tc = obj('target.configs', 'XCConfigurationList', buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
target = obj('target', 'PBXNativeTarget', buildConfigurationList=tc, buildPhases=phases, buildRules=[], dependencies=[], name='SillVision', productName='SillVision', productReference=product, productType='com.apple.product-type.application', packageProductDependencies=[protocol])
test_product = obj('release.product', 'PBXFileReference', explicitFileType='wrapper.application', path='SillVisionReleaseTest.app', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex=0)
release_configs = []
for mode in ['Debug', 'Release']:
    original = objects[target_configs[0 if mode == 'Debug' else 1]]['buildSettings']
    settings = {**original, 'PRODUCT_BUNDLE_IDENTIFIER': 'dev.ambrion.SillVision.ReleaseTest',
                'INFOPLIST_KEY_CFBundleDisplayName': 'CCR Sill 격리 테스트',
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'VISION_CLIENT DEBUG' if mode == 'Debug' else 'VISION_CLIENT'}
    release_configs.append(obj(mode + '.release', 'XCBuildConfiguration', name=mode, buildSettings=settings))
rc = obj('release.configs', 'XCConfigurationList', buildConfigurations=release_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
release_phases = []
for name, isa, entries in [('sources', 'PBXSourcesBuildPhase', builds), ('resources', 'PBXResourcesBuildPhase', [resource]), ('frameworks', 'PBXFrameworksBuildPhase', [framework])]:
    release_phases.append(obj('release.' + name, isa, buildActionMask=2147483647, files=entries, runOnlyForDeploymentPostprocessing=0))
release_target = obj('release.target', 'PBXNativeTarget', buildConfigurationList=rc, buildPhases=release_phases, buildRules=[], dependencies=[], name='SillVisionReleaseTest', productName='SillVisionReleaseTest', productReference=test_product, productType='com.apple.product-type.application', packageProductDependencies=[protocol])
ui_ref = obj('uitest.source', 'PBXFileReference', lastKnownFileType='sourcecode.swift', path='Tests/checks/vision-release-simulator/VisionReleaseSimulatorUITests.swift', sourceTree='SOURCE_ROOT')
ui_product = obj('uitest.product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='VisionReleaseSimulatorUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex=0)
ui_configs = []
for mode in ['Debug', 'Release']:
    ui_configs.append(obj(mode + '.uitest', 'XCBuildConfiguration', name=mode, buildSettings={
        'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'dev.ambrion.SillVision.ReleaseTest.UITests',
        'GENERATE_INFOPLIST_FILE': 'YES', 'TARGETED_DEVICE_FAMILY': '7', 'SUPPORTED_PLATFORMS': 'xrsimulator',
        'XROS_DEPLOYMENT_TARGET': '2.5', 'TEST_TARGET_NAME': 'SillVisionReleaseTest',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']}))
uc = obj('uitest.configs', 'XCConfigurationList', buildConfigurations=ui_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
proxy = obj('uitest.proxy', 'PBXContainerItemProxy', containerPortal=hashlib.sha1(b'project').hexdigest().upper()[:24], proxyType=1, remoteGlobalIDString=release_target, remoteInfo='SillVisionReleaseTest')
dependency = obj('uitest.dependency', 'PBXTargetDependency', target=release_target, targetProxy=proxy)
ui_phase = obj('uitest.sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=[obj('uitest.build', 'PBXBuildFile', fileRef=ui_ref)], runOnlyForDeploymentPostprocessing=0)
ui_target = obj('uitest.target', 'PBXNativeTarget', buildConfigurationList=uc, buildPhases=[ui_phase], buildRules=[], dependencies=[dependency], name='VisionReleaseSimulatorUITests', productName='VisionReleaseSimulatorUITests', productReference=ui_product, productType='com.apple.product-type.bundle.ui-testing')
objects[products]['children'].extend([test_product, ui_product])
objects[group]['children'].append(ui_ref)
project = obj('project', 'PBXProject', attributes={'LastUpgradeCheck': '2700', 'TargetAttributes': {ui_target: {'TestTargetID': release_target}}}, buildConfigurationList=pc, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target, release_target, ui_target], packageReferences=[package])
path = ROOT / 'SillVision.xcodeproj'
path.mkdir(exist_ok=True)
(path / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': project}, sort_keys=False))
schemes = path / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
def reference(identifier, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier}" BuildableName="{name}" BlueprintName="{name.split(chr(46))[0]}" ReferencedContainer="container:SillVision.xcodeproj"/>'
(schemes / 'SillVisionReleaseTest.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference(release_target, 'SillVisionReleaseTest.app')}</BuildActionEntry>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference(ui_target, 'VisionReleaseSimulatorUITests.xctest')}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO">{reference(ui_target, 'VisionReleaseSimulatorUITests.xctest')}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference(release_target, 'SillVisionReleaseTest.app')}</BuildableProductRunnable></LaunchAction>
</Scheme>
''')
print(f'Generated SillVision target with {len(files)} source files.')
