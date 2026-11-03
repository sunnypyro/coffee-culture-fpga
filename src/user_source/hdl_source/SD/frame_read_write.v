`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256,
	parameter WRITE_V_FLIP           = 1,      // 1: vertical flip when writing TF/BMP frame into SDRAM
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
) 
(
	input diagnostic_display_ready,diagnostic_write_reset,
    output reg diagnostic_underflow,diagnostic_read_overflow,diagnostic_write_overflow,
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    /*
    output                           rd_burst_req,               // to external memory controller,send out a burst read request
	output[BURST_BITS - 1:0]         rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // to external memory controller,base address of the burst read request 
	input                            rd_burst_data_valid,        // from external memory controller,read data valid 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // from external memory controller,read request data
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 //read_data_valid
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
    input                            picker_override,
    input                            picker_visible_toggle,
    input                            picker_cmd_valid,picker_cmd_cancel,
    input [7:0]                      picker_cmd_id,
    input [1:0]                      picker_cmd_source,
    output                           picker_cmd_accept,picker_result_valid,
    input                            picker_result_ready,
    output [7:0]                     picker_result_id,
    output [1:0]                     picker_result_code,picker_result_source,
    output [1:0]                     picker_active_source,
	input                            read_clk,                   // data read module clock
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            read_en,                    // data read module read request for one data, read_data valid next clock
	output[READ_DATA_BITS  - 1:0]    read_data,                  // read data
	/*
	output                           wr_burst_req,               // to external memory controller,send out a burst write request
	output[BURST_BITS - 1:0]         wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // to external memory controller,write data
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
    input                            picker_thumb,picker_write_abort,
    input [ADDR_BITS-1:0]            picker_tile_base,
    output                           picker_write_abort_done,
	input                            write_clk,                  // data write module clock
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output                           write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_en,                   // data write module write request for one data
	input[WRITE_DATA_BITS - 1:0]     write_data                 // write data

);
// Pipeline the FIFO pointer/count decode before burst arithmetic/arbitration.
// Controllers retain their existing burst-end/check wait cycles.
wire [8:0] wrusedw_f, rdusedw_f;
wire[8:0]usedw0,usedw1;
wire full0,full1,write_full;
wire empty0,empty1;wire[READ_DATA_BITS-1:0]data0,data1;
wire active_bank,job_bank,engine_req,engine_ack,engine_done,engine_append,engine_abort;
wire[20:0]engine_base,engine_len;
wire read_reset;
picker_reset_release u_read_reset(read_clk,rst,read_reset);
reg[1:0]bank_sync;
always @(posedge read_clk or posedge read_reset)if(read_reset)bank_sync<=0;else bank_sync<={bank_sync[0],active_bank};
assign wrusedw_f=job_bank?usedw1:usedw0;
assign read_data=bank_sync[1]?data1:data0;
assign read_finish=engine_done;
picker_scanout u_picker_scanout(
 .clk(mem_clk),.rst(rst),.frame_req(read_req),.normal_source(read_addr_index[0]),
 .override_enable(picker_override),.visible_toggle(picker_visible_toggle),
 .cmd_valid(picker_cmd_valid),.cmd_cancel(picker_cmd_cancel),.cmd_id(picker_cmd_id),.cmd_source(picker_cmd_source),
 .cmd_accept(picker_cmd_accept),.result_valid(picker_result_valid),.result_ready(picker_result_ready),
 .result_id(picker_result_id),.result_code(picker_result_code),.result_source(picker_result_source),
 .engine_ack(engine_ack),.engine_done(engine_done),.empty0(empty0),.empty1(empty1),
 .engine_req(engine_req),.engine_base(engine_base),.engine_len(engine_len),
 .engine_append(engine_append),.engine_abort(engine_abort),.job_bank(job_bank),.active_bank(active_bank),.frame_ack(read_req_ack),.active_source(picker_active_source));
reg [9:0] wrusedw, rdusedw;
always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        wrusedw <= 10'd0;
        rdusedw <= 10'd0;
    end else begin
        wrusedw <= {1'b0,wrusedw_f};
        rdusedw <= {1'b0,rdusedw_f};
    end
end

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire                                 read_fifo_aclr;             // fifo Asynchronous clear
wire                                 write_fifo_aclr;            // fifo Asynchronous clear

wire O_wr_busy;
wire O_rd_busy;

assign App_wr_busy = O_wr_busy;//下个时钟写指令拉高
assign App_rd_busy = O_rd_busy;//读指令还没有过去十个时钟;因为写指令优先，不需要在意下个时钟是否是读指令
assign App_wr_dm = 4'b0000;

//instantiate an asynchronous FIFO 
wfifo_32_32_512 write_buf
	(
	.clkr                      	(mem_clk                  ),          // Read side clock
	.clkw                      	(write_clk                ),          // Write side clock
	.rst                       	(rst | write_fifo_aclr    ),          // Asynchronous clear
	.we                      	(write_en                 ),          // Write Request
	.re                      	(App_wr_en        		  ),          // Read Request
	.di                       	(write_data               ),          // Input Data
	.empty_flag                 (                         ),          // Read side Empty flag
	.full_flag                  (write_full               ),          // Write side Full flag
	.wrusedw                	(              	  		  ),          // Read Used Words
	.rdusedw                	(rdusedw_f                  ),          // Write Used Words
	.dout                       (App_wr_din		          )
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.FRAME_WIDTH                (FRAME_WIDTH              ),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
    .picker_thumb(picker_thumb),.picker_tile_base(picker_tile_base),
    .picker_abort(picker_write_abort),.picker_abort_done(picker_write_abort_done),
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy				(App_rd_busy),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (write_req                ),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
	.write_addr_index           (write_addr_index         ),    
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(rdusedw                  )
);

//instantiate an asynchronous FIFO 
rfifo_32_32_512 read_buf(
 .clkr(read_clk),.clkw(mem_clk),.rst(rst||(read_fifo_aclr&&!job_bank&&!engine_append)),
 .we(Sdr_rd_en&&!job_bank),.re(read_en&&!bank_sync[1]&&!empty0),.di(Sdr_rd_dout),
 .empty_flag(empty0),.full_flag(full0),.wrusedw(usedw0),.rdusedw(),.dout(data0),.valid(),.afull(),.aempty());
rfifo_32_32_512 read_buf_alt(
 .clkr(read_clk),.clkw(mem_clk),.rst(rst||(read_fifo_aclr&&job_bank&&!engine_append)),
 .we(Sdr_rd_en&&job_bank),.re(read_en&&bank_sync[1]&&!empty1),.di(Sdr_rd_dout),
 .empty_flag(empty1),.full_flag(full1),.wrusedw(usedw1),.rdusedw(),.dout(data1),.valid(),.afull(),.aempty());

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               )
)
frame_fifo_read_m0
(
	.rst                        (rst                      ),
    .read_base_override(engine_base),.picker_read_enable(1'b1),.read_abort(engine_abort),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(Sdr_rd_en),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),
	
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
	.read_req                   (engine_req               ),
	.read_req_ack               (engine_ack               ),
	.read_finish                (engine_done              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
	.read_addr_index            (read_addr_index          ),    
	.read_len                   (engine_len               ),
	.fifo_aclr                  (read_fifo_aclr           ),
	.wrusedw                	(wrusedw                  )
);

// Sticky observations in their native domains; no data-path gating.
always @(posedge read_clk or posedge read_reset)
 if(read_reset)diagnostic_underflow<=0;
 else if(diagnostic_display_ready && read_en && (bank_sync[1]?empty1:empty0))diagnostic_underflow<=1;
always @(posedge mem_clk or posedge rst)
 if(rst)diagnostic_read_overflow<=0;
 else if(Sdr_rd_en && (job_bank?full1:full0))diagnostic_read_overflow<=1;
always @(posedge write_clk or posedge diagnostic_write_reset)
 if(diagnostic_write_reset)diagnostic_write_overflow<=0;
 else if(write_en && write_full)diagnostic_write_overflow<=1;
endmodule
