#!/usr/bin/env python3
"""
RPi → iPad USB Dashboard v2
- FFmpeg H.264/WebM stream (15-30fps)
- WebSocket audio (Opus/PCM via FFmpeg)
- Bidirectional file manager (browse, download, upload)
- Apple Pencil / touch → xdotool input injection
"""

import os, io, time, json, subprocess, threading, base64, glob, shutil, mimetypes
import asyncio, struct, wave
from pathlib import Path
from flask import (Flask, Response, jsonify, send_from_directory,
                   request, stream_with_context, abort)
from flask_sock import Sock
import simple_websocket

app  = Flask(__name__, static_folder='static')
sock = Sock(app)

DISPLAY   = os.environ.get("DISPLAY", ":0")
AUDIO_DEV = os.environ.get("AUDIO_DEV", "default")   # ALSA device
UPLOAD_DIR = Path("/tmp/rpi-uploads")
UPLOAD_DIR.mkdir(exist_ok=True)

# ── HELPERS ───────────────────────────────────────────────

def run(cmd, shell=True, timeout=5):
    try:
        return subprocess.check_output(cmd, shell=shell,
               stderr=subprocess.DEVNULL, timeout=timeout).decode().strip()
    except Exception:
        return ""

def get_display_res():
    """Get current display resolution."""
    raw = run(f"DISPLAY={DISPLAY} xdpyinfo 2>/dev/null | grep dimensions | awk '{{print $2}}'")
    if raw and 'x' in raw:
        w, h = raw.split('x')
        return int(w), int(h)
    return 1920, 1080

# ── SYSTEM STATS ──────────────────────────────────────────

def cpu_temp():
    raw = run("vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp")
    if "temp=" in raw:
        return raw.replace("temp=","").replace("'C","")
    try:
        return str(round(int(raw)/1000,1))
    except:
        return "N/A"

def cpu_percent():
    return run("top -bn1 | grep 'Cpu(s)' | awk '{print $2+$4}'") or "0"

def mem_info():
    raw = run("free -m | awk 'NR==2{print $2,$3,$4}'").split()
    if len(raw)==3:
        total,used,free=raw
        return {"total":total,"used":used,"free":free,"pct":round(int(used)/int(total)*100,1)}
    return {"total":"?","used":"?","free":"?","pct":0}

def disk_info():
    raw = run("df -h / | awk 'NR==2{print $2,$3,$4,$5}'").split()
    if len(raw)==4:
        return {"total":raw[0],"used":raw[1],"free":raw[2],"pct":raw[3]}
    return {"total":"?","used":"?","free":"?","pct":"?"}

def processes():
    raw = run("ps aux --sort=-%cpu | head -8 | tail -7")
    procs=[]
    for line in raw.splitlines():
        parts=line.split(None,10)
        if len(parts)>=11:
            procs.append({"user":parts[0],"cpu":parts[2],"mem":parts[3],"cmd":parts[10][:40]})
    return procs

def net_stats():
    r = run("cat /proc/net/dev | grep usb0")
    if r:
        p=r.split()
        try: return {"rx":p[1],"tx":p[9]}
        except: pass
    return {"rx":"0","tx":"0"}

# ── VIDEO STREAMING ───────────────────────────────────────
#
# Strategy:
#   1. FFmpeg captures X11 screen → pipe raw JPEG frames
#   2. Flask MJPEG route wraps them → Safari renders natively
#   Quality knobs: -r (fps), -vf scale, -q:v (jpeg quality 2-31, lower=better)

_ffmpeg_proc = None
_frame_lock   = threading.Lock()
_latest_frame = None
_frame_cond   = threading.Condition(_frame_lock)

def ffmpeg_capture_loop(fps=24, width=1280, scale_height=-1, quality=4):
    global _ffmpeg_proc, _latest_frame
    cmd = [
        "ffmpeg", "-loglevel", "quiet",
        "-f", "x11grab",
        "-framerate", str(fps),
        "-video_size", f"{width}x{get_display_res()[1] if scale_height==-1 else scale_height}",
        "-i", f"{DISPLAY}.0+0,0",
        "-vf", f"scale={width}:{scale_height}:flags=lanczos",
        "-f", "image2pipe",
        "-vcodec", "mjpeg",
        "-q:v", str(quality),
        "pipe:1"
    ]
    _ffmpeg_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    buf = b""
    SOI = b"\xff\xd8"
    EOI = b"\xff\xd9"

    while True:
        chunk = _ffmpeg_proc.stdout.read(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            start = buf.find(SOI)
            if start == -1:
                buf = b""
                break
            end = buf.find(EOI, start+2)
            if end == -1:
                buf = buf[start:]
                break
            frame = buf[start:end+2]
            buf   = buf[end+2:]
            with _frame_cond:
                _latest_frame = frame
                _frame_cond.notify_all()

def get_frame(timeout=1.0):
    with _frame_cond:
        _frame_cond.wait(timeout)
        return _latest_frame

# Start capture thread
_capture_settings = {"fps": 24, "width": 1280, "quality": 4}

def restart_capture(**kwargs):
    global _ffmpeg_proc
    _capture_settings.update(kwargs)
    if _ffmpeg_proc:
        _ffmpeg_proc.terminate()
        _ffmpeg_proc = None
    t = threading.Thread(
        target=ffmpeg_capture_loop,
        kwargs=_capture_settings,
        daemon=True
    )
    t.start()

restart_capture()

# ── AUDIO STREAMING ───────────────────────────────────────
#
# FFmpeg captures PulseAudio/ALSA → raw s16le PCM → WebSocket
# Browser Web Audio API plays it in real time.
# Rate: 44100Hz, stereo, 16-bit → ~176KB/s — fine over USB.

_audio_clients = set()
_audio_lock    = threading.Lock()

def audio_broadcast_loop():
    cmd = [
        "ffmpeg", "-loglevel", "quiet",
        "-f", "pulse", "-i", "default",   # PulseAudio
        "-ac", "2", "-ar", "44100",
        "-f", "s16le",
        "pipe:1"
    ]
    # fallback to alsa
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if proc.poll() is not None:
        cmd[3] = "alsa"
        cmd[5] = AUDIO_DEV
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    CHUNK = 4096  # ~23ms at 44100Hz stereo s16le
    while True:
        data = proc.stdout.read(CHUNK)
        if not data:
            break
        with _audio_lock:
            dead = set()
            for ws in list(_audio_clients):
                try:
                    ws.send(data)
                except Exception:
                    dead.add(ws)
            _audio_clients -= dead

threading.Thread(target=audio_broadcast_loop, daemon=True).start()

# ── INPUT INJECTION ───────────────────────────────────────

def inject_mouse(action, x, y, button=1, dx=0, dy=0, stream_w=1280):
    """Translate stream coords → display coords and inject via xdotool."""
    disp_w, disp_h = get_display_res()
    # scale from stream width maintaining aspect ratio
    stream_h = int(disp_h * stream_w / disp_w)
    rx = int(x * disp_w / stream_w)
    ry = int(y * disp_h / stream_h)
    rx = max(0, min(rx, disp_w-1))
    ry = max(0, min(ry, disp_h-1))

    env = {"DISPLAY": DISPLAY}
    base = ["xdotool"]

    if action == "move":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry)],
                         env=env, stderr=subprocess.DEVNULL)
    elif action == "down":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry),
                                  "mousedown", str(button)],
                         env=env, stderr=subprocess.DEVNULL)
    elif action == "up":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry),
                                  "mouseup", str(button)],
                         env=env, stderr=subprocess.DEVNULL)
    elif action == "click":
        subprocess.Popen(base + ["mousemove", str(rx), str(ry),
                                  "click", str(button)],
                         env=env, stderr=subprocess.DEVNULL)
    elif action == "scroll":
        btn = "4" if dy < 0 else "5"  # scroll up=4 down=5
        subprocess.Popen(base + ["mousemove", str(rx), str(ry),
                                  "click", "--repeat", "3", btn],
                         env=env, stderr=subprocess.DEVNULL)

def inject_key(key):
    env = {"DISPLAY": DISPLAY}
    subprocess.Popen(["xdotool", "key", key],
                     env=env, stderr=subprocess.DEVNULL)

def inject_type(text):
    env = {"DISPLAY": DISPLAY}
    subprocess.Popen(["xdotool", "type", "--clearmodifiers", "--", text],
                     env=env, stderr=subprocess.DEVNULL)

# ── ROUTES: VIDEO ──────────────────────────────────────────

@app.route("/")
def index():
    return send_from_directory("static", "index.html")

@app.route("/api/stream")
def stream():
    fps_limit = float(request.args.get("fps", 24))
    interval  = 1.0 / fps_limit

    def generate():
        last = 0
        while True:
            frame = get_frame(timeout=2.0)
            if not frame:
                continue
            now = time.time()
            if now - last < interval:
                continue
            last = now
            yield (
                b"--frame\r\n"
                b"Content-Type: image/jpeg\r\n\r\n" + frame + b"\r\n"
            )

    return Response(stream_with_context(generate()),
                    mimetype="multipart/x-mixed-replace; boundary=frame",
                    headers={"Cache-Control": "no-store",
                             "X-Accel-Buffering": "no"})

@app.route("/api/screenshot")
def screenshot():
    frame = _latest_frame
    if not frame:
        return Response("no frame", status=503)
    return Response(frame, mimetype="image/jpeg",
                    headers={"Cache-Control":"no-store"})

@app.route("/api/stream/settings", methods=["POST"])
def stream_settings():
    body = request.get_json(silent=True) or {}
    fps  = int(body.get("fps", 24))
    qual = int(body.get("quality", 4))   # 2=best, 10=balanced, 31=lowest
    w    = int(body.get("width", 1280))
    restart_capture(fps=fps, quality=qual, width=w)
    return jsonify({"ok": True, "fps": fps, "quality": qual, "width": w})

# ── ROUTES: AUDIO ──────────────────────────────────────────

@sock.route("/ws/audio")
def audio_ws(ws):
    with _audio_lock:
        _audio_clients.add(ws)
    try:
        while True:
            ws.receive(timeout=60)  # keep alive
    except Exception:
        pass
    finally:
        with _audio_lock:
            _audio_clients.discard(ws)

# ── ROUTES: INPUT ──────────────────────────────────────────

@app.route("/api/input/mouse", methods=["POST"])
def input_mouse():
    body   = request.get_json(silent=True) or {}
    action = body.get("action", "move")   # move|down|up|click|scroll
    x      = float(body.get("x", 0))
    y      = float(body.get("y", 0))
    btn    = int(body.get("button", 1))
    dx     = float(body.get("dx", 0))
    dy     = float(body.get("dy", 0))
    sw     = int(body.get("streamW", 1280))
    inject_mouse(action, x, y, btn, dx, dy, sw)
    return jsonify({"ok": True})

@app.route("/api/input/key", methods=["POST"])
def input_key():
    body = request.get_json(silent=True) or {}
    key  = body.get("key", "")
    if key:
        inject_key(key)
    return jsonify({"ok": True})

@app.route("/api/input/type", methods=["POST"])
def input_type():
    body = request.get_json(silent=True) or {}
    text = body.get("text", "")
    if text:
        inject_type(text)
    return jsonify({"ok": True})

# ── ROUTES: FILES ──────────────────────────────────────────

ALLOWED_BROWSE_ROOTS = [
    Path.home(),
    Path("/tmp"),
    Path("/media"),
    Path("/mnt"),
]

def safe_path(raw):
    """Resolve and validate path stays within allowed roots."""
    p = Path(raw).resolve()
    for root in ALLOWED_BROWSE_ROOTS:
        try:
            p.relative_to(root.resolve())
            return p
        except ValueError:
            continue
    return None

@app.route("/api/files/list")
def files_list():
    raw  = request.args.get("path", str(Path.home()))
    path = safe_path(raw)
    if not path or not path.exists():
        return jsonify({"error": "Invalid path"}), 400

    entries = []
    try:
        for item in sorted(path.iterdir(), key=lambda x: (x.is_file(), x.name.lower())):
            stat = item.stat()
            entries.append({
                "name":     item.name,
                "path":     str(item),
                "is_dir":   item.is_dir(),
                "size":     stat.st_size if item.is_file() else 0,
                "modified": int(stat.st_mtime),
                "mime":     mimetypes.guess_type(item.name)[0] or "",
            })
    except PermissionError:
        return jsonify({"error": "Permission denied"}), 403

    return jsonify({
        "path":    str(path),
        "parent":  str(path.parent),
        "entries": entries,
    })

@app.route("/api/files/download")
def files_download():
    raw  = request.args.get("path", "")
    path = safe_path(raw)
    if not path or not path.is_file():
        return jsonify({"error": "Not a file"}), 404
    return send_from_directory(str(path.parent), path.name, as_attachment=True)

@app.route("/api/files/upload", methods=["POST"])
def files_upload():
    dest_raw = request.args.get("dest", str(Path.home()))
    dest     = safe_path(dest_raw)
    if not dest or not dest.is_dir():
        return jsonify({"error": "Invalid destination"}), 400

    saved = []
    for f in request.files.values():
        name = Path(f.filename).name  # strip path
        out  = dest / name
        f.save(str(out))
        saved.append(name)
    return jsonify({"ok": True, "saved": saved})

@app.route("/api/files/mkdir", methods=["POST"])
def files_mkdir():
    body = request.get_json(silent=True) or {}
    dest = safe_path(body.get("path",""))
    if not dest:
        return jsonify({"error":"Invalid path"}),400
    dest.mkdir(parents=True, exist_ok=True)
    return jsonify({"ok":True})

@app.route("/api/files/delete", methods=["POST"])
def files_delete():
    body = request.get_json(silent=True) or {}
    path = safe_path(body.get("path",""))
    if not path or not path.exists():
        return jsonify({"error":"Not found"}),404
    if path.is_dir():
        shutil.rmtree(str(path))
    else:
        path.unlink()
    return jsonify({"ok":True})

@app.route("/api/files/rename", methods=["POST"])
def files_rename():
    body = request.get_json(silent=True) or {}
    src  = safe_path(body.get("src",""))
    new_name = Path(body.get("name","")).name
    if not src or not src.exists() or not new_name:
        return jsonify({"error":"Invalid"}),400
    dst = src.parent / new_name
    src.rename(dst)
    return jsonify({"ok":True})

# ── ROUTES: STATS & TERMINAL ───────────────────────────────

@app.route("/api/stats")
def stats():
    mem  = mem_info()
    disk = disk_info()
    return jsonify({
        "hostname": run("hostname"),
        "uptime":   run("uptime -p").replace("up ",""),
        "cpu":      cpu_percent(),
        "temp":     cpu_temp(),
        "mem":      mem,
        "disk":     disk,
        "usb_ip":   run("ip addr show usb0 2>/dev/null | grep 'inet ' | awk '{print $2}'") or "not connected",
        "net":      net_stats(),
        "processes":processes(),
        "time":     time.strftime("%H:%M:%S"),
        "date":     time.strftime("%A %d %B %Y"),
        "display":  "%dx%d" % get_display_res(),
        "stream":   _capture_settings,
    })

BLOCKED = ["rm -rf","mkfs","dd ","shutdown","reboot","passwd","wget","curl","chmod 777"]

@app.route("/api/run", methods=["POST"])
def run_cmd():
    body = request.get_json(silent=True) or {}
    cmd  = body.get("cmd","").strip()
    if any(b in cmd for b in BLOCKED):
        return jsonify({"error":"Command blocked"}),403
    if not cmd:
        return jsonify({"output":""})
    out = run(cmd, timeout=10)
    return jsonify({"output": out})

# ── MAIN ──────────────────────────────────────────────────

if __name__ == "__main__":
    print("RPi Dashboard v2 → http://0.0.0.0:80")
    app.run(host="0.0.0.0", port=80, debug=False, threaded=True)
