import Foundation

/// 與 venera 漫畫源腳本相容的 JavaScript 執行環境（依公開 API 文件自行實作）。
/// 原生功能經由全域物件 `__native` 提供（見 VeneraBridge）。
enum VeneraPrelude {
    static let source = #"""
var __global = this;

// ---------- 二進位工具 ----------
var __B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var __B64_LOOKUP = (function () {
  var t = new Uint8Array(256);
  for (var i = 0; i < 256; i++) t[i] = 255;
  for (var j = 0; j < 64; j++) t[__B64.charCodeAt(j)] = j;
  t[45] = 62; t[95] = 63;
  return t;
})();

function __b64ToBuf(b64) {
  b64 = String(b64).replace(/[\s=]+/g, '');
  var n = b64.length;
  var outLen = Math.floor(n * 3 / 4);
  var out = new Uint8Array(outLen);
  var p = 0;
  for (var i = 0; i < n; i += 4) {
    var a = __B64_LOOKUP[b64.charCodeAt(i)];
    var b = __B64_LOOKUP[b64.charCodeAt(i + 1)];
    var c = i + 2 < n ? __B64_LOOKUP[b64.charCodeAt(i + 2)] : 0;
    var d = i + 3 < n ? __B64_LOOKUP[b64.charCodeAt(i + 3)] : 0;
    var v = (a << 18) | (b << 12) | (c << 6) | d;
    if (p < outLen) out[p++] = (v >> 16) & 255;
    if (p < outLen) out[p++] = (v >> 8) & 255;
    if (p < outLen) out[p++] = v & 255;
  }
  return out.buffer;
}

function __toU8(v) {
  if (v instanceof Uint8Array) return v;
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  if (Array.isArray(v)) return Uint8Array.from(v);
  if (typeof v === 'string') return new Uint8Array(__b64ToBuf(__native.utf8Encode(v)));
  throw 'Unsupported binary value';
}

function __bufToB64(buf) {
  var u8 = __toU8(buf);
  var n = u8.length;
  var parts = [];
  var chunk = '';
  for (var i = 0; i < n; i += 3) {
    var a = u8[i], b = i + 1 < n ? u8[i + 1] : 0, c = i + 2 < n ? u8[i + 2] : 0;
    var v = (a << 16) | (b << 8) | c;
    chunk += __B64[(v >> 18) & 63] + __B64[(v >> 12) & 63] +
      (i + 1 < n ? __B64[(v >> 6) & 63] : '=') + (i + 2 < n ? __B64[v & 63] : '=');
    if (chunk.length > 8192) { parts.push(chunk); chunk = ''; }
  }
  parts.push(chunk);
  return parts.join('');
}

// ---------- Convert ----------
var Convert = {
  encodeUtf8: function (s) { return __b64ToBuf(__native.utf8Encode(String(s))); },
  decodeUtf8: function (v) { return __native.utf8Decode(__bufToB64(v)); },
  encodeGbk: function (s) { return __b64ToBuf(__native.gbkEncode(String(s))); },
  decodeGbk: function (v) { return __native.gbkDecode(__bufToB64(v)); },
  encodeBase64: function (v) { return __bufToB64(v); },
  decodeBase64: function (s) { return __b64ToBuf(s); },
  md5: function (v) { return __b64ToBuf(__native.hash('md5', __bufToB64(v))); },
  sha1: function (v) { return __b64ToBuf(__native.hash('sha1', __bufToB64(v))); },
  sha256: function (v) { return __b64ToBuf(__native.hash('sha256', __bufToB64(v))); },
  sha512: function (v) { return __b64ToBuf(__native.hash('sha512', __bufToB64(v))); },
  hmac: function (key, value, hash) {
    return __b64ToBuf(__native.hmac(hash, __bufToB64(key), __bufToB64(value), false));
  },
  hmacString: function (key, value, hash) {
    return __native.hmac(hash, __bufToB64(key), __bufToB64(value), true);
  },
  hexEncode: function (v) {
    var u8 = __toU8(v), s = '';
    for (var i = 0; i < u8.length; i++) s += (u8[i] < 16 ? '0' : '') + u8[i].toString(16);
    return s;
  },
  decryptAesEcb: function (value, key) { return __aes('ecb', false, value, key, null, 16); },
  encryptAesEcb: function (value, key) { return __aes('ecb', true, value, key, null, 16); },
  decryptAesCbc: function (value, key, iv) { return __aes('cbc', false, value, key, iv, 16); },
  encryptAesCbc: function (value, key, iv) { return __aes('cbc', true, value, key, iv, 16); },
  decryptAesCfb: function (value, key, iv, blockSize) { return __aes('cfb', false, value, key, iv, blockSize || 16); },
  encryptAesCfb: function (value, key, iv, blockSize) { return __aes('cfb', true, value, key, iv, blockSize || 16); },
  decryptAesOfb: function (value, key, iv, blockSize) { return __aes('ofb', false, value, key, iv, blockSize || 16); },
  encryptAesOfb: function (value, key, iv, blockSize) { return __aes('ofb', true, value, key, iv, blockSize || 16); },
  decryptRsa: function (value, key) {
    var r = __native.rsaDecrypt(__bufToB64(value), String(key));
    if (r == null) throw 'RSA decrypt failed';
    return __b64ToBuf(r);
  }
};
function __aes(mode, encrypt, value, key, iv, blockSize) {
  var r = __native.aes(mode, encrypt, __bufToB64(value), __bufToB64(key), iv == null ? '' : __bufToB64(iv), blockSize);
  if (r == null) throw 'AES operation failed';
  return __b64ToBuf(r);
}

// ---------- 雜項 ----------
function createUuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
    var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}
function randomInt(min, max) { return Math.floor(Math.random() * (max - min)) + min; }
function randomDouble(min, max) { return Math.random() * (max - min) + min; }

var __timerId = 0;
var __timers = {};
function setTimeout(cb, delay) {
  var args = Array.prototype.slice.call(arguments, 2);
  var id = ++__timerId;
  __timers[id] = true;
  __native.delay(delay || 0, function () {
    if (__timers[id]) { delete __timers[id]; cb.apply(null, args); }
  });
  return id;
}
function clearTimeout(id) { delete __timers[id]; }
function setInterval(cb, delay) {
  var id = ++__timerId;
  __timers[id] = true;
  var tick = function () {
    if (!__timers[id]) return;
    __native.delay(delay || 0, function () {
      if (!__timers[id]) return;
      cb();
      tick();
    });
  };
  tick();
  return id;
}
function clearInterval(id) { delete __timers[id]; }

function log(level, title, content) { __native.log(String(level), String(title), String(content)); }
function __fmt(a) {
  if (typeof a === 'string') return a;
  try { return JSON.stringify(a); } catch (e) { return String(a); }
}
var console = {
  log: function () { log('info', 'JS Console', Array.prototype.map.call(arguments, __fmt).join(' ')); },
  info: function () { log('info', 'JS Console', Array.prototype.map.call(arguments, __fmt).join(' ')); },
  warn: function () { log('warning', 'JS Console', Array.prototype.map.call(arguments, __fmt).join(' ')); },
  error: function () { log('error', 'JS Console', Array.prototype.map.call(arguments, __fmt).join(' ')); },
  debug: function () {}
};

function sendMessage() { throw 'sendMessage is not supported in this runtime'; }
var appVersion = '1.5.0';
var APP = {
  get version() { return appVersion; },
  get locale() { return 'zh_TW'; },
  get platform() { return 'ios'; }
};
function setClipboard(text) { __native.setClipboard(String(text)); }
function getClipboard() { return __native.getClipboard(); }
function compute(func) {
  var args = Array.prototype.slice.call(arguments, 1);
  return new Promise(function (resolve, reject) {
    try {
      var f = typeof func === 'string' ? (0, eval)(func) : func;
      resolve(f.apply(null, args));
    } catch (e) { reject(e); }
  });
}
function btoa(str) {
  str = String(str);
  var u8 = new Uint8Array(str.length);
  for (var i = 0; i < str.length; i++) u8[i] = str.charCodeAt(i) & 255;
  return __bufToB64(u8);
}
function atob(b64) {
  var u8 = new Uint8Array(__b64ToBuf(b64));
  var out = '';
  for (var i = 0; i < u8.length; i++) out += String.fromCharCode(u8[i]);
  return out;
}

// ---------- Network ----------
function Cookie(o) { this.name = o.name; this.value = o.value; this.domain = o.domain; }

function __encodeForm(obj) {
  return Object.keys(obj).map(function (k) {
    return encodeURIComponent(k) + '=' + encodeURIComponent(obj[k]);
  }).join('&');
}

function __http(method, url, headers, data, bytes) {
  return new Promise(function (resolve, reject) {
    headers = Object.assign({}, headers || {});
    var body = null;
    if (data !== undefined && data !== null) {
      if (typeof data === 'string') {
        body = __native.utf8Encode(data);
      } else if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) {
        body = __bufToB64(data);
      } else {
        var ctKey = Object.keys(headers).filter(function (k) { return k.toLowerCase() === 'content-type'; })[0];
        if (ctKey && /x-www-form-urlencoded/i.test(headers[ctKey])) {
          body = __native.utf8Encode(__encodeForm(data));
        } else {
          body = __native.utf8Encode(JSON.stringify(data));
          if (!ctKey) headers['Content-Type'] = 'application/json';
        }
      }
    }
    __native.http(String(method).toUpperCase(), String(url), JSON.stringify(headers), body, !!bytes,
      function (json) {
        try {
          var r = JSON.parse(json);
          resolve({
            status: r.status,
            headers: r.headers,
            body: bytes ? __b64ToBuf(r.body) : r.body
          });
        } catch (e) { reject(String(e)); }
      },
      function (message) { reject(String(message)); });
  });
}

var Network = {
  fetchBytes: function (method, url, headers, data) { return __http(method, url, headers, data, true); },
  sendRequest: function (method, url, headers, data) { return __http(method, url, headers, data, false); },
  get: function (url, headers) { return __http('GET', url, headers, null, false); },
  post: function (url, headers, data) { return __http('POST', url, headers, data, false); },
  put: function (url, headers, data) { return __http('PUT', url, headers, data, false); },
  patch: function (url, headers, data) { return __http('PATCH', url, headers, data, false); },
  delete: function (url, headers) { return __http('DELETE', url, headers, null, false); },
  setCookies: function (url, cookies) { __native.cookieSet(String(url), JSON.stringify(cookies || [])); },
  getCookies: function (url) { return JSON.parse(__native.cookieGet(String(url))); },
  deleteCookies: function (url) { __native.cookieDelete(String(url)); }
};

function fetch(url, options) {
  var method = 'GET', headers = {}, data = null;
  if (options) {
    method = options.method || method;
    headers = options.headers || headers;
    data = options.body || data;
  }
  return Network.fetchBytes(method, url, headers, data).then(function (result) {
    return {
      ok: result.status >= 200 && result.status < 300,
      status: result.status,
      statusText: '',
      headers: result.headers,
      arrayBuffer: function () { return Promise.resolve(result.body); },
      text: function () { return Promise.resolve(Convert.decodeUtf8(result.body)); },
      json: function () { return Promise.resolve(JSON.parse(Convert.decodeUtf8(result.body))); }
    };
  });
}

// ---------- Html ----------
function __html(fn, doc, node, arg) {
  var r = __native.html(fn, doc, node, arg === undefined || arg === null ? '' : String(arg));
  return r == null ? null : JSON.parse(r);
}

class HtmlDocument {
  constructor(html) {
    this.key = HtmlDocument._next++;
    __native.html('parse', this.key, -1, String(html));
  }
  querySelector(query) {
    var k = __html('querySelector', this.key, -1, query);
    return k == null ? null : new HtmlElement(k, this.key);
  }
  querySelectorAll(query) {
    var ks = __html('querySelectorAll', this.key, -1, query) || [];
    var doc = this.key;
    return ks.map(function (k) { return new HtmlElement(k, doc); });
  }
  getElementById(id) {
    var k = __html('getElementById', this.key, -1, id);
    return k == null ? null : new HtmlElement(k, this.key);
  }
  dispose() { __native.html('dispose', this.key, -1, ''); }
}
HtmlDocument._next = 1;

class HtmlElement {
  constructor(key, doc) { this.key = key; this.doc = doc; }
  get text() { return __html('text', this.doc, this.key); }
  get attributes() { return __html('attributes', this.doc, this.key) || {}; }
  get children() {
    var doc = this.doc;
    return (__html('children', doc, this.key) || []).map(function (k) { return new HtmlElement(k, doc); });
  }
  get nodes() {
    var doc = this.doc;
    return (__html('nodes', doc, this.key) || []).map(function (k) { return new HtmlNode(k, doc); });
  }
  get parent() {
    var k = __html('parent', this.doc, this.key);
    return k == null ? null : new HtmlElement(k, this.doc);
  }
  get innerHtml() { return __html('innerHtml', this.doc, this.key); }
  get classNames() { return __html('classNames', this.doc, this.key) || []; }
  get id() { return __html('id', this.doc, this.key); }
  get localName() { return __html('localName', this.doc, this.key); }
  get previousSibling() {
    var k = __html('previousSibling', this.doc, this.key);
    return k == null ? null : new HtmlElement(k, this.doc);
  }
  get nextSibling() {
    var k = __html('nextSibling', this.doc, this.key);
    return k == null ? null : new HtmlElement(k, this.doc);
  }
  querySelector(query) {
    var k = __html('querySelector', this.doc, this.key, query);
    return k == null ? null : new HtmlElement(k, this.doc);
  }
  querySelectorAll(query) {
    var doc = this.doc;
    return (__html('querySelectorAll', doc, this.key, query) || []).map(function (k) { return new HtmlElement(k, doc); });
  }
  getElementById(id) {
    var k = __html('getElementById', this.doc, this.key, id);
    return k == null ? null : new HtmlElement(k, this.doc);
  }
}

class HtmlNode {
  constructor(key, doc) { this.key = key; this.doc = doc; }
  get type() { return __html('nodeType', this.doc, this.key); }
  get text() { return __html('nodeText', this.doc, this.key); }
  toElement() {
    var k = __html('nodeToElement', this.doc, this.key);
    return k == null ? null : new HtmlElement(k, this.doc);
  }
}

// ---------- UI ----------
var __loadingId = 0;
var UI = {
  showMessage: function (message) { __native.uiMessage(String(message)); },
  showDialog: function (title, content, actions) {
    actions = actions || [];
    var handlers = actions.map(function (a) { return a.callback; });
    __native.uiDialog(String(title), String(content),
      JSON.stringify(actions.map(function (a) { return { text: a.text, style: a.style || 'text' }; })),
      function (index) { var cb = handlers[index]; if (cb) cb(); });
  },
  launchUrl: function (url) { __native.uiLaunch(String(url)); },
  showLoading: function (onCancel) { return ++__loadingId; },
  cancelLoading: function (id) {},
  showInputDialog: function (title, validator) {
    return new Promise(function (resolve) {
      var ask = function () {
        __native.uiInput(String(title), function (value) {
          if (value === null || value === undefined) { resolve(null); return; }
          var err = validator ? validator(value) : null;
          if (err) { __native.uiMessage(String(err)); ask(); } else { resolve(value); }
        });
      };
      ask();
    });
  },
  showSelectDialog: function (title, options, initialIndex) {
    return new Promise(function (resolve) {
      __native.uiSelect(String(title), JSON.stringify(options || []), function (index) {
        resolve(index < 0 ? null : index);
      });
    });
  }
};

// ---------- 資料型別 ----------
function Comic(o) { Object.assign(this, o); if (this.subtitle === undefined) this.subtitle = o.subTitle; }
function ComicDetails(o) { Object.assign(this, o); if (this.subtitle === undefined) this.subtitle = o.subTitle; }
function Comment(o) { Object.assign(this, o); }
function ImageLoadingConfig(o) { Object.assign(this, o); }

class ComicSource {
  constructor() {
    this.name = ''; this.key = ''; this.version = ''; this.minAppVersion = ''; this.url = '';
  }
  loadData(dataKey) {
    var r = __native.loadData(this.key, String(dataKey));
    return r == null ? undefined : JSON.parse(r);
  }
  saveData(dataKey, data) { __native.saveData(this.key, String(dataKey), JSON.stringify(data === undefined ? null : data)); }
  deleteData(dataKey) { __native.deleteData(this.key, String(dataKey)); }
  loadSetting(key) {
    var r = __native.loadSetting(this.key, String(key));
    if (r != null) return JSON.parse(r);
    // 預設值用載入當下的快照：有的腳本會在 init 裡改寫 this.settings.xxx（例如把設定物件換成字串）
    var d = this.__defaults;
    if (d && Object.prototype.hasOwnProperty.call(d, key) && d[key] !== undefined) return d[key];
    // 沒有預設值的設定回傳 null（venera 的行為），腳本自己會判斷
    return null;
  }
  get isLogged() { return __native.isLogged(this.key); }
  translate(key) {
    var t = this.translation && this.translation['zh_TW'];
    if (t && t[key]) return t[key];
    t = this.translation && this.translation['zh_CN'];
    return (t && t[key]) || key;
  }
  init() {}
}
ComicSource.sources = {};

// ---------- 圖片處理（modifyImage 專用） ----------
class Image {
  constructor(key) { this.key = key; }
  copyRange(x, y, width, height) {
    var k = __native.image('copyRange', JSON.stringify([this.key, x, y, width, height]));
    return k == null ? null : new Image(k);
  }
  copyAndRotate90() {
    var k = __native.image('copyAndRotate90', JSON.stringify([this.key]));
    return k == null ? null : new Image(k);
  }
  fillImageAt(x, y, image) { __native.image('fillImageAt', JSON.stringify([this.key, x, y, image.key])); }
  fillImageRangeAt(x, y, image, srcX, srcY, width, height) {
    __native.image('fillImageRangeAt', JSON.stringify([this.key, x, y, image.key, srcX, srcY, width, height]));
  }
  get width() { return __native.image('getWidth', JSON.stringify([this.key])); }
  get height() { return __native.image('getHeight', JSON.stringify([this.key])); }
  static empty(width, height) { return new Image(__native.image('emptyImage', JSON.stringify([width, height]))); }
}

// ======================================================================
// 以下為 GodBook 原生端呼叫的輔助函式
// ======================================================================
function __jsonReplacer(k, v) {
  if (v instanceof Map) { var o = {}; v.forEach(function (val, key) { o[key] = val; }); return o; }
  if (v instanceof Set) return Array.from(v);
  if (typeof v === 'function') return undefined;
  if (typeof v === 'bigint') return String(v);
  if (v instanceof ArrayBuffer) return undefined;
  return v;
}
function __json(v) { return v === undefined ? 'null' : JSON.stringify(v, __jsonReplacer); }

function __run(thunk, ok, err) {
  try {
    Promise.resolve(thunk()).then(
      function (v) { try { ok(__json(v)); } catch (e) { err(String(e)); } },
      function (e) { err(__errText(e)); });
  } catch (e) { err(__errText(e)); }
}
function __errText(e) {
  if (e === null || e === undefined) return 'Unknown error';
  if (typeof e === 'string') return e;
  if (e.message) return String(e.message);
  try { return JSON.stringify(e); } catch (x) { return String(e); }
}

function __loadSource(js) {
  js = String(js).replace(/\r\n/g, '\n');
  var m = js.match(/^\s*class\s+([A-Za-z_$][\w$]*)\s+extends\s+ComicSource/m);
  if (!m) throw 'Invalid Content';
  var inst = (new Function(js + '\n;return new ' + m[1] + '();'))();
  if (!inst.name) throw 'name is required';
  if (!inst.key) throw 'key is required';
  if (!/^[a-zA-Z0-9_]+$/.test(inst.key)) throw 'key ' + inst.key + ' is invalid';
  __native.bindSource(inst.key);
  var defaults = {};
  if (inst.settings && typeof inst.settings === 'object') {
    Object.keys(inst.settings).forEach(function (k) {
      var v = inst.settings[k];
      if (v && typeof v === 'object' && v.default !== undefined) defaults[k] = v.default;
    });
  }
  Object.defineProperty(inst, '__defaults', { value: defaults, enumerable: false });
  ComicSource.sources[inst.key] = inst;
  if (typeof inst.init === 'function') {
    try { var r = inst.init(); if (r && r.catch) r.catch(function (e) { console.error('init: ' + __errText(e)); }); }
    catch (e) { console.error('init: ' + __errText(e)); }
  }
  return inst.key;
}

function __splitOpt(x) {
  x = String(x);
  var i = x.indexOf('-');
  return i < 0 ? [x, x] : [x.slice(0, i), x.slice(i + 1)];
}
function __optList(list) {
  return (list || []).map(function (o) {
    return {
      type: o.type || 'select',
      label: o.label || '',
      options: (o.options || []).map(__splitOpt),
      def: (o.default === undefined || o.default === null) ? null : (typeof o.default === 'string' ? o.default : JSON.stringify(o.default))
    };
  });
}
function __parseTarget(t) {
  if (t === null || t === undefined) return null;
  if (typeof t === 'string') {
    var i = t.indexOf(':');
    var page = i < 0 ? t : t.slice(0, i), rest = i < 0 ? '' : t.slice(i + 1);
    if (page === 'search') return { kind: 'search', text: rest };
    if (page === 'category') {
      var at = rest.indexOf('@');
      return at < 0 ? { kind: 'category', category: rest, param: null }
                    : { kind: 'category', category: rest.slice(0, at), param: rest.slice(at + 1) };
    }
    return null;
  }
  if (t.page) {
    var a = t.attributes || {};
    if (t.page === 'search') return { kind: 'search', text: a.text || a.keyword || '' };
    if (t.page === 'category') return { kind: 'category', category: a.category, param: a.param == null ? null : a.param };
    return null;
  }
  if (t.action) {
    if (t.action === 'search') return { kind: 'search', text: t.keyword || '' };
    if (t.action === 'category') return { kind: 'category', category: t.keyword, param: t.param == null ? null : t.param };
  }
  return null;
}

function __describe(key) {
  var s = ComicSource.sources[key];
  var info = {
    key: s.key, name: s.name, version: s.version || '1.0.0', url: s.url || '',
    explore: (s.explore || []).map(function (e) {
      return { title: e.title, type: e.type, hasLoad: typeof e.load === 'function' };
    }),
    category: null, categoryOptions: [], ranking: null,
    search: null, favorites: null, account: null, settings: [], idMatch: null,
    hasThumbnailLoader: !!(s.comic && s.comic.onThumbnailLoad),
    hasClickTag: !!(s.comic && s.comic.onClickTag)
  };
  if (s.category && s.category.title) {
    info.category = {
      title: s.category.title,
      parts: (s.category.parts || []).map(function (p) {
        var items = [];
        var cats = p.categories;
        if (Array.isArray(cats)) {
          if (cats.length && typeof cats[0] === 'object') {
            cats.forEach(function (c) {
              var t = __parseTarget(c.target);
              if (t) items.push({ label: c.label, kind: t.kind, text: t.text || null, category: t.category || null, param: t.param == null ? null : t.param });
            });
          } else {
            cats.forEach(function (name, i) {
              if (p.itemType === 'search') items.push({ label: name, kind: 'search', text: name, category: null, param: null });
              else if (p.itemType === 'search_with_namespace') items.push({ label: name, kind: 'search', text: p.name + ':' + name, category: null, param: null });
              else items.push({ label: name, kind: 'category', text: null, category: name,
                param: p.groupParam != null ? p.groupParam : (p.categoryParams ? (p.categoryParams[i] == null ? null : p.categoryParams[i]) : null) });
            });
          }
        }
        return { name: p.name || '', items: items };
      })
    };
  }
  if (s.categoryComics) {
    info.categoryOptions = __optList(s.categoryComics.optionList);
    if (s.categoryComics.ranking) {
      info.ranking = { options: (s.categoryComics.ranking.options || []).map(__splitOpt) };
    }
  }
  if (s.search) {
    info.search = { options: __optList(s.search.optionList), hasLoad: typeof s.search.load === 'function', enableTags: !!s.search.enableTagsSuggestions };
  }
  if (s.favorites) {
    var f = s.favorites;
    info.favorites = {
      multiFolder: !!f.multiFolder,
      canToggle: typeof f.addOrDelFavorite === 'function',
      hasFolders: typeof f.loadFolders === 'function',
      canAddFolder: typeof f.addFolder === 'function',
      canDeleteFolder: typeof f.deleteFolder === 'function'
    };
  }
  if (s.account) {
    var a = s.account;
    info.account = {
      hasLogin: typeof a.login === 'function',
      webviewUrl: a.loginWithWebview ? (a.loginWithWebview.url || null) : null,
      cookieFields: a.loginWithCookies ? (a.loginWithCookies.fields || null) : null,
      registerWebsite: a.registerWebsite || null
    };
  }
  if (s.settings) {
    info.settings = Object.keys(s.settings).map(function (name) {
      var d = s.settings[name];
      return {
        name: name, title: d.title || name, type: d.type || 'input',
        options: (d.options || []).map(function (o) { return { value: String(o.value), text: o.text || String(o.value) }; }),
        defJSON: d.default === undefined ? null : JSON.stringify(d.default),
        buttonText: d.buttonText || null, validator: d.validator || null
      };
    });
  }
  if (s.comic && s.comic.idMatch) info.idMatch = String(s.comic.idMatch);
  if (s.comic) {
    var c = s.comic;
    info.comic = {
      comments: typeof c.loadComments === 'function',
      sendComment: typeof c.sendComment === 'function',
      chapterComments: typeof c.loadChapterComments === 'function',
      sendChapterComment: typeof c.sendChapterComment === 'function',
      like: typeof c.likeComic === 'function',
      rating: typeof c.starRating === 'function',
      thumbnails: typeof c.loadThumbnails === 'function',
      likeComment: typeof c.likeComment === 'function',
      voteComment: typeof c.voteComment === 'function',
      hasLink: !!(c.link && typeof c.link.linkToId === 'function'),
      linkDomains: (c.link && c.link.domains) ? c.link.domains.map(String) : []
    };
  }
  return info;
}

function __tagSuggestion(key, ns, tag) {
  var s = ComicSource.sources[key];
  if (s.search && typeof s.search.onTagSuggestionSelected === 'function') return s.search.onTagSuggestionSelected(ns, tag);
  return ns + ':' + tag;
}

function __normComic(c) {
  return {
    id: String(c.id), title: String(c.title === undefined || c.title === null ? '' : c.title),
    subtitle: c.subtitle || c.subTitle || '', cover: c.cover || '',
    tags: c.tags || [], description: c.description || ''
  };
}
function __normComics(list) { return (list || []).map(__normComic); }
function __flattenParts(r) {
  var out = [];
  if (Array.isArray(r)) r.forEach(function (p) { if (p && p.comics) out = out.concat(p.comics); });
  else if (r) Object.keys(r).forEach(function (k) { if (Array.isArray(r[k])) out = out.concat(r[k]); });
  return out;
}

async function __explore(key, idx, page, next) {
  var e = ComicSource.sources[key].explore[idx];
  if (e.type === 'multiPageComicList') {
    if (typeof e.load === 'function') {
      var r = await e.load(page);
      return { comics: __normComics(r.comics), maxPage: r.maxPage == null ? null : r.maxPage, next: null };
    }
    var n = await e.loadNext(next);
    return { comics: __normComics(n.comics), maxPage: null, next: n.next == null ? null : n.next, usesNext: true };
  }
  if (e.type === 'mixed') {
    var m = await e.load(page - 1);
    var comics = [];
    (m.data || []).forEach(function (d) {
      if (Array.isArray(d)) comics = comics.concat(d);
      else if (d && d.comics) comics = comics.concat(d.comics);
    });
    return { comics: __normComics(comics), maxPage: m.maxPage == null ? null : m.maxPage, next: null };
  }
  var parts = await e.load(null);
  return { comics: __normComics(__flattenParts(parts)), maxPage: 1, next: null };
}

async function __search(key, keyword, options, page, next) {
  var s = ComicSource.sources[key].search;
  if (typeof s.load === 'function') {
    var r = await s.load(keyword, options, page);
    return { comics: __normComics(r.comics), maxPage: r.maxPage == null ? null : r.maxPage, next: null };
  }
  var n = await s.loadNext(keyword, options, next);
  return { comics: __normComics(n.comics), maxPage: null, next: n.next == null ? null : n.next, usesNext: true };
}

async function __category(key, category, param, options, page) {
  var r = await ComicSource.sources[key].categoryComics.load(category, param, options, page);
  return { comics: __normComics(r.comics), maxPage: r.maxPage == null ? null : r.maxPage, next: null };
}

async function __ranking(key, option, page, next) {
  var rk = ComicSource.sources[key].categoryComics.ranking;
  if (typeof rk.load === 'function') {
    var r = await rk.load(option, page);
    return { comics: __normComics(r.comics), maxPage: r.maxPage == null ? null : r.maxPage, next: null };
  }
  var n = await rk.loadWithNext(option, next);
  return { comics: __normComics(n.comics), maxPage: null, next: n.next == null ? null : n.next, usesNext: true };
}

function __entries(obj) {
  if (!obj) return [];
  if (obj instanceof Map) return Array.from(obj.entries());
  return Object.keys(obj).map(function (k) { return [k, obj[k]]; });
}

async function __loadInfo(key, id) {
  var s = ComicSource.sources[key];
  var r = await s.comic.loadInfo(id);
  var tags = [];
  __entries(r.tags).forEach(function (e) {
    var values = Array.isArray(e[1]) ? e[1] : [];
    values.forEach(function (t) {
      var target = null;
      if (s.comic.onClickTag) {
        try { target = __parseTarget(s.comic.onClickTag(e[0], t)); } catch (x) { target = null; }
      }
      tags.push({ ns: e[0], name: String(t), target: target });
    });
  });
  var chapters = [];
  __entries(r.chapters).forEach(function (e) {
    if (e[1] !== null && typeof e[1] === 'object') {
      __entries(e[1]).forEach(function (c) { chapters.push({ id: String(c[0]), title: String(c[1]), group: String(e[0]) }); });
    } else {
      chapters.push({ id: String(e[0]), title: String(e[1]), group: null });
    }
  });
  return {
    title: r.title || '', subtitle: r.subtitle || r.subTitle || '', cover: r.cover || '',
    description: r.description || '', tags: tags, chapters: chapters,
    recommend: __normComics(r.recommend),
    likesCount: r.likesCount == null ? null : r.likesCount,
    commentCount: r.commentCount == null ? null : r.commentCount,
    uploader: r.uploader || null, updateTime: r.updateTime || null, uploadTime: r.uploadTime || null,
    stars: r.stars == null ? null : r.stars, url: r.url || null, maxPage: r.maxPage == null ? null : r.maxPage,
    subId: r.subId == null ? null : String(r.subId),
    isLiked: r.isLiked == null ? null : !!r.isLiked,
    isFavorite: r.isFavorite == null ? null : !!r.isFavorite,
    thumbnails: Array.isArray(r.thumbnails) ? r.thumbnails.map(String) : null
  };
}

async function __loadEp(key, comicId, epId) {
  var r = await ComicSource.sources[key].comic.loadEp(comicId, epId);
  return { images: (r.images || []).map(String) };
}

async function __loadImage(key, imageKey, comicId, epId) {
  var s = ComicSource.sources[key];
  var cfg;
  if (comicId !== null && comicId !== undefined) {
    cfg = s.comic.onImageLoad ? await s.comic.onImageLoad(imageKey, comicId, epId) : {};
  } else {
    cfg = s.comic.onThumbnailLoad ? await s.comic.onThumbnailLoad(imageKey) : {};
  }
  cfg = cfg || {};
  var retries = 5;
  for (;;) {
    try {
      var headers = cfg.headers || { 'user-agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1' };
      var res = await Network.fetchBytes(cfg.method || 'GET', cfg.url || imageKey, headers, cfg.data);
      if (res.status >= 400) throw 'HTTP ' + res.status;
      var body = res.body;
      if (typeof cfg.onResponse === 'function') {
        body = await cfg.onResponse(body);
        if (!body) throw 'Invalid onResponse result';
      }
      return { data: __bufToB64(body), modify: typeof cfg.modifyImage === 'string' ? cfg.modifyImage : null };
    } catch (e) {
      if (retries-- <= 0 || typeof cfg.onLoadFailed !== 'function') throw e;
      var next = await cfg.onLoadFailed();
      if (!next) throw e;
      cfg = next;
    }
  }
}

async function __favoriteFolders(key) {
  var r = await ComicSource.sources[key].favorites.loadFolders(null);
  var folders = [];
  __entries(r.folders).forEach(function (e) { folders.push({ id: String(e[0]), name: String(e[1]) }); });
  return { folders: folders };
}
async function __favorites(key, page, folder, next) {
  var f = ComicSource.sources[key].favorites;
  if (typeof f.loadComics === 'function') {
    var r = await f.loadComics(page, folder);
    return { comics: __normComics(r.comics), maxPage: r.maxPage == null ? null : r.maxPage, next: null };
  }
  var n = await f.loadNext(next, folder);
  return { comics: __normComics(n.comics), maxPage: null, next: n.next == null ? null : n.next, usesNext: true };
}

async function __login(key, account, pwd) {
  await ComicSource.sources[key].account.login(account, pwd);
  return true;
}
async function __cookieLogin(key, values) {
  var r = await ComicSource.sources[key].account.loginWithCookies.validate(values);
  return !!r;
}
function __logout(key) {
  var a = ComicSource.sources[key].account;
  if (a && typeof a.logout === 'function') a.logout();
  return true;
}
function __webCheck(key, url, title) {
  return !!ComicSource.sources[key].account.loginWithWebview.checkStatus(url, title);
}
function __webSuccess(key) {
  var w = ComicSource.sources[key].account.loginWithWebview;
  if (w && typeof w.onLoginSuccess === 'function') w.onLoginSuccess();
  return true;
}
async function __settingCallback(key, name) {
  var d = ComicSource.sources[key].settings[name];
  if (d && typeof d.callback === 'function') await d.callback();
  return true;
}

function __timeText(t) {
  if (t === null || t === undefined) return null;
  if (typeof t === 'number') {
    var d = new Date(t < 10000000000 ? t * 1000 : t);
    var p = function (n) { return n < 10 ? '0' + n : '' + n; };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }
  return String(t);
}
function __normComment(c) {
  return {
    id: c.id == null ? '' : String(c.id), userName: c.userName || '', avatar: c.avatar || null,
    content: c.content || '', time: __timeText(c.time),
    replyCount: c.replyCount == null ? null : c.replyCount,
    isLiked: c.isLiked == null ? null : !!c.isLiked,
    score: c.score == null ? null : c.score,
    voteStatus: c.voteStatus == null ? null : c.voteStatus
  };
}
async function __comments(key, comicId, subId, epId, page, replyTo) {
  var c = ComicSource.sources[key].comic;
  var r = (epId !== null && epId !== undefined)
    ? await c.loadChapterComments(comicId, epId, page, replyTo)
    : await c.loadComments(comicId, subId, page, replyTo);
  return { comments: (r.comments || []).map(__normComment), maxPage: r.maxPage == null ? null : r.maxPage };
}
async function __sendComment(key, comicId, subId, epId, content, replyTo) {
  var c = ComicSource.sources[key].comic;
  if (epId !== null && epId !== undefined) await c.sendChapterComment(comicId, epId, content, replyTo);
  else await c.sendComment(comicId, subId, content, replyTo);
  return true;
}
async function __likeComment(key, comicId, subId, commentId, isLike) {
  await ComicSource.sources[key].comic.likeComment(comicId, subId, commentId, isLike);
  return true;
}
async function __voteComment(key, comicId, subId, commentId, isUp, isCancel) {
  var r = await ComicSource.sources[key].comic.voteComment(comicId, subId, commentId, isUp, isCancel);
  return typeof r === 'number' ? r : 0;
}
async function __likeComic(key, id, isLike) {
  await ComicSource.sources[key].comic.likeComic(id, isLike);
  return true;
}
async function __rate(key, id, rating) {
  await ComicSource.sources[key].comic.starRating(id, rating);
  return true;
}
async function __thumbnails(key, id, next) {
  var r = await ComicSource.sources[key].comic.loadThumbnails(id, next);
  return { thumbnails: (r.thumbnails || []).map(String), next: r.next == null ? null : String(r.next) };
}
async function __favFolders(key, comicId) {
  var f = ComicSource.sources[key].favorites;
  if (typeof f.loadFolders !== 'function') return { folders: [{ id: '0', name: '收藏' }], favorited: [] };
  var r = await f.loadFolders(comicId);
  var folders = [];
  __entries(r.folders).forEach(function (e) { folders.push({ id: String(e[0]), name: String(e[1]) }); });
  return { folders: folders, favorited: (r.favorited || []).map(String) };
}
async function __favToggle(key, comicId, folderId, adding, favoriteId) {
  await ComicSource.sources[key].favorites.addOrDelFavorite(comicId, folderId, adding, favoriteId);
  return true;
}
async function __favAddFolder(key, name) {
  await ComicSource.sources[key].favorites.addFolder(name);
  return true;
}
async function __favDelFolder(key, id) {
  await ComicSource.sources[key].favorites.deleteFolder(id);
  return true;
}
function __linkToId(key, text) {
  var s = ComicSource.sources[key];
  var c = s.comic;
  if (!c) return null;
  text = String(text).trim();
  if (c.link && typeof c.link.linkToId === 'function') {
    var host = '';
    var m = text.match(/^https?:\/\/([^\/?#]+)/i);
    if (m) host = m[1].toLowerCase();
    var domains = (c.link.domains || []).map(function (d) { return String(d).toLowerCase(); });
    if (host && domains.some(function (d) { return host === d || host.endsWith('.' + d); })) {
      var id = c.link.linkToId(text);
      if (id) return String(id);
    }
  }
  if (c.idMatch) {
    try {
      var r = new RegExp(c.idMatch).exec(text);
      if (r) return String(r[1] !== undefined ? r[1] : r[0]);
    } catch (e) {}
  }
  return null;
}
"""#
}