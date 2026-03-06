# AXI-Stream Priority Packet Sorter

**Source:** Mock Interview

### Overview

A priority-based packet organizer that receives incoming packets and stores them in a FIFO structure sorted by priority level. Within the same priority, packets maintain FIFO order (first-come, first-served).

See [Scheme.md](Scheme.md) for block diagrams.

---

### Specifications

#### Packet Structure

| Field       | Width   | Description                                      |
|-------------|---------|--------------------------------------------------|
| Header      | 8 bits  | Contains priority and packet length info         |
| Payload     | N × 8 bits | Variable number of 8-bit data packets         |

**Header Byte Breakdown:**

| Bits  | Field          | Description                               |
|-------|----------------|-------------------------------------------|
| [7:6] | Priority       | 2-bit priority code (0=highest, 3=lowest) |
| [5:0] | Packet ID      | 6-bit unique packet identifier (0-63)     |

#### Sequence Item

| Parameter        | Value        | Notes                                    |
|------------------|--------------|------------------------------------------|
| Total Length     | 1-256 bytes  | Header + Payload (indices 0-255)         |
| Header Size      | 1 byte       | First byte of sequence item              |
| Payload Size     | 0-255 bytes  | Remaining bytes after header             |
| Byte Width       | 8 bits       | Each packet/byte is 8 bits wide          |
| Length Detection | EOP signal   | Packet ends when EOP is asserted         |

#### Priority Levels

| Code | Priority | Description          |
|------|----------|----------------------|
| 0    | Highest  | Critical/Real-time   |
| 1    | High     | Important            |
| 2    | Medium   | Normal               |
| 3    | Lowest   | Best-effort          |

#### FIFO Parameters

| Parameter    | Value      | Description                              |
|--------------|------------|------------------------------------------|
| Depth        | 256 each   | 256 cells per priority queue (0-255)     |
| Total Depth  | 1024       | 4 queues × 256 = 1024 total cells        |
| Data Width   | 8 bits     | Each cell holds one byte                 |
| Organization | 4 queues   | One queue per priority level             |

#### Overflow Behavior

| Condition      | Behavior                                           |
|----------------|----------------------------------------------------|
| FIFO Full      | Hold input data stable, assert `full` flag         |
| Back-Pressure  | Wait until `almost_full` flag drops                |
| Data Integrity | No data loss - sender must hold until ready        |

---

### Functional Requirements

1. **Packet Reception**
   - Accept incoming packets with header + payload format
   - Extract priority from header byte
   - Store entire packet in appropriate priority queue

2. **Priority-Based Ordering**
   - Packets sorted by priority (0 = highest priority, served first)
   - Within same priority: FIFO ordering maintained
   - Higher priority packets served before lower priority

3. **Packet Transmission**
   - Only transmit **complete items** (packets that have received both SOP and EOP)
   - Partial items (SOP received but no EOP yet) are NOT eligible for transmission
   - Output highest priority **complete** item first
   - If multiple complete items at same priority, output oldest first
   - If higher priority has only partial items, serve lower priority complete items
   - Complete entire item before switching priority (no preemption mid-transmission)
   - Streaming output: `out_sop` on first byte, `out_eop` on last byte
   - When highest priority queue has no complete items, check next priority level
   - Support back-pressure when FIFO full

4. **Status Signals (Suggested)**
   - `full` - FIFO cannot accept more data
   - `empty` - No **complete** items available for transmission
   - `almost_full` - Threshold warning
   - `packet_count[7:0]` - Number of complete items stored
   - `priority_status[3:0]` - Which priority queues have complete items ready

5. **Item Completeness Tracking**
   - Track SOP/EOP for each incoming item per queue
   - Item is "complete" only when EOP is received
   - Maintain separate counters for partial vs complete items per priority
   - Arbiter only considers queues with complete items

---

### Interface (AXI-Stream Style)

#### Flow Control

Uses standard AXI-Stream ready/valid handshaking:
- **Transfer occurs when:** `pkt_valid && pkt_ready` on rising clock edge
- **pkt_valid must not depend on pkt_ready** - Master asserts valid independently
- **Data must remain stable** while pkt_valid=1 and pkt_ready=0

#### Input Signals

| Signal          | Width  | Direction | AXI-Stream Equiv | Description                    |
|-----------------|--------|-----------|------------------|--------------------------------|
| clk             | 1      | Input     | ACLK             | System clock                   |
| rst_n           | 1      | Input     | ARESETn          | Active-low reset               |
| pkt_valid       | 1      | Input     | TVALID           | Input data valid               |
| pkt_ready       | 1      | Output    | TREADY           | Ready to accept data           |
| pkt_data        | 8      | Input     | TDATA            | Input byte data                |
| pkt_priority    | 2      | Input     | TUSER            | Priority field (from header)   |
| pkt_id          | 6      | Input     | TID              | Packet ID (from header)        |
| pkt_sop         | 1      | Input     | -                | Start of packet                |
| pkt_eop         | 1      | Input     | TLAST            | End of packet                  |

#### Output Signals

| Signal          | Width  | Direction | AXI-Stream Equiv | Description                    |
|-----------------|--------|-----------|------------------|--------------------------------|
| out_valid       | 1      | Output    | TVALID           | Output data valid              |
| out_ready       | 1      | Input     | TREADY           | Downstream ready               |
| out_data        | 8      | Output    | TDATA            | Output byte data               |
| out_priority    | 2      | Output    | TUSER            | Priority of current packet     |
| out_id          | 6      | Output    | TID              | Packet ID                      |
| out_sop         | 1      | Output    | -                | Start of packet                |
| out_eop         | 1      | Output    | TLAST            | End of packet                  |

#### Status Signals

| Signal          | Width  | Direction | Description                         |
|-----------------|--------|-----------|-------------------------------------|
| full            | 1      | Output    | ALL FIFOs full (global)             |
| empty           | 1      | Output    | No complete items available         |
| almost_full     | 1      | Output    | ANY queue at threshold (global)     |
| fifo_full       | 4      | Output    | Per-queue full flags [3:0]          |
| fifo_almost_full| 4      | Output    | Per-queue almost_full flags [3:0]   |
| packet_count    | 8      | Output    | Number of complete items            |
| priority_status | 4      | Output    | Queues with complete items          |

**Per-Priority Back-Pressure:**

`pkt_ready` is determined by the **target queue** (based on `pkt_priority`), not global status:

```
pkt_ready = ~fifo_almost_full[pkt_priority]
```

| P0 Full | P1 Full | P2 Full | P3 Full | `full` | `pkt_priority` | `pkt_ready` |
|---------|---------|---------|---------|--------|----------------|-------------|
| 1       | 0       | 0       | 0       | 0      | 0              | 0 (reject P0) |
| 1       | 0       | 0       | 0       | 0      | 3              | 1 (accept P3) |
| 1       | 1       | 1       | 1       | 1      | any            | 0 (reject all)|
| 0       | 0       | 0       | 0       | 0      | any            | 1 (accept all)|

#### Handshaking Timing

**Normal Transfer:**
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

**Back-Pressure (No Data Loss):**
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

**Back-Pressure Truth Table:**

| pkt_ready | pkt_valid | Action                                      |
|-----------|-----------|---------------------------------------------|
| 1         | 1         | **Transfer** - DUT accepts the byte         |
| 1         | 0         | DUT ready, no data from upstream            |
| **0**     | **1**     | **Back-pressure** - upstream holds data     |
| 0         | 0         | Idle                                        |

**No-Drop Guarantee:**
- Upstream MUST hold `pkt_data` stable while `pkt_valid=1` and `pkt_ready=0`
- Upstream CANNOT deassert `pkt_valid` until transfer completes
- DUT waits for `almost_full` to drop before reasserting `pkt_ready=1`

---

### Design Decisions

#### Reset Behavior

| Aspect              | Decision                                      |
|---------------------|-----------------------------------------------|
| Reset Type          | Asynchronous, active-low (`rst_n`)            |
| FIFO State          | All FIFOs empty after reset                   |
| Outputs             | All outputs deasserted (0)                    |
| Counters            | All counters reset to 0                       |
| Ready Signal        | `pkt_ready` = 1 after reset (ready to accept) |

#### Almost Full Threshold

| Parameter           | Value                                         |
|---------------------|-----------------------------------------------|
| Threshold           | 240 out of 256 (~94% full)                    |
| Scope               | Per-queue (each priority queue independent)   |
| Hysteresis          | Deassert `pkt_ready` at 240, reassert at 224  |

#### Simultaneous Operation

| Feature             | Supported                                     |
|---------------------|-----------------------------------------------|
| Full-duplex         | Yes - can receive and transmit same cycle     |
| Independent paths   | Input and output paths operate independently  |

#### Priority Preemption

| Scenario                                    | Behavior                          |
|---------------------------------------------|-----------------------------------|
| Higher priority arrives mid-transmission    | Finish current item first         |
| No preemption                               | Complete entire item before switch|
| Check priority                              | Only between items (at EOP)       |

#### Error Handling

| Error Condition                      | Behavior                                |
|--------------------------------------|-----------------------------------------|
| `pkt_sop` without previous `pkt_eop` | Discard partial packet, start new item  |
| Missing `pkt_sop` (data without SOP) | Ignore data until next SOP              |
| Error flag                           | Optional `error` output signal          |

#### Latency

| Type              | Description                                   |
|-------------------|-----------------------------------------------|
| Store-and-forward | Wait for complete item (EOP) before transmit  |
| Minimum latency   | 1 cycle after EOP received (best case)        |
| Typical latency   | Depends on queue depth and priority           |

#### RTL Parameters (Configurable)

| Parameter             | Default | Description                        |
|-----------------------|---------|------------------------------------|
| DATA_WIDTH            | 8       | Bits per data byte                 |
| FIFO_DEPTH            | 256     | Depth per priority queue           |
| NUM_PRIORITIES        | 4       | Number of priority levels          |
| PRIORITY_WIDTH        | 2       | Bits for priority field            |
| ID_WIDTH              | 6       | Bits for packet ID                 |
| ALMOST_FULL_THRESHOLD | 240     | Back-pressure assertion threshold  |
| ALMOST_FULL_RELEASE   | 224     | Back-pressure release threshold    |

#### Clock Domain

| Aspect        | Decision                                      |
|---------------|-----------------------------------------------|
| Clock domains | Single clock (fully synchronous)              |
| Clock         | All logic on rising edge of `clk`             |

---

### Implementation Considerations

1. **Memory Architecture Options:**
   - 4 separate FIFOs (one per priority) - simpler control
   - Single shared memory with linked lists - better utilization
   - Hybrid: small fast buffers + main memory

2. **Packet Storage:**
   - Store complete packets contiguously
   - Need packet boundary tracking (start/end pointers)
   - Consider packet descriptor + data separation

3. **Arbitration:**
   - Strict priority: always serve highest first
   - Weighted fair queue: prevent starvation of low priority

4. **Edge Cases:**
   - FIFO full during packet reception
   - Minimum packet size (header only, 1 byte)
   - Maximum packet size (256 bytes)
   - All queues empty/full

---

### Verification Focus Areas

1. **Priority Ordering** - Verify packets exit in correct priority order
2. **FIFO Order Within Priority** - Same priority packets maintain insertion order
3. **Boundary Conditions** - Full/empty transitions, max/min packet sizes
4. **Back-Pressure** - Behavior when FIFO is full
5. **Packet Integrity** - Data matches between input and output
6. **Throughput** - No data loss under various traffic patterns
7. **Corner Cases** - Rapid priority changes, burst traffic, starvation scenarios

---

### UVM Testbench Components Needed

1. **Sequence Item** - Packet with priority, header, payload
2. **Sequences** - Random, directed priority patterns, stress tests
3. **Driver** - Send packets byte-by-byte with proper handshaking
4. **Monitor** - Capture input/output packets
5. **Scoreboard** - Verify priority ordering and data integrity
6. **Coverage** - Priority distributions, packet sizes, FIFO levels

---

### Open Questions (To Clarify)

- [x] ~~Exact header format - what is the second field besides priority?~~ → Packet ID (6 bits)
- [x] ~~Is length stored in header or determined by EOP signal?~~ → Determined by EOP signal
- [x] ~~Flow control mechanism (ready/valid, credit-based)?~~ → AXI-Stream ready/valid handshaking
- [x] ~~Behavior on overflow - drop packet or back-pressure?~~ → Back-pressure: hold data stable until almost_full drops
- [x] ~~Is the 256-depth per priority or total shared?~~ → 256 depth per priority queue (4 × 256 = 1024 total cells)
- [x] ~~Output interface - packet-at-a-time or streaming?~~ → Streaming, same as input (SOP on first byte, EOP on last byte of each packet)

---

### Similar Industry Designs

This DUT is similar to:
- **Traffic Manager (TM)** in network switches
- **QoS (Quality of Service) queuing** in routers
- **Priority mailbox** in SoC interconnects
- **Weighted Fair Queuing (WFQ)** implementations

