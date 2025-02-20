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


assign rs1_wire = fetched_instruction[19:15];
assign rs2_wire = fetched_instruction[24:20];
assign rd_wire = fetched_instruction[11:7];
assign funct3_wire = fetched_instruction[14:12];
assign opcode_wire = fetched_instruction[6:0];
assign funct7_wire = fetched_instruction[31:25];

assign rs1 = rs1_wire;
assign rs2 = rs2_wire;
assign wbs = rd_wire;
assign f3 = funct3'(funct3_wire);
assign op_q = decode_opcode_q(opcode_wire);
assign format = decode_format(opcode_wire, op_q);
assign imm = decode_imm(fetched_instruction, format);
assign wbv = decode_writeback(op_q);
assign f7 = funct7_wire;




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
    if (op_q == 7'b0000011 || op_q == 7'b0100011) begin // q_load or q_store
        memory_stage_complete = data_mem_rsp.valid;
    end else
        memory_stage_complete = 1'b1;
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

logic branch_taken;
word branch_target;

// moved to outside always comb block

ext_operand exec_result_wire;

assign exec_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(imm),
        pc,
        op_q,
        f3,
        f7);


// Modified always_comb block
always_comb begin
    
    // Handle branching and jumping
    branch_taken = 1'b0;
    branch_target = pc + 4;
    
    case (op_q)
        q_branch: begin
            branch_taken = branch_condition(f3, rd1, rd2);
            branch_target = branch_taken ? (pc + imm) : (pc + 4);
            next_pc_comb = branch_target;
        end
        q_jal: begin
            next_pc_comb = pc + imm;
        end
        q_jalr: begin
            next_pc_comb = (rd1 + imm) & ~32'b1;
        end
        default: next_pc_comb = pc + 4;
    endcase
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

always@(*) begin
    data_mem_req = memory_io_no_req32;

    if (data_mem_rsp.ready && current_stage == stage_mem && (op_q == 7'b0100011 || op_q == 7'b0000011)) begin // q_store or q_load
        data_mem_req.addr = exec_result[`word_address_size - 1:0];
        if (op_q == 7'b0100011) begin // q_store
            data_mem_req.valid = true;
            data_mem_req.do_write = shuffle_store_mask(memory_mask(cast_to_memory_op(f3)), exec_result); //line 222
            data_mem_req.data = shuffle_store_data(rd2, exec_result); // line 223
        end else
        if (op_q == 7'b0000011) begin // q_load
            data_mem_req.valid = true;
            data_mem_req.do_read = shuffle_store_mask(memory_mask(cast_to_memory_op(f3)), exec_result); // line 227
        end
    end
end


word load_result;
always_ff @(posedge clk) begin
    if (data_mem_rsp.valid)
        load_result <= data_mem_rsp.data;
end

// Define this outside the always_comb block if not already defined
localparam opcode_q_load = 7'b0000011;

always_comb begin
    if (op_q == opcode_q_load) begin
        logic [31:0] loaded_data = data_mem_rsp.valid ? data_mem_rsp.data : load_result;
        wbd = subset_load_data(
            loaded_data,
            f3,  // Assuming f3 is the funct3 field from the instruction
            exec_result[1:0]  // Using the lower 2 bits of exec_result as the address offset
        );
    end else
        wbd = exec_result;
end




// writeback
word instruction_count /*verilator public*/;
always_ff @(posedge clk) begin
    if (reset) begin
        pc <= reset_pc;
        instruction_count <= 0;
    end else begin
        if (current_stage == stage_writeback) begin
            case (op_q)
                q_branch, q_jal, q_jalr: pc <= next_pc;
                default: pc <= pc + 4;
            endcase
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
