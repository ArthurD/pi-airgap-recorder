#!/usr/bin/env python3
"""umik-viewer - offline spectrogram browser for UMIK recordings.

    python3 tools/umik-viewer.py [data-dir] [--port 8377] [--no-browser]

Point it at any directory that contains session folders (a collected
"From SD"/"From USB" tree, a mounted stick, or the ingest archive); it finds
every  .../recordings/<session>/seg-*.wav  underneath. Entirely local:
binds 127.0.0.1 only, needs python3 + numpy, touches no network.

Why a server at all: segments are 172 MB of 24-bit PCM. Spectrograms are
computed here with numpy (cached under ~/.cache/umik-viewer), including
zoomed time-windows at full resolution, and audio is streamed as 16-bit WAV
with makeup gain applied BEFORE quantisation - a UMIK-1 in a quiet room
sits at -70 dBFS, and boosting after a 16-bit truncation would amplify
quantisation noise instead of signal. Durations are derived from actual
file sizes, never from the WAV header, so power-cut tail segments with
stale headers play fine untouched.

UI: pick session -> segment; wheel-zoom the spectrogram around the cursor;
drag the window (or its edge handles) on the full-clip overview strip;
click the spectrogram to move the playhead; arrows switch segments.
"""
import argparse, hashlib, json, os, re, struct, sys, threading, webbrowser, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

import numpy as np

# --------------------------------------------------------------------------
# WAV access (header parsed for format only; sizes come from the filesystem)
# --------------------------------------------------------------------------

class Wav:
    def __init__(self, path):
        self.path = path
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            head = f.read(8192)
        if head[0:4] != b"RIFF" or head[8:12] != b"WAVE":
            raise ValueError("not RIFF/WAVE")
        off, fmt, data_off = 12, None, None
        while off + 8 <= len(head):
            cid, clen = struct.unpack_from("<4sI", head, off)
            off += 8
            if cid == b"fmt ":
                _, ch, rate, _, _, bits = struct.unpack_from("<HHIIHH", head, off)
                fmt = (ch, rate, bits)
            elif cid == b"data":
                data_off = off
                break
            off += clen + (clen & 1)
        if fmt is None or data_off is None:
            raise ValueError("no fmt/data chunk in first 8KB")
        self.channels, self.rate, self.bits = fmt
        self.bps = self.bits // 8
        if self.bps not in (2, 3):
            raise ValueError(f"unsupported sample width {self.bits}")
        self.frame = self.channels * self.bps
        self.data_off = data_off
        self.frames = max(0, (size - data_off) // self.frame)  # true, not header
        self.duration = self.frames / self.rate

    def read_ch0(self, start_frame, n_frames):
        """First channel as float32 in [-1,1)."""
        n = max(0, min(n_frames, self.frames - start_frame))
        if n == 0:
            return np.zeros(0, np.float32)
        with open(self.path, "rb") as f:
            f.seek(self.data_off + start_frame * self.frame)
            raw = np.frombuffer(f.read(n * self.frame), np.uint8)
        n = len(raw) // self.frame
        raw = raw[: n * self.frame].reshape(n, self.frame)
        if self.bps == 3:
            v = (raw[:, 0].astype(np.int32) | (raw[:, 1].astype(np.int32) << 8)
                 | (raw[:, 2].astype(np.int32) << 16))
            v = np.where(v >= 1 << 23, v - (1 << 24), v)
            return (v / (1 << 23)).astype(np.float32)
        v = (raw[:, 0].astype(np.int32) | (raw[:, 1].astype(np.int32) << 8))
        v = np.where(v >= 1 << 15, v - (1 << 16), v)
        return (v / (1 << 15)).astype(np.float32)

# --------------------------------------------------------------------------
# Spectrogram -> PNG (PIL if present, else a minimal pure-zlib PNG writer)
# --------------------------------------------------------------------------

# magma-ish anchors, dark -> bright
_CMAP = np.array([
    (0, 0, 4), (18, 13, 49), (45, 17, 95), (79, 18, 123), (112, 31, 129),
    (145, 43, 129), (178, 53, 123), (211, 67, 109), (236, 88, 92),
    (249, 120, 80), (254, 158, 89), (254, 196, 116), (253, 231, 158),
    (252, 253, 191)], float)

def _colorize(z):  # z in [0,1] -> uint8 RGB
    pos = z * (len(_CMAP) - 1)
    i = np.clip(pos.astype(int), 0, len(_CMAP) - 2)
    t = (pos - i)[..., None]
    return (_CMAP[i] * (1 - t) + _CMAP[i + 1] * t).astype(np.uint8)

def _png_encode(rgb):
    try:
        from PIL import Image
        import io
        buf = io.BytesIO()
        Image.fromarray(rgb, "RGB").save(buf, "PNG")
        return buf.getvalue()
    except ImportError:
        pass
    h, w, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))

def spectrogram_png(wav, width=1600, height=512, f0=0, f1=None):
    """Render frames [f0, f1) - zooming in re-renders at full resolution."""
    f1 = wav.frames if f1 is None else max(0, min(int(f1), wav.frames))
    f0 = max(0, min(int(f0), f1))
    span_frames = max(1, f1 - f0)
    nfft = 2048
    while nfft > 256 and nfft * 2 > span_frames:   # deep zoom: shorter windows
        nfft //= 2
    hop = max(1, span_frames // width)
    cols = min(width, max(1, span_frames // hop))
    starts = (f0 + np.arange(cols) * hop).clip(f0, max(f0, f1 - nfft))
    lo, hi = int(starts[0]), int(starts[-1]) + nfft
    span = wav.read_ch0(lo, hi - lo)
    if len(span) < hi - lo:
        span = np.pad(span, (0, (hi - lo) - len(span)))
    idx = (starts - lo)[:, None] + np.arange(nfft)[None, :]
    seg = span[idx] * np.hanning(nfft).astype(np.float32)[None, :]
    mag = np.abs(np.fft.rfft(seg, axis=1))[:, 1:]          # drop DC
    db = 20 * np.log10(mag + 1e-9)
    # frequency bins -> <=height rows by max-pooling, low freq at the bottom
    nb = db.shape[1]
    factor = max(1, nb // height)
    nb2 = (nb // factor) * factor
    db = db[:, :nb2].reshape(cols, nb2 // factor, factor).max(axis=2)
    vmax = np.percentile(db, 99.9)
    vmin = max(np.percentile(db, 5.0), vmax - 100)
    if vmax - vmin < 40:
        vmin = vmax - 40
    z = np.clip((db - vmin) / (vmax - vmin), 0, 1)
    return _png_encode(_colorize(z.T[::-1]))               # upright

_CACHE_DIR = os.path.join(os.path.expanduser("~"), ".cache", "umik-viewer")

def _prune_cache(keep=600, drop=200):
    try:
        entries = sorted((e.stat().st_mtime, e.path)
                         for e in os.scandir(_CACHE_DIR)
                         if e.name.endswith(".png"))
        if len(entries) > keep:
            for _, p in entries[:drop]:
                os.unlink(p)
    except OSError:
        pass

def cached_spec(path, width, height, t0=0.0, t1=None):
    st = os.stat(path)
    tkey = f"{t0:.3f}-{'' if t1 is None else format(t1, '.3f')}"
    key = hashlib.sha1(f"{os.path.abspath(path)}|{st.st_mtime_ns}|{st.st_size}"
                       f"|{width}x{height}|{tkey}|v3".encode()).hexdigest()
    os.makedirs(_CACHE_DIR, exist_ok=True)
    cpath = os.path.join(_CACHE_DIR, key + ".png")
    if os.path.exists(cpath):
        with open(cpath, "rb") as f:
            return f.read()
    wav = Wav(path)
    f0 = int(t0 * wav.rate)
    f1 = None if t1 is None else int(t1 * wav.rate)
    png = spectrogram_png(wav, width, height, f0, f1)
    tmp = cpath + ".tmp"
    with open(tmp, "wb") as f:
        f.write(png)
    os.replace(tmp, cpath)
    _prune_cache()
    return png

# --------------------------------------------------------------------------
# Index
# --------------------------------------------------------------------------

SEG_RE = re.compile(r"^seg-.*\.wav$")

def build_index(root):
    collections = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        # Two layouts hold sessions: a medium's flat recordings/<session>,
        # and the archive's recordings/<unit>/<session> (unit layer added
        # with multi-unit support). The collection label is the medium's
        # containing directory for the former, the unit for the latter.
        parent_dir = os.path.dirname(dirpath)
        parent = os.path.basename(parent_dir)
        gparent = os.path.basename(os.path.dirname(parent_dir))
        if parent != "recordings" and gparent != "recordings":
            continue
        segs = sorted(f for f in filenames
                      if SEG_RE.match(f) and not f.endswith(".repaired.wav"))
        if not segs:
            continue
        sdir = dirpath
        if gparent == "recordings":
            coll = parent
        else:
            coll = os.path.relpath(os.path.dirname(parent_dir), root)
            coll = os.path.basename(os.path.abspath(root)) if coll == "." else coll
        meta = {}
        try:
            with open(os.path.join(sdir, "session.json")) as f:
                meta = json.load(f)
        except (OSError, ValueError):
            pass
        seglist = []
        for name in segs:
            p = os.path.join(sdir, name)
            try:
                size = os.path.getsize(p)
            except OSError:
                continue
            seglist.append({
                "name": name,
                "rel": os.path.relpath(p, root),
                "bytes": size,
                "dur": round(max(0, size - 44) / (48000 * 6), 1),  # display only
            })
        collections.setdefault(coll, []).append({
            "name": os.path.basename(sdir),
            "meta": meta,
            "segments": seglist,
        })
    for sessions in collections.values():
        sessions.sort(key=lambda s: s["name"])
    return [{"name": k, "sessions": v} for k, v in sorted(collections.items())]

# --------------------------------------------------------------------------
# Audio: stream first channel as mono 16-bit WAV, gain applied pre-quantise,
# with HTTP Range support so the <audio> element can seek.
# --------------------------------------------------------------------------

def audio16_total(wav):
    return 44 + wav.frames * 2

def audio16_header(wav):
    n = wav.frames * 2
    return struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + n, b"WAVE",
                       b"fmt ", 16, 1, 1, wav.rate, wav.rate * 2, 2, 16,
                       b"data", n)

def audio16_bytes(wav, start, end, gain):
    """Output bytes [start, end) of the virtual mono-16 WAV."""
    out = []
    if start < 44:
        out.append(audio16_header(wav)[start:min(end, 44)])
        start = 44
    if start >= end:
        return b"".join(out)
    s0 = (start - 44) // 2
    s1 = min(wav.frames, (end - 44 + 1) // 2)
    if s1 > s0:
        x = wav.read_ch0(s0, s1 - s0) * gain
        pcm = np.clip(x * 32767.0, -32768, 32767).astype("<i2").tobytes()
        a = start - (44 + s0 * 2)
        b = end - (44 + s0 * 2)
        out.append(pcm[a:b])
    return b"".join(out)

# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    root = "."
    index = []
    verbose = False
    # HTTP/1.1 (with accurate Content-Length, which we always send) is what
    # lets Chrome treat /audio16 as a seekable stream.
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if self.verbose:
            sys.stderr.write("%s  %s\n" % (self.log_date_time_string(),
                                           fmt % args))
            sys.stderr.flush()

    def _send(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def _resolve(self, rel):
        p = os.path.realpath(os.path.join(self.root, unquote(rel)))
        if p != os.path.realpath(self.root) and not p.startswith(
                os.path.realpath(self.root) + os.sep):
            raise PermissionError(rel)
        return p

    def do_GET(self):
        try:
            u = urlparse(self.path)
            q = parse_qs(u.query)
            if u.path == "/":
                self._send(200, "text/html; charset=utf-8", PAGE.encode())
            elif u.path == "/api/index":
                self._send(200, "application/json", json.dumps(
                    {"root": os.path.abspath(self.root),
                     "collections": self.index}).encode())
            elif u.path == "/api/spec":
                p = self._resolve(q["f"][0])
                w = min(4000, int(q.get("w", ["1600"])[0]))
                h = min(1024, int(q.get("h", ["512"])[0]))
                t0 = float(q.get("t0", ["0"])[0])
                t1v = q.get("t1", [""])[0]
                t1 = float(t1v) if t1v else None
                self._send(200, "image/png", cached_spec(p, w, h, t0, t1),
                           {"Cache-Control": "max-age=86400"})
            elif u.path == "/audio16":
                p = self._resolve(q["f"][0])
                wav = Wav(p)
                gain = 10 ** (float(q.get("boost", ["0"])[0]) / 20)
                total = audio16_total(wav)
                # Satisfy the WHOLE requested range and stream it in chunks;
                # Chrome aborts the connection once its buffer is full.
                a, b = 0, total
                rng = self.headers.get("Range")
                m = re.match(r"bytes=(\d*)-(\d*)", rng or "")
                if m and (m.group(1) or m.group(2)):
                    if m.group(1):
                        a = min(int(m.group(1)), total)
                        b = min(int(m.group(2)) + 1, total) if m.group(2) else total
                    else:                       # suffix form: last N bytes
                        a = max(0, total - int(m.group(2)))
                    code = 206
                else:
                    code = 200
                self.send_response(code)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Content-Length", str(max(0, b - a)))
                self.send_header("Accept-Ranges", "bytes")
                if code == 206:
                    self.send_header("Content-Range", f"bytes {a}-{b-1}/{total}")
                self.end_headers()
                try:
                    pos = a
                    while pos < b:
                        nxt = min(pos + (1 << 20), b)
                        self.wfile.write(audio16_bytes(wav, pos, nxt, gain))
                        pos = nxt
                except (BrokenPipeError, ConnectionResetError):
                    self.close_connection = True
            else:
                self._send(404, "text/plain", b"not found")
        except (KeyError, ValueError, OSError, PermissionError) as e:
            self._send(400, "text/plain", f"error: {e}".encode())

# --------------------------------------------------------------------------
# UI
# --------------------------------------------------------------------------

PAGE = r"""<!doctype html><html><head><meta charset="utf-8">
<title>umik viewer</title>
<style>
:root{--bg:#12121a;--panel:#1c1c28;--chip:#2a2a3c;--chipa:#4a6cf0;--fg:#e6e6f0;
  --dim:#9a9ab0;--accent:#7aa2ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:14px/1.45 -apple-system,Helvetica,Arial,sans-serif}
header{padding:10px 16px;background:var(--panel);display:flex;gap:14px;
  align-items:baseline}
header h1{font-size:15px;margin:0}
header .dim{color:var(--dim);font-size:12px}
#layout{display:flex;height:calc(100vh - 41px)}
#side{width:290px;min-width:290px;overflow-y:auto;background:var(--panel);
  padding:10px}
#main{flex:1;display:flex;flex-direction:column;overflow:hidden;padding:12px}
.coll{margin-bottom:14px}
.coll h2{font-size:12px;color:var(--dim);text-transform:uppercase;
  letter-spacing:.08em;margin:6px 0}
.sess{display:block;width:100%;text-align:left;margin:3px 0;padding:7px 9px;
  background:var(--chip);border:none;border-radius:7px;color:var(--fg);
  cursor:pointer;font:inherit}
.sess.active{background:var(--chipa)}
.sess .sub{color:var(--dim);font-size:11.5px}
.sess.active .sub{color:#dfe6ff}
#strip{display:flex;gap:5px;overflow-x:auto;padding:6px 0;min-height:44px}
.segchip{padding:5px 9px;background:var(--chip);border:none;border-radius:6px;
  color:var(--fg);cursor:pointer;font:12px monospace;white-space:nowrap}
.segchip.active{background:var(--chipa)}
#specwrap{position:relative;flex:1;min-height:0;background:#000;
  border-radius:8px;overflow:hidden;cursor:crosshair}
#spec{width:100%;height:100%;display:block;object-fit:fill;
  transform-origin:0 0;will-change:transform}
#playhead{position:absolute;top:0;bottom:0;width:1.5px;background:#fff;
  box-shadow:0 0 6px #fff;pointer-events:none;left:0}
#loading{position:absolute;inset:0;display:none;align-items:center;
  justify-content:center;color:var(--dim);background:#000a;font-size:13px}
#axis{display:flex;justify-content:space-between;color:var(--dim);
  font:11px monospace;padding:2px 2px}
#ovwrap{position:relative;height:84px;margin-top:2px;border-radius:6px;
  overflow:hidden;background:#000;cursor:crosshair;touch-action:none;
  user-select:none}
#ov{width:100%;height:100%;display:block;object-fit:fill;pointer-events:none}
#ovwin{position:absolute;top:0;bottom:0;border:1px solid #ffffff88;
  background:#ffffff14;cursor:grab}
.grip{position:absolute;top:0;bottom:0;width:9px}
#gripL{left:-1px;cursor:ew-resize;border-left:3px solid #ffffffaa}
#gripR{right:-1px;cursor:ew-resize;border-right:3px solid #ffffffaa}
#ovph{position:absolute;top:0;bottom:0;width:1px;background:#ff5d5d;
  pointer-events:none;left:0}
#bar{display:flex;gap:16px;align-items:center;padding:10px 2px 2px}
#bar audio{flex:1;min-width:200px;height:34px}
label{color:var(--dim);font-size:12px}
select,input[type=range]{accent-color:var(--accent)}
select{background:var(--chip);color:var(--fg);border:none;border-radius:5px;
  padding:3px 6px}
#meta{color:var(--dim);font-size:12px;padding:2px}
kbd{background:var(--chip);border-radius:4px;padding:0 5px;font-size:11px}
</style></head><body>
<header><h1>umik viewer</h1>
 <span class="dim" id="rootlbl"></span>
 <span class="dim" style="margin-left:auto">wheel: zoom &nbsp;&middot;&nbsp;
  side-scroll: pan &nbsp;&middot;&nbsp;
  drag strip below: pan/resize &nbsp;&middot;&nbsp; dbl-click strip: reset
  &nbsp;&middot;&nbsp;<kbd>&larr;</kbd><kbd>&rarr;</kbd> segments
  &nbsp;<kbd>space</kbd> play/pause</span></header>
<div id="layout">
 <div id="side"></div>
 <div id="main">
  <div id="meta">select a session</div>
  <div id="strip"></div>
  <div id="specwrap">
    <img id="spec" alt="">
    <div id="playhead"></div>
    <div id="loading">computing spectrogram&hellip;</div>
  </div>
  <div id="axis"><span id="t0">0:00</span>
    <span class="dim" id="mid">24 kHz &uarr; &nbsp; 0 Hz &darr;</span>
    <span id="t1">10:00</span></div>
  <div id="ovwrap">
    <img id="ov" alt="">
    <div id="ovwin"><div class="grip" id="gripL"></div>
      <div class="grip" id="gripR"></div></div>
    <div id="ovph"></div>
  </div>
  <div id="bar">
    <audio id="audio" controls preload="none"></audio>
    <label>boost <select id="boost">
      <option>0</option><option>12</option><option selected>24</option>
      <option>36</option><option>48</option></select> dB</label>
    <label>gain <input type="range" id="gain" min="0" max="30" value="0"
      step="1" style="width:110px"> <span id="gainlbl">+0</span> dB</label>
  </div>
 </div>
</div>
<script>
let IDX=null, cur={c:-1,s:-1,g:-1};
let dur=600;                       // current segment length (s)
let view={a:0,b:600};              // requested visible range
let loadedView={a:0,b:600};        // range of the image currently displayed
let refetchTimer=null;
const MINVIEW=0.5;
const $=id=>document.getElementById(id);
const audio=$('audio'), spec=$('spec'), ph=$('playhead');
const ovwrap=$('ovwrap'), ovwin=$('ovwin'), ovph=$('ovph');

let actx=null, gnode=null;
function ensureGain(){
  if(actx) return;
  actx=new (window.AudioContext||window.webkitAudioContext)();
  const src=actx.createMediaElementSource(audio);
  gnode=actx.createGain(); src.connect(gnode); gnode.connect(actx.destination);
}
$('gain').oninput=e=>{ensureGain();
  gnode.gain.value=Math.pow(10,e.target.value/20);
  $('gainlbl').textContent='+'+e.target.value;};

function fmtDur(s){const h=s/3600|0,m=(s%3600)/60|0;
  return h? h+'h'+String(m).padStart(2,'0') : m+'m';}
function segTime(n){const m=n.match(/seg-(\d{8})-(\d{2})(\d{2})(\d{2})/);
  return m? m[2]+':'+m[3]+':'+m[4] : n;}
function mmss(s){s=Math.max(0,s);
  return (s/60|0)+':'+String(s%60|0).padStart(2,'0');}
function curSeg(){
  const s=IDX&&IDX.collections[cur.c]&&IDX.collections[cur.c].sessions[cur.s];
  return s && s.segments[cur.g];}
function specURL(g,a,b,w,h){
  return '/api/spec?f='+encodeURIComponent(g.rel)+'&w='+w+'&h='+h
       +'&t0='+a.toFixed(3)+'&t1='+b.toFixed(3);}

async function load(){
  IDX=await (await fetch('/api/index')).json();
  $('rootlbl').textContent=IDX.root;
  const side=$('side'); side.innerHTML='';
  IDX.collections.forEach((c,ci)=>{
    const d=document.createElement('div'); d.className='coll';
    d.innerHTML='<h2>'+c.name+'</h2>';
    c.sessions.forEach((s,si)=>{
      const total=s.segments.reduce((a,x)=>a+x.dur,0);
      const b=document.createElement('button');
      b.className='sess'; b.id='sess-'+ci+'-'+si;
      const trust=(s.meta.clock_trusted===false)?' &middot; clock?':'';
      b.innerHTML='<b>'+s.name.slice(0,6)+'</b> &middot; '
        +s.name.slice(7,20).replace('T',' ')
        +'<div class="sub">'+s.segments.length+' segments &middot; '
        +fmtDur(total)+trust+'</div>';
      b.onclick=()=>selSession(ci,si);
      d.appendChild(b);
    });
    side.appendChild(d);
  });
  if(IDX.collections.length && IDX.collections[0].sessions.length)
    selSession(0,0);
}

function selSession(ci,si){
  document.querySelectorAll('.sess.active').forEach(e=>e.classList.remove('active'));
  const el=$('sess-'+ci+'-'+si); if(el) el.classList.add('active');
  cur.c=ci; cur.s=si;
  const s=IDX.collections[ci].sessions[si];
  const strip=$('strip'); strip.innerHTML='';
  s.segments.forEach((g,gi)=>{
    const b=document.createElement('button');
    b.className='segchip'; b.id='seg-'+gi; b.textContent=segTime(g.name);
    b.onclick=()=>selSeg(gi); strip.appendChild(b);
  });
  const m=s.meta, dev=m.device||{};
  $('meta').textContent=IDX.collections[ci].name+' / '+s.name
    +(m.storage?'  ·  storage: '+m.storage:'')
    +(dev.product?'  ·  '+dev.product:'')
    +(m.clock_trusted===false?'  ·  clock NOT trusted (ordering by counter)':'');
  selSeg(0);
}

function selSeg(gi){
  const s=IDX.collections[cur.c].sessions[cur.s];
  if(!s||gi<0||gi>=s.segments.length) return;
  document.querySelectorAll('.segchip.active').forEach(e=>e.classList.remove('active'));
  const el=$('seg-'+gi); if(el){el.classList.add('active');
    el.scrollIntoView({inline:'center',block:'nearest',behavior:'smooth'});}
  cur.g=gi;
  const g=s.segments[gi];
  dur=g.dur; view={a:0,b:dur}; loadedView={a:0,b:dur};
  spec.style.transform='none';
  $('loading').style.display='flex';
  spec.onload=()=>{$('loading').style.display='none'; prefetch(gi+1);};
  spec.src=specURL(g,0,dur,1600,512);
  $('ov').src=specURL(g,0,dur,1600,120);
  audio.pause();
  audio.src='/audio16?f='+encodeURIComponent(g.rel)+'&boost='+$('boost').value;
  audio.load();
  ph.style.left='0'; ovph.style.left='0';
  syncOverlay();
}
function prefetch(gi){
  const s=IDX.collections[cur.c].sessions[cur.s];
  if(s&&gi<s.segments.length)
    (new Image()).src=specURL(s.segments[gi],0,s.segments[gi].dur,1600,512);
}

// ---- zoom machinery -------------------------------------------------------

function clampView(){
  let w=view.b-view.a;
  if(w<MINVIEW){const c=(view.a+view.b)/2; view.a=c-MINVIEW/2; view.b=c+MINVIEW/2; w=MINVIEW;}
  if(w>dur){view.a=0; view.b=dur; return;}
  if(view.a<0){view.b-=view.a; view.a=0;}
  if(view.b>dur){view.a-=view.b-dur; view.b=dur; if(view.a<0)view.a=0;}
}
function syncOverlay(){
  ovwin.style.left=(view.a/dur*100)+'%';
  ovwin.style.width=((view.b-view.a)/dur*100)+'%';
  $('t0').textContent=mmss(view.a);
  $('t1').textContent=mmss(view.b);
}
function applyView(immediate){
  clampView(); syncOverlay();
  // instant CSS preview against the currently loaded image
  const W=spec.clientWidth||1, lw=loadedView.b-loadedView.a;
  const af=(view.a-loadedView.a)/lw, bf=(view.b-loadedView.a)/lw;
  const sc=1/Math.max(1e-6,(bf-af));
  spec.style.transform=(Math.abs(af)<1e-6&&Math.abs(sc-1)<1e-6)?'none'
    :'scaleX('+sc+') translateX('+(-af*W)+'px)';
  clearTimeout(refetchTimer);
  refetchTimer=setTimeout(fetchMain, immediate?0:220);
}
function fetchMain(){
  const g=curSeg(); if(!g) return;
  const req={a:view.a,b:view.b};
  const img=new Image();
  img.onload=()=>{
    // only accept if this is still (close to) what the user wants
    if(Math.abs(req.a-view.a)<1e-6&&Math.abs(req.b-view.b)<1e-6){
      spec.src=img.src; loadedView={a:req.a,b:req.b};
      spec.style.transform='none';
    }
  };
  img.src=specURL(g,req.a,req.b,1600,512);
}

$('specwrap').addEventListener('wheel',e=>{
  if(!curSeg())return;
  e.preventDefault();
  if(Math.abs(e.deltaX)>Math.abs(e.deltaY)){  // side-scroll: pan the window
    const w=view.b-view.a;
    if(w>=dur) return;
    const dt=e.deltaX*0.0015*w;               // one notch ~ 15% of the window
    view.a+=dt; view.b+=dt;
    applyView(false);
    return;
  }
  const r=$('specwrap').getBoundingClientRect();
  const frac=Math.min(1,Math.max(0,(e.clientX-r.left)/r.width));
  const tc=view.a+frac*(view.b-view.a);
  const f=Math.exp(e.deltaY*0.002);          // wheel up = zoom in
  let w=Math.min(dur,Math.max(MINVIEW,(view.b-view.a)*f));
  view.a=tc-frac*w; view.b=view.a+w;
  applyView(false);
},{passive:false});

let drag=null;
ovwrap.addEventListener('pointerdown',e=>{
  if(!curSeg())return;
  const r=ovwrap.getBoundingClientRect();
  const t=Math.min(dur,Math.max(0,(e.clientX-r.left)/r.width*dur));
  const id=e.target.id;
  if(id==='gripL') drag={mode:'l'};
  else if(id==='gripR') drag={mode:'r'};
  else if(id==='ovwin') drag={mode:'m', off:t-view.a};
  else{ const w=view.b-view.a;
    view.a=Math.max(0,Math.min(dur-w,t-w/2)); view.b=view.a+w;
    drag={mode:'m', off:t-view.a}; applyView(false); }
  try{ovwrap.setPointerCapture(e.pointerId);}catch(_){}
});
ovwrap.addEventListener('pointermove',e=>{
  if(!drag)return;
  const r=ovwrap.getBoundingClientRect();
  const t=Math.min(dur,Math.max(0,(e.clientX-r.left)/r.width*dur));
  if(drag.mode==='l') view.a=Math.min(view.b-MINVIEW,t);
  else if(drag.mode==='r') view.b=Math.max(view.a+MINVIEW,t);
  else{ const w=view.b-view.a;
    view.a=Math.max(0,Math.min(dur-w,t-drag.off)); view.b=view.a+w; }
  applyView(false);
});
ovwrap.addEventListener('pointerup',()=>{ if(drag){drag=null; applyView(true);} });
ovwrap.addEventListener('dblclick',()=>{ view={a:0,b:dur}; applyView(true); });

// ---- transport ------------------------------------------------------------

$('boost').onchange=()=>{const g=curSeg(); if(!g)return;
  const t=audio.currentTime,p=!audio.paused;
  audio.src='/audio16?f='+encodeURIComponent(g.rel)+'&boost='+$('boost').value;
  audio.load(); audio.currentTime=t; if(p) audio.play();};

$('specwrap').onclick=e=>{
  const g=curSeg(); if(!g)return;
  const r=$('specwrap').getBoundingClientRect();
  const frac=(e.clientX-r.left)/r.width;
  audio.currentTime=view.a+frac*(view.b-view.a);
  if(audio.paused) audio.play();
};
audio.onended=()=>{const s=IDX.collections[cur.c].sessions[cur.s];
  if(cur.g+1<s.segments.length){selSeg(cur.g+1); audio.play();}};
audio.onplay=()=>{ensureGain(); if(actx.state==='suspended') actx.resume();};

(function tick(){
  if(curSeg()){
    const ct=audio.currentTime, vw=view.b-view.a;
    const frac=(ct-view.a)/vw;
    if(frac>=0&&frac<=1){ph.style.display='block'; ph.style.left=(frac*100)+'%';}
    else ph.style.display='none';
    ovph.style.left=(ct/dur*100)+'%';
    $('mid').textContent='▶ '+mmss(ct)+'  ·  view '
      +mmss(view.a)+'–'+mmss(view.b)+'  ·  24 kHz ↑  0 Hz ↓';
  }
  requestAnimationFrame(tick);})();

document.onkeydown=e=>{
  if(e.target.tagName==='INPUT'||e.target.tagName==='SELECT') return;
  if(e.key==='ArrowRight'){selSeg(cur.g+1);e.preventDefault();}
  else if(e.key==='ArrowLeft'){selSeg(cur.g-1);e.preventDefault();}
  else if(e.key===' '){audio.paused?audio.play():audio.pause();e.preventDefault();}
  else if(e.key==='0'){view={a:0,b:dur};applyView(true);}
};
load();
</script></body></html>
"""

# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="offline UMIK spectrogram browser")
    ap.add_argument("data", nargs="?", default=".",
                    help="directory containing recordings/ trees (default: .)")
    ap.add_argument("--port", type=int, default=8377)
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--verbose", action="store_true",
                    help="log every HTTP request to stderr")
    args = ap.parse_args()

    root = os.path.abspath(args.data)
    index = build_index(root)
    nseg = sum(len(s["segments"]) for c in index for s in c["sessions"])
    if not nseg:
        sys.exit(f"no recordings/<session>/seg-*.wav found under {root}")
    print(f"indexed {sum(len(c['sessions']) for c in index)} sessions, "
          f"{nseg} segments under {root}")

    Handler.root = root
    Handler.index = index
    Handler.verbose = args.verbose
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"serving on {url}  (Ctrl-C to stop)")
    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")

if __name__ == "__main__":
    main()
