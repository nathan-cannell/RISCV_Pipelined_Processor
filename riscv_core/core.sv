`ifndef _riscv_multicycle
`define _riscv_multicycle

`include "base.sv"
`include "system.sv"
`include "riscv.sv"

module core (
    input logic       clk,
    input logic      reset,
    input logic      [`word_address_size-1:0] reset_pc,
    output memory_io_req   inst_mem_req,
    input  memory_io_rsp   inst_mem_rsp,
    output memory_io_req   data_mem_req,
    input  memory_io_rsp   data_mem_rsp
);

import riscv::*;

// Pipeline stage interfaces
stage_signal_t fetch_signal, decode_signal, execute_signal, memory_signal, writeback_signal;
fetch_set_pc_call_t fetch_set_pc_call;
fetch_set_pc_return_t fetch_set_pc_return;
fetched_instruction_t fetched_instruction;
reg_file_bypass_t reg_file_bypass;
decoded_instruction_t decoded_instruction;
writeback_instruction_t writeback_instruction;
executed_instruction_t executed_instruction;
pc_control_t pc_control;
memory_instruction_t memory_instruction;

// Fetch stage
fetch fetch_m (
    .clk(clk),
    .reset(reset),
    .reset_pc(reset_pc),
    .fetch_signal_in(fetch_signal),
    .fetch_set_pc_call_in(fetch_set_pc_call),
    .fetch_set_pc_return_out(fetch_set_pc_return),
    .inst_mem_req(inst_mem_req),
    .inst_mem_rsp(inst_mem_rsp),
    .fetched_instruction_out(fetched_instruction)
);

// Decode and writeback stage
decode_and_writeback decode_and_writeback_m (
    .clk(clk),
    .reset(reset),
    .decode_signal_in(decode_signal),
    .execute_signal_in(execute_signal),
    .writeback_signal_in(writeback_signal),
    .reg_file_bypass_out(reg_file_bypass),
    .fetched_instruction_in(fetched_instruction),
    .decoded_instruction_out(decoded_instruction),
    .writeback_instruction_in(writeback_instruction)
);

// Execute stage
execute execute_m (
    .clk(clk),
    .reset(reset),
    .reset_pc(reset_pc),
    .execute_signal_in(execute_signal),
    .memory_signal_in(memory_signal),
    .fetched_instruction_in(fetched_instruction),
    .reg_file_bypass_in(reg_file_bypass),
    .executed_instruction_in(executed_instruction),
    .writeback_instruction_in(writeback_instruction),
    .decoded_instruction_in(decoded_instruction),
    .executed_instruction_out(executed_instruction),
    .pc_control_out(pc_control)
);

// Memory stage
memory memory_m (
    .clk(clk),
    .reset(reset),
    .memory_signal_in(memory_signal),
    .writeback_signal_in(writeback_signal),
    .writeback_instruction_in(writeback_instruction),
    .reg_file_bypass_in(reg_file_bypass),
    .data_mem_req(data_mem_req),
    .data_mem_rsp(data_mem_rsp),
    .executed_instruction_in(executed_instruction),
    .memory_instruction_out(memory_instruction)
);

// Writeback stage
writeback writeback_m (
    .writeback_signal_in(writeback_signal),
    .data_mem_rsp(data_mem_rsp),
    .memory_instruction_in(memory_instruction),
    .writeback_instruction_out(writeback_instruction)
);

// Control unit
control control_m (
    .inst_mem_rsp(inst_mem_rsp),
    .data_mem_rsp(data_mem_rsp),
    .pc_control_in(pc_control),
    .fetched_instruction_in(fetched_instruction),
    .decoded_instruction_in(decoded_instruction),
    .executed_instruction_in(executed_instruction),
    .memory_instruction_in(memory_instruction),
    .fetch_signal_out(fetch_signal),
    .decode_signal_out(decode_signal),
    .execute_signal_out(execute_signal),
    .memory_signal_out(memory_signal),
    .writeback_signal_out(writeback_signal),
    .fetch_set_pc_call_out(fetch_set_pc_call)
);

endmodule
`endif
