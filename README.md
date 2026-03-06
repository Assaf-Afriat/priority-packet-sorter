# Priority Packet Sorter

AXI-Stream style priority packet sorter in SystemVerilog. Receives packets with 4 priority levels and outputs them in priority order. Within the same priority, FIFO order is maintained.

## Features

- 4 priority levels (0 = highest, 3 = lowest)
- Ready/valid handshaking (AXI-Stream compatible)
- Store-and-forward: only complete packets are transmitted
- Per-priority back-pressure with hysteresis
- Configurable FIFO depth, data width, and thresholds

## Block Diagram

```
                    ┌─────────────────────────────────────────────────┐
                    │          PRIORITY PACKET SORTER                 │
                    │                                                 │
  pkt_valid ───────►│  ┌─────────┐    ┌─────────────────────────┐     │───────► out_valid
  pkt_data[7:0] ───►│  │  INPUT  │    │       FIFO ARRAY        │     │───────► out_data[7:0]
  pkt_priority[1:0]►│  │  STAGE  │───►│                         │     │───────► out_priority[1:0]
  pkt_id[5:0] ─────►│  │         │    │  P0  P1  P2  P3         │     │───────► out_id[5:0]
  pkt_sop ─────────►│  │  PACK   │    │  256  256  256  256     │     │───────► out_sop
  pkt_eop ─────────►│  │  + ERR  │    │  each 16-bit wide       │     │───────► out_eop
                    │  └─────────┘    └───────────┬─────────────┘     │
  pkt_ready ◄───────│                             │                   │◄─────── out_ready
                    │                    ┌────────▼────────┐          │
                    │                    │ PRIORITY ARBITER│          │
                    │                    │ + OUTPUT STATE  │          │
                    │                    │   MACHINE       │          │
                    │                    └─────────────────┘          │
                    │                                                 │
                    │──► full, empty, almost_full                     │
                    │──► fifo_full[3:0], fifo_almost_full[3:0]        │
                    │──► packet_count[7:0], priority_status[3:0]      │
                    │──► error_sop_without_eop, error_data_without_sop│
                    │──► error_eop_without_sop, error_queue[3:0]      │
                    └─────────────────────────────────────────────────┘
```

## Interface

### Input (Slave)

| Signal | Width | Description |
|--------|-------|-------------|
| `pkt_valid` | 1 | Input data valid (TVALID) |
| `pkt_ready` | 1 (out) | Ready to accept (TREADY) |
| `pkt_data` | 8 | Byte data (TDATA) |
| `pkt_priority` | 2 | Priority 0-3 (TUSER) |
| `pkt_id` | 6 | Packet ID (TID) |
| `pkt_sop` | 1 | Start of packet |
| `pkt_eop` | 1 | End of packet (TLAST) |

### Output (Master)

| Signal | Width | Description |
|--------|-------|-------------|
| `out_valid` | 1 | Output data valid (TVALID) |
| `out_ready` | 1 (in) | Downstream ready (TREADY) |
| `out_data` | 8 | Byte data (TDATA) |
| `out_priority` | 2 | Priority of current packet (TUSER) |
| `out_id` | 6 | Packet ID (TID) |
| `out_sop` | 1 | Start of packet |
| `out_eop` | 1 | End of packet (TLAST) |

### Status

| Signal | Width | Description |
|--------|-------|-------------|
| `full` | 1 | All FIFOs full |
| `empty` | 1 | No complete packets |
| `almost_full` | 1 | Any queue at threshold |
| `fifo_full` | 4 | Per-queue full flags |
| `fifo_almost_full` | 4 | Per-queue almost full |
| `packet_count` | 8 | Total complete packets |
| `priority_status` | 4 | Queues with complete packets |

### Errors

| Signal | Width | Description |
|--------|-------|-------------|
| `error_sop_without_eop` | 1 | SOP received mid-packet |
| `error_data_without_sop` | 1 | Data without SOP |
| `error_eop_without_sop` | 1 | EOP without SOP |
| `error_queue` | 4 | Which queue had the error |

## Quick Start

Simulate with Xilinx Vivado (XSIM):

```bash
cd tests
xvlog -sv ../rtl/sync_fifo.sv ../rtl/priority_packet_sorter.sv tb_priority_packet_sorter.sv
xelab tb_priority_packet_sorter -s sim
xsim sim -R
```

Or with Icarus Verilog:

```bash
cd tests
iverilog -g2012 -o sim.vvp ../rtl/sync_fifo.sv ../rtl/priority_packet_sorter.sv tb_priority_packet_sorter.sv
vvp sim.vvp
```

## License

MIT
