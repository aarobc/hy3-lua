import json
import subprocess
import time
from typing import Optional
from tests.driver_base import Node, WMDriver

class HyprlandDriver(WMDriver):
    def __init__(self, compose_file: str = "environment/compose.yml"):
        self.compose_file = compose_file

    def _hyprctl(self, *args) -> str:
        cmd = ["docker", "compose", "-f", self.compose_file, "exec", "-T", "hyprland", "hyprctl", *args]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return res.stdout.strip()

    def _repl(self, code: str) -> str:
        # Wrap code in function to ensure reliable return value
        wrapped = f"local function _exec() {code} end return _exec()"
        out = self._hyprctl("repl", wrapped)
        return out

    def reset(self):
        # Close all windows
        for _ in range(30):
            n_str = self._hyprctl("repl", "return #hl.get_windows()")
            try:
                n = int(n_str)
            except ValueError:
                n = 0
            if n == 0:
                break
            self._hyprctl("repl", "for _, w in ipairs(hl.get_windows()) do hl.dispatch(hl.dsp.window.close({window = w})) end")
            time.sleep(0.3)

        # Clear state table in layout
        self._hyprctl("repl", "for k in pairs(_G.hy3dbg.state) do _G.hy3dbg.state[k] = nil end")
        time.sleep(0.2)

    def open_window(self, title: str) -> None:
        self._hyprctl("dispatch", f'hl.dsp.exec_cmd("foot -T {title} -- sleep 3600")')
        for _ in range(40):
            time.sleep(0.1)
            code = f"""
            for _, w in ipairs(hl.get_windows()) do
                if w.title == "{title}" then
                    return "found"
                end
            end
            return "not_found"
            """
            if self._repl(code) == "found":
                break
        else:
            raise TimeoutError(f"Window {title} did not open in Hyprland in time")
        time.sleep(0.2)

    def close_window(self) -> None:
        self._hyprctl("dispatch", "hl.dsp.window.close()")
        time.sleep(0.3)

    def focus(self, direction: str) -> None:
        self._hyprctl("dispatch", f'hl.dsp.layout("focus {direction}")')
        time.sleep(0.15)

    def move(self, direction: str) -> None:
        self._hyprctl("dispatch", f'hl.dsp.layout("move {direction}")')
        time.sleep(0.15)

    def split(self, kind: str) -> None:
        if kind == "toggle":
            cmd = "togglesplit"
        elif kind in ("v", "vertical"):
            cmd = "splitv"
        elif kind in ("h", "horizontal"):
            cmd = "splith"
        else:
            raise ValueError(f"Unknown split kind: {kind}")
        self._hyprctl("dispatch", f'hl.dsp.layout("{cmd}")')
        time.sleep(0.15)

    def resize(self, action: str, direction: str, amount: str = "50px") -> None:
        self._hyprctl("dispatch", f'hl.dsp.layout("resize {action} {direction} {amount}")')
        time.sleep(0.15)

    def get_active_window_title(self) -> Optional[str]:
        out = self._repl("local w = hl.get_active_window(); return w and (w.title or tostring(w.stable_id)) or nil")
        if not out or out == "nil":
            return None
        return out

    def get_tree(self, ws: str = "1") -> Node:
        code = f"""
        local root = _G.hy3dbg.state[{ws}]
        if not root then return '{{"kind":"con","layout":"h","focused":false,"frac":1.0,"children":[]}}' end
        local wins = {{}}
        for _, w in ipairs(hl.get_windows()) do
            wins[tostring(w.stable_id)] = w.title or tostring(w.stable_id)
        end
        local act = hl.get_active_window()
        local act_id = act and tostring(act.stable_id) or nil
        local function ser(n)
            if n.kind == "win" then
                local title = wins[tostring(n.id)] or tostring(n.id)
                local foc = (tostring(n.id) == act_id)
                return string.format('{{"kind":"win","id":%q,"focused":%s,"frac":%f}}', title, tostring(foc), n.frac or 1.0)
            else
                local ch = {{}}
                for _, c in ipairs(n.children or {{}}) do
                    table.insert(ch, ser(c))
                end
                return string.format('{{"kind":"con","layout":%q,"focused":false,"frac":%f,"children":[%s]}}', n.orient or "h", n.frac or 1.0, table.concat(ch, ","))
            end
        end
        local ch = {{}}
        for _, c in ipairs(root.children or {{}}) do
            table.insert(ch, ser(c))
        end
        return string.format('{{"kind":"con","layout":%q,"focused":false,"frac":1.0,"children":[%s]}}', root.layout or "h", table.concat(ch, ","))
        """
        raw_json = self._repl(code)
        try:
            data = json.loads(raw_json)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Failed to parse json from Hyprland: {raw_json}") from e

        def parse(node_dict: dict) -> Node:
            if node_dict["kind"] == "win":
                return Node(
                    kind="win",
                    id=node_dict.get("id"),
                    focused=bool(node_dict.get("focused")),
                    frac=float(node_dict.get("frac", 1.0))
                )
            children = [parse(c) for c in node_dict.get("children", [])]
            return Node(
                kind="con",
                layout=node_dict.get("layout", "h"),
                focused=bool(node_dict.get("focused")),
                frac=float(node_dict.get("frac", 1.0)),
                children=children
            )

        return parse(data)
