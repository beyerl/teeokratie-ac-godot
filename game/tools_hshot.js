const { chromium } = require('playwright');
(async () => {
  const url=process.argv[2], out=process.argv[3];
  const b=await chromium.launch({headless:true,args:['--no-sandbox','--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--ignore-gpu-blocklist']});
  const p=await b.newPage({viewport:{width:960,height:540}});
  await p.goto(url,{waitUntil:'load',timeout:60000});
  await p.waitForTimeout(20000);
  await p.screenshot({path:out});
  await b.close();
})().catch(e=>{console.error('FATAL',e);process.exit(1);});
