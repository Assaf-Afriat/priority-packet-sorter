# Rollback Pointers - Future Enhancement

## The Problem

When a malformed packet is received (e.g., 100 bytes written but no EOP, or a new SOP mid-packet), the partial data is already in the FIFO. The current design raises an error flag but cannot remove the corrupt data.

```
FIFO state after error:
  wr_ptr ────────────────────────────────────────────▼
  ┌────┬────┬────┬────┬─────┬────┬────┬────┬────┬────┐
  │ D0 │ D1 │ D2 │... │ D98 │ D0'│ D1'│    │    │    │
  │SOP │    │    │    │ !!  │SOP'│    │    │    │    │
  └────┴────┴────┴────┴─────┴────┴────┴────┴────┴────┘
   ▲                    ▲     ▲
   rd_ptr               │     New packet starts, but old
                        │     garbage is ahead of it
                        Never got EOP!
```

The read side will eventually try to read D0-D98 as a "packet," but there's no EOP -- it's garbage.

---

## The Solution: Commit/Rollback FIFO

Add a **checkpoint pointer** alongside the write pointer. Think of it like a database transaction: you start writing, and at the end you either **commit** (keep it) or **rollback** (discard it).

### Two New Pointers

| Pointer | Purpose |
|---------|---------|
| `wr_ptr` | Advances normally on every write (same as today) |
| `commit_ptr` | Only advances when a **complete packet** (EOP) is written |
| `checkpoint_ptr` | Saved `wr_ptr` position at the start of each packet (SOP) |

**Key rule:** The read side only sees data up to `commit_ptr`, not `wr_ptr`.

---

## How It Works

```
1. SOP arrives → save wr_ptr as checkpoint: checkpoint_ptr = wr_ptr
2. Data bytes arrive → wr_ptr advances normally, checkpoint_ptr stays
3a. EOP arrives (happy path) → commit_ptr = wr_ptr (packet visible to reader)
3b. Error (new SOP, timeout) → wr_ptr = checkpoint_ptr (discard partial data)
```

### Visual Walkthrough

**Step 1: SOP arrives, start writing**

```
  checkpoint        wr_ptr
     ▼                 ▼
  ┌────┬────┬────┬────┬────┐
  │ D0 │ D1 │ D2 │ D3 │    │
  │SOP │    │    │    │    │
  └────┴────┴────┴────┴────┘
  ▲
  commit_ptr (read side can't see any of this yet)
```

**Step 2a: EOP arrives -- COMMIT**

```
  The packet is valid. Move commit_ptr forward.

                         commit_ptr = wr_ptr
                              ▼
  ┌────┬────┬────┬────┬────┬────┐
  │ D0 │ D1 │ D2 │ D3 │ D4 │    │
  │SOP │    │    │    │EOP │    │
  └────┴────┴────┴────┴────┴────┘
  ▲
  rd_ptr (now the reader can see and read this packet)
```

**Step 2b: Error (new SOP mid-packet) -- ROLLBACK**

```
  Bad packet! Snap wr_ptr back to checkpoint.

  wr_ptr = checkpoint_ptr
     ▼
  ┌────┬────┬────┬────┬────┐
  │ D0 │ D1 │ D2 │ D3 │    │  ← data still in memory,
  │SOP │    │    │    │    │    but wr_ptr is back here
  └────┴────┴────┴────┴────┘    so it will be overwritten
  ▲
  commit_ptr / rd_ptr (reader never saw the bad data)
```

The old data isn't physically erased -- it's just invisible because `wr_ptr` is back behind it. New writes will overwrite those cells.

---

## FIFO Changes Required

The `sync_fifo` module would need new signals and logic:

```systemverilog
// New registers
logic [ADDR_WIDTH-1:0] wr_ptr;         // current write position
logic [ADDR_WIDTH-1:0] commit_ptr;     // last committed position
logic [ADDR_WIDTH-1:0] checkpoint_ptr; // saved position at SOP

// New input signals from top level
input logic commit,    // Assert on EOP write (packet complete)
input logic rollback,  // Assert on error (discard partial packet)

// Item count for read side uses commit_ptr, not wr_ptr
// Reader only sees committed data
assign committed_count = commit_ptr - rd_ptr;

// Full check uses wr_ptr (we still need space to write)
assign full = (wr_ptr + 1'b1 == rd_ptr);

// Empty check uses commit_ptr (reader only reads committed data)
assign empty = (commit_ptr == rd_ptr);

// On commit (EOP written successfully)
if (commit)
    commit_ptr <= wr_ptr;

// On rollback (error detected)
if (rollback)
    wr_ptr <= checkpoint_ptr;

// On SOP (start of new packet)
if (sop)
    checkpoint_ptr <= wr_ptr;
```

---

## Integration with priority_packet_sorter

The top-level module would drive the new FIFO signals:

```systemverilog
// Per-queue commit/rollback signals
logic [NUM_PRIORITIES-1:0] fifo_commit;
logic [NUM_PRIORITIES-1:0] fifo_rollback;

// Commit when EOP is successfully written
assign fifo_commit[i] = wr_eop[i];

// Rollback when SOP arrives mid-packet (error_sop_without_eop)
// The rollback restores wr_ptr, so the partial data is discarded
assign fifo_rollback[i] = fifo_wr_en[i] && pkt_sop && receiving_partial[i];
```

The `complete_count` logic would also need adjustment:
- Only count committed packets (use `committed_count` from FIFO)
- On rollback, the partial data is gone, so no decrement needed

---

## Complexity Considerations

| Aspect | Impact |
|--------|--------|
| FIFO interface | New `commit`, `rollback`, `sop` inputs needed |
| Count logic | Two separate counts: uncommitted (`wr_ptr - checkpoint_ptr`) vs committed (`commit_ptr - rd_ptr`) |
| Full/empty | `full` uses `wr_ptr` (need space to write), `empty` uses `commit_ptr` (only read committed data) |
| Almost full | Needs rethinking -- based on `wr_ptr` or `commit_ptr`? |
| Timing | Rollback and checkpoint must be coordinated with write enable |
| Genericity | `sync_fifo` becomes a packet-aware FIFO, no longer fully generic |

---

## Industry Reference

Xilinx's `axis_data_fifo` IP in **packet mode** implements exactly this pattern. When packet mode is enabled, data is only made available to the read side after a complete packet (TLAST) is received. If the FIFO is reset mid-packet, the partial data is discarded.

---

## Status

- [ ] Implement `commit_ptr` and `checkpoint_ptr` in `sync_fifo`
- [ ] Add `commit` / `rollback` / `sop` ports to `sync_fifo`
- [ ] Update `priority_packet_sorter` to drive commit/rollback signals
- [ ] Update `complete_count` logic to work with committed counts
- [ ] Update `empty` / `full` / `almost_full` for dual-pointer semantics
- [ ] Add testbench cases for rollback scenarios
- [ ] Update `design_review.md`
