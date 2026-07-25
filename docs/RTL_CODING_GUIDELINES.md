# CORDIC Accelerator — RTL_CODING_GUIDELINES.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Applies To:** All RTL files in `rtl/`

---

## 1. General Principles

| Principle | Rule |
|-----------|------|
| **Synthesizability** | All RTL must be synthesizable by Yosys and commercial tools. No `initial`, `fork/join`, `wait`, or non-constant loops in RTL. |
| **Determinism** | No race conditions. All sequential logic uses `always_ff @(posedge clk)` with synchronous reset. |
| **Parameterization** | All constants from `cordic_pkg.sv`. No hardcoded magic numbers in RTL. |
| **Single Clock Domain** | V1 uses single clock (`clk`). No CDC in V1. |
| **Active-Low Reset** | `rst_n` synchronous, active-low. All registers reset in same cycle. |

---

## 2. Naming Conventions

### 2.1 File Names
| Type | Convention | Example |
|------|------------|---------|
| Module | `snake_case.sv` | `cordic_stage.sv` |
| Package | `snake_case_pkg.sv` | `cordic_pkg.sv` |
| Interface | `snake_case_if.sv` | N/A (not used in V1) |
| Testbench | `snake_case_tb.sv` | `cordic_tb.sv` |
| Constraints | `snake_case.sdc` | `cordic.sdc` |

### 2.2 Signal Names
| Category | Convention | Example |
|----------|------------|---------|
| Inputs | `*_in` or `*_i` | `x_in`, `valid_in` |
| Outputs | `*_out` or `*_o` | `x_out`, `valid_out` |
| Internal Registers | `*_r` or `*_reg` | `valid_r`, `x_reg` |
| Combinational | `*_c` or `*_next` | `x_next`, `valid_c` |
| Parameters | `UPPER_CASE` | `WIDTH`, `ITERATIONS` |
| Localparams | `lower_case` | `max_pos`, `k_factor` |
| Types | `_t` suffix | `fixed_t`, `cordic_cfg_t` |
| Enums | `_e` suffix | `state_e`, `mode_e` |

### 2.3 Module/Package Names
| Scope | Convention | Example |
|-------|------------|---------|
| Module | `snake_case` | `cordic_pipeline` |
| Package | `snake_case_pkg` | `cordic_pkg` |
| Generate blocks | `g_` prefix | `g_stages` |
| Assertions | `assert_` prefix | `assert_valid_ready` |

---

## 3. Module Template

```systemverilog
module module_name #(
  parameter int PARAM_NAME = DEFAULT_VALUE  // From cordic_pkg
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Inputs
  input  logic [WIDTH-1:0]        signal_in,
  input  logic                    valid_in,
  // Outputs
  output logic [WIDTH-1:0]        signal_out,
  output logic                    valid_out
);

  // ------------------------------------------------------------
  // Local parameters / constants
  // ------------------------------------------------------------
  localparam int LOCAL_CONST = PARAM_NAME * 2;

  // ------------------------------------------------------------
  // Type declarations (if needed)
  // ------------------------------------------------------------
  typedef enum logic [1:0] {
    STATE_IDLE  = 2'b00,
    STATE_RUN   = 2'b01,
    STATE_DONE  = 2'b10
  } state_e;

  // ------------------------------------------------------------
  // Registers / State
  // ------------------------------------------------------------
  state_e current_state, next_state;
  logic [WIDTH-1:0] data_reg;
  logic             valid_reg;

  // ------------------------------------------------------------
  // Combinational Logic
  // ------------------------------------------------------------
  always_comb begin
    next_state = current_state;
    case (current_state)
      STATE_IDLE:  if (valid_in) next_state = STATE_RUN;
      STATE_RUN:   next_state = STATE_DONE;
      STATE_DONE:  next_state = STATE_IDLE;
      default:     next_state = STATE_IDLE;
    endcase
  end

  // ------------------------------------------------------------
  // Sequential Logic
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      current_state <= STATE_IDLE;
      data_reg      <= '0;
      valid_reg     <= 1'b0;
    end else begin
      current_state <= next_state;
      case (current_state)
        STATE_IDLE: begin
          if (valid_in) begin
            data_reg  <= signal_in;
            valid_reg <= 1'b1;
          end else begin
            valid_reg <= 1'b0;
          end
        end
        STATE_RUN: begin
          data_reg  <= data_reg + 1;  // Example operation
          valid_reg <= 1'b1;
        end
        STATE_DONE: begin
          valid_reg <= 1'b0;
        end
      endcase
    end
  end

  // ------------------------------------------------------------
  // Outputs
  // ------------------------------------------------------------
  assign signal_out = data_reg;
  assign valid_out  = valid_reg;

  // ------------------------------------------------------------
  // Assertions (bindable)
  // ------------------------------------------------------------
  // SVA assertions in separate bind module (see cordic_assertions.sv)

endmodule
```

---

## 4. Coding Style Rules

### 4.1 Formatting
| Rule | Requirement |
|------|-------------|
| Indentation | 2 spaces (no tabs) |
| Line length | ≤ 120 characters |
| `begin`/`end` | On same line as `if`/`case`/`for` |
| One statement per line | No multiple assignments per line |
| Blank line between | `always_comb`/`always_ff` blocks |

### 4.2 Signal Declaration
```systemverilog
// Preferred: grouped by direction, then type
input  logic                    clk,
input  logic                    rst_n,
input  logic [WIDTH-1:0]        data_in,
input  logic                    valid_in,
output logic [WIDTH-1:0]        data_out,
output logic                    valid_out

// Internal: group registers together
logic [WIDTH-1:0] data_reg;
logic             valid_reg;
logic [WIDTH-1:0] data_next;
```

### 4.3 Assignments
```systemverilog
// Continuous: use assign for simple combinational
assign ready_out = ~valid_reg | ready_in;

// Sequential: always_ff with synchronous reset
always_ff @(posedge clk) begin
  if (!rst_n) reg <= '0;
  else        reg <= next;
end

// Combinational: always_comb
always_comb begin
  next = reg + 1;
end
```

### 4.4 Case Statements
```systemverilog
// Always use full case with default
always_comb begin
  case (state)
    STATE_A: out = in_a;
    STATE_B: out = in_b;
    default: out = '0;  // Synthesis pragmas prevent latches
  endcase
end
```

### 4.5 Parameters
```systemverilog
// Use parameter int with default from package
module my_module #(
  parameter int WIDTH = cordic_pkg::WIDTH,
  parameter int FRACT_W = cordic_pkg::FRACT_W
) (...);
```

---

## 5. Synthesizable Constructs Only

### ✅ ALLOWED
| Construct | Usage |
|-----------|-------|
| `always_ff @(posedge clk)` | Sequential logic |
| `always_comb` | Combinational logic |
| `always_latch` | **NEVER** (latches not allowed) |
| `assign` | Simple combinational |
| `generate`/`genvar` | Parameterized instantiation |
| `if`/`else` | In `always_comb` or `always_ff` |
| `case`/`casez` | In `always_comb` or `always_ff` |
| `for` loops | Constant bounds only (unrolled) |
| `function` | Pure combinational, `automatic` |
| `typedef`/`struct`/`enum` | Type definitions |

### ❌ FORBIDDEN
| Construct | Reason |
|-----------|--------|
| `initial` | Not synthesizable |
| `#delay` | Not synthesizable |
| `fork`/`join` | Not synthesizable |
| `wait` | Not synthesizable |
| `while` loops | Not synthesizable |
| `repeat` with variable | Not synthesizable |
| `force`/`release` | Testbench only |
| `rand`/`randomize` | Testbench only |
| `interface` | Not in V1 (use structs) |

---

## 6. Reset Policy

| Signal Type | Reset Value | Style |
|-------------|-------------|-------|
| Control/Valid | `1'b0` | Synchronous, active-low |
| Data Registers | `'0` | Synchronous, active-low |
| State Machines | `IDLE` state | Synchronous, active-low |
| Output Registers | `'0` | Synchronous, active-low |

```systemverilog
// Standard reset template
always_ff @(posedge clk) begin
  if (!rst_n) begin
    signal_reg <= '0;
    valid_reg  <= 1'b0;
    state_reg  <= STATE_IDLE;
  end else begin
    signal_reg <= signal_next;
    valid_reg  <= valid_next;
    state_reg  <= state_next;
  end
end
```

**No asynchronous resets in datapath.** Control FSM may use async reset if required by flow, but V1 uses sync everywhere.

---

## 7. Parameter Usage

### 7.1 Package Parameters (Single Source)
```systemverilog
// In cordic_pkg.sv
parameter int WIDTH = 16;
parameter int FRACT_W = 12;
parameter int ITERATIONS = 8;

// In module
module my_module #(
  parameter int WIDTH = cordic_pkg::WIDTH,
  parameter int FRACT_W = cordic_pkg::FRACT_W
) (...);
```

### 7.2 Parameter Propagation
```systemverilog
// Top-down propagation
cordic_pipeline #(
  .WIDTH(WIDTH),
  .FRACT_W(FRACT_W),
  .ITERATIONS(ITERATIONS)
) pipe_inst (...);

// Generate-time parameterization
genvar i;
generate
  for (i = 0; i < ITERATIONS; i++) begin : g_stages
    cordic_stage #(
      .WIDTH(WIDTH),
      .FRACT_W(FRACT_W)
    ) stage_inst (
      .stage_idx(i[$clog2(ITERATIONS):0]),
      ...
    );
  end
endgenerate
```

### 7.3 Localparams (Not Overridden)
```systemverilog
localparam int MAX_POS = (1 << (WIDTH-1)) - 1;
localparam int MIN_NEG = -(1 << (WIDTH-1));
localparam int SHIFT_AMT = STAGE_IDX;  // Per-stage constant
```

---

## 8. Lint Rules (Verilator)

### 8.1 Required Clean
```bash
verilator --lint-only -Wall -Wno-UNUSED \
  -Wno-PINCONNECTEMPTY \
  -Wno-DECLFILENAME \
  rtl/*.sv
```

### 8.2 Waived Warnings (Documented)
| Warning | Reason | File |
|---------|--------|------|
| `UNUSED` | Output ports intentionally unused outputs in top-level | `cordic_top.sv` |
| `PINCONNECTEMPTY` | Empty port connections in generate | `cordic_pipeline.sv` |

**No other waivers allowed without Lead approval.**

---

## 9. Documentation Standards

### 9.1 Module Header
```systemverilog
//==============================================================================
// Module: module_name
// Description: Brief one-line description
// Author: Agent-X
// Date: 2026-07-22
// Parameters: WIDTH, FRACT_W, ...
// Interfaces: Input/Output handshake protocol
// Dependencies: cordic_pkg, fp_add_sub, ...
//==============================================================================
```

### 9.2 Signal Comments
```systemverilog
input  logic [WIDTH-1:0]  x_in,    // X input (Q{FRACT_W}.{WIDTH-FRACT_W})
input  logic              valid_in // Input valid (1-cycle pulse)
```

### 9.3 Assertion Comments
```systemverilog
// assert_valid_ready: valid_in |-> ready_out within 2 cycles
// assert_no_latch: all combinational paths covered
```

---

## 10. File Organization

```
rtl/
├── pkg/
│   └── cordic_pkg.sv           // Package (Lead only)
├── common/
│   └── cordic_assertions.sv    // Bindable SVA (Lead only)
├── fp_add_sub.sv               // Agent-A
├── cordic_lut.sv               // Agent-B
├── cordic_stage.sv             // Agent-C
├── cordic_pipeline.sv          // Agent-D
└── cordic_top.sv               // Lead
```

**Ownership:** Each file has single owner (see `CORDIC_IMPLEMENTATION_TRACKER_v2.md`). No shared RTL files.

---

## 11. Verification Hooks

### 11.1 Coverage Points
```systemverilog
// In module (conditional compile)
`ifdef COVERAGE
  covergroup cg_module @(posedge clk);
    cp_valid: coverpoint valid_in;
    cp_ready: coverpoint ready_out;
    cp_sat:   coverpoint sat;
  endgroup
`endif
```

### 11.2 Assertion Binding
```systemverilog
// In cordic_assertions.sv
module cordic_assertions #(...) (...);
// SVA properties here
endmodule

// In each RTL file (at bottom)
`ifdef ASSERT_ON
  cordic_assertions #(
    .WIDTH(WIDTH),
    .ITERATIONS(ITERATIONS)
  ) assertions_inst (...);
`endif
```

---

## 12. Git Workflow

| Rule | Description |
|------|-------------|
| Branch per agent | `wave1/fp_add_sub-agentA`, `wave1/cordic_lut-agentB`, etc. |
| No direct push to master | All changes via PR |
| PR requires | Lint clean, Gate passed, Owner approval |
| Gate reviews | Lead reviews at each gate (see tracker) |

---

## 13. Checklist for Code Review

- [ ] Follows module template
- [ ] All parameters from `cordic_pkg`
- [ ] Synchronous active-low reset
- [ ] No latches (`always_comb` fully covered)
- [ ] No forbidden constructs
- [ ] Verilator lint clean (or waived with comment)
- [ ] Assertions bound (`ASSERT_ON` compile)
- [ ] Coverage groups present (`COVERAGE` compile)
- [ ] Header comment complete
- [ ] Signal comments on all ports
- [ ] Single owner — no shared files

---

**End of RTL_CODING_GUIDELINES.md**  
*All RTL must comply. Non-compliant code rejected at Gate reviews.*