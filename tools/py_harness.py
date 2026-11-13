#!/usr/bin/env python3
"""本地 Python 模式的后台进程：游戏通过 127.0.0.1 上的一个 TCP 端口和它说话。

协议：每行一个 JSON。
  请求  {"cmd": "load", "slot": 1, "src": "..."}
        {"cmd": "step", "slot": 1, "dt": 0.016, "sensors": {...}}
        {"cmd": "quit"}
  响应  {"ok": true, ...}
玩家代码跑在自己的 Python 里（朋友局模式），所以这里不做沙箱，
只做"每帧调用一次 loop()"的宿主，外加行数上限防止死循环卡死游戏。
"""
import json
import socket
import sys
import types

MAX_LINES_PER_CALL = 20000
MAX_LOGS = 60


class Budget(Exception):
    pass


def _count_lines(frame, event, arg):
    if event == "line":
        _count_lines.n += 1
        if _count_lines.n > MAX_LINES_PER_CALL:
            raise Budget()
    return _count_lines


_count_lines.n = 0


def _wrap(value):
    if isinstance(value, dict):
        return types.SimpleNamespace(**{k: _wrap(v) for k, v in value.items()})
    if isinstance(value, list):
        return [_wrap(v) for v in value]
    return value


class Slot:
    def __init__(self, src):
        self.controls = {}
        self.logs = []
        self.env = {}
        self.loop = None
        self.started = False
        self.error = ""
        self._install_api()
        try:
            exec(compile(src, "<unit>", "exec"), self.env)
            self.loop = self.env.get("loop")
        except SyntaxError as e:
            self.error = "第 %s 行 语法错误：%s" % (e.lineno or 0, e.msg)
        except Exception as e:
            self.error = "%s: %s" % (type(e).__name__, e)

    def _install_api(self):
        c = self.controls
        env = self.env
        env["mem"] = {}
        env["PI"] = 3.141592653589793

        def set_lift(v):
            c["lift"] = max(0.0, min(1.0, float(v)))

        def set_tilt(pitch=0.0, roll=0.0):
            c["pitch"] = max(-1.0, min(1.0, float(pitch)))
            c["roll"] = max(-1.0, min(1.0, float(roll)))

        def set_rcs(turn=0.0, forward=0.0):
            c["turn"] = max(-1.0, min(1.0, float(turn)))
            c["forward"] = max(-1.0, min(1.0, float(forward)))

        def drill(on=True):
            c["drill"] = bool(on)

        def laser(x, y, z):
            c["laser"] = True
            c["laser_x"], c["laser_y"], c["laser_z"] = float(x), float(y), float(z)

        def laser_off():
            c["laser"] = False

        def shoot(x, y, z):
            c["shoot"] = True
            c["shoot_x"], c["shoot_y"], c["shoot_z"] = float(x), float(y), float(z)

        def go_to(x, y, z):
            c["go_x"], c["go_y"], c["go_z"] = float(x), float(y), float(z)
            c["go"] = True

        def stop():
            c["go"] = False

        def set_velocity(vx, vz):
            c["vx"], c["vz"] = float(vx), float(vz)
            c["vel_mode"] = True

        def set_altitude(y):
            c["alt_target"] = float(y)
            c["alt_mode"] = True

        def transfer(on=True):
            c["transfer"] = bool(on)

        def _missing(name):
            def fn(*_a, **_k):
                raise NotImplementedError("本地 Python 模式暂不支持 %s()" % name)
            return fn

        for name in ("place", "build", "build_here", "produce", "mark",
                     "team_set", "team_get", "command", "get_link"):
            env[name] = _missing(name)
        env["find_path"] = lambda x, y, z: []
        env.update({
            "set_lift": set_lift, "set_tilt": set_tilt, "set_rcs": set_rcs,
            "drill": drill, "laser": laser, "laser_off": laser_off,
            "shoot": shoot, "go_to": go_to, "stop": stop,
            "set_velocity": set_velocity, "set_altitude": set_altitude,
            "transfer": transfer,
            "print": lambda *a, **k: self.logs.append(" ".join(str(x) for x in a)),
        })

    def inject(self, sensors):
        for k, v in sensors.items():
            self.env[k] = _wrap(v)

    def step(self):
        # 注意：必须原地清空，不能重新赋值——API 闭包抓的是同一个 dict
        del self.logs[:]
        self.controls.clear()
        if self.error:
            return
        try:
            if not self.started:
                self.started = True
                start = self.env.get("start")
                if callable(start):
                    start()
            if callable(self.loop):
                _count_lines.n = 0
                sys.settrace(_count_lines)
                try:
                    self.loop()
                finally:
                    sys.settrace(None)
        except Budget:
            self.error = "代码一次执行超过 %d 行，可能是死循环" % MAX_LINES_PER_CALL
        except Exception as e:
            self.error = "%s: %s" % (type(e).__name__, e)


def main():
    port = int(sys.argv[sys.argv.index("--port") + 1])
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    f = s.makefile("rw", encoding="utf-8", newline="\n")
    slots = {}
    for line in f:
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = req.get("cmd")
        if cmd == "quit":
            break
        if cmd == "load":
            slot = int(req["slot"])
            slots[slot] = Slot(req.get("src", ""))
            f.write(json.dumps({"ok": not slots[slot].error,
                                "error": slots[slot].error}) + "\n")
            f.flush()
            continue
        if cmd == "step":
            slot = slots.get(int(req["slot"]))
            if slot is None:
                f.write(json.dumps({"ok": False, "error": "没有这个单位的代码"}) + "\n")
            else:
                slot.inject(req.get("sensors", {}))
                slot.step()
                f.write(json.dumps({
                    "ok": not slot.error,
                    "error": slot.error,
                    "controls": slot.controls,
                    "logs": slot.logs[:MAX_LOGS],
                }) + "\n")
            f.flush()
    for f_ in (f, s):
        try:
            f_.close()
        except OSError:
            pass


if __name__ == "__main__":
    main()
