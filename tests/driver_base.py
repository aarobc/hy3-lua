from dataclasses import dataclass, field
from typing import List, Optional

@dataclass
class Node:
    kind: str  # 'win' or 'con'
    id: Optional[str] = None  # window title/id, e.g. 'w1'
    layout: Optional[str] = None  # 'h' or 'v'
    focused: bool = False
    frac: float = 1.0
    children: List['Node'] = field(default_factory=list)

    def to_canonical_string(self, include_fractions: bool = False) -> str:
        if self.kind == "win":
            f = "*" if self.focused else ""
            frac_str = f" ({self.frac:.4f})" if include_fractions else ""
            return f"{self.id}{f}{frac_str}"
        layout_str = (self.layout or "h").upper()
        f = "*" if self.focused else ""
        c_str = ", ".join(c.to_canonical_string(include_fractions) for c in self.children)
        frac_str = f" ({self.frac:.4f})" if include_fractions else ""
        return f"{layout_str}{f}[{c_str}]{frac_str}"

class WMDriver:
    def reset(self):
        raise NotImplementedError

    def open_window(self, title: str) -> None:
        raise NotImplementedError

    def close_window(self) -> None:
        raise NotImplementedError

    def focus(self, direction: str) -> None:
        raise NotImplementedError

    def move(self, direction: str) -> None:
        raise NotImplementedError

    def split(self, kind: str) -> None:
        """kind in ('v', 'h', 'toggle')"""
        raise NotImplementedError

    def resize(self, action: str, direction: str, amount: str = "50px") -> None:
        """action in ('grow', 'shrink'), direction in ('width', 'height', 'left', 'right', 'up', 'down')"""
        raise NotImplementedError

    def get_tree(self, ws: str = "1") -> Node:
        raise NotImplementedError

    def get_tree_string(self, ws: str = "1", include_fractions: bool = False) -> str:
        return self.get_tree(ws).to_canonical_string(include_fractions)

    def get_active_window_title(self) -> Optional[str]:
        raise NotImplementedError
