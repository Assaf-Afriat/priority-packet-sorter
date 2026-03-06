# Synchronous FIFO Documentation

## Overview

A FIFO (First-In, First-Out) is a memory buffer where data is read in the same order it was written. Think of it like a queue at a store - the first person in line is the first person served.

---

## Architecture

```
        wr_en                              rd_en
          │                                  │
          ▼                                  ▼
    ┌───────────┐                      ┌───────────┐
    │  wr_ptr   │                      │  rd_ptr   │
    │  (write   │                      │  (read    │
    │  address) │                      │  address) │
    └─────┬─────┘                      └─────┬─────┘
          │                                  │
          ▼                                  ▼
    ┌─────────────────────────────────────────────┐
    │                  mem[DEPTH]                 │
    │  [0] [1] [2] [3] ... [253] [254] [255]      │
    │   ▲                              ▲          │
    │   └──── wr_ptr writes here       │          │
    │                    rd_ptr reads here ──────┘│
    └─────────────────────────────────────────────┘
```

---

## Why "Synchronous"?

| Type | Clock Domains | Use Case |
|------|---------------|----------|
| **Synchronous FIFO** | Single clock | Same clock for read and write |
| Asynchronous FIFO | Two clocks | Different clocks for read and write (CDC) |

Our design uses a **synchronous FIFO** because the entire priority sorter operates on a single clock domain.

---

## Key Components

### 1. Memory Array (`mem`)

```systemverilog
logic [DATA_WIDTH-1:0] mem [DEPTH];
```

- Array of registers that stores the actual data
- Size: `DEPTH` entries, each `DATA_WIDTH` bits wide
- Example: 256 entries × 8 bits = 2048 bits total

### 2. Write Pointer (`wr_ptr`)

```systemverilog
logic [ADDR_WIDTH-1:0] wr_ptr;  // For DEPTH=256, this is 8 bits
```

- Points to the **next location to write**
- Increments after each successful write
- Wraps around automatically: 255 + 1 = 0 (due to bit overflow)

### 3. Read Pointer (`rd_ptr`)

```systemverilog
logic [ADDR_WIDTH-1:0] rd_ptr;  // For DEPTH=256, this is 8 bits
```

- Points to the **next location to read**
- Increments after each successful read
- Wraps around automatically: 255 + 1 = 0

### 4. Item Counter (`item_count`)

```systemverilog
logic [ADDR_WIDTH:0] item_count;  // One extra bit! (9 bits for DEPTH=256)
```

- Tracks how many items are currently in the FIFO
- **Extra bit** allows us to distinguish between full (256) and empty (0)
- Without extra bit: `wr_ptr == rd_ptr` could mean full OR empty!

---

## Pointer Behavior

### Circular Buffer Concept

The FIFO operates as a **circular buffer**. Pointers wrap around when they reach the end.

```
Initial state (empty):
    wr_ptr = 0, rd_ptr = 0, count = 0
    
    [_] [_] [_] [_] [_] [_] [_] [_]
     ▲
    wr_ptr
    rd_ptr

After writing A, B, C:
    wr_ptr = 3, rd_ptr = 0, count = 3
    
    [A] [B] [C] [_] [_] [_] [_] [_]
     ▲           ▲
    rd_ptr      wr_ptr

After reading A:
    wr_ptr = 3, rd_ptr = 1, count = 2
    
    [_] [B] [C] [_] [_] [_] [_] [_]
         ▲       ▲
       rd_ptr   wr_ptr

After writing D, E, F, G, H (wrapping):
    wr_ptr = 0, rd_ptr = 1, count = 7
    
    [H] [B] [C] [D] [E] [F] [G] [_]
     ▲   ▲
   wr_ptr rd_ptr
```

---

## Write Logic

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr <= '0;
    end
    else if (wr_en && !full) begin
        mem[wr_ptr] <= wr_data;    // Write data to memory
        wr_ptr <= wr_ptr + 1'b1;   // Move to next slot
    end
end
```

**Key Points:**
- Write only happens when `wr_en` is high AND FIFO is not full
- Data is written to `mem[wr_ptr]`
- Pointer increments AFTER write
- Ignore writes when full (prevents overflow)

---

## Read Logic

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_ptr <= '0;
    end
    else if (rd_en && !empty) begin
        rd_ptr <= rd_ptr + 1'b1;   // Move to next slot
    end
end

assign rd_data = mem[rd_ptr];      // Combinational read
```

**Key Points:**
- Read only happens when `rd_en` is high AND FIFO is not empty
- `rd_data` is **combinational** (available same cycle)
- Pointer increments AFTER read
- Ignore reads when empty (prevents underflow)

---

## Item Counter Logic

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        item_count <= '0;
    end
    else begin
        case ({wr_en && !full, rd_en && !empty})
            2'b10:   item_count <= item_count + 1'b1;  // Write only
            2'b01:   item_count <= item_count - 1'b1;  // Read only
            default: item_count <= item_count;         // Both or neither
        endcase
    end
end
```

**Truth Table:**

| Write | Read | Action | Count Change |
|-------|------|--------|--------------|
| 0 | 0 | Idle | No change |
| 1 | 0 | Write only | +1 |
| 0 | 1 | Read only | -1 |
| 1 | 1 | Both | No change (add and remove cancel out) |

---

## Status Flags

### Full Flag

```systemverilog
assign full = (item_count == DEPTH);  // count == 256
```

- FIFO cannot accept more data
- Writes are ignored when full

### Empty Flag

```systemverilog
assign empty = (item_count == '0);    // count == 0
```

- No data available to read
- Reads are ignored when empty

### Almost Full (with Hysteresis)

```
Count:   0 -------- 224 -------- 240 -------- 256
                     ▲            ▲
                 RELEASE      THRESHOLD

State transitions:
- almost_full = 0: stays 0 until count >= 240, then → 1
- almost_full = 1: stays 1 until count < 224, then → 0
```

**Why Hysteresis?**

Without hysteresis:
```
count = 239 → almost_full = 0 → pkt_ready = 1 → write happens
count = 240 → almost_full = 1 → pkt_ready = 0 → no write
count = 239 → almost_full = 0 → pkt_ready = 1 → write happens
... rapid toggling!
```

With hysteresis:
```
count = 239 → almost_full = 0 → pkt_ready = 1 → write happens
count = 240 → almost_full = 1 → pkt_ready = 0 → no write
count = 239 → almost_full = 1 (stays!) → pkt_ready = 0 → no write
count = 223 → almost_full = 0 → pkt_ready = 1 → stable operation
```

The "dead zone" between 224-239 prevents oscillation.

---

## First-Word Fall-Through (FWFT)

```systemverilog
assign rd_data = mem[rd_ptr];  // Combinational, not registered
```

**Standard FIFO vs FWFT:**

| Type | Behavior | Latency |
|------|----------|---------|
| Standard | Assert `rd_en`, data appears NEXT cycle | 1 cycle |
| **FWFT** | Data available immediately at `rd_data` | 0 cycles |

Our FIFO uses FWFT - the data at `rd_ptr` is always visible on `rd_data`. When you assert `rd_en`, you're acknowledging that data and moving to the next item.

---

## Timing Diagram

### Normal Operation

```
           ___     ___     ___     ___     ___
clk       |   |___|   |___|   |___|   |___|   |
           _______________
wr_en     |               |___________________
                              
wr_data   | A  |  B  |  C  |
          
wr_ptr    | 0  |  1  |  2  |  3  |
          
count     | 0  |  1  |  2  |  3  |
                  ▲     ▲     ▲
              Write A  B     C
```

### Simultaneous Read/Write

```
           ___     ___     ___     ___     ___
clk       |   |___|   |___|   |___|   |___|   |
           _______________________
wr_en     |                       |___________
           _______________________
rd_en     |                       |___________
                              
wr_data   | D  |  E  |  F  |
          
rd_data   | A  |  B  |  C  |

count     | 3  |  3  |  3  |  3  |   (no change!)
                  ▲
            Read and write same cycle
```

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DATA_WIDTH` | 8 | Width of each data entry (bits) |
| `DEPTH` | 256 | Number of entries |
| `ALMOST_FULL_THRESHOLD` | 240 | Assert almost_full when count >= this |
| `ALMOST_FULL_RELEASE` | 224 | Deassert almost_full when count < this |

---

## Usage in Priority Packet Sorter

### Data Packing

In the priority sorter, we don't store just 8-bit data. We **pack** multiple fields into each FIFO entry:

```systemverilog
localparam FIFO_DATA_WIDTH = DATA_WIDTH + ID_WIDTH + 1 + 1;  // 8 + 6 + 1 + 1 = 16 bits

assign fifo_wr_data = {pkt_eop, pkt_sop, pkt_id, pkt_data};
```

**Packed Entry Format (16 bits):**

```
┌─────────┬─────────┬───────────┬──────────────┐
│   [15]  │   [14]  │  [13:8]   │    [7:0]     │
├─────────┼─────────┼───────────┼──────────────┤
│ pkt_eop │ pkt_sop │  pkt_id   │   pkt_data   │
│  1 bit  │  1 bit  │  6 bits   │    8 bits    │
└─────────┴─────────┴───────────┴──────────────┘
     MSB                                  LSB
```

### Example: Complete Item Flow

**Input: Priority 0 item with 22 bytes (header + 21 payload)**

| Cycle | pkt_data | pkt_id | pkt_sop | pkt_eop | FIFO Entry (16 bits) |
|-------|----------|--------|---------|---------|----------------------|
| 1 | 0x41 | 1 | **1** | 0 | `0_1_000001_01000001` (Header/SOP) |
| 2 | 0x01 | 1 | 0 | 0 | `0_0_000001_00000001` (Payload) |
| 3 | 0x02 | 1 | 0 | 0 | `0_0_000001_00000010` (Payload) |
| ... | ... | 1 | 0 | 0 | ... |
| 22 | 0x15 | 1 | 0 | **1** | `1_0_000001_00010101` (Last/EOP) |

**FIFO[0] State After Item:**

```
Priority 0 FIFO (22 entries written):

Index   Entry Value              EOP  SOP  ID   DATA    Description
──────────────────────────────────────────────────────────────────
[0]     0_1_000001_01000001      0    1    1    0x41    Header (SOP=1)
[1]     0_0_000001_00000001      0    0    1    0x01    Payload byte 1
[2]     0_0_000001_00000010      0    0    1    0x02    Payload byte 2
...     ...                      ...  ...  ...  ...     ...
[21]    1_0_000001_00010101      1    0    1    0x15    Last byte (EOP=1)
                                 ▲
                                 │
                       EOP triggers complete_count++
```

### Unpacking on Read

When reading from FIFO, extract each field:

```systemverilog
// Unpack the read data
assign out_data = fifo_rd_data[selected_priority][7:0];    // Data byte
assign out_id   = fifo_rd_data[selected_priority][13:8];   // Packet ID
assign out_sop  = fifo_rd_data[selected_priority][14];     // Start of packet
assign out_eop  = fifo_rd_data[selected_priority][15];     // End of packet
```

### Memory Usage

| Component | Calculation | Total |
|-----------|-------------|-------|
| Entry width | 16 bits | - |
| Entries per FIFO | 256 | - |
| Bits per FIFO | 16 × 256 | 4,096 bits |
| Number of FIFOs | 4 (one per priority) | - |
| **Total memory** | 4 × 4,096 | **16,384 bits (2 KB)** |

---

## Interface Summary

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `clk` | 1 | Input | Clock |
| `rst_n` | 1 | Input | Async active-low reset |
| `wr_en` | 1 | Input | Write enable |
| `wr_data` | DATA_WIDTH | Input | Data to write |
| `rd_en` | 1 | Input | Read enable (acknowledge) |
| `rd_data` | DATA_WIDTH | Output | Data to read (FWFT) |
| `full` | 1 | Output | FIFO is full |
| `empty` | 1 | Output | FIFO is empty |
| `almost_full` | 1 | Output | At threshold (with hysteresis) |
| `count` | $clog2(DEPTH)+1 | Output | Current item count |

