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
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
library UNISIM;
use UNISIM.VComponents.all;
use work.help_funcs.all;

entity PANDA_LIGHT is
    generic (
        G_CLK_MULT          : positive range 2 to 256 := 5; -- 20 MHz * 5 / 2 = 50 MHz
        G_CLK_DIV           : positive range 1 to 256 := 2;
        G_CLK_PERIOD        : real := 20.0; -- 50 MHz in nano seconds
        FCTRL_CLK_MULT      : positive := 2; -- Flash clock: 20 MHz
        FCTRL_CLK_DIV       : positive := 5;
        HOR_LED_COUNT       : positive :=  13;
        VER_LED_COUNT       : positive :=   7;
        START_LED_NUM       : natural :=  10;
        FRAME_DELAY         : natural := 120;
        SETTINGS_FLASH_ADDR : std_ulogic_vector(23 downto 0) := x"060000"
    );
    port (
        CLK20   : in std_ulogic;
        
        -- SPI Flash
        FLASH_MISO  : in std_ulogic;
        FLASH_MOSI  : out std_ulogic := '0';
        FLASH_CS    : out std_ulogic := '1';
        FLASH_SCK   : out std_ulogic := '0';
        
        -- PMOD
        PMOD0   : inout std_ulogic_vector(3 downto 0) := "0000"
    );
end PANDA_LIGHT;

architecture rtl of PANDA_LIGHT is
    
    attribute keep  : boolean;
    
    signal g_clk    : std_ulogic := '0';
    signal g_rst    : std_ulogic := '0';
    
    signal g_clk_stopped    : std_ulogic := '0';
    
    signal pmod0_deb    : std_ulogic_vector(3 downto 0) := x"0";
    signal pmod0_deb_q  : std_ulogic_vector(3 downto 0) := x"0";
    
    --------------------
    --- configurator ---
    --------------------
    
    -- Inputs
    signal conf_clk : std_ulogic := '0';
    signal conf_rst : std_ulogic := '0';
    
    signal conf_calculate           : std_ulogic := '0';
    signal conf_configure_ledcor    : std_ulogic := '0';
    signal conf_configure_ledex     : std_ulogic := '0';
    
    signal conf_frame_width     : std_ulogic_vector(10 downto 0) := (others => '0');
    signal conf_frame_height    : std_ulogic_vector(10 downto 0) := (others => '0');
    
    signal conf_settings_wr_en  : std_ulogic := '0';
    signal conf_settings_data   : std_ulogic_vector(7 downto 0) := x"00";
    
    -- Outputs
    signal conf_cfg_sel_ledcor  : std_ulogic := '0';
    signal conf_cfg_sel_ledex   : std_ulogic := '0';
    
    signal conf_cfg_addr        : std_ulogic_vector(9 downto 0) := (others => '0');
    signal conf_cfg_wr_en       : std_ulogic := '0';
    signal conf_cfg_data        : std_ulogic_vector(7 downto 0) := x"00";
    
    signal conf_idle    : std_ulogic := '0';
    
    
    -------------------------
    --- SPI Flash control ---
    -------------------------
    
    -- Inputs
    signal fctrl_clk    : std_ulogic := '0';
    signal fctrl_rst    : std_ulogic := '0';
    
    signal fctrl_addr   : std_ulogic_vector(23 downto 0) := x"000000";
    signal fctrl_din    : std_ulogic_vector(7 downto 0) := x"00";
    signal fctrl_rd_en  : std_ulogic := '0';
    signal fctrl_wr_en  : std_ulogic := '0';
    signal fctrl_miso   : std_ulogic := '0';
    
    -- Outputs
    signal fctrl_dout   : std_ulogic_vector(7 downto 0) := x"00";
    signal fctrl_valid  : std_ulogic := '0';
    signal fctrl_wr_ack : std_ulogic := '0';
    signal fctrl_busy   : std_ulogic := '0';
    signal fctrl_full   : std_ulogic := '0';
    signal fctrl_mosi   : std_ulogic := '0';
    signal fctrl_c      : std_ulogic := '0';
    signal fctrl_sn     : std_ulogic := '1';
    
    attribute keep of fctrl_dout    : signal is true;
    attribute keep of fctrl_valid   : signal is true;
    attribute keep of fctrl_wr_ack  : signal is true;
    attribute keep of fctrl_busy    : signal is true;
    
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
            
            CLK_IN          => CLK20,
            CLK_OUT         => g_clk,
            CLK_OUT_STOPPED => g_clk_stopped
        );
    
    
    --------------------------------------
    ------ global signal management ------
    --------------------------------------
    
    g_rst   <= g_clk_stopped;
    
    FLASH_MOSI  <= fctrl_mosi;
    FLASH_CS    <= fctrl_sn;
    FLASH_SCK   <= fctrl_c;
    
    PMOD0(0)    <= 'Z';
    PMOD0(1)    <= 'Z';
    PMOD0(2)    <= 'Z';
    PMOD0(3)    <= 'Z';
    
    pmod0_DEBOUNCE_gen : for i in 0 to 3 generate
        
        pmod00_DEBOUNCE_inst : entity work.DEBOUNCE
            generic map (
                CYCLE_COUNT => 100
            )
            port map (
                CLK => g_clk,
                I   => PMOD0(i),
                O   => pmod0_deb(i)
            );
        
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
            
            SETTINGS_WR_EN  => conf_settings_wr_en,
            SETTINGS_DATA   => conf_settings_data,
            
            CFG_SEL_LEDCOR  => conf_cfg_sel_ledcor,
            CFG_SEL_LEDEX   => conf_cfg_sel_ledex,
            
            CFG_ADDR    => conf_cfg_addr,
            CFG_WR_EN   => conf_cfg_wr_en,
            CFG_DATA    => conf_cfg_data,
            
            IDLE    => conf_idle
        );
    
    configurator_stim_gen : if true generate
        type led_lookup_table_type is
            array(0 to 255) of
            std_ulogic_vector(7 downto 0);
        
        type state_type is (
            INIT,
            SENDING_SETTINGS,
            CALCULATING,
            CONF_LEDCOR_WAITING_FOR_BUSY,
            CONF_LEDCOR_WAITING_FOR_IDLE,
            CONF_LEDCOR_CONFIGURING_LED_CORRECTION,
            IDLE
        );
        
        signal state    : state_type := INIT;
        signal counter  : unsigned(9 downto 0) := (others => '1');
        
        function calc_gamma_cor_value(i : natural; y : real)
            return natural is
        begin
            return natural(255.0 * ((real(i) / 255.0) ** y));
        end function;
        
        function calc_gamma_cor_table(y : real)
            return led_lookup_table_type
        is
            variable t  : led_lookup_table_type;
        begin
            for i in 0 to 255 loop
                t(i)    := stdulv(calc_gamma_cor_value(i, y), 8);
            end loop;
            return t;
        end function;
        
        constant R_LOOKUP_TABLE : led_lookup_table_type := calc_gamma_cor_table(2.0);
        constant G_LOOKUP_TABLE : led_lookup_table_type := calc_gamma_cor_table(2.0);
        constant B_LOOKUP_TABLE : led_lookup_table_type := calc_gamma_cor_table(2.0);
    begin
        
        conf_frame_width    <= stdulv(640, 11);
        conf_frame_height   <= stdulv(480, 11);
        
        configurator_stim_proc : process(g_clk, g_rst)
        begin
            if g_rst='1' then
                conf_settings_wr_en     <= '0';
                conf_settings_data      <= x"00";
                conf_calculate          <= '0';
                conf_configure_ledcor   <= '0';
                counter                 <= (others => '1');
            elsif rising_edge(g_clk) then
                conf_settings_wr_en     <= '0';
                conf_calculate          <= '0';
                conf_configure_ledcor   <= '0';
                
                case state is
                    
                    when INIT =>
                        state   <= SENDING_SETTINGS;
                    
                    when SENDING_SETTINGS =>
                        counter             <= counter+1;
                        conf_settings_wr_en <= '1';
                        case counter+1 is
                            when "0000000000"   =>  conf_settings_data  <= stdulv(HOR_LED_COUNT, 8);
                            when "0000000001"   =>  conf_settings_data  <= x"00";
                            when "0000000010"   =>  conf_settings_data  <= x"00";
                            when "0000000011"   =>  conf_settings_data  <= x"00";
                            when "0000000100"   =>  conf_settings_data  <= x"00";
                            when "0000000101"   =>  conf_settings_data  <= x"00";
                            when "0000000110"   =>  conf_settings_data  <= stdulv(VER_LED_COUNT, 8);
                            when "0000000111"   =>  conf_settings_data  <= x"00";
                            when "0000001000"   =>  conf_settings_data  <= x"00";
                            when "0000001001"   =>  conf_settings_data  <= x"00";
                            when "0000001010"   =>  conf_settings_data  <= x"00";
                            when "0000001011"   =>  conf_settings_data  <= x"00";
                            when "0000001100"   =>  conf_settings_data  <= stdulv(START_LED_NUM, 8);
                            when "0000001101"   =>  conf_settings_data  <= stdulv(FRAME_DELAY, 8);
                            when "0000001110"   =>  conf_settings_data  <= x"00";
                            when others         =>
                                                    if counter < 256+14 then
                                                        conf_settings_data  <= R_LOOKUP_TABLE(nat(counter-14));
                                                    elsif counter < 2*256+14 then
                                                        conf_settings_data  <= G_LOOKUP_TABLE(nat(counter-256-14));
                                                    elsif counter < 3*256+14 then
                                                        conf_settings_data  <= B_LOOKUP_TABLE(nat(counter-2*256-14));
                                                    else
                                                        state   <= CALCULATING;
                                                    end if;
                        end case;
                    
                    when CALCULATING =>
                        conf_calculate  <= '1';
                        state           <= CONF_LEDCOR_WAITING_FOR_BUSY;
                    
                    when CONF_LEDCOR_WAITING_FOR_BUSY =>
                        if conf_idle='0' then
                            state   <= CONF_LEDCOR_WAITING_FOR_IDLE;
                        end if;
                    
                    when CONF_LEDCOR_WAITING_FOR_IDLE =>
                        if conf_idle='1' then
                            state   <= CONF_LEDCOR_CONFIGURING_LED_CORRECTION;
                        end if;
                    
                    when CONF_LEDCOR_CONFIGURING_LED_CORRECTION =>
                        conf_configure_ledcor   <= '1';
                        state                   <= IDLE;
                    
                    when IDLE =>
                        null;
                    
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
            READING_SETTINGS
        );
        
        signal state    : state_type := INIT;
        signal counter  : unsigned(10 downto 0) := uns(1023, 11);
    begin
        
        fctrl_addr  <= SETTINGS_FLASH_ADDR;
        
        spi_flash_control_stim_proc : process(g_clk, g_rst)
        begin
            if g_rst='1' then
                state   <= INIT;
            elsif rising_edge(g_clk) then
                fctrl_rd_en <= '0';
                
                case state is
                    
                    when INIT =>
                        counter <= uns(1023, 11);
                        if pmod0_deb(0)='1' and pmod0_deb_q(0)='0' then
                            state   <= READING_SETTINGS;
                        end if;
                    
                    when READING_SETTINGS =>
                        -- (read 1025 bytes)
                        fctrl_rd_en <= '1';
                        if counter(counter'high)='1' then
                            state   <= INIT;
                        end if;
                        if fctrl_valid='1' then
                            counter <= counter-1;
                        end if;
                    
                end case;
                
                pmod0_deb_q <= pmod0_deb;
            end if;
        end process;
        
    end generate;
    
end rtl;

