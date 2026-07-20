# Rec Agent Rules & Best Practices

These rules help guide AI behavior when working inside the Rec repository to maintain smooth video performance and stability.

## 1. Performance & Architecture
- **CoreMedia Optimization**: `CMSampleBuffer` processing is highly sensitive. Keep memory allocations inside the `captureOutput` and `stream` hot loops as lightweight as possible.
- **Smart Locking**: For high-frequency threaded operations, prefer `os_unfair_lock` or GCD serial queues over standard `NSLock` contention to prevent thermal throttling.
- **Clean Encoding**: Video encoding can cause memory leaks if references aren't released properly. Always ensure AVAssetWriter inputs and sessions are cleanly stopped and flushed.

## 2. Code Quality & UX
- **Human-Readable Errors**: Video encoding and hardware access failures can be cryptic. Always surface clear, human-readable error alerts if ScreenCaptureKit fails to start.
- **Graceful Hardware Fallbacks**: Account for users who may not have external cameras or microphones connected when building hardware-access features.
- **Clean Code**: Organize the file with clearly labeled sections (e.g., `// MARK: - Video Pipeline`).

## 3. Workflow
- **Compile & Verify**: Before presenting a completed feature, compile the app locally using `swiftc`, kill the existing process (`pkill`), and launch the newly compiled `.app` so it can be tested locally.
- **Wait for Approval**: Avoid unprompted Git pushes. Wait for the user to test the local build and give the green light before pushing to GitHub.
