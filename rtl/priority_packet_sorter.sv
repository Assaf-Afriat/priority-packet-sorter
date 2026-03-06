//-----------------------------------------------------------------------------
// Module: priority_packet_sorter
// Assaf Afriat
// 23.2.2026
// Description:
//   AXI-Stream style priority packet sorter. Receives packets with priority
//   levels and outputs them in priority order. Within the same priority,
//   packets maintain FIFO order. Only complete packets (SOP to EOP received)
//   are eligible for transmission.
//
// Features:
//   - 4 priority levels (0=highest, 3=lowest)
//   - Ready/valid handshaking (AXI-Stream style)
//   - Back-pressure support with no data loss
//   - Store-and-forward: waits for complete packet before transmit
//-----------------------------------------------------------------------------

module priority_packet_sorter #(
    // Data width parameters
    parameter DATA_WIDTH            = 8,        // Bits per data byte
    parameter ID_WIDTH              = 6,        // Bits for packet ID
    
    // Priority parameters  
    parameter NUM_PRIORITIES        = 4,        // Number of priority levels
    parameter PRIORITY_WIDTH        = 2,        // Bits for priority field
    
    // FIFO parameters
    parameter FIFO_DEPTH            = 256,      // Depth per priority queue
    parameter ALMOST_FULL_THRESHOLD = 240,      // Assert back-pressure
    parameter ALMOST_FULL_RELEASE   = 224       // Release back-pressure
)(
    //-------------------------------------------------------------------------
    // Clock and Reset
    //-------------------------------------------------------------------------
    input  logic                        clk,
    input  logic                        rst_n,      // Async active-low reset
    
    //-------------------------------------------------------------------------
    // Input Interface (Slave - receives packets)
    //-------------------------------------------------------------------------
    input  logic                        pkt_valid,  // Input data valid
    output logic                        pkt_ready,  // Ready to accept data
    input  logic [DATA_WIDTH-1:0]       pkt_data,   // Input byte data
    input  logic [PRIORITY_WIDTH-1:0]   pkt_priority, // Priority (0=highest)
    input  logic [ID_WIDTH-1:0]         pkt_id,     // Packet ID
    input  logic                        pkt_sop,    // Start of packet
    input  logic                        pkt_eop,    // End of packet
    
    //-------------------------------------------------------------------------
    // Output Interface (Master - sends packets)
    //-------------------------------------------------------------------------
    output logic                        out_valid,  // Output data valid
    input  logic                        out_ready,  // Downstream ready
    output logic [DATA_WIDTH-1:0]       out_data,   // Output byte data
    output logic [PRIORITY_WIDTH-1:0]   out_priority, // Priority of packet
    output logic [ID_WIDTH-1:0]         out_id,     // Packet ID
    output logic                        out_sop,    // Start of packet
    output logic                        out_eop,    // End of packet
    
    //-------------------------------------------------------------------------
    // Status Signals
    //-------------------------------------------------------------------------
    output logic                        full,           // ALL FIFOs full
    output logic                        empty,          // No complete items
    output logic                        almost_full,    // ANY queue at threshold
    output logic [NUM_PRIORITIES-1:0]   fifo_full,      // Per-queue full flags
    output logic [NUM_PRIORITIES-1:0]   fifo_almost_full, // Per-queue almost_full
    output logic [7:0]                  packet_count,   // Complete items count
    output logic [NUM_PRIORITIES-1:0]   priority_status, // Queues with complete items
    
    //-------------------------------------------------------------------------
    // Error Signals
    //-------------------------------------------------------------------------
    output logic                        error_sop_without_eop,  // SOP received mid-packet
    output logic                        error_data_without_sop, // Data without SOP
    output logic                        error_eop_without_sop,  // EOP without SOP
    output logic [NUM_PRIORITIES-1:0]   error_queue,            // Which queue had error
    
    //-------------------------------------------------------------------------
    // Debug Signals (for testbench visibility)
    //-------------------------------------------------------------------------
    output logic [NUM_PRIORITIES-1:0]   debug_fifo_wr_en,       // FIFO write enables
    output logic [NUM_PRIORITIES-1:0]   debug_wr_eop,           // EOP write per queue
    output logic                        debug_input_transfer,   // Input transfer happening
    output logic                        debug_valid_write,      // Valid write signal
    output logic [NUM_PRIORITIES-1:0]   debug_receiving_partial, // Per-queue receiving state
    output logic                        debug_curr_recv_partial  // Muxed receiving partial
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    // Calculate address width needed for FIFO depth
    localparam ADDR_WIDTH = $clog2(FIFO_DEPTH);
    
    // Width of data stored in FIFO (data + id + sop + eop)
    localparam FIFO_DATA_WIDTH = DATA_WIDTH + ID_WIDTH + 1 + 1;

    //=========================================================================
    // Internal Signal Declarations
    //=========================================================================
    
    // FIFO write interface (from input side)
    logic [NUM_PRIORITIES-1:0]              fifo_wr_en;     // Write enable per queue
    logic [FIFO_DATA_WIDTH-1:0]             fifo_wr_data;   // Data to write (shared)
    
    // FIFO read interface (to output side)
    logic [NUM_PRIORITIES-1:0]              fifo_rd_en;     // Read enable per queue
    logic [FIFO_DATA_WIDTH-1:0]             fifo_rd_data [NUM_PRIORITIES]; // Data from each queue
    logic [NUM_PRIORITIES-1:0]              fifo_empty;     // Per-queue empty flags
    
    // FIFO level tracking
    logic [ADDR_WIDTH:0]                    fifo_count [NUM_PRIORITIES]; // Items in each FIFO
    
    // Packet completion tracking (per queue)
    logic [7:0]                             complete_count [NUM_PRIORITIES]; // Complete packets per queue
    logic [NUM_PRIORITIES-1:0]              has_complete;   // Queue has at least 1 complete packet
    
    // Input handling
    logic                                   input_transfer; // Valid transfer on input
    logic [NUM_PRIORITIES-1:0]              receiving_partial; // Currently receiving (SOP seen, no EOP yet)
    
    // Output handling  
    logic                                   output_transfer; // Valid transfer on output
    logic [PRIORITY_WIDTH-1:0]              locked_priority; // Locked priority during active packet
    logic                                   out_in_progress; // Mid-packet output active
    
    // Arbiter
    logic [PRIORITY_WIDTH-1:0]              selected_priority; // Highest priority with complete packet
    logic                                   any_complete;   // At least one queue has complete packet

    //=========================================================================
    // Input Transfer Detection
    //=========================================================================
    
    // A transfer happens when both valid and ready are high
    assign input_transfer = pkt_valid && pkt_ready;

    //=========================================================================
    // Partial Packet Tracking (per queue)
    //=========================================================================
    //
    // Track if we're in the middle of receiving a packet for each queue.
    // receiving_partial[i] = 1 means we've seen SOP but not EOP yet.
    //
    // This is used for error detection:
    //   - SOP when receiving_partial = 1 → Error! Previous packet incomplete
    //   - Data when receiving_partial = 0 and !SOP → Error! No packet started
    //   - EOP when receiving_partial = 0 → Error! No packet to end
    //
    //=========================================================================
    
    genvar i;  // Declared once, used in all generate blocks
    
    // Partial packet tracking - using simple if-else for each queue
    // Queue 0
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            receiving_partial[0] <= 1'b0;
        end
        else if (input_transfer && pkt_priority == 2'd0) begin
            if (pkt_sop && pkt_eop)
                receiving_partial[0] <= 1'b0;
            else if (pkt_sop)
                receiving_partial[0] <= 1'b1;
            else if (pkt_eop)
                receiving_partial[0] <= 1'b0;
        end
    end
    
    // Queue 1
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            receiving_partial[1] <= 1'b0;
        end
        else if (input_transfer && pkt_priority == 2'd1) begin
            if (pkt_sop && pkt_eop)
                receiving_partial[1] <= 1'b0;
            else if (pkt_sop)
                receiving_partial[1] <= 1'b1;
            else if (pkt_eop)
                receiving_partial[1] <= 1'b0;
        end
    end
    
    // Queue 2
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            receiving_partial[2] <= 1'b0;
        end
        else if (input_transfer && pkt_priority == 2'd2) begin
            if (pkt_sop && pkt_eop)
                receiving_partial[2] <= 1'b0;
            else if (pkt_sop)
                receiving_partial[2] <= 1'b1;
            else if (pkt_eop)
                receiving_partial[2] <= 1'b0;
        end
    end
    
    // Queue 3
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            receiving_partial[3] <= 1'b0;
        end
        else if (input_transfer && pkt_priority == 2'd3) begin
            if (pkt_sop && pkt_eop)
                receiving_partial[3] <= 1'b0;
            else if (pkt_sop)
                receiving_partial[3] <= 1'b1;
            else if (pkt_eop)
                receiving_partial[3] <= 1'b0;
        end
    end

    //=========================================================================
    // Error Detection Logic
    //=========================================================================
    //
    // Detect malformed packets and flag errors. Errors are pulses (1 cycle).
    //
    // Error conditions:
    //   1. SOP_WITHOUT_EOP: SOP arrives while receiving_partial = 1
    //      → Previous packet was incomplete, discarding it
    //   2. DATA_WITHOUT_SOP: Data (no SOP) arrives while receiving_partial = 0
    //      → Data without a packet start, ignoring it
    //   3. EOP_WITHOUT_SOP: EOP (no SOP) arrives while receiving_partial = 0
    //      → End without a start, ignoring it
    //
    //=========================================================================
    
    logic err_sop_mid_pkt;      // SOP while receiving partial
    logic err_data_no_start;    // Data without SOP
    logic err_eop_no_start;     // EOP without SOP
    logic err_curr_partial;     // Muxed receiving_partial for error detection
    
    // Mux for error detection
    always_comb begin
        case (pkt_priority)
            2'd0: err_curr_partial = receiving_partial[0];
            2'd1: err_curr_partial = receiving_partial[1];
            2'd2: err_curr_partial = receiving_partial[2];
            2'd3: err_curr_partial = receiving_partial[3];
            default: err_curr_partial = 1'b0;
        endcase
    end
    
    always_comb begin
        err_sop_mid_pkt   = 1'b0;
        err_data_no_start = 1'b0;
        err_eop_no_start  = 1'b0;
        error_queue       = '0;
        
        if (input_transfer) begin
            // Check if current queue is in partial receive state
            if (pkt_sop && err_curr_partial) begin
                // ERROR: SOP received but previous packet not complete
                err_sop_mid_pkt = 1'b1;
                case (pkt_priority)
                    2'd0: error_queue[0] = 1'b1;
                    2'd1: error_queue[1] = 1'b1;
                    2'd2: error_queue[2] = 1'b1;
                    2'd3: error_queue[3] = 1'b1;
                    default: ;
                endcase
            end
            
            if (!pkt_sop && !err_curr_partial) begin
                // Data or EOP without a started packet
                if (pkt_eop) begin
                    // ERROR: EOP without SOP
                    err_eop_no_start = 1'b1;
                end
                else begin
                    // ERROR: Data without SOP
                    err_data_no_start = 1'b1;
                end
                case (pkt_priority)
                    2'd0: error_queue[0] = 1'b1;
                    2'd1: error_queue[1] = 1'b1;
                    2'd2: error_queue[2] = 1'b1;
                    2'd3: error_queue[3] = 1'b1;
                    default: ;
                endcase
            end
        end
    end
    
    // Register error outputs for clean timing
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_sop_without_eop  <= 1'b0;
            error_data_without_sop <= 1'b0;
            error_eop_without_sop  <= 1'b0;
        end
        else begin
            error_sop_without_eop  <= err_sop_mid_pkt;
            error_data_without_sop <= err_data_no_start;
            error_eop_without_sop  <= err_eop_no_start;
        end
    end
    
    //=========================================================================
    // Error Handling Notes
    //=========================================================================
    //
    // LIMITATION: When SOP arrives mid-packet (error_sop_without_eop):
    //   - The partial packet data is already in the FIFO
    //   - We cannot easily "unwrite" this data
    //   - The new packet starts, but old partial data remains
    //   - This corrupts the FIFO contents for that priority queue
    //
    // MITIGATION:
    //   - Error flags indicate corruption occurred
    //   - Testbench/verification should check error flags
    //   - In production, upstream should not send malformed packets
    //
    // FUTURE ENHANCEMENT:
    //   - Add rollback pointers to discard partial packets
    //   - Or add packet boundary markers in FIFO
    //
    //=========================================================================
    
    //=========================================================================
    // Per-Priority Ready Logic (Back-Pressure)
    //=========================================================================
    
    // Ready is based on the TARGET queue (the one indicated by pkt_priority)
    // We use almost_full for hysteresis to avoid rapid toggling
    logic target_almost_full;
    
    always_comb begin
        case (pkt_priority)
            2'd0: target_almost_full = fifo_almost_full[0];
            2'd1: target_almost_full = fifo_almost_full[1];
            2'd2: target_almost_full = fifo_almost_full[2];
            2'd3: target_almost_full = fifo_almost_full[3];
            default: target_almost_full = 1'b1;
        endcase
    end
    
    assign pkt_ready = ~target_almost_full;
    
    //=========================================================================
    // Global Status Signals
    //=========================================================================
    
    // Full = ALL queues are full
    assign full = &fifo_full;
    
    // Almost full = ANY queue is at threshold
    assign almost_full = |fifo_almost_full;
    
    // Empty = no complete packets available anywhere
    assign empty = ~any_complete;
    
    // Any queue has a complete packet?
    assign any_complete = |has_complete;
    
    // Priority status = which queues have complete packets ready
    assign priority_status = has_complete;

    //=========================================================================
    // FIFO Write Data Packing
    //=========================================================================
    //
    // We pack multiple fields into one FIFO entry:
    //   [DATA_WIDTH-1:0]     = pkt_data (8 bits)
    //   [+ID_WIDTH-1:0]      = pkt_id   (6 bits)  
    //   [+1]                 = pkt_sop  (1 bit)
    //   [+1]                 = pkt_eop  (1 bit)
    //   Total: 8 + 6 + 1 + 1 = 16 bits per FIFO entry
    //
    //=========================================================================
    
    assign fifo_wr_data = {pkt_eop, pkt_sop, pkt_id, pkt_data};
    
    //=========================================================================
    // FIFO Write Enable - Route to Correct Queue
    //=========================================================================
    //
    // Only ONE queue receives data at a time, based on pkt_priority.
    // Write happens when we have a valid transfer (valid && ready).
    //
    // Error handling:
    //   - Data without SOP: Do NOT write (ignore orphan data)
    //   - EOP without SOP: Do NOT write (ignore orphan EOP)
    //   - SOP while partial: DO write (start new packet, discard old)
    //
    //=========================================================================
    
    logic valid_write;  // Should we actually write to FIFO?
    logic current_receiving_partial;  // Muxed receiving_partial for current priority
    
    // Explicit mux for receiving_partial to avoid dynamic indexing issues
    always_comb begin
        case (pkt_priority)
            2'd0: current_receiving_partial = receiving_partial[0];
            2'd1: current_receiving_partial = receiving_partial[1];
            2'd2: current_receiving_partial = receiving_partial[2];
            2'd3: current_receiving_partial = receiving_partial[3];
            default: current_receiving_partial = 1'b0;
        endcase
    end
    
    always_comb begin
        fifo_wr_en = '0;  // Default: no writes
        valid_write = 1'b0;
        
        if (input_transfer) begin
            // Determine if this is a valid write
            if (pkt_sop) begin
                // SOP always starts a new packet (even if error - discard old)
                valid_write = 1'b1;
            end
            else if (current_receiving_partial) begin
                // Middle or end of packet - only valid if we're receiving
                valid_write = 1'b1;
            end
            // else: data/EOP without SOP - invalid, don't write
            
            if (valid_write) begin
                // Enable write to the queue matching the priority
                case (pkt_priority)
                    2'd0: fifo_wr_en[0] = 1'b1;
                    2'd1: fifo_wr_en[1] = 1'b1;
                    2'd2: fifo_wr_en[2] = 1'b1;
                    2'd3: fifo_wr_en[3] = 1'b1;
                    default: ; // No write
                endcase
            end
        end
    end

    //=========================================================================
    // FIFO Instances - One per Priority Level
    //=========================================================================
    //
    // Generate 4 identical FIFOs, each handling one priority level.
    // All FIFOs share the same write data bus, but only one is enabled.
    //
    //=========================================================================
    
    generate
        for (i = 0; i < NUM_PRIORITIES; i++) begin : gen_priority_fifos
            
            sync_fifo #(
                .DATA_WIDTH            (FIFO_DATA_WIDTH),
                .DEPTH                 (FIFO_DEPTH),
                .ALMOST_FULL_THRESHOLD (ALMOST_FULL_THRESHOLD),
                .ALMOST_FULL_RELEASE   (ALMOST_FULL_RELEASE)
            ) u_fifo (
                // Clock and reset
                .clk        (clk),
                .rst_n      (rst_n),
                
                // Write interface
                .wr_en      (fifo_wr_en[i]),
                .wr_data    (fifo_wr_data),
                
                // Read interface
                .rd_en      (fifo_rd_en[i]),
                .rd_data    (fifo_rd_data[i]),
                
                // Status
                .full       (fifo_full[i]),
                .empty      (fifo_empty[i]),
                .almost_full(fifo_almost_full[i]),
                .count      (fifo_count[i])
            );
            
        end
    endgenerate

    //=========================================================================
    // Packet Completion Tracking
    //=========================================================================
    //
    // We need to track how many COMPLETE packets are in each queue.
    // A packet is "complete" when we've received its EOP.
    //
    // Rules:
    //   - Increment complete_count when EOP is written to queue
    //   - Decrement complete_count when EOP is read from queue
    //
    // This is critical because we only transmit COMPLETE packets.
    // If a queue has data but no complete packets, we skip it.
    //
    //=========================================================================
    
    // Extract EOP from read data for completion tracking
    logic [NUM_PRIORITIES-1:0] rd_eop;  // EOP bit from each queue's read data
    
    generate
        for (i = 0; i < NUM_PRIORITIES; i++) begin : gen_rd_eop
            // EOP is the MSB of our packed data
            assign rd_eop[i] = fifo_rd_data[i][FIFO_DATA_WIDTH-1];
        end
    endgenerate
    
    // EOP write detection per queue (explicit signals to avoid dynamic indexing issues)
    logic [NUM_PRIORITIES-1:0] wr_eop;  // EOP being written to each queue
    
    assign wr_eop[0] = fifo_wr_en[0] && pkt_eop;
    assign wr_eop[1] = fifo_wr_en[1] && pkt_eop;
    assign wr_eop[2] = fifo_wr_en[2] && pkt_eop;
    assign wr_eop[3] = fifo_wr_en[3] && pkt_eop;
    
    // Debug signal assignments
    assign debug_fifo_wr_en    = fifo_wr_en;
    assign debug_wr_eop        = wr_eop;
    assign debug_input_transfer = input_transfer;
    assign debug_valid_write   = valid_write;
    assign debug_receiving_partial = receiving_partial;
    assign debug_curr_recv_partial = current_receiving_partial;
    
    // Complete packet counter per queue
    generate
        for (i = 0; i < NUM_PRIORITIES; i++) begin : gen_complete_counters
            
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    complete_count[i] <= '0;
                end
                else begin
                    // Simultaneous increment and decrement possible
                    case ({wr_eop[i], fifo_rd_en[i] && rd_eop[i]})
                        2'b10:   complete_count[i] <= complete_count[i] + 1'b1;
                        2'b01:   complete_count[i] <= complete_count[i] - 1'b1;
                        default: complete_count[i] <= complete_count[i];
                    endcase
                end
            end
            
            // Queue has at least one complete packet?
            assign has_complete[i] = (complete_count[i] != '0);
            
        end
    endgenerate
    
    // Total complete packets across all queues
    always_comb begin
        packet_count = '0;
        for (int j = 0; j < NUM_PRIORITIES; j++) begin
            packet_count = packet_count + complete_count[j];
        end
    end

    //=========================================================================
    // Priority Arbiter
    //=========================================================================
    //
    // Selects which queue to read from based on:
    //   1. Queue must have at least one COMPLETE packet (has_complete[i] = 1)
    //   2. Choose highest priority (lowest number) among eligible queues
    //   3. Once transmission starts, LOCK to that priority until EOP
    //
    // Why lock? We can't switch queues mid-packet! Must finish entire item
    // before checking priorities again.
    //
    //=========================================================================
    
    // Find highest priority queue with complete packet (combinational)
    always_comb begin
        selected_priority = '0;  // Default to highest priority
        
        // Priority encoder: check from highest (0) to lowest (3)
        // First match wins
        if (has_complete[0])
            selected_priority = 2'd0;
        else if (has_complete[1])
            selected_priority = 2'd1;
        else if (has_complete[2])
            selected_priority = 2'd2;
        else if (has_complete[3])
            selected_priority = 2'd3;
    end

    //=========================================================================
    // Output State Machine
    //=========================================================================
    //
    // States:
    //   OUT_IDLE        - No output, waiting for complete packet
    //   OUT_TRANSMIT    - Presenting data, locked after first byte transfers
    //
    // Transitions:
    //   OUT_IDLE → OUT_TRANSMIT:   When any queue has a complete packet (no out_ready dependency)
    //   OUT_TRANSMIT → OUT_IDLE:   When EOP is successfully transmitted
    //
    // Priority re-evaluation:
    //   While in OUT_TRANSMIT but before the first byte is accepted (out_packet_locked=0),
    //   active_priority continuously tracks selected_priority. This allows a
    //   higher-priority packet that arrives during back-pressure to take precedence.
    //   Once the first byte transfers, priority is locked until EOP.
    //
    //=========================================================================
    
    typedef enum logic {
        OUT_IDLE,
        OUT_TRANSMIT
    } out_state_t;
    
    out_state_t out_state, out_state_next;
    logic out_packet_locked;
    
    // Combinational priority selector:
    //   Before first byte transfers → use selected_priority directly (zero lag)
    //   After first byte transfers  → use registered locked_priority (locked)
    logic [PRIORITY_WIDTH-1:0] active_priority;
    assign active_priority = out_packet_locked ? locked_priority : selected_priority;
    
    // State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_state <= OUT_IDLE;
            locked_priority <= '0;
            out_packet_locked <= 1'b0;
        end
        else begin
            out_state <= out_state_next;
            
            if (out_state == OUT_TRANSMIT && !out_packet_locked && output_transfer) begin
                // Lock priority on first byte transfer
                locked_priority <= selected_priority;
                out_packet_locked <= 1'b1;
            end
            else if (out_state == OUT_TRANSMIT && output_transfer && out_eop) begin
                out_packet_locked <= 1'b0;
            end
            else if (out_state_next == OUT_IDLE) begin
                out_packet_locked <= 1'b0;
            end
        end
    end
    
    // Next state logic
    always_comb begin
        out_state_next = out_state;
        
        case (out_state)
            OUT_IDLE: begin
                // Enter TRANSMIT when any complete packet exists.
                // No out_ready dependency: AXI-Stream requires TVALID independent of TREADY.
                if (any_complete) begin
                    out_state_next = OUT_TRANSMIT;
                end
            end
            
            OUT_TRANSMIT: begin
                if (output_transfer && out_eop) begin
                    // Return to IDLE after completing a packet.
                    // Gives the arbiter one cycle to re-evaluate with updated complete_count.
                    out_state_next = OUT_IDLE;
                end
            end
        endcase
    end
    
    // Track if we're in middle of transmission
    assign out_in_progress = (out_state == OUT_TRANSMIT);

    //=========================================================================
    // FIFO Read Enable Logic
    //=========================================================================
    //
    // Read from FIFO only on a successful output transfer (valid && ready).
    // Uses active_priority to select which queue to read from.
    //
    //=========================================================================
    
    always_comb begin
        fifo_rd_en = '0;
        
        if (output_transfer) begin
            case (active_priority)
                2'd0: fifo_rd_en[0] = 1'b1;
                2'd1: fifo_rd_en[1] = 1'b1;
                2'd2: fifo_rd_en[2] = 1'b1;
                2'd3: fifo_rd_en[3] = 1'b1;
                default: ;
            endcase
        end
    end
    
    // Output transfer happens when valid and ready
    assign output_transfer = out_valid && out_ready;

    //=========================================================================
    // Output Data Unpacking
    //=========================================================================
    //
    // Extract fields from the selected FIFO's read data:
    //   [7:0]   = data
    //   [13:8]  = id
    //   [14]    = sop
    //   [15]    = eop
    //
    //=========================================================================
    
    // Mux to select read data from current transmitting queue
    logic [FIFO_DATA_WIDTH-1:0] current_rd_data;
    logic                       current_fifo_empty;
    
    always_comb begin
        case (active_priority)
            2'd0: current_rd_data = fifo_rd_data[0];
            2'd1: current_rd_data = fifo_rd_data[1];
            2'd2: current_rd_data = fifo_rd_data[2];
            2'd3: current_rd_data = fifo_rd_data[3];
            default: current_rd_data = '0;
        endcase
    end
    
    always_comb begin
        case (active_priority)
            2'd0: current_fifo_empty = fifo_empty[0];
            2'd1: current_fifo_empty = fifo_empty[1];
            2'd2: current_fifo_empty = fifo_empty[2];
            2'd3: current_fifo_empty = fifo_empty[3];
            default: current_fifo_empty = 1'b1;
        endcase
    end
    
    // Unpack the fields
    assign out_data = current_rd_data[DATA_WIDTH-1:0];
    assign out_id   = current_rd_data[DATA_WIDTH+ID_WIDTH-1:DATA_WIDTH];
    assign out_sop  = current_rd_data[DATA_WIDTH+ID_WIDTH];
    assign out_eop  = current_rd_data[DATA_WIDTH+ID_WIDTH+1];
    
    // Output priority matches what we're transmitting
    assign out_priority = active_priority;

    //=========================================================================
    // Output Valid Logic
    //=========================================================================
    //
    // out_valid is high when:
    //   1. We're in TRANSMIT state
    //   2. The current queue is not empty (should always be true if logic is correct)
    //
    //=========================================================================
    
    assign out_valid = (out_state == OUT_TRANSMIT) && !current_fifo_empty;

endmodule
