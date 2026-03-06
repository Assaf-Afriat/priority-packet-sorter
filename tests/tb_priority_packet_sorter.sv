//-----------------------------------------------------------------------------
// Testbench: tb_priority_packet_sorter
// 
// Description:
//   Simple testbench for priority_packet_sorter module.
//   Tests basic functionality:
//     - Single packet transmission
//     - Multiple packets with different priorities
//     - Priority ordering verification
//     - Back-pressure handling
//     - Error detection
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_priority_packet_sorter;

    //=========================================================================
    // Parameters
    //=========================================================================
    parameter DATA_WIDTH            = 8;
    parameter ID_WIDTH              = 6;
    parameter NUM_PRIORITIES        = 4;
    parameter PRIORITY_WIDTH        = 2;
    parameter FIFO_DEPTH            = 256;
    parameter ALMOST_FULL_THRESHOLD = 240;
    parameter ALMOST_FULL_RELEASE   = 224;
    
    parameter CLK_PERIOD = 10;  // 100 MHz

    //=========================================================================
    // DUT Signals
    //=========================================================================
    
    // Clock and Reset
    logic                        clk;
    logic                        rst_n;
    
    // Input Interface
    logic                        pkt_valid;
    logic                        pkt_ready;
    logic [DATA_WIDTH-1:0]       pkt_data;
    logic [PRIORITY_WIDTH-1:0]   pkt_priority;
    logic [ID_WIDTH-1:0]         pkt_id;
    logic                        pkt_sop;
    logic                        pkt_eop;
    
    // Output Interface
    logic                        out_valid;
    logic                        out_ready;
    logic [DATA_WIDTH-1:0]       out_data;
    logic [PRIORITY_WIDTH-1:0]   out_priority;
    logic [ID_WIDTH-1:0]         out_id;
    logic                        out_sop;
    logic                        out_eop;
    
    // Status Signals
    logic                        full;
    logic                        empty;
    logic                        almost_full;
    logic [NUM_PRIORITIES-1:0]   fifo_full;
    logic [NUM_PRIORITIES-1:0]   fifo_almost_full;
    logic [7:0]                  packet_count;
    logic [NUM_PRIORITIES-1:0]   priority_status;
    
    // Error Signals
    logic                        error_sop_without_eop;
    logic                        error_data_without_sop;
    logic                        error_eop_without_sop;
    logic [NUM_PRIORITIES-1:0]   error_queue;
    
    // Debug Signals
    logic [NUM_PRIORITIES-1:0]   debug_fifo_wr_en;
    logic [NUM_PRIORITIES-1:0]   debug_wr_eop;
    logic                        debug_input_transfer;
    logic                        debug_valid_write;
    logic [NUM_PRIORITIES-1:0]   debug_receiving_partial;
    logic                        debug_curr_recv_partial;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    
    priority_packet_sorter #(
        .DATA_WIDTH            (DATA_WIDTH),
        .ID_WIDTH              (ID_WIDTH),
        .NUM_PRIORITIES        (NUM_PRIORITIES),
        .PRIORITY_WIDTH        (PRIORITY_WIDTH),
        .FIFO_DEPTH            (FIFO_DEPTH),
        .ALMOST_FULL_THRESHOLD (ALMOST_FULL_THRESHOLD),
        .ALMOST_FULL_RELEASE   (ALMOST_FULL_RELEASE)
    ) dut (
        // Clock and Reset
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // Input Interface
        .pkt_valid              (pkt_valid),
        .pkt_ready              (pkt_ready),
        .pkt_data               (pkt_data),
        .pkt_priority           (pkt_priority),
        .pkt_id                 (pkt_id),
        .pkt_sop                (pkt_sop),
        .pkt_eop                (pkt_eop),
        
        // Output Interface
        .out_valid              (out_valid),
        .out_ready              (out_ready),
        .out_data               (out_data),
        .out_priority           (out_priority),
        .out_id                 (out_id),
        .out_sop                (out_sop),
        .out_eop                (out_eop),
        
        // Status Signals
        .full                   (full),
        .empty                  (empty),
        .almost_full            (almost_full),
        .fifo_full              (fifo_full),
        .fifo_almost_full       (fifo_almost_full),
        .packet_count           (packet_count),
        .priority_status        (priority_status),
        
        // Error Signals
        .error_sop_without_eop  (error_sop_without_eop),
        .error_data_without_sop (error_data_without_sop),
        .error_eop_without_sop  (error_eop_without_sop),
        .error_queue            (error_queue),
        
        // Debug Signals
        .debug_fifo_wr_en       (debug_fifo_wr_en),
        .debug_wr_eop           (debug_wr_eop),
        .debug_input_transfer   (debug_input_transfer),
        .debug_valid_write      (debug_valid_write),
        .debug_receiving_partial(debug_receiving_partial),
        .debug_curr_recv_partial(debug_curr_recv_partial)
    );

    //=========================================================================
    // Clock Generation
    //=========================================================================
    
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //=========================================================================
    // Test Variables
    //=========================================================================
    
    int test_pass_count = 0;
    int test_fail_count = 0;
    int total_tests = 0;
    
    // Expected output tracking
    typedef struct {
        logic [DATA_WIDTH-1:0]     data;
        logic [PRIORITY_WIDTH-1:0] prio;
        logic [ID_WIDTH-1:0]       id;
        logic                      sop;
        logic                      eop;
    } packet_byte_t;
    
    packet_byte_t expected_queue[$];

    //=========================================================================
    // Tasks
    //=========================================================================
    
    // Reset the DUT
    task automatic reset_dut();
        $display("[%0t] Resetting DUT...", $time);
        rst_n = 0;
        pkt_valid = 0;
        pkt_data = 0;
        pkt_priority = 0;
        pkt_id = 0;
        pkt_sop = 0;
        pkt_eop = 0;
        out_ready = 1;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);
        $display("[%0t] Reset complete", $time);
    endtask
    
    // Send a single byte with AXI-Stream handshake
    task automatic send_byte(
        logic [DATA_WIDTH-1:0]     in_data,
        logic [PRIORITY_WIDTH-1:0] in_prio,
        logic [ID_WIDTH-1:0]       in_id,
        logic                      in_sop,
        logic                      in_eop
    );
        // Set data signals
        pkt_data     = in_data;
        pkt_priority = in_prio;
        pkt_id       = in_id;
        pkt_sop      = in_sop;
        pkt_eop      = in_eop;
        pkt_valid    = 1;
        
        // Standard AXI-Stream handshake:
        // Keep valid high until we see a clock edge where ready is also high
        do begin
            @(posedge clk);
        end while (!pkt_ready);
        
        // Transfer completed on this clock edge
        // Small delay to let registered outputs settle before next byte
        #1;
        
        // Deassert valid
        pkt_valid = 0;
        pkt_sop   = 0;
        pkt_eop   = 0;
    endtask
    
    // Send a complete packet
    task automatic send_packet(
        logic [PRIORITY_WIDTH-1:0] in_prio,
        logic [ID_WIDTH-1:0]       in_id,
        int                        in_length
    );
        logic sop_flag;
        logic eop_flag;
        logic [DATA_WIDTH-1:0] data_byte;
        
        $display("[%0t] Sending packet: priority=%0d, id=%0d, length=%0d", 
                 $time, in_prio, in_id, in_length);
        
        for (int i = 0; i < in_length; i++) begin
            sop_flag = (i == 0);
            eop_flag = (i == in_length - 1);
            data_byte = i + 1;
            
            send_byte(data_byte, in_prio, in_id, sop_flag, eop_flag);
            
            // Add to expected queue for checking
            expected_queue.push_back('{data_byte, in_prio, in_id, sop_flag, eop_flag});
        end
        
        $display("[%0t] Packet sent", $time);
    endtask
    
    // Receive and verify output
    task automatic receive_and_check(int num_bytes);
        packet_byte_t expected;
        int received = 0;
        
        $display("[%0t] Receiving %0d bytes...", $time, num_bytes);
        
        while (received < num_bytes) begin
            @(negedge clk);  // Sample at negedge to see stable output before next posedge
            
            if (out_valid && out_ready) begin
                if (expected_queue.size() > 0) begin
                    expected = expected_queue.pop_front();
                    
                    // Debug: show all received fields
                    $display("[%0t] RX[%0d]: data=%0h id=%0d sop=%b eop=%b prio=%0d", 
                             $time, received, out_data, out_id, out_sop, out_eop, out_priority);
                    
                    // Check each field
                    if (out_data !== expected.data) begin
                        $display("[%0t] ERROR: data mismatch. Expected=%0h, Got=%0h", 
                                 $time, expected.data, out_data);
                        test_fail_count++;
                    end
                    else if (out_priority !== expected.prio) begin
                        $display("[%0t] ERROR: priority mismatch. Expected=%0d, Got=%0d", 
                                 $time, expected.prio, out_priority);
                        test_fail_count++;
                    end
                    else if (out_id !== expected.id) begin
                        $display("[%0t] ERROR: id mismatch. Expected=%0d, Got=%0d", 
                                 $time, expected.id, out_id);
                        test_fail_count++;
                    end
                    else if (out_sop !== expected.sop) begin
                        $display("[%0t] ERROR: sop mismatch. Expected=%0b, Got=%0b", 
                                 $time, expected.sop, out_sop);
                        test_fail_count++;
                    end
                    else if (out_eop !== expected.eop) begin
                        $display("[%0t] ERROR: eop mismatch. Expected=%0b, Got=%0b", 
                                 $time, expected.eop, out_eop);
                        test_fail_count++;
                    end
                    else begin
                        test_pass_count++;
                    end
                end
                
                received++;
            end
        end
        
        $display("[%0t] Received %0d bytes", $time, received);
    endtask
    
    // Wait for empty
    task automatic wait_for_empty(int timeout_cycles = 1000);
        int count = 0;
        while (!empty && count < timeout_cycles) begin
            @(posedge clk);
            count++;
        end
        if (count >= timeout_cycles) begin
            $display("[%0t] WARNING: Timeout waiting for empty", $time);
        end
    endtask

    //=========================================================================
    // Test Cases
    //=========================================================================
    
    // Test 1: Single packet
    task automatic test_single_packet();
        $display("\n========== TEST 1: Single Packet ==========");
        total_tests++;
        
        reset_dut();
        
        // Debug: Check initial state
        $display("[%0t] INIT: pkt_ready=%b empty=%b packet_count=%0d", 
                 $time, pkt_ready, empty, packet_count);
        
        send_packet(2'd0, 6'd1, 5);
        
        // Go straight to receiving - no gap where bytes could drain
        receive_and_check(5);
        wait_for_empty();
        
        if (empty) begin
            $display("TEST 1 PASSED: Single packet transmitted correctly");
        end else begin
            $display("TEST 1 FAILED: FIFO not empty after transmission");
            test_fail_count++;
        end
    endtask
    
    // Test 2: Multiple packets same priority (FIFO order)
    task automatic test_fifo_order();
        $display("\n========== TEST 2: FIFO Order (Same Priority) ==========");
        total_tests++;
        
        reset_dut();
        
        // Disable output while queueing multiple packets
        out_ready = 0;
        
        // Send 3 packets to priority 1
        send_packet(2'd1, 6'd10, 3);
        send_packet(2'd1, 6'd11, 4);
        send_packet(2'd1, 6'd12, 2);
        
        // Enable output and receive all (3 + 4 + 2 = 9 bytes)
        out_ready = 1;
        receive_and_check(9);
        wait_for_empty();
        
        if (empty) begin
            $display("TEST 2 PASSED: FIFO order maintained");
        end else begin
            $display("TEST 2 FAILED: FIFO not empty");
            test_fail_count++;
        end
    endtask
    
    // Test 3: Priority ordering
    task automatic test_priority_order();
        $display("\n========== TEST 3: Priority Ordering ==========");
        total_tests++;
        
        reset_dut();
        
        // Disable output temporarily to queue packets
        out_ready = 0;
        
        // Send packets in reverse priority order
        send_packet(2'd3, 6'd30, 2);  // Lowest
        send_packet(2'd2, 6'd20, 2);  // Medium
        send_packet(2'd1, 6'd10, 2);  // High
        send_packet(2'd0, 6'd0,  2);  // Highest
        
        // Clear expected queue - we need to reorder by priority
        expected_queue.delete();
        
        // Expected order: P0, P1, P2, P3 (struct: data, prio, id, sop, eop)
        expected_queue.push_back('{8'd1, 2'd0, 6'd0, 1'b1, 1'b0});  // P0 byte 1 (SOP)
        expected_queue.push_back('{8'd2, 2'd0, 6'd0, 1'b0, 1'b1});  // P0 byte 2 (EOP)
        expected_queue.push_back('{8'd1, 2'd1, 6'd10, 1'b1, 1'b0}); // P1 byte 1
        expected_queue.push_back('{8'd2, 2'd1, 6'd10, 1'b0, 1'b1}); // P1 byte 2
        expected_queue.push_back('{8'd1, 2'd2, 6'd20, 1'b1, 1'b0}); // P2 byte 1
        expected_queue.push_back('{8'd2, 2'd2, 6'd20, 1'b0, 1'b1}); // P2 byte 2
        expected_queue.push_back('{8'd1, 2'd3, 6'd30, 1'b1, 1'b0}); // P3 byte 1
        expected_queue.push_back('{8'd2, 2'd3, 6'd30, 1'b0, 1'b1}); // P3 byte 2
        
        // Enable output and receive
        out_ready = 1;
        receive_and_check(8);
        wait_for_empty();
        
        if (empty) begin
            $display("TEST 3 PASSED: Priority ordering correct");
        end else begin
            $display("TEST 3 FAILED: FIFO not empty");
            test_fail_count++;
        end
    endtask
    
    // Test 4: Back-pressure (output not ready)
    task automatic test_backpressure();
        $display("\n========== TEST 4: Back-Pressure ==========");
        total_tests++;
        
        reset_dut();
        
        // Disable output before sending
        out_ready = 0;
        
        // Send a packet
        send_packet(2'd0, 6'd5, 4);
        
        // Wait for TX state machine to see complete packet
        repeat(3) @(posedge clk);
        
        // Check that out_valid is asserted (waiting for ready)
        if (!out_valid) begin
            $display("TEST 4 FAILED: out_valid should be high during back-pressure");
            test_fail_count++;
        end else begin
            $display("TEST 4: Back-pressure holding correctly");
        end
        
        // Wait more cycles to verify data holds
        repeat(10) @(posedge clk);
        
        // Re-enable and drain
        out_ready = 1;
        receive_and_check(4);
        wait_for_empty();
        
        if (empty) begin
            $display("TEST 4 PASSED: Back-pressure handled correctly");
        end else begin
            $display("TEST 4 FAILED: FIFO not empty");
            test_fail_count++;
        end
    endtask
    
    // Test 5: Error detection - data without SOP
    task automatic test_error_data_without_sop();
        $display("\n========== TEST 5: Error - Data Without SOP ==========");
        total_tests++;
        
        reset_dut();
        
        // Send data without SOP (should be ignored)
        send_byte(8'hAB, 2'd0, 6'd1, 1'b0, 1'b0);
        
        @(posedge clk);
        
        if (error_data_without_sop) begin
            $display("TEST 5 PASSED: Error detected for data without SOP");
            test_pass_count++;
        end else begin
            $display("TEST 5 FAILED: Error not detected");
            test_fail_count++;
        end
        
        // Verify FIFO is still empty (data was ignored)
        if (empty) begin
            $display("TEST 5: Orphan data correctly ignored");
        end else begin
            $display("TEST 5 WARNING: FIFO should be empty");
        end
    endtask
    
    // Test 6: Single-byte packet (SOP and EOP same cycle)
    task automatic test_single_byte_packet();
        $display("\n========== TEST 6: Single-Byte Packet ==========");
        total_tests++;
        
        reset_dut();
        
        // Single byte packet (SOP=1, EOP=1)
        send_byte(8'hFF, 2'd2, 6'd42, 1'b1, 1'b1);
        
        expected_queue.push_back('{8'hFF, 2'd2, 6'd42, 1'b1, 1'b1});
        
        receive_and_check(1);
        wait_for_empty();
        
        if (empty) begin
            $display("TEST 6 PASSED: Single-byte packet handled correctly");
        end else begin
            $display("TEST 6 FAILED: FIFO not empty");
            test_fail_count++;
        end
    endtask

    //=========================================================================
    // Main Test Sequence
    //=========================================================================
    
    initial begin
        $display("\n");
        $display("==========================================================");
        $display("  Priority Packet Sorter Testbench");
        $display("==========================================================");
        $display("\n");
        
        // Run all tests
        test_single_packet();
        test_fifo_order();
        test_priority_order();
        test_backpressure();
        test_error_data_without_sop();
        test_single_byte_packet();
        
        // Summary
        $display("\n");
        $display("==========================================================");
        $display("  Test Summary");
        $display("==========================================================");
        $display("  Total Tests:  %0d", total_tests);
        $display("  Byte Checks:  %0d passed, %0d failed", test_pass_count, test_fail_count);
        $display("==========================================================");
        
        if (test_fail_count == 0) begin
            $display("  ALL TESTS PASSED!");
        end else begin
            $display("  SOME TESTS FAILED!");
        end
        
        $display("==========================================================\n");
        
        $finish;
    end

    //=========================================================================
    // Timeout Watchdog
    //=========================================================================
    
    initial begin
        #500000;  // 500us timeout
        $display("\n[%0t] ERROR: Testbench timeout!", $time);
        $display("Final state: empty=%b packet_count=%0d priority_status=%b out_valid=%b",
                 empty, packet_count, priority_status, out_valid);
        $finish;
    end

    //=========================================================================
    // Waveform Dump
    //=========================================================================
    
    initial begin
        $dumpfile("tb_priority_packet_sorter.vcd");
        $dumpvars(0, tb_priority_packet_sorter);
    end

endmodule
