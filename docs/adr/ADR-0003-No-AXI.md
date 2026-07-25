# ADR-0003: No AXI Interfaces in V1

**Status:** ACCEPTED  
**Date:** 2026-07-22  
**Authors:** Principal ASIC Architect, Technical Lead  
**Reviewers:** All Agents  

---

## Context

Initial tracker proposed:
- AXI-Lite for configuration register file (`cordic_regfile.sv`)
- AXI-Stream for data input/output (`cordic_top` ports)

These add significant verification complexity for an undergraduate project.

## Decision

**No AXI in V1.** Use simple valid/ready handshake for data and config.

## Alternatives Considered

| Alternative | Implementation | Verification Burden | Decision |
|-------------|----------------|---------------------|----------|
| **AXI-Lite config** | 5-channel handshake, address map, register file | 50+ cycles protocol compliance, UVM RAL | REJECTED |
| **AXI-Stream data** | TVALID/TREADY, TLAST, TUSER, TKEEP | Protocol compliance, frame handling | REJECTED |
| **Simple valid/ready** | 2 signals per direction | Trivial (2-cycle protocol) | **ACCEPTED** |
| **Pulse-only** | valid=1 for 1 cycle | No backpressure | REJECTED (no flow control) |

## Consequences

### Positive
- **Zero protocol compliance risk** — no AXI VIP needed
- **Trivial verification** — 2-signal handshake, 100% coverage in 10 tests
- **No register file RTL** — config captured in 1 cycle, held in register
- **V2 AXI wrapper isolated** — adds AXI without touching pipeline

### Negative
- **Non-standard interface** — requires adapter for SoC integration
- **No address map** — config is struct, not registers
- **No burst/stream** — single vector per transaction

## V1 Interface (Frozen)

```systemverilog
// Data handshake
input  logic                    valid_in;
output logic                    ready_out;
input  logic signed [WIDTH-1:0] x_in, y_in, z_in;

output logic                    valid_out;
input  logic                    ready_in;
output logic signed [WIDTH-1:0] x_out, y_out, z_out;

// Config handshake
input  logic                    config_valid;
output logic                    config_ready;
input  cordic_cfg_t             cfg;  // struct: iterations, saturate
```

## V2.2 Migration Path

```
V1:                    V2.2:
┌─────────────┐       ┌─────────────────┐
│ cordic_top  │       │ axi_lite_adapter │──► cordic_top (unchanged)
│             │       │                 │
│ valid/ready │◄──────│ TVALID/TREADY   │
│ config_v/r  │◄──────│ AW/AR channels  │
└─────────────┘       └─────────────────┘
```

- `axi_lite_adapter` converts AXI-Lite → simple handshake
- `axi_stream_adapter` converts AXI-Stream → valid/ready
- **Zero changes to V1 pipeline RTL**

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| SoC integration needs AXI | V2.2 delivers adapter in 1 week |
| Config struct changes | Frozen in `cordic_pkg.sv`; V2 extends, not modifies |
| Verification gap | Simple handshake 100% covered; AXI verified in V2.2 |

---

**Sign-off:** Principal Architect ✅ | Technical Lead ✅ | Agent-A ⏳ | Agent-B ⏳ | Agent-C ⏳ | Agent-D ⏳