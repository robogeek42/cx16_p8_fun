%import syslib
%import textio
%import diskio
%import emudbg
%import keycode
%zeropage basicsafe

main {

	; standard (default) addresses for tile and map data
	; tiles start at $1F000, map starts at $1B000
	;
	; 16x16 tiles, 256 colour index (1byte) is 256bytes per tile.
	;  - $1F000 -> $1F7FF is charset (2048 bytes = 8 tiles worth)
	;  - $1F800 -> $1F9BF is free (448 bytes = 1 tile + a bit)
	; map starts at $1B000 2 bytes per location
	;  - $1B000 -> $1EFFF = 16k for map etc.
	;                       64x128 map: 64*128*2 = 16k
	; sprites $13000 -> $1AFFF = 32k space for 128 16x16 256c sprites

	; new map:
	; sprites $13000 -> $16FFF : 16k
	; map     $17000 -> $1AFFF : 16k
	; tiles   $1B000 -> $1EFFF : 16k

	; revised to keep standard layers from $1B000 untouched
	; sprites $13000 -> $14FFF : 8k
	; tiles   $15000 -> $16FFF : 8k
	; map     $17000 -> $1AFFF : 16k
	
	const ubyte spriteBaseBank = 1
	const uword spriteBaseAddr = $3000
	const ubyte tileBaseBank = 1
	const uword tileBaseAddr = $B000
	ubyte tileBase16_11 = 0
	const ubyte mapBaseBank = 1
	const uword mapBaseAddr = $7000
	ubyte mapBase16_9 = 0

	const ubyte palBaseBank = 1
	const uword palBaseAddr = $FA00

	ubyte key_bits = 0
	const ubyte KEY_BITS_W   = $01
	const ubyte KEY_MASK_W   = $FE
	const ubyte KEY_BITS_A   = $02
	const ubyte KEY_MASK_A   = $FD
	const ubyte KEY_BITS_S   = $04
	const ubyte KEY_MASK_S   = $FB
	const ubyte KEY_BITS_D   = $08
	const ubyte KEY_MASK_D   = $F7
	const ubyte KEY_BITS_X   = $10
	const ubyte KEY_MASK_X   = $EF

	const ubyte BOB_DIR_DN = 0
	const ubyte BOB_DIR_UP = 1
	const ubyte BOB_DIR_LT = 2
	const ubyte BOB_DIR_RT = 3

	const uword screen_width_pixels = 320
	const uword screen_height_pixels = 240
	const ubyte screen_half_width_pixels = 160
	const ubyte screen_half_height_pixels = 120

	const ubyte view_map_size = 32			; size of map enabled in L0_CONFIG (32x32)
	const uword view_map_sizew = 32			; size of map as word
	const uword view_map_size_bytesw = 2048;		; num bytes for view map

	; filled in at load_map() time
	ubyte map_width_tiles 			; overall map size (larger than that which is enabled)
	ubyte map_height_tiles 
	uword map_width_tilesw 			; overall map size as word
	uword map_height_tilesw 
	bool map_data_loaded = false
	
	; offset in tiles of the current 32x32 viewable section of the map
	;ubyte map_offset_tx = 0
	;ubyte map_offset_ty = 0
	; offset of the screen in pixels from the 32x32 tile section of the map
	; with a 32x32 map of 16x16 tiles, this is MAX 511 in either direction
	uword screen_offset_px = 0
	uword screen_offset_py = 0
	; position of the player relative to the screen in pixels
	uword bob_screen_pos_px = 0
	uword bob_screen_pos_py = 0
	uword bob_px = 0
	uword bob_py = 0

	ubyte[view_map_size] rows_loaded
	ubyte[view_map_size] cols_loaded
	ubyte low_row_index = 0
	ubyte low_col_index = 0
	ubyte hi_row_index = 0
	ubyte hi_col_index = 0

	; save vector for VERA regs
	ubyte[8] v
	bool main_exit = false

;============================================================
; SCREEN SETUP FOR 4BPP
;============================================================
	sub setup_screen() {
        tileBase16_11 = (tileBaseBank<<5) | (tileBaseAddr>>11)
		mapBase16_9 = (mapBaseBank<<7) | (mapBaseAddr>>9)
	
		save_vera()

        ; enable 320*240  8bpp tile-mode
        cx16.VERA_CTRL=0
        cx16.VERA_DC_VIDEO = (cx16.VERA_DC_VIDEO & %11001111) | %00010000      ; enable only layer 0
        cx16.VERA_DC_HSCALE = 64
        cx16.VERA_DC_VSCALE = 64
        ;cx16.VERA_L0_CONFIG = %01010010 ; map h/w (0,0) = 64x64, color depth (10) = 4bpp, 256c should be off to use pallete
        cx16.VERA_L0_CONFIG = %00000010 ; map h/w (0,0) = 32x32, color depth (10) = 4bpp, 256c off
        cx16.VERA_L0_MAPBASE = mapBase16_9
        cx16.VERA_L0_TILEBASE = tileBase16_11<<2 | %11 ; tile size 16x16
	}

;============================================================
; MAIN START
;============================================================
	sub start() {

		setup_screen()

		diskio.chdir("assets")
		load_tiles()

		; place bob in the centre of the screen
		bob_screen_pos_px = screen_width_pixels >> 1
		bob_screen_pos_py = screen_height_pixels >> 1

		load_sprites()

		load_map_raw()

		uword load_off_tx = map_width_tilesw >> 1
		load_off_tx -= (bob_screen_pos_px >>4)

		uword load_off_ty = map_height_tilesw >> 1
		load_off_ty -= (bob_screen_pos_py >>4)

		load_map_offset(load_off_tx, load_off_ty)

		bob_px = (load_off_tx << 4) + bob_screen_pos_px
		bob_py = (load_off_ty << 4) + bob_screen_pos_py
		bob_anim(0, 0)
		
        sys.set_irqd()
        uword old_keyhdl = cx16.KEYHDL
        cx16.KEYHDL = &keyboard_handler
        sys.clear_irqd()

		uword bob_anim_time = cbm.RDTIM16()
		const uword bob_anim_rate = 6 ; in jiffies

		;============================================================
		; GAME LOOP
		;============================================================

		const ubyte bob_speed=2
		ubyte bob_frame = 0
		ubyte bob_dir = 3
		do {
			sys.wait(1);
			bool update_bob = false

			if (key_bits & KEY_BITS_W) != 0 {
				bob_dir = BOB_DIR_UP
				if is_tile_land( bob_px >> 4, (bob_py - bob_speed) >> 4 ) and is_tile_land( (bob_px+15) >> 4, (bob_py - bob_speed) >> 4 ) 
				{
					; check if we have to move back into the centre
					if bob_screen_pos_py > screen_half_height_pixels {
						bob_screen_pos_py -= bob_speed
						bob_py -= bob_speed
						update_bob = true
					} else {
						; normally just scroll the screen keeping bob in the centre
						if can_scroll(bob_dir, bob_speed) {
							do_scroll(bob_dir, bob_speed)
							update_bob = true
						} else {
							; can't scroll? just move bob up the screen without scrolling
							if bob_py > bob_speed + 16 {
								bob_py -= bob_speed
								bob_screen_pos_py -= bob_speed
								update_bob = true
							}
						}
					}
				}
			} else
			if (key_bits & KEY_BITS_S) != 0 {
				bob_dir = BOB_DIR_DN
				if is_tile_land( bob_px >> 4, (bob_py + bob_speed + 15) >> 4 ) and is_tile_land( (bob_px+15) >> 4, (bob_py + bob_speed + 15) >> 4 )
				{
					; check if we have to move back into the centre
					if bob_screen_pos_py < screen_half_height_pixels {
						bob_screen_pos_py += bob_speed
						bob_py += bob_speed
						update_bob = true
					} else {
						; normally just scroll the screen keeping bob in the centre
						if can_scroll(bob_dir, bob_speed) {
							do_scroll(bob_dir, bob_speed)
							update_bob = true
						} else {
							; can't scroll? just move bob down the screen without scrolling
							if bob_py + 16 < (map_height_tilesw <<4) - bob_speed - 16 {
								bob_py += bob_speed
								bob_screen_pos_py += bob_speed
								update_bob = true
							}
						}
					}
				}
			} else
			if (key_bits & KEY_BITS_A) != 0 {
				bob_dir = BOB_DIR_LT
				if is_tile_land( (bob_px - bob_speed) >> 4, bob_py >> 4 ) and is_tile_land( (bob_px - bob_speed) >> 4, (bob_py+15) >> 4 )
				{
					; check if we have to move back into the centre
					if bob_screen_pos_px > screen_half_width_pixels {
						bob_screen_pos_px -= bob_speed
						bob_px -= bob_speed
						update_bob = true
					} else {
						; normally just scroll the screen keeping bob in the centre
						if can_scroll(bob_dir, bob_speed) {
							do_scroll(bob_dir, bob_speed)
							update_bob = true
						} else {
							; can't scroll? just move bob left without scrolling
							if bob_px > bob_speed + 16 {
								bob_px -= bob_speed
								bob_screen_pos_px -= bob_speed
								update_bob = true
							}
						}
					}
				}
			} else
			if (key_bits & KEY_BITS_D) != 0 {
				bob_dir = BOB_DIR_RT
				if is_tile_land( (bob_px + bob_speed + 15) >> 4, bob_py >> 4 ) and is_tile_land( (bob_px + bob_speed + 15) >> 4, (bob_py+15) >> 4 ) 
				{
					; check if we have to move back into the centre
					if bob_screen_pos_px < screen_half_width_pixels {
						bob_screen_pos_px += bob_speed
						bob_px += bob_speed
						update_bob = true
					} else {
						if can_scroll(bob_dir, bob_speed) {
							do_scroll(bob_dir, bob_speed)
							update_bob = true
						} else {
							; can't scroll? just move bob right without scrolling
							if bob_px + 16 < (map_width_tilesw <<4) - bob_speed - 16 {
								bob_px += bob_speed
								bob_screen_pos_px += bob_speed
								update_bob = true
							}
						}
					}
				}
			}
			if ((key_bits & KEY_BITS_X) != 0) {
				main_exit = true
			}

			if update_bob 
			{
				uword tm = cbm.RDTIM16()
				if (bob_anim_time < tm)
				{
					bob_frame = (bob_frame+1) %4
					bob_anim_time = tm + bob_anim_rate
				}
				bob_anim(bob_dir, bob_frame)
				emudbg.console_write(conv.str_uw(bob_px))
				emudbg.console_write(",")
				emudbg.console_write(conv.str_uw(bob_py))
				emudbg.console_write(" s ")
				emudbg.console_write(conv.str_uw(bob_screen_pos_px))
				emudbg.console_write(",")
				emudbg.console_write(conv.str_uw(bob_screen_pos_py))
				emudbg.console_write("    \n")
			}
		} until (main_exit == true)

        sys.set_irqd()
        cx16.KEYHDL = old_keyhdl
        sys.clear_irqd()
	}

	sub can_scroll(ubyte dir, ubyte bob_speed) -> bool
	{
		when dir {
			BOB_DIR_UP -> return can_scroll_up(bob_speed)
			BOB_DIR_DN -> return can_scroll_down(bob_speed)
			BOB_DIR_LT -> return can_scroll_left(bob_speed)
			BOB_DIR_RT -> return can_scroll_right(bob_speed)
		}
	}
	sub can_scroll_up(uword bob_speed) -> bool
	{
		if screen_pos_to_real_ty(0) > 0 {
			return true
		}
		return false
	}
	sub can_scroll_down(uword bob_speed) -> bool
	{
		ubyte endofscreen_tile = screen_pos_to_real_ty(screen_height_pixels + bob_speed)
		if endofscreen_tile+1 < map_height_tiles {
			return true
		}
		return false
	}
	sub can_scroll_left(uword bob_speed) -> bool
	{
		if screen_pos_to_real_tx(0) > 0 {
			return true
		}
		return false
	}
	sub can_scroll_right(uword bob_speed) -> bool
	{
		ubyte endofscreen_tile = screen_pos_to_real_tx(screen_width_pixels + bob_speed)
		if endofscreen_tile+1 < map_width_tiles {
			return true
		}
		return false
	}


	sub do_scroll(ubyte dir, ubyte bob_speed)
	{
		when dir {
			BOB_DIR_UP -> do_scroll_up(bob_speed)
			BOB_DIR_DN -> do_scroll_down(bob_speed)
			BOB_DIR_LT -> do_scroll_left(bob_speed)
			BOB_DIR_RT -> do_scroll_right(bob_speed)
		}
	}
	sub do_scroll_right(uword speed_px)
	{
		ubyte view_tx = screen_pos_to_view_tx(screen_width_pixels-1)
		ubyte real_tx = screen_pos_to_real_tx(screen_width_pixels-1)
		ubyte next_view_col = view_tx
		ubyte next_real_col = real_tx

		screen_offset_px += speed_px
		screen_offset_px &= $1FF
		update_vera_hscroll(screen_offset_px)
		next_view_col = (view_tx + 1) % view_map_size
		next_real_col = (real_tx + 1) % map_width_tiles

		; check col after the one at the right of the screen
		; make sure it contains the correct col from the original map
		; if not, load it

		if cols_loaded[next_view_col] != next_real_col {
			load_map_col(next_real_col, next_view_col)
		}

		bob_px += speed_px
	}

	sub do_scroll_down(uword speed_py)
	{
		ubyte view_ty = screen_pos_to_view_ty(screen_height_pixels-1)
		ubyte real_ty = screen_pos_to_real_ty(screen_height_pixels-1)
		ubyte next_view_row = view_ty
		ubyte next_real_row = real_ty

		screen_offset_py += speed_py
		screen_offset_py &= $1FF
		update_vera_vscroll(screen_offset_py)
		next_view_row = (view_ty + 1) % view_map_size
		next_real_row = (real_ty + 1) % map_height_tiles

		; check row after the one at the bottom of the screen
		; make sure it contains the correct row from the original map
		; if not, load it

		if rows_loaded[next_view_row] != next_real_row {
			load_map_row(next_real_row, next_view_row)
		}

		bob_py += speed_py
	}
	sub do_scroll_left(uword speed_px)
	{
		ubyte view_tx = screen_pos_to_view_tx(0)
		ubyte real_tx = screen_pos_to_real_tx(0)

		ubyte prev_view_col = view_tx
		ubyte prev_real_col = real_tx
	
		screen_offset_px -= speed_px
		screen_offset_px &= $1FF
		update_vera_hscroll(screen_offset_px)
		prev_view_col = (view_tx - 1) % view_map_size
		prev_real_col = (real_tx - 1) % map_width_tiles

		if cols_loaded[prev_view_col] != prev_real_col {
			load_map_col(prev_real_col, prev_view_col)
		}

		bob_px -= speed_px
	}
	sub do_scroll_up(uword speed_py)
	{
		ubyte view_ty = screen_pos_to_view_ty(0)
		ubyte real_ty = screen_pos_to_real_ty(0)

		ubyte prev_view_row = view_ty
		ubyte prev_real_row = real_ty

		screen_offset_py -= speed_py
		screen_offset_py &= $1FF
		update_vera_vscroll(screen_offset_py)
		prev_view_row = (view_ty - 1) % view_map_size
		prev_real_row = (real_ty - 1) % map_height_tiles

		if rows_loaded[prev_view_row] != prev_real_row {
			load_map_row(prev_real_row, prev_view_row)
		}

		bob_py -= speed_py
	}

;============================================================
; KEYBOARD HANDLER
;============================================================
    sub keyboard_handler(ubyte keynum) -> ubyte {
        ; NOTE: this handler routine expects the keynum in A and return value in A
        ;       which is thankfully how prog8 translates this subroutine's calling convention.
		ubyte keycode = keynum & $7F
        if keynum & $80 == 0 {
			when keycode {
				keycodes.KEYCODE_W -> key_bits |= KEY_BITS_W ; w - up
				keycodes.KEYCODE_S -> key_bits |= KEY_BITS_S ; s - down
				keycodes.KEYCODE_A -> key_bits |= KEY_BITS_A ; a - left
				keycodes.KEYCODE_D -> key_bits |= KEY_BITS_D ; d - right
				keycodes.KEYCODE_X -> key_bits |= KEY_BITS_X ; x - exit
			}
		}
        else {
			when keycode {
				keycodes.KEYCODE_W -> key_bits &= KEY_MASK_W ; w - up
				keycodes.KEYCODE_S -> key_bits &= KEY_MASK_S ; s - down
				keycodes.KEYCODE_A -> key_bits &= KEY_MASK_A ; a - left
				keycodes.KEYCODE_D -> key_bits &= KEY_MASK_D ; d - right
				keycodes.KEYCODE_X -> key_bits &= KEY_MASK_X ; x - exit
			}
		}

        if keynum==$6e {
            ; escape stops the program
			main_exit = true
        }
        return 0        ; By returning 0 (in A) we will eat this key event. Return the original keynum value to pass it through.
    }
;============================================================
; SAVE/RESTORE VERA REGISTERS
;============================================================
	sub save_vera() {
		v[0] = cx16.VERA_CTRL
		v[1] = cx16.VERA_DC_VIDEO
		v[2] = cx16.VERA_L0_CONFIG
		v[3] = cx16.VERA_L0_MAPBASE
		v[4] = cx16.VERA_L0_TILEBASE
		v[5] = cx16.VERA_L1_CONFIG
		v[6] = cx16.VERA_L1_MAPBASE
		v[7] = cx16.VERA_L1_TILEBASE
	}
	sub restore_vera() {
		cx16.VERA_CTRL = v[0]
		cx16.VERA_DC_VIDEO = v[1]
		cx16.VERA_L0_CONFIG = v[2]
		cx16.VERA_L0_MAPBASE = v[3]
		cx16.VERA_L0_TILEBASE = v[4]
		cx16.VERA_L1_CONFIG = v[5]
		cx16.VERA_L1_MAPBASE = v[6]
		cx16.VERA_L1_TILEBASE = v[7]
	}

;============================================================
; LOAD TILES, SPRITES
;============================================================
	sub load_tiles() {

		ubyte n
		bool ret
		uword tbaddr = tileBaseAddr ; tileBaseAddr is a constant
		str filename = " "*20

		; terrain tiles: 16x16 in 4bpp so size is 128b
		
		; basic terrain
		for n in 0 to 15 {
			gen_filename( filename, "tr", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, tileBaseBank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128
		}
		; terrain feature on grass
		for n in 0 to 14 {
			gen_filename( filename, "gtf", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, tileBaseBank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128
		}
		; terrain feature on desert
		for n in 0 to 14 {
			gen_filename( filename, "dtf", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, tileBaseBank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128
		}
		; terrain feature on mud
		for n in 0 to 14 {
			gen_filename( filename, "mtf", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, tileBaseBank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128
		}
		; terrain feature on snow
		for n in 0 to 14 {
			gen_filename( filename, "stf", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, tileBaseBank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128
		}

		; load the unified palette
		;   0 = terrain (tr 01->13)
		;   1 = terrain extras (tr 14-16)
		;   2 = facbob
		void diskio.vload_raw( "palette.bin", palBaseBank, palBaseAddr )

	}

	sub load_sprites() {
		; BOB tiles: 16x16 in 4bpp so size is 128b

		uword saddr = spriteBaseAddr
		
		; BOB sprites are stored as 4 frames each of UP DOWN LEFT RIGHT
		; will be simplified later to use mirrored versions
		ubyte n
		str filename = "?"*16
		bool ret
		for n in 0 to 15 {
			gen_filename( filename, "fb", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, spriteBaseBank, saddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			; next address
			saddr += 128
		}
	}

;============================================================
; Animate BOB sprite
;============================================================
	sub bob_anim(uword dir, uword frame)
	{
		; set the correct sprite to use for BOB
		uword saddr = spriteBaseAddr + 128 * ( (dir*4) + frame)

		ubyte spriteBase12_5 = lsb( saddr  >> 5)
		ubyte spriteBase16_13 = msb( saddr >> 5) | spriteBaseBank << 3
		
		const ubyte ZDEPTH = 3 ; In front of LAYER1
		const ubyte FLIP = 0 ; Not flipped or mirrored

		cx16.VERA_ADDR_L = $00 ; sprite attribute #0 (BOB sprite)
		cx16.VERA_ADDR_M = $FC
		cx16.VERA_ADDR_H = 1 | %00010000     ; bank=1, increment 1
		cx16.VERA_DATA0 = spriteBase12_5
		cx16.VERA_DATA0 = spriteBase16_13  ; mode is 0 = 4bpp
		cx16.VERA_DATA0 = lsb(bob_screen_pos_px) ; X
		cx16.VERA_DATA0 = msb(bob_screen_pos_px)
		cx16.VERA_DATA0 = lsb(bob_screen_pos_py) ; Y
		cx16.VERA_DATA0 = msb(bob_screen_pos_py)
		cx16.VERA_DATA0 = FLIP | (ZDEPTH<<2)
		cx16.VERA_DATA0 = %01010010 ; 16x16, use palette offset 2

		; turn on sprites
		cx16.VERA_DC_VIDEO |= %01000000
	}

;============================================================
; GENERATE FILENAME
;============================================================
	sub gen_filename(str filename, str prefix, str suffix, ubyte num) {
		uword strptr = filename
		str numstr = "    "
		str two_digits = "   "

		strptr += string.copy(prefix, strptr)
		numstr = conv.str_ub0(num)
		string.right(numstr, 2, two_digits)
		strptr += string.copy(two_digits, strptr)
		strptr += string.copy(suffix, strptr)
	}

;============================================================
; MAP LOADING and POSITION CALC FUNCTIONS
;============================================================

	sub load_map_raw() {
		; Load the raw map to CPU ram
		; CX16 has 512 KB of banked RAM 
		; a 64x64 map is 4k - a single (window into a) bank can contain 8k
		; use cx16.rambank() to switch banks 

		;void  diskio.load_raw("map64.dat", $A000)
		;void  diskio.load_raw("map64res.dat", $A000)
		;map_width_tiles = 64
		;map_height_tiles = 64
		;void  diskio.load_raw("m5res.dat", $A000) ; this map doesn't need resources on snow
		;map_width_tiles = 60
		;map_height_tiles = 60
		void  diskio.load_raw("m4mod.dat", $A000)
		map_width_tiles = 120
		map_height_tiles = 120

		map_width_tilesw = map_width_tiles as uword
		map_height_tilesw = map_height_tiles as uword
		map_data_loaded = true
		uword cpuptr 
		uword cpuoffset 

		; translate feature overlays into tiles
		for cpuoffset in 0 to map_width_tilesw*map_height_tilesw-1 {
			cpuptr = $A000 + (cpuoffset % $2000)
			ubyte terr = @(cpuptr) & $0F
			ubyte feat = @(cpuptr) >> 4
			cx16.rambank( lsb((cpuoffset / $2000) + 1) )
			ubyte t = 0
			if terr > 0 and terr <= 12 {
				t = ((terr + 3) >> 2) - 1
			}
			if terr == 15 {
				t = 3
			}
			if feat > 0 {
				@(cpuptr) = 16 + t * 15 + feat - 1
			}
		}
	}

	sub get_palette(ubyte val) -> ubyte {
		ubyte pal = 0
		if val > 12 and val < 16 pal = 1 ; pavement, lake and snow is palette=1
		if val >= 16+(3*15) pal = 1 ; snow with feature is also palette 1
		return pal
	}

	sub load_map_offset(uword src_col, uword src_row) {
		if map_data_loaded==false {
			load_map_raw()
		}

		; load the screen portion of the map with map data
		ubyte x
		ubyte y
		uword cpuoffset = src_row * map_width_tilesw + src_col

		; VERA load 
		cx16.VERA_ADDR_L =lsb(mapBaseAddr) 
		cx16.VERA_ADDR_M = msb(mapBaseAddr)
		cx16.VERA_ADDR_H = mapBaseBank | %00010000     ; bank=1, increment 1
		for y in 0 to view_map_size-1 {
			uword cpuptr = $A000 + (cpuoffset % $2000)
			for x in 0 to view_map_size-1 {
				ubyte paloff = get_palette( @(cpuptr) )

				cx16.rambank( lsb((cpuoffset / $2000) + 1) )
				cx16.VERA_DATA0 = @(cpuptr)
				cx16.VERA_DATA0 = 0 | paloff << 4
				cpuptr += 1
				
			}
			cpuoffset += map_width_tilesw
			rows_loaded[y] = (y + lsb(src_row)) % map_height_tiles
		}
		update_low_hi_row_index()
		for x in 0 to view_map_size-1 {
			cols_loaded[x] = (x + lsb(src_col)) % map_width_tiles
		}
		update_low_hi_col_index()
	}

	sub load_map_row(uword src_row, uword dest_row) {

		ubyte x
		uword mapOffset = (dest_row * view_map_sizew + 0)*2
		uword mapbaseptr = mapBaseAddr + mapOffset
		uword dc = 0
		; VERA load 
		cx16.VERA_ADDR_L =lsb(mapbaseptr) 
		cx16.VERA_ADDR_M = msb(mapbaseptr)
		cx16.VERA_ADDR_H = mapBaseBank | %00010000     ; bank=1, increment 1
		for x in 0 to view_map_size-1 {
			uword cpuoffset = src_row * map_width_tilesw + cols_loaded[lsb(dc)]
			uword cpuptr = $A000 + (cpuoffset % $2000)
			cx16.rambank( lsb((cpuoffset / $2000) + 1) )

			ubyte paloff = get_palette( @(cpuptr) )

			cx16.VERA_DATA0 = @(cpuptr)
			cx16.VERA_DATA0 = 0 | paloff << 4

			; keep track of the map offset, even though it will be auto incremented
			mapOffset+=2

			; Check if the VERA address is going outside of the View tile map (32x32 tiles)
			if mapOffset > view_map_size_bytesw {
				; if so, wrap the address
				mapOffset -= view_map_size_bytesw
				mapbaseptr = mapBaseAddr + mapOffset
				cx16.VERA_ADDR_L =lsb(mapbaseptr) 
				cx16.VERA_ADDR_M = msb(mapbaseptr)
				cx16.VERA_ADDR_H = mapBaseBank | %00010000     ; bank=1, increment 1
			}

			; increment the column index so we can look up what column needs to be read from main map
			dc = (dc+1) % view_map_size
		}
		
		rows_loaded[lsb(dest_row)] = lsb(src_row)
		update_low_hi_row_index()
	}
	sub load_map_col(uword src_col, uword dest_col) {
		uword mapbaseptr =  0
		uword dr = 0
		; VERA load 
		ubyte y
		for y in 0 to view_map_size-1 {
			uword cpuoffset = rows_loaded[lsb(dr)] * map_width_tilesw + src_col
			uword cpuptr = $A000 + (cpuoffset % $2000)
			cx16.rambank( lsb((cpuoffset / $2000) + 1) )
			uword mapOffset = (dr * view_map_sizew + dest_col)*2
			if mapOffset > view_map_size_bytesw {
				mapOffset -= view_map_size_bytesw
			}
			mapbaseptr = mapBaseAddr + mapOffset

			ubyte paloff = get_palette( @(cpuptr) )

			; slow, but write the exact address each time with a inc-1 to be able to write the 2 byte field
			cx16.VERA_ADDR_L =lsb(mapbaseptr) 
			cx16.VERA_ADDR_M = msb(mapbaseptr)
			cx16.VERA_ADDR_H = mapBaseBank | %00010000     ; bank=1, increment 1
			cx16.VERA_DATA0 = @(cpuptr)
			cx16.VERA_DATA0 = 0 | paloff << 4
			dr = (dr+1) % view_map_size
		}

		cols_loaded[lsb(dest_col)] = lsb(src_col)
		update_low_hi_col_index()
	}

	sub verify() -> bool {
		; check tiles in view against tiles that should be loaded
		bool ret = true
		
		cx16.VERA_ADDR_L =lsb(mapBaseAddr) 
		cx16.VERA_ADDR_M = msb(mapBaseAddr)
		cx16.VERA_ADDR_H = mapBaseBank | %00010000     ; bank=1, increment 1

		ubyte x
		ubyte y
		for y in 0 to view_map_size-1 {
			for x in 0 to view_map_size-1 {
				ubyte A = cx16.VERA_DATA0
				ubyte B = cx16.VERA_DATA0
				uword cpuoffset = cols_loaded[x] + rows_loaded[y] * map_width_tilesw
				uword cpuptr = $A000 + (cpuoffset % $2000)
				cx16.rambank( lsb((cpuoffset / $2000) + 1) )
				ubyte C = @(cpuptr)
				if A != C or B != 0 {
					emudbg.console_write("e (")
					emudbg.console_write(conv.str_ub(x))
					emudbg.console_write(",")
					emudbg.console_write(conv.str_ub(y))
					emudbg.console_write(") (")
					emudbg.console_write(conv.str_ub(cols_loaded[x]))
					emudbg.console_write(",")
					emudbg.console_write(conv.str_ub(rows_loaded[y]))
					emudbg.console_write(") ")
					emudbg.console_write(conv.str_ubhex(B))
					emudbg.console_write(conv.str_ubhex(A))
					emudbg.console_write("-")
					emudbg.console_write(conv.str_ubhex(C))
					emudbg.console_write(" : ")
					;return false
				}
			}
		}
		return ret
	}

	sub update_low_hi_row_index() {
		ubyte low_row_value = 255
		ubyte hi_row_value = 0

		ubyte i
		; TODO make this more efficient - shouldn't be a loop
		for i in 0 to (view_map_size-1) {
			if rows_loaded[i] < low_row_value {
				low_row_value = rows_loaded[i]
				low_row_index = i
			}
			if rows_loaded[i] > hi_row_value {
				hi_row_value = rows_loaded[i]
				hi_row_index = i
			}
		}
	}
	sub update_low_hi_col_index() {
		ubyte low_col_value = 255
		ubyte hi_col_value = 0
		ubyte i
		; TODO make this more efficient - shouldn't be a loop
		for i in 0 to view_map_size-1 {
			if cols_loaded[i] < low_col_value {
				low_col_value = cols_loaded[i]
				low_col_index = i
			}
			if cols_loaded[i] > hi_col_value {
				hi_col_value = cols_loaded[i]
				hi_col_index = i
			}
		}
	}

	sub view_to_real_tx(ubyte view_tx) -> ubyte {
		; look up real tile number using the row/col loaded arrays
		return cols_loaded[lsb(view_tx)]
	}
	sub view_to_real_ty(ubyte view_ty) -> ubyte {
		; look up real tile number using the row/col loaded arrays
		return rows_loaded[lsb(view_ty)]
	}
	sub real_to_view_tx(ubyte real_tx) -> ubyte {
		ubyte view_tx = 255 ; not in view
		if real_tx >= cols_loaded[low_col_index] and real_tx <= cols_loaded[hi_col_index] {
			; in view
			ubyte i 
			; TODO make this more efficient - shouldn't be a loop
			for i in 0 to view_map_size-1 {
				if cols_loaded[i] == real_tx {
					view_tx = i
					break
				}
			}
		}
		return view_tx
	}
	sub real_to_view_ty(ubyte real_ty) -> ubyte {
		ubyte view_ty = 255 ; not in view
		if real_ty >= rows_loaded[low_row_index] and real_ty <= rows_loaded[hi_row_index] {
			; in view
			ubyte i 
			; TODO make this more efficient - shouldn't be a loop
			for i in 0 to view_map_size-1 {
				if rows_loaded[i] == real_ty {
					view_ty = i
					break
				}
			}
		}
		return view_ty
	}

	sub screen_pos_to_view_tx(uword screen_px) -> ubyte {
		ubyte view_tx
		uword view_px = screen_offset_px + screen_px
		view_tx = lsb(view_px >> 4)
		view_tx %= view_map_size
		return view_tx
	}
	sub screen_pos_to_view_ty(uword screen_py) -> ubyte {
		ubyte view_ty
		uword view_py = screen_offset_py + screen_py 
		view_ty = lsb(view_py >> 4)
		view_ty %= view_map_size
		return view_ty
	}
	sub screen_pos_to_real_tx(uword screen_px) -> ubyte {
		ubyte real_tx
		ubyte view_tx = screen_pos_to_view_tx(screen_px)
		real_tx = cols_loaded[view_tx]
		return real_tx
	}
	sub screen_pos_to_real_ty(uword screen_py) -> ubyte {
		ubyte real_ty
		ubyte view_ty = screen_pos_to_view_ty(screen_py)
		real_ty = rows_loaded[view_ty]
		return real_ty
	}

	sub update_vera_vscroll(uword val) {
		val &= $FFF 		; 12 bit register
		cx16.VERA_L0_VSCROLL_L = lsb(val)
		cx16.VERA_L0_VSCROLL_H = msb(val)
	}
	sub update_vera_hscroll(uword val) {
		val &= $FFF 		; 12 bit register
		cx16.VERA_L0_HSCROLL_L = lsb(val)
		cx16.VERA_L0_HSCROLL_H = msb(val)
	}

;============================================================
; Tile checking
;============================================================

	sub is_tile_land(uword tx, uword ty) -> bool
	{
		uword cpuoffset = ty * map_width_tilesw + tx
		uword cpuptr = $A000 + (cpuoffset % $2000)
		cx16.rambank( lsb((cpuoffset / $2000) + 1) )
		if @(cpuptr) > 0 and @(cpuptr) <16 and @(cpuptr) != 14 return true
		return false
	}

;============================================================
; END OF main()

}
