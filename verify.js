const { chromium } = require('playwright');
(async () => {
  const errors = [];
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
  });
  const page = await browser.newPage({ viewport: { width: 960, height: 640 } });
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('CONSOLE: ' + m.text()); });
  await page.goto('http://127.0.0.1:8099/index.html', { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(16000); // boot + onStart cutscene
  await page.screenshot({ path: 'shot_boot.png' });
  // click near a hotspot region (Bookshelve ~ left of centre); coords in canvas space
  await page.mouse.click(560, 330);
  await page.waitForTimeout(1200);
  await page.screenshot({ path: 'shot_click.png' });
  // click a verb button if it appeared (top of the three)
  await page.mouse.click(520, 285);
  await page.waitForTimeout(3500);
  await page.screenshot({ path: 'shot_interact.png' });
  console.log('ERRORS:', errors.length);
  errors.slice(0, 20).forEach(e => console.log(e));
  await browser.close();
})().catch(e => { console.error('FATAL', e); process.exit(1); });
