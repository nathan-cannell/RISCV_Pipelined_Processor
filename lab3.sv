`ifndef _core_v
`define _core_v

`include "system.sv"
`include "base.sv"
`include "memory_io.sv"
`include "memory.sv"
`include "riscv32_common.sv"

module core(
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc
    ,output memory_io_req   inst_mem_req
    ,input  memory_io_rsp   inst_mem_rsp
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp
    );

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

logic [3:0] mem_write_mask;
word mem_write_data;
word mem_read_data;
logic mem_read_en;
logic mem_write_en;

wire [1:0] shift_amount_byte;
wire [1:0] shift_amount_halfword;

word    reg_file[0:31];

always @(fetched_instruction) begin
    rs1 = decode_rs1(fetched_instruction);
    rs2 = decode_rs2(fetched_instruction);
    wbs = decode_rd(fetched_instruction);
    f3 = decode_funct3(fetched_instruction);
    op_q = decode_opcode_q(fetched_instruction);
    format = decode_format(fetched_instruction, op_q);
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

always_comb begin
    read_reg_valid = false;
    write_reg_valid = false;
    if (current_stage == stage_decode) begin
        read_reg_valid = true;
    end

    if (current_stage == stage_writeback && wbv) begin
        write_reg_valid = true;
    end
end

always_comb begin
    if (rs1 == `tag_size'(0))
        rd1 = `word_size'(0);
    else
        rd1 = reg_file_rd1;
    if (rs2 == `tag_size'(0))
        rd2 = `word_size'(0);
    else
        rd2 = reg_file_rd2;
end

ext_operand exec_result_comb;
word next_pc_comb;
always @(*) begin
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

always_comb begin
    wbd = exec_result;
end
assign shift_amount_byte = exec_result[1:0];
assign shift_amount_halfword = {exec_result[1], 1'b0};

// Memory stage logic
always_comb begin
    mem_write_mask = 4'b0000;
    mem_write_data = 32'b0;
    mem_read_en = 1'b0;
    mem_write_en = 1'b0;

    if (current_stage == stage_mem) begin
        case (op_q)
            opcode_load: begin
                mem_read_en = 1'b1;
                case (f3)
                    funct3_addsub:   mem_write_mask = 4'b0001 << shift_amount_byte;
                    funct3_sll:    mem_write_mask = 4'b0011 << shift_amount_halfword;
                    funct3_slt:    mem_write_mask = 4'b1111;
                    default: mem_write_mask = 4'b0000;
                endcase
            end

            opcode_store: begin
                mem_write_en = 1'b1;
                case (f3)
                    funct3_addsub: begin //sb
                        mem_write_mask = 4'b0001 << shift_amount_byte;
                        mem_write_data = {4{rd2[7:0]}};
                    end
                    funct3_sll: begin //sh
                        mem_write_mask = 4'b0011 << shift_amount_halfword;
                        mem_write_data = {2{rd2[15:0]}};
                    end
                    funct3_slt: begin //sw
                        mem_write_mask = 4'b1111;
                        mem_write_data = rd2;
                    end
                    default: begin
                        mem_write_mask = 4'b0000;
                        mem_write_data = 32'b0;
                    end
                endcase
            end

            default: begin
                mem_read_en  = 1'b0;
                mem_write_en = 1'b0;
            end
        endcase
    end
end

// Memory interface
assign data_mem_req.addr = exec_result;
assign data_mem_req.valid = (current_stage == stage_mem) && (mem_read_en || mem_write_en);
assign data_mem_req.do_read = mem_read_en ? mem_write_mask : 4'b0000;
assign data_mem_req.do_write = mem_write_en ? mem_write_mask : 4'b0000;
assign data_mem_req.data = mem_write_data;

// Handle memory read data
always_ff @(posedge clk) begin
    if (data_mem_rsp.valid && mem_read_en) begin
        mem_read_data <= data_mem_rsp.data;
    end
end

// Writeback stage logic
always_comb begin
    case (op_q)
        opcode_load: begin
            case (f3)
                funct3_addsub: wbd = {{24{mem_read_data[7]}}, mem_read_data[7:0]}; //lb lbu
                funct3_sll: wbd = {{16{mem_read_data[15]}}, mem_read_data[15:0]};  //lh lhu
                funct3_slt: wbd = mem_read_data; //lw
                default: wbd = mem_read_data;
            endcase
        end
        default: wbd = exec_result;
    endcase
end

always_ff @(posedge clk) begin
    if (reset)
        pc <= reset_pc;
    else begin
        if (current_stage == stage_writeback)
            pc <= next_pc;
    end
end

always_ff @(posedge clk) begin
    if (reset)
        current_stage <= stage_fetch;
    else begin
        case (current_stage)
            stage_fetch:
                current_stage <= stage_decode;
            stage_decode:
                current_stage <= stage_execute;
            stage_execute:
                current_stage <= stage_mem;
            stage_mem:
                current_stage <= stage_writeback;
            stage_writeback:
                current_stage <= stage_fetch;
            default:
                current_stage <= stage_fetch;
        endcase
    end
end

endmodule : core
`endif
