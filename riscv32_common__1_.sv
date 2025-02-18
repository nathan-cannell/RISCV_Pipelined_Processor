`ifndef _riscv32_common_sv
`define _riscv32_common_sv

`define enable_ext_m        1
`define tag_size            5
`define word_size           32

typedef logic [`tag_size - 1:0]             tag;
typedef logic [4:0]                         shamt;
typedef logic [31:0]                        instr32;
typedef logic [6:0]                         funct7;
typedef logic [6:0]                         opcode;
typedef logic signed [`word_size:0]         ext_operand;
typedef logic [`word_size - 1:0]            operand;
typedef logic [`word_address_size - 1:0]    word_address;

typedef enum {
     r_format = 0
    ,i_format
    ,s_format
    ,u_format
    ,b_format
    ,j_format
} instr_format;

typedef enum logic [6:0] {
    opcode_load   = 7'b0000011,
    opcode_store  = 7'b0100011,
    q_op_imm      = 7'b0010011,
    q_op          = 7'b0110011,
    q_auipc       = 7'b0010111,
    q_lui         = 7'b0110111,
    q_branch      = 7'b1100011,
    q_jalr        = 7'b1100111,
    q_jal         = 7'b1101111,
    q_system      = 7'b1110011,
    q_unknown     = 7'b1111111
} opcode_q;

typedef enum logic [2:0] {
    funct3_addsub = 3'b000,
    funct3_sll    = 3'b001,
    funct3_slt    = 3'b010,
    funct3_sltu   = 3'b011,
    funct3_xor    = 3'b100,
    funct3_srl    = 3'b101,
    funct3_or     = 3'b110,
    funct3_and    = 3'b111
} funct3;

function automatic opcode_q decode_opcode_q(instr32 instr);
    case (instr[6:0])
        7'b0000011:   return opcode_load;
        7'b0100011:  return opcode_store;
        7'b0010011:    return q_op_imm;
        7'b0110011:    return q_op;
        7'b0010111:    return q_auipc;
        7'b0110111:    return q_lui;
        7'b1100011:    return q_branch;
        7'b1100111:    return q_jalr;
        7'b1101111:    return q_jal;
        7'b1110011:    return q_system;
        default:        return q_unknown;
    endcase
endfunction

function automatic instr_format decode_format(instr32 instr, opcode_q op_q);
    case (op_q)
        opcode_load:  return i_format;
        opcode_store: return s_format;
        q_op_imm:     return i_format;
        q_op:         return r_format;
        q_lui:        return u_format;
        q_auipc:      return u_format;
        q_branch:     return b_format;
        q_jalr:       return i_format;
        q_jal:        return j_format;
        default:       return r_format;
    endcase
endfunction

function automatic funct7 decode_funct7(instr32 instr, instr_format format);
    if (format == r_format || format == i_format)
        return instr[31:25];
    return 7'd0;
endfunction

function automatic ext_operand execute(
     ext_operand rd1
    ,ext_operand rd2
    ,ext_operand imm
    ,word        pc
    ,opcode_q    op_q
    ,funct3      f3
    ,funct7      f7);
    ext_operand result;
    ext_operand operand1, operand2;

    operand1 = (op_q == q_auipc)
        ? { 1'b0, pc } : rd1;
    operand2 = (op_q == q_op_imm || op_q == q_lui || op_q == q_auipc)
        ? imm : rd2;

    case (op_q)
        q_lui:              result = { 1'b0, imm[`word_size-1:0] };
        q_auipc:            result = { 1'b0, pc } + imm;
        q_op, q_op_imm: begin
            case (f3)
                funct3_addsub:
                    if (op_q == q_op_imm)
                        result = operand1 + operand2;
                    else
                        result = f7_mod(f7) ? (operand1 - operand2) : (operand1 + operand2);
                funct3_slt:     result = (operand1 < operand2) ? 1 : 0;
                funct3_sltu:    result = { 1'b0, operand1[`word_size-1:0] } < { 1'b0, operand2[`word_size-1:0] } ? 1 : 0;
                funct3_sll:     result = operand1 << operand2[5:0];
                funct3_srl:    result = f7_mod(f7) ? (operand1 >>> operand2[5:0]) : { 1'b0, operand1[`word_size-1:0] } >> operand2[5:0];
                funct3_xor:     result = operand1 ^ operand2;
                funct3_or:      result = operand1 | operand2;
                funct3_and:     result = operand1 & operand2;
                default: begin
                            $display("Unimplemented f3: %x", f3);
                            result = 0;
                end
            endcase
        end
        default: begin
            $display("Should never get here: pc=%x op=%b", pc, op_q);
            result = 0;
        end
    endcase
    return result;
endfunction

function automatic tag decode_rs2(instr32 instr);
    return instr[24:20];
endfunction

function automatic shamt decode_shamt(instr32 instr);
    return instr[24:20];
endfunction

function automatic tag decode_rs1(instr32 instr);
    return instr[19:15];
endfunction

function automatic tag decode_rd(instr32 instr);
    return instr[11:7];
endfunction

function automatic funct3 decode_funct3(instr32 instr);
    return funct3'(instr[14:12]);
endfunction


function automatic logic [`word_size-1:0] decode_imm(instr32 instr, instr_format format);
    case(format)
        i_format : return { {(`word_size - 12){instr[31]}}, instr[31:20] };
        s_format : return { {(`word_size - 12){instr[31]}}, instr[31:25], instr[11:7] };
        u_format : return { instr[31:12], {12{1'b0}} };
        j_format : return { {(`word_size - 21){instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0 };
        b_format : return { {(`word_size - 21){instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0 };
        default: return {`word_size{1'b0}};
    endcase
endfunction

function automatic bool decode_writeback(opcode_q in);
    case (in)
        q_op_imm, q_op, q_auipc, q_lui, q_jal, q_jalr:  return true;
        default: return false;
    endcase
endfunction

function bool f7_mod(funct7 in);
    return in[5];
endfunction

function automatic ext_operand cast_to_ext_operand(operand in);
    ext_operand temp;
    temp =  {{($bits(ext_operand) - $bits(in)){in[`word_size - 1]}}, in}; // Remove backticks from $bits()
    return temp;
endfunction

function automatic operand cast_to_operand(ext_operand in);
    return in[`word_size - 1:0];
endfunction

function automatic bool is_negative(ext_operand in);
    return in[`word_size - 1];
endfunction

function automatic bool is_over_or_under(ext_operand in);
    return in[`word_size];
endfunction

`endif
