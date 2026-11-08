// UI harvesting for the design reference pipeline: a 1440x900 viewport
// screenshot of a page, saved to .design-refs/captured/.
//
//   node scripts/harvest-ui.js <url> [output-name.png]
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

(async () => {
  const url = process.argv[2];
  // the name only: a path in the argument never writes outside captured/
  const outputName = path.basename(process.argv[3] || 'reference-ui.png');
  if (!url) {
    console.error('Please provide a URL to harvest.');
    process.exit(1);
  }

  const outputDir = path.join(__dirname, '../.design-refs/captured');
  fs.mkdirSync(outputDir, { recursive: true });

  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

    console.log(`Navigating to ${url}...`);
    await page.goto(url, { waitUntil: 'networkidle' });

    // Scroll to trigger lazy-loaded images/cards, then back to the top for the capture
    await page.mouse.wheel(0, 1000);
    await page.waitForTimeout(1500);
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(300);

    const outputPath = path.join(outputDir, outputName);
    await page.screenshot({ path: outputPath, fullPage: false });
    console.log(`Saved screenshot successfully to ${outputPath}`);
  } finally {
    await browser.close();
  }
})().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
