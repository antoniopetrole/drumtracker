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
import base64
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
import urllib.parse
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


class Page:
    """A real headless browser driven over its debugging protocol: real time, true
    device emulation, JS errors reported. Uses a throwaway profile. Needs the
    websocket-client package."""

    def __init__(self, port, work, width=390, height=844, debug_port=19222):
        import websocket
        exe = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
        self.work = work
        self.errors = []
        self.profile = os.path.join(work, "edge-profile-%d" % debug_port)
        self.proc = subprocess.Popen(
            [exe, "--headless=new", "--disable-gpu", "--remote-debugging-port=%d" % debug_port,
             "--remote-allow-origins=*", "--no-first-run",
             "--user-data-dir=" + self.profile, "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        target = None
        for _ in range(100):
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/json" % debug_port, timeout=2) as r:
                    pages = [t for t in json.load(r) if t["type"] == "page"]
                if pages:
                    target = pages[0]
                    break
            except OSError:
                pass
            time.sleep(0.2)
        self.ws = websocket.create_connection(target["webSocketDebuggerUrl"], timeout=20)
        self.next_id = 0
        self.call("Runtime.enable")
        self.call("Page.enable")
        self.call("Emulation.setDeviceMetricsOverride",
                  width=width, height=height, deviceScaleFactor=2, mobile=width < 800)
        self.call("Page.navigate", url="http://127.0.0.1:%s/drums.html" % port)

    def call(self, method, **params):
        self.next_id += 1
        self.ws.send(json.dumps({"id": self.next_id, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("method") == "Runtime.exceptionThrown":
                detail = msg["params"]["exceptionDetails"]
                self.errors.append(detail.get("exception", {}).get("description") or detail.get("text"))
            if msg.get("id") == self.next_id:
                return msg.get("result", {})

    def eval(self, expression):
        result = self.call("Runtime.evaluate", expression=expression, returnByValue=True)
        if "exceptionDetails" in result:
            self.errors.append(str(result["exceptionDetails"]))
            return None
        return result["result"].get("value")

    def resize(self, width, height):
        self.call("Emulation.setDeviceMetricsOverride",
                  width=width, height=height, deviceScaleFactor=2, mobile=width < 800)

    def shot(self, name):
        data = self.call("Page.captureScreenshot", format="png")["data"]
        with open(os.path.join(self.work, "shots", name + ".png"), "wb") as f:
            f.write(base64.b64decode(data))

    def close(self):
        try:
            self.ws.close()
        finally:
            self.proc.kill()
            # Edge's helpers detach from the process we started, so find them by this
            # run's throwaway profile. That also keeps this away from any real browser.
            script = ("Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | "
                      "Where-Object { $_.CommandLine -like '*" + self.profile.replace("'", "''") + "*' } | "
                      "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }")
            subprocess.run(["powershell", "-NoProfile", "-Command", script],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def check_web_page(port, work):
    def report(name, ok, detail=""):
        print("%s  web: %s  [%s]" % ("PASS" if ok else "FAIL", name, detail), flush=True)

    page, headers = http_get(port, "drums.html")
    report("page served from the user www root", "Drum Timing" in page, len(page))

    first, size = read_snapshot(port)
    report("snapshot parses as JSON", first["version"] == 1, "%d bytes" % size)
    time.sleep(0.5)
    second, _ = read_snapshot(port)
    report("seq advances while the dashboard runs", second["seq"] > first["seq"], second["seq"])
    lanes = {l["name"]: l for l in second["lanes"]}
    report("snare bias is +15", abs(lanes["Snare"]["bias"] - 15) < 0.1, lanes["Snare"]["bias"])
    report("hat bias is -8", abs(lanes["Hi-hat"]["bias"] + 8) < 0.1, lanes["Hi-hat"]["bias"])
    report("self-test is flagged", len(second["selftest"]) == 3, second["selftest"])

    batch, _ = http_get(port, "_/GET/EXTSTATE/LiveDrumGrooveMonitor/snapshot;GET/EXTSTATE/LiveDrumGrooveMonitor/library;")
    keys = [line.split("\t")[2] for line in batch.split("\n") if line.startswith("EXTSTATE")]
    report("a batched request returns both values", keys == ["snapshot", "library"], keys)

    # From here on, everything goes through the actual page in a real browser.
    browser = Page(port, work)
    try:
        time.sleep(2)
        seq_a = browser.eval("lastSeq")
        time.sleep(1.5)
        seq_b = browser.eval("lastSeq")
        report("page keeps polling, it doesn't freeze", seq_b is not None and seq_a is not None and seq_b > seq_a, "%s -> %s" % (seq_a, seq_b))
        report("page says it's connected", "detector" in (browser.eval("document.getElementById('conn').textContent") or ""),
               browser.eval("document.getElementById('conn').textContent"))
        browser.shot("phone")
        report("rock beat card shows +15", "+15" in (browser.eval("document.querySelectorAll('.lane .value')[1].textContent") or ""),
               browser.eval("document.querySelectorAll('.lane .value')[1].textContent"))

        picker = lambda: browser.eval("document.getElementById('pattern').value")
        option_count = browser.eval("document.getElementById('pattern').options.length")
        groups = browser.eval("Array.from(document.querySelectorAll('#pattern optgroup')).map(g => g.label + ':' + g.children.length)")
        report("picker is filled", groups == ["Rudiments:10", "Grooves:2", "My grooves:1"], groups)
        report("picker has an entry for each pattern", option_count == 14, option_count)
        report("picker shows what's loaded", picker() == "__custom" or picker() == "groove:rock", picker())

        def choose(pattern_id):
            browser.eval("var e = document.getElementById('pattern'); e.value = %s; e.dispatchEvent(new Event('change'));" % json.dumps(pattern_id))
            time.sleep(1.2)
            return read_snapshot(port)[0]

        snap = choose("rudiment:single-paradiddle")
        by_name = {l["name"]: l for l in snap["lanes"]}
        report("choosing a rudiment on the page loads it", snap["pattern"]["name"] == "Single paradiddle", snap["pattern"]["name"])
        report("sticking reaches REAPER's snapshot", snap["pattern"].get("sticking") == "RlrrLrllRlrrLrll", snap["pattern"].get("sticking"))
        report("rudiment scores the snare and mutes the rest", by_name["Snare"]["scoring"] and not by_name["Kick"]["scoring"])
        report("loading a pattern starts fresh stats", by_name["Snare"]["hits"] < 3, by_name["Snare"]["hits"])
        time.sleep(0.5)
        report("picker follows the load", picker() == "rudiment:single-paradiddle", picker())
        report("sticking is on the page", (browser.eval("document.getElementById('sticking').textContent") or "").startswith("Rlrr"),
               browser.eval("document.getElementById('sticking').textContent"))
        report("muted lanes are hidden", browser.eval("document.querySelectorAll('.lane').length") == 1,
               browser.eval("document.querySelectorAll('.lane').length"))
        browser.shot("phone_rudiment")

        snap = choose("user:My funk: 1")
        report("an awkward saved-groove name loads from the page", snap["pattern"]["name"] == "My funk: 1", snap["pattern"]["name"])
        report("a groove has no sticking", snap["pattern"].get("sticking") is None)
        report("sticking leaves the page", browser.eval("document.getElementById('sticking').hidden") is True)
        snap = choose("rudiment:does-not-exist")
        report("an unknown pattern changes nothing", snap["pattern"]["name"] == "My funk: 1", snap["pattern"]["name"])
        snap = choose("groove:rock")
        report("back to the rock beat", snap["pattern"]["name"] == "Rock beat", snap["pattern"]["name"])
        time.sleep(2.5)
        snap = read_snapshot(port)[0]
        report("hits score again after the switch", {l["name"]: l for l in snap["lanes"]}["Snare"]["hits"] >= 1)

        snap = choose("rudiment:single-paradiddle")
        http_get(port, "_/SET/EXTSTATE/LDGMTest/dynamics/on")
        time.sleep(1)
        browser.eval("document.getElementById('reset').click(); document.getElementById('reset').click();")
        time.sleep(6)
        snap = read_snapshot(port)[0]
        snare = {l["name"]: l for l in snap["lanes"]}["Snare"]
        dyn = snare.get("dynamics") or {}
        report("two taps of Reset clear, then the 18 dB self-test reads 18 dB", abs((dyn.get("gap") or 0) - 18.06) < 1, dyn.get("gap"))
        report("no ghosts lost in the self-test", dyn.get("ghost_misses") == 0, dyn.get("ghost_misses"))
        report("timing reads +5 ms alongside it", abs((snare.get("bias") or 0) - 5) < 0.2, snare.get("bias"))
        gap_text = browser.eval("document.querySelector('.gapvalue').textContent")
        report("the gap is on the page", (gap_text or "").startswith("18"), gap_text)
        browser.shot("phone_dynamics")
        browser.resize(1180, 820)
        time.sleep(0.5)
        browser.shot("tablet_dynamics")
        browser.resize(390, 844)

        before = read_snapshot(port)[0]["lanes"][1]["hits"]
        browser.eval("document.getElementById('reset').click();")
        time.sleep(0.6)
        report("one tap of Reset doesn't clear anything", read_snapshot(port)[0]["lanes"][1]["hits"] >= before)
        report("Reset asks for a second tap", browser.eval("document.getElementById('reset').textContent") == "Tap again")

        browser.eval("document.getElementById('stop').click();")
        time.sleep(0.8)
        report("Stop on the page stops the transport", read_snapshot(port)[0]["playing"] is False)
        browser.eval("document.getElementById('play').click();")
        time.sleep(0.8)
        report("Play on the page starts it", read_snapshot(port)[0]["playing"] is True)
        report("no JavaScript errors", not browser.errors, browser.errors)
    finally:
        browser.close()


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
        closed_page = Page(web_port, work, debug_port=19223)
        time.sleep(2.5)
        print("%s  web: page says the dashboard is closed" % ("PASS" if closed_page.eval("document.getElementById('conn').textContent") == "Dashboard closed" else "FAIL"), flush=True)
        closed_page.shot("phone_closed")
    proc.kill()
    if web_port:
        time.sleep(3)
        conn = closed_page.eval("document.getElementById('conn').textContent")
        print("%s  web: an open page says it lost REAPER  [%s]" % ("PASS" if conn == "Can't reach REAPER" else "FAIL", conn), flush=True)
        closed_page.shot("phone_unreachable")
        closed_page.close()


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

    data_dir = os.path.join(res, "Data", "LiveDrumGrooveMonitor")
    os.makedirs(data_dir, exist_ok=True)
    with open(os.path.join(data_dir, "settings.lua"), "w") as f:
        f.write("return { }")
    with open(os.path.join(data_dir, "grooves.lua"), "w") as f:
        f.write('return { { name = "My funk: 1", lanes = { { steps = { 0, 3 }, scoring = true }, '
                '{ steps = { 4, 12 }, scoring = true } } } }')

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
