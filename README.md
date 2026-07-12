# Rec

A lightweight, native macOS screen and internal audio recorder built with Swift, AVFoundation, and ScreenCaptureKit.

It runs cleanly with a simple floating UI, saving your recordings directly to your Downloads folder.

## Installation

This application requires no external dependencies. It builds itself directly on your Mac using Apple's Command Line Tools, ensuring the resulting app is fully native and fully trusted by your system.

### How to Install

1. Download the source code as a ZIP (or clone this repository).
2. Open your terminal and navigate to the downloaded folder.
3. Run the installer script:

```bash
./install-screenrecorder.command
```

**Note:** If macOS prevents the script from running, you may need to make it executable first:
```bash
chmod +x install-screenrecorder.command
./install-screenrecorder.command
```

4. The script will guide you through installing the Command Line Tools (if you don't already have them).
5. Once built, a window will pop up. **Drag the Rec icon onto the Applications folder** to complete the installation.

## Usage

1. Open **Rec** from your Applications folder.
2. A small, floating record button will appear on your screen.
3. Click the circle to start recording. It will capture your screen and the internal audio output.
4. Click the square (stop) button to finish recording.
5. The recording will be saved directly into your `Downloads` folder as a `.mov` file.

## Requirements

- macOS 13.0 (Ventura) or later.
- Apple's Command Line Tools (the installer script handles this automatically).
- Permissions: You will need to grant Screen Recording and Microphone permissions upon first launch.

## Built With

- **Swift**
- **ScreenCaptureKit**
- **AVFoundation**
- **Cocoa (AppKit)**
