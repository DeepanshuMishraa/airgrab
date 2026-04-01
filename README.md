# airgrab

**Hand- and gaze-driven window movement for macOS.**  
airgrab uses your webcam with Apple’s Vision framework: you **pinch** to grab the window under your gaze, **move** your hand to drag it, then **open your palm** to drop it.

Requires **macOS 14+**.

## Permissions

- **Camera** — hand pose and (with calibration) head pose  
- **Microphone** — clap detection for activation and deactivation  
- **Accessibility** — read/write window position and size via the Accessibility API  

macOS will prompt for these when needed, so you usually do not need to set them up manually ahead of time.

## Install

Run it without installing:

```bash
npx airgrab
```

Install it globally:

```bash
npm install -g airgrab
airgrab
```

## Build and run

```bash
swift build -c release
.build/release/airgrab
```

Install on your `PATH` if you like:

```bash
cp .build/release/airgrab /usr/local/bin/
```

## Run on login

If you want airgrab to start automatically after login or restart, the easiest path is to install it globally first:

```bash
npm install -g airgrab
```

Then:

1. Run `which airgrab` and copy the full path.
2. Open **Automator** and create a new **Application**.
3. Add a **Run Shell Script** action.
4. Paste this, replacing `/full/path/to/airgrab` with the path from `which airgrab`:

```bash
nohup /full/path/to/airgrab >/tmp/airgrab.log 2>&1 &
```

5. Save it as something like `Airgrab Launcher.app`.
6. Open **System Settings → General → Login Items**.
7. Add `Airgrab Launcher.app` under **Open at Login**.

That will start airgrab automatically in the background each time you log in.

## First run and calibration

On first launch, airgrab walks you through:

1. **Gaze calibration** — look at each monitor and confirm so it knows which screen you’re facing.  
2. **Hand calibration** — hold a steady **thumb–index pinch** (grab), then a clear **open palm** (release). Samples use a **palm-centered** point so your release matches where your hand actually is.

Data is stored under `~/.local/share/airgrab/` (head calibration in `calibration.json`, hand poses in `calibration_hand.json` when using the default calibration path).

Recalibrate anytime:

```bash
airgrab --calibrate              # head + hand
airgrab --calibrate-head         # gaze only
airgrab --calibrate-hand         # grab/release poses only
```

## How to use it

1. **Activate** — **clap once** to turn control on.  
2. **Grab** — look at the window you want; with stable gaze, **pinch** (thumb and index together). The window is raised and a light overlay shows it’s grabbed.  
3. **Drag** — while control is active, **move your hand**; motion is **incremental frame-to-frame**, so switching from pinch to open palm doesn’t throw the window sideways.  
4. **Release** — **open your palm** again in the same steady way, and the window stays where you left it.  
5. **Deactivate** — **clap again** to turn control off. If you clap while holding a window, it is released immediately.

Monitor focus can follow your gaze during normal use (same calibration as above).

## Command-line options

| Flag | Description |
|------|-------------|
| `--calibrate` | Force full recalibration (head + hand) |
| `--calibrate-head` | Gaze / monitor calibration only |
| `--calibrate-hand` | Hand grab/release sampling only |
| `--calibration-file` *path* | Custom base path (default: `~/.local/share/airgrab/calibration.json`) |
| `--camera` *n* | Webcam index (default: `0`) |
| `--verbose` | Extra logging (e.g. gaze / hand hints) |
| `--debug` | Debug traces |
| `-v`, `--version` | Print version |
| `-h`, `--help` | Help |

Run `airgrab --help` for the in-app banner and summary.

## How it works (short)

- **Vision** — `VNDetectHumanHandPoseRequest` for pinch / open palm / fist and a **palm-based** normalized position for dragging.  
- **Audio** — clap detection via `AVAudioEngine` to toggle control on and off.  
- **Face / gaze** — optional yaw/pitch (and calibration) to pick monitor and target window under gaze.  
- **Accessibility** — `AXUIElement` to raise windows, move them during drag, and track geometry for overlays.  
- **Drag math** — per-frame movement scaled by the **current display’s frame**, clamped to the union of all screens’ **visible** frames.

---

See [LICENSE](LICENSE) for license terms.
