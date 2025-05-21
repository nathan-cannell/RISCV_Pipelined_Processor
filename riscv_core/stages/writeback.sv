`ifndef _WRITEBACK_
`define _WRITEBACK_

`include "system.sv"
`include "riscv32_common.sv"

module writeback (
    input logic clk,
    input logic reset,
    
    // Pipeline control signals
    input stage_signal_t writeback_signal_in,
    
    // Memory interface
    input memory_io_rsp data_mem_rsp,
    
    // Input from memory stage
    input memory_instruction_t memory_instruction_in,
    
    // Writeback outputs
    output writeback_instruction_t writeback_instruction_out
);

import riscv::*;

// Writeback data processing
always_comb begin
    writeback_instruction_out = '{
        valid: 1'b0,
        wbs: '0,
        wbd: '0,
        wbv: 1'b0
    };

    if (writeback_signal_in.advance && memory_instruction_in.valid) begin
        writeback_instruction_out.wbs = memory_instruction_in.writeback_instruction.wbs;
        writeback_instruction_out.wbv = memory_instruction_in.writeback_instruction.wbv;
        writeback_instruction_out.valid = memory_instruction_in.writeback_instruction.valid;

        // Handle load instructions
        if (memory_instruction_in.op_q == q_load) begin
            writeback_instruction_out.wbd = subset_load_data(
                shuffle_load_data(data_mem_rsp.data, 
                                memory_instruction_in.writeback_instruction.wbd),
                cast_to_memory_op(memory_instruction_in.f3)
            );
        end else begin
            // ALU results and immediate writes
            writeback_instruction_out.wbd = memory_instruction_in.writeback_instruction.wbd;
        end
    end
end

endmodule
`endif
