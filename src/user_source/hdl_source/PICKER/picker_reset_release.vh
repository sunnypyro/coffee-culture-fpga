`ifndef FOUR_GRID_PICKER_RESET_RELEASE
`define FOUR_GRID_PICKER_RESET_RELEASE
// Only this synchronizer sees an asynchronous reset release. All consumers
// stay reset until three local rising edges have qualified its removal.
module picker_reset_release(input wire clk,raw,output wire reset_out);
 (* syn_preserve=1, syn_keep=1 *) reg[2:0]release_pipe;
 always @(posedge clk or posedge raw)begin
  if(raw)release_pipe<=3'b111;
  else release_pipe<={release_pipe[1:0],1'b0};
 end
 assign reset_out=release_pipe[2];
endmodule
`endif
