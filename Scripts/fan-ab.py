#!/usr/bin/env python3
"""
Matched-load A/B for fan policy.

Answers "does my curve actually cool better than firmware?" -- which raw
averages cannot, because the fan only spins when the machine is busy, so any
naive comparison contrasts a loaded machine against an idle one and attributes
the difference to airflow. This runs the SAME synthetic load under each policy
and compares die temperature *binned by CPU power*, so only like is compared
with like.

  python3 Scripts/fan-ab.py --duration 240

Restores the original policy on exit, including on ctrl-c.
"""

import argparse, json, math, multiprocessing as mp, os, signal, socket, sys, time

SOCK = "/var/run/macpulse.sock"
OUT = os.path.expanduser("~/MacPulse/build/fan-ab")


# ---------------------------------------------------------------- socket

def unwrap(v):
    return v.get("_0", v) if isinstance(v, dict) else v


class Daemon:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(5)
        self.s.connect(SOCK)
        self.buf = b""
        self.control = None
        # One generator for the life of the connection. Creating a fresh one
        # per call abandons the previous mid-yield.
        self.frames = self._frames()

    def _frames(self):
        """Yield decoded frames as they arrive."""
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
            try:
                d = self.s.recv(1 << 20)
            except socket.timeout:
                return
            if not d:
                return
            self.buf += d

    def send(self, cmd):
        # Swift synthesises enum-with-payload as {"case": {"_0": ...}}.
        self.s.sendall((json.dumps(cmd) + "\n").encode())

    def set_policy(self, policy, confirm=True, timeout=8):
        self.send({"setPolicy": {"_0": policy}})
        if not confirm:
            return True
        # Frames already in flight still carry the OLD mode, so wait for one
        # that actually reports the requested mode before believing it.
        t0 = time.time()
        for f in self.frames:
            if "control" in f:
                c = unwrap(f["control"])
                self.control = c
                if c["policy"]["mode"] == policy["mode"]:
                    return True
            if time.time() - t0 > timeout:
                return False
        return False

    def wait_control(self, timeout=6):
        t0 = time.time()
        for f in self.frames:
            if "control" in f:
                self.control = unwrap(f["control"])
                return self.control
            if time.time() - t0 > timeout:
                break
        return self.control

    def collect(self, seconds, tag, sink):
        """Record ticks for `seconds`, appending dicts to `sink`."""
        t0 = time.time()
        for f in self.frames:
            if "tick" in f:
                t = unwrap(f["tick"])
                t["_phase"] = tag
                sink.append(t)
            if time.time() - t0 >= seconds:
                return


# ---------------------------------------------------------------- workload

def _burn(stop_at):
    """Integer work only. Deliberately allocation-free: on an 8 GB machine a
    memory-hungry load would measure the swap subsystem, not the cooler."""
    x = 0
    while time.time() < stop_at:
        for _ in range(200000):
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF
    return x


def run_load(seconds, workers):
    stop_at = time.time() + seconds
    procs = [mp.Process(target=_burn, args=(stop_at,)) for _ in range(workers)]
    for p in procs:
        p.start()
    return procs


# ---------------------------------------------------------------- analysis

def analyse(samples, bin_w=500):
    """Bin by CPU power, compare die temp per bin. Only bins populated under
    BOTH policies are reported -- an unmatched bin is exactly the confound
    this whole script exists to avoid."""
    bins = {}
    for s in samples:
        if s.get("dieTempC") is None:
            continue
        b = int(s["cpuPowerMW"] // bin_w) * bin_w
        bins.setdefault(b, {}).setdefault(s["_phase"], []).append(s["dieTempC"])

    rows = []
    for b in sorted(bins):
        g = bins[b]
        if "auto" not in g or "curve" not in g:
            continue
        if len(g["auto"]) < 5 or len(g["curve"]) < 5:
            continue
        a, c = sum(g["auto"]) / len(g["auto"]), sum(g["curve"]) / len(g["curve"])
        rows.append((b, a, len(g["auto"]), c, len(g["curve"]), a - c))
    return rows


def report(samples, rows):
    print("\n" + "=" * 66)
    print("MATCHED-LOAD RESULT — die temp by CPU power bin")
    print("=" * 66)
    if not rows:
        print("  No power bin had >=5 samples under both policies.")
        print("  The two runs did not overlap in load; nothing can be concluded.")
        return
    print(f"  {'CPU power':>12} {'auto':>9} {'curve':>9} {'benefit':>9}")
    tot_w = tot_d = 0.0
    for b, a, na, c, nc, d in rows:
        n = min(na, nc)
        tot_w += n
        tot_d += d * n
        print(f"  {b/1000:5.1f}-{(b+500)/1000:4.1f} W {a:8.1f}C {c:8.1f}C {d:+8.1f}C   "
              f"(n={na}/{nc})")
    print("-" * 66)
    print(f"  Weighted mean benefit of the curve: {tot_d/tot_w:+.2f} °C")
    for tag in ("auto", "curve"):
        g = [s for s in samples if s["_phase"] == tag and s.get("fans")]
        if g:
            print(f"    {tag:5}: mean fan {sum(x['fans'][0]['rpm'] for x in g)/len(g):.0f} rpm")
    print("  Positive benefit = the curve ran cooler at the same power.")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--duration", type=int, default=240, help="seconds of load per phase")
    # 90 s was not enough: the second phase started 5.3 C hotter than the first
    # and that head start swamped the effect being measured. Settle now waits
    # for the die to actually stop falling rather than trusting a timer.
    ap.add_argument("--settle", type=int, default=300, help="max cooldown seconds between phases")
    ap.add_argument("--settle-to", type=float, default=1.0,
                    help="consider settled when die moves <this C over 30s")
    ap.add_argument("--order", default="auto,curve",
                    help="phase order; run the reverse too and average to "
                         "cancel any residual soak bias")
    ap.add_argument("--workers", type=int, default=4, help="burn processes (P-core count)")
    args = ap.parse_args()

    d = Daemon()
    original = d.wait_control()
    if original is None:
        sys.exit("no control state from daemon; is macpulsed running?")
    orig_policy = original["policy"]
    print(f"  current policy: {orig_policy['mode']}")
    if not orig_policy.get("curve"):
        sys.exit("no curve configured — set one in the app first, "
                 "otherwise there is nothing to compare against auto.")

    restored = {"done": False}

    def restore(*_):
        if restored["done"]:
            return
        restored["done"] = True
        try:
            d.set_policy(orig_policy)
            time.sleep(1)
            print(f"\n  restored policy: {orig_policy['mode']}")
        except Exception as e:
            print(f"\n  WARNING: could not restore policy ({e}). "
                  f"Set it manually in the app.", file=sys.stderr)

    signal.signal(signal.SIGINT, lambda *a: (restore(), sys.exit(130)))
    import atexit
    atexit.register(restore)

    samples = []
    curve_policy = dict(orig_policy, mode="curve")
    auto_policy = dict(orig_policy, mode="auto")

    order = [x.strip() for x in args.order.split(",")]
    plans = {"auto": auto_policy, "curve": curve_policy}
    for tag in order:
        policy = plans[tag]
        print(f"\n  [{tag}] applying policy…")
        if not d.set_policy(policy):
            sys.exit(f"daemon did not confirm {tag} policy; aborting rather than "
                     f"measuring an unknown state")
        time.sleep(3)
        print(f"  [{tag}] settling (waiting for die to stop falling, max {args.settle}s)…")
        settle = []
        t0 = time.time()
        while time.time() - t0 < args.settle:
            d.collect(30, f"{tag}-settle", settle)
            temps = [x["dieTempC"] for x in settle[-30:] if x.get("dieTempC")]
            if len(temps) >= 20 and (max(temps) - min(temps)) < args.settle_to:
                break
        t = [x["dieTempC"] for x in settle[-5:] if x.get("dieTempC")]
        print(f"  [{tag}] settled at {sum(t)/len(t):.1f} C after {int(time.time()-t0)}s")
        print(f"  [{tag}] running load on {args.workers} workers for {args.duration}s…")
        procs = run_load(args.duration, args.workers)
        d.collect(args.duration, tag, samples)
        for p in procs:
            p.join(timeout=5)
        n = len([s for s in samples if s["_phase"] == tag])
        print(f"  [{tag}] captured {n} samples")

    restore()

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"run-{int(time.time())}.jsonl")
    with open(path, "w") as f:
        for s in samples:
            f.write(json.dumps(s) + "\n")
    print(f"\n  raw samples: {path}")
    report(samples, analyse(samples))


if __name__ == "__main__":
    main()
