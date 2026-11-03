import sys
import time
import argparse
from typing import Dict, Any, Callable
from tests.driver_base import WMDriver
from tests.sway_driver import SwayDriver
from tests.hyprland_driver import HyprlandDriver

TESTS: Dict[str, Callable[[WMDriver], None]] = {}

def test_case(name: str):
    def decorator(fn):
        TESTS[name] = fn
        return fn
    return decorator

# ----------------- A. Insertion -----------------

@test_case("A.1 Two windows default orientation")
def test_a1(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    assert d.get_tree_string() == "H[w1, w2*]", f"Got {d.get_tree_string()}"

@test_case("A.2 Consecutive opens append after focused")
def test_a2(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.open_window("w3")
    assert d.get_tree_string() == "H[w1, w2, w3*]", f"Got {d.get_tree_string()}"

@test_case("A.3 Open after left window inserts in middle")
def test_a3(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.focus("left")
    d.open_window("w3")
    assert d.get_tree_string() == "H[w1, w3*, w2]", f"Got {d.get_tree_string()}"

@test_case("A.4 splitv wraps focused leaf into V container")
def test_a4(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")
    assert d.get_tree_string() == "H[w1, V[w2, w3*]]", f"Got {d.get_tree_string()}"

@test_case("A.5 splith inside vertical layout")
def test_a5(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.split("v")
    d.open_window("w2")  # V[w1, w2*]
    d.split("h")
    d.open_window("w3")
    assert d.get_tree_string() == "V[w1, H[w2, w3*]]", f"Got {d.get_tree_string()}"

@test_case("A.6 Container inheritance without explicit wrap")
def test_a6(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.open_window("w4")
    assert d.get_tree_string() == "H[w1, V[w2, w3, w4*]]", f"Got {d.get_tree_string()}"

@test_case("A.7 Open after first child in container")
def test_a7(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.focus("up")        # w2 focused
    d.open_window("w4")
    assert d.get_tree_string() == "H[w1, V[w2, w4*, w3]]", f"Got {d.get_tree_string()}"

# ----------------- B. Movement -----------------

@test_case("B.1 Sibling swap right")
def test_b1(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.focus("left")
    d.move("right")
    assert d.get_tree_string() == "H[w2, w1*]", f"Got {d.get_tree_string()}"

@test_case("B.2 Sibling swap left")
def test_b2(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.move("left")
    assert d.get_tree_string() == "H[w2*, w1]", f"Got {d.get_tree_string()}"

@test_case("B.3 Move into perpendicular container right (descend to focused child)")
def test_b3(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.focus("left")      # w1 focused
    d.move("right")      # w1 moves into V container adjacent to w3
    assert d.get_tree_string() == "H[V[w2, w1*, w3]]", f"Got {d.get_tree_string()}"

@test_case("B.4 Move into perpendicular container with top child focused")
def test_b4(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.focus("up")        # w2 focused
    d.focus("left")      # w1 focused
    d.move("right")      # w1 moves into V container at w2 index
    assert d.get_tree_string() == "H[V[w1*, w2, w3]]", f"Got {d.get_tree_string()}"

@test_case("B.5 Orthogonal promotion left (1-child container persists)")
def test_b5(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.move("left")       # w3 promoted out of V
    assert d.get_tree_string() == "H[w1, w3*, V[w2]]", f"Got {d.get_tree_string()}"

@test_case("B.6 Orthogonal promotion right")
def test_b6(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.split("v")
    d.open_window("w2")
    d.focus("left")      # w1
    d.split("h")         # singleton in V flips to H? No, w1 in V[w1, w2]
    # Build: H[V[w1, w2*], w3]
    d.reset()
    d.open_window("w1")
    d.open_window("w2")  # H[w1, w2*]
    d.focus("left")      # w1
    d.split("v")
    d.open_window("w3")  # H[V[w1, w3*], w2]
    d.move("right")      # w3 promoted right of V
    assert d.get_tree_string() == "H[V[w1], w3*, w2]", f"Got {d.get_tree_string()}"

@test_case("B.7 Workspace reorientation on orthogonal move")
def test_b7(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.split("v")
    d.open_window("w2")  # V[w1, w2*]
    d.focus("up")        # w1
    d.move("left")       # workspace reorients to H, w1 promoted left
    assert d.get_tree_string() == "H[w1*, V[w2]]", f"Got {d.get_tree_string()}"

@test_case("B.8 Edge move noop on single output")
def test_b8(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.focus("left")
    d.move("left")
    assert d.get_tree_string() == "H[w1*, w2]", f"Got {d.get_tree_string()}"

@test_case("B.9 Vertical swap inside container")
def test_b9(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.split("v")
    d.open_window("w2")  # V[w1, w2*]
    d.move("up")
    assert d.get_tree_string() == "V[w2*, w1]", f"Got {d.get_tree_string()}"

# ----------------- C. Focus -----------------

@test_case("C.1 Focus left and right")
def test_c1(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.focus("left")
    assert d.get_tree_string() == "H[w1*, w2]"
    d.focus("right")
    assert d.get_tree_string() == "H[w1, w2*]"

@test_case("C.2 Focus into container descends to last focused child")
def test_c2(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.focus("left")      # w1*
    d.focus("right")     # descends to w3*
    assert d.get_tree_string() == "H[w1, V[w2, w3*]]"

@test_case("C.3 Focus climb out of container")
def test_c3(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.focus("up")        # w2*
    d.focus("left")      # climbs out to w1*
    assert d.get_tree_string() == "H[w1*, V[w2, w3]]"

@test_case("C.4 Focus no-op at deepest parallel container edge")
def test_c4(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.focus("down")      # no-op at bottom of V (no wrap)
    assert d.get_tree_string() == "H[w1, V[w2, w3*]]"

@test_case("C.5 Focus no-op at workspace edge")
def test_c5(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.focus("left")      # w1*
    d.focus("left")      # no-op at left edge (no wrap)
    assert d.get_tree_string() == "H[w1*, w2]"

# ----------------- D. Closure & Reaping -----------------

@test_case("D.1 Close one of two")
def test_d1(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.close_window()
    assert d.get_tree_string() == "H[w1*]"

@test_case("D.2 Close middle window (focus falls to previous focus stack member)")
def test_d2(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.open_window("w3")
    d.focus("left")      # w2*
    d.close_window()
    assert d.get_tree_string() == "H[w1, w3*]", f"Got {d.get_tree_string()}"

@test_case("D.3 Close last window (focus goes to left neighbor)")
def test_d3(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.open_window("w3")  # w3*
    d.close_window()
    assert d.get_tree_string() == "H[w1, w2*]"

@test_case("D.4 1-child container persists on close")
def test_d4(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.close_window()     # closes w3
    assert d.get_tree_string() == "H[w1, V[w2*]]"

@test_case("D.5 Empty container reaped when last child closed")
def test_d5(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.close_window()     # H[w1, V[w2*]]
    d.close_window()     # closes w2, V is empty -> reaped!
    assert d.get_tree_string() == "H[w1*]"

# ----------------- E. Splits & Orientation -----------------

@test_case("E.1 Singleton splitv flips workspace root")
def test_e1(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.split("v")
    d.open_window("w2")
    assert d.get_tree_string() == "V[w1, w2*]"

@test_case("E.2 togglesplit on leaf in H container wraps in V")
def test_e2(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("toggle")
    d.open_window("w3")
    assert d.get_tree_string() == "H[w1, V[w2, w3*]]"

@test_case("E.3 Open after promotion joins 1-child container")
def test_e3(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.split("v")
    d.open_window("w3")  # H[w1, V[w2, w3*]]
    d.move("left")       # H[w1, w3*, V[w2]]
    d.focus("right")     # w2*
    d.open_window("w4")
    assert d.get_tree_string() == "H[w1, w3, V[w2, w4*]]"

@test_case("F.1 Resize grow width")
def test_f1(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.focus("left")  # w1*
    d.resize("grow", "width", "10 ppt")
    t = d.get_tree()
    w1, w2 = t.children[0], t.children[1]
    assert abs(w1.frac - 0.6) < 0.05, f"Expected w1 frac ~0.6, got {w1.frac}"
    assert abs(w2.frac - 0.4) < 0.05, f"Expected w2 frac ~0.4, got {w2.frac}"

@test_case("F.2 Resize shrink width")
def test_f2(d: WMDriver):
    d.reset()
    d.open_window("w1")
    d.open_window("w2")
    d.focus("left")  # w1*
    d.resize("grow", "width", "10 ppt")
    d.resize("shrink", "width", "10 ppt")
    t = d.get_tree()
    w1, w2 = t.children[0], t.children[1]
    assert abs(w1.frac - 0.5) < 0.05, f"Expected w1 frac ~0.5, got {w1.frac}"
    assert abs(w2.frac - 0.5) < 0.05, f"Expected w2 frac ~0.5, got {w2.frac}"


def run_tests(target: str):
    driver: WMDriver
    if target == "sway":
        driver = SwayDriver()
    elif target == "hyprland":
        driver = HyprlandDriver()
    else:
        raise ValueError(f"Unknown target {target}")

    passed = 0
    failed = 0
    print(f"\n================ Running Test Suite on [{target.upper()}] ================")
    start_time = time.time()
    for name, test_fn in TESTS.items():
        print(f"--- Running: {name} ...", end=" ", flush=True)
        try:
            test_fn(driver)
            print("PASS")
            passed += 1
        except Exception as e:
            print(f"FAIL: {e}")
            failed += 1

    total_time = time.time() - start_time
    print(f"\n[{target.upper()}] Results: {passed} passed, {failed} failed in {total_time:.2f}s\n")
    return failed == 0

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=["sway", "hyprland", "both"], default="sway")
    args = parser.parse_args()

    if args.target == "both":
        ok_sway = run_tests("sway")
        ok_hypr = run_tests("hyprland")
        sys.exit(0 if (ok_sway and ok_hypr) else 1)
    else:
        ok = run_tests(args.target)
        sys.exit(0 if ok else 1)
