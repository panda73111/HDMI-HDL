----------------------------------------------------------------------------------
-- Engineer: Sebastian Huether
-- 
-- Create Date:    15:32:18 12/10/2014 
-- Module Name:    CONFIGURATOR - rtl 
-- Project Name:   pandaLight-Tests
-- Tool versions:  Xilinx ISE 14.7
-- Description: 
--
-- Additional Comments:
--  Maximum LED  width = 2 * (frame  width / 2^(FRAME_SIZE_BITS-7)) + 1
--  Maximum LED height = 2 * (frame height / 2^(FRAME_SIZE_BITS-7)) + 1
--  This limits the maximum LED size to an 8 bit value
--  
--  Horizontal scale = maximum LED  width / 256
--    Vertical scale = maximum LED height / 256
--  (between 0 and 1)
--  
--  Absolute LED  width = horizontal scale * scaled LED  width
--  Absolute LED height =   vertical scale * scaled LED height
--  (Therefore also limited to 8 bit)
--  
--  Values scaled by maximum LED width according to the above schema:
--    - horizontal LED width
--    - horizontal LED step
--    - horizontal LED offset
--    - vertical LED width
--    - vertical LED pad
--  Values scaled by maximum LED height according to the above schema:
--    - horizontal LED height
--    - horizontal LED pad
--    - vertical LED height
--    - vertical LED step
--    - vertical LED offset
--  
--  The scales are kept as fixed point numbers, 8 bit + 8 bit fraction
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.help_funcs.all;

entity CONFIGURATOR is
    generic (
        FRAME_SIZE_BITS         : natural := 11;
        -- dummy values
        HOR_LED_CNT             : std_ulogic_vector(7 downto 0) := stdulv( 16, 8);
        HOR_LED_SCALED_WIDTH    : std_ulogic_vector(7 downto 0) := stdulv( 96, 8); -- 720p: 60 pixel
        HOR_LED_SCALED_HEIGHT   : std_ulogic_vector(7 downto 0) := stdulv(226, 8); -- 720p: 80 pixel
        HOR_LED_SCALED_STEP     : std_ulogic_vector(7 downto 0) := stdulv(128, 8); -- 720p: 80 pixel
        HOR_LED_SCALED_PAD      : std_ulogic_vector(7 downto 0) := stdulv( 15, 8); -- 720p:  5 pixel
        HOR_LED_SCALED_OFFS     : std_ulogic_vector(7 downto 0) := stdulv( 16, 8); -- 720p: 10 pixel
        VER_LED_CNT             : std_ulogic_vector(7 downto 0) := stdulv(  9, 8);
        VER_LED_SCALED_WIDTH    : std_ulogic_vector(7 downto 0) := stdulv(128, 8); -- 720p: 80 pixel
        VER_LED_SCALED_HEIGHT   : std_ulogic_vector(7 downto 0) := stdulv(169, 8); -- 720p: 60 pixel
        VER_LED_SCALED_STEP     : std_ulogic_vector(7 downto 0) := stdulv(226, 8); -- 720p: 80 pixel
        VER_LED_SCALED_PAD      : std_ulogic_vector(7 downto 0) := stdulv(  8, 8); -- 720p:  5 pixel
        VER_LED_SCALED_OFFS     : std_ulogic_vector(7 downto 0) := stdulv( 29, 8)  -- 720p: 10 pixel
    );
    port (
        CLK : in std_ulogic;
        RST : in std_ulogic;
        
        CALCULATE       : in std_ulogic;
        CONFIGURE_LEDEX : in std_ulogic;
        
        FRAME_WIDTH     : in std_ulogic_vector(FRAME_SIZE_BITS-1 downto 0);
        FRAME_HEIGHT    : in std_ulogic_vector(FRAME_SIZE_BITS-1 downto 0);
        
        CFG_SEL_LEDEX   : out std_ulogic := '0';
        
        CFG_ADDR    : out std_ulogic_vector(3 downto 0) := "0000";
        CFG_WR_EN   : out std_ulogic := '0';
        CFG_DATA    : out std_ulogic_vector(7 downto 0) := x"00";
        
        CALCULATION_FINISHED    : out std_ulogic := '0'
    );
end CONFIGURATOR;

architecture rtl of CONFIGURATOR is
    
    type state_type is (
        WAITING_FOR_START,
        CALCULATING_LED_SCALE,
        CALCULATING_ABSOLUTE_HOR_VALUES,
        CALCULATING_WAIT_FOR_ABSOLUTE_HOR_VALUE,
        CALCULATING_ABSOLUTE_VER_VALUES,
        CALCULATING_WAIT_FOR_ABSOLUTE_VER_VALUE,
        CONFIGURING_LEDEX
    );
    
    type reg_type is record
        state                   : state_type;
        cfg_sel_ledex           : std_ulogic;
        cfg_addr                : std_ulogic_vector(3 downto 0);
        cfg_wr_en               : std_ulogic;
        cfg_data                : std_ulogic_vector(7 downto 0);
        multiplier_start        : std_ulogic;
        multiplier_multiplicand : std_ulogic_vector(15 downto 0);
        multiplier_multiplier   : std_ulogic_vector(15 downto 0);
        hor_scale               : std_ulogic_vector(15 downto 0);
        ver_scale               : std_ulogic_vector(15 downto 0);
        buf_p                   : unsigned(3 downto 0);
        buf_di                  : std_ulogic_vector(7 downto 0);
        buf_wr_en               : std_ulogic;
        calculation_finished    : std_ulogic;
    end record;
    
    constant reg_type_def   : reg_type := (
        state                   => WAITING_FOR_START,
        cfg_sel_ledex           => '0',
        cfg_addr                => "1111",
        cfg_wr_en               => '0',
        cfg_data                => x"00",
        multiplier_start        => '0',
        multiplier_multiplicand => (others => '0'),
        multiplier_multiplier   => (others => '0'),
        hor_scale               => x"0000",
        ver_scale               => x"0000",
        buf_p                   => "1111",
        buf_di                  => x"00",
        buf_wr_en               => '0',
        calculation_finished    => '0'
    );
    
    signal cur_reg, next_reg    : reg_type := reg_type_def;
    
    signal multiplier_valid     : std_ulogic := '0';
    signal multiplier_result    : std_ulogic_vector(31 downto 0);
    
    type led_profile_buf_type is
        array(0 to 15) of
        std_ulogic_vector(7 downto 0);
    
    signal led_profile_buf  : led_profile_buf_type;
    
    signal buf_do   : std_ulogic_vector(7 downto 0) := x"00";
    
begin
    
    CFG_SEL_LEDEX           <= cur_reg.cfg_sel_ledex;
    CFG_ADDR                <= cur_reg.cfg_addr;
    CFG_WR_EN               <= cur_reg.cfg_wr_en;
    CFG_DATA                <= cur_reg.cfg_data;
    CALCULATION_FINISHED    <= cur_reg.calculation_finished;
    
    ITERATIVE_MULTIPLIER_inst : entity work.ITERATIVE_MULTIPLIER
        generic map (
            WIDTH   => 16
        )
        port map (
            CLK => CLK,
            RST => RST,
            
            START   => cur_reg.multiplier_start,
            
            MULTIPLICAND    => cur_reg.multiplier_multiplicand,
            MULTIPLIER      => cur_reg.multiplier_multiplier,
            
            VALID   => multiplier_valid,
            RESULT  => multiplier_result
        );
    
    -- ensure block RAM usage
    led_profile_buf_proc : process(CLK)
        alias p     is next_reg.buf_p;
        alias di    is next_reg.buf_di;
        alias do    is buf_do;
        alias wr_en is next_reg.buf_wr_en;
    begin
        if rising_edge(CLK) then
            -- write first mode
            if wr_en='1' then
                led_profile_buf(nat(p))  <= di;
                do                  <= di;
            else
                do  <= led_profile_buf(nat(p));
            end if;
        end if;
    end process;
    
    stm_proc : process(RST, cur_reg, CALCULATE, CONFIGURE_LEDEX, FRAME_WIDTH, FRAME_HEIGHT,
        multiplier_valid, multiplier_result, buf_do)
        alias cr is cur_reg;
        variable r  : reg_type := reg_type_def;
    begin
        r                   := cr;
        r.cfg_sel_ledex     := '0';
        r.cfg_wr_en         := '0';
        r.multiplier_start  := '0';
        r.buf_wr_en         := '0';
        
        case cr.state is
            
            when WAITING_FOR_START =>
                r.multiplier_multiplicand   := (others => '0');
                r.multiplier_multiplier     := (others => '0');
                r.hor_scale                 := (others => '0');
                r.ver_scale                 := (others => '0');
                r.cfg_addr                  := (others => '1');
                if CALCULATE='1' then
                    r.state := CALCULATING_LED_SCALE;
                end if;
                if CONFIGURE_LEDEX='1' then
                    r.state := CONFIGURING_LEDEX;
                end if;
            
            when CALCULATING_LED_SCALE =>
                r.calculation_finished  := '0';
                -- dividing by 16: cut lower 4 bits
                -- multiplying by 2 and adding 1: left shift '1' by 1
                -- lower 8 bits of hor scale is the fraction part (2^-1 to 2^-8)
                r.hor_scale(7 downto  0)    := FRAME_WIDTH(10 downto 4) & '1';
                r.ver_scale(7 downto  0)    := FRAME_HEIGHT(10 downto 4) & '1';
                r.state                     := CALCULATING_ABSOLUTE_HOR_VALUES;
            
            when CALCULATING_ABSOLUTE_HOR_VALUES =>
                r.multiplier_multiplicand   := cr.hor_scale;
                r.buf_p                     := cr.buf_p+1;
                case cr.buf_p+1 is
                    when "0000" =>  r.multiplier_multiplier(7 downto 0) := HOR_LED_SCALED_WIDTH;
                    when "0001" =>  r.multiplier_multiplier(7 downto 0) := HOR_LED_SCALED_STEP;
                    when "0010" =>  r.multiplier_multiplier(7 downto 0) := HOR_LED_SCALED_OFFS;
                    when "0011" =>  r.multiplier_multiplier(7 downto 0) := VER_LED_SCALED_WIDTH;
                    when others =>  r.multiplier_multiplier(7 downto 0) := VER_LED_SCALED_PAD;
                end case;
                r.multiplier_start  := '1';
                r.state             := CALCULATING_WAIT_FOR_ABSOLUTE_HOR_VALUE;
            
            when CALCULATING_WAIT_FOR_ABSOLUTE_HOR_VALUE =>
                r.buf_wr_en := '1';
                r.buf_di    := multiplier_result(15 downto 8);
                if multiplier_valid='1' then
                    r.state := CALCULATING_ABSOLUTE_HOR_VALUES;
                    if cr.buf_p=4 then
                        r.state := CALCULATING_ABSOLUTE_VER_VALUES;
                    end if;
                end if;
            
            when CALCULATING_ABSOLUTE_VER_VALUES =>
                r.multiplier_multiplicand   := cr.ver_scale;
                r.buf_p                     := cr.buf_p+1;
                case cr.buf_p+1 is
                    when "0101" =>  r.multiplier_multiplier(7 downto 0) := VER_LED_SCALED_HEIGHT;
                    when "0110" =>  r.multiplier_multiplier(7 downto 0) := VER_LED_SCALED_STEP;
                    when "0111" =>  r.multiplier_multiplier(7 downto 0) := VER_LED_SCALED_OFFS;
                    when "1000" =>  r.multiplier_multiplier(7 downto 0) := HOR_LED_SCALED_HEIGHT;
                    when others =>  r.multiplier_multiplier(7 downto 0) := HOR_LED_SCALED_PAD;
                end case;
                r.multiplier_start  := '1';
                r.state             := CALCULATING_WAIT_FOR_ABSOLUTE_VER_VALUE;
            
            when CALCULATING_WAIT_FOR_ABSOLUTE_VER_VALUE =>
                r.buf_wr_en := '1';
                r.buf_di    := multiplier_result(15 downto 8);
                if multiplier_valid='1' then
                    r.state := CALCULATING_ABSOLUTE_VER_VALUES;
                    if cr.buf_p=9 then
                        r.calculation_finished  := '1';
                        r.state                 := WAITING_FOR_START;
                    end if;
                end if;
            
            when CONFIGURING_LEDEX =>
                r.cfg_sel_ledex := '1';
                r.cfg_wr_en     := '1';
                r.cfg_addr      := cr.cfg_addr+1;
                case cr.cfg_addr+1 is
                    when "0000" =>  r.cfg_data  := HOR_LED_CNT; r.buf_p := "0000";
                    when "0001" =>  r.cfg_data  := buf_do;      r.buf_p := "1000"; -- hor. LED width
                    when "0010" =>  r.cfg_data  := buf_do;      r.buf_p := "0001"; -- hor. LED height
                    when "0011" =>  r.cfg_data  := buf_do;      r.buf_p := "1001"; -- hor. LED step
                    when "0100" =>  r.cfg_data  := buf_do;      r.buf_p := "0010"; -- hor. LED pad
                    when "0101" =>  r.cfg_data  := buf_do;                         -- hor. LED offset
                    when "0110" =>  r.cfg_data  := VER_LED_CNT; r.buf_p := "0011";
                    when "0111" =>  r.cfg_data  := buf_do;      r.buf_p := "0101"; -- ver. LED width
                    when "1000" =>  r.cfg_data  := buf_do;      r.buf_p := "0110"; -- ver. LED height
                    when "1001" =>  r.cfg_data  := buf_do;      r.buf_p := "0100"; -- ver. LED step
                    when "1010" =>  r.cfg_data  := buf_do;      r.buf_p := "0111"; -- ver. LED pad
                    when "1011" =>  r.cfg_data  := buf_do;                         -- ver. LED offset
                    when "1100" =>  r.cfg_data  := "00000" & FRAME_WIDTH(10 downto 8);
                    when "1101" =>  r.cfg_data  := FRAME_WIDTH(7 downto 0);
                    when "1110" =>  r.cfg_data  := "00000" & FRAME_HEIGHT(10 downto 8);
                    when others =>  r.cfg_data  := FRAME_HEIGHT(7 downto 0);
                                    r.state     := WAITING_FOR_START;
                end case;
            
        end case;
        
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
            cur_reg     <= next_reg;
        end if;
    end process;
    
end rtl;