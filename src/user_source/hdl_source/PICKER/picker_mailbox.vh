`ifndef FOUR_GRID_PICKER_MAILBOX
`define FOUR_GRID_PICKER_MAILBOX
// Held-bus mailbox: same common reset assertion on both clock domains.
// Cancel is a transaction; never reset just one end to cancel a message.
module picker_mailbox #(parameter WIDTH=8)(
 input wire src_clk,src_rst,src_send,output wire src_ready,
 input wire[WIDTH-1:0]src_data,output reg src_done,
 input wire dst_clk,dst_rst,output reg dst_valid,
 output reg[WIDTH-1:0]dst_data,input wire dst_accept
);
 reg[WIDTH-1:0]held_data;
 reg request,ack;
 (* syn_preserve=1 *) reg[1:0]request_sync,ack_sync;
 assign src_ready=(request==ack_sync[1]);
 reg ack_seen;
 always @(posedge src_clk or posedge src_rst)begin
  if(src_rst)begin request<=0;held_data<=0;ack_sync<=0;ack_seen<=0;src_done<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};src_done<=0;
   if(ack_sync[1]!=ack_seen)begin ack_seen<=ack_sync[1];src_done<=1;end
   if(src_send&&src_ready)begin held_data<=src_data;request<=~request;end
  end
 end
 always @(posedge dst_clk or posedge dst_rst)begin
  if(dst_rst)begin request_sync<=0;ack<=0;dst_valid<=0;dst_data<=0;end
  else begin
   request_sync<={request_sync[0],request};
   if(!dst_valid&&request_sync[1]!=ack)begin dst_data<=held_data;dst_valid<=1;end
   if(dst_valid&&dst_accept)begin ack<=request_sync[1];dst_valid<=0;end
  end
 end
endmodule
`endif
