// Shares the existing physical audio-sector client between narration and BGM.
// A selected request owns the audio slot until its complete sector has ended.
module sd_audio_sector_mux (
    input  wire        clk,
    input  wire        rst,

    input  wire        voice_req,
    input  wire [31:0] voice_sector,
    output wire [7:0]  voice_data,
    output wire        voice_valid,
    output wire        voice_end,

    input  wire        bgm_req,
    input  wire [31:0] bgm_sector,
    output wire [7:0]  bgm_data,
    output wire        bgm_valid,
    output wire        bgm_end,

    output wire        aud_req,
    output wire [31:0] aud_sector,
    input  wire [7:0]  aud_data,
    input  wire        aud_valid,
    input  wire        aud_end
);
    localparam OWNER_NONE  = 2'd0;
    localparam OWNER_VOICE = 2'd1;
    localparam OWNER_BGM   = 2'd2;

    reg [1:0] owner;
    reg [31:0] owner_sector;
    reg end_seen;
    reg prefer_bgm;
    reg [7:0] voice_data_r;
    reg [7:0] bgm_data_r;
    reg voice_valid_r;
    reg bgm_valid_r;
    reg voice_end_r;
    reg bgm_end_r;

    assign aud_req    = (owner != OWNER_NONE) && !end_seen;
    assign aud_sector = owner_sector;
    assign voice_data = voice_data_r;
    assign bgm_data   = bgm_data_r;
    assign voice_valid = voice_valid_r;
    assign bgm_valid = bgm_valid_r;
    assign voice_end = voice_end_r;
    assign bgm_end = bgm_end_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            owner          <= OWNER_NONE;
            owner_sector   <= 32'd0;
            end_seen       <= 1'b0;
            prefer_bgm     <= 1'b0;
            voice_data_r   <= 8'd0;
            bgm_data_r     <= 8'd0;
            voice_valid_r  <= 1'b0;
            bgm_valid_r    <= 1'b0;
            voice_end_r    <= 1'b0;
            bgm_end_r      <= 1'b0;
        end else begin
            voice_valid_r <= 1'b0;
            bgm_valid_r   <= 1'b0;
            voice_end_r   <= 1'b0;
            bgm_end_r     <= 1'b0;

            if (owner == OWNER_NONE) begin
                end_seen <= 1'b0;
                if (voice_req && bgm_req) begin
                    if (prefer_bgm) begin
                        owner        <= OWNER_BGM;
                        owner_sector <= bgm_sector;
                    end else begin
                        owner        <= OWNER_VOICE;
                        owner_sector <= voice_sector;
                    end
                end else if (voice_req) begin
                    owner        <= OWNER_VOICE;
                    owner_sector <= voice_sector;
                end else if (bgm_req) begin
                    owner        <= OWNER_BGM;
                    owner_sector <= bgm_sector;
                end
            end else if (!end_seen) begin
                if (owner == OWNER_VOICE) begin
                    voice_data_r  <= aud_data;
                    voice_valid_r <= aud_valid;
                    voice_end_r   <= aud_end;
                end else begin
                    bgm_data_r    <= aud_data;
                    bgm_valid_r   <= aud_valid;
                    bgm_end_r     <= aud_end;
                end

                if (aud_end)
                    end_seen <= 1'b1;
            end else if ((owner == OWNER_VOICE) && !voice_req) begin
                owner      <= OWNER_NONE;
                prefer_bgm <= 1'b1;
            end else if ((owner == OWNER_BGM) && !bgm_req) begin
                owner      <= OWNER_NONE;
                prefer_bgm <= 1'b0;
            end
        end
    end
endmodule
