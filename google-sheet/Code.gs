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
 *      (Setup also adds a small timer that keeps the script awake so scans are fast.)
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
  punches.appendRow([date, time, week, text_(id), text_(name), punch, hours, '', d.toISOString(), 'P-' + id + '-' + now]);
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
