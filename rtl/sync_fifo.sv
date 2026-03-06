//-----------------------------------------------------------------------------
// Module: sync_fifo
// 
// Description:
//   Synchronous FIFO with configurable depth and data width.
//   Single clock domain, used for priority queue storage.
//
// Features:
//   - Configurable depth and width
//   - Full/empty flags
//   - Almost full with configurable threshold and hysteresis
//   - Item count output
//   - First-word fall-through (data available immediately on read)
//-----------------------------------------------------------------------------

module sync_fifo #(
    parameter DATA_WIDTH            = 8,        // Width of data
    parameter DEPTH                 = 256,      // Number of entries
    parameter ALMOST_FULL_THRESHOLD = 240,      // Assert almost_full
    parameter ALMOST_FULL_RELEASE   = 224       // Deassert almost_full (hysteresis)
)(
    //-------------------------------------------------------------------------
    // Clock and Reset
    //-------------------------------------------------------------------------
    input  logic                        clk,
    input  logic                        rst_n,
    
    //-------------------------------------------------------------------------
    // Write Interface
    //-------------------------------------------------------------------------
    input  logic                        wr_en,      // Write enable
    input  logic [DATA_WIDTH-1:0]       wr_data,    // Data to write
    
    //-------------------------------------------------------------------------
    // Read Interface
    //-------------------------------------------------------------------------
    input  logic                        rd_en,      // Read enable
    output logic [DATA_WIDTH-1:0]       rd_data,    // Data read out
    
    //-------------------------------------------------------------------------
    // Status Outputs
    //-------------------------------------------------------------------------
    output logic                        full,       // FIFO is full
    output logic                        empty,      // FIFO is empty
    output logic                        almost_full,// At threshold
    output logic [$clog2(DEPTH):0]      count       // Current item count
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam ADDR_WIDTH = $clog2(DEPTH);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    
    // Memory array - this is where data is stored
    logic [DATA_WIDTH-1:0] mem [DEPTH];
    
    // Pointers
    logic [ADDR_WIDTH-1:0] wr_ptr;  // Write pointer (where to write next)
    logic [ADDR_WIDTH-1:0] rd_ptr;  // Read pointer (where to read next)
    
    // Item counter (one extra bit to distinguish full from empty)
    logic [ADDR_WIDTH:0] item_count;
    
    // Almost full register (for hysteresis)
    logic almost_full_reg;

    //=========================================================================
    // Write Logic
    //=========================================================================
    
    // Separate pointer update and memory write for cleaner synthesis
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
        end
        else if (wr_en && !full) begin
            // Increment write pointer (wraps automatically)
            wr_ptr <= wr_ptr + 1'b1;
        end
    end
    
    // Memory write - separate always block
    always_ff @(posedge clk) begin
        if (wr_en && !full) begin
            mem[wr_ptr] <= wr_data;
        end
    end

    //=========================================================================
    // Read Logic
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= '0;
        end
        else if (rd_en && !empty) begin
            // Increment read pointer (wraps automatically)
            rd_ptr <= rd_ptr + 1'b1;
        end
    end
    
    // Read data comes directly from memory (combinational)
    // This gives us "first-word fall-through" behavior
    assign rd_data = mem[rd_ptr];

    //=========================================================================
    // Item Counter
    //=========================================================================
    
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

    //=========================================================================
    // Status Flags
    //=========================================================================
    
    // Full when counter equals depth
    assign full = (item_count == DEPTH);
    
    // Empty when counter is zero
    assign empty = (item_count == '0);
    
    // Count output
    assign count = item_count;

    //=========================================================================
    // Almost Full with Hysteresis
    //=========================================================================
    // 
    // Hysteresis prevents rapid toggling:
    // - Assert almost_full when count >= ALMOST_FULL_THRESHOLD (240)
    // - Deassert almost_full when count < ALMOST_FULL_RELEASE (224)
    // - Stay in current state when count is between 224-239
    //
    //  Count:  0 -------- 224 -------- 240 -------- 256
    //                      ^            ^
    //                  RELEASE      THRESHOLD
    //
    //  almost_full: 0 → stays 0 → goes 1 when >= 240
    //  almost_full: 1 → stays 1 → goes 0 when < 224
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            almost_full_reg <= 1'b0;
        end
        else begin
            if (item_count >= ALMOST_FULL_THRESHOLD) begin
                // Above threshold: assert almost_full
                almost_full_reg <= 1'b1;
            end
            else if (item_count < ALMOST_FULL_RELEASE) begin
                // Below release point: deassert almost_full
                almost_full_reg <= 1'b0;
            end
            // Between RELEASE and THRESHOLD: keep current state (hysteresis)
        end
    end
    
    assign almost_full = almost_full_reg;

endmodule
