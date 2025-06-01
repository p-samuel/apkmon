# 👾apkmon - Delphi Android APK Deployment Monitor

A Windows console application that monitors directories for Android shared library (.so) file changes and automatically builds/deploys APK files to Android emulators.

![Demo](img/demo.gif)

## Notes

- Only monitors `.so` files to avoid infinite deployment loops. If this happens, maybe your project is rebuilding itself, or something else is causing the .so files to be created consecutively. It should only build when the .so files flag `FILE_ACTION_ADDED` is detected.
- Automatically detects Android emulators using `adb devices`
- Supports multiple project monitoring simultaneously

## Requirements

- Windows OS
- Delphi/RAD Studio with Android development support
- Android SDK with ADB in PATH
- Running Android emulator

## Usage

1. Run `apkmon.exe`
2. Enter the root directory to monitor (searches recursively)
3. Enter project names to match (without .dproj extension)
4. Select build configuration (Debug/Release)
5. Choose action:
   - **Build only**: Rebuilds project when .so files change
   - **Deploy only**: Deploys existing APK to emulator
   - **Build and Deploy**: Builds project then deploys to emulator

## How It Works

1. Scans for `.dproj` files matching your project names
2. Extracts package names from project files or AndroidManifest.template.xml
3. Monitors for `.so` file changes using Windows directory change notifications
4. Waits for file stability before processing
5. Builds project using MSBuild (if configured)
6. Finds corresponding APK file
7. Clears app data and installs APK to emulator
8. Starts the application
