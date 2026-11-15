/**
 * Crew Clock → Google Sheets sync.
 *
 * Clock in / clock out by QR. The tablet shows one QR code that changes every 30 seconds.
 * Workers scan it with their own phone and this script records the punch. A worker's first
 * scan asks "Who are you?" and links that phone to them; after that the phone clocks them
 * in or out straight away, and only that phone works for them.
 * (The older "tap your name, then scan" tablet version is still supported.)
 * Also receives worker details from the tablet. Older photo punches go to a private
 * Drive folder called "Crew Clock photos".
 *
 * After changing this file: Deploy → Manage deployments → ✏️ Edit → Version: New version → Deploy.
 * The web app link stays the same.
 *
 * Setup (one time):
 *   1. Paste this whole file into Extensions → Apps Script, then Save.
 *   2. Choose the "setup" function at the top and press Run. Allow access when asked.
 *      (Setup also adds a timer that keeps the script awake so scans are fast, builds the
 *      Summary tab for the owner, and refreshes it every 10 minutes.)
 *   3. Deploy → New deployment → type "Web app".
 *        Execute as: Me      Who has access: Anyone
 *      Press Deploy and copy the Web app URL.
 *   4. Tablet link = that URL + "?key=" + SYNC_KEY below.
 *      Paste it into Crew Clock → Manager → Cloud sync.
 */

// Secret that the tablet must send. Keep it private. If you change it, update the tablet link too.
const SYNC_KEY = 'PASTE_YOUR_SYNC_KEY_HERE';

// Time zone used for dates and times written to the sheet.
const TZ = 'Australia/Brisbane';

const PHOTO_FOLDER = 'Crew Clock photos';
const PUNCH_HEADERS = ['Date', 'Time', 'Week starting', 'Worker ID', 'Name', 'Punch', 'Shift hours', 'Photo', 'Recorded at', 'Ref'];
const WORKER_HEADERS = ['Worker ID', 'Name', 'Role', 'Status', 'ID photo', 'Added', 'Updated', 'Phone linked', 'Phone ID', 'Last punch', 'Last punch at'];
const W_PHONE_LINKED = 8; // column numbers in Workers
const W_PHONE_ID = 9;
const W_LAST = 10; // IN or OUT
const W_LAST_AT = 11; // time of the last punch

const CODE_SECONDS = 30; // the tablet's QR code changes this often
const REPEAT_GUARD_MS = 2 * 60 * 1000; // a second scan within 2 minutes doesn't flip IN/OUT

/** Run once from the editor: creates the tabs and the photo folder, and asks for permission. */
function setup() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  ensureSheets_(ss);
  getFolder_();
  installKeepWarm_();
  ss.setSpreadsheetTimeZone(TZ);
  installSummaryTrigger_();
  formatTabs();
  refreshSummary();
  Logger.log('Setup done. Now deploy as a Web app. Your sync key is: ' + SYNC_KEY);
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  if (p.a === 's') {
    return HtmlService.createHtmlOutput(stationPage_(String(p.q || '')))
      .setTitle('Crew Clock')
      .addMetaTag('viewport', 'width=device-width, initial-scale=1');
  }
  if (p.a === 'scan') {
    return HtmlService.createHtmlOutput(scanPage_(p))
      .setTitle('Crew Clock')
      .addMetaTag('viewport', 'width=device-width, initial-scale=1');
  }
  return ContentService.createTextOutput('Crew Clock sync is running. Paste this link, plus ?key=YOUR_KEY, into the tablet app.');
}

function doPost(e) {
  let body;
  try {
    body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
  } catch (err) {
    return out_({ ok: false, error: 'Unreadable request.' });
  }
  // Scans from workers' phones (via the scan web page). No sync key: the signed QR code proves the scan.
  try {
    if (body.type === 'station_scan') return out_(stationScan(String(body.q || ''), String(body.device || '')));
    if (body.type === 'station_link') return out_(stationLink(String(body.q || ''), String(body.device || ''), String(body.id || '')));
  } catch (err) {
    return out_({ ok: false, error: 'The timesheet is busy. Scan again. (' + String(err && err.message ? err.message : err) + ')' });
  }

  const key = (e && e.parameter && e.parameter.key) || body.key || '';
  if (key !== SYNC_KEY) return out_({ ok: false, error: 'Wrong sync key. Check the tablet link ends with ?key= and the key from the script.' });

  // Quick reads the tablet makes every few seconds: no lock, no spreadsheet.
  if (body.type === 'recent') return out_({ ok: true, items: recentList_(), now: Date.now() });
  if (body.type === 'qr_status') return out_(qrStatus_(String(body.token || '')));

  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(25000);

    const ss = SpreadsheetApp.getActiveSpreadsheet();
    ensureSheets_(ss);
    switch (body.type) {
      case 'ping':
        return out_({ ok: true, sheet: ss.getName() });
      case 'punch':
        return out_(addPunch_(ss, body));
      case 'worker':
        return out_(upsertWorker_(ss, body));
      case 'workers':
        return out_({ ok: true, workers: listWorkers_(ss.getSheetByName('Workers')) });
      case 'unlink':
        return out_(unlinkPhone_(ss, String(body.id || '')));
      default:
        return out_({ ok: false, error: 'Unknown record type: ' + body.type });
    }
  } catch (err) {
    return out_({ ok: false, error: String(err && err.message ? err.message : err) });
  } finally {
    try { lock.releaseLock(); } catch (ignored) {}
  }
}

function addPunch_(ss, b) {
  const sh = ss.getSheetByName('Punches');
  const ref = String(b.ref || '');
  if (ref && sh.getLastRow() > 1) {
    const hit = sh.getRange(2, 10, sh.getLastRow() - 1, 1).createTextFinder(ref).matchEntireCell(true).findNext();
    if (hit) return { ok: true, duplicate: true };
  }
  let photo = '';
  if (b.photo) {
    const url = saveImage_(b.photo, [b.id, b.punch, b.date, String(b.time || '').replace(':', '.')].join(' ') + '.jpg');
    photo = '=HYPERLINK("' + url + '","View photo")';
  }
  sh.appendRow([
    b.date, b.time, b.week, text_(b.id), text_(b.name), b.punch,
    b.hours === '' || b.hours == null ? '' : Number(b.hours),
    photo, b.at || '', ref,
  ]);
  return { ok: true };
}

function upsertWorker_(ss, b) {
  const sh = ss.getSheetByName('Workers');
  const id = String(b.id || '');
  if (!id) return { ok: false, error: 'Worker ID missing.' };
  let row = 0;
  if (sh.getLastRow() > 1) {
    const hit = sh.getRange(2, 1, sh.getLastRow() - 1, 1).createTextFinder(id).matchEntireCell(true).findNext();
    if (hit) row = hit.getRow();
  }
  let photoCell = row ? sh.getRange(row, 5).getFormula() || sh.getRange(row, 5).getValue() : '';
  if (b.photo) {
    const url = saveImage_(b.photo, id + ' ID photo ' + Utilities.formatDate(new Date(), ss.getSpreadsheetTimeZone(), 'yyyy-MM-dd HH.mm') + '.jpg');
    photoCell = '=HYPERLINK("' + url + '","View ID photo")';
  }
  const old = row ? sh.getRange(row, 1, 1, WORKER_HEADERS.length).getValues()[0] : [];
  const pick = (v, i) => (v === undefined || v === null ? (old[i] === undefined ? '' : old[i]) : v);
  const values = [text_(id), text_(pick(b.name, 1)), text_(pick(b.role, 2)), pick(b.status, 3), photoCell, pick(b.added, 5), new Date()];
  if (row) {
    sh.getRange(row, 1, 1, values.length).setValues([values]);
  } else {
    sh.appendRow(values);
  }
  return { ok: true };
}

function ensureSheets_(ss) {
  const made = [];
  let punches = ss.getSheetByName('Punches');
  if (!punches) {
    punches = ss.insertSheet('Punches');
    punches.getRange(1, 1, 1, PUNCH_HEADERS.length).setValues([PUNCH_HEADERS]).setFontWeight('bold');
    punches.setFrozenRows(1);
    punches.hideColumns(10); // Ref is only for avoiding duplicates
    made.push(punches);
  }
  let workers = ss.getSheetByName('Workers');
  if (!workers) {
    workers = ss.insertSheet('Workers');
    workers.getRange(1, 1, 1, WORKER_HEADERS.length).setValues([WORKER_HEADERS]).setFontWeight('bold');
    workers.setFrozenRows(1);
    made.push(workers);
  }
  if (workers.getRange(1, WORKER_HEADERS.length).getValue() !== WORKER_HEADERS[WORKER_HEADERS.length - 1]) {
    workers.getRange(1, 1, 1, WORKER_HEADERS.length).setValues([WORKER_HEADERS]).setFontWeight('bold');
    workers.hideColumns(W_PHONE_ID); // the phone's private ID is only for matching
  }
  if (!ss.getSheetByName('Weekly hours')) {
    const weekly = ss.insertSheet('Weekly hours', 0);
    weekly.getRange('A1').setFormula(
      '=IFERROR(QUERY(Punches!A:I, "select C, D, E, count(G), sum(G) where F = \'OUT\' and G is not null ' +
      'group by C, D, E order by C desc, E ' +
      'label C \'Week starting\', D \'Worker ID\', E \'Name\', count(G) \'Shifts\', sum(G) \'Hours\'", 1), ' +
      '"No completed shifts yet. Hours appear here after workers clock out.")'
    );
    weekly.getRange('A1:E1').setFontWeight('bold');
    weekly.setFrozenRows(1);
    made.push(weekly);
  }
  // Remove the empty starter tab once ours exist.
  const blank = ss.getSheetByName('Sheet1');
  if (made.length && blank && blank.getLastRow() === 0 && ss.getSheets().length > 1) ss.deleteSheet(blank);
}

// ---------------- QR clock in / out ----------------

/** HMAC-SHA256 of msg with SYNC_KEY, as hex. The tablet signs QR codes the same way. */
function sign_(msg) {
  const bytes = Utilities.computeHmacSha256Signature(msg, SYNC_KEY, Utilities.Charset.UTF_8);
  return bytes.map(function (b) { return ('0' + ((b + 256) % 256).toString(16)).slice(-2); }).join('');
}

/** Called from the phone's scan page. Checks the QR code and the phone, then records the punch. */
function confirmScan(p, device) {
  p = p || {};
  const token = String(p.t || ''), id = String(p.w || ''), name = String(p.n || ''), exp = Number(p.x || 0);
  const cache = CacheService.getScriptCache();
  const fail = function (msg) {
    if (token) cache.put('qre_' + token, msg, 600); // lets the tablet show why the scan was refused
    return { ok: false, error: msg };
  };
  if (!token || !id || !exp || !p.s) return fail('This QR code is incomplete. Tap your name on the tablet again.');
  if (sign_(token + '|' + id + '|' + name + '|' + exp) !== String(p.s)) {
    return fail('This QR code is not from the work tablet. Scan the code on the tablet.');
  }
  const now = Date.now();
  if (now > exp) return fail('This QR code has expired. Tap your name on the tablet again.');

  const lock = LockService.getScriptLock();
  lock.waitLock(25000);
  try {
    const done = cache.get('qr_' + token);
    if (done) {
      const prev = JSON.parse(done);
      prev.repeat = true;
      return prev; // same phone reloaded the page: show the same result
    }
    device = String(device || '');
    if (!/^D[A-Za-z0-9]{16,64}$/.test(device)) {
      return fail('Your phone\'s browser is blocking storage, so it can\'t be linked. Turn off private browsing and scan again.');
    }

    const ss = SpreadsheetApp.getActiveSpreadsheet();
    ensureSheets_(ss);
    const workers = ss.getSheetByName('Workers');
    let row = findRow_(workers, 1, id);
    if (row) {
      const status = String(workers.getRange(row, 4).getValue());
      if (status === 'Switched off') return fail(name + '\'s account is switched off. Ask your manager.');
    }

    // Phone linking: one phone per worker, one worker per phone.
    const owner = findRow_(workers, W_PHONE_ID, device);
    if (owner && owner !== row) {
      const other = workers.getRange(owner, 2).getValue();
      return fail('This phone is linked to ' + other + '. Each person must clock in with their own phone.');
    }
    const linked = row ? String(workers.getRange(row, W_PHONE_ID).getValue()) : '';
    if (linked && linked !== device) {
      return fail('This phone isn\'t linked to ' + name + '. Use your own phone, or ask your manager to reset your phone link.');
    }
    if (!row) {
      workers.appendRow([text_(id), text_(name), '', 'Active', '', '', new Date()]);
      row = workers.getLastRow();
    }
    let firstLink = false;
    if (!linked) {
      workers.getRange(row, W_PHONE_LINKED, 1, 2).setValues([[new Date(), device]]);
      firstLink = true;
    }

    const result = recordPunch_(ss, workers, row, id, name, now);
    result.firstLink = firstLink;
    cache.put('qr_' + token, JSON.stringify(result), 21600);
    cache.remove('qre_' + token);
    return result;
  } finally {
    try { lock.releaseLock(); } catch (ignored) {}
  }
}

// ---------------- Single QR for everyone ----------------

/** Writes an IN or OUT punch (the opposite of the worker's last one) and returns the result. */
function recordPunch_(ss, workers, row, id, name, now) {
  const punches = ss.getSheetByName('Punches');
  let lastType = String(workers.getRange(row, W_LAST).getValue() || '');
  let lastAt = Number(workers.getRange(row, W_LAST_AT).getValue()) || 0;
  if (!lastType && punches.getLastRow() > 1) {
    // Older sheets: find the last punch in the Punches tab.
    const rows = punches.getRange(2, 4, punches.getLastRow() - 1, 6).getValues(); // D..I
    for (let i = rows.length - 1; i >= 0; i--) {
      if (String(rows[i][0]) === id) {
        lastType = String(rows[i][2]);
        lastAt = Date.parse(rows[i][5]) || 0;
        break;
      }
    }
  }
  const punch = lastType === 'IN' ? 'OUT' : 'IN';
  const hours = punch === 'OUT' && lastAt ? Math.round((now - lastAt) / 36000) / 100 : '';
  const d = new Date(now);
  const dow = Number(Utilities.formatDate(d, TZ, 'u')); // 1 = Monday
  const date = Utilities.formatDate(d, TZ, 'yyyy-MM-dd');
  const time = Utilities.formatDate(d, TZ, 'h:mm a').toLowerCase();
  const week = Utilities.formatDate(new Date(now - (dow - 1) * 86400000), TZ, 'yyyy-MM-dd');
  punches.appendRow([Utilities.parseDate(date, TZ, 'yyyy-MM-dd'), time, Utilities.parseDate(week, TZ, 'yyyy-MM-dd'),
    text_(id), text_(name), punch, hours, '', d.toISOString(), 'P-' + id + '-' + now]);
  workers.getRange(row, W_LAST, 1, 2).setValues([[punch, now]]);
  const result = { ok: true, punch: punch, name: name, id: id, time: time, date: date, hours: hours, at: now };
  pushRecent_(result);
  return result;
}

// Note: Google reserves the URL parameters "c" and "sid", so the code travels as "q".
/** QR codes look like "<window>.<signature>". A code is good for a few windows (about 1–2 minutes). */
function stationCodeProblem_(code, maxAgeWindows) {
  const m = /^(\d+)\.([0-9a-f]{12})$/.exec(String(code || ''));
  if (!m) return 'This QR link is from an older version of Crew Clock. Update the station or tablet app, then scan again. (code A)';
  const w = Number(m[1]);
  if (sign_('w|' + w).slice(0, 12) !== m[2]) {
    return 'This code isn\'t from your work station. Check the station uses the same sheet link and key as this script. (code B)';
  }
  const nowW = Math.floor(Date.now() / (CODE_SECONDS * 1000));
  if (nowW - w > maxAgeWindows) return 'This code has expired. Scan the code on the station again. (code C)';
  if (w - nowW > 2) return 'The station\'s clock is ahead of the real time. Fix the date and time on the station, then scan again. (code D)';
  return '';
}

function validDevice_(device) {
  return /^D[A-Za-z0-9]{16,64}$/.test(String(device || ''));
}

/** Called by the phone right after scanning the tablet's QR code. */
function stationScan(code, device) {
  const problem = stationCodeProblem_(code, 4);
  if (problem) return { ok: false, error: problem };
  if (!validDevice_(device)) {
    return { ok: false, error: 'Your phone\'s browser is blocking storage, so it can\'t be linked. Turn off private browsing and scan again.' };
  }
  const lock = LockService.getScriptLock();
  lock.waitLock(25000);
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    ensureSheets_(ss);
    const workers = ss.getSheetByName('Workers');
    const row = findRow_(workers, W_PHONE_ID, device);
    if (!row) return { ok: true, needsLink: true, workers: unlinkedWorkers_(workers) };
    const vals = workers.getRange(row, 1, 1, W_LAST_AT).getValues()[0];
    const id = String(vals[0]), name = String(vals[1]);
    if (String(vals[3]) === 'Switched off') return { ok: false, error: name + '\'s account is switched off. Ask your manager.' };
    const now = Date.now();
    const lastAt = Number(vals[W_LAST_AT - 1]) || 0;
    if (lastAt && now - lastAt < REPEAT_GUARD_MS) {
      const mins = Math.max(1, Math.ceil((REPEAT_GUARD_MS - (now - lastAt)) / 60000));
      return {
        ok: true, repeat: true, punch: String(vals[W_LAST - 1]), name: name, id: id,
        time: Utilities.formatDate(new Date(lastAt), TZ, 'h:mm a').toLowerCase(), hours: '',
        note: 'Already recorded. To ' + (String(vals[W_LAST - 1]) === 'IN' ? 'clock out' : 'clock in') + ', scan again in ' + mins + ' min.',
      };
    }
    return recordPunch_(ss, workers, row, id, name, now);
  } finally {
    try { lock.releaseLock(); } catch (ignored) {}
  }
}

/** First scan on a phone: the worker picked their name, so link this phone and record the punch. */
function stationLink(code, device, id) {
  const problem = stationCodeProblem_(code, 10);
  if (problem) return { ok: false, error: problem };
  if (!validDevice_(device)) return { ok: false, error: 'Your phone\'s browser is blocking storage. Turn off private browsing and scan again.' };
  const lock = LockService.getScriptLock();
  lock.waitLock(25000);
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    ensureSheets_(ss);
    const workers = ss.getSheetByName('Workers');
    const owner = findRow_(workers, W_PHONE_ID, device);
    if (owner) {
      return { ok: false, error: 'This phone is already linked to ' + workers.getRange(owner, 2).getValue() + '. Scan the code again.' };
    }
    const row = findRow_(workers, 1, String(id || ''));
    if (!row) return { ok: false, error: 'That name isn\'t on the list any more. Ask your manager.' };
    const vals = workers.getRange(row, 1, 1, W_PHONE_ID).getValues()[0];
    const name = String(vals[1]);
    if (String(vals[3]) === 'Switched off') return { ok: false, error: name + '\'s account is switched off. Ask your manager.' };
    if (String(vals[W_PHONE_ID - 1])) {
      return { ok: false, error: name + ' is already linked to another phone. If that\'s you with a new phone, ask your manager to reset your phone link.' };
    }
    workers.getRange(row, W_PHONE_LINKED, 1, 2).setValues([[new Date(), String(device)]]);
    const result = recordPunch_(ss, workers, row, String(vals[0]), name, Date.now());
    result.firstLink = true;
    return result;
  } finally {
    try { lock.releaseLock(); } catch (ignored) {}
  }
}

/** Everyone in the Workers tab, for the manager screen. Phone IDs are never sent, only whether one is linked. */
function listWorkers_(workers) {
  if (workers.getLastRow() < 2) return [];
  return workers.getRange(2, 1, workers.getLastRow() - 1, W_LAST_AT).getValues()
    .filter(function (r) { return r[0]; })
    .map(function (r) {
      return {
        id: String(r[0]), name: String(r[1]), role: String(r[2]), status: String(r[3] || 'Active'),
        linked: !!String(r[W_PHONE_ID - 1]), lastPunch: String(r[W_LAST - 1] || ''), lastAt: Number(r[W_LAST_AT - 1]) || 0,
      };
    });
}

/** Active workers without a linked phone, for the "Who are you?" list. */
function unlinkedWorkers_(workers) {
  if (workers.getLastRow() < 2) return [];
  return workers.getRange(2, 1, workers.getLastRow() - 1, W_PHONE_ID).getValues()
    .filter(function (r) { return r[0] && String(r[3]) !== 'Switched off' && !String(r[W_PHONE_ID - 1]); })
    .map(function (r) { return { id: String(r[0]), name: String(r[1]) }; })
    .sort(function (a, b) { return a.name.localeCompare(b.name); });
}

/** Latest punches, kept in the cache so the tablet can show "who just clocked in" cheaply. */
function pushRecent_(result) {
  const cache = CacheService.getScriptCache();
  const list = recentList_();
  list.unshift({ id: result.id, name: result.name, punch: result.punch, time: result.time, hours: result.hours, at: result.at });
  cache.put('recent', JSON.stringify(list.slice(0, 40)), 21600);
}

function recentList_() {
  const raw = CacheService.getScriptCache().get('recent');
  try { return raw ? JSON.parse(raw) : []; } catch (e) { return []; }
}

/** Runs every 5 minutes so the script stays loaded and scans are answered quickly. */
function keepWarm() {
  CacheService.getScriptCache().get('recent');
}

function installKeepWarm_() {
  const exists = ScriptApp.getProjectTriggers().some(function (t) { return t.getHandlerFunction() === 'keepWarm'; });
  if (!exists) ScriptApp.newTrigger('keepWarm').timeBased().everyMinutes(5).create();
}

/** The page a phone opens after scanning the tablet's single QR code. */
function stationPage_(code) {
  const c = JSON.stringify(String(code)).replace(/</g, '\\u003c');
  return '<!doctype html><html><head><meta charset="utf-8"><style>' +
    'body{margin:0;font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:#F2F0EF;color:#231F20}' +
    'header{background:#DA291C;color:#fff;padding:18px 20px;border-bottom:4px solid #F6BE00}' +
    'header b{font-size:20px;letter-spacing:1px}header span{display:block;font-size:11px;letter-spacing:1.5px;color:#F6BE00;font-weight:600}' +
    'main{padding:24px 16px;max-width:480px;margin:0 auto}' +
    '.card{background:#fff;border:1px solid #DDD8D5;border-radius:14px;padding:24px 18px;text-align:center}' +
    '.big{font-size:42px;font-weight:800;margin:6px 0}.mark{font-size:56px;line-height:1}' +
    '.in{color:#3E8468}.out{color:#9A5A00}.err{color:#9F1D14}.muted{color:#6B6461;font-size:15px}' +
    '.spin{width:36px;height:36px;border:4px solid #DDD8D5;border-top-color:#DA291C;border-radius:50%;margin:10px auto;animation:s 1s linear infinite}' +
    '@keyframes s{to{transform:rotate(360deg)}}' +
    'h2{margin:0 0 4px;font-size:22px}.list{text-align:left;margin-top:14px;display:flex;flex-direction:column;gap:8px}' +
    'button{font:inherit;font-size:17px;padding:14px 16px;border-radius:10px;border:1px solid #DDD8D5;background:#fff;color:#231F20;text-align:left;cursor:pointer}' +
    'button.primary{background:#DA291C;color:#fff;border-color:#DA291C;text-align:center;font-weight:700}' +
    'button.plain{text-align:center}input{font:inherit;font-size:17px;padding:12px 14px;border-radius:10px;border:1px solid #DDD8D5;width:100%;box-sizing:border-box}' +
    '</style></head><body><header><b>CREW CLOCK</b><span>JAYBEL OFFICE CHOICE</span></header>' +
    '<main><div class="card" id="c"><div class="spin"></div><p class="muted">Recording your scan…</p></div></main>' +
    '<script>var C=' + c + ',W=[];' +
    'function $(){return document.getElementById("c")}' +
    'function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;"}[c]})}' +
    'function dev(){try{var d=localStorage.getItem("ccDevice");if(!d){var a=new Uint8Array(16);crypto.getRandomValues(a);' +
    'd="D"+Array.from(a,function(b){return("0"+b.toString(16)).slice(-2)}).join("");localStorage.setItem("ccDevice",d)}return d}catch(e){return""}}' +
    'function wait(t){$().innerHTML="<div class=\\"spin\\"></div><p class=\\"muted\\">"+t+"</p>"}' +
    'function fail(e){show({ok:false,error:"Couldn\'t reach the timesheet. Check your internet and scan again."})}' +
    'function show(r){if(r&&r.needsLink){W=r.workers||[];pick("");return}var c=$();' +
    'if(r&&r.ok){var isIn=r.punch==="IN";' +
    'c.innerHTML="<div class=\\"mark "+(isIn?"in":"out")+"\\">&#10003;</div><div class=\\"big "+(isIn?"in":"out")+"\\">"+(isIn?"Clocked in":"Clocked out")+"</div>"+' +
    '"<p style=\\"font-size:20px;margin:8px 0\\"><b>"+esc(r.name)+"</b> · "+esc(r.time)+"</p>"+' +
    '(r.hours!==""&&r.hours!=null?"<p class=\\"muted\\">Shift length: "+esc(r.hours)+" h</p>":"")+' +
    '(r.note?"<p class=\\"muted\\">"+esc(r.note)+"</p>":"")+' +
    '(r.firstLink?"<p class=\\"muted\\">This phone is now linked to you. Next time, just scan the code.</p>":"")+' +
    '"<p class=\\"muted\\">You can close this page.</p>"}' +
    'else{c.innerHTML="<div class=\\"mark err\\">!</div><p style=\\"font-size:18px\\" class=\\"err\\"><b>Not recorded</b></p><p>"+esc(r&&r.error||"Something went wrong. Scan again.")+"</p>"}}' +
    'function pick(q){var c=$();var ql=q.toLowerCase();var rows=W.filter(function(w){return !ql||w.name.toLowerCase().indexOf(ql)>=0});' +
    'c.style.textAlign="left";c.innerHTML="<h2>Who are you?</h2><p class=\\"muted\\">First time on this phone. Pick your name once and this phone is linked to you.</p>"+' +
    '(W.length>8?"<input id=\\"q\\" placeholder=\\"Find your name\\" value=\\""+esc(q)+"\\">":"")+' +
    '"<div class=\\"list\\">"+(rows.length?rows.map(function(w){return"<button data-id=\\""+esc(w.id)+"\\">"+esc(w.name)+"</button>"}).join(""):' +
    '"<p class=\\"muted\\">"+(W.length?"No one matches.":"Everyone already has a linked phone.")+" Don\'t see your name? Ask your manager to add you or reset your phone link.</p>")+"</div>";' +
    'var qi=document.getElementById("q");if(qi){qi.oninput=function(){pick(qi.value);var n=document.getElementById("q");n.focus();n.setSelectionRange(n.value.length,n.value.length)}}' +
    'c.querySelectorAll("button[data-id]").forEach(function(b){b.onclick=function(){confirmPick(b.getAttribute("data-id"),b.textContent)}})}' +
    'function confirmPick(id,name){var c=$();c.style.textAlign="center";' +
    'c.innerHTML="<h2>Are you "+esc(name)+"?</h2><p class=\\"muted\\">This links this phone to "+esc(name)+". Only "+esc(name)+" can use it to clock in and out.</p>"+' +
    '"<div class=\\"list\\"><button class=\\"primary\\" id=\\"yes\\">Yes, that\'s me</button><button class=\\"plain\\" id=\\"no\\">Back</button></div>";' +
    'document.getElementById("no").onclick=function(){pick("")};' +
    'document.getElementById("yes").onclick=function(){c.style.textAlign="center";wait("Linking your phone…");' +
    'google.script.run.withSuccessHandler(show).withFailureHandler(fail).stationLink(C,dev(),id)}}' +
    'google.script.run.withSuccessHandler(show).withFailureHandler(fail).stationScan(C,dev());' +
    '</script></body></html>';
}

/** The tablet asks this every few seconds while its QR code is on screen. */
function qrStatus_(token) {
  if (!token) return { ok: false, error: 'Token missing.' };
  const cache = CacheService.getScriptCache();
  const done = cache.get('qr_' + token);
  if (done) return { ok: true, done: true, result: JSON.parse(done) };
  const refused = cache.get('qre_' + token);
  return { ok: true, done: false, refused: refused || '' };
}

function unlinkPhone_(ss, id) {
  const workers = ss.getSheetByName('Workers');
  const row = findRow_(workers, 1, id);
  if (!row) return { ok: true, unlinked: false };
  workers.getRange(row, W_PHONE_LINKED, 1, 2).setValues([['', '']]);
  return { ok: true, unlinked: true };
}

function findRow_(sheet, col, value) {
  if (!value || sheet.getLastRow() < 2) return 0;
  const hit = sheet.getRange(2, col, sheet.getLastRow() - 1, 1).createTextFinder(String(value)).matchEntireCell(true).findNext();
  return hit ? hit.getRow() : 0;
}

/** The page the worker's phone opens after scanning. */
function scanPage_(p) {
  const params = JSON.stringify({ t: p.t || '', w: p.w || '', n: p.n || '', x: p.x || '', s: p.s || '' }).replace(/</g, '\\u003c');
  return '<!doctype html><html><head><meta charset="utf-8"><style>' +
    'body{margin:0;font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:#F2F0EF;color:#231F20}' +
    'header{background:#DA291C;color:#fff;padding:18px 20px;border-bottom:4px solid #F6BE00}' +
    'header b{font-size:20px;letter-spacing:1px}header span{display:block;font-size:11px;letter-spacing:1.5px;color:#F6BE00;font-weight:600}' +
    'main{padding:28px 20px;max-width:480px;margin:0 auto;text-align:center}' +
    '.card{background:#fff;border:1px solid #DDD8D5;border-radius:14px;padding:28px 20px}' +
    '.big{font-size:44px;font-weight:800;margin:6px 0}.mark{font-size:56px;line-height:1}' +
    '.in{color:#3E8468}.out{color:#9A5A00}.err{color:#9F1D14}.muted{color:#6B6461;font-size:15px}' +
    '.spin{width:36px;height:36px;border:4px solid #DDD8D5;border-top-color:#DA291C;border-radius:50%;margin:10px auto;animation:s 1s linear infinite}' +
    '@keyframes s{to{transform:rotate(360deg)}}' +
    '</style></head><body><header><b>CREW CLOCK</b><span>JAYBEL OFFICE CHOICE</span></header>' +
    '<main><div class="card" id="c"><div class="spin"></div><p class="muted">Recording your scan…</p></div></main>' +
    '<script>var P=' + params + ';' +
    'function esc(s){return String(s).replace(/[&<>"]/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;"}[c]})}' +
    'function dev(){try{var d=localStorage.getItem("ccDevice");if(!d){var a=new Uint8Array(16);crypto.getRandomValues(a);' +
    'd="D"+Array.from(a,function(b){return("0"+b.toString(16)).slice(-2)}).join("");localStorage.setItem("ccDevice",d)}return d}catch(e){return""}}' +
    'function show(r){var c=document.getElementById("c");if(r&&r.ok){var isIn=r.punch==="IN";' +
    'c.innerHTML="<div class=\\"mark "+(isIn?"in":"out")+"\\">&#10003;</div><div class=\\"big "+(isIn?"in":"out")+"\\">"+(isIn?"Clocked in":"Clocked out")+"</div>"+' +
    '"<p style=\\"font-size:20px;margin:8px 0\\"><b>"+esc(r.name)+"</b> · "+esc(r.time)+"</p>"+' +
    '(r.hours!==""&&r.hours!=null?"<p class=\\"muted\\">Shift length: "+esc(r.hours)+" h</p>":"")+' +
    '(r.firstLink?"<p class=\\"muted\\">This phone is now linked to you. Use it every time you clock in or out.</p>":"")+' +
    '"<p class=\\"muted\\">You can close this page.</p>"}' +
    'else{c.innerHTML="<div class=\\"mark err\\">!</div><p style=\\"font-size:18px\\" class=\\"err\\"><b>Not recorded</b></p><p>"+esc(r&&r.error||"Something went wrong. Try again.")+"</p>"}}' +
    'google.script.run.withSuccessHandler(show).withFailureHandler(function(e){show({ok:false,error:"Couldn\'t reach the timesheet. Check your internet and scan again."})}).confirmScan(P,dev());' +
    '</script></body></html>';
}

function getFolder_() {
  const props = PropertiesService.getScriptProperties();
  const id = props.getProperty('photoFolderId');
  if (id) {
    try { return DriveApp.getFolderById(id); } catch (ignored) {}
  }
  const found = DriveApp.getFoldersByName(PHOTO_FOLDER);
  const folder = found.hasNext() ? found.next() : DriveApp.createFolder(PHOTO_FOLDER);
  props.setProperty('photoFolderId', folder.getId());
  return folder;
}

function saveImage_(base64, name) {
  const blob = Utilities.newBlob(Utilities.base64Decode(base64), 'image/jpeg', name);
  return getFolder_().createFile(blob).getUrl();
}

/** Stops typed text being treated as a formula. */
function text_(v) {
  const s = String(v == null ? '' : v);
  return /^[=+\-@]/.test(s) ? "'" + s : s;
}

function out_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// ---------------- Owner report: the Summary tab ----------------

const BRAND = { red: '#DA291C', yellow: '#F6BE00', ink: '#231F20', grey: '#F2F0EF', line: '#DDD8D5', muted: '#6B6461', green: '#3E8468', greenBg: '#E2EFE9', amber: '#9A5A00', amberBg: '#FDF1CC', errBg: '#FBE3E1', err: '#9F1D14' };
const PERIODS = ['This week', 'Last week', 'This month', 'Last month', 'Last 7 days', 'Last 30 days', 'Custom dates'];
const LONG_SHIFT_HOURS = 12; // shifts longer than this are flagged
const FORGOT_OUT_HOURS = 14; // still clocked in after this long: probably forgot to clock out

/** Adds the Crew Clock menu and refreshes the Summary when the sheet is opened. */
function onOpen() {
  SpreadsheetApp.getUi().createMenu('Crew Clock')
    .addItem('Refresh summary', 'refreshSummary')
    .addItem('Tidy up all tabs', 'formatTabs')
    .addToUi();
  try { refreshSummary(); } catch (e) {}
}

/** Changing the period on the Summary tab rebuilds it straight away. */
function onEdit(e) {
  try {
    const r = e && e.range;
    if (!r || r.getSheet().getName() !== 'Summary') return;
    const a1 = r.getA1Notation();
    if (a1 === 'C6' || a1 === 'H6' || a1 === 'J6') refreshSummary();
  } catch (err) {}
}

function installSummaryTrigger_() {
  const exists = ScriptApp.getProjectTriggers().some(function (t) { return t.getHandlerFunction() === 'refreshSummary'; });
  if (!exists) ScriptApp.newTrigger('refreshSummary').timeBased().everyMinutes(10).create();
}

const dayKey_ = function (ms) { return Utilities.formatDate(new Date(ms), TZ, 'yyyy-MM-dd'); };
const keyToDate_ = function (k) { return Utilities.parseDate(k, TZ, 'yyyy-MM-dd'); };
const addDays_ = function (k, n) { return dayKey_(keyToDate_(k).getTime() + n * 86400000 + 12 * 3600000); };
const hm_ = function (h) { const m = Math.round(h * 60); return Math.floor(m / 60) + ':' + ('0' + (m % 60)).slice(-2); };
const when_ = function (ms) { return Utilities.formatDate(new Date(ms), TZ, 'EEE d MMM, h:mm a').replace('AM', 'am').replace('PM', 'pm'); };

/** Start and end day keys (inclusive) for the chosen period. */
function periodRange_(period, customFrom, customTo) {
  const today = dayKey_(Date.now());
  const dow = Number(Utilities.formatDate(new Date(), TZ, 'u'));
  const monday = addDays_(today, -(dow - 1));
  const monthStart = today.slice(0, 8) + '01';
  const prevMonthEnd = addDays_(monthStart, -1);
  switch (period) {
    case 'Last week': return [addDays_(monday, -7), addDays_(monday, -1)];
    case 'This month': return [monthStart, addDays_(addDays_(monthStart, 32).slice(0, 8) + '01', -1)];
    case 'Last month': return [prevMonthEnd.slice(0, 8) + '01', prevMonthEnd];
    case 'Last 7 days': return [addDays_(today, -6), today];
    case 'Last 30 days': return [addDays_(today, -29), today];
    case 'Custom dates': {
      const f = customFrom instanceof Date ? dayKey_(customFrom.getTime() + 12 * 3600000) : '';
      const t = customTo instanceof Date ? dayKey_(customTo.getTime() + 12 * 3600000) : '';
      if (f && t && f <= t) return [f, t];
      return [monday, addDays_(monday, 6)];
    }
    default: return [monday, addDays_(monday, 6)];
  }
}

/** Pairs every clock-in with the next clock-out, per worker. */
function allShifts_(ss) {
  const sh = ss.getSheetByName('Punches');
  if (!sh || sh.getLastRow() < 2) return [];
  const rows = sh.getRange(2, 1, sh.getLastRow() - 1, 9).getValues();
  const punches = [];
  rows.forEach(function (r) {
    const at = Date.parse(r[8]) || 0;
    if (!at || !r[3]) return;
    punches.push({ id: String(r[3]), name: String(r[4]), type: String(r[5]), at: at });
  });
  punches.sort(function (a, b) { return a.at - b.at; });
  const open = {}, shifts = [];
  punches.forEach(function (p) {
    if (p.type === 'IN') {
      if (open[p.id]) shifts.push({ id: p.id, name: open[p.id].name, in: open[p.id].at, out: 0, hours: 0, open: false, missingOut: true });
      open[p.id] = p;
    } else if (p.type === 'OUT' && open[p.id]) {
      const st = open[p.id];
      shifts.push({ id: p.id, name: st.name, in: st.at, out: p.at, hours: (p.at - st.at) / 3600000, open: false });
      delete open[p.id];
    }
  });
  Object.keys(open).forEach(function (id) {
    shifts.push({ id: id, name: open[id].name, in: open[id].at, out: 0, hours: 0, open: true });
  });
  return shifts;
}

/** Works out the numbers for the Summary tab. Kept separate from the drawing so it can be tested. */
function summaryData_(ss, period, customFrom, customTo) {
  const range = periodRange_(period, customFrom, customTo);
  const from = range[0], to = range[1];
  const wsh = ss.getSheetByName('Workers');
  const people = {};
  if (wsh && wsh.getLastRow() > 1) {
    wsh.getRange(2, 1, wsh.getLastRow() - 1, 4).getValues().forEach(function (r) {
      if (r[0]) people[String(r[0])] = { id: String(r[0]), name: String(r[1]), role: String(r[2]), status: String(r[3] || 'Active') };
    });
  }
  const shifts = allShifts_(ss);
  const now = Date.now();
  const rows = {};
  const ensure = function (id, name) {
    if (!rows[id]) {
      const p = people[id] || { id: id, name: name, role: '', status: 'Active' };
      rows[id] = { id: id, name: p.name || name, role: p.role, status: p.status, shifts: 0, hours: 0, days: {}, daily: {}, firstIn: 0, lastOut: 0, onShift: false };
    }
    return rows[id];
  };
  Object.keys(people).forEach(function (id) { if (people[id].status !== 'Switched off') ensure(id, people[id].name); });

  const attention = [];
  shifts.forEach(function (s) {
    const k = dayKey_(s.in);
    if (s.open) {
      ensure(s.id, s.name).onShift = true;
      const hrs = (now - s.in) / 3600000;
      if (hrs > FORGOT_OUT_HOURS) attention.push({ name: s.name, issue: 'Still clocked in after ' + hm_(hrs) + ' h. Probably forgot to clock out.', when: when_(s.in) });
      return;
    }
    if (k < from || k > to) return;
    if (s.missingOut) {
      attention.push({ name: s.name, issue: 'Clocked in twice without clocking out. This shift has no hours.', when: when_(s.in) });
      return;
    }
    const r = ensure(s.id, s.name);
    r.shifts++;
    r.hours += s.hours;
    r.days[k] = true;
    r.daily[k] = (r.daily[k] || 0) + s.hours;
    if (!r.firstIn || s.in < r.firstIn) r.firstIn = s.in;
    if (s.out > r.lastOut) r.lastOut = s.out;
    if (s.hours > LONG_SHIFT_HOURS) attention.push({ name: s.name, issue: 'Long shift: ' + hm_(s.hours) + ' h. Check the clock-out time.', when: when_(s.in) });
  });

  const list = Object.keys(rows).map(function (id) { return rows[id]; })
    .sort(function (a, b) { return (b.hours - a.hours) || a.name.localeCompare(b.name); });
  const days = [];
  for (let k = from; k <= to && days.length < 62; k = addDays_(k, 1)) days.push(k);
  return {
    from: from, to: to, days: days, list: list, attention: attention,
    totalHours: list.reduce(function (t, r) { return t + r.hours; }, 0),
    totalShifts: list.reduce(function (t, r) { return t + r.shifts; }, 0),
    worked: list.filter(function (r) { return r.shifts > 0; }).length,
    onShift: list.filter(function (r) { return r.onShift; }).length,
  };
}

/** Rebuilds the Summary tab. Runs on open, when the period changes, and every 10 minutes. */
function refreshSummary() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  ensureSheets_(ss);
  let sh = ss.getSheetByName('Summary');
  let period = 'This week', customFrom = '', customTo = '';
  if (sh) {
    period = String(sh.getRange('C6').getValue() || 'This week');
    customFrom = sh.getRange('H6').getValue();
    customTo = sh.getRange('J6').getValue();
  } else {
    sh = ss.insertSheet('Summary', 0);
  }
  if (PERIODS.indexOf(period) < 0) period = 'This week';
  const d = summaryData_(ss, period, customFrom, customTo);

  sh.getCharts().forEach(function (c) { sh.removeChart(c); });
  sh.clear();
  sh.clearConditionalFormatRules();
  sh.getRange(1, 1, sh.getMaxRows(), sh.getMaxColumns()).clearDataValidations().setFontFamily('Roboto').setFontColor(BRAND.ink).setVerticalAlignment('middle');
  sh.setHiddenGridlines(true);
  const cols = 12 + Math.max(0, d.days.length - 10);
  if (sh.getMaxColumns() < cols + 2) sh.insertColumnsAfter(sh.getMaxColumns(), cols + 2 - sh.getMaxColumns());
  sh.setColumnWidth(1, 16);
  sh.setColumnWidth(2, 190);
  const widths = { 3: 130, 4: 110, 5: 80, 6: 80, 7: 100, 8: 100, 9: 90, 10: 160, 11: 160, 12: 100 };
  for (let c = 3; c <= cols + 1; c++) sh.setColumnWidth(c, widths[c] || 64);

  // Header band
  const band = sh.getRange(1, 1, 4, cols + 1);
  band.setBackground(BRAND.red);
  sh.getRange(1, 2).setValue('JAYBEL OFFICE CHOICE').setFontColor(BRAND.yellow).setFontSize(10).setFontWeight('bold');
  sh.getRange(2, 2).setValue('Staff hours').setFontColor('#FFFFFF').setFontSize(22).setFontWeight('bold');
  sh.getRange(3, 2).setValue('Crew Clock timesheet · updated ' + when_(Date.now()) + ' · refreshes every 10 minutes')
    .setFontColor('#FFFFFF').setFontSize(10);
  sh.getRange(4, 1, 1, cols + 1).setBackground(BRAND.yellow);
  sh.setRowHeight(1, 24); sh.setRowHeight(2, 40); sh.setRowHeight(3, 22); sh.setRowHeight(4, 4);

  // Period picker
  sh.getRange('B6').setValue('PERIOD').setFontSize(9).setFontWeight('bold').setFontColor(BRAND.muted).setHorizontalAlignment('right');
  sh.getRange('C6:D6').merge().setValue(period).setFontWeight('bold').setBackground('#FFFFFF')
    .setBorder(true, true, true, true, false, false, BRAND.red, SpreadsheetApp.BorderStyle.SOLID_MEDIUM)
    .setDataValidation(SpreadsheetApp.newDataValidation().requireValueInList(PERIODS, true).setAllowInvalid(false).build());
  sh.getRange('E6').setNumberFormat('@').setValue(Utilities.formatDate(keyToDate_(d.from), TZ, 'EEE d MMM') + ' – ' + Utilities.formatDate(keyToDate_(d.to), TZ, 'EEE d MMM yyyy'))
    .setFontColor(BRAND.muted);
  sh.getRange('G6').setValue('From').setFontSize(9).setFontColor(BRAND.muted).setHorizontalAlignment('right');
  sh.getRange('I6').setValue('To').setFontSize(9).setFontColor(BRAND.muted).setHorizontalAlignment('right');
  const dateRule = SpreadsheetApp.newDataValidation().requireDate().setAllowInvalid(false).build();
  sh.getRange('H6').setValue(customFrom instanceof Date ? customFrom : '').setDataValidation(dateRule).setNumberFormat('d mmm yyyy').setBackground(BRAND.grey);
  sh.getRange('J6').setValue(customTo instanceof Date ? customTo : '').setDataValidation(dateRule).setNumberFormat('d mmm yyyy').setBackground(BRAND.grey);
  sh.getRange('K6').setValue('← for "Custom dates"').setFontSize(9).setFontColor(BRAND.muted);
  sh.setRowHeight(6, 30);

  // Headline tiles
  const tiles = [
    ['TOTAL HOURS', Math.round(d.totalHours * 100) / 100, '0.00', BRAND.ink],
    ['SHIFTS', d.totalShifts, '0', BRAND.ink],
    ['STAFF WORKED', d.worked, '0', BRAND.ink],
    ['ON SHIFT NOW', d.onShift, '0', d.onShift ? BRAND.green : BRAND.muted],
  ];
  tiles.forEach(function (t, i) {
    const c = 2 + i * 2;
    sh.getRange(8, c, 1, 2).merge().setValue(t[0]).setFontSize(9).setFontWeight('bold').setFontColor(BRAND.muted).setBackground(BRAND.grey);
    sh.getRange(9, c, 1, 2).merge().setValue(t[1]).setNumberFormat(t[2]).setFontSize(24).setFontWeight('bold').setFontColor(t[3])
      .setBackground(BRAND.grey).setHorizontalAlignment('left');
    sh.getRange(8, c, 2, 2).setBorder(true, true, true, true, false, false, '#FFFFFF', SpreadsheetApp.BorderStyle.SOLID_THICK);
  });
  sh.setRowHeight(8, 22); sh.setRowHeight(9, 44);

  // Hours by employee
  let row = 11;
  const section = function (r, title, note) {
    sh.getRange(r, 2).setValue(title).setFontSize(12).setFontWeight('bold');
    if (note) sh.getRange(r, 4).setValue(note).setFontSize(9).setFontColor(BRAND.muted);
    sh.setRowHeight(r, 28);
  };
  section(row, 'Hours by employee', 'Shifts count on the day they started. Hours are clock-in to clock-out.');
  row++;
  const head = ['Employee', 'ID', 'Role', 'Shifts', 'Days', 'Total hours', 'Total (h:mm)', 'Avg shift', 'First clock-in', 'Last clock-out', 'Status'];
  sh.getRange(row, 2, 1, head.length).setValues([head]).setBackground(BRAND.ink).setFontColor('#FFFFFF').setFontWeight('bold').setFontSize(10);
  sh.getRange(row, 5, 1, 5).setHorizontalAlignment('right');
  sh.setRowHeight(row, 28);
  const tableTop = row + 1;
  if (d.list.length) {
    const values = d.list.map(function (r) {
      return [r.name, r.id, r.role, r.shifts, Object.keys(r.days).length, Math.round(r.hours * 100) / 100, hm_(r.hours),
        r.shifts ? Math.round(r.hours / r.shifts * 100) / 100 : '', r.firstIn ? when_(r.firstIn) : '', r.lastOut ? when_(r.lastOut) : '',
        r.onShift ? 'On shift' : (r.status === 'Switched off' ? 'Switched off' : 'Off')];
    });
    const body = sh.getRange(tableTop, 2, values.length, head.length);
    // Keep "42:30" and "Mon 9 Nov, 7:00 am" as text so Sheets doesn't turn them into dates.
    sh.getRange(tableTop, 8, values.length + 1, 1).setNumberFormat('@');
    sh.getRange(tableTop, 10, values.length, 2).setNumberFormat('@');
    body.setValues(values).setFontSize(10);
    sh.getRange(tableTop, 2, values.length, 1).setFontWeight('bold');
    sh.getRange(tableTop, 5, values.length, 5).setHorizontalAlignment('right');
    sh.getRange(tableTop, 7, values.length, 1).setNumberFormat('0.00').setFontWeight('bold');
    sh.getRange(tableTop, 9, values.length, 1).setNumberFormat('0.00');
    for (let i = 0; i < values.length; i++) {
      sh.getRange(tableTop + i, 2, 1, head.length).setBackground(i % 2 ? BRAND.grey : '#FFFFFF');
      const st = sh.getRange(tableTop + i, 12);
      if (values[i][10] === 'On shift') st.setFontColor(BRAND.green).setFontWeight('bold');
      else st.setFontColor(BRAND.muted);
      sh.setRowHeight(tableTop + i, 26);
    }
    row = tableTop + values.length;
    sh.getRange(row, 2, 1, head.length).setValues([['Total', '', '', d.totalShifts, '', Math.round(d.totalHours * 100) / 100, hm_(d.totalHours), '', '', '', '']])
      .setFontWeight('bold').setBackground(BRAND.amberBg)
      .setBorder(true, false, false, false, false, false, BRAND.ink, SpreadsheetApp.BorderStyle.SOLID_MEDIUM);
    sh.getRange(row, 5, 1, 5).setHorizontalAlignment('right');
    sh.getRange(row, 7).setNumberFormat('0.00');
    sh.setRowHeight(row, 28);
  } else {
    sh.getRange(tableTop, 2).setValue('No employees yet. Add them in the Crew Clock Manager screen.').setFontColor(BRAND.muted);
    row = tableTop;
  }

  // Daily hours grid
  row += 3;
  if (d.days.length <= 31 && d.list.length) {
    section(row, 'Daily hours', 'Hours per day, by the day each shift started.');
    row++;
    const dh = ['Employee'].concat(d.days.map(function (k) { return Utilities.formatDate(keyToDate_(k), TZ, 'EEE d'); })).concat(['Total']);
    sh.getRange(row, 2, 1, dh.length).setValues([dh]).setBackground(BRAND.ink).setFontColor('#FFFFFF').setFontWeight('bold').setFontSize(10);
    sh.getRange(row, 3, 1, dh.length - 1).setHorizontalAlignment('center');
    const gv = d.list.map(function (r) {
      return [r.name].concat(d.days.map(function (k) { return r.daily[k] ? Math.round(r.daily[k] * 100) / 100 : ''; }))
        .concat([Math.round(r.hours * 100) / 100]);
    });
    const totals = ['Total'].concat(d.days.map(function (k) {
      return Math.round(d.list.reduce(function (t, r) { return t + (r.daily[k] || 0); }, 0) * 100) / 100 || '';
    })).concat([Math.round(d.totalHours * 100) / 100]);
    gv.push(totals);
    const grid = sh.getRange(row + 1, 2, gv.length, dh.length);
    grid.setValues(gv).setFontSize(10);
    sh.getRange(row + 1, 3, gv.length, dh.length - 1).setNumberFormat('0.00').setHorizontalAlignment('center');
    // Shade busier days more strongly
    const rule = SpreadsheetApp.newConditionalFormatRule()
      .setGradientMinpointWithValue('#FFFFFF', SpreadsheetApp.InterpolationType.NUMBER, '0')
      .setGradientMaxpointWithValue('#F4B8B2', SpreadsheetApp.InterpolationType.NUMBER, '12')
      .setRanges([sh.getRange(row + 1, 3, gv.length - 1, d.days.length)]).build();
    sh.setConditionalFormatRules([rule]);
    sh.getRange(row + gv.length, 2, 1, dh.length).setFontWeight('bold').setBackground(BRAND.amberBg)
      .setBorder(true, false, false, false, false, false, BRAND.ink, SpreadsheetApp.BorderStyle.SOLID_MEDIUM);
    sh.getRange(row + 1, 2 + dh.length - 1, gv.length, 1).setFontWeight('bold');
    row += gv.length + 3;
  }

  // Needs attention
  section(row, 'Needs attention', d.attention.length ? 'Check these with the employee and fix the times in the Punches tab if needed.' : '');
  row++;
  if (d.attention.length) {
    sh.getRange(row, 2, 1, 3).setValues([['Employee', 'Started', 'What to check']]).setBackground(BRAND.ink).setFontColor('#FFFFFF').setFontWeight('bold').setFontSize(10);
    const av = d.attention.map(function (a) { return [a.name, a.when, a.issue]; });
    sh.getRange(row + 1, 3, av.length, 1).setNumberFormat('@');
    sh.getRange(row + 1, 2, av.length, 3).setValues(av).setFontSize(10).setBackground(BRAND.errBg);
    row += av.length + 1;
  } else {
    sh.getRange(row, 2).setValue('Nothing to check. Every shift in this period looks normal.').setFontColor(BRAND.green);
    row++;
  }

  // Chart of hours per employee, below everything else
  row += 2;
  const withHours = d.list.filter(function (r) { return r.hours > 0; }).length;
  if (withHours) {
    const chart = sh.newChart()
      .setChartType(Charts.ChartType.BAR)
      .addRange(sh.getRange(tableTop, 2, withHours, 1))
      .addRange(sh.getRange(tableTop, 7, withHours, 1))
      .setPosition(row, 2, 0, 0)
      .setOption('title', 'Total hours by employee')
      .setOption('titleTextStyle', { color: BRAND.ink, fontSize: 12, bold: true })
      .setOption('colors', [BRAND.red])
      .setOption('legend', { position: 'none' })
      .setOption('hAxis', { minValue: 0, gridlines: { color: '#EEEEEE' } })
      .setOption('width', 620)
      .setOption('height', Math.max(180, 40 + withHours * 32))
      .build();
    sh.insertChart(chart);
  }
  ss.setActiveSheet(sh);
}

/** Gives Punches, Workers and Weekly hours a consistent, readable style. */
function formatTabs() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  ensureSheets_(ss);
  const head = function (sh, n) {
    sh.getRange(1, 1, 1, n).setBackground(BRAND.ink).setFontColor('#FFFFFF').setFontWeight('bold');
    sh.setFrozenRows(1);
    sh.setRowHeight(1, 28);
    if (!sh.getBandings().length && sh.getLastRow() > 1) {
      sh.getRange(1, 1, Math.max(2, sh.getLastRow()), n).applyRowBanding(SpreadsheetApp.BandingTheme.LIGHT_GREY, true, false);
    }
  };
  const p = ss.getSheetByName('Punches');
  head(p, PUNCH_HEADERS.length);
  if (p.getLastRow() > 1) {
    // Old rows stored the date as text: turn them into real dates.
    const n = p.getLastRow() - 1;
    const rng = p.getRange(2, 1, n, 3);
    const v = rng.getValues();
    let changed = false;
    v.forEach(function (r) {
      [0, 2].forEach(function (i) {
        if (typeof r[i] === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(r[i])) { r[i] = keyToDate_(r[i]); changed = true; }
      });
    });
    if (changed) rng.setValues(v);
  }
  p.getRange('A:A').setNumberFormat('ddd d mmm yyyy');
  p.getRange('C:C').setNumberFormat('d mmm yyyy');
  p.getRange('G:G').setNumberFormat('0.00');
  [130, 90, 110, 90, 170, 70, 95, 100, 200].forEach(function (w, i) { p.setColumnWidth(i + 1, w); });
  p.getRange(1, 1, 1, PUNCH_HEADERS.length).setValues([PUNCH_HEADERS]);

  const w = ss.getSheetByName('Workers');
  head(w, WORKER_HEADERS.length);
  w.getRange('H:H').setNumberFormat('d mmm yyyy, h:mm am/pm');
  w.getRange('G:G').setNumberFormat('d mmm yyyy, h:mm am/pm');
  [90, 170, 120, 100, 110, 100, 160, 160].forEach(function (x, i) { w.setColumnWidth(i + 1, x); });
  w.hideColumns(W_PHONE_ID);
  w.hideColumns(W_LAST_AT);

  const wk = ss.getSheetByName('Weekly hours');
  if (wk) {
    wk.getRange(1, 1, 1, 5).setBackground(BRAND.ink).setFontColor('#FFFFFF').setFontWeight('bold');
    wk.getRange('A:A').setNumberFormat('d mmm yyyy');
    wk.getRange('E:E').setNumberFormat('0.00');
    [120, 100, 170, 70, 90].forEach(function (x, i) { wk.setColumnWidth(i + 1, x); });
  }
  // Tab order and colours: Summary first.
  const order = ['Summary', 'Weekly hours', 'Punches', 'Workers'];
  order.forEach(function (name, i) {
    const s = ss.getSheetByName(name);
    if (s) { ss.setActiveSheet(s); ss.moveActiveSheet(i + 1); }
  });
  const sumSheet = ss.getSheetByName('Summary');
  if (sumSheet) sumSheet.setTabColor(BRAND.red);
}
