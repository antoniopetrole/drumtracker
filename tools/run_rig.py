#!/usr/bin/env python3
"""Developer tool: run tests/reaper_integration.lua in a fully isolated REAPER.

Usage: run_rig.py <reaper_install_copy_dir> <work_dir> [--screenshot-ui] [--timeout N]

Isolation: -cfgfile gives the instance its own resource directory, -new gives it
an empty project, and audio mode 4 (Dummy Audio) keeps it off real interfaces. A
guard watches the real %APPDATA%\\REAPER and kills the rig at once if a file there
changes before the test script has proved, by running from res, that the instance
is isolated. --web-port N also serves web/drums.html on that port.

Without -cfgfile REAPER reads the user's real config, even from a copied install:
an empty reaper.ini beside the exe does NOT make it portable.

For the dashboard test, work_dir needs reaper_imgui-x64.dll, and
res/Scripts/ReaTeam Extensions/API/imgui.lua from ReaImGui's shims/ directory.
"""
import atexit
import ctypes
import ctypes.wintypes as wt
import os
import re
import shutil
import struct
import subprocess
import sys
import json
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
user32 = ctypes.windll.user32
user32.SetProcessDPIAware()  # report real pixel sizes, or captures get cropped
AUDIO_MODE = os.environ.get("LDGM_AUDIO_MODE", "4")


def window_titles(pid):
    titles = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        owner = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            buf = ctypes.create_unicode_buffer(512)
            user32.GetWindowTextW(hwnd, buf, 512)
            if buf.value:
                titles.append((hwnd, buf.value))
        return True

    user32.EnumWindows(cb, 0)
    return titles


def all_windows(pid):
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        owner = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True

    user32.EnumWindows(cb, 0)
    return found


def print_window(hwnd, path):
    """Renders one window to a BMP via PrintWindow. Never reads the screen, so it
    can't capture anything but this window, and never changes focus."""
    gdi32 = ctypes.windll.gdi32
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    wdc = user32.GetWindowDC(hwnd)
    mdc = gdi32.CreateCompatibleDC(wdc)
    bmp = gdi32.CreateCompatibleBitmap(wdc, w, h)
    gdi32.SelectObject(mdc, bmp)
    user32.PrintWindow(hwnd, mdc, 2)  # PW_RENDERFULLCONTENT

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
                    ("biPlanes", wt.WORD), ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
                    ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", wt.LONG), ("biYPelsPerMeter", wt.LONG),
                    ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD)]

    info = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, h, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(info), 0)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(hwnd, wdc)
    with open(path, "wb") as f:
        f.write(b"BM" + struct.pack("<IHHI", 54 + len(buf), 0, 0, 54))
        f.write(bytes(info))
        f.write(buf.raw)
    return w, h


def http_get(port, path):
    with urllib.request.urlopen("http://127.0.0.1:%s/%s" % (port, path), timeout=5) as r:
        return r.read().decode("utf8", "replace"), dict(r.headers)


def read_snapshot(port):
    text, _ = http_get(port, "_/GET/EXTSTATE/LiveDrumGrooveMonitor/snapshot")
    parts = text.split("\n")[0].split("\t")
    raw = "\t".join(parts[3:]).replace("\\t", "\t").replace("\\n", "\n").replace("\\\\", "\\")
    return json.loads(raw), len(text)


def browser_shot(port, name, width, height, work):
    """Renders the page inside an iframe of exactly this size. Headless windows have
    a minimum width, and this also proves the page can be embedded. Uses a throwaway
    browser profile, so it never touches a real one."""
    exe = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
    shots = os.path.join(work, "shots")
    out = os.path.join(shots, name + ".png")
    frame = os.path.join(shots, name + "_frame.html")
    with open(frame, "w") as f:
        f.write('<!doctype html><body style="margin:0;background:#000">'
                '<iframe src="http://127.0.0.1:%s/drums.html" width="%d" height="%d" '
                'style="border:0;display:block"></iframe></body>' % (port, width, height))
    subprocess.run([exe, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--user-data-dir=" + os.path.join(work, "edge-profile-" + name),
                    "--window-size=%d,%d" % (max(width, 520), height), "--virtual-time-budget=4000",
                    "--screenshot=" + out, "file:///" + frame.replace("\\", "/")],
                   timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):  # the browser can return before the file lands
        if os.path.exists(out):
            break
        time.sleep(0.1)
    print("shot", name, os.path.exists(out), flush=True)


def check_web_page(port, work):
    def report(name, ok, detail=""):
        print("%s  web: %s  [%s]" % ("PASS" if ok else "FAIL", name, detail), flush=True)

    page, headers = http_get(port, "drums.html")
    report("page served from the user www root", "Drum Timing" in page, len(page))
    print("web headers:", {k: v for k, v in headers.items()}, flush=True)

    first, size = read_snapshot(port)
    report("snapshot parses as JSON", first["version"] == 1, "%d bytes" % size)
    time.sleep(0.5)
    second, _ = read_snapshot(port)
    report("seq advances while the dashboard runs", second["seq"] > first["seq"], second["seq"])
    lanes = {l["name"]: l for l in second["lanes"]}
    report("snare bias reaches the page as +15", abs(lanes["Snare"]["bias"] - 15) < 0.1, lanes["Snare"]["bias"])
    report("hat bias reaches the page as -8", abs(lanes["Hi-hat"]["bias"] + 8) < 0.1, lanes["Hi-hat"]["bias"])
    report("self-test is flagged to the page", len(second["selftest"]) == 3, second["selftest"])

    browser_shot(port, "phone", 390, 844, work)
    browser_shot(port, "tablet", 1180, 820, work)

    http_get(port, "_/1016")
    time.sleep(0.6)
    report("Stop button's command stops the transport", read_snapshot(port)[0]["playing"] is False)
    before = read_snapshot(port)[0]["lanes"][1]["hits"]
    http_get(port, "_/SET/EXTSTATE/LiveDrumGrooveMonitor/command/reset")
    time.sleep(0.6)
    after = read_snapshot(port)[0]["lanes"][1]
    report("Reset button's command clears results", after["hits"] == 0 and before > 0, "%s -> %s" % (before, after["hits"]))
    report("after reset there are no fake numbers", after.get("bias") is None and after.get("latest") is None, after.get("bias"))
    browser_shot(port, "phone_reset", 390, 844, work)
    http_get(port, "_/1007")
    time.sleep(0.6)
    report("Play button's command starts the transport", read_snapshot(port)[0]["playing"] is True)


def capture_ui(proc, work):
    """Captures the dashboard's own window across the tab cycle, then quits the rig."""
    shots = os.path.join(work, "shots")
    os.makedirs(shots, exist_ok=True)
    time.sleep(7)  # let a few bars of hits accumulate
    web_port = sys.argv[sys.argv.index("--web-port") + 1] if "--web-port" in sys.argv else None
    if web_port:
        check_web_page(web_port, work)
    for i in range(8):
        for n, hwnd in enumerate(all_windows(proc.pid)):
            buf = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, buf, 256)
            cls = ctypes.create_unicode_buffer(256)
            user32.GetClassNameW(hwnd, cls, 256)
            if "REAPER v" in buf.value:
                continue
            size = print_window(hwnd, os.path.join(shots, "w%d_%d.bmp" % (n, i)))
            if i == 0:
                print("captured", repr(buf.value), cls.value, size, flush=True)
        time.sleep(2)
    if web_port:
        for hwnd in all_windows(proc.pid):
            buf = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, buf, 256)
            if buf.value.startswith("Live Drum Groove Monitor"):
                user32.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE: closes the dashboard
        time.sleep(3)
        text, _ = http_get(web_port, "_/GET/EXTSTATE/LiveDrumGrooveMonitor/snapshot")
        cleared = text.split("\n")[0].split("\t")[3:] in ([], [""])
        print("%s  web: closing the dashboard clears the snapshot" % ("PASS" if cleared else "FAIL"), flush=True)
        browser_shot(web_port, "phone_closed", 390, 500, work)
    proc.kill()
    if web_port:
        time.sleep(1)
        browser_shot(web_port, "phone_unreachable", 390, 500, work)


def snapshot(path):
    out = {}
    for name in os.listdir(path):
        full = os.path.join(path, name)
        if os.path.isfile(full):
            out[name] = os.path.getmtime(full)
    return out


def main():
    install, work = sys.argv[1], sys.argv[2]
    timeout = int(sys.argv[sys.argv.index("--timeout") + 1]) if "--timeout" in sys.argv else 120
    res = os.path.join(work, "res")
    user_res = os.path.join(os.environ["APPDATA"], "REAPER")

    for sub in ("Scripts/LiveDrumGrooveMonitor", "Effects/LiveDrumGrooveMonitor", "UserPlugins"):
        os.makedirs(os.path.join(res, sub), exist_ok=True)
    for f in os.listdir(os.path.join(REPO, "lua")):
        shutil.copy(os.path.join(REPO, "lua", f), os.path.join(res, "Scripts/LiveDrumGrooveMonitor", f))
    shutil.copy(os.path.join(REPO, "jsfx", "Live Drum Onset Detector.jsfx"),
                os.path.join(res, "Effects/LiveDrumGrooveMonitor"))
    shutil.copy(os.path.join(REPO, "tests", "reaper_integration.lua"), os.path.join(res, "Scripts"))
    os.makedirs(os.path.join(res, "reaper_www_root"), exist_ok=True)
    shutil.copy(os.path.join(REPO, "web", "drums.html"), os.path.join(res, "reaper_www_root"))
    dll = os.path.join(work, "reaper_imgui-x64.dll")
    if os.path.exists(dll):
        shutil.copy(dll, os.path.join(res, "UserPlugins"))

    with open(os.path.join(res, "Scripts", "__startup.lua"), "w") as f:
        f.write('dofile(reaper.GetResourcePath() .. "/Scripts/reaper_integration.lua")\n')

    ini = os.path.join(res, "reaper.ini")
    if not os.path.exists(ini):
        with open(ini, "w") as f:
            f.write("[REAPER]\nsplash=0\n")
    # Never open the real interface: a fresh config can default to ASIO.
    with open(ini, errors="ignore") as f:
        text = f.read()
    text = re.sub(r"(?m)^(mode|asio_driver|asio_driver_name)=.*\n", "", text)
    if "[audioconfig]" in text:
        text = text.replace("[audioconfig]\n", "[audioconfig]\nmode=%s\n" % AUDIO_MODE, 1)
    else:
        text += "\n[audioconfig]\nmode=%s\n" % AUDIO_MODE
    if "--web-port" in sys.argv:
        port = sys.argv[sys.argv.index("--web-port") + 1]
        text = re.sub(r"(?m)^csurf_.*\n", "", text)
        text = text.replace("[REAPER]\n", "[REAPER]\ncsurf_cnt=1\ncsurf_0=HTTP 0 %s '' '' 0 ''\n" % port, 1)
    with open(ini, "w") as f:
        f.write(text)

    results = os.path.join(work, "results.txt")
    for p in (results, results + ".done"):
        if os.path.exists(p):
            os.remove(p)

    env = dict(os.environ, LDGM_RESULTS=results)
    if "--screenshot-ui" in sys.argv:
        env["LDGM_SCREENSHOT"] = "1"
        env["LDGM_CYCLE_TABS"] = "1"

    before = snapshot(user_res)
    proc = subprocess.Popen(
        [os.path.join(install, "reaper.exe"), "-cfgfile", ini, "-new", "-newinst", "-nosplash", "-noactivate", "-ignoreerrors"],
        env=env, cwd=work)
    print("rig pid", proc.pid, flush=True)

    def isolation_proven():
        # The test script exists only in res, so it logging res means this instance
        # is using it. From then on, config changes are the user's own REAPER saving.
        try:
            with open(results) as f:
                first = f.readline().strip()
        except OSError:
            return False
        return os.path.normcase(os.path.normpath(first.partition("=")[2])) == os.path.normcase(os.path.normpath(res))

    def guard_tripped():
        if not isolation_proven():
            after = snapshot(user_res)
            changed = [n for n in after if after[n] != before.get(n)]
            if changed:
                return "user config changed before isolation was proven: " + ", ".join(changed)
        for _, title in window_titles(proc.pid):
            if "Drum Setup" in title:
                return "user project opened: " + title
        return None

    atexit.register(lambda: proc.poll() is None and proc.kill())
    seen = set()
    started = time.time()
    status = "timeout"
    while time.time() - started < timeout:
        reason = guard_tripped()
        if reason:
            proc.kill()
            print("GUARD KILLED RIG:", reason, flush=True)
            return 2
        for _, title in window_titles(proc.pid):
            if title not in seen:
                seen.add(title)
                print("window:", title, flush=True)
        if os.path.exists(results + ".done"):
            status = "done"
            break
        if proc.poll() is not None:
            status = "exited %d" % proc.returncode
            break
        time.sleep(0.1)

    print("status:", status, flush=True)
    if "--screenshot-ui" in sys.argv and status == "done":
        capture_ui(proc, work)
    if "--screenshot-ui" not in sys.argv and proc.poll() is None:
        time.sleep(1)
        if proc.poll() is None:
            proc.kill()
    if os.path.exists(results):
        print(open(results).read())
    after = snapshot(user_res)
    print("isolated resource path confirmed:", isolation_proven(), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
