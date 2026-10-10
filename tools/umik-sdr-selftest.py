#!/usr/bin/env python3
"""
umik-sdr-selftest.py - offline checks for the RTL-SDR recorder's scan parser,
detector, channel picker and SigMF clip files (boot/payload/usr/local/bin/umik-sdr).

    python3 tools/umik-sdr-selftest.py        # add -v for each test's name

No dongle, no network, standard library only. Synthetic rtl_power CSV is laid
out by the recorder's own port of rtl_power's hop planner (umik-sdr --fake
uses the same generator), so rows, bins, duplicated last values, the DC fix
and shifted sweeps look like the real tool's output.
"""
import calendar
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import random
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True      # no __pycache__ next to the payload
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "boot", "payload", "usr", "local", "bin", "umik-sdr")
_loader = importlib.machinery.SourceFileLoader("umik_sdr", SCRIPT)
U = importlib.util.module_from_spec(importlib.util.spec_from_loader("umik_sdr", _loader))
_loader.exec_module(U)

NO_EXCLUDE = []

# The contract's .sigmf-meta global keys, in its order; --fake adds umik:fake after them.
META_GLOBAL_KEYS = [
    "core:datatype", "core:sample_rate", "core:version", "core:num_channels", "core:sha512",
    "core:recorder", "core:hw", "core:description", "core:extensions",
    "umik:unit", "umik:session", "umik:recorder", "umik:boot_id", "umik:clock_trusted",
    "umik:time_source", "umik:started_utc", "umik:ended_utc", "umik:started_iso", "umik:ended_iso",
    "umik:started_mono", "umik:duration_s", "umik:samples", "umik:bytes", "umik:target_hz",
    "umik:center_hz", "umik:offset_hz", "umik:captured_lower_hz", "umik:captured_upper_hz",
    "umik:gain_db", "umik:ppm", "umik:pass", "umik:index", "umik:snr_db", "umik:peak_db",
    "umik:floor_db", "umik:width_khz", "umik:occupancy", "umik:kind", "umik:band",
    "umik:seen_scans", "umik:last_seen_pass", "umik:scan", "umik:source", "umik:software"]


def config(argv=(), env=None):
    """umik-sdr's typed settings from flags and environment, as main() builds them."""
    args = U.build_parser().parse_args(list(argv))
    return U.make_config(U.raw_settings(args, env or {}), args)


def read_json(path):
    with open(path) as fh:
        return json.load(fh)


def read_jsonl(path):
    with open(path) as fh:
        return [json.loads(l) for l in fh]


def iso_seconds(s):
    """'2026-10-10T23:15:02.417Z' -> seconds since the epoch."""
    return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")) + int(s[20:23]) / 1000.0


def scan(emitters, start, stop, bin_khz, sweeps=3, alternate=True, mask_hz=None,
         flatten=True, pass_no=1, seed=7, spur_db=15.0, thr=12.0):
    """One scan of `sweeps` sweeps through the real pipeline -> detections."""
    sc = U.prepare_scan({"name": "t", "start_mhz": start, "stop_mhz": stop, "bin_khz": bin_khz}, 0.0)
    vals = []
    for s in range(sweeps):
        lo, hi = U.sweep_range(sc, alternate and U.sweep_shifted(pass_no, s))
        plan = U.power_plan(lo, hi, sc["bin_hz"], 0.0)
        text = U.fake_power_csv(plan, emitters, sweep=s, pass_no=pass_no, seed=seed + s, spur_db=spur_db)
        rows = U.parse_power_csv(text)
        assert len(rows) == plan["hops"]
        vals.append(U.rows_to_grid(rows, sc["grid"], U.DC_MASK_HZ if mask_hz is None else mask_hz,
                                   flatten=flatten))
    return U.detect("t", sc["grid"], vals, thr)[0]


def sig(mhz, snr=20.0, width=5.0, occ=1.0, peak=None):
    band, kind = U.band_of(mhz * 1e6)
    return {"freq_hz": int(mhz * 1e6), "peak_db": peak if peak is not None else -50.0 + snr,
            "floor_db": -50.0, "snr_db": snr, "width_khz": width, "occupancy": occ,
            "kind": kind, "band": band, "scan": "t"}


class RtlPowerFormat(unittest.TestCase):
    def test_hop_plans_match_rtl_power(self):
        main = U.power_plan(87500000, 1750000000, 50000)
        self.assertEqual((main["hops"], main["bins"], main["bw"]), (594, 64, 2798821))
        self.assertAlmostEqual(main["step"], 43731.578, places=2)
        fm = U.power_plan(87500000, 108000000, 10000)
        self.assertEqual((fm["hops"], fm["bins"]), (8, 512))      # "10k" really is 5 kHz bins
        uhf = U.power_plan(420000000, 480000000, 10000)
        self.assertEqual((uhf["hops"], uhf["bins"]), (22, 512))
        cropped = U.power_plan(87500000, 1750000000, 50000, 0.2)
        self.assertEqual((cropped["hops"], cropped["bins"]), (743, 52))

    def test_shifted_sweep_keeps_the_grid(self):
        for start, stop, khz in ((108, 1750, 50), (87.5, 108, 10), (136, 174, 10), (400, 520, 10),
                                 (87.5, 1750, 50), (420, 480, 10)):
            sc = U.prepare_scan({"name": "t", "start_mhz": start, "stop_mhz": stop, "bin_khz": khz}, 0.0)
            lo, hi = U.sweep_range(sc, True)
            p2 = U.power_plan(lo, hi, sc["bin_hz"])
            self.assertEqual(p2["bw"], sc["plan"]["bw"])
            self.assertEqual(p2["hops"], sc["plan"]["hops"] + 1)
            self.assertLessEqual(lo, start * 1e6)
            self.assertGreaterEqual(hi, stop * 1e6)
            # a quarter hop off: plain centres AND plain edges land well inside shifted hops
            off = (p2["centres"][1] - sc["plan"]["centres"][0]) / sc["plan"]["bw"]
            self.assertAlmostEqual(off, 0.75, places=3)

    def test_row_parse(self):
        # 4 bins + rtl_power's repeated last bin; -inf is an all-zero FFT bin
        text = "2026-10-10, 12:00:00, 100000000, 102000000, 500000.00, 128, -50.00, -inf, -30.00, -40.00, -40.00\n"
        rows = U.parse_power_csv(text + "garbage line\n")
        self.assertEqual(len(rows), 1)
        lo, hi, step, samples, vals = rows[0]
        self.assertEqual((lo, hi, step, samples), (100000000, 102000000, 500000.0, 128))
        self.assertEqual(vals, [-50.0, None, -30.0, -40.0])

    def test_grid_places_bins_by_frequency(self):
        grid = {"f0": 100000000.0, "step": 500000.0, "n": 4}
        rows = [(100000000, 102000000, 500000.0, 128, [-50.0, -45.0, -30.0, -40.0])]
        # mask off: every bin lands where its frequency says
        self.assertEqual(U.rows_to_grid(rows, grid, 0, flatten=False), [-50.0, -45.0, -30.0, -40.0])
        # masked: the Nyquist bin (index 0) and the centre bin (index 2, 101 MHz) with
        # at least one bin either side of it - here that is the whole tiny row
        self.assertEqual(U.rows_to_grid(rows, grid, 1.0, flatten=False), [None, None, None, None])
        wide = {"f0": 100000000.0, "step": 250000.0, "n": 8}
        rows = [(100000000, 102000000, 250000.0, 128, [-50.0, -51.0, -52.0, -45.0, -30.0, -40.0, -41.0, -42.0])]
        self.assertEqual(U.rows_to_grid(rows, wide, 1.0, flatten=False),
                         [None, -51.0, -52.0, None, None, None, -41.0, -42.0])


class Detection(unittest.TestCase):
    def test_30db_carrier_found(self):
        sigs = scan([(146.52, 3.0, 30.0, None, None)], 140, 150, 50)
        self.assertEqual(len(sigs), 1, sigs)
        s = sigs[0]
        step = U.power_plan(140000000, 150000000, 50000)["step"]
        self.assertLessEqual(abs(s["freq_hz"] - 146.52e6), step / 2 + 1)
        self.assertAlmostEqual(s["snr_db"], 30.0, delta=1.5)
        self.assertEqual(s["occupancy"], 1.0)
        self.assertEqual((s["kind"], s["band"]), ("voice", "2 m amateur"))

    def test_dc_spur_bins_are_masked(self):
        # strong spur skirts at every hop centre, never shifted: the mask alone must hide them
        self.assertEqual(scan([], 87.5, 200, 50, alternate=False, spur_db=25.0, flatten=False), [])
        # ... and the test has teeth: unmasked, every hop centre reads as a signal
        raw = scan([], 87.5, 200, 50, alternate=False, spur_db=25.0, flatten=False, mask_hz=0)
        plan = U.power_plan(87500000, 200000000, 50000)
        self.assertEqual(len(raw), plan["hops"])
        for s in raw:
            self.assertLessEqual(min(abs(s["freq_hz"] - c) for c in plan["centres"]), 1.5 * plan["step"])

    def test_spur_past_the_mask_fails_occupancy(self):
        # unmasked, but alternate sweeps shifted: the spur moves, reads intermittent, never a channel
        sigs = scan([], 87.5, 200, 50, spur_db=14.0, flatten=False, mask_hz=0)
        self.assertTrue(sigs)
        self.assertTrue(all(s["occupancy"] < U.CONTINUOUS for s in sigs), sigs)
        self.assertEqual(U.select_signals(sigs, 15.0, NO_EXCLUDE), [])

    def test_weak_carrier_at_a_hop_edge_stays_continuous(self):
        # 14 dB, always on, in the last (rolled-off) bin of a plain hop
        plan = U.power_plan(140000000, 160000000, 50000)
        f = (plan["centres"][3] + (plan["bins"] - 1 - plan["bins"] // 2) * plan["step"]) / 1e6
        em = [(f, 3.0, 14.0, None, None)]
        flat = [s for s in scan(em, 140, 160, 50) if abs(s["freq_hz"] / 1e6 - f) < 0.05]
        self.assertEqual(len(flat), 1)
        self.assertEqual(flat[0]["occupancy"], 1.0)
        # without the roll-off correction the plain sweeps read it ~3 dB short of the threshold
        raw = [s for s in scan(em, 140, 160, 50, flatten=False) if abs(s["freq_hz"] / 1e6 - f) < 0.05]
        self.assertTrue(raw and raw[0]["occupancy"] < U.CONTINUOUS)

    def test_single_sweep_scan(self):
        # UMIK_SDR_SWEEPS=1: no shifted sweep this pass, masked bins stay empty
        sigs = scan([(146.52, 3.0, 30.0, None, None), (744.0, 10000.0, 20.0, None, None)],
                    140, 800, 50, sweeps=1)
        chans = U.select_signals(sigs, 15.0, NO_EXCLUDE)
        self.assertEqual(len(chans), 2, chans)
        self.assertTrue(all(c["occupancy"] == 1.0 for c in chans))

    def test_occupancy_filter(self):
        em = [(150.0, 3.0, 14.0, None, None),     # weak, always on: kept (continuous)
              (152.0, 3.0, 14.0, (1,), None),     # weak, one sweep in three: dropped
              (154.0, 3.0, 20.0, (1,), None)]     # strong, one sweep in three: kept on SNR
        sigs = {round(s["freq_hz"] / 1e6): s for s in scan(em, 145, 160, 50)}
        self.assertEqual(sorted(sigs), [150, 152, 154])
        self.assertEqual(sigs[150]["occupancy"], 1.0)
        self.assertAlmostEqual(sigs[152]["occupancy"], 1 / 3.0, places=2)
        self.assertAlmostEqual(sigs[154]["occupancy"], 1 / 3.0, places=2)
        kept = {round(c["freq_hz"] / 1e6) for c in U.select_signals(list(sigs.values()), 15.0, NO_EXCLUDE)}
        self.assertEqual(kept, {150, 154})

    def test_fm_station_lumps_are_one_channel(self):
        station = [(101.1 + d, 30.0, db, None, None) for d, db in ((-0.06, 26.0), (0.0, 38.0), (0.07, 29.0))]
        bug = [(101.45, 3.0, 18.0, None, None)]   # 350 kHz off the station: its own channel
        fine = scan(station + bug, 87.5, 108, 10)
        coarse = scan(station + bug, 87.5, 120, 50)
        self.assertGreaterEqual(len([s for s in fine if abs(s["freq_hz"] - 101.1e6) <= 100e3]), 3)
        chans = U.select_signals(fine + coarse, 15.0, NO_EXCLUDE)
        self.assertEqual(len(chans), 2, chans)
        near = [c for c in chans if abs(c["freq_hz"] - 101.1e6) <= 100e3]
        self.assertEqual(len(near), 1)
        self.assertEqual(U.iq_rate_for(near[0], 250000, 1024000), 1024000)
        self.assertEqual(len([c for c in chans if abs(c["freq_hz"] - 101.45e6) <= 25e3]), 1)

    def test_lte_block_is_one_channel(self):
        sigs = scan([(744.0, 10000.0, 20.0, None, None)], 700, 800, 50)     # 739-749 MHz
        chans = U.select_signals(sigs, 15.0, NO_EXCLUDE)
        self.assertEqual(len(chans), 1, chans)
        c = chans[0]
        self.assertTrue(739e6 <= c["freq_hz"] <= 749e6, c)
        self.assertEqual(c["kind"], "cellular")
        self.assertGreater(c["width_khz"], 5000)
        self.assertEqual(U.iq_rate_for(c, 250000, 1024000), 250000)      # wide, but not FM

    def test_uhf_tv_channel_is_one_channel(self):
        sigs = scan([(506.0, 6000.0, 22.0, None, None), (503.31, 3.0, 30.0, None, None)], 490, 520, 50)
        chans = U.select_signals(sigs, 15.0, NO_EXCLUDE)
        self.assertEqual(len(chans), 1, chans)
        self.assertEqual(chans[0]["kind"], "broadcast")
        self.assertLessEqual(abs(chans[0]["freq_hz"] - 503.31e6), 25e3)    # at the pilot

    def test_exclusions_apply(self):
        sigs = [sig(710.0, snr=30), sig(720.0, snr=20)]
        kept = U.select_signals(sigs, 15.0, [(698.0, 716.0), (777.0, 787.0), (824.0, 849.0)])
        self.assertEqual([c["freq_hz"] for c in kept], [720000000])
        # an excluded uplink burst must not swallow its neighbour on the way out
        wide = sig(715.9, snr=30, width=600.0)
        kept = U.select_signals([wide, sig(716.2, snr=16)], 15.0, [(698.0, 716.0)])
        self.assertEqual([c["freq_hz"] for c in kept], [716200000])


class Rotation(unittest.TestCase):
    def test_seen_once_stays_remember_once_passes(self):
        r = U.Rotation(8, 2)
        r.update([sig(433.92)], 1)
        self.assertEqual([c["source"] for c in r.plan(1, 120)], ["scan"])
        self.assertEqual([c["source"] for c in r.plan(2, 120)], ["remembered"])
        self.assertEqual(r.plan(3, 120), [])

    def test_seen_twice_stays_remember_passes(self):
        r = U.Rotation(8, 2)
        r.update([sig(433.92)], 1)
        r.update([sig(433.94)], 2)          # 20 kHz off: the same channel
        for p in range(2, 10):
            plan = r.plan(p, 120)
            self.assertEqual(len(plan), 1, p)
            self.assertEqual((plan[0]["seen_scans"], plan[0]["last_seen_pass"]), (2, 2))
        self.assertEqual(r.plan(10, 120), [])

    def test_one_transmitter_twice_in_a_pass_counts_once(self):
        r = U.Rotation(8, 2)
        r.update([sig(433.92, snr=22), sig(433.95, snr=20)], 1)    # main + fine scan, 30 kHz apart
        plan = r.plan(1, 120)
        self.assertEqual(len(plan), 1)
        self.assertEqual(plan[0]["seen_scans"], 1)

    def test_distinct_neighbours_keep_their_own_keys(self):
        r = U.Rotation(8, 2)
        r.update([sig(100.0)], 1)
        r.update([sig(99.92, snr=30), sig(100.08, snr=25)], 2)     # 160 kHz apart, both near the old key
        self.assertEqual(len(r.plan(2, 120)), 2)

    def test_wide_signal_keeps_its_key_as_its_peak_wanders(self):
        r = U.Rotation(8, 2)
        r.update([sig(744.0, width=10000.0)], 1)
        r.update([sig(747.5, width=10000.0)], 2)
        plan = r.plan(2, 120)
        self.assertEqual(len(plan), 1)
        self.assertEqual(plan[0]["seen_scans"], 2)

    def test_cap_keeps_the_strongest(self):
        r = U.Rotation(8, 2)
        r.update([sig(150.0 + i, snr=13.0 + i) for i in range(5)], 1)
        self.assertEqual(sorted(c["snr_db"] for c in r.plan(1, 2)), [16.0, 17.0])


class Pass(unittest.TestCase):
    def test_wide_rate_goes_to_the_fm_channel_only(self):
        # One pass's scans find an FM station and a flat 6 MHz UHF TV channel (no pilot to
        # narrow its measured width). The TV channel measures ~6 MHz wide - under the old
        # "wider than 100 kHz" rule it took the wide rate too; now only the FM one does.
        station = [(104.1 + d, 30.0, db, None, None) for d, db in ((-0.06, 26.0), (0.0, 38.0), (0.07, 29.0))]
        tv = [(539.0, 6000.0, 20.0, None, None)]
        cfg = config()
        sigs = scan(station, 87.5, 108, 10) + scan(tv, 520, 560, 50)
        kept = U.select_signals(sigs, cfg.thr_burst, cfg.exclude)
        plan = U.pass_plan(U.Rotation(cfg.remember_passes, cfg.remember_once), kept, 1, cfg,
                           random.Random(1))
        self.assertEqual(len(plan), 2, plan)
        fm = [c for c in plan if U.in_fm(c["freq_hz"])]
        other = [c for c in plan if not U.in_fm(c["freq_hz"])]
        self.assertEqual((len(fm), len(other)), (1, 1), plan)
        tv = other[0]
        self.assertEqual((tv["kind"], tv["band"]), ("broadcast", "UHF TV (ch 14-36) / wireless mics"))
        self.assertGreater(tv["width_khz"], 5000)
        self.assertEqual((fm[0]["iq_rate"], tv["iq_rate"]), (cfg.iq_rate_wide, cfg.iq_rate))
        self.assertEqual((cfg.iq_rate_wide, cfg.iq_rate), (1024000, 250000))
        # ... and the FM band's gain with it
        self.assertEqual((fm[0]["gain_db"], tv["gain_db"]), (cfg.gain_wide, cfg.gain))
        self.assertEqual((cfg.gain_wide, cfg.gain), (15.7, 37.2))
        self.assertEqual(sorted(c["index"] for c in plan), [1, 2])


class Capture(unittest.TestCase):
    def test_rtl_sdr_block_boundary_is_avoided(self):
        n = U.capture_samples(131072 / 250000.0, 250000)       # exactly one 262144-byte block
        self.assertEqual(n, 131073)
        self.assertNotEqual((2 * n) % U.RTL_SDR_BLOCK, 0)
        self.assertEqual(U.capture_samples(15.3, 1024000), 15667200)

    def test_benign_librtlsdr_chatter_is_not_a_failure(self):
        ok = ("Found 1 device(s):\n  0:  Realtek, RTL2838UHIDIR, SN: 00000001\n"
              "Allocating 15 zero-copy buffers\nFailed to allocate zero-copy buffer for transfer 4\n"
              "Falling back to buffers in userspace\nReading samples in async mode...\n"
              "\nUser cancel, exiting...\n")
        self.assertEqual(U.judge_sdr(0, False, ok), "")
        # one PLL line per open is librtlsdr setting the sample rate before any
        # frequency (every R820T run prints it); two means a tune really failed
        pll = "[R82XX] PLL not locked!\n"
        self.assertEqual(U.judge_sdr(0, False, pll + ok), "")
        self.assertIn("PLL not locked", U.judge_sdr(0, False, pll + ok + pll))
        # libusb on macOS prints this on every open; it only matters with a bad exit
        kd = "Kernel driver is active, or device is claimed by second instance of librtlsdr.\n"
        self.assertEqual(U.judge_sdr(0, False, kd + pll + ok), "")
        self.assertIn("exit 1", U.judge_sdr(1, False, kd + "usb_claim_interface error -6\n"))
        # a bad exit after only the benign lines names the last line, not the PLL chatter
        # (seen 2026-10-10: "rtl_sdr exit 5: [R82XX] PLL not locked!" for a one-off USB error)
        self.assertEqual(U.judge_sdr(5, False, kd + pll + "Tuned to 442424117 Hz.\n"),
                         "rtl_sdr exit 5: Tuned to 442424117 Hz.")
        self.assertIn("sample rate", U.judge_sdr(0, False, "WARNING: Failed to set sample rate.\n"))
        self.assertTrue(U.judge_sdr(1, False, "usb_claim_interface error -6\n"))
        self.assertTrue(U.judge_sdr(0, True, ""))

    def test_rate_rule(self):
        # the wide rate is for the FM band, edges included, and nothing else - however wide
        for mhz, width in ((87.5, 40.0), (104.1, 40.0), (108.0, 200.0)):
            self.assertEqual(U.iq_rate_for(sig(mhz, width=width), 250000, 1024000), 1024000, mhz)
        for mhz, width in ((87.4, 40.0), (108.1, 200.0), (162.55, 12.0), (915.0, 150.0),
                           (539.0, 6000.0), (744.0, 10000.0)):
            self.assertEqual(U.iq_rate_for(sig(mhz, width=width), 250000, 1024000), 250000, mhz)

    def test_gain_rule(self):
        # the FM band's gain goes where its wide rate goes: edges included, however wide
        for mhz, width in ((87.5, 40.0), (104.1, 40.0), (108.0, 200.0)):
            self.assertEqual(U.gain_for(sig(mhz, width=width), 37.2, 15.7), 15.7, mhz)
        for mhz, width in ((87.4, 40.0), (108.1, 200.0), (162.55, 12.0), (915.0, 150.0),
                           (539.0, 6000.0)):
            self.assertEqual(U.gain_for(sig(mhz, width=width), 37.2, 15.7), 37.2, mhz)
        self.assertEqual(U.gain_for(sig(104.1), 37.2, "auto"), "auto")
        self.assertEqual(U.gain_for(sig(162.55), "auto", 15.7), "auto")

    def test_scan_gain_rule(self):
        # a scan takes the FM band's gain only if its whole range is in the band:
        # one that straddles 108 MHz (the old 87.5-1750 main scan) takes the other
        for spec in ("87.5-108:10", "fm=88-100:5"):
            self.assertEqual(U.gain_for(U.parse_scan(spec), 37.2, 15.7), 15.7, spec)
        for spec in ("108-1750:50", "87.5-1750:50", "87.4-108:10", "100-108.1:10", "136-174:10"):
            self.assertEqual(U.gain_for(U.parse_scan(spec), 37.2, 15.7), 37.2, spec)

    def test_clip_base(self):
        t = calendar.timegm((2026, 10, 10, 23, 15, 2)) + 0.417
        self.assertEqual(U.clip_base(t, 104100000), "clip-20261010-231502-104100k")
        self.assertEqual((U.DATA_EXT, U.META_EXT), (".sigmf-data", ".sigmf-meta"))
        self.assertEqual(U.utc_stamp(t), "20261010T231502Z")
        self.assertEqual(U.iso_ms(t), "2026-10-10T23:15:02.417Z")
        # a fraction that rounds up into the next second stays on this one, like the name
        self.assertEqual(U.iso_ms(t - 0.417 + 0.9997), "2026-10-10T23:15:02.999Z")

    def test_fake_iq_carrier_sits_at_minus_a_quarter_rate(self):
        b = U.fake_iq_block()
        iq = [complex(b[i] - 127.5, b[i + 1] - 127.5) for i in range(0, 4096, 2)]
        # mixing by exp(+j 2 pi (rate/4) t) = j^n brings the carrier to DC
        dc = sum(x * (1j ** (n % 4)) for n, x in enumerate(iq)) / len(iq)
        self.assertGreater(abs(dc), 30)


class SigMF(unittest.TestCase):
    # The addendum's worked example, field for field.
    CLIP = {"file": "clip-20261010-231502-104100k.sigmf-data",
            "meta": "clip-20261010-231502-104100k.sigmf-meta",
            "freq_hz": 104100000, "center_hz": 104356000, "offset_hz": 256000, "iq_rate": 1024000,
            "format": "cu8", "gain_db": 25.4, "started_utc": "20261010T231502Z", "started_mono": 1234.5,
            "clock_trusted": True, "duration_s": 15.3, "samples": 15667200, "bytes": 31334400,
            "pass": 1, "index": 7, "snr_db": 31.2, "peak_db": -20.1, "floor_db": -51.3,
            "width_khz": 150.0, "occupancy": 1.0, "kind": "broadcast", "band": "FM broadcast",
            "seen_scans": 3, "last_seen_pass": 1, "scan": "main", "source": "scan"}
    DEVICE = {"usb_id": "0bda:2838", "vendor_id": "0bda", "product_id": "2838", "sdr": "RTL2832U",
              "product": "RTL2838UHIDIR", "manufacturer": "Realtek", "serial": "00000001",
              "tuner": "R820T"}
    T0 = calendar.timegm((2026, 10, 10, 23, 15, 2)) + 0.417

    def sess(self, **kw):
        s = {"unit": "umik1", "session": "umik1-sdr_000003_20261010T230000Z", "boot_id": "1a2b3c4d",
             "time_source": "rtc", "ppm": 0, "hw": U.hw_text(self.DEVICE),
             "software": {"umik_sdr": "1.0", "rtl_sdr": "2.0.2"}, "fake": False}
        s.update(kw)
        return s

    def test_contract_example(self):
        sha = hashlib.sha512(b"the data").hexdigest()
        m = U.sigmf_meta(dict(self.CLIP), self.T0, sha, self.sess())
        want = {
            "global": {
                "core:datatype": "cu8",
                "core:sample_rate": 1024000.0,
                "core:version": "1.0.0",
                "core:num_channels": 1,
                "core:sha512": sha,
                "core:recorder": "umik-sdr 1.0 (pi-airgap-recorder), rtl_sdr 2.0.2",
                "core:hw": "RTL2832U 0bda:2838 Realtek RTL2838UHIDIR serial 00000001, tuner R820T",
                "core:description": "15.3 s of raw IQ around 104.1000 MHz (FM broadcast), captured "
                                    "2026-10-10T23:15:02Z by unit umik1, clock trusted (rtc)",
                "core:extensions": [{"name": "umik", "version": "1.0.0", "optional": True}],
                "umik:unit": "umik1", "umik:session": "umik1-sdr_000003_20261010T230000Z",
                "umik:recorder": "sdr", "umik:boot_id": "1a2b3c4d",
                "umik:clock_trusted": True, "umik:time_source": "rtc",
                "umik:started_utc": "20261010T231502Z", "umik:ended_utc": "20261010T231517Z",
                "umik:started_iso": "2026-10-10T23:15:02.417Z", "umik:ended_iso": "2026-10-10T23:15:17.717Z",
                "umik:started_mono": 1234.5, "umik:duration_s": 15.3, "umik:samples": 15667200,
                "umik:bytes": 31334400,
                "umik:target_hz": 104100000, "umik:center_hz": 104356000, "umik:offset_hz": 256000,
                "umik:captured_lower_hz": 103844000, "umik:captured_upper_hz": 104868000,
                "umik:gain_db": 25.4, "umik:ppm": 0,
                "umik:pass": 1, "umik:index": 7,
                "umik:snr_db": 31.2, "umik:peak_db": -20.1, "umik:floor_db": -51.3, "umik:width_khz": 150.0,
                "umik:occupancy": 1.0, "umik:kind": "broadcast", "umik:band": "FM broadcast",
                "umik:seen_scans": 3, "umik:last_seen_pass": 1, "umik:scan": "main", "umik:source": "scan",
                "umik:software": {"umik_sdr": "1.0", "rtl_sdr": "2.0.2"}},
            "captures": [
                {"core:sample_start": 0, "core:frequency": 104356000.0,
                 "core:datetime": "2026-10-10T23:15:02.417Z"}],
            "annotations": [
                {"core:sample_start": 0, "core:sample_count": 15667200,
                 "core:freq_lower_edge": 104025000.0, "core:freq_upper_edge": 104175000.0,
                 "core:label": "104.1000 MHz FM broadcast", "core:generator": "umik-sdr 1.0",
                 "core:comment": "target channel: scan snr 31.2 dB, width 150.0 kHz, occupancy 1.0"}]}
        self.assertEqual(m, want)
        # ... and in the contract's order, which dict equality does not see
        self.assertEqual(list(m), ["global", "captures", "annotations"])
        self.assertEqual(list(m["global"]), META_GLOBAL_KEYS)
        self.assertEqual(list(m["captures"][0]), list(want["captures"][0]))
        self.assertEqual(list(m["annotations"][0]), list(want["annotations"][0]))
        self.assertEqual(json.loads(json.dumps(m)), want)       # plain JSON all the way down

    def test_auto_gain_untrusted_clock_and_fake(self):
        clip = dict(self.CLIP, gain_db="auto", clock_trusted=False)
        m = U.sigmf_meta(clip, self.T0, "0" * 128,
                         self.sess(time_source="none", fake=True, hw=U.hw_text(self.DEVICE, fake=True)))
        g = m["global"]
        self.assertEqual(g["umik:gain_db"], "auto")
        self.assertEqual((g["umik:clock_trusted"], g["umik:time_source"]), (False, "none"))
        self.assertTrue(g["core:description"].endswith("clock not trusted (none)"), g["core:description"])
        self.assertEqual(list(g), META_GLOBAL_KEYS + ["umik:fake"])
        self.assertIs(g["umik:fake"], True)
        self.assertTrue(g["core:hw"].startswith("FAKE"), g["core:hw"])
        self.assertNotIn("umik:fake", U.sigmf_meta(dict(self.CLIP), self.T0, "0" * 128, self.sess())["global"])


class Leftovers(unittest.TestCase):
    def test_parts_and_orphaned_data_go_pairs_and_the_mic_stay(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdr = os.path.join(tmp, "u1-sdr_000002_20261010T230000Z")
            mic = os.path.join(tmp, "u1_000007_20261010T230000Z")
            os.makedirs(sdr)
            os.makedirs(mic)
            stays = [os.path.join(sdr, n) for n in (
                "clip-a.sigmf-data", "clip-a.sigmf-meta",   # a complete pair
                "clip-f.sigmf-meta",                        # meta alone: not the recorder's call
                "._clip-e.sigmf-data",                      # a Mac's AppleDouble: not a clip
                "clips.jsonl", "session.json")] + \
                [os.path.join(mic, n) for n in ("seg-1.wav.part", "x.sigmf-data")]   # the mic's
            goes = [os.path.join(sdr, n) for n in (
                "clip-b.sigmf-data",                        # cut between the two renames
                "clip-c.sigmf-data", "clip-c.sigmf-meta.part",   # cut while the meta was written
                "clip-d.sigmf-data.part",                   # cut mid-capture
                "scan-p0002-main.csv.gz.part")]
            for p in stays + goes:
                open(p, "wb").close()
            self.assertEqual(U.remove_leftovers(tmp), (3, 2))
            self.assertEqual([p for p in stays if not os.path.exists(p)], [])
            self.assertEqual([p for p in goes if os.path.exists(p)], [])
            self.assertEqual(U.remove_leftovers(tmp), (0, 0))
            self.assertEqual(U.remove_leftovers(os.path.join(tmp, "nowhere")), (0, 0))


class Config(unittest.TestCase):
    def cfg(self, argv, env):
        return config(argv, env)

    def test_flag_beats_env_beats_default(self):
        self.assertEqual(self.cfg([], {}).dwell, 15.0)
        self.assertEqual(self.cfg([], {"UMIK_SDR_DWELL": "9"}).dwell, 9.0)
        self.assertEqual(self.cfg(["--dwell", "3"], {"UMIK_SDR_DWELL": "9"}).dwell, 3.0)
        self.assertEqual(self.cfg([], {"UMIK_SDR_DWELL": ""}).dwell, 15.0)     # empty = default

    def test_scans_and_exclusions(self):
        c = self.cfg([], {})
        self.assertEqual([(s["name"], s["start_mhz"], s["stop_mhz"], s["bin_khz"]) for s in c.scans],
                         [("main", 108.0, 1750.0, 50.0), ("fm", 87.5, 108.0, 10.0),
                          ("vhf", 136.0, 174.0, 10.0), ("uhf", 400.0, 520.0, 10.0)])
        self.assertEqual((c.thr, c.thr_burst), (10.0, 14.0))
        self.assertEqual(c.exclude, [(698.0, 716.0), (777.0, 787.0), (824.0, 849.0), (960.0, 1215.0)])
        c = self.cfg([], {"UMIK_SDR_FINE": "", "UMIK_SDR_EXCLUDE": ""})         # empty = off
        self.assertEqual(([s["name"] for s in c.scans], c.exclude), (["main"], []))
        c = self.cfg(["--fine", "ism=433-435:5", "902-928:10", "903-910:10"], {})
        self.assertEqual([s["name"] for s in c.scans], ["main", "ism", "uhf", "uhf2"])
        self.assertEqual(self.cfg([], {"UMIK_SDR_GAIN": "auto"}).gain, "auto")

    def test_gains(self):
        c = self.cfg([], {})
        self.assertEqual((c.gain, c.gain_wide), (37.2, 15.7))
        self.assertEqual([(s["name"], s["gain"]) for s in c.scans],
                         [("main", 37.2), ("fm", 15.7), ("vhf", 37.2), ("uhf", 37.2)])
        for env in ({"UMIK_SDR_GAIN_WIDE": "auto"}, {"UMIK_SDR_GAIN_WIDE": " Auto "}):
            self.assertEqual(self.cfg([], env).gain_wide, "auto")
        self.assertEqual(self.cfg([], {"UMIK_SDR_GAIN_WIDE": "7.7"}).gain_wide, 7.7)
        self.assertEqual(self.cfg([], {"UMIK_SDR_GAIN_WIDE": ""}).gain_wide, 15.7)     # empty = default
        self.assertEqual(self.cfg(["--gain-wide", "20.7"], {"UMIK_SDR_GAIN_WIDE": "auto"}).gain_wide, 20.7)
        c = self.cfg(["--gain-wide", "auto"], {"UMIK_SDR_GAIN": "40.2"})
        self.assertEqual((c.gain, c.gain_wide), (40.2, "auto"))
        self.assertEqual([s["gain"] for s in c.scans], [40.2, "auto", 40.2, 40.2])
        # a main scan that takes in the FM band straddles 108 MHz: the general gain
        self.assertEqual(self.cfg(["--scan", "87.5-1750:50"], {}).scans[0]["gain"], 37.2)

    def test_bad_values_name_their_knob(self):
        for env, frag in (({"UMIK_SDR_IQ_RATE": "500000"}, "UMIK_SDR_IQ_RATE"),
                          ({"UMIK_SDR_SCAN": "87.5-1750"}, "UMIK_SDR_SCAN"),
                          ({"UMIK_SDR_SWEEPS": "two"}, "UMIK_SDR_SWEEPS"),
                          ({"UMIK_SDR_GAIN_WIDE": "loud"}, "UMIK_SDR_GAIN_WIDE"),
                          ({"UMIK_SDR_GAIN_WIDE": "61"}, "UMIK_SDR_GAIN_WIDE"),
                          ({"UMIK_VID": "27x2"}, "UMIK_VID")):
            with self.assertRaises(U.ConfigError) as cm:
                self.cfg([], env)
            self.assertIn(frag, str(cm.exception))


class EndToEnd(unittest.TestCase):
    """The whole loop in --fake mode: the file layout the Mac-side ingest
    relies on (flat session directory, names, JSON keys, byte counts)."""

    def run_fake(self, tmp, *extra, stop_after=None):
        cmd = [sys.executable, SCRIPT, "--fake", "--data-dir", os.path.join(tmp, "rec"),
               "--unit", "test", "--dwell", "0.3", "--gap-max", "0", "--pass-pause-max", "0",
               "--max-channels", "3"] + list(extra)
        p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                             env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        if stop_after:
            time.sleep(stop_after)
            p.send_signal(signal.SIGTERM)
        _, err = p.communicate(timeout=120)
        return p.returncode, err.decode()

    def session_dir(self, tmp):
        rec = os.path.join(tmp, "rec")
        dirs = sorted(d for d in os.listdir(rec) if not d.startswith("."))
        return os.path.join(rec, dirs[-1]), dirs

    def test_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, err = self.run_fake(tmp, "--passes", "2")
            self.assertEqual(rc, 0, err)
            sdir, dirs = self.session_dir(tmp)
            self.assertEqual(len(dirs), 1)
            self.assertRegex(dirs[0], r"^test-sdr_000001_\d{8}T\d{6}Z$")
            names = sorted(os.listdir(sdir))
            self.assertEqual([n for n in names if n.endswith(".part")], [])
            self.assertTrue(all(os.path.isfile(os.path.join(sdir, n)) for n in names))    # flat
            for p in (1, 2):
                for sc in ("main", "fm", "vhf", "uhf"):
                    self.assertIn("scan-p%04d-%s.csv.gz" % (p, sc), names)
                doc = read_json(os.path.join(sdir, "scan-p%04d.json" % p))
                self.assertEqual(list(doc)[:3], ["pass", "started_utc", "started_mono"])
                self.assertEqual(len(doc["channels"]), 3)
            with open(os.path.join(sdir, "session.json")) as fh:
                text = fh.read()
            sj = json.loads(text)
            for key in ("session", "unit", "recorder", "started_utc", "started_mono", "clock_trusted",
                        "time_source", "gps", "net", "rtc", "time_seed", "storage", "device", "sdr",
                        "software"):
                self.assertIn(key, sj)
            self.assertEqual((sj["session"], sj["recorder"], sj["time_source"]), ("000001", "sdr", "none"))
            self.assertEqual((sj["sdr"]["gain_db"], sj["sdr"]["gain_wide_db"]), (37.2, 15.7))
            self.assertEqual([(s["name"], s["gain_db"]) for s in sj["sdr"]["scans"]],
                             [("main", 37.2), ("fm", 15.7), ("vhf", 37.2), ("uhf", 37.2)])
            # tools/umik-lib.sh json_str reads these line by line
            for line in ('  "unit": "test",', '  "clock_trusted": false,', '  "time_source": "none",'):
                self.assertIn(line, text.splitlines())
            clips = read_jsonl(os.path.join(sdir, "clips.jsonl"))
            self.assertEqual(len(clips), 6)
            self.assertEqual(sorted(c["file"] for c in clips), [n for n in names if n.endswith(".sigmf-data")])
            self.assertEqual(sorted(c["meta"] for c in clips), [n for n in names if n.endswith(".sigmf-meta")])
            self.assertEqual([n for n in names if n.endswith(".cu8")], [])
            for c in clips:
                self.assertTrue(c["ok"])
                self.assertEqual(c["meta"], c["file"][:-len(".sigmf-data")] + ".sigmf-meta")
                self.assertEqual(os.path.getsize(os.path.join(sdir, c["file"])), 2 * c["samples"])
                self.assertEqual(c["center_hz"] - c["freq_hz"], c["iq_rate"] // 4)
            with open(os.path.join(tmp, "logs", "umik.log")) as fh:
                log = fh.read()
            self.assertRegex(log, r"(?m)^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ boot=\S+ up= *\d+s "
                                  r"umik-sdr: session 000001 finished after 2 passes")

    def test_every_clip_is_a_sigmf_pair(self):
        """One whole pass, every channel: the pairs, their meta against their
        data and their clips.jsonl line, and the rate and gain rules through
        run_pass."""
        with tempfile.TemporaryDirectory() as tmp:
            rc, err = self.run_fake(tmp, "--passes", "1", "--max-channels", "120",
                                    "--dwell", "0.1", "--jitter", "0")
            self.assertEqual(rc, 0, err)
            sdir, _ = self.session_dir(tmp)
            names = sorted(os.listdir(sdir))
            doc = read_json(os.path.join(sdir, "scan-p0001.json"))
            plan = doc["channels"]
            clips = read_jsonl(os.path.join(sdir, "clips.jsonl"))
            self.assertGreater(len(plan), 10)
            self.assertEqual(len(clips), len(plan))
            # the wide rate went to the FM band and nowhere else, however wide the rest measured
            for ch in plan:
                self.assertEqual(ch["iq_rate"], 1024000 if U.in_fm(ch["freq_hz"]) else 250000, ch)
            self.assertTrue(any(U.in_fm(ch["freq_hz"]) for ch in plan))
            self.assertTrue(any(not U.in_fm(ch["freq_hz"]) and ch["width_khz"] > 1000 for ch in plan))
            # ... and the FM band's gain with it; a scan gets it only if it lies wholly in the band
            for ch in plan:
                self.assertEqual(ch["gain_db"], 15.7 if U.in_fm(ch["freq_hz"]) else 37.2, ch)
            self.assertTrue(any(400e6 <= ch["freq_hz"] <= 520e6 for ch in plan))
            self.assertEqual([(m["name"], m["gain_db"]) for m in doc["scans"]],
                             [("main", 37.2), ("fm", 15.7), ("vhf", 37.2), ("uhf", 37.2)])
            # two files per clip, and nothing else clip-shaped
            self.assertEqual(sorted(c["file"] for c in clips), [n for n in names if n.endswith(".sigmf-data")])
            self.assertEqual(sorted(c["meta"] for c in clips), [n for n in names if n.endswith(".sigmf-meta")])
            self.assertEqual([n for n in names if n.startswith("clip-")
                              and not n.endswith((".sigmf-data", ".sigmf-meta"))], [])
            for c in clips:
                self.assertTrue(c["ok"])
                m = read_json(os.path.join(sdir, c["meta"]))
                with open(os.path.join(sdir, c["file"]), "rb") as fh:
                    data = fh.read()
                g, caps, anns = m["global"], m["captures"], m["annotations"]
                self.assertEqual(list(m), ["global", "captures", "annotations"])
                self.assertEqual(list(g), META_GLOBAL_KEYS + ["umik:fake"])
                self.assertEqual((g["core:datatype"], g["core:version"], g["core:num_channels"]),
                                 ("cu8", "1.0.0", 1))
                self.assertEqual(len(data), c["bytes"])
                self.assertEqual(g["core:sha512"], hashlib.sha512(data).hexdigest())
                self.assertNotIn("core:dataset", g)
                self.assertEqual(g["core:sample_rate"], float(c["iq_rate"]))
                # the gain it was captured at: the FM band's in the band, the other one elsewhere
                self.assertEqual(g["umik:gain_db"], 15.7 if U.in_fm(c["freq_hz"]) else 37.2, c["freq_hz"])
                # core:frequency is the tuned centre; the target sits offset_hz below it
                self.assertEqual(caps, [{"core:sample_start": 0, "core:frequency": float(c["center_hz"]),
                                         "core:datetime": g["umik:started_iso"]}])
                self.assertEqual(g["umik:target_hz"], c["center_hz"] - c["offset_hz"])
                self.assertEqual((g["umik:captured_lower_hz"], g["umik:captured_upper_hz"]),
                                 (c["center_hz"] - c["iq_rate"] // 2, c["center_hz"] + c["iq_rate"] // 2))
                # ended = started + samples / rate; the second-stamps match the ISO ones and the name
                started, ended = iso_seconds(g["umik:started_iso"]), iso_seconds(g["umik:ended_iso"])
                self.assertAlmostEqual(ended - started, c["samples"] / float(c["iq_rate"]), delta=0.0015)
                self.assertAlmostEqual(ended - started, c["duration_s"], delta=0.0015)
                self.assertEqual(g["umik:started_utc"], U.utc_stamp(int(started)))
                self.assertEqual(g["umik:ended_utc"], U.utc_stamp(int(ended)))
                self.assertEqual(g["umik:started_utc"], c["started_utc"])
                self.assertTrue(c["file"].startswith("clip-%s-%s-" % (c["started_utc"][:8], c["started_utc"][9:15])))
                # the annotation: the whole clip, the channel's measured width around the target
                self.assertEqual(len(anns), 1)
                a = anns[0]
                self.assertEqual((a["core:sample_start"], a["core:sample_count"]), (0, c["samples"]))
                self.assertAlmostEqual(a["core:freq_lower_edge"], c["freq_hz"] - c["width_khz"] * 500.0, delta=0.5)
                self.assertAlmostEqual(a["core:freq_upper_edge"], c["freq_hz"] + c["width_khz"] * 500.0, delta=0.5)
                # every namespace in use is core or declared in core:extensions
                declared = {e["name"] for e in g["core:extensions"]}
                self.assertEqual(declared, {"umik"})
                self.assertTrue(all(e["optional"] is True for e in g["core:extensions"]))
                for obj in [g] + caps + anns:
                    for key in obj:
                        self.assertIn(key.split(":")[0], declared | {"core"}, key)
                # --fake says so
                self.assertIs(g["umik:fake"], True)
                self.assertTrue(g["core:hw"].startswith("FAKE"), g["core:hw"])
                # the line and the meta agree on everything they share
                for key in ("pass", "index", "snr_db", "peak_db", "floor_db", "width_khz", "occupancy",
                            "kind", "band", "seen_scans", "last_seen_pass", "scan", "source", "samples",
                            "bytes", "duration_s", "started_mono", "clock_trusted", "gain_db",
                            "center_hz", "offset_hz"):
                    self.assertEqual(g["umik:" + key], c[key], key)

    def test_sigterm_mid_clip_then_leftovers_swept(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, err = self.run_fake(tmp, "--dwell", "30", stop_after=3)
            self.assertEqual(rc, 0, err)
            self.assertIn("discarded the clip in flight", err)
            self.assertIn("stopped cleanly", err)
            sdir, _ = self.session_dir(tmp)
            self.assertEqual([n for n in os.listdir(sdir) if n.endswith(".part")], [])
            self.assertEqual([n for n in os.listdir(sdir) if n.startswith("clip-")], [])
            # A power cut leaves the clip in flight behind, or - cut between the two
            # renames - a data file whose meta never landed. The next start clears both,
            # and leaves a complete pair alone.
            part = os.path.join(sdir, "clip-20261010-000000-100000k.sigmf-data.part")
            orphan = os.path.join(sdir, "clip-20261010-000001-100000k.sigmf-data")
            pair = [os.path.join(sdir, "clip-20261010-000002-100000k" + ext) for ext in (".sigmf-data", ".sigmf-meta")]
            for p in [part, orphan] + pair:
                open(p, "wb").close()
            rc, err = self.run_fake(tmp, "--passes", "1", "--max-channels", "0")
            self.assertEqual(rc, 0, err)
            self.assertIn("removed 1 stale .part file(s) and 1 .sigmf-data file(s) with no .sigmf-meta "
                          "from earlier sessions", err)
            self.assertFalse(os.path.exists(part))
            self.assertFalse(os.path.exists(orphan))
            self.assertTrue(all(os.path.exists(p) for p in pair))


if __name__ == "__main__":
    unittest.main()
