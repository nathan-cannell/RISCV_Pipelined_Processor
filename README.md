# RISC-V 5-Stage Pipelined 32-bit Core

A clean, modular, and educational implementation of a 5-stage pipelined RISC-V 32-bit processor in SystemVerilog.  
This project demonstrates a classic RISC-V pipeline with hazard detection, forwarding, and clean separation of each pipeline stage.

---

## 🚀 Features

- **5-Stage Pipeline**: Fetch, Decode, Execute, Memory, Writeback
- **Data Hazard Detection & Forwarding**: Handles RAW hazards with stall and bypass logic
- **Control Hazard Handling**: Pipeline flush on branch misprediction
- **Modular Structure**: Each stage and interface in its own file for clarity and reuse
- **Parameterizable**: Easily adjust word size, address size, and other architectural parameters
- **RISC-V RV32I Support**: Implements the base integer instruction set
- **Ready for Extension**: Hooks for AMO, M extension, and more

---

## 📂 File Structure
```
/src/
base.sv # Core type and parameter definitions
system.sv # Instruction field decoders and helpers
riscv32_common.sv # RISC-V opcode/type definitions and decode logic
memory_io.sv # Memory interface structs and helpers
core.sv # Top-level module connecting all pipeline stages
fetch.sv # Instruction fetch stage
decode.sv # Instruction decode and register file stage
execute.sv # ALU and branch execution stage
memory.sv # Data memory access stage
writeback.sv # Register file writeback stage
control.sv # Pipeline control, hazard detection, and flush logic
```

---

## 🏗️ Pipeline Overview

| Stage     | Description                                                      |
|-----------|------------------------------------------------------------------|
| Fetch     | Fetches instructions from memory, manages PC and branch targets  |
| Decode    | Decodes instructions, reads register file, generates control     |
| Execute   | Performs ALU ops, calculates branches, handles forwarding        |
| Memory    | Loads/stores data, handles memory interface                      |
| Writeback | Writes results back to register file                             |

---

## ⚡ How to Use

1. **Clone the repository**
git clone https://github.com/nathan-cannell/RISCV_Pipelined_Processor.git
cd riscv-pipeline-core/src


2. **Simulate**
- Use your preferred SystemVerilog simulator (e.g., ModelSim, Questa, Verilator).
- Compile all `.sv` files in `src/` in the order shown above.
- Provide a testbench (not included here) to drive the core and memory.

3. **Customize**
- Adjust parameters in `base.sv` and `system.sv` for different word sizes or features.
- Extend with additional RISC-V extensions as needed.

---

## 📝 Example: Top-Level Instantiation
```
module top;
logic clk, reset;
logic [31:0] reset_pc;
memory_io_req inst_mem_req, data_mem_req;
memory_io_rsp inst_mem_rsp, data_mem_rsp;

core u_core (
    .clk(clk),
    .reset(reset),
    .reset_pc(reset_pc),
    .inst_mem_req(inst_mem_req),
    .inst_mem_rsp(inst_mem_rsp),
    .data_mem_req(data_mem_req),
    .data_mem_rsp(data_mem_rsp)
);
endmodule
```
---

## 📖 References

- [RISC-V ISA Specification](https://riscv.org/technical/specifications/)
- [SystemVerilog IEEE 1800-2017 Standard](https://ieeexplore.ieee.org/document/8299595)

---

## 🙌 Credits

- Modular pipeline design inspired by classic CPU architecture texts
- Instruction decode and ALU logic based on the RISC-V RV32I specification

---

## 🛠️ Contributing

Pull requests and issues are welcome!  
Feel free to fork, extend, and share feedback to make this a better educational resource.

---

## 📄 License

This project is open source and available under the MIT License.
