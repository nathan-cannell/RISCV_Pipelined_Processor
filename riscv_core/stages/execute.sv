`ifndef _EXECUTE_
`define _EXECUTE_

`include "riscv32_common.sv"

module execute (
    input  logic clk,
    input  logic reset,
    input  riscv::word reset_pc,

    // Pipeline control signals
    input  stage_signal_t execute_signal_in,
    input  stage_signal_t memory_signal_in,

    // For branch mispredict detection
    input  fetched_instruction_t fetched_instruction_in,

    // Forwarding/bypassing
    input  reg_file_bypass_t reg_file_bypass_in,
    input  executed_instruction_t executed_instruction_in,
    input  writeback_instruction_t writeback_instruction_in,

    // Datapath
    input  decoded_instruction_t  decoded_instruction_in,
    output executed_instruction_t executed_instruction_out,
    output pc_control_t           pc_control_out
);

import riscv::*;

word pc;
ext_operand exec_result_comb;
word next_pc_comb;
word exec_bypassed_rd1_comb;
word exec_bypassed_rd2_comb;

// Forwarding logic and operand selection
always @(*) begin
    word rd1, rd2;
    // Register x0 is always zero
    rd1 = (decoded_instruction_in.rs1 == 5'd0) ? `word_size'd0 : decoded_instruction_in.rd1;
    rd2 = (decoded_instruction_in.rs2 == 5'd0) ? `word_size'd0 : decoded_instruction_in.rd2;

    exec_bypassed_rd1_comb = rd1;
    exec_bypassed_rd2_comb = rd2;

    // ALU/execute operation
    exec_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(decoded_instruction_in.imm),
        decoded_instruction_in.pc,
        decoded_instruction_in.op_q,
        decoded_instruction_in.f3,
        decoded_instruction_in.f7
    );

    // Next PC calculation (for branch/jump)
    next_pc_comb = compute_next_pc(
        cast_to_ext_operand(rd1),
        exec_result_comb,
        decoded_instruction_in.imm,
        decoded_instruction_in.pc,
        decoded_instruction_in.op_q,
        decoded_instruction_in.f3
    );

    // Default: no mispredict
    pc_control_out = '{default:0};
    pc_control_out.fetch_mispredict = 1'b0;

    // Branch/jump misprediction detection
    if (decoded_instruction_in.valid && next_pc_comb != fetched_instruction_in.pc) begin
        pc_control_out.fetch_mispredict = 1'b1;
        pc_control_out.correct_pc = next_pc_comb;
    end

    // PC mismatch (should not normally happen)
    if (decoded_instruction_in.valid && decoded_instruction_in.pc != pc) begin
        pc_control_out.wrong_pc = 1'b1;
        pc_control_out.correct_pc = pc;
    end
end

// Pipeline register and output logic
always_ff @(posedge clk) begin
    if (reset) begin
        executed_instruction_out.valid <= 1'b0;
        pc <= reset_pc;
    end else begin
        if (decoded_instruction_in.valid && execute_signal_in.advance) begin
            if (decoded_instruction_in.pc == pc) begin
                executed_instruction_out.valid <= 1'b1;
                pc <= next_pc_comb;
            end else begin
                // Flush this instruction if PC doesn't match
                executed_instruction_out.valid <= 1'b0;
            end

            executed_instruction_out.rd1 <= exec_bypassed_rd1_comb;
            executed_instruction_out.rd2 <= exec_bypassed_rd2_comb;
            executed_instruction_out.rs1 <= decoded_instruction_in.rs1;
            executed_instruction_out.rs2 <= decoded_instruction_in.rs2;
            executed_instruction_out.writeback_instruction.wbs  <= decoded_instruction_in.wbs;
            executed_instruction_out.writeback_instruction.wbv  <= decoded_instruction_in.wbv;
            executed_instruction_out.writeback_instruction.wbd  <= exec_result_comb[`word_size-1:0];
            executed_instruction_out.writeback_instruction.valid<= decoded_instruction_in.valid;
            executed_instruction_out.f3  <= decoded_instruction_in.f3;
            executed_instruction_out.op_q<= decoded_instruction_in.op_q;
        end else if (memory_signal_in.advance) begin
            executed_instruction_out <= '{default:0};
            executed_instruction_out.valid <= 1'b0;
        end
    end
end

endmodule
`endif
