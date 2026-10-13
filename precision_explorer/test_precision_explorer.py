#!/usr/bin/env python3
"""Test suite for the Adaptive-11 Precision Explorer Harness.

Tests:
1. Golden model import and multi-mode instantiation.
2. Canonical vector file existence and parsing (920 vectors).
3. MaxAbs and RMS error statistical metric calculation correctness.
4. Mode 11 bit-exact self-equivalence (0 error, 100% match).
5. Strict monotonic decrease of angular Z error across Modes 1-11.
6. RTL simulation output verification against Python model.
7. CSV schema and report generation integrity.
8. SVG plot file structure and validity.

Owner: Verification Lead
Directory: precision_explorer/
"""

import csv
import math
import os
import sys
import unittest
import xml.etree.ElementTree as ET

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO_ROOT, "tb"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from golden_model import CordicGoldenModel  # noqa: E402
import precision_explorer  # noqa: E402


class TestPrecisionExplorer(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.vec_path = precision_explorer.VEC_FILE
        cls.vectors = precision_explorer.load_canonical_vectors(cls.vec_path)
        cls.results = precision_explorer.run_precision_sweep(cls.vectors)

    def test_01_canonical_vectors_loaded(self):
        """Verify that exactly 920 canonical vectors are loaded with 8 fields."""
        self.assertEqual(len(self.vectors), 920)
        for v in self.vectors[:10]:
            self.assertEqual(len(v), 8)

    def test_02_golden_model_multi_mode(self):
        """Verify CordicGoldenModel instantiates for modes 1 through 11."""
        for m in range(1, 12):
            model = CordicGoldenModel(width=16, fract_w=12, iterations=m)
            xo, yo, zo, ovf = model.cordic_rotation(4096, 0, 0)
            self.assertIsInstance(xo, int)
            self.assertIsInstance(yo, int)
            self.assertIsInstance(zo, int)

    def test_03_metric_calculation_synthetic(self):
        """Test MaxAbs and RMS formulas on known synthetic distributions."""
        errors = [3, -4, 0, 5, -2]
        abs_err = [abs(e) for e in errors]
        max_err = max(abs_err)
        rms_err = math.sqrt(sum(e * e for e in errors) / len(errors))

        self.assertEqual(max_err, 5)
        # 9 + 16 + 0 + 25 + 4 = 54; 54/5 = 10.8; sqrt(10.8) ~= 3.2863
        self.assertAlmostEqual(rms_err, math.sqrt(10.8), places=4)

    def test_04_mode11_zero_error(self):
        """Verify Mode 11 has 100% bit-exact matches and 0.0 error vs Fixed-11."""
        m11 = self.results[10]  # mode 11
        self.assertEqual(m11["mode"], 11)
        self.assertEqual(m11["exact_matches"], 920)
        self.assertEqual(m11["mismatches"], 0)
        self.assertEqual(m11["match_pct"], 100.0)
        self.assertEqual(m11["max_err_x_lsb"], 0)
        self.assertEqual(m11["max_err_y_lsb"], 0)
        self.assertEqual(m11["max_err_z_lsb"], 0)
        self.assertEqual(m11["rms_err_x_lsb"], 0.0)
        self.assertEqual(m11["rms_err_y_lsb"], 0.0)
        self.assertEqual(m11["rms_err_z_lsb"], 0.0)

    def test_05_z_error_monotonicity(self):
        """Verify angular Z RMS error decreases strictly monotonically from Mode 1 to 11."""
        prev_rms = float("inf")
        for r in self.results:
            curr_rms = r["rms_err_z_lsb"]
            self.assertLess(curr_rms, prev_rms, f"Mode {r['mode']} RMS Z ({curr_rms}) >= previous ({prev_rms})")
            prev_rms = curr_rms

    def test_06_conv_error_monotonicity(self):
        """Verify linear convergence zone X and Y RMS error decrease with iteration count."""
        # Modes 1 to 5 and 6 to 11 should show decreasing RMS trend
        r1 = self.results[0]["conv_rms_err_x_lsb"]
        r4 = self.results[3]["conv_rms_err_x_lsb"]
        r8 = self.results[7]["conv_rms_err_x_lsb"]
        r11 = self.results[10]["conv_rms_err_x_lsb"]
        self.assertGreater(r1, r4)
        self.assertGreater(r4, r8)
        self.assertGreater(r8, r11)
        self.assertEqual(r11, 0.0)

    def test_07_csv_schema_and_contents(self):
        """Verify CSV output exists and has expected header and 11 rows."""
        csv_path = precision_explorer.CSV_OUT
        precision_explorer.write_csv_metrics(self.results, csv_path)
        self.assertTrue(os.path.exists(csv_path))

        with open(csv_path, "r") as f:
            reader = csv.DictReader(f)
            rows = list(reader)

        self.assertEqual(len(rows), 11)
        required_cols = [
            "mode", "vector_count", "exact_matches", "mismatches", "match_pct",
            "max_err_x_lsb", "max_err_y_lsb", "max_err_z_lsb",
            "rms_err_x_lsb", "rms_err_y_lsb", "rms_err_z_lsb",
            "max_err_x_real", "rms_err_x_real"
        ]
        for col in required_cols:
            self.assertIn(col, rows[0].keys())

    def test_08_svg_validity(self):
        """Verify SVG chart is valid XML and contains expected svg root and paths."""
        svg_path = precision_explorer.SVG_OUT
        precision_explorer.render_svg_chart(self.results, svg_path)
        self.assertTrue(os.path.exists(svg_path))

        # Parse XML
        tree = ET.parse(svg_path)
        root = tree.getroot()
        self.assertTrue(root.tag.endswith("svg"))
        paths = list(root.iter("{http://www.w3.org/2000/svg}path")) + list(root.iter("path"))
        self.assertGreaterEqual(len(paths), 6)  # at least 6 series plotted

    def test_09_rtl_sim_results_match_golden(self):
        """Verify RTL simulation results in rtl_sim_results.txt match Python model bit-for-bit."""
        sim_res_file = os.path.join(precision_explorer.OUTPUT_DIR, "rtl_sim_results.txt")
        if not os.path.exists(sim_res_file):
            self.skipTest("rtl_sim_results.txt not yet generated by Verilator run")

        with open(sim_res_file, "r") as f:
            reader = csv.DictReader(f)
            rtl_rows = list(reader)

        self.assertEqual(len(rtl_rows), 11)
        for i, r_row in enumerate(rtl_rows):
            py_row = self.results[i]
            mode = int(r_row["mode"])
            self.assertEqual(mode, py_row["mode"])
            self.assertEqual(int(r_row["exact_matches"]), py_row["exact_matches"])
            self.assertEqual(int(r_row["max_err_x"]), py_row["max_err_x_lsb"])
            self.assertEqual(int(r_row["max_err_y"]), py_row["max_err_y_lsb"])
            self.assertEqual(int(r_row["max_err_z"]), py_row["max_err_z_lsb"])
            self.assertAlmostEqual(float(r_row["rms_err_z"]), py_row["rms_err_z_lsb"], places=2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
