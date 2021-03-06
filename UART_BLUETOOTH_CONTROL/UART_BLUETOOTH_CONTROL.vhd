----------------------------------------------------------------------------------
-- Engineer: Sebastian Huether
-- 
-- Create Date:    12:51:56 01/19/2015 
-- Module Name:    UART_BLUETOOTH_CONTROL - rtl 
-- Project Name:   UART_BLUETOOTH_CONTROL
-- Tool versions:  Xilinx ISE 14.7
-- Description:
--  Controller component for the PAN1322 bluetooth module
--  (and other chips compatible with the eUniStone SPP-AT protocol)
-- Additional Comments:
--  Stone the man who chose ASCII for this inter-chip bus data encoding!!!
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.help_funcs.all;
use work.txt_util.all;

entity UART_BLUETOOTH_CONTROL is
    generic (
        CLK_IN_PERIOD   : real;
        BAUD_RATE       : positive := 115_200;
        BUFFER_SIZE     : positive := 1024;
        -- default Serial over Bluetooth UUID
        UUID            : string(1 to 32) := "0000110100001000800000805F9B34FB";
        COD             : string(1 to 6) := "040400";
        DEVICE_NAME     : string := "pandaLight";
        SERVICE_NAME    : string := "Serial port";
        SERVICE_CHANNEL : positive range 1 to 30 := 1
    );
    port (
        CLK : in std_ulogic;
        RST : in std_ulogic;
        
        BT_CTS  : in std_ulogic;
        BT_RTS  : out std_ulogic := '0';
        BT_RXD  : in std_ulogic;
        BT_TXD  : out std_ulogic := '1';
        BT_WAKE : out std_ulogic := '0';
        BT_RSTN : out std_ulogic := '0';
        
        DIN         : in std_ulogic_vector(7 downto 0);
        DIN_WR_EN   : in std_ulogic;
        SEND_PACKET : in std_ulogic;
        
        DOUT        : out std_ulogic_vector(7 downto 0) := x"00";
        DOUT_VALID  : out std_ulogic := '0';
        
        CONNECTED   : out std_ulogic := '0';
        
        MTU_SIZE        : out std_ulogic_vector(9 downto 0) := (others => '0');
        MTU_SIZE_VALID  : out std_ulogic := '0';
        
        ERROR   : out std_ulogic := '0';
        BUSY    : out std_ulogic := '0'
    );
end UART_BLUETOOTH_CONTROL;

architecture rtl of UART_BLUETOOTH_CONTROL is
    
    constant CRLF                   : string := CR & LF;
    constant RESET_CMD              : string := "AT+RES" & CRLF;
    constant SECURITY_CMD           : string := "AT+JSEC=4,1,04,0000,0,0" & CRLF; -- "just works" security, output device
    constant DEVICE_NAME_CMD        : string := "AT+JSLN=" & pad_left(DEVICE_NAME'length, 2, '0') & "," & DEVICE_NAME & CRLF;
    constant REGISTER_SERVICE_CMD   : string := "AT+JRLS=32," & pad_left(SERVICE_NAME'length, 2, '0') & "," & UUID &
                                                "," & SERVICE_NAME & "," & pad_left(SERVICE_CHANNEL, 2, '0') & "," & COD & CRLF;
    constant ENABLE_SCAN_CMD        : string := "AT+JDIS=3" & CRLF;
    constant AUTO_ACCEPT_CMD        : string := "AT+JAAC=1" & CRLF;
    constant SEND_DATA_CMD_PREFIX   : string := "AT+JSDA=";
    
    type state_type is (
        HARD_RESETTING,
        WAITING_FOR_BOOT,
        SENDING_SECURITY_CMD,
        WAITING_FOR_SECURITY_ACK,
        SENDING_DEVICE_NAME_CMD,
        WAITING_FOR_DEVICE_NAME_ACK,
        SENDING_REGISTER_SERVICE_CMD,
        WAITING_FOR_REGISTER_SERVICE_ACK,
        SENDING_ENABLE_SCAN_CMD,
        WAITING_FOR_ENABLE_SCAN_ACK,
        SENDING_AUTO_ACCEPT_CMD,
        WAITING_FOR_AUTO_ACCEPT_ACK,
        WAITING_FOR_PACKET_TO_SEND,
        SENDING_SEND_DATA_CMD_PREFIX,
        SENDING_PACKET_LENGTH1,
        SENDING_PACKET_LENGTH2,
        SENDING_PACKET_LENGTH3,
        SENDING_PACKET_COMMA,
        SENDING_PACKET_WAITING_FOR_DATA,
        SENDING_PACKET,
        SENDING_PACKET_LAST_BYTE,
        SENDING_PACKET_END_CR,
        SENDING_PACKET_END_LF,
        EVALUATING_ERROR
    );
    
    type reg_type is record
        state               : state_type;
        bt_rstn             : std_ulogic;
        bt_wake             : std_ulogic;
        bt_rts              : std_ulogic;
        retry_count         : unsigned(2 downto 0);
        rst_count           : unsigned(4 downto 0);
        char_index          : unsigned(6 downto 0);
        tx_din              : std_ulogic_vector(7 downto 0);
        tx_wr_en            : std_ulogic;
        error               : std_ulogic;
        data_buf_rd_en      : std_ulogic;
        bytes_left_counter  : unsigned(11 downto 0);
        packet_pending      : boolean;
    end record;
    
    constant reg_type_def   : reg_type := (
        state               => HARD_RESETTING,
        bt_rstn             => '0',
        bt_wake             => '1',
        bt_rts              => '0',
        retry_count         => "011",
        rst_count           => "01111",
        char_index          => uns(1, 7),
        tx_din              => x"00",
        tx_wr_en            => '0',
        error               => '0',
        data_buf_rd_en      => '0',
        bytes_left_counter  => uns(0, 12),
        packet_pending      => false
    );
    
    signal cur_reg, next_reg    : reg_type := reg_type_def;
    
    signal rx_packet_valid  : std_ulogic := '0';
    signal rx_data_valid    : std_ulogic := '0';
    signal rx_data          : std_ulogic_vector(7 downto 0) := x"00";
    
    signal rx_mtu_size          : std_ulogic_vector(9 downto 0) := (others => '0');
    signal rx_mtu_size_valid    : std_ulogic := '0';
    
    signal rx_rst       : std_ulogic := '0';
    signal rx_ok        : std_ulogic := '0';
    signal rx_connected : std_ulogic := '0';
    signal rx_error     : std_ulogic := '0';
    
    signal data_buf_dout    : std_ulogic_vector(7 downto 0) := x"00";
    
    signal send_packet_q    : std_ulogic := '0';
    
    -- 3 digit BCD counter for ASCII data length string
    signal data_len_counter                     : unsigned(11 downto 0) := uns(0, 12);
    signal data_len_counter_to_send             : unsigned(11 downto 0) := uns(0, 12);
    signal hex_data_len_counter                 : unsigned(11 downto 0) := uns(0, 12);
    signal hex_data_len_counter_ascii           : std_ulogic_vector(23 downto 0) := x"000000";
    signal hex_data_len_counter_ascii_to_send   : std_ulogic_vector(23 downto 0) := x"303030";
    
begin
    
    BT_RTS  <= cur_reg.bt_rts;
    BT_RSTN <= cur_reg.bt_rstn;
    BT_WAKE <= cur_reg.bt_wake;
    
    DOUT        <= rx_data;
    DOUT_VALID  <= rx_data_valid;
    
    CONNECTED   <= rx_connected;
    
    MTU_SIZE        <= rx_mtu_size;
    MTU_SIZE_VALID  <= rx_mtu_size_valid;
    
    ERROR   <= cur_reg.error;
    BUSY    <= '1' when cur_reg.state/=WAITING_FOR_PACKET_TO_SEND else '0';
    
    rx_rst  <= RST or not cur_reg.bt_rstn;
    
    hex_data_len_counter_ascii(23 downto 16)    <= stdulv(resize(hex_data_len_counter(11 downto 8), 8) + character'pos('0'));
    hex_data_len_counter_ascii(15 downto  8)    <= stdulv(resize(hex_data_len_counter( 7 downto 4), 8) + character'pos('0'));
    hex_data_len_counter_ascii( 7 downto  0)    <= stdulv(resize(hex_data_len_counter( 3 downto 0), 8) + character'pos('0'));
    
    UART_SENDER_inst : entity work.UART_SENDER
        generic map (
            CLK_IN_PERIOD   => CLK_IN_PERIOD,
            BAUD_RATE       => BAUD_RATE,
            DATA_BITS       => 8,
            STOP_BITS       => 1,
            PARITY_BIT_TYPE => 0,
            BUFFER_SIZE     => BUFFER_SIZE
        )
        port map (
            CLK => CLK,
            RST => RST,
            
            DIN     => cur_reg.tx_din,
            WR_EN   => cur_reg.tx_wr_en,
            CTS     => BT_CTS,
            
            TXD     => BT_TXD
        );
    
    UART_BLUETOOTH_INPUT_PARSER_inst : entity work.UART_BLUETOOTH_INPUT_PARSER
        generic map (
            CLK_IN_PERIOD   => CLK_IN_PERIOD,
            BAUD_RATE       => BAUD_RATE
        )
        port map (
            CLK => CLK,
            RST => rx_rst,
            
            BT_RXD  => BT_RXD,
            
            PACKET_VALID    => rx_packet_valid,
            DATA_VALID      => rx_data_valid,
            DATA            => rx_data,
            
            MTU_SIZE        => rx_mtu_size,
            MTU_SIZE_VALID  => rx_mtu_size_valid,
            
            OK          => rx_ok,
            CONNECTED   => rx_connected,
            ERROR       => rx_error
        );
    
    data_buf_ASYNC_FIFO_inst : entity work.ASYNC_FIFO
        generic map (
            WIDTH   => 8,
            DEPTH   => BUFFER_SIZE
        )
        port map (
            CLK => CLK,
            RST => RST,
            
            DIN     => DIN,
            WR_EN   => DIN_WR_EN,
            RD_EN   => cur_reg.data_buf_rd_en,
            
            DOUT    => data_buf_dout
        );
    
    data_len_counter_proc : process(RST, CLK)
    begin
        if RST='1' then
            data_len_counter        <= uns(0, 12);
            hex_data_len_counter    <= uns(0, 12);
        elsif rising_edge(CLK) then
            if DIN_WR_EN='1' then
                data_len_counter    <= data_len_counter+1;
                -- simple 3 digit BCD counter
                hex_data_len_counter    <= hex_data_len_counter+1;
                if hex_data_len_counter(3 downto 0)=9 then
                    hex_data_len_counter    <= hex_data_len_counter+7;
                    if hex_data_len_counter(7 downto 4)=9 then
                        hex_data_len_counter    <= hex_data_len_counter+103;
                    end if;
                end if;
            end if;
            if send_packet_q='1' then
                hex_data_len_counter_ascii_to_send  <= hex_data_len_counter_ascii;
                data_len_counter_to_send            <= data_len_counter;
                hex_data_len_counter                <= uns(0, 12);
                data_len_counter                    <= uns(0, 12);
            end if;
            send_packet_q   <= SEND_PACKET;
        end if;
    end process;
    
    stm_proc : process(cur_reg, RST, rx_ok, rx_error, data_buf_dout,
        data_len_counter_to_send, hex_data_len_counter_ascii_to_send, SEND_PACKET)
        alias cr is cur_reg;
        variable r  : reg_type := reg_type_def;
    begin
        r   := cr;
        
        r.bt_rstn           := '1';
        r.bt_wake           := '1';
        r.bt_rts            := '1';
        r.tx_wr_en          := '0';
        r.error             := '0';
        r.data_buf_rd_en    := '0';
        
        if SEND_PACKET='1' then
            r.packet_pending    := true;
        end if;
        
        case cr.state is
            
            when HARD_RESETTING =>
                r.bt_rstn   := '0';
                r.rst_count := cr.rst_count-1;
                if cr.rst_count(cr.rst_count'high)='1' then
                    r.state := WAITING_FOR_BOOT;
                end if;
            
            when WAITING_FOR_BOOT =>
                r.rst_count := "01111";
                if rx_ok='1' then
                    r.state := SENDING_SECURITY_CMD;
                end if;
            
            when SENDING_SECURITY_CMD =>
                r.tx_wr_en      := '1';
                r.tx_din        := stdulv(SECURITY_CMD(int(cr.char_index)));
                r.char_index    := cr.char_index+1;
                if cr.char_index=SECURITY_CMD'length then
                    r.state := WAITING_FOR_SECURITY_ACK;
                end if;
            
            when WAITING_FOR_SECURITY_ACK =>
                r.char_index    := uns(1, 7);
                if rx_ok='1' then
                    r.state := SENDING_DEVICE_NAME_CMD;
                end if;
            
            when SENDING_DEVICE_NAME_CMD =>
                r.tx_wr_en      := '1';
                r.tx_din        := stdulv(DEVICE_NAME_CMD(int(cr.char_index)));
                r.char_index    := cr.char_index+1;
                if cr.char_index=DEVICE_NAME_CMD'length then
                    r.state := WAITING_FOR_DEVICE_NAME_ACK;
                end if;
            
            when WAITING_FOR_DEVICE_NAME_ACK =>
                r.char_index    := uns(1, 7);
                if rx_ok='1' then
                    r.state := SENDING_REGISTER_SERVICE_CMD;
                end if;
            
            when SENDING_REGISTER_SERVICE_CMD =>
                r.tx_wr_en      := '1';
                r.tx_din        := stdulv(REGISTER_SERVICE_CMD(int(cr.char_index)));
                r.char_index    := cr.char_index+1;
                if cr.char_index=REGISTER_SERVICE_CMD'length then
                    r.state := WAITING_FOR_REGISTER_SERVICE_ACK;
                end if;
            
            when WAITING_FOR_REGISTER_SERVICE_ACK =>
                r.char_index    := uns(1, 7);
                if rx_ok='1' then
                    r.state := SENDING_ENABLE_SCAN_CMD;
                end if;
            
            when SENDING_ENABLE_SCAN_CMD =>
                r.tx_wr_en      := '1';
                r.tx_din        := stdulv(ENABLE_SCAN_CMD(int(cr.char_index)));
                r.char_index    := cr.char_index+1;
                if cr.char_index=ENABLE_SCAN_CMD'length then
                    r.state := WAITING_FOR_ENABLE_SCAN_ACK;
                end if;
            
            when WAITING_FOR_ENABLE_SCAN_ACK =>
                r.char_index    := uns(1, 7);
                if rx_ok='1' then
                    r.state := SENDING_AUTO_ACCEPT_CMD;
                end if;
            
            when SENDING_AUTO_ACCEPT_CMD =>
                r.tx_wr_en      := '1';
                r.tx_din        := stdulv(AUTO_ACCEPT_CMD(int(cr.char_index)));
                r.char_index    := cr.char_index+1;
                if cr.char_index=AUTO_ACCEPT_CMD'length then
                    r.state := WAITING_FOR_AUTO_ACCEPT_ACK;
                end if;
            
            when WAITING_FOR_AUTO_ACCEPT_ACK =>
                if rx_ok='1' then
                    r.state := WAITING_FOR_PACKET_TO_SEND;
                end if;
            
            when WAITING_FOR_PACKET_TO_SEND =>
                r.char_index    := uns(1, 7);
                if cr.packet_pending then
                    r.packet_pending    := false;
                    r.state             := SENDING_SEND_DATA_CMD_PREFIX;
                end if;
            
            when SENDING_SEND_DATA_CMD_PREFIX =>
                r.tx_wr_en      := '1';
                r.tx_din        := stdulv(SEND_DATA_CMD_PREFIX(int(cr.char_index)));
                r.char_index    := cr.char_index+1;
                if cr.char_index=SEND_DATA_CMD_PREFIX'length then
                    r.state := SENDING_PACKET_LENGTH1;
                end if;
            
            when SENDING_PACKET_LENGTH1 =>
                r.tx_wr_en  := '1';
                r.tx_din    := hex_data_len_counter_ascii_to_send(23 downto 16);
                r.state     := SENDING_PACKET_LENGTH2;
            
            when SENDING_PACKET_LENGTH2 =>
                r.tx_wr_en  := '1';
                r.tx_din    := hex_data_len_counter_ascii_to_send(15 downto 8);
                r.state     := SENDING_PACKET_LENGTH3;
            
            when SENDING_PACKET_LENGTH3 =>
                r.tx_wr_en  := '1';
                r.tx_din    := hex_data_len_counter_ascii_to_send(7 downto 0);
                r.state     := SENDING_PACKET_COMMA;
            
            when SENDING_PACKET_COMMA =>
                r.tx_wr_en              := '1';
                r.tx_din                := stdulv(',');
                r.bytes_left_counter    := data_len_counter_to_send-3;
                r.data_buf_rd_en        := '1';
                r.state                 := SENDING_PACKET_WAITING_FOR_DATA;
            
            when SENDING_PACKET_WAITING_FOR_DATA =>
                r.data_buf_rd_en    := '1';
                r.state             := SENDING_PACKET;
            
            when SENDING_PACKET =>
                r.tx_wr_en              := '1';
                r.tx_din                := data_buf_dout;
                r.bytes_left_counter    := cr.bytes_left_counter-1;
                if cr.bytes_left_counter(11)='1' then
                    r.state := SENDING_PACKET_LAST_BYTE;
                else
                    r.data_buf_rd_en    := '1';
                end if;
            
            when SENDING_PACKET_LAST_BYTE =>
                r.tx_wr_en  := '1';
                r.tx_din    := data_buf_dout;
                r.state     := SENDING_PACKET_END_CR;
            
            when SENDING_PACKET_END_CR =>
                r.tx_wr_en  := '1';
                r.tx_din    := stdulv(CRLF(1));
                r.state     := SENDING_PACKET_END_LF;
            
            when SENDING_PACKET_END_LF =>
                r.tx_wr_en  := '1';
                r.tx_din    := stdulv(CRLF(2));
                r.state     := WAITING_FOR_PACKET_TO_SEND;
            
            when EVALUATING_ERROR =>
                r.rst_count     := "01111";
                r.char_index    := uns(1, 7);
                if cr.retry_count(cr.retry_count'high)='0' then
                    -- try again 4 times
                    r.retry_count   := cr.retry_count-1;
                    r.state         := HARD_RESETTING;
                else
                    -- give up
                    r.error := '1';
                end if;
            
        end case;
        
        if rx_error='1' then
            r.state := EVALUATING_ERROR;
        end if;
        
        if RST='1' then
            r   := reg_type_def;
        end if;
        
        next_reg    <= r;
    end process;
    
    stm_sync_proc : process(RST, CLK)
    begin
        if RST='1' then
            cur_reg <= reg_type_def;
        elsif rising_edge(CLK) then
            cur_reg <= next_reg;
        end if;
    end process;
    
end rtl;
