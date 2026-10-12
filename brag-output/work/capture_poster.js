const puppeteer = require('/Users/arunthomas/.gemini/antigravity-ide/scratch/OmniSearch/node_modules/puppeteer-core');
const path = require('path');

async function capturePoster() {
    const browser = await puppeteer.launch({
        executablePath: '/Users/arunthomas/.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.42/chrome-headless-shell-mac-arm64/chrome-headless-shell',
        headless: "new",
        args: ['--no-sandbox', '--disable-setuid-sandbox']
    });

    const page = await browser.newPage();
    await page.setViewport({
        width: 1920,
        height: 1080,
        deviceScaleFactor: 1
    });

    const fileUrl = 'file://' + path.resolve(__dirname, '../composition/index.html');
    await page.goto(fileUrl, { waitUntil: 'networkidle0' });

    // Seek to settled scene 2 (t = 5.5s)
    await page.evaluate(() => {
        if (typeof seekTo === 'function') {
            seekTo(5.5);
        }
    });

    // Wait a moment for styles/transitions to settle
    await new Promise(r => setTimeout(r, 600));

    // Capture the #stage element or full viewport
    const stage = await page.$('.stage-wrapper');
    const outputPath = path.resolve(__dirname, '../brag.jpg');
    if (stage) {
        await stage.screenshot({
            path: outputPath,
            type: 'jpeg',
            quality: 92
        });
    } else {
        await page.screenshot({
            path: outputPath,
            type: 'jpeg',
            quality: 92
        });
    }

    console.log("Captured poster frame to:", outputPath);
    await browser.close();
}

capturePoster().catch(err => {
    console.error("Error capturing poster:", err);
    process.exit(1);
});
