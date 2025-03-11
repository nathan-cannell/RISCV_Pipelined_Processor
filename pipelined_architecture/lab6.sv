`ifndef _riscv_multicycle  // Prevent multiple inclusions of this code block
`define _riscv_multicycle   // Define a macro to indicate this file has been included

/*

This is a very simple 5 stage multicycle RISC-V 32bit design.

The stages are fetch, decode, execute, memory, writeback

*/

`include "base.sv"  // Include file defining basic parameters like word size
`include "system.sv" // Include file defining memory interface types
`include "riscv.sv"  // Include file defining RISC-V specific definitions (instructions, opcodes, etc.)

module core (          // Define the module named 'core'
    input logic       clk,           // Clock input
    input logic      reset,         // Reset input
    input logic      [`word_address_size-1:0] reset_pc,  // Initial Program Counter value after reset
    output memory_io_req   inst_mem_req,  // Instruction memory request interface
    input  memory_io_rsp   inst_mem_rsp,  // Instruction memory response interface
    output memory_io_req   data_mem_req,  // Data memory request interface
    input  memory_io_rsp   data_mem_rsp   // Data memory response interface
);

import riscv::*;  // Import the riscv package to bring definitions into scope

/*

 Instruction fetch

*/

word_address    pc;           // Program Counter register
instr32 instruction_read;  // Register to hold the instruction read from memory

// Valid signal for the fetch stage
logic           fetch_valid;  // Indicates whether the fetch stage is valid and should execute

// Program Counter update logic
always @(posedge clk) begin  // Sequential logic block triggered on the positive edge of the clock
    if (reset) begin          // If reset is asserted
        pc <= reset_pc;       // Initialize the PC with the reset value
        fetch_valid <= 1'b1;  // Enable fetching after reset
    end else begin             // If reset is not asserted
        if (fetch_valid) begin // We are always fetching as long as fetch_valid is true.
            if(inst_mem_rsp.valid) // If there is a valid response from the instruction memory.
                pc <= pc + 4;   // Increment PC to fetch the next instruction (assuming 4-byte instructions)
        end
    end
end

// Instruction memory request logic
always @(*) begin          // Combinational logic block, updates whenever any input changes
    inst_mem_req = memory_io_no_req;  // Initialize the instruction memory request with a "no request" value
    inst_mem_req.addr = pc;          // Set the address of the request to the current PC value
    inst_mem_req.valid = fetch_valid && inst_mem_rsp.ready;  // The request is valid if fetch is enabled and the memory is ready
    inst_mem_req.do_read[3:0] = (fetch_valid) ? 4'b1111 : 0; // Read all 4 bytes if fetch is valid, otherwise, read none
    instruction_read = shuffle_store_data(inst_mem_rsp.data, inst_mem_rsp.addr); // Align instruction based on address
end

/*

  Pipeline Register: Fetch/Decode

*/

instr32    fetch_decode_instruction;  // Register to hold the instruction passed from fetch to decode
logic      fetch_decode_valid;    // Indicates whether the data in the register is valid

// Fetch/Decode pipeline register update logic
always_ff @(posedge clk) begin      // Sequential logic block triggered on the positive edge of the clock
    if (reset) begin                // If reset is asserted
        fetch_decode_instruction <= 32'b0;  // Initialize the instruction register to 0
        fetch_decode_valid <= 1'b0;        // Invalidate the register
    end else begin                   // If reset is not asserted
        fetch_decode_instruction <= instruction_read;  // Store the fetched instruction into the register
        fetch_decode_valid <= fetch_valid && inst_mem_rsp.valid; // Instruction is passed when fetch stage is valid and valid response is ready.

    end
end

/*
    Forwarding logic
*/ 
always_comb begin
    word rd1;
    word rd2;

    // Forwarding logic for rd1
    if (decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs) begin
        rd1 = executed_instruction_in.writeback_instruction.wbd;
    end else if (decoded_instruction_in.rs1 == memory_instruction_out.writeback_instruction.wbs) begin
        rd1 = memory_instruction_out.writeback_instruction.wbd;
    end else begin
        rd1 = reg_file[decoded_instruction_in.rs1];
    end

    // Forwarding logic for rd2
    if (decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs) begin
        rd2 = executed_instruction_in.writeback_instruction.wbd;
    end else if (decoded_instruction_in.rs2 == memory_instruction_out.writeback_instruction.wbs) begin
        rd2 = memory_instruction_out.writeback_instruction.wbd;
    end else begin
        rd2 = reg_file[decoded_instruction_in.rs2];
    end

    decoded_instruction_out.rd1 = rd1;
    decoded_instruction_out.rd2 = rd2;
end

/*
    Data hazards
*/
always @(*) begin
    word rd1;
    word rd2;

    // Forwarding logic for rd1
    if (decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs) begin
        rd1 = executed_instruction_in.writeback_instruction.wbd;
    end else if (decoded_instruction_in.rs1 == memory_instruction_out.writeback_instruction.wbs) begin
        rd1 = memory_instruction_out.writeback_instruction.wbd;
    end else if (decoded_instruction_in.rs1 == 5'd0) begin
        rd1 = `word_size'd0;
    end else begin
        rd1 = decoded_instruction_in.rd1;
    end

    // Forwarding logic for rd2
    if (decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs) begin
        rd2 = executed_instruction_in.writeback_instruction.wbd;
    end else if (decoded_instruction_in.rs2 == memory_instruction_out.writeback_instruction.wbs) begin
        rd2 = memory_instruction_out.writeback_instruction.wbd;
    end else if (decoded_instruction_in.rs2 == 5'd0) begin
        rd2 = `word_size'd0;
    end else begin
        rd2 = decoded_instruction_in.rd2;
    end

    exec_bypassed_rd1_comb = rd1;
    exec_bypassed_rd2_comb = rd2;

    // Rest of your logic: Execute stage operations
    ext_operand exec_result_comb;
    word next_pc_comb;

    // Perform the operation based on the instruction type
    exec_result_comb = execute(
        cast_to_ext_operand(exec_bypassed_rd1_comb),
        cast_to_ext_operand(exec_bypassed_rd2_comb),
        cast_to_ext_operand(decoded_instruction_in.imm),
        decoded_instruction_in.pc,
        decoded_instruction_in.op_q,
        decoded_instruction_in.f3,
        decoded_instruction_in.f7);

    // Compute next PC for branch instructions
    next_pc_comb = compute_next_pc(
        cast_to_ext_operand(exec_bypassed_rd1_comb),
        exec_result_comb,
        decoded_instruction_in.imm,
        decoded_instruction_in.pc,
        decoded_instruction_in.op_q,
        decoded_instruction_in.f3);

    // Control signals for misprediction handling
    pc_control_out = {($bits(pc_control_t)){1'b0}};
    pc_control_out.fetch_mispredict = false;

    if (decoded_instruction_in.valid && next_pc_comb != fetched_instruction_in.pc) begin
        pc_control_out.fetch_mispredict = true;
        pc_control_out.correct_pc = next_pc_comb;
    end

    if (decoded_instruction_in.valid && decoded_instruction_in.pc != pc) begin
        pc_control_out.wrong_pc = true;
        pc_control_out.correct_pc = pc;
    end

    // Output signals for the next stage
    executed_instruction_out.valid = decoded_instruction_in.valid;
    executed_instruction_out.rd1 = exec_bypassed_rd1_comb;
    executed_instruction_out.rd2 = exec_bypassed_rd2_comb;
    executed_instruction_out.rs1 = decoded_instruction_in.rs1;
    executed_instruction_out.rs2 = decoded_instruction_in.rs2;
    executed_instruction_out.writeback_instruction.wbs = decoded_instruction_in.wbs;
    executed_instruction_out.writeback_instruction.wbv = decoded_instruction_in.wbv;
    executed_instruction_out.writeback_instruction.wbd = exec_result_comb[`word_size-1:0];
    executed_instruction_out.writeback_instruction.valid = decoded_instruction_in.valid;
    executed_instruction_out.f3 = decoded_instruction_in.f3;
    executed_instruction_out.op_q = decoded_instruction_in.op_q;
end

/*

  Instruction decode

*/
tag     rs1;          // Register address for source register 1
tag     rs2;          // Register address for source register 2
word    rd1;          // Data read from register rs1
word    rd2;          // Data read from register rs2
tag     wbs;          // Register address for writeback
word    wbd;          // Data to be written back
logic   wbv;          // Writeback valid signal
word    reg_file_rd1; // Data read from register file for rs1
word    reg_file_rd2; // Data read from register file for rs2
word    imm;          // Immediate value extracted from instruction
funct3  f3;           // Function code 3 bits
funct7  f7;           // Function code 7 bits
opcode_q op_q;        // Opcode
instr_format format;  // Instruction format type
bool     is_memory_op; // Flag if instruction is memory operation

word    reg_file[0:31]; // Register file (32 registers)

//Valid signal for decode stage
logic    decode_valid;  // Indicates whether the decode stage is valid and should execute

// Instruction decode logic
always @(*) begin            // Combinational logic block
    if (fetch_decode_valid) begin  // If the input from the fetch stage is valid
        rs1 = decode_rs1(fetch_decode_instruction);  // Decode the rs1 field from the instruction
        rs2 = decode_rs2(fetch_decode_instruction);  // Decode the rs2 field from the instruction
        wbs = decode_rd(fetch_decode_instruction);   // Decode the rd field from the instruction (writeback register)
        f3 = decode_funct3(fetch_decode_instruction); // Decode the funct3 field from the instruction
        op_q = decode_opcode_q(fetch_decode_instruction); // Decode the opcode field from the instruction
        format = decode_format(op_q); // Determine the instruction format
        imm = decode_imm(fetch_decode_instruction, format);   // Decode the immediate field from the instruction
        wbv = decode_writeback(op_q);    // Determine if the instruction requires a writeback
        f7 = decode_funct7(fetch_decode_instruction, format); // Decode the funct7 field from the instruction
        decode_valid = 1'b1;            // Mark the decode stage as valid
    end else begin                       // If the input from the fetch stage is not valid
        rs1 = 0;                        // Set rs1 to 0
        rs2 = 0;                        // Set rs2 to 0
        wbs = 0;                        // Set wbs to 0
        f3 = 0;                         // Set f3 to 0
        op_q = q_unknown;               // Set opcode to unknown
        format = r_format;              // Set format to R-type (default)
        imm = 0;                        // Set immediate to 0
        wbv = 0;                        // Set writeback to false
        f7 = 0;                         // Set f7 to 0
        decode_valid = 1'b0;            // Mark the decode stage as invalid
    end
end

logic read_reg_valid;  // Indicates whether reading from the register file is valid
logic write_reg_valid; // Indicates whether writing to the register file is valid

// Register file read/write logic
always_ff @(posedge clk) begin  // Sequential logic block
    if (read_reg_valid) begin    // If reading from the register file is valid
        reg_file_rd1 <= reg_file[rs1];  // Read the data from register rs1
        reg_file_rd2 <= reg_file[rs2];  // Read the data from register rs2
    end
    else if (write_reg_valid)      // If writing to the register file is valid
        reg_file[wbs] <= wbd;      // Write the data to register wbs
end

logic memory_stage_complete; //Flag to indicate if the memory stage is complete
word memory_writeback_wbd; //The data to be written back from memory
tag  memory_writeback_wbs; //The register to be written back to from memory
logic memory_writeback_wbv; //Flag to indicate if write back is valid
opcode_q memory_writeback_op_q; //Opcode from the memory stage

// Memory stage complete logic
always @(*) begin
    if (op_q == q_load || op_q == q_store) begin //If the opcode is load or store.
        if (data_mem_rsp.valid) //If the data memory response is valid
            memory_stage_complete = true; //Then the memory stage is complete
        else
            memory_stage_complete = false; //Otherwise its not
    end else
        memory_stage_complete = true; //If its not a load or store, the stage is complete.
end
logic memory_writeback_valid;...
// Register file read/write enable logic
always @(*) begin
    read_reg_valid = false;  // By default, register read is invalid
    write_reg_valid = false; // By default, register write is invalid
    if (decode_valid) begin  // If the decode stage is valid
        read_reg_valid = true; // Enable reading from the register file
    end

    //if (memory_stage_complete && current_stage == stage_writeback && wbv) begin // OLD
    if (memory_stage_complete && memory_writeback_valid && wbv) begin // NEW
        write_reg_valid = true;  // Enable writing to the register file
        wbd = memory_writeback_wbd;    // Set the write data
        wbs = memory_writeback_wbs;    // Set the writeback register

    end
end... /*
   Pipeline Register: Decode/Execute
*/

// Instruction information
tag     decode_execute_rs1;  // Register address for source register 1
tag     decode_execute_rs2;  // Register address for source register 2
tag     decode_execute_wbs;  // Register address for writeback
logic   decode_execute_wbv;  // Writeback valid signal
funct3  decode_execute_f3;   // Function code 3 bits
funct7  decode_execute_f7;   // Function code 7 bits
opcode_q decode_execute_op_q; // Opcode
word    decode_execute_rd1;  // Data read from register rs1
word    decode_execute_rd2;  // Data read from register rs2
word    decode_execute_imm;  // Immediate value

logic   decode_execute_valid; // Valid signal for the Decode/Execute pipeline register

// Decode/Execute pipeline register update logic
always_ff @(posedge clk) begin  // Sequential logic block
  if (reset) begin            // If reset is asserted
    decode_execute_valid <= 1'b0;    // Invalidate the register
    decode_execute_rs1   <= 0;       // Initialize rs1
    decode_execute_rs2   <= 0;       // Initialize rs2
    decode_execute_wbs   <= 0;       // Initialize wbs
    decode_execute_wbv   <= 1'b0;    // Invalidate writeback
    decode_execute_f3    <= 0;       // Initialize f3
    decode_execute_f7    <= 0;       // Initialize f7
    decode_execute_op_q  <= q_unknown; // Initialize opcode
    decode_execute_rd1   <= 0;       // Initialize rd1
    decode_execute_rd2   <= 0;       // Initialize rd2
    decode_execute_imm   <= 0;       // Initialize immediate
  end else begin               // If reset is not asserted
    decode_execute_valid <= decode_valid; // If decode stage is valid then this stage is valid as well.
    decode_execute_rs1   <= rs1;      // Pass rs1 to the next stage
    decode_execute_rs2   <= rs2;      // Pass rs2 to the next stage
    decode_execute_wbs   <= wbs;      // Pass wbs to the next stage
    decode_execute_wbv   <= wbv;      // Pass wbv to the next stage
    decode_execute_f3    <= f3;       // Pass f3 to the next stage
    decode_execute_f7    <= f7;       // Pass f7 to the next stage
    decode_execute_op_q  <= op_q;     // Pass opcode to the next stage
    decode_execute_rd1   <= reg_file_rd1; // Pass rd1 to the next stage
    decode_execute_rd2   <= reg_file_rd2; // Pass rd2 to the next stage
    decode_execute_imm   <= imm;      // Pass immediate to the next stage
  end
end

/*

 Instruction execute

 */

word    rd1_execute;  // Operand 1 for execution
word    rd2_execute;  // Operand 2 for execution

// Operand selection logic
always_comb begin
    if (decode_execute_rs1 == `tag_size'd0) // If rs1 is zero (x0 register)
        rd1_execute = `word_size'd0;     // Read zero
    else
        rd1_execute = decode_execute_rd1;  // Otherwise, read the register value
    if (decode_execute_rs2 == `tag_size'd0) // If rs2 is zero (x0 register)
        rd2_execute = `word_size'd0;     // Read zero
    else
        rd2_execute = decode_execute_rd2;  // Otherwise, read the register value
end

ext_operand exec_result_comb; // Result of the execution (extended operand)
word next_pc_comb;          // Next program counter value (combinational)

//Valid signal for execute stage
logic execute_valid;  // Indicates whether the execute stage is valid

// Execution logic
always @(*) begin      // Combinational logic block
    if (decode_execute_valid) begin  // If the input from the decode stage is valid
        exec_result_comb = execute(   // Execute the instruction
            cast_to_ext_operand(rd1_execute),  // Cast operand 1 to extended operand
            cast_to_ext_operand(rd2_execute),  // Cast operand 2 to extended operand
            cast_to_ext_operand(decode_execute_imm),  // Cast immediate to extended operand
            pc,                       // Current PC value
            decode_execute_op_q,      // Opcode
            decode_execute_f3,       // Function code 3 bits
            decode_execute_f7);        // Function code 7 bits
        next_pc_comb = compute_next_pc(  // Compute the next PC value
            cast_to_ext_operand(rd1_execute),  // Cast operand 1 to extended operand
            exec_result_comb,         // Execution result
            decode_execute_imm,       // Immediate value
            pc,                       // Current PC value
            decode_execute_op_q,      // Opcode
            decode_execute_f3);        // Function code 3 bits
        execute_valid <= 1'b1;          // Mark the execute stage as valid
    end else begin                     // If the input from the decode stage is not valid
        exec_result_comb = 0;         // Set the execution result to 0
        next_pc_comb = 0;             // Set the next PC to 0
        execute_valid <= 1'b0;          // Mark the execute stage as invalid
    end
end... word exec_result;  // Execution result (truncated to word size)
word next_pc;      // Next program counter value
// Execution result and next PC update logic
always_ff @(posedge clk) begin  // Sequential logic block
    if (execute_valid) begin      // If the execute stage is valid

        exec_result <= exec_result_comb[`word_size-1:0];  // Store the execution result
        next_pc <= next_pc_comb;              // Store the next PC value

    end
end

/*

  Pipeline Register: Execute/Memory

*/

word execute_memory_exec_result;  // Execution result
word execute_memory_next_pc;    // Next PC
tag  execute_memory_wbs;       // `ifndef __lab6_sv
`define __lab5_sv

// modularized pipelined (no hazard/mispredict handling)
`include "riscv.sv"

typedef struct packed {
    bool valid;
    riscv::word pc;
} fetch_set_pc_call_t;

typedef struct packed {
    bool _unused_;
} fetch_set_pc_return_t;

typedef struct packed {
    bool advance;
    bool flush;
} stage_signal_t;

typedef struct packed {
    bool valid;
    riscv::instr32 instruction;
    riscv::word pc;
} fetched_instruction_t;


module fetch(
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc

    // Stage control signalling
    ,input stage_signal_t       fetch_signal_in

    // Control function interfaces
    ,input fetch_set_pc_call_t    fetch_set_pc_call_in
    ,output fetch_set_pc_return_t  fetch_set_pc_return_out

    // Principle operation data path
    ,output memory_io_req           inst_mem_req
    ,input  memory_io_rsp           inst_mem_rsp
    ,output fetched_instruction_t   fetched_instruction_out
    );

import riscv::*;

word fetch_pc;
bool clear_fetch_stream;
word clear_to_this_pc;
word issued_fetch_pc;
bool issued;
instr32 latched_instruction_read;
bool latched_instruction_valid;
word latched_instruction_pc;

always @(*) begin
    inst_mem_req = memory_io_no_req;

    inst_mem_req.addr = fetch_pc;
    inst_mem_req.do_read[3:0] = 4'b1111;
    inst_mem_req.valid = inst_mem_rsp.ready
                        && fetch_signal_in.advance;
    inst_mem_req.user_tag = 0;

    fetched_instruction_out.valid = latched_instruction_valid;
    fetched_instruction_out.instruction = latched_instruction_read;
    fetched_instruction_out.pc = latched_instruction_pc;

    if (inst_mem_rsp.valid
        && fetch_signal_in.advance
        ) begin
        if (clear_fetch_stream &&
            inst_mem_rsp.addr != clear_to_this_pc) begin
            // discard

        end else begin
            word memory_read;
            memory_read = shuffle_store_data(inst_mem_rsp.data, inst_mem_rsp.addr);
            fetched_instruction_out.valid = true;
            fetched_instruction_out.instruction = memory_read[31:0];
            fetched_instruction_out.pc = inst_mem_rsp.addr;
        end
    end
end


// Forwarding Logic
always_comb begin
    // Forwarding logic for rd1
    if (decoded_instruction_in.rs1 == executed_instruction_in.wbs) begin
        rd1 = executed_instruction_in.writeback_instruction.wbd;
    end else if (decoded_instruction_in.rs1 == memory_instruction_out.writeback_instruction.wbs) begin
        rd1 = memory_instruction_out.writeback_instruction.wbd;
    end else begin
        rd1 = reg_file[decoded_instruction_in.rs1];
    end

    // Similar logic for rd2
end
always @(*) begin
    if (decoded_instruction_in.valid && next_pc_comb != fetched_instruction_in.pc) begin
        pc_control_out.fetch_mispredict = true;
        pc_control_out.correct_pc = next_pc_comb;
    end
end

// Data Hazards
always_ff @(posedge clk) begin
    if (pc_control_out.fetch_mispredict) begin
        // Flush pipeline stages
        decoded_instruction_out.valid <= false;
        executed_instruction_out.valid <= false;
        memory_instruction_out.valid <= false;
        fetch_pc <= pc_control_out.correct_pc;
    end
end

// Bypass logic
always_comb begin
    // Bypassing logic for rd1
    if (decoded_instruction_in.rs1 == executed_instruction_in.wbs) begin
        rd1 = executed_instruction_in.writeback_instruction.wbd;
    end else if (decoded_instruction_in.rs1 == memory_instruction_out.writeback_instruction.wbs) begin
        rd1 = memory_instruction_out.writeback_instruction.wbd;
    end else begin
        rd1 = reg_file[decoded_instruction_in.rs1];
    end

    // Similar logic for rd2
end


always_ff @(posedge clk) begin
    if (reset) begin
        fetch_pc <= reset_pc;
        latched_instruction_valid <= false;
        clear_fetch_stream <= false;
        clear_to_this_pc <= 0;
    end else begin

        if (inst_mem_rsp.valid) begin
            issued <= false;
            if (clear_fetch_stream
                && inst_mem_rsp.addr != clear_to_this_pc) begin
                // do nthing
            end else begin
                clear_fetch_stream <= false;
                if (fetch_signal_in.advance) begin
                    word memory_read;
                    memory_read = shuffle_store_data(inst_mem_rsp.data, inst_mem_rsp.addr);
                    latched_instruction_pc <= inst_mem_rsp.addr;
                    latched_instruction_read <= memory_read[31:0];
                    latched_instruction_valid <= true;
                end
            end
        end

        if (inst_mem_req.valid) begin
            fetch_pc <= fetch_pc + 4;
        end

        //if (fetched_instruction_out.valid)
        //    $display("PC out: %x rsp.addr=%x", fetched_instruction_out.pc, inst_mem_rsp.addr);

        if (fetch_set_pc_call_in.valid) begin
            //$display("fetch_pc reset to: %x", fetch_set_pc_call_in.pc);
            fetch_pc <= fetch_set_pc_call_in.pc;
            latched_instruction_valid <= false;
            clear_fetch_stream <= true;
            clear_to_this_pc <= fetch_set_pc_call_in.pc;
        end else if (!fetch_signal_in.advance) begin
            // ut oh.  Fetch is only approximate, however
            // so we do our best to guess what is needed
            fetch_pc <= latched_instruction_pc + 4;
            clear_fetch_stream <= true;
            clear_to_this_pc <= latched_instruction_pc + 4;

        end
    end
end

endmodule

typedef struct packed {
    bool valid;
    riscv::tag rs1;
    riscv::tag rs2;
    riscv::word rd1;
    riscv::word rd2;
    riscv::word imm;
    riscv::tag wbs;
    bool wbv;
    riscv::funct3 f3;
    riscv::funct7 f7;
    riscv::opcode_q op_q;
    riscv::instr_format format;
    riscv::instr32 instruction;
    riscv::word pc;    
} decoded_instruction_t;

typedef struct packed {
    bool valid;
    bool wbv;
    riscv::tag wbs;
    riscv::word wbd;    
} writeback_instruction_t;

typedef struct packed {
    bool    valid;
    riscv::word    rd;
    riscv::tag     rs;
} reg_file_bypass_t;

module decode_and_writeback (
    input logic       clk
    ,input logic      reset

    // Stage control signalling
    ,input stage_signal_t   decode_signal_in
    ,input stage_signal_t   execute_signal_in
    ,input stage_signal_t   writeback_signal_in

    // Control function interfaces
    ,output reg_file_bypass_t reg_file_bypass_out

    // Principle operation data path
    ,input fetched_instruction_t fetched_instruction_in
    ,output decoded_instruction_t decoded_instruction_out

    ,input writeback_instruction_t writeback_instruction_in
    );
    
import riscv::*;

word    reg_file[0:31];

word    reg_file_bypass_rd;
tag     reg_file_bypass_rs;
bool    reg_file_bypass_valid;

always_comb begin
    reg_file_bypass_out.valid = reg_file_bypass_valid;
    reg_file_bypass_out.rd = reg_file_bypass_rd;
    reg_file_bypass_out.rs = reg_file_bypass_rs;
end

tag last_decode_instruction_rs1;
tag last_decode_instruction_rs2;

initial begin
    for (int i = 0; i < 32; i++)
        reg_file[i] = `word_size'd0;
end

always_ff @(posedge clk) begin
    word    wbd;
    tag     rs1;
    tag     rs2;
    opcode_q op_q;
    instr_format format;
    tag read_reg_rs1;
    tag read_reg_rs2;
    
    rs1 = decode_rs1(fetched_instruction_in.instruction);
    rs2 = decode_rs2(fetched_instruction_in.instruction);
    op_q = decode_opcode_q(fetched_instruction_in.instruction);
    format = decode_format(op_q);

    if (reset)
        reg_file_bypass_valid <= false;

    if (reset || decode_signal_in.flush) begin
        decoded_instruction_out <= {($bits(decoded_instruction_t)){1'b0}};
        decoded_instruction_out.valid <= false;
    end else begin
        if (decode_signal_in.advance
            && fetched_instruction_in.valid) begin
            decoded_instruction_out.valid <= true;
            decoded_instruction_out.rs1 <= rs1;
            decoded_instruction_out.rs2 <= rs2;
            decoded_instruction_out.wbs <= decode_rd(fetched_instruction_in.instruction);
            decoded_instruction_out.f3 <= decode_funct3(fetched_instruction_in.instruction);
            decoded_instruction_out.op_q <= op_q;
            decoded_instruction_out.format <= format;
            decoded_instruction_out.imm <= decode_imm(fetched_instruction_in.instruction, format);
            decoded_instruction_out.wbv <= decode_writeback(op_q);
            decoded_instruction_out.f7 <= decode_funct7(fetched_instruction_in.instruction, format);
            decoded_instruction_out.pc <= fetched_instruction_in.pc;
            decoded_instruction_out.instruction <= fetched_instruction_in.instruction;
        end else begin //if (execute_signal_in.advance) begin
            // Either always or only on exec advance is fine.
            decoded_instruction_out <= {($bits(decoded_instruction_t)){1'b0}};
            decoded_instruction_out.valid <= false;
        end

    end

    if (decode_signal_in.advance
        && fetched_instruction_in.valid) begin
        decoded_instruction_out.rd1 <= reg_file[rs1];
        decoded_instruction_out.rd2 <= reg_file[rs2];            
    end

    // Write back
    if (!reset
        && writeback_signal_in.advance
        && writeback_instruction_in.valid
        && writeback_instruction_in.wbv) begin
        reg_file[writeback_instruction_in.wbs] <= writeback_instruction_in.wbd;
        reg_file_bypass_rs <= writeback_instruction_in.wbs;
        reg_file_bypass_rd <= writeback_instruction_in.wbd;
        reg_file_bypass_valid <= true;
    end

end
endmodule


typedef struct packed {
    bool valid;
    riscv::word rd1;
    riscv::word rd2;
    riscv::tag rs1;
    riscv::tag rs2;
    riscv::funct3 f3;
    riscv::opcode_q op_q;
    writeback_instruction_t writeback_instruction;
} executed_instruction_t;

typedef struct packed {
    bool fetch_mispredict;
    bool wrong_pc;
    riscv::word correct_pc;    
}   pc_control_t;

module execute (
    input logic       clk
    ,input logic      reset
    ,input riscv::word       reset_pc
    // Stage control signalling
    ,input stage_signal_t   execute_signal_in
    ,input stage_signal_t   memory_signal_in

    // For detecting a branch mispredict
    ,input fetched_instruction_t fetched_instruction_in

    // For bypassing
    ,input reg_file_bypass_t reg_file_bypass_in
    ,input executed_instruction_t executed_instruction_in
    ,input writeback_instruction_t writeback_instruction_in

    // Datapath proper
    ,input decoded_instruction_t  decoded_instruction_in
    ,output executed_instruction_t executed_instruction_out

    ,output pc_control_t pc_control_out
    );

import riscv::*;

word pc;
ext_operand exec_result_comb;
word next_pc_comb;
word exec_bypassed_rd1_comb;
word exec_bypassed_rd2_comb;

always @(*) begin
    word rd1;
    word rd2;

    // TODO: Implement bypass logic
    rd1 = ((decoded_instruction_in.rs1 == 5'd0) ? `word_size'd0 : decoded_instruction_in.rd1);
    rd2 = ((decoded_instruction_in.rs2 == 5'd0) ? `word_size'd0 : decoded_instruction_in.rd2);

    exec_bypassed_rd1_comb = rd1;
    exec_bypassed_rd2_comb = rd2;

    exec_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(decoded_instruction_in.imm),
        decoded_instruction_in.pc,
        decoded_instruction_in.op_q,
        decoded_instruction_in.f3,
        decoded_instruction_in.f7);

    // "ground truth" for the next PC comes from this calculation.
    next_pc_comb = compute_next_pc(
        cast_to_ext_operand(rd1),
        exec_result_comb,
        decoded_instruction_in.imm,
        decoded_instruction_in.pc,
        decoded_instruction_in.op_q,
        decoded_instruction_in.f3);

    pc_control_out = {($bits(pc_control_t)){1'b0}};
    pc_control_out.fetch_mispredict = false;

    if (decoded_instruction_in.valid
        && next_pc_comb != fetched_instruction_in.pc) begin
        pc_control_out.fetch_mispredict = true;
        pc_control_out.correct_pc = next_pc_comb;
    end

    if (decoded_instruction_in.valid
        && decoded_instruction_in.pc != pc) begin
        pc_control_out.wrong_pc = true;
        pc_control_out.correct_pc = pc;
    end

end


always_ff @(posedge clk) begin
    if (reset) begin
        executed_instruction_out.valid <= false;
        pc <= reset_pc;
    end else begin
        if (decoded_instruction_in.valid && execute_signal_in.advance) begin
            if (decoded_instruction_in.pc == pc) begin
                executed_instruction_out.valid <= true;
                pc <= next_pc_comb;
            end else
                // Flush this instruction out
                executed_instruction_out.valid <= false;

            executed_instruction_out.rd1 <= exec_bypassed_rd1_comb;
            executed_instruction_out.rd2 <= exec_bypassed_rd2_comb;
            executed_instruction_out.rs1 <= decoded_instruction_in.rs1;
            executed_instruction_out.rs2 <= decoded_instruction_in.rs2;
            executed_instruction_out.writeback_instruction.wbs <= decoded_instruction_in.wbs;
            executed_instruction_out.writeback_instruction.wbv <= decoded_instruction_in.wbv;
            executed_instruction_out.writeback_instruction.wbd <= exec_result_comb[`word_size-1:0];
            executed_instruction_out.writeback_instruction.valid <= decoded_instruction_in.valid;
            executed_instruction_out.f3 <= decoded_instruction_in.f3;
            executed_instruction_out.op_q <= decoded_instruction_in.op_q;
        end else if (memory_signal_in.advance) begin
            executed_instruction_out <= {($bits(executed_instruction_t)){1'b0}};
            executed_instruction_out.valid <= false;
        end
    end
end

endmodule


typedef struct packed {
    bool valid;
    riscv::word pc;
    riscv::word exec_result;
    riscv::funct3 f3;
    riscv::opcode_q op_q;
    writeback_instruction_t writeback_instruction;
} memory_instruction_t;


module memory (
    input logic       clk
    ,input logic      reset

    // Stage control signalling
    ,input stage_signal_t   memory_signal_in
    ,input stage_signal_t   writeback_signal_in

    // For bypassing
    ,input reg_file_bypass_t reg_file_bypass_in
    ,input writeback_instruction_t writeback_instruction_in

    // Datapath proper
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp
    ,input executed_instruction_t  executed_instruction_in
    ,output memory_instruction_t memory_instruction_out

    );

import riscv::*;


always @(*) begin
    word  rd2;
    word  rd1;

    rd1 = executed_instruction_in.rd1;
    rd2 = executed_instruction_in.rd2;
    data_mem_req = memory_io_no_req;

    if (memory_signal_in.advance && executed_instruction_in.valid
        && (executed_instruction_in.op_q == q_store
         || executed_instruction_in.op_q == q_load
         || executed_instruction_in.op_q == q_amo)) begin
        data_mem_req.user_tag = 0;
        if (executed_instruction_in.op_q == q_store) begin
            data_mem_req.addr = executed_instruction_in.writeback_instruction.wbd[`word_address_size - 1:0];
            data_mem_req.valid = true;
            data_mem_req.do_write = shuffle_store_mask(memory_mask(
                cast_to_memory_op(executed_instruction_in.f3)), executed_instruction_in.writeback_instruction.wbd[`word_size - 1:0]);
            data_mem_req.data = shuffle_store_data(rd2, executed_instruction_in.writeback_instruction.wbd[`word_size - 1:0]);
        end
        else if (executed_instruction_in.op_q == q_load) begin  // q_load
            data_mem_req.addr = executed_instruction_in.writeback_instruction.wbd[`word_address_size - 1:0];
            data_mem_req.valid = true;
            data_mem_req.do_read = shuffle_store_mask(memory_mask(
                cast_to_memory_op(executed_instruction_in.f3)), executed_instruction_in.writeback_instruction.wbd[`word_size - 1:0]);
        end
/*        else if (executed_instruction_in.op_q == q_amo) begin
            data_mem_req.addr = rd1;
            data_mem_req.data = rd2;
            data_mem_req.valid = true;
            if (executed_instruction_in.f3 == f3_amo_d) begin
                data_mem_req.do_write = {(`word_size_bytes){1'b1}};
                data_mem_req.do_read = {(`word_size_bytes){1'b1}};
            end
        end
*/
    end
end

always_ff @(posedge clk) begin
    if (memory_signal_in.advance) begin
        memory_instruction_out <= {($bits(memory_instruction_t)){1'b0}};
        if (executed_instruction_in.valid) begin
            memory_instruction_out.writeback_instruction <= executed_instruction_in.writeback_instruction;
            memory_instruction_out.f3 <= executed_instruction_in.f3;
            memory_instruction_out.op_q <= executed_instruction_in.op_q;
            memory_instruction_out.valid <= executed_instruction_in.valid;
        end
    end else if (writeback_signal_in.advance)
        memory_instruction_out <= {($bits(memory_instruction_t)){1'b0}};

end

endmodule

module writeback(
    input stage_signal_t writeback_signal_in
    ,input memory_io_rsp data_mem_rsp
    ,input memory_instruction_t memory_instruction_in
    ,output writeback_instruction_t writeback_instruction_out
    );

import riscv::*;

always @(*) begin
    writeback_instruction_out = {($bits(writeback_instruction_t)){1'b0}};
    if (writeback_signal_in.advance && memory_instruction_in.valid) begin
        writeback_instruction_out = memory_instruction_in.writeback_instruction;
        if (memory_instruction_in.op_q == q_load || memory_instruction_in.op_q == q_amo) begin
            writeback_instruction_out.wbd = subset_load_data(
                                shuffle_load_data(data_mem_rsp.data, memory_instruction_in.writeback_instruction.wbd[`word_size - 1:0]),
                                cast_to_memory_op(memory_instruction_in.f3));
            writeback_instruction_out.valid = data_mem_rsp.valid & memory_instruction_in.valid;
        end
    end
end

endmodule

module control(
    input memory_io_rsp inst_mem_rsp
    ,input memory_io_rsp data_mem_rsp
    ,input pc_control_t pc_control_in
    ,input fetched_instruction_t fetched_instruction_in
    ,input decoded_instruction_t decoded_instruction_in
    ,input executed_instruction_t executed_instruction_in
    ,input memory_instruction_t memory_instruction_in
    ,output stage_signal_t  fetch_signal_out
    ,output stage_signal_t  decode_signal_out
    ,output stage_signal_t  execute_signal_out
    ,output stage_signal_t  memory_signal_out
    ,output stage_signal_t  writeback_signal_out
    ,output fetch_set_pc_call_t fetch_set_pc_call_out
    );

import riscv::*;

// Stall / Flush logic 
always_comb begin
    // Start with everything running smooth
    fetch_signal_out.advance = true;
    fetch_signal_out.flush = false;
    decode_signal_out.advance = true;
    decode_signal_out.flush = false;
    execute_signal_out.advance = true;
    execute_signal_out.flush = false;
    memory_signal_out.advance = true;
    memory_signal_out.flush = false;
    fetch_set_pc_call_out.valid = false;
    // TODO: Manage hazards and branch mispredicts


end
endmodule

module core #(
    parameter btb_enable = false          // use a BTB?
    ) (
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc
    ,output memory_io_req   inst_mem_req
    ,input  memory_io_rsp   inst_mem_rsp
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp);

import riscv::*;

/* verilator lint_off UNOPTFLAT */
stage_signal_t fetch_signal, decode_signal, execute_signal, memory_signal, writeback_signal;
/* verilator lint_on UNOPTFLAT */

// Interface function structs to fetch
fetch_set_pc_call_t fetch_set_pc_call;
fetch_set_pc_return_t fetch_set_pc_return;

// Chief output of fetch
fetched_instruction_t fetched_instruction;

// Instantiate the fetch module proper
fetch fetch_m(.clk(clk), .reset(reset)
    ,.reset_pc(reset_pc)
    ,.fetch_signal_in(fetch_signal)
    ,.fetch_set_pc_call_in(fetch_set_pc_call)
    ,.fetch_set_pc_return_out(fetch_set_pc_return)
    ,.inst_mem_req(inst_mem_req)
    ,.inst_mem_rsp(inst_mem_rsp)
    ,.fetched_instruction_out(fetched_instruction)
    );


reg_file_bypass_t reg_file_bypass;
decoded_instruction_t decoded_instruction;
writeback_instruction_t writeback_instruction;

// Instantiate the decode and writeback module proper
decode_and_writeback decode_and_writeback_m(.clk(clk), .reset(reset)
    // Stage control signalling
    ,.decode_signal_in(decode_signal)
    ,.execute_signal_in(execute_signal)
    ,.writeback_signal_in(writeback_signal)
    // Control function interfaces
    ,.reg_file_bypass_out(reg_file_bypass)

    // Principle operation data path
    ,.fetched_instruction_in(fetched_instruction)
    ,.decoded_instruction_out(decoded_instruction)
    ,.writeback_instruction_in(writeback_instruction)
    );

executed_instruction_t executed_instruction;
pc_control_t pc_control;

execute execute_m(
    .clk(clk), .reset(reset)
    ,.reset_pc(reset_pc)
    ,.execute_signal_in(execute_signal)
    ,.memory_signal_in(memory_signal)

    ,.fetched_instruction_in(fetched_instruction)
    ,.reg_file_bypass_in(reg_file_bypass)
    ,.executed_instruction_in(executed_instruction)
    ,.writeback_instruction_in(writeback_instruction)

    ,.decoded_instruction_in(decoded_instruction)
    ,.executed_instruction_out(executed_instruction)
    ,.pc_control_out(pc_control)
    );

memory_instruction_t memory_instruction;

memory memory_m(
    .clk(clk), .reset(reset)
    ,.memory_signal_in(memory_signal)
    ,.writeback_signal_in(writeback_signal)

    ,.writeback_instruction_in(writeback_instruction)
    ,.reg_file_bypass_in(reg_file_bypass)

    ,.data_mem_req(data_mem_req)
    ,.data_mem_rsp(data_mem_rsp)
    ,.executed_instruction_in(executed_instruction)
    ,.memory_instruction_out(memory_instruction)
    );

writeback writeback_m(
    .writeback_signal_in(writeback_signal)
    ,.data_mem_rsp(data_mem_rsp)
    ,.memory_instruction_in(memory_instruction)
    ,.writeback_instruction_out(writeback_instruction)
    );

control control_m(
    .inst_mem_rsp(inst_mem_rsp)
    ,.data_mem_rsp(data_mem_rsp)
    ,.pc_control_in(pc_control)
    ,.fetched_instruction_in(fetched_instruction)
    ,.decoded_instruction_in(decoded_instruction)
    ,.executed_instruction_in(executed_instruction)
    ,.memory_instruction_in(memory_instruction)
    ,.fetch_signal_out(fetch_signal)
    ,.decode_signal_out(decode_signal)
    ,.execute_signal_out(execute_signal)
    ,.memory_signal_out(memory_signal)
    ,.writeback_signal_out(writeback_signal)
    ,.fetch_set_pc_call_out(fetch_set_pc_call)
    );

endmodule

`endif
Writeback register
logic execute_memory_wbv;       // Writeback valid
opcode_q execute_memory_op_q;  // Opcode
funct3 execute_memory_f3;      // Function 3

logic execute_memory_valid;   // Valid signal

// Execute/Memory pipeline register update logic
always_ff @(posedge clk) begin  // Sequential logic block
  if (reset) begin            // If reset is asserted
    execute_memory_valid <= 1'b0;    // Invalidate the register
    execute_memory_exec_result <= 0; // Initialize execution result
    execute_memory_next_pc   <= 0;   // Initialize next PC
    execute_memory_wbs      <= 0;   // Initialize writeback register
    execute_memory_wbv      <= 1'b0;    // Invalidate writeback
    execute_memory_op_q     <= q_unknown; // Initialize opcode
    execute_memory_f3       <= 0;   // Initialize function 3
  end else begin               // If reset is not asserted
    execute_memory_valid <= execute_valid; // Valid if previous stage was valid
    execute_memory_exec_result <= exec_result; // Pass execution result
    execute_memory_next_pc   <= next_pc;   // Pass next PC
    execute_memory_wbs      <= decode_execute_wbs; // Pass writeback register
    execute_memory_wbv      <= decode_execute_wbv; // Pass writeback valid signal
    execute_memory_op_q     <= decode_execute_op_q; // Pass opcode
    execute_memory_f3       <= decode_execute_f3;   // Pass function 3
  end
end... /*

  Stage and mem

 */

//Valid signal for memory stage
logic memory_valid;  // Indicates whether the memory stage is valid

// Data memory request logic
always @(*) begin  // Combinational logic block
    data_mem_req = memory_io_no_req; // Initialize data memory request to "no request"
    if (execute_memory_valid) begin // If the execute/memory stage is valid
        if(execute_memory_op_q == q_store || execute_memory_op_q == q_load) begin // If instruction is store or load
          data_mem_req.addr = exec_result[`word_address_size - 1:0]; // Address from execution result
          data_mem_req.valid = true; // Memory request is valid
          if(execute_memory_op_q == q_store) begin // If store instruction
            data_mem_req.do_write = shuffle_store_mask(memory_mask(cast_to_memory_op(execute_memory_f3)), exec_result);
            //data_mem_req.data = shuffle_store_data(rd2, exec_result);
          end else begin // If load instruction
            data_mem_req.do_read = shuffle_store_mask(memory_mask(cast_to_memory_op(execute_memory_f3)), exec_result);
          end
          memory_valid <= 1'b1; // Memory stage is valid
        end else begin // If not load or store
            memory_valid <= 1'b0; // Memory stage is invalid
        end
    end else begin // If execute/memory stage is invalid
        memory_valid <= 1'b0; // Memory stage is invalid
    end
end

word load_result;  // Result of a load operation
// Load result update logic
always_ff @(posedge clk) begin  // Sequential logic block
    if (data_mem_rsp.valid) // If data memory response is valid
        load_result <= data_mem_rsp.data; // Store the data
end... // Writeback data selection logic
always @(*) begin
    if (execute_memory_op_q == q_load) //If it is a load operation
        wbd = subset_load_data( //Extract specific bytes from loaded data
                    shuffle_load_data(data_mem_rsp.valid ? data_mem_rsp.data : load_result, exec_result),
                    cast_to_memory_op(execute_memory_f3));
    else
        wbd = exec_result; //Otherwise the write back data is the execution result

end

/*

  Pipeline Register: Memory / Writeback

*/

// Memory/Writeback pipeline register update logic

always_ff @(posedge clk) begin  // Sequential logic block
  if (reset) begin            // If reset is asserted
    memory_writeback_valid <= 1'b0;    // Invalidate
    memory_writeback_wbd   <= 0;       // Initialize
    memory_writeback_wbs   <= 0;       // Initialize
    memory_writeback_wbv   <= 1'b0;    // Invalidate
    memory_writeback_op_q  <= q_unknown; // Initialize
  end else begin               // If reset is not asserted
    memory_writeback_valid <= memory_valid; // Pass valid signal
    memory_writeback_wbd   <= wbd;   // Pass writeback data
    memory_writeback_wbs   <= execute_memory_wbs; // Pass writeback register
    memory_writeback_wbv   <= execute_memory_wbv; // Pass writeback valid
    memory_writeback_op_q  <= execute_memory_op_q; // Pass opcode
  end
end

/*

 Writeback

 */

//Valid signal for writeback stage
logic writeback_valid;  // Indicates whether the writeback stage is valid

// Writeback logic
always @(*) begin    // Combinational logic block
    writeback_valid = memory_writeback_valid; // Writeback is valid if data is available.
    if (writeback_valid && memory_writeback_wbv) begin // If writeback stage is valid and writeback is enabled
        write_reg_valid = true; // Enable writing to register file
        wbd = memory_writeback_wbd;   // Set writeback data
        wbs = memory_writeback_wbs;   // Set writeback register
    end else begin
        write_reg_valid = false;  // Otherwise disable writing
    end
end

/*

 Stage control

 */
//Removed the old stage control
//Since there are valid signals for all of them.

endmodule
`endif
