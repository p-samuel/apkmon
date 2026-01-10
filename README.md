# APKMon - Delphi Android APK Deploy Monitor

A Windows console tool that monitors directories for Android shared library (.so) file changes and automatically builds/deploys APK files to connected devices.

![Demo](img/demo.gif)

## Requirements

- Windows
- Delphi/RAD Studio with Android support
- ADB in PATH
- FFmpeg in PATH (for screen recording)

```powershell
choco install ffmpeg
```

### Environment Setup

Add to System PATH:
```
C:\Users\<user>\AppData\Local\Android\Sdk\emulator
C:\Users\<user>\AppData\Local\Android\Sdk\platform-tools
C:\Windows\Microsoft.NET\Framework\v4.0.30319
```

Environment variables:
- **BDS**: `C:\Program Files (x86)\Embarcadero\Studio\23.0`
- **FrameworkDir**: `C:\Windows\Microsoft.NET\Framework\v4.0.30319`
- **FrameworkVersion**: `v4.5`

## Usage

Run `apkmon.exe` and follow prompts to configure watch directory, projects, build config, and deploy action.

## Commands

### Projects
| Command | Description |
|---------|-------------|
| `list` | Show current projects |
| `add <project>` | Add project to monitor |
| `build all\|<name>` | Build project(s) |
| `deploy all\|<name>` | Deploy project(s) |
| `bd all\|<name>` | Build and deploy |

### Monitoring
| Command | Description |
|---------|-------------|
| `pause` | Pause auto-detection |
| `resume` | Resume auto-detection |

### Devices
| Command | Description |
|---------|-------------|
| `devices` | List connected devices |
| `pair <ip>:<port>` | Pair WiFi device (Android 11+) |
| `connect <ip>:<port>` | Connect to WiFi device |
| `disconnect [<ip>:<port>]` | Disconnect WiFi device(s) |

### Logcat
| Command | Description |
|---------|-------------|
| `logcat [filter]` | Start logcat |
| `logcat -s <device> [filter]` | Logcat on specific device |
| `logcat stop` | Stop logcat |
| `logcat pause/resume` | Pause/resume output |
| `logcat clear` | Clear buffer |
| `logcat status` | Show status |

### Screen Recording
| Command | Description |
|---------|-------------|
| `record output <path>` | Set output folder |
| `record start <device>` | Start recording |
| `record stop` | Stop and save |
| `record status` | Show status |

Records at 60fps, native resolution. Long recordings auto-segment and merge via FFmpeg. Auto-saves on app exit.

### General
| Command | Description |
|---------|-------------|
| `help` | Show commands |
| `quit` | Exit |

## Notes

- Only monitors `.so` files to avoid infinite loops
- First build must be done manually via `Project > Deployment > Deploy`
- Delphi FMX requires ARM/ARM64 devices (x86 emulators need Google APIs ARM image)
