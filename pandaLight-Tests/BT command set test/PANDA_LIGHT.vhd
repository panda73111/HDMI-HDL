----------------------------------------------------------------------------------
-- Engineer: Sebastian Huether
-- 
-- Create Date:    21:49:35 07/28/2014 
-- Module Name:    PANDA_LIGHT - rtl 
-- Project Name:   PANDA_LIGHT
-- Tool versions:  Xilinx ISE 14.7
-- Description: 
--
-- Additional Comments: 
--  
--  the UART interface is  identical for Bluetooth and USB
--  
--  command byte format (from the view of the device):
--  
--    bit 7..5 - category
--    bit 4..0 - specific command
--    
--      000xxxxx - system commands                            | implemented
--                                                            | 
--      00000000 | 0x00 - send system information via UART    | x
--      00000001 | 0x01 - reboot                              | 
--                                                            | 
--      001xxxxx - settings related commands                  | 
--                                                            | 
--      00100000 | 0x20 - load settings from flash            | x
--      00100001 | 0x21 - save settings to flash              | x
--      00100010 | 0x22 - receive settings from UART          | x
--      00100011 | 0x23 - send settings to UART               | x
--                                                            | 
--      010xxxxx - bitfile related commands                   | 
--                                                            | 
--      01000000 | 0x40 - receive bitfile from UART           | 
--      01000001 | 0x41 - send bitfile to UART                | 
--                                                            | 
--      011xxxxx - status indications/handshakes from device  | 
--                                                            | 
--      01100000 | 0x60 - pause UART                          | 
--      01100001 | 0x61 - resume UART                         | 
--      
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.help_funcs.all;

entity PANDA_LIGHT is
    generic (
        PANDALIGHT_MAGIC    : string := "PANDALIGHT";
        VERSION_MAJOR       : natural range 0 to 255 := 0;
        VERSION_MINOR       : natural range 0 to 255 := 1;
        G_CLK_MULT          : positive range 2 to 256 := 5; -- 20 MHz * 5 / 2 = 50 MHz
        G_CLK_DIV           : positive range 1 to 256 := 2;
        G_CLK_PERIOD        : real := 20.0; -- 50 MHz in nano seconds
        FCTRL_CLK_MULT      : positive :=  2; -- Flash clock: 20 MHz
        FCTRL_CLK_DIV       : positive :=  5;
        RX0_BITFILE_ADDR    : std_ulogic_vector(23 downto 0) := x"000000";
        RX1_BITFILE_ADDR    : std_ulogic_vector(23 downto 0) := x"060000";
        SETTINGS_FLASH_ADDR : std_ulogic_vector(23 downto 0) := x"0C0000";
        BITFILE_SIZE        : positive := 342816
    );
    port (
        CLK20   : in std_ulogic;
        
        -- USB UART
        USB_RXD     : in std_ulogic;
        USB_TXD     : out std_ulogic := '1';
        USB_CTSN    : in std_ulogic;
        USB_RTSN    : out std_ulogic := '0';
        USB_DSRN    : in std_ulogic;
        USB_DTRN    : out std_ulogic := '0';
        USB_DCDN    : out std_ulogic := '0';
        USB_RIN     : out std_ulogic := '0';
        
        -- BT UART
        BT_CTSN : in std_ulogic;
        BT_RTSN : out std_ulogic := '0';
        BT_RXD  : in std_ulogic;
        BT_TXD  : out std_ulogic := '1';
        BT_WAKE : out std_ulogic := '0';
        BT_RSTN : out std_ulogic := '0';
        
        -- SPI Flash
        FLASH_MISO  : in std_ulogic;
        FLASH_MOSI  : out std_ulogic := '0';
        FLASH_CS    : out std_ulogic := '1';
        FLASH_SCK   : out std_ulogic := '0';
        
        -- PMOD
        PMOD0   : inout std_ulogic_vector(3 downto 0) := "0000";
        PMOD1   : inout std_ulogic_vector(3 downto 0) := "0000"
    );
end PANDA_LIGHT;

architecture rtl of PANDA_LIGHT is
    
    attribute keep  : boolean;
    
    signal g_clk    : std_ulogic := '0';
    signal g_rst    : std_ulogic := '0';
    
    signal g_clk_locked : std_ulogic := '0';
    
    signal pmod0_deb    : std_ulogic_vector(3 downto 0) := x"0";
    signal pmod0_deb_q  : std_ulogic_vector(3 downto 0) := x"0";
    
    signal start_sysinfo_to_uart            : boolean := false;
    signal start_settings_read_from_flash   : boolean := false;
    signal start_settings_write_to_flash    : boolean := false;
    signal start_settings_read_from_uart    : boolean := false;
    signal start_settings_write_to_uart     : boolean := false;
    signal start_bitfile_read_from_uart     : boolean := false;
    signal start_bitfile_write_to_uart      : boolean := false;
    
    signal bitfile_index    : unsigned(0 downto 0) := "0";
    
    signal usb_dsrn_deb         : std_ulogic := '0';
    signal usb_dsrn_deb_q       : std_ulogic := '0';
    
    
    ------------------------------
    --- UART Bluetooth control ---
    ------------------------------
    
    -- inputs
    signal btctrl_clk   : std_ulogic := '0';
    signal btctrl_rst   : std_ulogic := '0';
    
    signal btctrl_bt_cts    : std_ulogic := '0';
    signal btctrl_bt_rxd    : std_ulogic := '0';
    
    signal btctrl_din           : std_ulogic_vector(7 downto 0) := x"00";
    signal btctrl_din_wr_en     : std_ulogic := '0';
    signal btctrl_send_packet   : std_ulogic := '0';
    
    -- outputs
    signal btctrl_bt_rts    : std_ulogic := '0';
    signal btctrl_bt_txd    : std_ulogic := '0';
    signal btctrl_bt_wake   : std_ulogic := '0';
    signal btctrl_bt_rstn   : std_ulogic := '0';
    
    signal btctrl_dout          : std_ulogic_vector(7 downto 0) := x"00";
    signal btctrl_dout_valid    : std_ulogic := '0';
    
    signal btctrl_connected : std_ulogic := '0';
    
    signal btctrl_mtu_size          : std_ulogic_vector(9 downto 0) := (others => '0');
    signal btctrl_mtu_size_valid    : std_ulogic := '0';
    
    signal btctrl_error : std_ulogic := '0';
    signal btctrl_busy  : std_ulogic := '0';
    
    
    ------------------------
    --- UART USB control ---
    ------------------------
    
    signal usbctrl_clk  : std_ulogic := '0';
    signal usbctrl_rst  : std_ulogic := '0';
    
    signal usbctrl_cts  : std_ulogic := '0';
    signal usbctrl_rts  : std_ulogic := '0';
    signal usbctrl_rxd  : std_ulogic := '0';
    signal usbctrl_txd  : std_ulogic := '0';
    
    signal usbctrl_din          : std_ulogic_vector(7 downto 0) := x"00";
    signal usbctrl_din_wr_en    : std_ulogic := '0';
    
    signal usbctrl_dout         : std_ulogic_vector(7 downto 0) := x"00";
    signal usbctrl_dout_valid   : std_ulogic := '0';
    
    signal usbctrl_full     : std_ulogic := '0';
    signal usbctrl_error    : std_ulogic := '0';
    signal usbctrl_busy     : std_ulogic := '0';
    
    
    ----------------------------
    --- UART transport layer ---
    ----------------------------
    
    signal tl_clk   : std_ulogic := '0';
    signal tl_rst   : std_ulogic := '0';
    
    signal tl_packet_in         : std_ulogic_vector(7 downto 0) := x"00";
    signal tl_packet_in_wr_en   : std_ulogic := '0';
    
    signal tl_packet_out        : std_ulogic_vector(7 downto 0) := x"00";
    signal tl_packet_out_valid  : std_ulogic := '0';
    signal tl_packet_out_end    : std_ulogic := '0';
    
    signal tl_din           : std_ulogic_vector(7 downto 0) := x"00";
    signal tl_din_wr_en     : std_ulogic := '0';
    signal tl_send_packet   : std_ulogic := '0';
    
    signal tl_dout          : std_ulogic_vector(7 downto 0) := x"00";
    signal tl_dout_valid    : std_ulogic := '0';
    
    signal tl_busy  : std_ulogic := '0';
    
    
    --------------------
    --- configurator ---
    --------------------
    
    -- inputs
    signal conf_clk : std_ulogic := '0';
    signal conf_rst : std_ulogic := '0';
    
    signal conf_calculate           : std_ulogic := '0';
    signal conf_configure_ledcor    : std_ulogic := '0';
    signal conf_configure_ledex     : std_ulogic := '0';
    
    signal conf_frame_width     : std_ulogic_vector(10 downto 0) := (others => '0');
    signal conf_frame_height    : std_ulogic_vector(10 downto 0) := (others => '0');
    
    signal conf_settings_addr   : std_ulogic_vector(9 downto 0) := (others => '0');
    signal conf_settings_wr_en  : std_ulogic := '0';
    signal conf_settings_din    : std_ulogic_vector(7 downto 0) := x"00";
    signal conf_settings_dout   : std_ulogic_vector(7 downto 0) := x"00";
    
    -- outputs
    signal conf_cfg_sel_ledcor  : std_ulogic := '0';
    signal conf_cfg_sel_ledex   : std_ulogic := '0';
    
    signal conf_cfg_addr        : std_ulogic_vector(9 downto 0) := (others => '0');
    signal conf_cfg_wr_en       : std_ulogic := '0';
    signal conf_cfg_data        : std_ulogic_vector(7 downto 0) := x"00";
    
    signal conf_busy    : std_ulogic := '0';
    
    
    -------------------------
    --- SPI flash control ---
    -------------------------
    
    -- inputs
    signal fctrl_clk    : std_ulogic := '0';
    signal fctrl_rst    : std_ulogic := '0';
    
    signal fctrl_addr   : std_ulogic_vector(23 downto 0) := x"000000";
    signal fctrl_din    : std_ulogic_vector(7 downto 0) := x"00";
    signal fctrl_rd_en  : std_ulogic := '0';
    signal fctrl_wr_en  : std_ulogic := '0';
    signal fctrl_miso   : std_ulogic := '0';
    
    -- outputs
    signal fctrl_dout   : std_ulogic_vector(7 downto 0) := x"00";
    signal fctrl_valid  : std_ulogic := '0';
    signal fctrl_wr_ack : std_ulogic := '0';
    signal fctrl_busy   : std_ulogic := '0';
    signal fctrl_full   : std_ulogic := '0';
    signal fctrl_mosi   : std_ulogic := '0';
    signal fctrl_c      : std_ulogic := '0';
    signal fctrl_sn     : std_ulogic := '1';
    
begin
    
    ------------------------------
    ------ clock management ------
    ------------------------------
    
    CLK_MAN_inst : entity work.CLK_MAN
        generic map (
            CLK_IN_PERIOD   => 50.0, -- 20 MHz in nano seconds
            MULTIPLIER      => G_CLK_MULT,
            DIVISOR         => G_CLK_DIV
        )
        port map (
            RST => '0',
            
            CLK_IN  => CLK20,
            CLK_OUT => g_clk,
            LOCKED  => g_clk_locked
        );
    
    
    --------------------------------------
    ------ global signal management ------
    --------------------------------------
    
    g_rst   <= '1' when g_clk_locked='0' or pmod0_deb(0)='1' else '0';
    
    FLASH_MOSI  <= fctrl_mosi;
    FLASH_CS    <= fctrl_sn;
    FLASH_SCK   <= fctrl_c;
    
    PMOD0(0)    <= 'Z';
    PMOD0(1)    <= 'Z';
    PMOD0(2)    <= 'Z';
    PMOD0(3)    <= 'Z';
    
    PMOD1(0)    <= 'Z';
    PMOD1(1)    <= 'Z';
    PMOD1(2)    <= 'Z';
    PMOD1(3)    <= 'Z';
    
    BT_TXD  <= btctrl_bt_txd;
    USB_TXD <= usbctrl_txd;
    
    USB_RTSN    <= not usbctrl_rts;
    BT_RTSN     <= not btctrl_bt_rts;
    
    BT_RSTN <= btctrl_bt_rstn;
    BT_WAKE <= btctrl_bt_wake;
    
    pmod0_DEBOUNCE_gen : for i in 0 to 3 generate
        
        pmod0_DEBOUNCE_inst : entity work.DEBOUNCE
            generic map (
                CYCLE_COUNT => 100
            )
            port map (
                CLK => g_clk,
                I   => PMOD0(i),
                O   => pmod0_deb(i)
            );
        
    end generate;
    
    pmod0_deb_sync_proc : process(g_clk)
    begin
        if rising_edge(g_clk) then
            pmod0_deb_q <= pmod0_deb;
        end if;
    end process;
    
    
    ------------------------------
    --- UART Bluetooth control ---
    ------------------------------
    
    btctrl_clk  <= g_clk;
    btctrl_rst  <= g_rst;
    
    btctrl_bt_cts   <= not BT_CTSN;
    btctrl_bt_rxd   <= BT_RXD;
    
    btctrl_din          <= tl_packet_out;
    btctrl_din_wr_en    <= tl_packet_out_valid;
    btctrl_send_packet  <= tl_packet_out_end;
    
    UART_BLUETOOTH_CONTROL_inst : entity work.UART_BLUETOOTH_CONTROL
        generic map (
            CLK_IN_PERIOD   => G_CLK_PERIOD,
            BUFFER_SIZE     => 2048
        )
        port map (
            CLK => btctrl_clk,
            RST => btctrl_rst,
            
            BT_CTS  => btctrl_bt_cts,
            BT_RTS  => btctrl_bt_rts,
            BT_RXD  => btctrl_bt_rxd,
            BT_TXD  => btctrl_bt_txd,
            BT_WAKE => btctrl_bt_wake,
            BT_RSTN => btctrl_bt_rstn,
            
            DIN         => btctrl_din,
            DIN_WR_EN   => btctrl_din_wr_en,
            SEND_PACKET => btctrl_send_packet,
            
            DOUT        => btctrl_dout,
            DOUT_VALID  => btctrl_dout_valid,
            
            CONNECTED   => btctrl_connected,
            
            MTU_SIZE        => btctrl_mtu_size,
            MTU_SIZE_VALID  => btctrl_mtu_size_valid,
            
            ERROR   => btctrl_error,
            BUSY    => btctrl_busy
        );
    
    
    ------------------------
    --- UART USB control ---
    ------------------------
    
    usbctrl_clk <= g_clk;
    usbctrl_rst <= g_rst;
    
    usbctrl_cts <= not USB_CTSN;
    usbctrl_rxd <= USB_RXD;
    
    usbctrl_din         <= tl_packet_out;
    usbctrl_din_wr_en   <= tl_packet_out_valid;
    
    usb_dsrn_DEBOUNCE_inst : entity work.DEBOUNCE
        generic map (
            CYCLE_COUNT => 100
        )
        port map (
            CLK => g_clk,
            I   => USB_DSRN,
            O   => usb_dsrn_deb
        );
    
    UART_CONTROL_inst : entity work.UART_CONTROL
        generic map (
            CLK_IN_PERIOD   => G_CLK_PERIOD,
            BUFFER_SIZE     => 2048
        )
        port map (
            CLK => usbctrl_clk,
            RST => usbctrl_rst,
            
            CTS => usbctrl_cts,
            RTS => usbctrl_rts,
            RXD => usbctrl_rxd,
            TXD => usbctrl_txd,
            
            DIN         => usbctrl_din,
            DIN_WR_EN   => usbctrl_din_wr_en,
            
            DOUT        => usbctrl_dout,
            DOUT_VALID  => usbctrl_dout_valid,
            
            FULL    => usbctrl_full,
            ERROR   => usbctrl_error,
            BUSY    => usbctrl_busy
        );
    
    
    ----------------------------
    --- UART transport layer ---
    ----------------------------
    
    tl_clk  <= g_clk;
    
    -- if one device connects, tl_rst <= '0'
    tl_rst  <= g_rst or not (btctrl_connected or not usb_dsrn_deb);
    
    tl_packet_in        <= btctrl_dout when btctrl_dout_valid='1' else usbctrl_dout;
    tl_packet_in_wr_en  <= btctrl_dout_valid or usbctrl_dout_valid;
    
    TRANSPORT_LAYER_inst : entity work.TRANSPORT_LAYER
        port map (
            CLK => tl_clk,
            RST => tl_rst,
            
            PACKET_IN       => tl_packet_in,
            PACKET_IN_WR_EN => tl_packet_in_wr_en,
            
            PACKET_OUT          => tl_packet_out,
            PACKET_OUT_VALID    => tl_packet_out_valid,
            PACKET_OUT_END      => tl_packet_out_end,
            
            DIN         => tl_din,
            DIN_WR_EN   => tl_din_wr_en,
            SEND_PACKET => tl_send_packet,
            
            DOUT        => tl_dout,
            DOUT_VALID  => tl_dout_valid,
            
            BUSY    => tl_busy
        );
    
    tl_stim_gen : if true generate
        type cmd_eval_state_type is (
            WAITING_FOR_COMMAND,
            RECEIVING_DATA_FROM_UART,
            RECEIVING_BITFILE_READ_INDEX_FROM_UART,
            RECEIVING_BITFILE_WRITE_INDEX_FROM_UART
        );
        
        signal cmd_eval_state   : cmd_eval_state_type := WAITING_FOR_COMMAND;
        signal cmd_eval_counter : unsigned(20 downto 0) := uns(1023, 21);
        
        type data_handling_state_type is (
            WAITING_FOR_COMMAND,
            SENDING_PANDALIGHT_MAGIC_TO_UART,
            SENDING_MAJOR_VERSION_TO_UART,
            SENDING_MINOR_VERSION_TO_UART,
            WAITING_FOR_DATA,
            SENDING_SETTINGS_TO_UART,
            SENDING_BITFILE_TO_UART
        );
        
        signal data_handling_state      : data_handling_state_type := WAITING_FOR_COMMAND;
        signal data_handling_counter    : unsigned(20 downto 0) := uns(1022, 21);
        signal magic_char_index         : unsigned(7 downto 0) := uns(1, 8);
    begin
        
        tl_evaluation_proc : process(tl_clk, tl_rst)
        begin
            if tl_rst='1' then
                cmd_eval_state                  <= WAITING_FOR_COMMAND;
                cmd_eval_counter                <= uns(1023, cmd_eval_counter'length);
                start_sysinfo_to_uart           <= false;
                start_settings_read_from_flash  <= false;
                start_settings_write_to_flash   <= false;
                start_settings_read_from_uart   <= false;
                start_settings_write_to_uart    <= false;
                start_bitfile_read_from_uart    <= false;
                start_bitfile_write_to_uart     <= false;
            elsif rising_edge(tl_clk) then
                start_sysinfo_to_uart           <= false;
                start_settings_read_from_flash  <= false;
                start_settings_write_to_flash   <= false;
                start_settings_read_from_uart   <= false;
                start_settings_write_to_uart    <= false;
                start_bitfile_read_from_uart    <= false;
                start_bitfile_write_to_uart     <= false;
                case cmd_eval_state is
                    
                    when WAITING_FOR_COMMAND =>
                        if tl_dout_valid='1' then
                            case tl_dout is
                                when x"00" => -- send system information via UART
                                    start_sysinfo_to_uart           <= true;
                                when x"20" => -- load settings from flash
                                    start_settings_read_from_flash  <= true;
                                when x"21" => -- save settings to flash
                                    start_settings_write_to_flash   <= true;
                                when x"22" => -- receive settings from UART
                                    start_settings_read_from_uart   <= true;
                                    cmd_eval_counter    <= uns(1023, cmd_eval_counter'length);
                                    cmd_eval_state      <= RECEIVING_DATA_FROM_UART;
                                when x"23" => -- send settings to UART
                                    start_settings_write_to_uart    <= true;
                                when x"40" => -- receive bitfile from UART
                                    cmd_eval_state      <= RECEIVING_BITFILE_READ_INDEX_FROM_UART;
                                when x"41" => -- send bitfile to UART
                                    cmd_eval_state      <= RECEIVING_BITFILE_WRITE_INDEX_FROM_UART;
                                when others =>
                                    null;
                            end case;
                        end if;
                    
                    when RECEIVING_DATA_FROM_UART =>
                        if tl_dout_valid='1' then
                            cmd_eval_counter    <= cmd_eval_counter-1;
                        end if;
                        if cmd_eval_counter(cmd_eval_counter'high)='1' then
                            cmd_eval_state  <= WAITING_FOR_COMMAND;
                        end if;
                    
                    when RECEIVING_BITFILE_READ_INDEX_FROM_UART =>
                        if tl_dout_valid='1' then
                            bitfile_index                   <= uns(tl_dout(0 downto 0));
                            start_bitfile_read_from_uart    <= true;
                            cmd_eval_counter    <= uns(BITFILE_SIZE, cmd_eval_counter'length);
                            cmd_eval_state      <= RECEIVING_DATA_FROM_UART;
                        end if;
                    
                    when RECEIVING_BITFILE_WRITE_INDEX_FROM_UART =>
                        if tl_dout_valid='1' then
                            bitfile_index                   <= uns(tl_dout(0 downto 0));
                            start_bitfile_write_to_uart     <= true;
                            cmd_eval_state      <= WAITING_FOR_COMMAND;
                        end if;
                    
                end case;
            end if;
        end process;
        
        tl_stim_proc : process(tl_rst, tl_clk)
        begin
            if tl_rst='1' then
                data_handling_state     <= WAITING_FOR_COMMAND;
                data_handling_counter   <= uns(1022, data_handling_counter'length);
                magic_char_index        <= uns(1, magic_char_index'length);
                tl_din_wr_en            <= '0';
                tl_send_packet          <= '0';
            elsif rising_edge(tl_clk) then
                tl_din_wr_en    <= '0';
                tl_send_packet  <= '0';
                
                case data_handling_state is
                    
                    when WAITING_FOR_COMMAND =>
                        if start_sysinfo_to_uart then
                            data_handling_counter   <=
                                uns(PANDALIGHT_MAGIC'length-2, data_handling_counter'length);
                            magic_char_index        <= uns(1, magic_char_index'length);
                            data_handling_state     <= SENDING_PANDALIGHT_MAGIC_TO_UART;
                        end if;
                        if start_settings_write_to_uart then
                            data_handling_counter   <= uns(1022, data_handling_counter'length);
                            data_handling_state     <= WAITING_FOR_DATA;
                        end if;
                    
                    when SENDING_PANDALIGHT_MAGIC_TO_UART =>
                        tl_din_wr_en            <= '1';
                        tl_din                  <= stdulv(PANDALIGHT_MAGIC(int(magic_char_index)));
                        magic_char_index        <= magic_char_index+1;
                        data_handling_counter   <= data_handling_counter-1;
                        if data_handling_counter(data_handling_counter'high)='1' then
                            data_handling_state <= SENDING_MAJOR_VERSION_TO_UART;
                        end if;
                    
                    when SENDING_MAJOR_VERSION_TO_UART =>
                        tl_din_wr_en        <= '1';
                        tl_din              <= stdulv(VERSION_MAJOR, 8);
                        data_handling_state <= SENDING_MINOR_VERSION_TO_UART;
                    
                    when SENDING_MINOR_VERSION_TO_UART =>
                        tl_din_wr_en        <= '1';
                        tl_din              <= stdulv(VERSION_MINOR, 8);
                        tl_send_packet      <= '1';
                        data_handling_state <= WAITING_FOR_COMMAND;
                    
                    when WAITING_FOR_DATA =>
                        data_handling_state <= SENDING_SETTINGS_TO_UART;
                    
                    when SENDING_SETTINGS_TO_UART =>
                        tl_din_wr_en            <= '1';
                        tl_din                  <= conf_settings_dout;
                        data_handling_counter   <= data_handling_counter-1;
                        if data_handling_counter(7 downto 0)=uns(255, 8) then
                            tl_send_packet  <= '1';
                        end if;
                        if data_handling_counter(data_handling_counter'high)='1' then
                            data_handling_state <= WAITING_FOR_COMMAND;
                        end if;
                    
                    when SENDING_BITFILE_TO_UART =>
                        null;
                    
                end case;
            end if;
        end process;
        
    end generate;
    
    
    -------------------
    -- configurator ---
    -------------------
    
    conf_clk    <= g_clk;
    conf_rst    <= g_rst;
    
    CONFIGURATOR_inst : entity work.CONFIGURATOR
        port map (
            CLK => conf_clk,
            RST => conf_rst,
            
            CALCULATE           => conf_calculate,
            CONFIGURE_LEDCOR    => conf_configure_ledcor,
            CONFIGURE_LEDEX     => conf_configure_ledex,
            
            FRAME_WIDTH     => conf_frame_width,
            FRAME_HEIGHT    => conf_frame_height,
            
            SETTINGS_ADDR   => conf_settings_addr,
            SETTINGS_WR_EN  => conf_settings_wr_en,
            SETTINGS_DIN    => conf_settings_din,
            SETTINGS_DOUT   => conf_settings_dout,
            
            CFG_SEL_LEDCOR  => conf_cfg_sel_ledcor,
            CFG_SEL_LEDEX   => conf_cfg_sel_ledex,
            
            CFG_ADDR    => conf_cfg_addr,
            CFG_WR_EN   => conf_cfg_wr_en,
            CFG_DATA    => conf_cfg_data,
            
            BUSY    => conf_busy
        );
    
    configurator_stim_gen : if true generate
        type led_lookup_table_type is
            array(0 to 255) of
            std_ulogic_vector(7 downto 0);
        
        type state_type is (
            INIT,
            READING_SETTINGS_FROM_FLASH,
            CALCULATING,
            CONF_LEDCOR_WAITING_FOR_BUSY,
            CONF_LEDCOR_WAITING_FOR_IDLE,
            CONF_LEDCOR_CONFIGURING_LED_CORRECTION,
            CONF_LEDEX_WAITING_FOR_BUSY,
            CONF_LEDEX_WAITING_FOR_IDLE,
            CONF_LEDEX_CONFIGURING_LED_COLOR_EXTRACTOR,
            IDLE_WAITING_FOR_IDLE,
            IDLE,
            WRITING_SETTINGS_TO_FLASH,
            RECEIVING_SETTINGS_FROM_UART,
            SENDING_SETTINGS_TO_UART
        );
        
        signal state            : state_type := INIT;
        signal counter          : unsigned(10 downto 0) := uns(1023, 11);
        signal settings_addr    : std_ulogic_vector(9 downto 0) := (others => '0');
    begin
        
        conf_frame_width    <= stdulv(640, 11);
        conf_frame_height   <= stdulv(480, 11);
        
        configurator_stim_proc : process(g_clk, g_rst)
        begin
            if g_rst='1' then
                conf_settings_wr_en     <= '0';
                conf_settings_din       <= x"00";
                conf_calculate          <= '0';
                conf_configure_ledex    <= '0';
                conf_configure_ledcor   <= '0';
                counter                 <= uns(1023, 11);
                settings_addr           <= (others => '0');
                conf_settings_addr      <= (others => '0');
            elsif rising_edge(g_clk) then
                conf_settings_wr_en     <= '0';
                conf_calculate          <= '0';
                conf_configure_ledex    <= '0';
                conf_configure_ledcor   <= '0';
                
                case state is
                    
                    when INIT =>
                        counter         <= uns(1023, counter'length);
                        settings_addr   <= (others => '0');
                        state           <= READING_SETTINGS_FROM_FLASH;
                    
                    when READING_SETTINGS_FROM_FLASH =>
                        conf_settings_addr  <= settings_addr;
                        conf_settings_wr_en <= fctrl_valid;
                        conf_settings_din   <= fctrl_dout;
                        if fctrl_valid='1' then
                            counter         <= counter-1;
                            settings_addr   <= settings_addr+1;
                        end if;
                        if counter(counter'high)='1' then
                            -- read 1k bytes
                            state   <= CALCULATING;
                        end if;
                    
                    when CALCULATING =>
                        conf_calculate  <= '1';
                        state           <= CONF_LEDCOR_WAITING_FOR_BUSY;
                    
                    when CONF_LEDCOR_WAITING_FOR_BUSY =>
                        if conf_busy='1' then
                            state   <= CONF_LEDCOR_WAITING_FOR_IDLE;
                        end if;
                    
                    when CONF_LEDCOR_WAITING_FOR_IDLE =>
                        if conf_busy='0' then
                            state   <= CONF_LEDCOR_CONFIGURING_LED_CORRECTION;
                        end if;
                    
                    when CONF_LEDCOR_CONFIGURING_LED_CORRECTION =>
                        conf_configure_ledcor   <= '1';
                        state                   <= CONF_LEDEX_WAITING_FOR_BUSY;
                    
                    when CONF_LEDEX_WAITING_FOR_BUSY =>
                        if conf_busy='1' then
                            state   <= CONF_LEDEX_WAITING_FOR_IDLE;
                        end if;
                    
                    when CONF_LEDEX_WAITING_FOR_IDLE =>
                        if conf_busy='0' then
                            state   <= CONF_LEDEX_CONFIGURING_LED_COLOR_EXTRACTOR;
                        end if;
                    
                    when CONF_LEDEX_CONFIGURING_LED_COLOR_EXTRACTOR =>
                        conf_configure_ledex    <= '1';
                        state                   <= IDLE_WAITING_FOR_IDLE;
                    
                    when IDLE_WAITING_FOR_IDLE =>
                        if conf_busy='0' then
                            state   <= IDLE;
                        end if;
                    
                    when IDLE =>
                        counter             <= uns(1023, counter'length);
                        settings_addr       <= (others => '0');
                        conf_settings_addr  <= (others => '0');
                        if start_settings_read_from_flash then
                            state   <= READING_SETTINGS_FROM_FLASH;
                        end if;
                        if start_settings_write_to_flash then
                            state   <= WRITING_SETTINGS_TO_FLASH;
                        end if;
                        if start_settings_read_from_uart then
                            state   <= RECEIVING_SETTINGS_FROM_UART;
                        end if;
                        if start_settings_write_to_uart then
                            state   <= SENDING_SETTINGS_TO_UART;
                        end if;
                    
                    when WRITING_SETTINGS_TO_FLASH =>
                        conf_settings_addr  <= settings_addr;
                        counter             <= counter-1;
                        settings_addr       <= settings_addr+1;
                        if counter(counter'high)='1' then
                            -- wrote 1k bytes
                            state   <= IDLE;
                        end if;
                    
                    when RECEIVING_SETTINGS_FROM_UART =>
                        conf_settings_addr  <= settings_addr;
                        conf_settings_wr_en <= tl_dout_valid;
                        conf_settings_din   <= tl_dout;
                        if tl_dout_valid='1' then
                            counter         <= counter-1;
                            settings_addr   <= settings_addr+1;
                        end if;
                        if counter(counter'high)='1' then
                            -- received 1k bytes
                            state   <= CALCULATING;
                        end if;
                    
                    when SENDING_SETTINGS_TO_UART =>
                        conf_settings_addr  <= conf_settings_addr+1;
                        counter             <= counter-1;
                        if counter(counter'high)='1' then
                            -- sent 1k bytes
                            state   <= IDLE;
                        end if;
                    
                end case;
            end if;
        end process;
        
    end generate;
    
    
    -------------------------
    --- SPI Flash control ---
    -------------------------
    
    fctrl_clk   <= g_clk;
    fctrl_rst   <= g_rst;
    
    fctrl_miso  <= FLASH_MISO;
    
    SPI_FLASH_CONTROL_inst : entity work.SPI_FLASH_CONTROL
        generic map (
            CLK_IN_PERIOD   => G_CLK_PERIOD,
            CLK_OUT_MULT    => FCTRL_CLK_MULT,
            CLK_OUT_DIV     => FCTRL_CLK_DIV,
            BUF_SIZE        => 1024
        )
        port map (
            CLK => fctrl_clk,
            RST => fctrl_rst,
            
            ADDR    => fctrl_addr,
            DIN     => fctrl_din,
            RD_EN   => fctrl_rd_en,
            WR_EN   => fctrl_wr_en,
            MISO    => fctrl_miso,
            
            DOUT    => fctrl_dout,
            VALID   => fctrl_valid,
            WR_ACK  => fctrl_wr_ack,
            BUSY    => fctrl_busy,
            FULL    => fctrl_full,
            MOSI    => fctrl_mosi,
            C       => fctrl_c,
            SN      => fctrl_sn
        );
    
    spi_flash_control_stim_gen : if true generate
        type state_type is (
            INIT,
            IDLE,
            READING_DATA,
            WAITING_FOR_DATA,
            WRITING_DATA
        );
        
        signal state    : state_type := INIT;
        signal counter  : unsigned(20 downto 0) := uns(1023, 21);
        
        signal handling_settings    : boolean := true;
        
        signal bitfile_address  : std_ulogic_vector(23 downto 0) := x"000000";
    begin
        
        bitfile_address <= RX0_BITFILE_ADDR when bitfile_index=0 else RX1_BITFILE_ADDR;
        
        fctrl_addr  <= SETTINGS_FLASH_ADDR when handling_settings else bitfile_address;
        fctrl_din   <= conf_settings_dout when handling_settings else tl_dout;
        
        spi_flash_control_stim_proc : process(g_clk, g_rst)
            variable next_state : state_type := INIT;
        begin
            if g_rst='1' then
                state               <= INIT;
                fctrl_rd_en         <= '0';
                fctrl_wr_en         <= '0';
                handling_settings   <= true;
            elsif rising_edge(g_clk) then
                fctrl_rd_en <= '0';
                fctrl_wr_en <= '0';
                
                case state is
                    
                    when INIT =>
                        state   <= READING_DATA;
                    
                    when IDLE =>
                        handling_settings   <= true;
                        counter             <= uns(1023, counter'length);
                        
                        if start_bitfile_read_from_uart or start_bitfile_write_to_uart then
                            handling_settings   <= false;
                            counter             <= uns(BITFILE_SIZE, counter'length);
                        end if;
                        
                        next_state  := state;
                        if start_settings_read_from_flash then
                            next_state  := READING_DATA;
                        end if;
                        if start_settings_write_to_flash then
                            next_state  := WAITING_FOR_DATA;
                        end if;
                        if start_bitfile_read_from_uart then
                            next_state  := READING_DATA;
                        end if;
                        if start_bitfile_write_to_uart then
                            next_state  := WAITING_FOR_DATA;
                        end if;
                        state   <= next_state;
                    
                    when READING_DATA =>
                        if counter(counter'high)='1' then
                            state   <= IDLE;
                        else
                            fctrl_rd_en <= '1';
                        end if;
                        if fctrl_valid='1' then
                            counter <= counter-1;
                        end if;
                    
                    when WAITING_FOR_DATA =>
                        state   <= WRITING_DATA;
                    
                    when WRITING_DATA =>
                        counter     <= counter-1;
                        if counter(counter'high)='1' then
                            state   <= IDLE;
                        else
                            fctrl_wr_en <= '1';
                        end if;
                    
                end case;
            end if;
        end process;
        
    end generate;
    
end rtl;

