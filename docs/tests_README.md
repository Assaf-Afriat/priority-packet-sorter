# Priority Packet Sorter - Tests

## Overview

This folder contains testbenches and test utilities for the Priority Packet Sorter.

## Files

| File | Description |
|------|-------------|
| `tb_priority_packet_sorter.sv` | Main testbench |
| `run_test.sh` | Shell script to run simulation |
| `README.md` | This file |

## Test Cases

### Test 1: Single Packet
- Send one packet (5 bytes)
- Verify correct transmission

### Test 2: FIFO Order (Same Priority)
- Send 3 packets to same priority queue
- Verify FIFO order maintained (first-in, first-out)

### Test 3: Priority Ordering
- Send packets in reverse priority order (P3, P2, P1, P0)
- Verify output order is by priority (P0, P1, P2, P3)

### Test 4: Back-Pressure
- Send packet, then deassert `out_ready`
- Verify DUT holds data and waits
- Reassert `out_ready`, verify transmission resumes

### Test 5: Error Detection - Data Without SOP
- Send data byte without SOP
- Verify `error_data_without_sop` is asserted
- Verify data is ignored (not written to FIFO)

### Test 6: Single-Byte Packet
- Send packet with SOP=1 and EOP=1 in same cycle
- Verify correct handling

## Running Tests

### Using Icarus Verilog (Free)

```bash
cd tests
chmod +x run_test.sh
./run_test.sh
```

Or manually:

```bash
iverilog -g2012 -o sim.vvp ../rtl/sync_fifo.sv ../rtl/priority_packet_sorter.sv tb_priority_packet_sorter.sv
vvp sim.vvp
```

### Using Other Simulators

Edit `run_test.sh` and change `SIMULATOR` variable:
- `iverilog` - Icarus Verilog (free)
- `vcs` - Synopsys VCS
- `questa` - Siemens Questa/ModelSim
- `xsim` - Xilinx Vivado Simulator

## Expected Output

```
==========================================================
  Priority Packet Sorter Testbench
==========================================================

========== TEST 1: Single Packet ==========
[...] Sending packet: priority=0, id=1, length=5
[...] Packet sent
[...] Receiving 5 bytes...
[...] Received 5 bytes
TEST 1 PASSED: Single packet transmitted correctly

========== TEST 2: FIFO Order (Same Priority) ==========
[...] 
TEST 2 PASSED: FIFO order maintained

========== TEST 3: Priority Ordering ==========
[...]
TEST 3 PASSED: Priority ordering correct

========== TEST 4: Back-Pressure ==========
[...]
TEST 4 PASSED: Back-pressure handled correctly

========== TEST 5: Error - Data Without SOP ==========
[...]
TEST 5 PASSED: Error detected for data without SOP

========== TEST 6: Single-Byte Packet ==========
[...]
TEST 6 PASSED: Single-byte packet handled correctly

==========================================================
  Test Summary
==========================================================
  Total Tests:  6
  Byte Checks:  XX passed, 0 failed
==========================================================
  ALL TESTS PASSED!
==========================================================
```

## Waveform Viewing

The testbench generates `tb_priority_packet_sorter.vcd` for waveform viewing.

Open with GTKWave (free):

```bash
gtkwave tb_priority_packet_sorter.vcd
```

## Adding New Tests

1. Add a new task in the testbench:

```systemverilog
task automatic test_my_new_test();
    $display("\n========== TEST N: My New Test ==========");
    total_tests++;
    
    reset_dut();
    // Your test logic here
    
    $display("TEST N PASSED/FAILED: Description");
endtask
```

2. Call it from the main test sequence:

```systemverilog
initial begin
    // ... existing tests ...
    test_my_new_test();
    // ...
end
```

## Future Tests (TODO)

- [ ] Maximum packet size (256 bytes)
- [ ] FIFO full behavior (per priority)
- [ ] Almost full threshold testing
- [ ] Error: SOP without previous EOP
- [ ] Error: EOP without SOP
- [ ] Concurrent input/output
- [ ] Stress test: random packets
- [ ] Coverage-driven tests

