`ifndef _core_v
`define _core_v
`include "system.sv"
`include "base.sv"
`include "memory_io.sv"
`include "memory.sv"

/*

This is a very simple 5 stage multicycle RISC-V 32bit design.

The stages are fetch, decode, execute, memory, writeback

*/

`include "base.sv"
`include "system.sv"
`include "memory_io.sv"


module core(
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc
    ,output memory_io_req   inst_mem_req
    ,input  memory_io_rsp   inst_mem_rsp
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp
    );

`include "riscv32_common.sv"

typedef enum {
    stage_fetch
    ,stage_decode
    ,stage_execute
    ,stage_mem
    ,stage_writeback
}   stage;

stage   current_stage;


word_address    pc;

assign inst_mem_req.addr = pc;
assign inst_mem_req.valid = inst_mem_rsp.ready && (stage_fetch == current_stage);
assign inst_mem_req.do_read = (stage_fetch == current_stage) ? 4'b1111 : 0;

instr32    latched_instruction_read;
always_ff @(posedge clk) begin
    if (inst_mem_rsp.valid) begin
        latched_instruction_read <= inst_mem_rsp.data;
    end

end

instr32    fetched_instruction;
assign fetched_instruction = (inst_mem_rsp.valid) ? inst_mem_rsp.data : latched_instruction_read;

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

always_comb begin
    rs1 = decode_rs1(fetched_instruction);
    rs2 = decode_rs2(fetched_instruction);
    wbs = decode_rd(fetched_instruction);
    f3 = decode_funct3(fetched_instruction);
    op_q = decode_opcode_q(fetched_instruction);
    format = decode_format(op_q);
    imm = decode_imm(fetched_instruction, format);
    wbv = decode_writeback(op_q);
    f7 = decode_funct7(fetched_instruction, format);
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
always_comb begin
    if (op_q == q_load || op_q == q_store) begin
        if (data_mem_rsp.valid)
            memory_stage_complete = true;
        else
            memory_stage_complete = false;
    end else
        memory_stage_complete = true;
end

always_comb begin
    read_reg_valid = false;
    write_reg_valid = false;
    if (current_stage == stage_decode) begin
        read_reg_valid = true;
    end

    if (memory_stage_complete && current_stage == stage_writeback && wbv) begin
        write_reg_valid = true;
    end
end

/*

 Instruction execute

 */

always_comb begin
    if (rs1 == `tag_size'd0)
        rd1 = `word_size'd0;
    else
        rd1 = reg_file_rd1;        
    if (rs2 == `tag_size'd0)
        rd2 = `word_size'd0;
    else
        rd2 = reg_file_rd2;        
end

ext_operand exec_result_comb;
word next_pc_comb;
always_comb begin
    exec_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(imm),
        pc,
        op_q,
        f3,
        f7);
    next_pc_comb = pc + 4;
end

word exec_result;
word next_pc;
always_ff @(posedge clk) begin
    if (current_stage == stage_execute) begin
        exec_result <= exec_result_comb[`word_size-1:0];
        next_pc <= next_pc_comb;
    end
end

/*

  Stage and mem

 */

always_comb begin
    /*
    data_mem_req.valid = false;
    data_mem_req.do_read = {(`word_address_size/8){1'b0}};
    data_mem_req.do_write = {(`word_address_size/8){1'b0}};
    data_mem_req.addr = {(`word_address_size){1'b0}};
    data_mem_req.data = {(`word_size){1'b0}};
    */
    // This effectively does the above.  The above is there for documentation
    data_mem_req = memory_io_no_req32;

    if (data_mem_rsp.ready && current_stage == stage_mem && (op_q == q_store || op_q == q_load)) begin
        data_mem_req.addr = exec_result[`word_address_size - 1:0];
        if (op_q == q_store) begin
            data_mem_req.valid = true;
            data_mem_req.do_write = shuffle_store_mask(memory_mask(cast_to_memory_op(f3)), exec_result);
            data_mem_req.data = shuffle_store_data(rd2, exec_result);
        end else
        if (op_q == q_load) begin
            data_mem_req.valid = true;
            data_mem_req.do_read = shuffle_store_mask(memory_mask(cast_to_memory_op(f3)), exec_result);
        end
    end
end

word load_result;
always_ff @(posedge clk) begin
    if (data_mem_rsp.valid)
        load_result <= data_mem_rsp.data;
end

always_comb begin
    if (op_q == q_load)
        wbd = subset_load_data(
                    shuffle_load_data(data_mem_rsp.valid ? data_mem_rsp.data : load_result, exec_result),
                    cast_to_memory_op(f3));
    else
        wbd = exec_result;

end

word instruction_count /*verilator public*/;
always_ff @(posedge clk) begin
    if (reset) begin
        pc <= reset_pc;
        instruction_count <= 0;
    end else begin
        if (current_stage == stage_writeback) begin
            pc <= next_pc;
            instruction_count <= instruction_count + 1;

        end
    end
end

/*

 Stage control

 */
always_ff @(posedge clk) begin
    if (reset)
        current_stage <= stage_fetch;
    else begin
        case (current_stage)
            stage_fetch:
                if (inst_mem_rsp.valid)
                    current_stage <= stage_decode;
            stage_decode:
                current_stage <= stage_execute;
            stage_execute:
                current_stage <= stage_mem;
            stage_mem:
                current_stage <= stage_writeback;
            stage_writeback:
                if (memory_stage_complete)
                    current_stage <= stage_fetch;
            default:
                current_stage <= stage_fetch;
        endcase
    end
end

endmodule
`endif
