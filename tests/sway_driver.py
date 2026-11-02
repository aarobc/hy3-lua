import json
import subprocess
import time
from typing import Optional
from tests.driver_base import Node, WMDriver

class SwayDriver(WMDriver):
    def __init__(self, compose_file: str = "environment/compose.yml"):
        self.compose_file = compose_file

    def _run_swaymsg(self, *args) -> str:
        cmd = ["docker", "compose", "-f", self.compose_file, "exec", "-T", "sway", "swaymsg", *args]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return res.stdout

    def reset(self):
        # Close all windows
        for _ in range(20):
            t = self._get_raw_tree()
            ws = self._find_ws(t, "1")
            wins = self._collect_windows(ws) if ws else []
            if not wins:
                break
            self._run_swaymsg('[app_id=".*"] kill')
            time.sleep(0.3)

        # Ensure workspace 1 is focused and layout is splith
        self._run_swaymsg("workspace 1")
        self._run_swaymsg("layout splith")
        time.sleep(0.2)

    def _get_raw_tree(self) -> dict:
        out = self._run_swaymsg("-t", "get_tree")
        return json.loads(out)

    def _find_ws(self, node: dict, name: str) -> Optional[dict]:
        if node.get("type") == "workspace" and str(node.get("name")) == name:
            return node
        for child in node.get("nodes", []) + node.get("floating_nodes", []):
            r = self._find_ws(child, name)
            if r:
                return r
        return None

    def _collect_windows(self, node: dict) -> list:
        wins = []
        if node.get("type") == "con" and not node.get("nodes"):
            if node.get("name"):
                wins.append(node["name"])
        for c in node.get("nodes", []) + node.get("floating_nodes", []):
            wins.extend(self._collect_windows(c))
        return wins

    def open_window(self, title: str) -> None:
        self._run_swaymsg("exec", f"foot -T {title} -- sleep 3600")
        for _ in range(30):
            time.sleep(0.1)
            t = self._get_raw_tree()
            ws = self._find_ws(t, "1")
            if ws and title in self._collect_windows(ws):
                break
        else:
            raise TimeoutError(f"Window {title} did not open in Sway in time")
        # Ensure it has focus
        time.sleep(0.1)
        active = self.get_active_window_title()
        if active != title:
            self._run_swaymsg(f'[title="{title}"] focus')
            time.sleep(0.1)

    def close_window(self) -> None:
        self._run_swaymsg("kill")
        time.sleep(0.2)

    def focus(self, direction: str) -> None:
        self._run_swaymsg("focus", direction)
        time.sleep(0.1)

    def move(self, direction: str) -> None:
        self._run_swaymsg("move", direction)
        time.sleep(0.1)

    def split(self, kind: str) -> None:
        if kind == "toggle":
            self._run_swaymsg("split", "toggle")
        elif kind in ("v", "vertical"):
            self._run_swaymsg("splitv")
        elif kind in ("h", "horizontal"):
            self._run_swaymsg("splith")
        else:
            raise ValueError(f"Unknown split kind: {kind}")
        time.sleep(0.1)

    def resize(self, action: str, direction: str, amount: str = "50px") -> None:
        self._run_swaymsg("resize", action, direction, amount)
        time.sleep(0.1)

    def get_active_window_title(self) -> Optional[str]:
        t = self._get_raw_tree()
        def find_focused(n):
            if n.get("focused") and n.get("type") == "con" and not n.get("nodes"):
                return n.get("name")
            for c in n.get("nodes", []) + n.get("floating_nodes", []):
                r = find_focused(c)
                if r:
                    return r
            return None
        return find_focused(t)

    def get_tree(self, ws: str = "1") -> Node:
        raw = self._get_raw_tree()
        ws_node = self._find_ws(raw, ws)
        if not ws_node:
            return Node(kind="con", layout="h", children=[])

        def parse(node: dict) -> Node:
            if node.get("type") == "con" and not node.get("nodes"):
                return Node(
                    kind="win",
                    id=node.get("name"),
                    focused=bool(node.get("focused")),
                    frac=float(node.get("percent") or 1.0)
                )
            layout = "h" if node.get("layout") in ("splith", "output") else "v"
            children = [parse(c) for c in node.get("nodes", [])]
            return Node(
                kind="con",
                layout=layout,
                focused=bool(node.get("focused")),
                frac=float(node.get("percent") or 1.0),
                children=children
            )

        return parse(ws_node)
