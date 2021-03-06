--------------------------------------------------------------------------------
-- Engineer: Sebastian Huether
--
-- Create Date:   16:35:35 09/26/2016
-- Module Name:   BLACK_BORDER_DETECTOR_tb
-- Project Name:  BLACK_BORDER_DETECTOR
-- Tool versions: Xilinx ISE 14.7
-- Description:
--   
-- VHDL Test Bench Created by ISE for module: BLACK_BORDER_DETECTOR
--   
-- Dependencies:
-- 
-- Additional Comments:
--   
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
use work.help_funcs.all;
use work.video_profiles.all;

ENTITY BLACK_BORDER_DETECTOR_tb IS
    generic (
        R_BITS      : positive range 5 to 12 := 8;
        G_BITS      : positive range 6 to 12 := 8;
        B_BITS      : positive range 5 to 12 := 8;
        DIM_BITS    : positive range 9 to 16 := 11
    );
END BLACK_BORDER_DETECTOR_tb;

ARCHITECTURE behavior OF BLACK_BORDER_DETECTOR_tb IS
    
    -- Inputs
    signal CLK  : std_ulogic := '0';
    signal RST  : std_ulogic := '0';
    
    signal CFG_CLK      : std_ulogic := '0';
    signal CFG_ADDR     : std_ulogic_vector(3 downto 0) := (others => '0');
    signal CFG_WR_EN    : std_ulogic := '0';
    signal CFG_DATA     : std_ulogic_vector(7 downto 0) := (others => '0');
    
    signal FRAME_VSYNC      : std_ulogic := '0';
    signal FRAME_HSYNC      : std_ulogic := '0';
    signal FRAME_RGB_WR_EN  : std_ulogic := '0';
    signal FRAME_RGB        : std_ulogic_vector(R_BITS+G_BITS+B_BITS-1 downto 0) := (others => '0');
    
    -- Outputs
    signal BORDER_VALID     : std_ulogic;
    signal HOR_BORDER_SIZE  : std_ulogic_vector(DIM_BITS-1 downto 0);
    signal VER_BORDER_SIZE  : std_ulogic_vector(DIM_BITS-1 downto 0);
    
    -- clock period definitions
    constant G_CLK_PERIOD           : time := 40 ns; -- 25 MHz
    constant G_CLK_PERIOD_REAL      : real := real(G_CLK_PERIOD / 1 ps) / real(1 ns / 1 ps);
    constant CLK_IN_TO_CLK10_MULT   : natural := 2;
    constant CLK_IN_TO_CLK10_DIV    : natural := 5;
    
    signal g_clk            : std_ulogic := '0';
    signal g_rst            : std_ulogic := '0';
    signal pix_clk          : std_ulogic := '0';
    signal pix_clk_locked   : std_ulogic := '0';
    signal vsync            : std_ulogic := '0';
    signal hsync            : std_ulogic := '0';
    signal rgb_enable       : std_ulogic := '0';
    signal x, y             : std_ulogic_vector(DIM_BITS-1 downto 0) := (others => '0');
    
    constant VP         : video_profile_type := VIDEO_PROFILES(VIDEO_PROFILE_640_480p_60);
    constant PROFILE    :
        std_ulogic_vector(log2(VIDEO_PROFILE_COUNT)-1 downto 0) :=
        stdulv(VIDEO_PROFILE_640_480p_60, log2(VIDEO_PROFILE_COUNT));
    
    constant FRAME_WIDTH    : std_ulogic_vector(15 downto 0) := stdulv(VP.width, 16);
    constant FRAME_HEIGHT   : std_ulogic_vector(15 downto 0) := stdulv(VP.height, 16);
    
    type frame_type_type is (
        FULL_BLACK,
        FULL_WHITE,
        TOP_BLACK,
        BOTTOM_BLACK,
        LEFT_BLACK,
        RIGHT_BLACK,
        LETTERBOX_16_9,
        LETTERBOX_21_9
    );
    
    signal frame_type   : frame_type_type := FULL_BLACK;
    
    constant BORDER_HEIGHT_16_9 : natural := int(0.125*real(int(FRAME_HEIGHT)));
    constant BORDER_HEIGHT_21_9 : natural := int(1.5*real(int(FRAME_HEIGHT))/7.0);
    
BEGIN
    
    -- clock generation
    g_clk   <= not g_clk after G_CLK_PERIOD/2;
    
    CLK     <= pix_clk;
    CFG_CLK <= g_clk;
    
    BLACK_BORDER_DETECTOR_inst : entity work.BLACK_BORDER_DETECTOR
        generic map (
            R_BITS      => R_BITS,
            G_BITS      => G_BITS,
            B_BITS      => B_BITS,
            DIM_BITS    => DIM_BITS
        )
        port map (
            CLK => CLK,
            RST => RST,
            
            CFG_CLK     => CFG_CLK,
            CFG_ADDR    => CFG_ADDR,
            CFG_WR_EN   => CFG_WR_EN,
            CFG_DATA    => CFG_DATA,
            
            FRAME_VSYNC     => FRAME_VSYNC,
            FRAME_HSYNC     => FRAME_HSYNC,
            FRAME_RGB_WR_EN => FRAME_RGB_WR_EN,
            FRAME_RGB       => FRAME_RGB,
            
            BORDER_VALID    => BORDER_VALID,
            HOR_BORDER_SIZE => HOR_BORDER_SIZE,
            VER_BORDER_SIZE => VER_BORDER_SIZE
        );
    
    VIDEO_TIMING_GEN_inst : entity work.VIDEO_TIMING_GEN
        generic map (
            CLK_IN_PERIOD           => G_CLK_PERIOD_REAL,
            CLK_IN_TO_CLK10_MULT    => CLK_IN_TO_CLK10_MULT,
            CLK_IN_TO_CLK10_DIV     => CLK_IN_TO_CLK10_DIV,
            DIM_BITS                => DIM_BITS,
            MOCK_CLK_MAN            => false
        )
        port map (
            CLK_IN  => g_clk,
            RST     => '0',
            
            PROFILE => PROFILE,
            
            CLK_OUT         => pix_clk,
            CLK_OUT_LOCKED  => pix_clk_locked,
            
            POS_VSYNC   => vsync,
            POS_HSYNC   => hsync,
            RGB_ENABLE  => rgb_enable,
            RGB_X       => x,
            RGB_Y       => y
        );
    
    frame_gen_proc : process
        constant side_ratio : real := 1.0/3.0;
        variable x_frac : real;
        variable y_frac : real;
    begin
        wait until RST='0';
        wait until rising_edge(CLK) and pix_clk_locked='1';
        
        loop
            wait until rising_edge(pix_clk) and vsync='0';
            FRAME_VSYNC <= '0';
            
            while vsync='0' loop
                
                x_frac      := real(int(x))/real(int(FRAME_WIDTH));
                y_frac      := real(int(y))/real(int(FRAME_HEIGHT));
                FRAME_RGB   <= x"00_00_00";
                
                case frame_type is
                    
                    when FULL_BLACK =>
                        null;
                    
                    when FULL_WHITE =>
                        FRAME_RGB   <= x"FF_FF_FF";
                    
                    when TOP_BLACK =>
                        if y_frac>side_ratio then
                            FRAME_RGB   <= x"FF_FF_FF";
                        end if;
                    
                    when BOTTOM_BLACK =>
                        if y_frac<(1.0-side_ratio) then
                            FRAME_RGB   <= x"FF_FF_FF";
                        end if;
                    
                    when LEFT_BLACK =>
                        if x_frac>side_ratio then
                            FRAME_RGB   <= x"FF_FF_FF";
                        end if;
                    
                    when RIGHT_BLACK =>
                        if x_frac<(1.0-side_ratio) then
                            FRAME_RGB   <= x"FF_FF_FF";
                        end if;
                    
                    when LETTERBOX_16_9 =>
                        if y>BORDER_HEIGHT_16_9 and y<FRAME_HEIGHT-BORDER_HEIGHT_16_9 then
                            FRAME_RGB   <= x"FF_FF_FF";
                        end if;
                    
                    when LETTERBOX_21_9 =>
                        if y>BORDER_HEIGHT_21_9 and y<FRAME_HEIGHT-BORDER_HEIGHT_21_9 then
                            FRAME_RGB   <= x"FF_FF_FF";
                        end if;
                    
                end case;
                
                FRAME_RGB_WR_EN <= rgb_enable;
                FRAME_HSYNC     <= hsync;
                wait until rising_edge(pix_clk);
                
            end loop;
            
            FRAME_VSYNC <= '1';
            
        end loop;
    end process;
    
    -- Stimulus process
    stim_proc: process
        
        type cfg_type is record
            enable              : std_ulogic;
            threshold           : std_ulogic_vector(7 downto 0);
            consistent_frames   : std_ulogic_vector(7 downto 0);
            inconsistent_frames : std_ulogic_vector(7 downto 0);
            remove_bias         : std_ulogic_vector(7 downto 0);
            scan_width          : std_ulogic_vector(15 downto 0);
            scan_height         : std_ulogic_vector(15 downto 0);
            frame_width         : std_ulogic_vector(15 downto 0);
            frame_height        : std_ulogic_vector(15 downto 0);
        end record;
        
        variable cfg    : cfg_type;
        
        procedure write_config (cfg : in cfg_type) is
        begin
            CFG_WR_EN   <= '1';
            RST         <= '1';
            for settings_i in 0 to 12 loop
                CFG_ADDR    <= stdulv(settings_i, 4);
                case settings_i is
                    when 0      =>  CFG_DATA    <= "0000000" & cfg.enable;
                    when 1      =>  CFG_DATA    <= cfg.threshold;
                    when 2      =>  CFG_DATA    <= cfg.consistent_frames;
                    when 3      =>  CFG_DATA    <= cfg.inconsistent_frames;
                    when 4      =>  CFG_DATA    <= cfg.remove_bias;
                    when 5      =>  CFG_DATA    <= cfg.scan_width  (15 downto 8);
                    when 6      =>  CFG_DATA    <= cfg.scan_width  ( 7 downto 0);
                    when 7      =>  CFG_DATA    <= cfg.scan_height (15 downto 8);
                    when 8      =>  CFG_DATA    <= cfg.scan_height ( 7 downto 0);
                    when 9      =>  CFG_DATA    <= cfg.frame_width (15 downto 8);
                    when 10     =>  CFG_DATA    <= cfg.frame_width ( 7 downto 0);
                    when 11     =>  CFG_DATA    <= cfg.frame_height(15 downto 8);
                    when 12     =>  CFG_DATA    <= cfg.frame_height( 7 downto 0);
                end case;
                wait until rising_edge(CFG_CLK);
            end loop;
            CFG_WR_EN   <= '0';
            RST         <= '0';
        end procedure;
        
        procedure wait_frames(count : positive) is
        begin
            for frame_i in 1 to count loop
                wait until rising_edge(CLK) and FRAME_VSYNC='0';
                wait until rising_edge(CLK) and FRAME_VSYNC='1';
            end loop;
        end procedure;
        
        procedure test(
            ft          : frame_type_type;
            test_i      : natural;
            test_title  : string;
            hor_size    : natural;
            ver_size    : natural
        ) is
            constant expect_change  :
                boolean :=
                int(HOR_BORDER_SIZE)/=hor_size or
                int(VER_BORDER_SIZE)/=ver_size;
        begin
            report "Starting test " & natural'image(test_i) & ": " & test_title;
            frame_type  <= ft;
            
            wait_frames(1);
            
            if expect_change then
                assert BORDER_VALID='0'
                    report "Border is valid too long"
                    severity FAILURE;
            end if;
            
            wait_frames(2);
            
            assert BORDER_VALID='1'
                report "Border was not detected"
                severity FAILURE;
            
            assert int(HOR_BORDER_SIZE)=hor_size
                report "Wrong HOR_BORDER_SIZE, expected: " &
                    natural'image(hor_size) & ", got " &
                    natural'image(int(HOR_BORDER_SIZE))
                severity FAILURE;
            assert int(VER_BORDER_SIZE)=ver_size
                report "Wrong VER_BORDER_SIZE" &
                    natural'image(ver_size) & ", got " &
                    natural'image(int(VER_BORDER_SIZE))
                severity FAILURE;
            
            wait for 10 us;
            wait until rising_edge(CLK);
        end procedure;
        
    begin
        -- hold reset state for 100 ns.
        g_rst   <= '1';
        wait for 100 ns;
        
        cfg := (
            enable              => '1',
            threshold           => stdulv( 20,  8),
            consistent_frames   => stdulv(  2,  8),
            inconsistent_frames => stdulv(  1,  8),
            remove_bias         => stdulv(  2,  8),
            scan_width          => stdulv(120, 16),
            scan_height         => stdulv(120, 16),
            frame_width         => FRAME_WIDTH,
            frame_height        => FRAME_HEIGHT
        );
        write_config(cfg);
        
        g_rst   <= '0';
        wait until rising_edge(CLK) and pix_clk_locked='1' and FRAME_VSYNC='1';
        
        test(    FULL_BLACK, 0,        "Black frames", 122, 122);
        test(    FULL_WHITE, 1,        "White frames",   0,   0);
        test(     TOP_BLACK, 2,    "Top black frames",   0,   0);
        test(  BOTTOM_BLACK, 3, "Bottom black frames",   0,   0);
        test(    LEFT_BLACK, 4,   "Left black frames",   0,   0);
        test(   RIGHT_BLACK, 5,  "Right black frames",   0,   0);
        test(LETTERBOX_16_9, 6,         "16:9 frames",   0, BORDER_HEIGHT_16_9+2);
        test(LETTERBOX_21_9, 7,         "21:9 frames",   0, BORDER_HEIGHT_21_9+2);
        
        report "NONE. All tests successful, quitting"
            severity FAILURE;
    end process;
    
END;
