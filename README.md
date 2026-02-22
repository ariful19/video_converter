# video_converter_app

Android Flutter app to downscale videos to a selected resolution (for example 4K -> 720p) with proportional bitrate adjustment to reduce output size.

## Features

- Pick a video file from device storage.
- Choose target resolution (2160p/1440p/1080p/720p/480p).
- App requires a lower-than-source target preset to ensure size reduction.
- Convert with FFmpeg using:
  - Aspect-ratio-safe scaling
  - H.264 video + AAC audio output
  - Proportional video/audio bitrate scaling
- Save the converted file to the same source media folder on Android.
- If source folder metadata is unavailable, app asks once for folder access and reuses it.
- View conversion progress and output summary (resolution, bitrate, size).

## Run

```bash
flutter pub get
flutter run
```

## Build verification

- `flutter analyze` passed
- `flutter test` passed
- `flutter build apk --debug` succeeded (`build\app\outputs\flutter-apk\app-debug.apk`)
