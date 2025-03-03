`ifndef _riscv_multicycle
`define _riscv_multicycle

/*

This is a very simple 5 stage multicycle RISC-V 32bit design.

The stages are fetch, decode, execute, memory, writeback

*/

`include "base.sv"  // Assuming this defines `word_size`, `word_address_size`, etc.
`include "system.sv" // Assuming this defines memory_io_* types
`include "riscv.sv"  // Assuming this includes the definitions from paste.txt

module core (
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc
    ,output memory_io_req   inst_mem_req
    ,input  memory_io_rsp   inst_mem_rsp
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp);

import riscv::*;  // Import the package

/*

 Instruction fetch

*/

word_address    pc;
instr32 instruction_read;

// Valid signal for the fetch stage
logic           fetch_valid;

always @(posedge clk) begin
    if (reset) begin
        pc <= reset_pc;
        fetch_valid <= 1'b1;  // Start fetching after reset
    end else begin
        if (fetch_valid) begin //We are always fetching as long as fetch_valid is true.
            if(inst_mem_rsp.valid) //If there is a valid response from the instruction memory.
                pc <= pc + 4;
        end
    end
end


always @(*) begin
    inst_mem_req = memory_io_no_req;
    inst_mem_req.addr = pc;
    inst_mem_req.valid = fetch_valid && inst_mem_rsp.ready;
    inst_mem_req.do_read[3:0] = (fetch_valid) ? 4'b1111 : 0;
    instruction_read = shuffle_store_data(inst_mem_rsp.data, inst_mem_rsp.addr);
end

/*

  Pipeline Register: Fetch/Decode

*/

instr32    fetch_decode_instruction;
logic      fetch_decode_valid;

always_ff @(posedge clk) begin
    if (reset) begin
        fetch_decode_instruction <= 32'b0;
        fetch_decode_valid <= 1'b0;
    end else begin
        fetch_decode_instruction <= instruction_read;
        fetch_decode_valid <= fetch_valid && inst_mem_rsp.valid; // Instruction is passed when fetch stage is valid and valid response is ready.

    end
end

/*

  Instruction decode

*/
tag     rs1;
tag     rs2;
word    rd1;
word    rd2;
tag     wbs;
word    wbd;
logic   wbv;
word    reg_file_rd1;
word    reg_file_rd2;
word    imm;
funct3  f3;
funct7  f7;
opcode_q op_q;
instr_format format;
bool     is_memory_op;

word    reg_file[0:31];

//Valid signal for decode stage
logic    decode_valid;

always @(*) begin
    if (fetch_decode_valid) begin
        rs1 = decode_rs1(fetch_decode_instruction);
        rs2 = decode_rs2(fetch_decode_instruction);
        wbs = decode_rd(fetch_decode_instruction);
        f3 = decode_funct3(fetch_decode_instruction);
        op_q = decode_opcode_q(fetch_decode_instruction);
        format = decode_format(op_q);
        imm = decode_imm(fetch_decode_instruction, format);
        wbv = decode_writeback(op_q);
        f7 = decode_funct7(fetch_decode_instruction, format);
        decode_valid = 1'b1;
    end else begin
        rs1 = 0;
        rs2 = 0;
        wbs = 0;
        f3 = 0;
        op_q = q_unknown;
        format = r_format;
        imm = 0;
        wbv = 0;
        f7 = 0;
        decode_valid = 1'b0;
    end
end

logic read_reg_valid;
logic write_reg_valid;

always_ff @(posedge clk) begin
    if (read_reg_valid) begin
        reg_file_rd1 <= reg_file[rs1];
        reg_file_rd2 <= reg_file[rs2];
    end
    else if (write_reg_valid)
        reg_file[wbs] <= wbd;
end

logic memory_stage_complete;
always @(*) begin
    if (op_q == q_load || op_q == q_store) begin
        if (data_mem_rsp.valid)
            memory_stage_complete = true;
        else
            memory_stage_complete = false;
    end else
        memory_stage_complete = true;
end

always @(*) begin
    read_reg_valid = false;
    write_reg_valid = false;
    if (decode_valid) begin
        read_reg_valid = true;
    end

    if (memory_stage_complete && current_stage == stage_writeback && wbv) begin
        write_reg_valid = true;
    end
end

/*
   Pipeline Register: Decode/Execute
*/

// Instruction information
tag     decode_execute_rs1;
tag     decode_execute_rs2;
tag     decode_execute_wbs;
logic   decode_execute_wbv;
funct3  decode_execute_f3;
funct7  decode_execute_f7;
opcode_q decode_execute_op_q;
word    decode_execute_rd1;
word    decode_execute_rd2;
word    decode_execute_imm;

logic   decode_execute_valid;

always_ff @(posedge clk) begin
  if (reset) begin
    decode_execute_valid <= 1'b0;
    decode_execute_rs1   <= 0;
    decode_execute_rs2   <= 0;
    decode_execute_wbs   <= 0;
    decode_execute_wbv   <= 1'b0;
    decode_execute_f3    <= 0;
    decode_execute_f7    <= 0;
    decode_execute_op_q  <= q_unknown;
    decode_execute_rd1   <= 0;
    decode_execute_rd2   <= 0;
    decode_execute_imm   <= 0;
  end else begin
    decode_execute_valid <= decode_valid; //If decode stage is valid then this stage is valid as well.
    decode_execute_rs1   <= rs1;
    decode_execute_rs2   <= rs2;
    decode_execute_wbs   <= wbs;
    decode_execute_wbv   <= wbv;
    decode_execute_f3    <= f3;
    decode_execute_f7    <= f7;
    decode_execute_op_q  <= op_q;
    decode_execute_rd1   <= reg_file_rd1;
    decode_execute_rd2   <= reg_file_rd2;
    decode_execute_imm   <= imm;
  end
end

/*

 Instruction execute

 */

word    rd1_execute;
word    rd2_execute;

always_comb begin
    if (decode_execute_rs1 == `tag_size'd0)
        rd1_execute = `word_size'd0;
    else
        rd1_execute = decode_execute_rd1;
    if (decode_execute_rs2 == `tag_size'd0)
        rd2_execute = `word_size'd0;
    else
        rd2_execute = decode_execute_rd2;
end

ext_operand exec_result_comb;
word next_pc_comb;

//Valid signal for execute stage
logic execute_valid;

always @(*) begin
    if (decode_execute_valid) begin
        exec_result_comb = execute(
            cast_to_ext_operand(rd1_execute),
            cast_to_ext_operand(rd2_execute),
            cast_to_ext_operand(decode_execute_imm),
            pc,
            decode_execute_op_q,
            decode_execute_f3,
            decode_execute_f7);
        next_pc_comb = compute_next_pc(
            cast_to_ext_operand(rd1_execute),
            exec_result_comb,
            decode_execute_imm,
            pc,
            decode_execute_op_q,
            decode_execute_f3);
        execute_valid <= 1'b1;
    end else begin
        exec_result_comb = 0;
        next_pc_comb = 0;
        execute_valid <= 1'b0;
    end
end

word exec_result;
word next_pc;
always_ff @(posedge clk) begin
    if (execute_valid) begin

        exec_result <= exec_result_comb[`word_size-1:0];
        next_pc <= next_pc_comb;

    end
end

/*

  Pipeline Register: Execute/Memory

*/

word execute_memory_exec_result;
word execute_memory_next_pc;
tag  execute_memory_wbs;
logic execute_memory_wbv;
opcode_q execute_memory_op_q;
funct3 execute_memory_f3;

logic execute_memory_valid;

always_ff @(posedge clk) begin
  if (reset) begin
    execute_memory_valid <= 1'b0;
    execute_memory_exec_result <= 0;
    execute_memory_next_pc   <= 0;
    execute_memory_wbs      <= 0;
    execute_memory_wbv      <= 1'b0;
    execute_memory_op_q     <= q_unknown;
    execute_memory_f3       <= 0;
  end else begin
    execute_memory_valid <= execute_valid;
    execute_memory_exec_result <= exec_result;
    execute_memory_next_pc   <= next_pc;
    execute_memory_wbs      <= decode_execute_wbs;
    execute_memory_wbv      <= decode_execute_wbv;
    execute_memory_op_q     <= decode_execute_op_q;
    execute_memory_f3       <= decode_execute_f3;
  end
end


/*

  Stage and mem

 */

//Valid signal for memory stage
logic memory_valid;

always @(*) begin
    data_mem_req = memory_io_no_req;
    if (execute_memory_valid) begin
        if(execute_memory_op_q == q_store || execute_memory_op_q == q_load) begin
          data_mem_req.addr = exec_result[`word_address_size - 1:0];
          data_mem_req.valid = true;
          if(execute_memory_op_q == q_store) begin
            data_mem_req.do_write = shuffle_store_mask(memory_mask(cast_to_memory_op(execute_memory_f3)), exec_result);
            //data_mem_req.data = shuffle_store_data(rd2, exec_result);
          end else begin
            data_mem_req.do_read = shuffle_store_mask(memory_mask(cast_to_memory_op(execute_memory_f3)), exec_result);
          end
          memory_valid <= 1'b1;
        end else begin
            memory_valid <= 1'b0;
        end
    end else begin
        memory_valid <= 1'b0;
    end
end

word load_result;
always_ff @(posedge clk) begin
    if (data_mem_rsp.valid)
        load_result <= data_mem_rsp.data;
end

always @(*) begin
    if (execute_memory_op_q == q_load)
        wbd = subset_load_data(
                    shuffle_load_data(data_mem_rsp.valid ? data_mem_rsp.data : load_result, exec_result),
                    cast_to_memory_op(execute_memory_f3));
    else
        wbd = exec_result;

end

/*

  Pipeline Register: Memory / Writeback

*/

word memory_writeback_wbd;
tag  memory_writeback_wbs;
logic memory_writeback_wbv;
opcode_q memory_writeback_op_q;

logic memory_writeback_valid;

always_ff @(posedge clk) begin
  if (reset) begin
    memory_writeback_valid <= 1'b0;
    memory_writeback_wbd   <= 0;
    memory_writeback_wbs   <= 0;
    memory_writeback_wbv   <= 1'b0;
    memory_writeback_op_q  <= q_unknown;
  end else begin
    memory_writeback_valid <= memory_valid;
    memory_writeback_wbd   <= wbd;
    memory_writeback_wbs   <= execute_memory_wbs;
    memory_writeback_wbv   <= execute_memory_wbv;
    memory_writeback_op_q  <= execute_memory_op_q;
  end
end

/*

 Writeback

 */

//Valid signal for writeback stage
logic writeback_valid;

always @(*) begin
    writeback_valid = memory_writeback_valid; //Writeback is valid if data is available.
    if (writeback_valid && memory_writeback_wbv) begin
        write_reg_valid = true;
        wbd = memory_writeback_wbd;
        wbs = memory_writeback_wbs;
    end else begin
        write_reg_valid = false;
    end
end

/*

 Stage control

 */
//Removed the old stage control
//Since there are valid signals for all of them.

endmodule
`endif
