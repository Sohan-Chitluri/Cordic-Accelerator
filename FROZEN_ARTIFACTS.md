# FROZEN_ARTIFACTS.md — Wave 0 Frozen Hardware & Physical Artifacts

**Freeze Point Tag:** `wave0-freeze`  
**Commit:** `bd7707a`  
**Date:** 2026-10-10  
**Rules:** Measured numbers only. Flow, SDC (2.0 ns input delay) and constraints are frozen. RTL untouched.

This document records the exact cryptographic SHA256 checksums, timestamps (UTC), and file sizes for all physical post-route netlists and extracted parasitics across the fixed reference design family, as well as the golden RTL sources at the freeze tag.

---

## 1. Post-Route Routed Netlists (`cordic_top_routed.v`)

| Design Configuration | Path | SHA256 Checksum | Modification Time (UTC) | Size (Bytes) |
|---|---|---|---|---|
| **Fixed-4** | `output_iter4/cordic_top_routed.v` | `af3573f37d7e15a5e3a1be33796c02d774028e232e0061e1f57c9fa9951405ea` | `2026-09-30T12:20:53.519650+00:00` | 716,559 |
| **Fixed-6** | `output_iter6/cordic_top_routed.v` | `7361e37912d35c71e1ee8b3ca2d54ee0ca3b5dd56fd6cfae958c6e4b81d0be9a` | `2026-10-02T11:06:44.193262+00:00` | 986,019 |
| **Fixed-8 (Baseline)** | `output/cordic_top_routed.v` | `b5d88a5da228421b51fe2a206e78d0078c125cc0fa14852b1c1b9bbbafda0114` | `2026-10-02T11:46:10.913218+00:00` | 1,266,510 |
| **Fixed-9** | `output_iter9/cordic_top_routed.v` | `c544e7745b27fba323e88d0add222177b4e3e77d53d79b7913bc52a4ee52122b` | `2026-10-02T11:13:09.631309+00:00` | 1,424,864 |
| **Fixed-11** | `output_iter11/cordic_top_routed.v` | `310bc24fafe2ff5f349e4b12825f5db59a798dea30818444d408402e644c0f35` | `2026-09-30T12:27:45.791417+00:00` | 1,697,830 |
| **Fixed-12** | `output_iter12/cordic_top_routed.v` | `da1235097359cf29833a8b6b35fb99a80b60f23a4be8146e98c115ec2c9e748c` | `2026-09-30T12:36:02.753407+00:00` | 1,813,848 |

---

## 2. Post-Route Extracted Parasitics (`cordic_top_routed.spef`)

| Design Configuration | Path | SHA256 Checksum | Modification Time (UTC) | Size (Bytes) |
|---|---|---|---|---|
| **Fixed-4** | `output_iter4/cordic_top_routed.spef` | `6421e8d5ffc933a525e2b24f4bfc84ce78b43248599dc5f3742dd54183e6fbb2` | `2026-09-30T12:20:53.520909+00:00` | 3,011,758 |
| **Fixed-6** | `output_iter6/cordic_top_routed.spef` | `c4fdb80cb075b21301b1f5bb191cd01c11638a9257c54a2a10eaced0a82ae21d` | `2026-10-02T11:06:44.193591+00:00` | 4,120,368 |
| **Fixed-8 (Baseline)** | `output/cordic_top_routed.spef` | `3b78dbf47b9eb694416b490256250afd44095ead2e0413212994fb10aa49b95d` | `2026-10-02T11:46:10.907710+00:00` | 5,323,444 |
| **Fixed-9** | `output_iter9/cordic_top_routed.spef` | `52286ed8adc1450b1af9b2b0ebab9d9574391af0ce975da39ad80ac54eacea9f` | `2026-10-02T11:13:09.632227+00:00` | 5,852,657 |
| **Fixed-11** | `output_iter11/cordic_top_routed.spef` | `55498eeef76b203668ee7ce6869e7ee0d4bc7afb36e0d904b76674338b1a4af1` | `2026-09-30T12:27:45.793417+00:00` | 7,119,800 |
| **Fixed-12** | `output_iter12/cordic_top_routed.spef` | `7be8e44e3acdfc3f397ccbde1dcfca262e6fab4970a7791429b654ffeeecac39` | `2026-09-30T12:36:02.755277+00:00` | 7,794,586 |

---

## 3. RTL Source Files at Tag `wave0-freeze`

| Module / Source File | Path | SHA256 Checksum | Modification Time (UTC) | Size (Bytes) |
|---|---|---|---|---|
| `cordic_lut` | `rtl/cordic_lut.sv` | `175431fc7ffdd720ecdc9a6725ceb3f349f0b882f956c898be1cb84bf87c2312` | `2026-09-28T16:44:49.328883+00:00` | 4,001 |
| `cordic_pipeline` | `rtl/cordic_pipeline.sv` | `d4e55ddae16e739aff060ba021ded3cfef85a42f928454f7a8f57f5368067b58` | `2026-09-28T19:57:33.282653+00:00` | 18,596 |
| `cordic_stage` | `rtl/cordic_stage.sv` | `ca1b229e5a0b3239403ca673a5fc41a0d6e50903231c821a45b4d5d2f70c3c90` | `2026-09-28T16:44:49.328883+00:00` | 10,233 |
| `cordic_top` | `rtl/cordic_top.sv` | `d98ee482de980ad09879a7f16b986c4eccd0848e6867229624c0daf9858295d0` | `2026-09-07T16:27:08.422791+00:00` | 2,210 |
| `fp_add_sub` | `rtl/fp_add_sub.sv` | `858d5cb38d2a189331f5fb810f3e0b835cf916307703ee724d9dae0e27fc7e49` | `2026-09-30T02:34:59.231035+00:00` | 3,722 |

---

## 4. Staleness Invariant Verification

For every design configuration in the frozen family:
$$\text{mtime}(\texttt{cordic\_top\_synth.v}) < \text{mtime}(\texttt{cordic\_top\_routed.v}) < \text{mtime}(\texttt{sta\_postroute\_*.rpt})$$
This monotonicity confirms zero cached or stale artifacts were reused across any reporting.
