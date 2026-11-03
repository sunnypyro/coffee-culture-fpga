// Match the exact DOS 8.3 names used by the media card.
// entry_name is FAT directory bytes 0..10, packed in byte order.
module fat32_name_match (
    input  wire [87:0] entry_name,
    output reg  [3:0]  file_kind
);
    always @(*) begin
        file_kind = 4'd0;
        // Share the long common prefix and extension comparisons instead of
        // synthesizing eight independent 88-bit equality comparators.
        if ((entry_name[39:24] == 16'h2020) && (entry_name[23:0] == "BMP")) begin
            if (entry_name[87:48] == "PHOTO") begin
                case (entry_name[47:40])
                    "1": file_kind = 4'd1;
                    "2": file_kind = 4'd2;
                    "3": file_kind = 4'd3;
                    "4": file_kind = 4'd4;
                    default: ;
                endcase
            end
        end else if ((entry_name[39:24] == 16'h2020) && (entry_name[23:0] == "WAV")) begin
            if (entry_name[87:48] == "AUDIO") begin
                case (entry_name[47:40])
                    "1": file_kind = 4'd5;
                    "2": file_kind = 4'd6;
                    "3": file_kind = 4'd7;
                    "4": file_kind = 4'd8;
                    default: ;
                endcase
            end else if ((entry_name[87:64] == "BGM") &&
                         (entry_name[63:24] == 40'h2020202020)) begin
                file_kind = 4'd9;
            end
        end
    end
endmodule
