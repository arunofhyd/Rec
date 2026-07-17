<div align="center">
  <img src="logo.svg" alt="Rec Logo" width="120" height="120">
  
  <h1>Rec</h1>
  <p><strong>Native Screen & Audio Recorder for macOS</strong></p>
  <p align="center">
  Made for <img src="https://cdn.simpleicons.org/apple/white" width="11" height="11" valign="middle"> <strong>macOS</strong>
  </p>

  <p>
    <img src="https://img.shields.io/badge/Built%20With-Swift-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
    <img src="https://img.shields.io/badge/Capture-ScreenCaptureKit-34C759?style=flat-square&logo=apple&logoColor=white" alt="On-Device">
    <img src="https://img.shields.io/badge/Platform-macOS-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS">
    <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
  </p>

  <p><em>Your recording. Simplified.</em></p>
</div>

---

**Rec** is a free, delightfully simple native screen and internal audio recorder for macOS. It features an unobtrusive floating UI, allowing you to capture exactly what you need without cluttering your workspace.

Built with Apple's modern ScreenCaptureKit framework, Rec seamlessly records your system's internal audio right alongside your video feed—without needing any third-party audio drivers. **100% on-device, no cloud, no accounts, no subscriptions.**

## 🔒 Why Rec?

| Feature | Rec | Native macOS Screen Recorder |
| :--- | :--- | :--- |
| **Internal Audio** | 🔊 **Included Native Capture** | 🔇 Requires 3rd-party drivers |
| **UI** | 🪟 **Floating Panel** | 🪟 Floating Panel |
| **Specific App** | 🎯 **Yes, Window Target** | ❌ No |
| **Custom Quality** | ⚙️ **Selectable FPS, Res, Bitrate** | ❌ Fixed |
| **Timer** | ⏱️ **None, 5s, or 10s** | ⏱️ 5s or 10s |

## ✨ Key Features

*   **Internal Audio**: 🔊 Seamlessly captures your Mac's internal audio right alongside your video feed using ScreenCaptureKit. No 3rd-party audio loopback drivers needed.
*   **Multiple Modes**: 🎯 Record your entire screen, click-and-drag to select a specific region, or record a specific application window.
*   **Custom Quality**: ⚙️ Adjust your Framerate (30 or 60 FPS), Resolution (Native Retina, 1080p, or 720p), and Video Encoding Bitrate.
*   **Floating Controls**: 🪟 A small, unobtrusive control panel that stays out of your way and hides automatically from the final recording.
*   **Countdown Timer**: ⏱️ Set a 5 or 10-second countdown delay before recording officially begins.
*   **Native & Fast**: 🚀 Encodes directly to a multiplexed `.mov` file using hardware acceleration via AVAssetWriter. No post-processing or splicing delays.

## 📦 Install

Install by running the installer in **Terminal**:

1. **Download** [`install-rec.command`](install-rec.command) (open the file, then click **Download raw file**).
2. Open **Terminal** (`⌘ + Space`, type `Terminal`, press Enter).
3. Type `sh ` — that's **s**, **h**, then a **space**.
4. **Drag** the downloaded `install-rec.command` into the Terminal window (its path fills in automatically).
5. Press **Enter**, follow the prompts, then **drag Rec onto the Applications folder**.

> **First time only:** The installer may ask to install Apple's Command Line Tools (a small, official Apple download). Click **Install**, wait, then continue. This lets your Mac build the app locally — which is why macOS trusts it and never shows a "damaged app" warning.

After installing, look for the **record circle icon in your menu bar** (top-right).

## ⚙️ How It Works

The installer downloads the app's source and **builds it right on your Mac**. Because it's compiled locally rather than downloaded pre-made, macOS Gatekeeper trusts it — no bypassing scary warnings.

## 🗑️ Uninstall

1. Quit Rec (menu-bar icon → **Quit**).
2. Drag **Rec** from Applications to the Trash.
3. To remove saved data: delete `~/Library/Application Support/Rec`.

## 📦 Tech Stack
*   **Swift** (AppKit)
*   **ScreenCaptureKit** (Native video/audio capturing)
*   **AVFoundation** (Hardware-accelerated multiplexing)
*   **Shell** (Installer & Builder)

## 📄 License
MIT License. Free for personal use.

---

<p align="center">
  Made with ❤️ by <a href="mailto:arunthomas04042001@gmail.com">Arun Thomas</a>
</p>
