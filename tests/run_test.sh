#!/bin/bash
#-----------------------------------------------------------------------------
# Run script for Priority Packet Sorter Testbench
#-----------------------------------------------------------------------------

# Simulator options (choose one)
SIMULATOR="iverilog"  # Options: iverilog, vcs, questa, xsim

# File paths
RTL_DIR="../rtl"
TEST_DIR="."

# RTL files
RTL_FILES=(
    "$RTL_DIR/sync_fifo.sv"
    "$RTL_DIR/priority_packet_sorter.sv"
)

# Testbench files
TB_FILES=(
    "$TEST_DIR/tb_priority_packet_sorter.sv"
)

echo "=========================================="
echo "  Priority Packet Sorter - Test Runner"
echo "=========================================="

case $SIMULATOR in
    "iverilog")
        echo "Using Icarus Verilog..."
        iverilog -g2012 -o sim.vvp ${RTL_FILES[@]} ${TB_FILES[@]}
        if [ $? -eq 0 ]; then
            vvp sim.vvp
        else
            echo "Compilation failed!"
            exit 1
        fi
        ;;
        
    "vcs")
        echo "Using VCS..."
        vcs -sverilog -timescale=1ns/1ps ${RTL_FILES[@]} ${TB_FILES[@]} -o simv
        if [ $? -eq 0 ]; then
            ./simv
        else
            echo "Compilation failed!"
            exit 1
        fi
        ;;
        
    "questa")
        echo "Using Questa/ModelSim..."
        vlib work
        vlog -sv ${RTL_FILES[@]} ${TB_FILES[@]}
        if [ $? -eq 0 ]; then
            vsim -c -do "run -all; quit" tb_priority_packet_sorter
        else
            echo "Compilation failed!"
            exit 1
        fi
        ;;
        
    "xsim")
        echo "Using Xilinx Vivado Simulator..."
        xvlog -sv ${RTL_FILES[@]} ${TB_FILES[@]}
        if [ $? -eq 0 ]; then
            xelab -debug typical tb_priority_packet_sorter -s sim_snapshot
            xsim sim_snapshot -runall
        else
            echo "Compilation failed!"
            exit 1
        fi
        ;;
        
    *)
        echo "Unknown simulator: $SIMULATOR"
        exit 1
        ;;
esac

echo "=========================================="
echo "  Simulation Complete"
echo "=========================================="
