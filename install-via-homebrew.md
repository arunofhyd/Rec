# Install Rec via Homebrew

To install Rec on a brand new Mac, you can run the following combined command in your Terminal. This will install Homebrew (if you don't already have it), add the custom repository, and install the Rec application:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && brew tap arunofhyd/rec && brew install --cask rec
```

### Important Note for New Users:
Because this application is not yet notarized with an Apple Developer certificate, macOS Gatekeeper will block it the very first time you try to open it, showing a message that Apple could not verify "Rec" is free of malware.

To open the app for the first time:
1. Try to open the **Rec** app from your Applications folder.
2. When the prompt appears saying it cannot be opened, click **Done**.
3. Open macOS **System Settings** and go to **Privacy & Security**.
4. Scroll down to the **Security** section.
5. You will see a message saying "Rec" was blocked to protect your Mac. Click the **Open Anyway** button.
6. Click **Open** on the final confirmation prompt.

You will only need to do this once.
