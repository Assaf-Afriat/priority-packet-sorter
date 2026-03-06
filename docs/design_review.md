# Priority Packet Sorter - Design Review

## Document Information

| Item | Details |
|------|---------|
| Design | Priority Packet Sorter |
| Version | 1.1 |
| Author | Assaf Afriat|
| Status | Complete - Ready for Verification |

---

## 1. Design Overview

The Priority Packet Sorter is an AXI-Stream style module that receives packets with priority levels and outputs them in priority order. Within the same priority, packets maintain FIFO order (first-come, first-served).

### Key Features

- 4 priority levels (0 = highest, 3 = lowest)
- Ready/valid handshaking (AXI-Stream compatible)
- Back-pressure support with no data loss
- Store-and-forward: waits for complete packet before transmit
- Per-priority back-pressure (independent queue management)
- Configurable parameters for reuse

---

## 2. Architecture Block Diagram

```
┌────────────────────────────────────────────────────────────────────────────┐
│                        PRIORITY PACKET SORTER                              │
│                                                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         INPUT STAGE                                 │   │
│  │                                                                     │   │
│  │   pkt_valid ──┬──────────────────────────────────────────┐          │   │
│  │               │                                          │          │   │
│  │   pkt_ready ◄─┼─── ~fifo_almost_full[pkt_priority]       │          │   │
│  │               │                                          ▼          │   │
│  │               │                              ┌────────────────────┐ │   │
│  │   pkt_data ───┼──────────────────────────────┤                    │ │   │
│  │   pkt_id ─────┼──────────────────────────────┤  PACK INTO 16-bit  │ │   │
│  │   pkt_sop ────┼──────────────────────────────┤  fifo_wr_data      │ │   │
│  │   pkt_eop ────┼──────────────────────────────┤                    │ │   │
│  │               │                              └─────────┬──────────┘ │   │
│  │               │                                        │            │   │
│  │               │    input_transfer = valid && ready     │            │   │
│  │               │              │                         │            │   │
│  │               ▼              ▼                         ▼            │   │
│  │         ┌─────────────────────────────────────────────────┐         │   │
│  │         │           PARTIAL PACKET TRACKER                │         │   │
│  │         │  receiving_partial[pkt_priority] = SOP..EOP     │         │   │
│  │         └──────────────────────┬──────────────────────────┘         │   │
│  │                                │                                    │   │
│  │                                ▼                                    │   │
│  │         ┌─────────────────────────────────────────────────┐         │   │
│  │         │              ERROR DETECTION                    │         │   │
│  │         │  • SOP while receiving_partial → error          │         │   │
│  │         │  • Data/EOP without SOP → error, ignore         │         │   │
│  │         └─────────────────┬───────────────────────────────┘         │   │
│  │                           │                                         │   │
│  │                           ▼                                         │   │
│  │         ┌─────────────────────────────────────────────────┐         │   │
│  │         │         WRITE ENABLE (with error filter)        │         │   │
│  │         │  fifo_wr_en = valid_write && input_transfer     │         │   │
│  │         └──────┬──────────┬──────────┬──────────┬─────────┘         │   │
│  │                │          │          │          │                   │   │
│  └────────────────┼──────────┼──────────┼──────────┼───────────────────┘   │
│                   ▼          ▼          ▼          ▼                       │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         FIFO ARRAY                                  │   │
│  │                                                                     │   │
│  │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐            │   │
│  │   │  FIFO 0  │  │  FIFO 1  │  │  FIFO 2  │  │  FIFO 3  │            │   │
│  │   │ Priority │  │ Priority │  │ Priority │  │ Priority │            │   │
│  │   │ HIGHEST  │  │   HIGH   │  │  MEDIUM  │  │  LOWEST  │            │   │
│  │   │          │  │          │  │          │  │          │            │   │
│  │   │ 256 x 16 │  │ 256 x 16 │  │ 256 x 16 │  │ 256 x 16 │            │   │
│  │   └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘            │   │
│  │        │             │             │             │                  │   │
│  │        ▼             ▼             ▼             ▼                  │   │
│  │   complete[0]   complete[1]   complete[2]   complete[3]             │   │
│  │   (EOP count)   (EOP count)   (EOP count)   (EOP count)             │   │
│  │        │             │             │             │                  │   │
│  └────────┼─────────────┼─────────────┼─────────────┼──────────────────┘   │
│           │             │             │             │                      │
│           ▼             ▼             ▼             ▼                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      PRIORITY ARBITER                               │   │
│  │                                                                     │   │
│  │   has_complete[0] ? → selected = 0                                  │   │
│  │   has_complete[1] ? → selected = 1                                  │   │
│  │   has_complete[2] ? → selected = 2                                  │   │
│  │   has_complete[3] ? → selected = 3                                  │   │
│  │                           │                                         │   │
│  │                           ▼                                         │   │
│  │              ┌─────────────────────────┐                            │   │
│  │              │  OUTPUT STATE MACHINE   │                            │   │
│  │              │                         │                            │   │
│  │              │  IDLE ────► TRANSMIT    │                            │   │
│  │              │    ▲            │       │                            │   │
│  │              │    │            │       │                            │   │
│  │              │    └── EOP ─────┘       │                            │   │
│  │              │                         │                            │   │
│  │              │  Lock: active_priority  │                            │   │
│  │              └────────────┬────────────┘                            │   │
│  │                           │                                         │   │
│  └───────────────────────────┼─────────────────────────────────────────┘   │
│                              │                                             │
│                              ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         OUTPUT STAGE                                │   │
│  │                                                                     │   │
│  │   fifo_rd_en[active_priority] = output_transfer                     │   │
│  │                              │                                      │   │
│  │                              ▼                                      │   │
│  │              ┌─────────────────────────┐                            │   │
│  │              │  UNPACK FROM 16-bit     │                            │   │
│  │              │  current_rd_data        │                            │   │
│  │              └────────────┬────────────┘                            │   │
│  │                           │                                         │   │
│  │   out_valid ◄─────────────┼─── (OUT_TRANSMIT && !fifo_empty)        │   │
│  │   out_data ◄──────────────┼─── [7:0]                                │   │
│  │   out_id ◄────────────────┼─── [13:8]                               │   │
│  │   out_sop ◄───────────────┼─── [14]                                 │   │
│  │   out_eop ◄───────────────┼─── [15]                                 │   │
│  │   out_priority ◄──────────┴─── active_priority                      │   │
│  │                                                                     │   │
│  │   out_ready ──────────────────► (from downstream)                   │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Data Flow

### 3.1 Input Path

```
pkt_data[7:0] ─────┐
pkt_id[5:0] ───────┤
pkt_sop ───────────┼───► PACK ───► fifo_wr_data[15:0] ───► FIFO[pkt_priority]
pkt_eop ───────────┘
```

**Packed Format (16 bits):**

```
┌─────────┬─────────┬───────────┬──────────────┐
│   [15]  │   [14]  │  [13:8]   │    [7:0]     │
├─────────┼─────────┼───────────┼──────────────┤
│ pkt_eop │ pkt_sop │  pkt_id   │   pkt_data   │
│  1 bit  │  1 bit  │  6 bits   │    8 bits    │
└─────────┴─────────┴───────────┴──────────────┘
```

### 3.2 Output Path

```
FIFO[active_priority] ───► fifo_rd_data[15:0] ───► UNPACK ───┬► out_data[7:0]
                                                              ├► out_id[5:0]
                                                              ├► out_sop
                                                              └► out_eop

active_priority = out_packet_locked ? locked_priority : selected_priority
```

---

## 4. Module Hierarchy

```
priority_packet_sorter (top)
    │
    ├── sync_fifo [0] (Priority 0 - Highest)
    ├── sync_fifo [1] (Priority 1 - High)
    ├── sync_fifo [2] (Priority 2 - Medium)
    └── sync_fifo [3] (Priority 3 - Lowest)
```

---

## 5. Interface Specification

### 5.1 Input Interface

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| clk | 1 | Input | System clock |
| rst_n | 1 | Input | Async active-low reset |
| pkt_valid | 1 | Input | Input data valid |
| pkt_ready | 1 | Output | Ready to accept data |
| pkt_data | 8 | Input | Input byte data |
| pkt_priority | 2 | Input | Priority (0=highest) |
| pkt_id | 6 | Input | Packet ID |
| pkt_sop | 1 | Input | Start of packet |
| pkt_eop | 1 | Input | End of packet |

### 5.2 Output Interface

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| out_valid | 1 | Output | Output data valid |
| out_ready | 1 | Input | Downstream ready |
| out_data | 8 | Output | Output byte data |
| out_priority | 2 | Output | Priority of packet |
| out_id | 6 | Output | Packet ID |
| out_sop | 1 | Output | Start of packet |
| out_eop | 1 | Output | End of packet |

### 5.3 Status Interface

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| full | 1 | Output | ALL FIFOs full |
| empty | 1 | Output | No complete items |
| almost_full | 1 | Output | ANY queue at threshold |
| fifo_full | 4 | Output | Per-queue full flags |
| fifo_almost_full | 4 | Output | Per-queue almost_full |
| packet_count | 8 | Output | Complete items count |
| priority_status | 4 | Output | Queues with complete items |

### 5.4 Debug Interface

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| debug_fifo_wr_en | 4 | Output | FIFO write enables |
| debug_wr_eop | 4 | Output | EOP write per queue |
| debug_input_transfer | 1 | Output | Input transfer happening |
| debug_valid_write | 1 | Output | Valid write signal |
| debug_receiving_partial | 4 | Output | Per-queue receiving state |
| debug_curr_recv_partial | 1 | Output | Muxed receiving partial |

### 5.5 Error Interface

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| error_sop_without_eop | 1 | Output | SOP received mid-packet (1-cycle pulse) |
| error_data_without_sop | 1 | Output | Data received without SOP (1-cycle pulse) |
| error_eop_without_sop | 1 | Output | EOP received without SOP (1-cycle pulse) |
| error_queue | 4 | Output | Which queue experienced the error |

---

## 6. Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| DATA_WIDTH | 8 | Bits per data byte |
| ID_WIDTH | 6 | Bits for packet ID |
| NUM_PRIORITIES | 4 | Number of priority levels |
| PRIORITY_WIDTH | 2 | Bits for priority field |
| FIFO_DEPTH | 256 | Depth per priority queue |
| ALMOST_FULL_THRESHOLD | 240 | Assert back-pressure |
| ALMOST_FULL_RELEASE | 224 | Release back-pressure |

---

## 7. Functional Description

### 7.1 Packet Reception

1. Upstream asserts `pkt_valid` with data
2. DUT checks `fifo_almost_full[pkt_priority]`
3. If not almost full: `pkt_ready = 1`, transfer occurs
4. Data packed and written to appropriate FIFO
5. On EOP write: `complete_count[priority]++`

### 7.2 Priority Arbitration

1. Check `has_complete[0]` first (highest priority)
2. If not, check `has_complete[1]`, then [2], then [3]
3. First queue with complete packet wins (`selected_priority`)
4. `active_priority` tracks `selected_priority` until first byte transfers
5. After first byte transfers, `locked_priority` locks until EOP

### 7.3 Packet Output

1. Enter `OUT_TRANSMIT` state when `any_complete = 1` (no `out_ready` dependency)
2. `active_priority` = `selected_priority` (continuously re-evaluates during back-pressure)
3. On first `output_transfer`: lock `locked_priority`, set `out_packet_locked = 1`
4. Read from locked queue only on `output_transfer` (valid && ready)
5. Unpack data and drive outputs
6. On EOP read: `complete_count[priority]--`, `out_packet_locked = 0`
7. Always return to `OUT_IDLE` after EOP (arbiter re-evaluates with updated counts)

---

## 8. State Machine

### 8.1 Output State Machine

```
                  any_complete = 1
        ┌─────────────────────────────────┐
        │                                 │
        ▼                                 │
   ┌─────────┐                      ┌─────┴─────┐
   │         │   any_complete = 1   │           │
   │  IDLE   │ ────────────────────►│ TRANSMIT  │
   │         │                      │           │
   └─────────┘                      └─────┬─────┘
        ▲                                 │
        │    EOP transmitted              │
        └─────────────────────────────────┘
                  (always return to IDLE)
```

**Note:** After every EOP, the machine returns to IDLE for one cycle. This gives `complete_count` time to update so the arbiter can correctly select the next highest priority. If more complete packets exist, IDLE → TRANSMIT occurs on the next cycle.

### 8.2 Priority Locking with `active_priority`

```
  active_priority = out_packet_locked ? locked_priority : selected_priority

  ┌──────────────────────────────────────────────────────────────────────┐
  │  OUT_TRANSMIT entered, out_packet_locked = 0                       │
  │                                                                     │
  │  active_priority = selected_priority  (zero-lag, combinational)     │
  │  → Continuously re-evaluates while waiting for out_ready            │
  │  → Higher-priority packet arriving during back-pressure wins        │
  │                                                                     │
  │  First output_transfer occurs:                                      │
  │    locked_priority ← selected_priority                              │
  │    out_packet_locked = 1                                            │
  │                                                                     │
  │  active_priority = locked_priority  (registered, stable)            │
  │  → No priority switch mid-packet, ensures packet integrity          │
  │                                                                     │
  │  EOP transferred → out_packet_locked = 0, return to IDLE            │
  └──────────────────────────────────────────────────────────────────────┘
```

### 8.3 State Descriptions

| State | Description |
|-------|-------------|
| OUT_IDLE | No output, waiting for complete packet |
| OUT_TRANSMIT | Presenting data; locked to `locked_priority` after first byte transfers |

---

## 9. Timing Diagrams

### 9.1 Normal Input Transfer

```
           ___     ___     ___     ___     ___
clk       |   |___|   |___|   |___|   |___|   |
           _______________________
pkt_valid |                       |___________
           _______________________
pkt_ready |                       |___________
                  ^     ^     ^
pkt_data  |  D0  |  D1  |  D2  |
                  ^     ^     ^
            Transfer every cycle (valid && ready)
```

### 9.2 Back-Pressure Scenario

```
           ___     ___     ___     ___     ___     ___     ___
clk       |   |___|   |___|   |___|   |___|   |___|   |___|   |
           _______________________________________________
pkt_valid |                                               |___
           ________                           ____________
pkt_ready |        |_________________________|            |___
                   ^                         ^     ^
pkt_data  |  D0   |  D0   |  D0   |  D0   |  D0  |  D1  |
                   |                         |     |
                   FIFO full,                Space available,
                   pkt_ready=0               D0 transfers, then D1
                   Data held stable
```

### 9.3 Priority Switching

```
           ___     ___     ___     ___     ___     ___     ___
clk       |   |___|   |___|   |___|   |___|   |___|   |___|   |
           _______________________         _________________
out_valid |                       |_______|                 |___

out_data  | P1-D0 | P1-D1 | P1-D2 |  ---  | P0-D0 | P0-D1 |
                              ^       ^
out_eop   __________         _|___    |
                    |_______|     |___|_____________________
                              ^   ^
                    P1 EOP    1-cycle IDLE gap
                    transmitted    (arbiter re-evaluates,
                                   picks P0 as next highest)
```

**Note:** The 1-cycle gap between packets is the IDLE dwell that allows `complete_count` to update and the arbiter to correctly select the next priority.

---

## 10. Memory Usage

| Component | Calculation | Total |
|-----------|-------------|-------|
| Entry width | 16 bits | - |
| Entries per FIFO | 256 | - |
| Bits per FIFO | 16 × 256 | 4,096 bits |
| Number of FIFOs | 4 | - |
| **Total FIFO memory** | 4 × 4,096 | **16,384 bits** |
| Control logic | ~200 FFs estimated | ~200 bits |
| **Total estimated** | - | **~2.1 KB** |

---

## 11. Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Back-pressure | Per-priority | Allow accepting low priority when high is full |
| FIFO type | Synchronous | Single clock domain |
| Packet tracking | EOP counting | Simple, accurate completion detection |
| Priority lock | `out_packet_locked` after first transfer until EOP | No preemption mid-packet, re-evaluates during back-pressure |
| IDLE after EOP | Always return to OUT_IDLE | Gives `complete_count` 1 cycle to update for correct arbiter result |
| Hysteresis | 240/224 thresholds | Prevents ready signal toggling |
| Data packing | 16-bit entries | Single FIFO per queue, synchronized metadata |

---

## 12. Code Organization

| Section | Lines (approx) | Purpose |
|---------|-------|---------|
| Parameters | 18-30 | Configurable values |
| Ports | 31-88 | Input/Output/Status/Error/Debug signals |
| Local Params | 90-98 | Calculated values |
| Internal Signals | 100-131 | Wire declarations |
| Input Transfer | 133-138 | Detect valid transfers |
| Partial Packet Tracking | 140-215 | Track SOP/EOP state per queue |
| Error Detection | 217-302 | Detect and flag malformed packets |
| Back-Pressure | 326-343 | Per-priority ready logic |
| Global Status | 345-362 | full, empty, almost_full |
| Data Packing | 364-377 | Pack 4 fields into 16 bits |
| Write Enable | 379-434 | Route to correct FIFO (with error filter) |
| FIFO Instances | 436-474 | Generate 4 FIFOs |
| Completion Tracking | 476-548 | Count complete packets |
| Priority Arbiter | 550-578 | Select highest priority (combinational) |
| Output State Machine | 580-662 | OUT_IDLE/OUT_TRANSMIT with active_priority |
| Read Enable | 664-688 | Read from active queue on output_transfer |
| Data Unpacking | 690-733 | Extract fields, mux by active_priority |
| Output Valid | 735-748 | Assert when in OUT_TRANSMIT and FIFO not empty |

---

## 13. Files

| File | Description |
|------|-------------|
| `rtl/priority_packet_sorter.sv` | Top-level module |
| `rtl/sync_fifo.sv` | Synchronous FIFO with almost_full |
| `tests/tb_priority_packet_sorter.sv` | Testbench (6 tests) |
| `tests/run_test.sh` | Compile & run script |
| `docs/Axi-Stream.md` | DUT specification |
| `docs/Scheme.md` | Block diagrams (Mermaid) |
| `docs/design_review.md` | This document |
| `docs/fifo.md` | FIFO documentation |
| `docs/rollback.md` | Rollback pointer future enhancement |
| `docs/tests_README.md` | Test documentation |

---

## 14. Error Handling

### 14.1 Error Signals

| Signal | Description |
|--------|-------------|
| `error_sop_without_eop` | SOP received while already receiving a packet |
| `error_data_without_sop` | Data received without starting a packet |
| `error_eop_without_sop` | EOP received without starting a packet |
| `error_queue[3:0]` | Which priority queue experienced the error |

### 14.2 Error Conditions and Actions

| Error | Condition | Detection | Action |
|-------|-----------|-----------|--------|
| SOP without EOP | `pkt_sop && receiving_partial[priority]` | `error_sop_without_eop` pulse | Discard partial, start new packet |
| Data without SOP | `!pkt_sop && !pkt_eop && !receiving_partial[priority]` | `error_data_without_sop` pulse | Ignore data (no FIFO write) |
| EOP without SOP | `pkt_eop && !pkt_sop && !receiving_partial[priority]` | `error_eop_without_sop` pulse | Ignore EOP (no FIFO write) |

### 14.3 Partial Packet State Tracking

```
receiving_partial[i] tracks state per priority queue:

   0 (IDLE) ────────────────────────────────────┐
       │                                        │
       │ SOP (start packet)                     │ SOP && EOP (1-byte packet)
       ▼                                        │
   1 (RECEIVING) ◄──────────────────────────────┘
       │
       │ EOP (end packet)
       ▼
   0 (IDLE)
```

### 14.4 Known Limitation

**SOP mid-packet corruption:**
- When SOP arrives while receiving partial packet, old partial data remains in FIFO
- The FIFO contents become corrupted (partial + new packet mixed)
- Error flag is raised to indicate corruption
- Upstream should not send malformed packets

**Future enhancement:** Add rollback pointers to discard partial packets on error.

---

## 15. Known Limitations

1. ~~**No error handling**~~ ✅ Error handling added
2. **Partial packet rollback** - Cannot cleanly discard partial packets on error
3. **Fixed 4 priorities** - NUM_PRIORITIES parameter exists but arbiter is hardcoded
4. **No cut-through** - Must wait for complete packet (store-and-forward only)
5. **Single clock** - No CDC support

---

## 15. Future Enhancements

- [x] Add error handling for malformed packets
- [ ] Add rollback pointers to discard partial packets on error
- [ ] Parameterize the priority arbiter for N priorities
- [ ] Add optional cut-through mode for low latency
- [ ] Add performance counters (packets per priority, latency)
- [ ] Add CDC support for async interfaces

---

## 16. Review Checklist

| Item | Status | Notes |
|------|--------|-------|
| Specification complete | ✅ | All features defined |
| RTL complete | ✅ | All modules implemented |
| Error handling | ✅ | SOP/EOP error detection added |
| Lint clean | ✅ | No linter errors |
| Simulation | ✅ | 6/6 tests passing (single pkt, FIFO order, priority order, back-pressure, error detection, single-byte) |
| Code coverage | ⏳ | Pending verification |
| Timing closure | ⏳ | Pending synthesis |
| Documentation | ✅ | This document |

---

## 17. Approval

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Designer | Assaf Afriat| 23.2.2026| |
| Reviewer | | | |
| Approver | | | |

