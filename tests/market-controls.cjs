// Permission rendering checks without a browser or live database.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, '../index.html'), 'utf8');
const context = vm.createContext({
  user: null, verifiedAdminId: null,
  getActiveUser() { return this.user; },
  getMarketStatus(m) { return {code: m.closedPermanently || m.expired ? 'CLOSED' : 'OPEN'}; },
  escapeHtmlAttr(s) { return s.replaceAll('&', '&amp;').replaceAll('"', '&quot;'); },
});
// Use the application's permission and rendering functions, not test copies.
vm.runInContext(html.slice(html.indexOf('    function canAdmin()'), html.indexOf('    async function refreshAdminAuthority()')) +
  html.slice(html.indexOf('    function marketActionOptions('), html.indexOf('    function closeMarketMenu(')), context);
// Bind the active-badge stub in the VM's own global scope.
vm.runInContext('getActiveUser = () => user;', context);
const market = {id:'market-1', title:'Team prediction', creatorId:'creator', resolved:false, everTraded:false, closedPermanently:false};
const cases = [
  ['guest', null, null, {}, []],
  ['unrelated teammate', {id:'other', isAdmin:false}, null, {}, []],
  ['creator, untouched', {id:'creator', isAdmin:false}, null, {}, ['Edit prediction','Close prediction early']],
  ['creator, traded', {id:'creator', isAdmin:false}, null, {everTraded:true}, ['Close prediction early']],
  ['creator, closed', {id:'creator', isAdmin:false}, null, {closedPermanently:true}, []],
  ['creator, resolved', {id:'creator', isAdmin:false}, null, {resolved:true}, []],
  ['unverified admin badge', {id:'creator', isAdmin:true}, null, {}, []],
  ['verified identity on another badge', {id:'creator', isAdmin:true}, 'other', {}, []],
  ['verified admin', {id:'admin', isAdmin:true}, 'admin', {}, ['Edit prediction','Close prediction early','Resolve early','Delete prediction']],
  ['verified admin, traded', {id:'admin', isAdmin:true}, 'admin', {everTraded:true}, ['Close prediction early','Resolve early','Delete prediction']],
  ['verified admin, closed', {id:'admin', isAdmin:true}, 'admin', {closedPermanently:true}, ['Resolve prediction','Delete prediction']],
  ['verified admin, resolved', {id:'admin', isAdmin:true}, 'admin', {resolved:true}, ['Reverse resolution','Delete prediction']],
  ['persistent instance', {id:'admin', isAdmin:true}, 'admin', {persistentBetId:'daily'}, ['Close prediction early','Resolve early']],
];
for (const [name, user, authority, changes, expected] of cases) {
  Object.assign(context, {user, verifiedAdminId:authority, market:{...market, ...changes}});
  const labels = vm.runInContext('availableMarketActions(market).map(a => a.label)', context);
  assert.deepEqual(Array.from(labels), expected, name);
  const button = vm.runInContext('marketControls(market)', context);
  assert.equal(!!button, expected.length > 0, name);
  if (button) {
    assert.match(button, /aria-controls="marketOverflow"/);
    assert.match(button, /<svg.*aria-hidden="true"/);
  }
}
console.log(`PASS: ${cases.length} market permission/rendering states`);
