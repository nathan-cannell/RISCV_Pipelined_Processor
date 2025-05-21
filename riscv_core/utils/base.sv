`ifndef _BASE_SV_
`define _BASE_SV_

// Enable M extension by default
`define enable_ext_m        1

// Basic parameter definitions
`define word_size           32
`define word_address_size   32
`define tag_size            5
`define user_tag_size       4

// Basic type definitions
typedef logic [`tag_size - 1:0]             tag;
typedef logic [4:0]                         shamt;
typedef logic [31:0]                        instr32;
typedef logic [2:0]                         funct3;
typedef logic [6:0]                         funct7;
typedef logic [6:0]                         opcode;
typedef logic signed [`word_size:0]         ext_operand;
typedef logic [`word_size - 1:0]            operand;
typedef logic [`word_size - 1:0]            word;
typedef logic [`word_address_size - 1:0]    word_address;

// Instruction format enumeration
typedef enum {
     r_format = 0,
     i_format,
     s_format,
     u_format,
     b_format,
     j_format
} instr_format;

`endif
