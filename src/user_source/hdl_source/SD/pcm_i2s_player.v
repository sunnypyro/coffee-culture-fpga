// Serializes 24-bit signed PCM samples as 64fs I2S.
// The input FIFO is read only at a stereo-frame boundary, matching the
// existing I2S_receiver timing used by the HDMI transmitter.
module pcm_i2s_player #(
    // 诊断用开关（2026-09-15）：
    // 1 = 不播卡里的数据，改播本模块自己生成的一个响亮的方波测试音。
    //     注意：FIFO 照常读取，所以"读取→缓存→播放器"这条链仍然在流动。
    //     用途：把"播放器输出通路"和"卡里的数据"两件事彻底分开。
    // 0 = 正常使用（播卡里的音乐）。
    parameter TEST_TONE_EN = 1'b0,
    parameter CONTINUOUS_TRANSPORT = 1'b0
)(
    input  wire        mclk,
    input  wire        rst,
    input  wire        transport_rst,
    input  wire        content_release,
    output reg         content_ready,
    input  wire [15:0] fifo_data,
    input  wire        fifo_empty,
    input  wire        source_eof,
    input  wire        pause_state,
    input wire picker_hold_req,output wire pause_applied,
    output reg         fifo_read,
    output reg         i2s_bclk,
    output reg         i2s_lrck,
    output reg         i2s_dout,
    output reg         playback_done,
    output reg         playback_start_toggle
);
    reg [5:0]  bit_count;
    reg [63:0] shift_reg;
    reg [23:0] sample_word;
    reg [1:0]  eof_sync;
    // The WAV reader reports end-of-file as a short pulse, but the audio FIFO
    // still holds up to 512 samples (about 10 ms of sound) at that moment.
    // Latching it means "the file has ended" is still known when the FIFO
    // finally runs empty.  Cleared by the same rst that a new track uses.
    reg        eof_seen;
    reg        playback_started;
    reg        pause_sync0;
    reg        pause_sync1;
    wire arst;
    wire stereo_boundary=i2s_bclk&&(bit_count==63)&&i2s_lrck;
    wire tx_arst;
    wire content_reset = rst | (CONTINUOUS_TRANSPORT ? transport_rst : 1'b0);
    generate if (CONTINUOUS_TRANSPORT) begin : g_continuous
        picker_reset_release u_transport_reset(mclk,transport_rst,tx_arst);
    end else begin : g_legacy
        assign tx_arst = arst;
    end endgenerate
    reg [1:0] release_sync;
    reg zero_frame_armed;
    always @(posedge mclk or posedge arst) begin
        if(arst) begin release_sync<=0;zero_frame_armed<=0;content_ready<=0;end
        else begin
            release_sync<={release_sync[0],content_release};
            if(stereo_boundary) begin
                zero_frame_armed<=1;
                if(zero_frame_armed) content_ready<=1;
            end
        end
    end
    wire content_wait = CONTINUOUS_TRANSPORT && (!content_ready || !release_sync[1]);
    reg[1:0]picker_hold_sync;reg picker_hold_active;
    assign pause_applied=picker_hold_active;
    wire picker_pausing=picker_hold_sync[1]&&stereo_boundary;
    // On the release boundary use the normal consume branch immediately;
    // waiting one more frame would replay the pre-pause sample on the right.
    wire picker_gated=picker_hold_active&&!(stereo_boundary&&!picker_hold_sync[1]);
    always @(posedge mclk or posedge arst)begin
      if(arst)begin picker_hold_sync<=0;picker_hold_active<=0;end
      else begin
        picker_hold_sync<={picker_hold_sync[0],picker_hold_req};
        if(stereo_boundary)picker_hold_active<=picker_hold_sync[1];
      end
    end

    // 上电初值（只在上电时生效，不随复位变化）：
    // 见下面主状态机复位块里的说明 —— toggle 只允许翻转，不允许被单侧清成定值。
    initial playback_start_toggle = 1'b0;

    // ------------------------------------------------------------------
    // 诊断用测试音（只在 TEST_TONE_EN = 1 时生效）
    // 自己产生一个约 375 Hz 的响亮方波，振幅和开机提示音同量级。
    // 只要这个音能听到，就说明"播放器的输出通路 + HDMI + 显示器"整条是好的，
    // 问题只剩"从 FIFO 取出来的数据"。
    // ------------------------------------------------------------------
    // 第 2 版测试音（2026-09-15）：**每个采样都换一个大幅值的伪随机数**。
    // 为什么要改成这样：
    //   第 1 版测试音是 375 Hz 方波 —— 同一个值会连续保持上百个采样，
    //   "数据变化很慢"，所以它能听到只能说明"慢速数据"没问题；
    //   而卡里的音乐是**每个采样都在变**。
    //   这一版把"变化快"这个唯一剩下的变量单独拿出来试：
    //     能听到（噪声）⇒ 快速数据也没问题 ⇒ 病根在卡里那份数据；
    //     听不到        ⇒ 问题就出在"数据变化快"这件事上（查 I2S 时序/接收）。
    reg [23:0] tone_lfsr;
    always @(posedge mclk or posedge rst) begin
        if (rst)
            tone_lfsr <= 24'h12_3456;
        else
            tone_lfsr <= {tone_lfsr[22:0],
                          tone_lfsr[23] ^ tone_lfsr[22] ^ tone_lfsr[21] ^ tone_lfsr[16]};
    end
    // 只用高 20 位当数据，保证幅度足够大（响）
    wire signed [23:0] tone_word = {tone_lfsr[23:20], tone_lfsr[19:0], 4'b0};
    // 16 位 PCM -> 24 位 I2S 的**左对齐**（关键，2026-09-15 修）
    // I2S_receiver.v:115 取的是 64 位帧的 [63:40] = 高 24 位。
    //   原写法 {{8{fifo_data[15]}}, fifo_data} 只是把 16 位值塞进低 16 位、
    //   高 8 位做符号扩展，等于 ±32767 / 8388607 = 0.39% 满幅（约 -48 dBFS）；
    //   而开机提示音用的是 AMP = ±2,000,000 = 23.8% 满幅（约 -12.5 dBFS）。
    //   两者差 61 倍（约 36 dB）=> 提示音听得见、卡内音乐等于没声音。
    // 修法：左移 8 位对齐到 24 位满幅，符号位落在 bit23 仍然正确。
    wire        [23:0] sample_in  = TEST_TONE_EN ? tone_word
                                                 : {fifo_data, 8'b0};

    // ------------------------------------------------------------------
    // 复位整流（reset conditioning）
    // rst 来自 sd_card_clk 域：'track_start' 在 100 MHz 域里只有 1 个周期宽
    // （10 ns），而本模块跑在 12.295 MHz 上（周期 81 ns）。
    // 异步“置位”一定会被看到，但“释放”必须与本域时钟对齐 —— 裸异步释放
    // 会让寄存器落在建立/保持窗口里，产生亚稳态，或者出现“一部分寄存器已
    // 复位、另一部分还没复位”的半复位状态。
    // 这里把复位在 mclk 域内再保持 4 拍才释放，得到一个干净的同步释放。
    // ------------------------------------------------------------------
    reg [3:0] rst_stretch;
    always @(posedge mclk or posedge content_reset) begin
        if (content_reset)
            rst_stretch <= 4'hF;
        else
            rst_stretch <= {rst_stretch[2:0], 1'b0};
    end
    assign arst = rst_stretch[3];

    always @(posedge mclk or posedge arst) begin
        if (arst) begin
            pause_sync0 <= 1'b0;
            pause_sync1 <= 1'b0;
        end else begin
            pause_sync0 <= pause_state;
            pause_sync1 <= pause_sync0;
        end
    end

    always @(posedge mclk or posedge arst) begin
        if (arst)
            eof_sync <= 2'b00;
        else
            eof_sync <= {eof_sync[0], source_eof};
    end

    always @(posedge mclk or posedge arst) begin
        if (arst)
            eof_seen <= 1'b0;
        else if (eof_sync[1])
            eof_seen <= 1'b1;          // end of file seen: latch it
        else if (!fifo_empty)
            eof_seen <= 1'b0;          // new data arrived: a new file is playing
    end

    // Transport phase survives content reset. Data below is cleared independently.
    always @(posedge mclk or posedge tx_arst) begin
        if(tx_arst) begin bit_count<=0;i2s_bclk<=0;i2s_lrck<=0;end
        else begin
            i2s_bclk<=~i2s_bclk;
            if(i2s_bclk) begin
                if(bit_count==63) begin bit_count<=0;i2s_lrck<=~i2s_lrck;end
                else bit_count<=bit_count+1'b1;
            end
        end
    end

    always @(posedge mclk or posedge arst) begin
        if (arst) begin
            shift_reg    <= 64'd0;
            sample_word  <= 24'd0;
            fifo_read    <= 1'b0;
            i2s_dout     <= 1'b0;
            playback_done<= 1'b0;
            // ⚠️ playback_start_toggle 故意不在这里复位（2026-09-20 修复）：
            // 它是"音频开始播放"的跨时钟域翻转信号 —— 只允许翻转，不允许被单侧清成定值。
            // 本复位来自顶层 audio_fifo_rst，由 rst_all 和 track_start 驱动；后台图片预读
            // 不会复位当前 WAV。若在这里把 toggle 清 0，顶层视频域的边沿检测 (v1 ^ seen)
            // 会把"复位清零"误判成"开始播放"，多送一个假脉冲
            // ⇒ OSD 字幕时间轴被清零 ⇒ 旧图第一句字幕闪回约 0.5s。
            // 上电初值改由上面的 initial 提供，复位期间 toggle 保持原值。
            playback_started      <= 1'b0;
        end else begin
            fifo_read <= 1'b0;

            if (!pause_sync1 && fifo_empty && eof_seen)
                playback_started <= 1'b0;

            if (content_wait||pause_sync1||picker_gated||picker_pausing) begin
                // Keep the I2S clocks alive for HDMI, but output silence and
                // do not consume the FIFO or finish the track.
                if (i2s_bclk == 1'b1) begin
                    i2s_dout  <= 1'b0;
                    shift_reg <= 64'd0;
                end
            end else if (i2s_bclk == 1'b1) begin
                i2s_dout  <= shift_reg[63];
                shift_reg <= {shift_reg[62:0], 1'b0};

                if (bit_count == 6'd63) begin
                    if (i2s_lrck == 1'b0) begin
                        shift_reg <= {sample_word, 40'd0};
                    end else begin
                        if (!fifo_empty) begin
                sample_word  <= sample_in;
                shift_reg    <= {sample_in, 40'd0};
                            fifo_read    <= 1'b1;
                            playback_done<= 1'b0;
                            if (!playback_started) begin
                                playback_start_toggle <= ~playback_start_toggle;
                                playback_started      <= 1'b1;
                            end
                        end                         else begin
                            sample_word <= 24'd0;
                            shift_reg   <= 64'd0;
                            if (eof_seen)
                                playback_done <= 1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule
