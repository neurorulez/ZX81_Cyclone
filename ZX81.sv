//============================================================================
// 
//  Port to MiSTer.
//  Copyright (C) 2018 Sorgelig
//
//  ZX80-ZX81 replica for MiST
//  Copyright (C) 2018 GyР вЂњР’В¶rgy Szombathelyi
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [44:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output  [7:0] VIDEO_ARX,
	output  [7:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)
	input         TAPE_IN,

	// SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE
);

assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign LED_USER  = ioctl_download | tape_ready;
assign LED_DISK  = 0;
assign LED_POWER = 0;

assign VIDEO_ARX = status[1] ? 8'd16 : 8'd4;
assign VIDEO_ARY = status[1] ? 8'd9  : 8'd3;

`include "build_id.v"
localparam CONF_STR = {
	"ZX81;;",
	"-;",
	"F,O  P  ,Load tape;",
	"-;",
	"O1,Aspect ratio,4:3,16:9;",
	"O6,Video frequency,50Hz,60Hz;",
	"O7,Inverse video,Off,On;",
	"OCD,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"O23,Stereo mix,none,25%,50%,100%;", 
	"-;",
	"O4,Model,ZX80,ZX81;",
	"OAB,RAM size,1k,16k,32k,64k;",
	"O8,Swap joy axle,Off,On;",
	"R0,Reset;",
	"V,v1.0.",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;
wire locked;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk_sys),
	.locked(locked)
);

reg  ce_cpu_p;
reg  ce_cpu_n;
reg  ce_6m5,ce_psg;

always @(negedge clk_sys) begin
	reg [4:0] counter = 0;

	counter  <=  counter + 1'd1;
	ce_cpu_p <= !counter[3] & !counter[2:0];
	ce_cpu_n <=  counter[3] & !counter[2:0];
	ce_6m5   <= !counter[2:0];
	ce_psg   <= !counter[4:0];
end

//////////////////////  HPS I/O  //////////////////////

wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_download;
wire  [7:0] ioctl_index;

wire [10:0] ps2_key;
wire [24:0] ps2_mouse;

wire  [1:0] buttons;
wire  [4:0] joystick_0;
wire  [4:0] joystick_1;
wire [31:0] status;

wire        forced_scandoubler;

hps_io #(.STRLEN($size(CONF_STR)>>3)) hps_io
(
	.clk_sys(clk_sys),
	.conf_str(CONF_STR),
	.HPS_BUS(HPS_BUS),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),

	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index)
);


///////////////////   CPU   ///////////////////
wire [15:0] addr;
wire  [7:0] cpu_din;
wire  [7:0] cpu_dout;
wire        nM1;
wire        nMREQ;
wire        nIORQ;
wire        nRD;
wire        nWR;
wire        nRFSH;
wire        nHALT;
wire        nINT = addr[6];
reg       	reset;

T80pa cpu
(
	.RESET_n(~reset),
	.CLK(clk_sys),
	.CEN_p(ce_cpu_p),
	.CEN_n(ce_cpu_n),
	.WAIT_n(nWAIT),
	.INT_n(nINT),
	.NMI_n(nNMI),
	.BUSRQ_n(1),
	.M1_n(nM1),
	.MREQ_n(nMREQ),
	.IORQ_n(nIORQ),
	.RD_n(nRD),
	.WR_n(nWR),
	.RFSH_n(nRFSH),
	.HALT_n(nHALT),
	.A(addr),
	.DO(cpu_dout),
	.DI(cpu_din)
);

wire [7:0] io_dout = kbd_n ? (psg_sel ? psg_out : 8'hFF) : { tape_in, hz50, 1'b0, key_data[4:0] & ({5{addr[12]}} | ~joykeys) };

always_comb begin
	case({nMREQ, ~nM1 | nIORQ | nRD})
	    'b01: cpu_din = (~nM1 & nopgen) ? 8'h0 : mem_out;
	    'b10: cpu_din = io_dout;
	 default: cpu_din = 8'hFF;
	endcase
end

wire       tape_in = 0;
reg        zx81;
reg  [1:0] mem_size; //00-1k, 01 - 16k 10 - 32k
wire       hz50 = ~status[6];
wire       joyrev = status[8];
wire [4:0] joy = joystick_0 | joystick_1;
wire [4:0] joykeys = joyrev ? {joy[2], joy[3], joy[0], joy[1], joy[4]}:
										{joy[1], joy[0], joy[2], joy[3], joy[4]};

always @(posedge clk_sys) begin
	reg old_download;
	old_download <= ioctl_download;
	if(~ioctl_download & old_download & ioctl_index) tape_ready <= 1;
	
	reset <= buttons[1] | status[0] | (mod[1] & Fn[11]);
	if (reset) begin
		zx81 <= status[4];
		mem_size <= status[11:10];
		tape_ready <= 0;
	end
end

//////////////////   MEMORY   //////////////////

dpram #(.ADDRWIDTH(16)) ram
(
	.clock(clk_sys),
	.address_a(ram_a),
	.data_a(ram_in),
	.wren_a(ram_we | tapewrite_we),
	.q_a(ram_out)
);

dpram #(.ADDRWIDTH(14), .NUMWORDS(12288), .MEM_INIT_FILE("zx8x.mif")) rom
(
	.clock(clk_sys),
	.address_a({(zx81 ? rom_a[12] : 2'h2), rom_a[11:0]}),
	.q_a(rom_out)
);

wire [12:0] rom_a  = nRFSH ? addr[12:0] : { addr[12:9], ram_data_latch[5:0], row_counter };
wire [14:0] tape_load_addr = (&mem_size ? 15'h4000 : 15'h0) + ((ioctl_index[7:6] == 1) ? tape_addr + 4'd8 : tape_addr-1'd1);
wire [15:0] ram_a;
wire        ram_e_64k = &mem_size & (addr[13] | (addr[15] & nM1));
wire			rom_e  = ~addr[14] & (~addr[12] | zx81) & ~ram_e_64k;
wire        ram_e  = addr[14] | ram_e_64k;
wire        ram_we = ~nWR & ~nMREQ & ram_e;
wire  [7:0] ram_in = tapeloader ? tape_in_byte_r : cpu_dout;
wire  [7:0] rom_out;
wire  [7:0] ram_out;
wire  [7:0] mem_out;

always_comb begin
	casex({ tapeloader, rom_e, ram_e })
		'b110: mem_out = tape_loader_patch[addr - (zx81 ? 13'h0347 : 13'h0207)];
		'b010: mem_out = rom_out;
		'b001: mem_out = ram_out;
		default: mem_out = 8'd0;
	endcase

	casex({tapeloader, mem_size })
	   'b1XX: ram_a = tape_load_addr;
	   'b000: ram_a = { 6'b000000,            addr[9:0]  }; //1k
		'b001: ram_a = { 2'b00,                addr[13:0] }; //16k
		'b010: ram_a = { 1'b0, addr[15] & nM1, addr[13:0] }; //32k
		'b011: ram_a = { addr[15] & nM1,       addr[14:0] }; //64k
	endcase
end

////////////////////  TAPE  //////////////////////
reg   [7:0] tape_ram[16384];
reg         tapeloader, tapewrite_we;
reg  [13:0] tape_addr;
reg   [7:0] tape_in_byte,tape_in_byte_r;
reg         tape_ready;  // there is data in the tape memory
// patch the load ROM routines to loop until the memory is filled from $4000(.o file ) $4009 (.p file)
// xor a; loop: nop or scf, jr nc loop, jp h0207 (jp h0203 - ZX80)
reg   [7:0] tape_loader_patch[7] = '{8'haf, 8'h00, 8'h30, 8'hfd, 8'hc3, 8'h07, 8'h02};

always @(posedge clk_sys) if (ioctl_wr && ioctl_index) tape_ram[ioctl_addr] <= ioctl_dout;
always @(posedge clk_sys) tape_in_byte <= tape_ram[tape_addr];

always @(posedge clk_sys) begin
	reg old_nM1;

	old_nM1 <= nM1;
	tapewrite_we <= 0;
	
	if (~nM1 & old_nM1 & tape_ready) begin
		if (zx81) begin
			if (addr == 16'h0347) begin
				tape_loader_patch[1] <= 8'h00; //nop
				tape_loader_patch[5] <= 8'h07; //0207h
				tape_addr <= 14'h0;
				tapeloader <= 1;
			end
			if (addr >= 16'h03c3 || addr < 16'h0347) begin
				tapeloader <= 0;
			end
		end else begin
			if (addr == 16'h0207) begin
				tape_loader_patch[1] <= 8'h00; //nop
				tape_loader_patch[5] <= 8'h03; //0203h
				tape_addr <= 14'h0;
				tapeloader <= 1;
			end
			if (addr >= 16'h024d || addr < 16'h0207) begin
				tapeloader <= 0;
			end
		end
	end

	if (tapeloader & ce_cpu_p) begin
		if (tape_addr != ioctl_addr) begin
			tape_addr <= tape_addr + 1'h1;
			tape_in_byte_r <= tape_in_byte;
			tapewrite_we <= 1;
		end else begin
			tape_loader_patch[1] <= 8'h37; //scf
		end
	end
end

////////////////////  VIDEO //////////////////////
// Based on the schematic:
// http://searle.hostei.com/grant/zx80/zx80.html

// character generation
wire      nopgen = addr[15] & ~mem_out[6] & nHALT;
wire      data_latch_enable = nRFSH & ce_cpu_n & ~nMREQ;
reg [7:0] ram_data_latch;
reg       nopgen_store;
reg [2:0] row_counter;
wire      shifter_start = nMREQ & nopgen_store & ce_cpu_p & ~NMIlatch;
reg [7:0] shifter_reg;
reg       inverse;
wire      video_out = (~status[7] ^ shifter_reg[7] ^ inverse) & ~hblank & ~vblank; 

always @(posedge clk_sys) begin
	reg old_hsync;
	reg old_shifter_start;

	if (ce_6m5) begin
		old_hsync <= hsync;

		if (data_latch_enable) begin
			ram_data_latch <= mem_out;
			nopgen_store <= nopgen;
		end

		if (nMREQ & ce_cpu_p) inverse <= 0;

		old_shifter_start <= shifter_start;
		shifter_reg <= { shifter_reg[6:0], 1'b0 };
		if (~old_shifter_start & shifter_start) begin
			shifter_reg <= (~nM1 & nopgen) ? 8'h0 : mem_out;
			inverse <= ram_data_latch[7];
		end

		if (~old_hsync & hsync)	row_counter <= row_counter + 1'd1;
		if (vs) row_counter <= 0;
	end
end

// vsync generator
reg vsync; // cleaned version
reg vs;    // momentary version, sometimes used for row_counter reset trick
always @(posedge clk_sys) begin
	if (~nIORQ & ~nWR & ~NMIlatch) vs <= 0;
	if (~kbd_n & ~NMIlatch)        vs <= 1;
	if(!hsync) vsync<=vs;
end

// ZX81 upgrade
// http://searle.hostei.com/grant/zx80/zx80nmi.html
wire nWAIT = ~nHALT | nNMI;
wire nNMI = ~NMIlatch | ~hsync;

reg [7:0] sync_counter;
reg       NMIlatch;
reg       hsync;
always @(posedge clk_sys) begin
	if(ce_cpu_n) begin
		sync_counter <= sync_counter + 1'd1;
		if(sync_counter == 206) sync_counter <= 0;
		if(sync_counter == 15)  hsync <= 1;
		if(sync_counter == 31)  hsync <= 0;
	end

	if (~nM1 & ~nIORQ) {hsync,sync_counter} <= 0;

	if (zx81) begin
		if (~nIORQ & ~nWR & (addr[0] ^ addr[1])) NMIlatch <= addr[1];
	end
	else begin
		NMIlatch <= 0;
	end
end

//re-sync
reg hsync2, vsync2;
reg hblank, vblank;
always @(posedge clk_sys) begin
	reg [8:0] cnt;
	reg [4:0] vreg;
	reg       old_hsync;

	if(ce_6m5) begin
		cnt <= cnt + 1'd1;
		if(cnt == 413) cnt <= 0;

		if(cnt == 0)   hsync2 <= 1;
		if(cnt == 32)  hsync2 <= 0;

		if(cnt == 408) hblank <= 1;
		if(cnt == 64)  hblank <= 0;

		old_hsync <= hsync;
		if(~old_hsync & hsync) begin
			vreg <= {vreg[3:0], vsync};
			vblank <= |vreg;
			vsync2 <= vreg[2];
			if(&vreg[3:2]) cnt <= 0;
		end
	end
end

wire [1:0] scale = status[13:12];

video_mixer #(400,1) video_mixer
(
	.*,
	.ce_pix(ce_6m5),
	.ce_pix_out(CE_PIXEL),

	.scanlines({scale==3, scale==2}),
	.scandoubler(scale || forced_scandoubler),
	.hq2x(scale == 1),
	.mono(0),

	.R({4{video_out}}),
	.G({4{video_out}}),
	.B({4{video_out}}),

	.HSync(hsync2),
	.VSync(vsync2),
	.HBlank(hblank),
	.VBlank(vblank)
);

assign CLK_VIDEO = clk_sys;

////////////////////  SOUND //////////////////////
wire [7:0] psg_out;
wire       psg_sel = ~nIORQ & &addr[3:0]; //xF
wire [7:0] psg_ch_a, psg_ch_b, psg_ch_c;

YM2149 psg
(
	.CLK(clk_sys),
	.CE(ce_psg),
	.RESET(reset),
	.BDIR(psg_sel & ~nWR),
	.BC(psg_sel & (&addr[7:6] ^ nWR)),
	.DI(cpu_dout),
	.DO(psg_out),
	.CHANNEL_A(psg_ch_a),
	.CHANNEL_B(psg_ch_b),
	.CHANNEL_C(psg_ch_c)
);

wire [9:0] audio_l = { 1'b0, psg_ch_a, 1'b0 } + { 2'b00, psg_ch_b };
wire [9:0] audio_r = { 1'b0, psg_ch_c, 1'b0 } + { 2'b00, psg_ch_b };

assign AUDIO_L   = {audio_l, 6'd0};
assign AUDIO_R   = {audio_r, 6'd0};
assign AUDIO_S   = 0;
assign AUDIO_MIX = status[3:2]; 

////////////////////   HID   /////////////////////

wire kbd_n = nIORQ | nRD | addr[0];

wire [11:1] Fn;
wire  [2:0] mod;
wire  [4:0] key_data;

keyboard kbd( .* );

endmodule