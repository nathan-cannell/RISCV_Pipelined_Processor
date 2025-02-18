
module regfile(
    input logic clk,
    input logic [4:0] rs1,
    input logic [4:0] rs2,
    input logic [4:0] rd,
    input logic we,
    input logic [31:0] wdata,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2
);
    logic [31:0] registers[31:0];
    
    always_comb begin
        rdata1 = registers[rs1];
        rdata2 = registers[rs2];
    end

    always_ff @(posedge clk) begin
        if (we && rd != 0) registers[rd] <= wdata;
    end
endmodule