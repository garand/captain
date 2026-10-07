# Captain

Captain watches every connected webcam, works out which display you're looking at, and
switches a virtual webcam ("Captain Camera") to that display's camera with a cut or crossfade.

## How it works

- **Capture**: one `AVCaptureSession` per camera (`CameraFeed`).
- **Gaze**: Vision face landmarks on each feed, about 12 times a second (`FaceAnalyzer`). The camera
  you're facing sees the nose centered between your eyes and across the face outline; side
  cameras see it shifted. Pupil offset is blended in through the "Eye gaze influence" setting.
- **Switching**: `AppModel.evaluate` picks the camera with the most head-on view, after
  smoothing, a stickiness margin and a switch delay so glances don't cause flicker.
- **Output**: `Compositor` renders 1080p30 with Core Image (cut or `CIDissolveTransition`) and
  pushes frames into the camera extension's sink stream (`VirtualCameraOutput`).
- **Virtual camera**: `CameraExtension/` is a CoreMediaIO camera extension with a source
  stream (what Zoom/Meet/etc. read) and a sink stream (what Captain writes).

## Building

```sh
# Full build with the virtual camera. Needs a paid Apple Developer Program team.
CAPTAIN_TEAM_ID=ABCDE12345 ./scripts/build.sh

# Preview build without the virtual camera. Works with a free personal team.
./scripts/build.sh
```

The script generates the Xcode project with XcodeGen (`project.yml` = full,
`project-preview.yml` = preview, both include `base.yml`), builds Release, installs to
`/Applications` (system extensions only activate from there) and launches the app.

On the first full-build launch, approve the extension in **System Settings → General →
Login Items & Extensions → Camera Extensions**. Then pick **Captain Camera** in any video app.

## Using it

- Click a camera tile (or press ⌘1–⌘9) to take it live manually. ⌘0 returns to Auto.
- Right-click a tile to rename it (Left / Center / Right), reorder it or disable it.
- ⌘T toggles between cut and crossfade.
- Closing the window keeps the virtual camera running; quit from the menu bar icon.
