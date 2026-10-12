const puppeteer = require('/Users/arunthomas/.gemini/antigravity-ide/scratch/OmniSearch/node_modules/puppeteer-core');
const path = require('path');

async function captureSceneStills() {
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

    const keyframes = [
        { name: 'scene_01_problem.jpg', time: 1.8 },
        { name: 'scene_02_reveal.jpg', time: 5.5 },
        { name: 'scene_03_features.jpg', time: 10.0 },
        { name: 'scene_04_flow.jpg', time: 14.5 },
        { name: 'scene_05_install.jpg', time: 18.5 }
    ];

    for (const kf of keyframes) {
        await page.evaluate((t) => {
            if (typeof seekTo === 'function') seekTo(t);
        }, kf.time);

        await new Promise(r => setTimeout(r, 400));

        const stage = await page.$('.stage-wrapper');
        const outputPath = path.resolve(__dirname, kf.name);
        if (stage) {
            await stage.screenshot({ path: outputPath, type: 'jpeg', quality: 92 });
        } else {
            await page.screenshot({ path: outputPath, type: 'jpeg', quality: 92 });
        }
        console.log(`Saved ${kf.name} at t=${kf.time}s`);
    }

    await browser.close();
}

captureSceneStills().catch(err => {
    console.error("Error capturing stills:", err);
    process.exit(1);
});
