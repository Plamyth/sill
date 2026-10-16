#!/usr/bin/env python3
"""Generate the native Vision target without changing the iPad project."""
from pathlib import Path
import hashlib
import plistlib

ROOT = Path(__file__).resolve().parent.parent
CLIENT = ['StreamClient', 'StreamClient+Home', 'StreamClient+Remote', 'StreamClient+Viewport', 'DeviceIdentity', 'RemoteConnector', 'RemoteDialPolicy', 'SessionLink', 'MessageReader', 'SavedMacs', 'DiscoveryPolicy', 'GoodbyePolicy', 'HEVCDisplayView', 'DiagnosticsHUD', 'HostSettingsLedger', 'MacMenuState', 'MacMenuHub', 'PointerPresence', 'TrackpadGestures', 'TourPolicy', 'DuoPosture', 'InputOverlay', 'KeyChords', 'IPadMicrophoneCapture', 'IPadMicrophonePCM', 'IPadMicrophonePolicy', 'IPadMicrophoneFrameGate']
files = ['iOSClient/' + n + '.swift' for n in CLIENT] + ['visionOSClient/' + n + '.swift' for n in ['SillVisionApp', 'VisionPointer', 'VisionInputSession', 'VisionInputDebt', 'VisionPresentation', 'VisionRemoteKey', 'VisionKeyPalette', 'HIDKey', 'VisionInputFence', 'VisionTransition', 'VisionAudioState', 'VisionAudioController', 'VisionAudioRoute', 'VisionAudioPlayer', 'VisionAudioHardware', 'VisionAudioNativeGraph', 'VisionMicrophoneCapture', 'StreamClient+VisionMicrophone', 'VisionAudioBuffer', 'VisionTextDraft', 'VisionDraftEditor']]
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
    settings = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'dev.ambrion.SillVision', 'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_KEY_CFBundleDisplayName': 'CCR Sill', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES', 'INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents': 'YES', 'INFOPLIST_KEY_NSLocalNetworkUsageDescription': 'Pair with your Mac and use its screen over an encrypted connection.', 'INFOPLIST_FILE': 'visionOSClient/Info.plist', 'TARGETED_DEVICE_FAMILY': '7', 'SUPPORTED_PLATFORMS': 'xros xrsimulator', 'XROS_DEPLOYMENT_TARGET': '2.5', 'CURRENT_PROJECT_VERSION': '2', 'MARKETING_VERSION': '0.5.1', 'CODE_SIGN_STYLE': 'Automatic', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'VISION_CLIENT', 'SWIFT_OPTIMIZATION_LEVEL': '-O' if mode == 'Release' else '-Onone', 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'], 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES'}
    target_configs.append(obj(mode + '.target', 'XCBuildConfiguration', name=mode, buildSettings=settings))
pc = obj('project.configs', 'XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
tc = obj('target.configs', 'XCConfigurationList', buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
target = obj('target', 'PBXNativeTarget', buildConfigurationList=tc, buildPhases=phases, buildRules=[], dependencies=[], name='SillVision', productName='SillVision', productReference=product, productType='com.apple.product-type.application', packageProductDependencies=[protocol])
project = obj('project', 'PBXProject', attributes={'LastUpgradeCheck': '2700'}, buildConfigurationList=pc, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target], packageReferences=[package])
path = ROOT / 'SillVision.xcodeproj'
path.mkdir(exist_ok=True)
(path / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': project}, sort_keys=False))
print(f'Generated SillVision target with {len(files)} source files.')
