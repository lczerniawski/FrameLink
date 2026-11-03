#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 -B Tests/SourceChecks.py
xcrun swiftc FrameLink/Streaming/Packet.swift Tests/ProtocolChecks.swift -o "$work/checks"
"$work/checks"
xcrun swiftc FrameLink/Camera/RecentPhotoStore.swift Tests/RecentPhotoChecks.swift -o "$work/photo-checks"
"$work/photo-checks"
xcrun swiftc FrameLink/Camera/CameraControls.swift Tests/CameraControlChecks.swift -o "$work/camera-checks"
"$work/camera-checks"
# Compile the production preview-queue methods against native AVFoundation, without UIKit or camera input.
python3 - "$work/PreviewManager.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('FrameLink/Camera/CameraManager.swift').read_text()
methods = source.split('    func attachPreview(', 1)[1].split('    func setRotation(', 1)[0]
publish = source.split('    private func publish(', 1)[1].split('    private func finishPhoto(', 1)[0]
pathlib.Path(sys.argv[1]).write_text('''import AVFoundation
final class CameraManager: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "preview-check")
    func attachPreview(''' + methods + '    private func publish(' + publish + '''
    func previewQueueBarrier() async {
        await withCheckedContinuation { continuation in sessionQueue.async { continuation.resume() } }
    }
}
''')
PY
xcrun swiftc -parse-as-library "$work/PreviewManager.swift" Tests/PreviewConnectionChecks.swift -o "$work/preview-checks"
"$work/preview-checks"
xcrun swiftc FrameLink/AppCoordinator.swift Tests/NavigationChecks.swift -o "$work/navigation-checks"
"$work/navigation-checks"
plutil -lint FrameLink/Info.plist FrameLink.xcodeproj/project.pbxproj
python3 - <<'PY'
import json
import pathlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
p = plistlib.loads(pathlib.Path('FrameLink/Info.plist').read_bytes())
assert p['CFBundleDisplayName'] == p['CFBundleName'] == 'Frame Link'
for key in ['NSCameraUsageDescription', 'NSPhotoLibraryAddUsageDescription', 'NSPhotoLibraryUsageDescription', 'NSLocalNetworkUsageDescription', 'NSMotionUsageDescription']:
    assert 'Frame Link' in p[key] and 'FrameLink' not in p[key]
for source in pathlib.Path('FrameLink').rglob('*.swift'):
    for literal in re.findall(r'"(?:\\.|[^"\\])*"', source.read_text()):
        # The invitation context is a wire identifier, not user-facing branding.
        assert 'FrameLink' not in literal or literal == '"FrameLink/1/camera"', (source, literal)
print('Frame Link user-facing branding checks passed')
assert p['NSBonjourServices'] == ['_framelink._tcp']
assert all(p.get(k) for k in ['NSCameraUsageDescription', 'NSPhotoLibraryAddUsageDescription', 'NSPhotoLibraryUsageDescription', 'NSLocalNetworkUsageDescription', 'NSMotionUsageDescription'])
assert 'NSMicrophoneUsageDescription' not in p
assert 'delete' in p['NSPhotoLibraryUsageDescription']
print('Frame Link privacy configuration checks passed')
gallery = pathlib.Path('FrameLink/Views/RecentPhotosView.swift').read_text()
store = pathlib.Path('FrameLink/Camera/RecentPhotoStore.swift').read_text()
assert gallery.count('Button("Delete Photo", role: .destructive)') == 1
assert gallery.count('role: .destructive') == 2, 'Only the trash button and its single confirmation may delete'
assert 'let assetIdentifier: String\n' in store, 'Every gallery entry must require a Photos asset reference'
assert 'previewOnly' not in gallery + store and 'Remove Preview' not in gallery + store
print('Frame Link single-action deletion checks passed')
root = pathlib.Path('FrameLink/FrameLinkApp.swift').read_text()
assert '.navigationDestination(item: Binding(get: { coordinator.role }, set: { coordinator.select($0) }))' in root
assert 'navigationBarBackButtonHidden' not in root and 'DragGesture' not in root, 'Keep native interactive back navigation'
print('Frame Link native navigation wiring checks passed')
camera_view = pathlib.Path('FrameLink/Views/CameraView.swift').read_text()
camera_manager = pathlib.Path('FrameLink/Camera/CameraManager.swift').read_text()
assert 'private let session = AVCaptureSession()' in camera_manager, 'Keep capture graph access behind the camera queue'
assert 'previewLayer.session' not in camera_view and 'previewLayer.connection' not in camera_view, 'SwiftUI must not rebuild the capture graph on main'
assert 'static func dismantleUIView' in camera_view and 'camera?.detachPreview(previewLayer)' in camera_view
for method in ['attachPreview', 'detachPreview', 'setPreviewRotation']:
    body = camera_manager.split(f'func {method}(', 1)[1].split('\n    }', 1)[0]
    assert 'sessionQueue.async' in body, f'{method} must use the capture queue'
assert 'self.previewLayer' not in camera_manager, 'Do not steal another surface’s preview connection'
assert 'guard layer.session === self.session else { return }' in camera_manager, 'Only detach the requested layer from this session'
for body in re.findall(r'publish \{([^}]*)\}', camera_manager):
    assert not re.search(r'\b(?:device|session)\.', body), 'Snapshot hardware properties before publishing UI state'
print('Frame Link capture-queue preview wiring checks passed')
quick_controls = pathlib.Path('FrameLink/Views/CameraQuickControls.swift').read_text()
top_inset = camera_view.split('.safeAreaInset(edge: .top', 1)[1].split('.toolbar', 1)[0]
assert 'CameraQuickControls(' in top_inset, 'Frequent controls must stay directly above the preview'
assert 'verticalSizeClass == .compact' in camera_view, 'Large-text headers must not make portrait use landscape controls'
settings = camera_view.split('private struct CameraSettingsView:', 1)[1].split('private struct CameraPreview:', 1)[0]
assert 'camera.zoom' not in settings and 'camera.flash' not in settings and 'PhotoTimer' not in settings, 'Do not hide zoom, flash, or timer in settings'
assert 'Slider(' not in quick_controls and 'Slider(value:' not in quick_controls, 'Zoom must not use a slider'
assert 'zoom:' not in top_inset, 'Only flash and timer belong in the top controls'
assert '.overlay(alignment: .bottomLeading)' in camera_view and 'CameraZoomControls(' in camera_view
assert 'override func accessibilityIncrement()' in camera_view and 'override func accessibilityDecrement()' in camera_view, 'Keep fine zoom accessible without a slider'
horizon = quick_controls.split('struct CameraHorizonGuide:', 1)[1]
assert '.background' not in horizon and 'Text(' not in horizon, 'Keep the horizon guide free of badges and on-scene text'
assert 'if showLevel, let angle = level.angle' in camera_view, 'Hide the guide without a usable horizon'
print('Frame Link visible camera controls and minimal horizon wiring checks passed')
icon = pathlib.Path('FrameLink/FrameLinkIcon.icon')
model = json.loads((icon / 'icon.json').read_text())
assert model['supported-platforms']['squares'] == 'shared'
layers = [layer for group in model['groups'] for layer in group['layers']]
assert {layer['image-name'] for layer in layers} == {'CameraFrame.svg', 'LensRing.svg', 'Indicator.svg'}
def fill_rgb(value):
    return tuple(float(c) for c in value['solid'].split(':', 1)[1].split(',')[:3])
backgrounds = {item.get('appearance', 'light'): item['value'] for item in model['fill-specializations']}
assert backgrounds == {'light': 'system-light', 'dark': 'system-dark'}, 'Use native icon backgrounds, not custom color approximations'
assert 'fill' not in model, 'A custom default fill must not override the system backgrounds'
frame = next(layer for layer in layers if layer['image-name'] == 'CameraFrame.svg')
frame_colors = {item.get('appearance', 'light'): fill_rgb(item['value']) for item in frame['fill-specializations']}
assert max(frame_colors['light']) < 0.2, 'The camera outline must contrast with the light background'
assert min(frame_colors['dark']) > 0.8, 'The camera outline must contrast with the dark background'
assert min(frame_colors['tinted']) > 0.8, 'Mono styles must retain a readable camera silhouette'
for layer in layers:
    assert layer['glass'] is True
    svg = ET.parse(icon / 'Assets' / layer['image-name']).getroot()
    assert svg.tag == '{http://www.w3.org/2000/svg}svg'
    assert svg.attrib['viewBox'] == '0 0 1024 1024'
for group in model['groups']:
    assert group['specular'] is True and group['translucency']['enabled'] is True
project = pathlib.Path('FrameLink.xcodeproj/project.pbxproj').read_text()
assert project.count('ASSETCATALOG_COMPILER_APPICON_NAME = FrameLinkIcon;') == 2
objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', 'FrameLink.xcodeproj/project.pbxproj']))['objects']
project_object = next(obj for obj in objects.values() if obj['isa'] == 'PBXProject')
target_id, target = next((key, obj) for key, obj in objects.items() if obj['isa'] == 'PBXNativeTarget' and obj['name'] == 'FrameLink')
group_ids = target['fileSystemSynchronizedGroups']
assert len(group_ids) == 1, 'Use one native folder-backed app source tree'
app_folder = objects[group_ids[0]]
assert app_folder['isa'] == 'PBXFileSystemSynchronizedRootGroup'
assert app_folder['path'] == 'FrameLink' and app_folder['sourceTree'] == '<group>'
assert group_ids[0] in objects[project_object['mainGroup']]['children']
exceptions = [objects[ref] for ref in app_folder['exceptions'] if objects[ref]['target'] == target_id]
assert len(exceptions) == 1 and exceptions[0]['membershipExceptions'] == ['Info.plist'], 'Exclude the input plist from resources, not app sources or the icon'
assert all(obj.get('lastKnownFileType') != 'sourcecode.swift' for obj in objects.values()), 'Discover Swift files through the native folder, not a flat reference list'
for ref in objects[target['buildConfigurationList']]['buildConfigurations']:
    assert objects[ref]['buildSettings']['INFOPLIST_FILE'] == 'FrameLink/Info.plist'
ui_id, ui_target = next((key, obj) for key, obj in objects.items() if obj['isa'] == 'PBXNativeTarget' and obj['name'] == 'FrameLinkUITests')
assert ui_target['productType'] == 'com.apple.product-type.bundle.ui-testing'
assert [objects[ref]['path'] for ref in ui_target['fileSystemSynchronizedGroups']] == ['Tests/UI']
assert not set(group_ids) & set(ui_target['fileSystemSynchronizedGroups']), 'Keep UI test sources out of the app target'
assert any(objects[ref]['target'] == target_id for ref in ui_target['dependencies'])
scheme = ET.parse('FrameLink.xcodeproj/xcshareddata/xcschemes/FrameLink.xcscheme')
assert any(ref.get('BlueprintIdentifier') == ui_id for ref in scheme.findall('.//TestableReference/BuildableReference'))
assert pathlib.Path('Tests/UI/FrameLinkUITests.swift').is_file()
print('Frame Link native Xcode folders and UI test target checks passed')
assert re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);', project) == ['26.0', '26.0']
assert 'Assets.xcassets' not in project and not pathlib.Path('FrameLink/Assets.xcassets').exists()
print('Frame Link layered icon and iOS 26 configuration checks passed')
PY
