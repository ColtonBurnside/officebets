// Run with Playwright available through NODE_PATH. All backend calls are mocked.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
const user=(id,name,isAdmin=false)=>({id,name,isAdmin,active:true,balance:1000,balanceExact:'1000',avatar:'🏎️',bio:'On the grid',slips:[],lastSuperchargedAt:null});
const admin=user('11111111-1111-4111-8111-111111111111','Organizer',true),teammate=user('22222222-2222-4222-8222-222222222222','Teammate');
const markets=Array.from({length:9},(_,i)=>({id:`33333333-3333-4333-8333-${String(i).padStart(12,'0')}`,title:`Prediction ${i+1}`,description:'A friendly forecast for the team.',creatorId:admin.id,categoryId:i<5?'general':'sports',createdAt:new Date(Date.now()-i*1000).toISOString(),closesAt:new Date(Date.now()+(i+1)*3600000).toISOString(),resolved:i===8,winningOutcomeIdx:i===8?0:null,everTraded:true,volume:(i+1)*100,collateralVault:200,outcomes:[{name:'YES',poolReserve:200},{name:'NO',poolReserve:300}]}));
let snapshot={revision:1,serverTime:new Date().toISOString(),users:[admin,teammate],categories:[{id:'general',name:'General'},{id:'sports',name:'Sports'}],markets,transactions:[],house:{granted:0,returned:0}};
(async()=>{
 const browser=await chromium.launch({headless:true,timeout:15000,executablePath:process.env.CHROMIUM_PATH||undefined,args:['--no-sandbox','--disable-dev-shm-usage','--no-zygote','--single-process','--disable-gpu']});
 const page=await browser.newPage({viewport:{width:1440,height:1100}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',route=>{const url=route.request().url();if(url==='https://officebets.test/')return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(root,'index.html'),'utf8')});if(url.includes('/rest/v1/rpc/ob_admin_status'))return route.fulfill({json:{memberId:admin.id}});if(url.includes('/auth/v1/logout'))return route.fulfill({status:204});if(url.includes('/rest/v1/rpc/ob_snapshot'))return route.fulfill({json:snapshot});if(url.includes('/rest/v1/rpc/ob_market_view'))return route.fulfill({json:{activity:[],history:[]}});if(url.includes('/rest/v1/rpc/ob_action')){const req=route.request().postDataJSON();if(req.p_action==='delete_user')snapshot={...snapshot,revision:snapshot.revision+1,users:snapshot.users.filter(u=>u.id!==req.p_args.user)};return route.fulfill({json:snapshot});}return route.abort();});
 await page.routeWebSocket('**/*',ws=>ws.close());
 await page.goto('https://officebets.test/');await page.waitForFunction(()=>document.querySelectorAll('.category-row .prediction-card').length===9);
 assert.equal(await page.locator('#userSwitcherSelect').count(),0);
 assert.equal(await page.locator('#navBadgeIn').isVisible(),true);
 assert.equal(await page.locator('#accountMenu').isVisible(),false);
 assert.equal(await page.locator('.category-section').count(),2);
 assert.equal(await page.locator('#featuredDots button').count(),5);
 assert.match(await page.locator('#featuredMarket h3').innerText(),/Prediction 8/);
 await page.click('#featuredNext');assert.match(await page.locator('#featuredMarket h3').innerText(),/Prediction 7/);
 await page.click('#featuredPrev');assert.match(await page.locator('#featuredMarket h3').innerText(),/Prediction 8/);
 assert.equal(await page.locator('#featuredPrev').isDisabled(),true);
 assert.match(await page.locator('#endingSoon .ending-item').first().innerText(),/Prediction 1/);
 const rail=await page.locator('.workspace-sidebar').boundingBox(),content=await page.locator('.workspace-content').boundingBox();assert(rail.x>content.x+content.width);
 const newButton=await page.locator('#sidebarNewPrediction').boundingBox(),hero=await page.locator('#accountHero').boundingBox(),ending=await page.locator('.ending-panel').first().boundingBox();assert(newButton.y<hero.y&&hero.y<ending.y);
 await page.click('#navBadgeIn');assert.equal(await page.locator('#badgeSelect').inputValue(),'');await page.selectOption('#badgeSelect',admin.id);
 // Badge In dialog uses an explicit submit action.
 await page.evaluate(id=>switchTeammate(id),admin.id);
 assert.equal(await page.locator('#navBadgeIn').isVisible(),false);await page.click('#accountMenu summary');await page.getByRole('button',{name:'Edit Profile',exact:true}).first().click();assert.equal(await page.locator('#profileModal').isVisible(),true);await page.evaluate(()=>hideUtility('profileModal'));
 await page.reload();await page.waitForFunction(()=>document.getElementById('navUsername').textContent==='Organizer');
 await page.click('#settingsButton');assert.equal(await page.getByRole('button',{name:'Edit Channels',exact:true}).count(),1);await page.getByRole('button',{name:'Edit Channels',exact:true}).click();assert.equal(await page.locator('#manageCategoriesModal').isVisible(),true);await page.evaluate(()=>closeManageCategoriesModal());
 await page.click('#settingsButton');const ownRow=page.locator('#adminTools .admin-row').filter({has:page.locator('strong',{hasText:'Organizer'})}).first();assert.equal(await ownRow.getByRole('button',{name:'Delete account',exact:true}).isDisabled(),true);
 const otherRow=page.locator('#adminTools .admin-row').filter({has:page.locator('strong',{hasText:'Teammate'})}).first();page.once('dialog',d=>d.dismiss());await otherRow.getByRole('button',{name:'Delete account',exact:true}).click();assert.equal(snapshot.users.length,2);page.once('dialog',d=>d.accept('Teammate'));await otherRow.getByRole('button',{name:'Delete account',exact:true}).click();await page.waitForFunction(()=>!state.users.some(u=>u.name==='Teammate'));assert.equal(snapshot.users.length,1);await page.evaluate(()=>hideUtility('settingsModal'));
 // Admin can resolve another creator's open prediction before the close time.
 await page.evaluate(()=>{state.markets[0].creatorId='former-teammate';renderAll();});
 const firstCard=page.locator('.category-row .prediction-card').first();await firstCard.click({position:{x:6,y:6}});assert.equal(await page.locator('#tradeModal').isVisible(),true);
 await page.fill('#tradeAmountInput','10');await page.getByRole('button',{name:'Increase stake by one',exact:true}).click();assert.equal(await page.locator('#tradeAmountInput').inputValue(),'11');await page.getByRole('button',{name:'Decrease stake by one',exact:true}).click();assert.equal(await page.locator('#tradeAmountInput').inputValue(),'10');
 await page.evaluate(()=>{detailData={history:[{at:new Date().toISOString(),odds:[.4,.6],kind:'TRADE'}]};renderHistory();});
 const lines=await page.locator('#oddsChart polyline').evaluateAll(lines=>lines.map(l=>l.getAttribute('points')));assert.equal(lines.length,2);for(const line of lines){const [start,end]=line.split(' ').map(p=>p.split(',').map(Number));assert(end[0]>start[0]);assert.equal(start[1],end[1]);}
 await page.locator('#predictionTools .market-overflow-trigger').click();await page.locator('#marketOverflow').getByRole('menuitem',{name:'Resolve early',exact:true}).click();assert.equal(await page.locator('#settleModal').isVisible(),true);assert.equal(await page.locator('#tradeModal').isVisible(),false);await page.evaluate(()=>closeSettleModal());
 await firstCard.focus();await page.keyboard.press('Enter');assert.equal(await page.locator('#tradeModal').isVisible(),true);await page.evaluate(()=>closeTradeModal());
 await page.click('#accountMenu summary');await page.locator('.account-menu-options').getByRole('button',{name:'Badge Out',exact:true}).click();assert.equal(await page.locator('#navBadgeIn').isVisible(),true);
 await page.fill('#marketSearchInput','Prediction 6');assert.equal(await page.locator('.category-section').count(),1);assert.equal(await page.locator('.category-row .prediction-card').count(),1);await page.fill('#marketSearchInput','');
 await page.click('#tabBtn-leaderboard');assert.equal(await page.locator('#topMarkets').isVisible(),false);await page.click('#tabBtn-markets');assert.equal(await page.locator('#topMarkets').isVisible(),true);
 await page.screenshot({path:process.env.SCREENSHOT_DIR?path.join(process.env.SCREENSHOT_DIR,'officebets-desktop.png'):'/tmp/officebets-desktop.png',fullPage:true});
 for(const width of [390,760,1024]){await page.setViewportSize({width,height:900});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Page overflows at ${width}px`);assert.equal(await page.locator('#sidebarNewPrediction').isVisible(),true);assert.equal(await page.locator('#endingSoon').isVisible(),true);if(width===390)await page.screenshot({path:process.env.SCREENSHOT_DIR?path.join(process.env.SCREENSHOT_DIR,'officebets-mobile.png'):'/tmp/officebets-mobile.png',fullPage:true});}
 await page.evaluate(()=>{state.markets=[];renderAll();});assert.equal(await page.locator('#featuredDots button').count(),0);assert.equal(await page.locator('#featuredNext').isDisabled(),true);assert.match(await page.locator('#endingSoon').innerText(),/No open/);
 assert.deepEqual(errors,[]);await browser.close();console.log('PASS: layout, category rows, top-five ranking and disabled edges, ending soon, account menu, persistence, settings, confirmed deletion, search, tabs, responsive widths, empty states, whole-GW steps, card click/keyboard, admin early resolution and singleton chart');
})().catch(e=>{console.error(e);process.exit(1)});
