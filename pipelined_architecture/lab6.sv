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
tag  execute_memory_wbs;       // Writeback register
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
