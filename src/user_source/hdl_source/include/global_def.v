


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// sys_pll C1/C2: 1 GHz / 24, opposite phases; 12 ns read capture window.
`define	  SDR_CLK_PERIOD				(24)
`define   SDRAM_REFRESH_COUNT			4096
// init_cnt rolls over after matching this value, so subtract one to make
// the complete period no longer than 64 ms / 4096 refresh commands.
`define   SELF_REFRESH_INTERVAL			((64000000/`SDR_CLK_PERIOD/`SDRAM_REFRESH_COUNT)-1)
