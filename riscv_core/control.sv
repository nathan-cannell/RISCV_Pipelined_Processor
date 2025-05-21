`ifndef _CONTROL_
`define _CONTROL_

`include "riscv32_common.sv"

module control (
    input logic clk,
    input logic reset,
    
    // Pipeline stage inputs
    input fetched_instruction_t fetched_instruction_in,
    input decoded_instruction_t decoded_instruction_in,
    input executed_instruction_t executed_instruction_in,
    input memory_instruction_t memory_instruction_in,
    
    // Memory interfaces
    input memory_io_rsp inst_mem_rsp,
    input memory_io_rsp data_mem_rsp,
    
    // Branch prediction
    input pc_control_t pc_control_in,
    
    // Control outputs
    output stage_signal_t fetch_signal_out,
    output stage_signal_t decode_signal_out,
    output stage_signal_t execute_signal_out,
    output stage_signal_t memory_signal_out,
    output stage_signal_t writeback_signal_out,
    
    output fetch_set_pc_call_t fetch_set_pc_call_out
);

import riscv::*;

// Hazard detection signals
logic load_use_hazard;
logic data_hazard;
logic control_hazard;

// Forwarding paths
logic forward_rs1_ex;
logic forward_rs2_ex;
logic forward_rs1_mem;
logic forward_rs2_mem;

always_comb begin
    // Default: advance all stages, no flushes
    fetch_signal_out = '{advance: 1'b1, flush: 1'b0};
    decode_signal_out = '{advance: 1'b1, flush: 1'b0};
    execute_signal_out = '{advance: 1'b1, flush: 1'b0};
    memory_signal_out = '{advance: 1'b1, flush: 1'b0};
    writeback_signal_out = '{advance: 1'b1, flush: 1'b0};
    
    fetch_set_pc_call_out = '{valid: 1'b0, pc: '0};

    // Data hazard detection
    data_hazard = 1'b0;
    if (decoded_instruction_in.valid) begin
        // EX hazard
        if (executed_instruction_in.writeback_instruction.valid &&
            executed_instruction_in.writeback_instruction.wbv) begin
            if (decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs ||
                decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs) begin
                data_hazard = 1'b1;
            end
        end
        
        // MEM hazard
        if (memory_instruction_in.writeback_instruction.valid &&
            memory_instruction_in.writeback_instruction.wbv) begin
            if (decoded_instruction_in.rs1 == memory_instruction_in.writeback_instruction.wbs ||
                decoded_instruction_in.rs2 == memory_instruction_in.writeback_instruction.wbs) begin
                data_hazard = 1'b1;
            end
        end
    end

    // Load-use hazard detection
    load_use_hazard = 1'b0;
    if (executed_instruction_in.valid && 
        executed_instruction_in.op_q == q_load &&
        (decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs ||
         decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs)) begin
        load_use_hazard = 1'b1;
    end

    // Control hazard handling
    control_hazard = pc_control_in.fetch_mispredict;
    if (control_hazard) begin
        fetch_signal_out.flush = 1'b1;
        decode_signal_out.flush = 1'b1;
        execute_signal_out.flush = 1'b1;
        fetch_set_pc_call_out = '{valid: 1'b1, pc: pc_control_in.correct_pc};
    end

    // Stall logic
    if (data_hazard || load_use_hazard) begin
        fetch_signal_out.advance = 1'b0;
        decode_signal_out.advance = 1'b0;
        execute_signal_out.advance = 1'b0;
    end
end

endmodule
`endif
