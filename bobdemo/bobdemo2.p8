%import syslib
%import textio
%import diskio
%import emudbg
%import keycode
%zeropage basicsafe

main {

	; VERA memory map (Video RAM):
	; map0        $13000 -> $137FF : 32x32 * 2 bytes is 2k
	; map1        $13800 -> $13FFF : 32x32 * 2 bytes is 2k
	; sprites     $14000 -> $14FFF : 4k (bob takes 3k (24 sprites), + 4 cursor sprites)
	; tiles map0  $15000 -> $157FF : 2k (16 ground tiles, no edges) 
	; tiles map1  $15800 -> $1EFFF : 38k

	const ubyte map0BaseBank = 1
	const uword map0BaseAddr = $3000
	const ubyte map1BaseBank = 1
	const uword map1BaseAddr = $3800

	const ubyte spriteBaseBank = 1
	const uword spriteBaseAddr = $4000

	const ubyte tile0BaseBank = 1
	const uword tile0BaseAddr = $5000
	const ubyte tile1BaseBank = 1
	const uword tile1BaseAddr = $5800

	; this is always $1FA00 by design, 512 bytes (256 colours)
	const ubyte palBaseBank = 1
	const uword palBaseAddr = $FA00
	; sprite data is $1FC00 to $1FFFF, 1k = 128 sprites, 8bytes each

	; CPU Memory map
	const uword bankedRAM = $A000   ; 8k window into banked memory
	const ubyte map0rambank  = 1		; 16k for 128x128 so 2 banks
	const ubyte map1rambank  = 3		; 16k for 128x128 so 2 banks

	ubyte key_bits0 = 0
	const ubyte KEY_BITS_W   = $01
	const ubyte KEY_MASK_W   = $FE
	const ubyte KEY_BITS_A   = $02
	const ubyte KEY_MASK_A   = $FD
	const ubyte KEY_BITS_S   = $04
	const ubyte KEY_MASK_S   = $FB
	const ubyte KEY_BITS_D   = $08
	const ubyte KEY_MASK_D   = $F7
	const ubyte KEY_BITS_UPA   = $10
	const ubyte KEY_MASK_UPA   = $EF
	const ubyte KEY_BITS_RIGHTA   = $20
	const ubyte KEY_MASK_RIGHTA   = $DF
	const ubyte KEY_BITS_DOWNA   = $40
	const ubyte KEY_MASK_DOWNA   = $BF
	const ubyte KEY_BITS_LEFTA   = $80
	const ubyte KEY_MASK_LEFTA   = $7F

	ubyte key_bits1 = 0
	const ubyte KEY_BITS_X   = $01
	const ubyte KEY_MASK_X   = $FE

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
	const uword view_map_size_pixelsw = 512			; size in pixels of map enabled in L0_CONFIG (32x32)
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
	; position of the cursor in world
	ubyte cursor_tx = 0
	ubyte cursor_ty = 0

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
		ubyte tile0Base16_11 = (tile0BaseBank<<5) | (tile0BaseAddr>>11)
		ubyte tile1Base16_11 = (tile1BaseBank<<5) | (tile1BaseAddr>>11)
		ubyte map0Base16_9 = (map0BaseBank<<7) | (map0BaseAddr>>9)
		ubyte map1Base16_9 = (map1BaseBank<<7) | (map1BaseAddr>>9)
	
		save_vera()

        ; enable 320*240  8bpp tile-mode
        cx16.VERA_CTRL=0
        cx16.VERA_DC_VIDEO = (cx16.VERA_DC_VIDEO & %11001111) | %00110000      ; enable both layers
        cx16.VERA_DC_HSCALE = 64
        cx16.VERA_DC_VSCALE = 64

        cx16.VERA_L0_CONFIG = %00000010 ; map h/w (0,0) = 32x32, color depth (10) = 4bpp, 256c off
        cx16.VERA_L0_MAPBASE = map0Base16_9
        cx16.VERA_L0_TILEBASE = tile0Base16_11<<2 | %11 ; tile size 16x16

        cx16.VERA_L1_CONFIG = %00000010 ; map h/w (0,0) = 32x32, color depth (10) = 4bpp, 256c off
        cx16.VERA_L1_MAPBASE = map1Base16_9
        cx16.VERA_L1_TILEBASE = tile1Base16_11<<2 | %11 ; tile size 16x16
	}

;============================================================
; MAIN START
;============================================================
	sub start() {

		setup_screen()

		diskio.chdir("assets2")
		load_tiles()

		load_map_raw()

		; place bob in the centre of the screen
		bob_screen_pos_px = screen_width_pixels >> 1
		bob_screen_pos_py = screen_height_pixels >> 1
		cursor_tx = map_width_tiles >> 1
		cursor_ty = 1 + map_height_tiles >> 1

		load_sprites()


		uword load_off_tx = map_width_tilesw >> 1
		load_off_tx -= (bob_screen_pos_px >>4)

		uword load_off_ty = map_height_tilesw >> 1
		load_off_ty -= (bob_screen_pos_py >>4)

		init_machines()

		; test loop1
		add_belt(2,1, 54,55)
		add_belt(3,1, 55,55)
		add_belt(3,1, 56,55)
		add_belt(3,2, 57,55)
		add_belt(0,2, 57,56)
		add_belt(0,3, 57,57)
		add_belt(1,3, 56,57)
		add_belt(1,3, 55,57)
		add_belt(1,0, 54,57)
		add_belt(2,0, 54,56)

		; test loop 2
		add_belt(1,2, 64,55)
		add_belt(1,3, 65,55)
		add_belt(1,3, 66,55)
		add_belt(2,3, 67,55)
		add_belt(2,0, 67,56)
		add_belt(3,0, 67,57)
		add_belt(3,1, 66,57)
		add_belt(3,1, 65,57)
		add_belt(0,1, 64,57)
		add_belt(0,2, 64,56)

		add_machine(1,0, 56,62)
		add_machine(2,1, 58,62)
		add_machine(3,2, 60,62)

		load_map_offset(load_off_tx, load_off_ty)

		bob_px = (load_off_tx << 4) + bob_screen_pos_px
		bob_py = (load_off_ty << 4) + bob_screen_pos_py
		bob_anim(0, 0)
		show_cursor(0)
	
        sys.set_irqd()
        uword old_keyhdl = cx16.KEYHDL
        cx16.KEYHDL = &keyboard_handler
        sys.clear_irqd()

		uword bob_anim_time = cbm.RDTIM16()
		const uword bob_anim_rate = 6 ; in jiffies

		const uword key_delay = 8
		uword key_time = cbm.RDTIM16() + key_delay

		uword belt_anim_time = cbm.RDTIM16()
		const uword belt_anim_rate = 6 ; in jiffies
		cycle_belt_palette()

		uword mach_anim_time = cbm.RDTIM16()
		const uword mach_anim_rate = 8 ; in jiffies
		cycle_mach_palette()


		;============================================================
		; GAME LOOP
		;============================================================

		const ubyte bob_speed=2
		ubyte bob_frame = 0
		ubyte bob_dir = 3
		do {
			sys.wait(1);
			bool update_bob = false

			if (key_bits0 & KEY_BITS_W) != 0 {
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
			if (key_bits0 & KEY_BITS_S) != 0 {
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
			if (key_bits0 & KEY_BITS_A) != 0 {
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
			if (key_bits0 & KEY_BITS_D) != 0 {
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

			if (key_bits0 & $F0) !=0 and key_time < cbm.RDTIM16() 
			{
				key_time = cbm.RDTIM16() + key_delay
				if (key_bits0 & KEY_BITS_UPA) != 0 and cursor_ty > 0
				{
					cursor_ty -= 1
				}
				if (key_bits0 & KEY_BITS_DOWNA) != 0 and cursor_ty < map_height_tiles - 1
				{
					cursor_ty += 1
				}
				if (key_bits0 & KEY_BITS_RIGHTA) != 0 and cursor_tx < map_width_tiles - 1
				{
					cursor_tx += 1
				}
				if (key_bits0 & KEY_BITS_LEFTA) != 0 and cursor_tx > 0
				{
					cursor_tx -= 1
				}
				show_cursor(0)
			}

			if ((key_bits1 & KEY_BITS_X) != 0) {
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
;				emudbg.console_write(conv.str_uw(bob_px))
;				emudbg.console_write(",")
;				emudbg.console_write(conv.str_uw(bob_py))
;				emudbg.console_write(" s ")
;				emudbg.console_write(conv.str_uw(bob_screen_pos_px))
;				emudbg.console_write(",")
;				emudbg.console_write(conv.str_uw(bob_screen_pos_py))
;				emudbg.console_write(" c ")
;				emudbg.console_write(conv.str_uw(cursor_tx))
;				emudbg.console_write(",")
;				emudbg.console_write(conv.str_uw(cursor_ty))
;				emudbg.console_write("    \n")
				show_cursor(0)
			}

			if belt_anim_time < cbm.RDTIM16() 
			{
				belt_anim_time = cbm.RDTIM16() + belt_anim_rate
				cycle_belt_palette()
			}
			if mach_anim_time < cbm.RDTIM16() 
			{
				mach_anim_time = cbm.RDTIM16() + mach_anim_rate
				cycle_mach_palette()
				cycle_miner_palette()
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
		show_cursor(0)
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
				keycodes.KEYCODE_W -> key_bits0 |= KEY_BITS_W ; w - up
				keycodes.KEYCODE_S -> key_bits0 |= KEY_BITS_S ; s - down
				keycodes.KEYCODE_A -> key_bits0 |= KEY_BITS_A ; a - left
				keycodes.KEYCODE_D -> key_bits0 |= KEY_BITS_D ; d - right
				keycodes.KEYCODE_UPARROW    -> key_bits0 |= KEY_BITS_UPA ; w - up
				keycodes.KEYCODE_DOWNARROW  -> key_bits0 |= KEY_BITS_DOWNA ; s - down
				keycodes.KEYCODE_LEFTARROW  -> key_bits0 |= KEY_BITS_LEFTA ; a - left
				keycodes.KEYCODE_RIGHTARROW -> key_bits0 |= KEY_BITS_RIGHTA ; d - right

				keycodes.KEYCODE_X -> key_bits1 |= KEY_BITS_X ; x - exit
			}
		}
        else {
			when keycode {
				keycodes.KEYCODE_W -> key_bits0 &= KEY_MASK_W ; w - up
				keycodes.KEYCODE_S -> key_bits0 &= KEY_MASK_S ; s - down
				keycodes.KEYCODE_A -> key_bits0 &= KEY_MASK_A ; a - left
				keycodes.KEYCODE_D -> key_bits0 &= KEY_MASK_D ; d - right
				keycodes.KEYCODE_UPARROW    -> key_bits0 &= KEY_MASK_UPA ; w - up
				keycodes.KEYCODE_DOWNARROW  -> key_bits0 &= KEY_MASK_DOWNA ; s - down
				keycodes.KEYCODE_LEFTARROW  -> key_bits0 &= KEY_MASK_LEFTA ; a - left
				keycodes.KEYCODE_RIGHTARROW -> key_bits0 &= KEY_MASK_RIGHTA ; d - right

				keycodes.KEYCODE_X -> key_bits1 &= KEY_MASK_X ; x - exit
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

ubyte tiles_feature_start
ubyte tiles_belts_start
ubyte tiles_bbelts_start
ubyte tiles_machine_start 
ubyte tiles_machine_miner
ubyte tiles_machine_furnace
ubyte tiles_machine_assembler

	sub load_tiles() {

		ubyte n
		bool ret
		uword tbaddr = tile0BaseAddr ; tile0BaseAddr is a constant
		ubyte bank = tile0BaseBank
		str filename = " "*20

		; terrain tiles: 16x16 in 4bpp so size is 128b
		
		; 16 + 3*15 = 61 tiles in tile set 1 so < 8k at 4bpp

		; basic terrain
		for n in 0 to 15 {
			gen_filename( filename, "tr", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, bank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128
		}

		; second tileset

		tbaddr = tile1BaseAddr 
		bank = tile1BaseBank
		ubyte id = 0

		; blank
		filename = "blank.bin"
		ret =  diskio.vload_raw(filename, bank, tbaddr)
		if ret == false {
			restore_vera()
			txt.print("error loading ")
			txt.print( filename )
			return
		}
		tbaddr += 128 
		id++

		tiles_feature_start = id
		; terrain features
		for n in 0 to 14 {
			gen_filename( filename, "tf", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, bank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128 
			id++
		}

		tiles_belts_start = id
		; belts
		for n in 0 to 3 {
			gen_filename( filename, "belt", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, bank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128 
			id++
		}
		tiles_bbelts_start = id
		; bendy belts
		for n in 0 to 7 {
			gen_filename( filename, "bbelt", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, bank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128 
			id++
		}

		tiles_machine_furnace = id
		for n in 0 to 3 {
			gen_filename( filename, "fur", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, bank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128 
			id++
		}
		tiles_machine_assembler = id
		for n in 0 to 3 {
			gen_filename( filename, "asmb", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, bank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128 
			id++
		}
		tiles_machine_miner = id
		for n in 0 to 3 {
			gen_filename( filename, "miner", ".bin", n+1 )
			ret =  diskio.vload_raw(filename, bank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filename )
				return
			}
			tbaddr += 128 
			id++
		}

		; load the unified palette
		;   0 : CX16 default colours
		;   1 : Terrain (13 cols)
		;   2 : FAC Bob
		;   3 : Features (13 colours)
		;   4 : Belts
		;   5 : Assemblers and Furnaces

		void diskio.vload_raw( "palette.bin", palBaseBank, palBaseAddr )

	}
	const ubyte PAL_default  = 0
	const ubyte PAL_terrain  = 1
	const ubyte PAL_bob      = 2
	const ubyte PAL_features = 3
	const ubyte PAL_belt     = 4
	const ubyte PAL_fur_asmb = 5
	const ubyte PAL_miner    = 6

	sub load_sprites() {
		; BOB tiles: 16x16 in 4bpp so size is 128b

		uword saddr = spriteBaseAddr
		
		; BOB sprites are stored as 4 frames each of UP DOWN LEFT RIGHT
		; will be simplified later to use mirrored versions
		ubyte n
		str filename = "?"*16
		bool ret
		for n in 0 to 23 {
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
		
		for n in 0 to 3 {
			gen_filename( filename, "cursor", ".bin", n+1 )
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
		cx16.VERA_DATA0 = %01010000 | PAL_bob ; 16x16, use palette offset for BOB

		; turn on sprites
		cx16.VERA_DC_VIDEO |= %01000000
	}

	sub show_cursor(ubyte frame)
	{
		; set the correct sprite to use for Cursor
		uword saddr = spriteBaseAddr + $C00 + (frame*128)

		ubyte spriteBase12_5 = lsb( saddr  >> 5)
		ubyte spriteBase16_13 = msb( saddr >> 5) | spriteBaseBank << 3
		
		const ubyte ZDEPTH = 3 ; In front of LAYER1
		const ubyte FLIP = 0 ; Not flipped or mirrored

		uword cursor_screen_pos_px = real_tx_to_screen_pos(cursor_tx)
		uword cursor_screen_pos_py = real_ty_to_screen_pos(cursor_ty)
;		emudbg.console_write("r ")
;		emudbg.console_write(conv.str_ub(cursor_tx))
;		emudbg.console_write(",")
;		emudbg.console_write(conv.str_uw(cursor_ty))
;		emudbg.console_write(" v ")
;		emudbg.console_write(conv.str_ub(real_to_view_tx(cursor_tx)))
;		emudbg.console_write(",")
;		emudbg.console_write(conv.str_ub(real_to_view_ty(cursor_ty)))
;		emudbg.console_write(" sp ")
;		emudbg.console_write(conv.str_uw(cursor_screen_pos_px))
;		emudbg.console_write(",")
;		emudbg.console_write(conv.str_uw(cursor_screen_pos_py))
;		emudbg.console_write(" so ")
;		emudbg.console_write(conv.str_uw(screen_offset_px))
;		emudbg.console_write(",")
;		emudbg.console_write(conv.str_uw(screen_offset_py))
;		emudbg.console_write("  \n")

		cx16.VERA_ADDR_L = $08 ; sprite attribute #1 (cursor sprite)
		cx16.VERA_ADDR_M = $FC
		cx16.VERA_ADDR_H = 1 | %00010000     ; bank=1, increment 1
		cx16.VERA_DATA0 = spriteBase12_5
		cx16.VERA_DATA0 = spriteBase16_13  ; mode is 0 = 4bpp
		cx16.VERA_DATA0 = lsb(cursor_screen_pos_px) ; X
		cx16.VERA_DATA0 = msb(cursor_screen_pos_px)
		cx16.VERA_DATA0 = lsb(cursor_screen_pos_py) ; Y
		cx16.VERA_DATA0 = msb(cursor_screen_pos_py)
		cx16.VERA_DATA0 = FLIP | (ZDEPTH<<2)
		cx16.VERA_DATA0 = %01010000 | PAL_default ; 16x16, use default palette

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

		cx16.rambank(map0rambank)

		;void  diskio.load_raw("map64.dat", bankedRAM)
		;void  diskio.load_raw("map64res.dat", bankedRAM)
		;map_width_tiles = 64
		;map_height_tiles = 64
		;void  diskio.load_raw("m5res.dat", bankedRAM) ; this map doesn't need resources on snow
		;map_width_tiles = 60
		;map_height_tiles = 60

		void  diskio.load_raw("m4mod.dat", bankedRAM)
		map_width_tiles = 120
		map_height_tiles = 120

		map_width_tilesw = map_width_tiles as uword
		map_height_tilesw = map_height_tiles as uword
		map_data_loaded = true

		uword cpuoffset = 0
		uword cpuptr
		uword x,y
		for y in 0 to map_height_tilesw -1 {
			for x in 0 to map_width_tilesw -1 {
				cx16.rambank( lsb((cpuoffset / $2000) + map1rambank) )
				cpuptr = bankedRAM + (cpuoffset % $2000)
				@(cpuptr) = 0
				cpuoffset++
			}
		}
	}

	sub load_map_offset(uword src_col, uword src_row) {
		if map_data_loaded==false {
			load_map_raw()
		}

		; load the screen portion of the map with map data
		ubyte x
		ubyte y
		ubyte paloff
		uword cpuoffset = src_row * map_width_tilesw + src_col
		uword cpuptr

		; VERA load  - terrain into Layer 0
		cx16.VERA_ADDR_L =lsb(map0BaseAddr) 
		cx16.VERA_ADDR_M = msb(map0BaseAddr)
		cx16.VERA_ADDR_H = map0BaseBank | %00010000     ; increment 1
		for y in 0 to view_map_size-1 {
			cpuptr = bankedRAM + (cpuoffset % $2000)
			for x in 0 to view_map_size-1 {
				paloff = PAL_terrain

				cx16.rambank( lsb((cpuoffset / $2000) + map0rambank) )
				cx16.VERA_DATA0 = @(cpuptr) & $0F
				cx16.VERA_DATA0 = 0 | paloff << 4
				cpuptr += 1
				
			}
			cpuoffset += map_width_tilesw
			rows_loaded[y] = (y + lsb(src_row)) % map_height_tiles
		}

		cpuoffset = src_row * map_width_tilesw + src_col

		; VERA load  - features into layer 1
		cx16.VERA_ADDR_L =lsb(map1BaseAddr) 
		cx16.VERA_ADDR_M = msb(map1BaseAddr)
		cx16.VERA_ADDR_H = map1BaseBank | %00010000     ; increment 1
		for y in 0 to view_map_size-1 {
			cpuptr = bankedRAM + (cpuoffset % $2000)
			for x in 0 to view_map_size-1 {
				cx16.rambank( lsb((cpuoffset / $2000) + map0rambank) )
				ubyte feat = (@(cpuptr) & $F0) >> 4
				paloff = PAL_features
				cx16.rambank( lsb((cpuoffset / $2000) + map1rambank) )
				if feat == 0 {
					feat = @(cpuptr)
					if feat < tiles_machine_furnace paloff = PAL_belt
					if feat >= tiles_machine_furnace and feat < tiles_machine_miner paloff = PAL_fur_asmb
					if feat >= tiles_machine_miner paloff = PAL_miner
				}
				cx16.VERA_DATA0 = feat
				cx16.VERA_DATA0 = 0 | paloff << 4

				cpuptr += 1
				
			}
			cpuoffset += map_width_tilesw
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
		uword mapbaseptr = map0BaseAddr + mapOffset
		uword dc = 0
		uword cpuoffset, cpuptr
		ubyte paloff, feat
		; VERA load - terrain
		cx16.VERA_ADDR_L =lsb(mapbaseptr) 
		cx16.VERA_ADDR_M = msb(mapbaseptr)
		cx16.VERA_ADDR_H = map0BaseBank | %00010000     ; increment 1
		for x in 0 to view_map_size-1 {
			cpuoffset = src_row * map_width_tilesw + cols_loaded[lsb(dc)]
			cpuptr = bankedRAM + (cpuoffset % $2000)
			cx16.rambank( lsb((cpuoffset / $2000) + map0rambank) )

			cx16.VERA_DATA0 = @(cpuptr) & $0F
			cx16.VERA_DATA0 = 0 | PAL_terrain << 4

			; keep track of the map offset, even though it will be auto incremented
			mapOffset+=2

			; Check if the VERA address is going outside of the View tile map (32x32 tiles)
			if mapOffset > view_map_size_bytesw {
				; if so, wrap the address
				mapOffset -= view_map_size_bytesw
				mapbaseptr = map0BaseAddr + mapOffset
				cx16.VERA_ADDR_L =lsb(mapbaseptr) 
				cx16.VERA_ADDR_M = msb(mapbaseptr)
				cx16.VERA_ADDR_H = map0BaseBank | %00010000     ; increment 1
			}

			; increment the column index so we can look up what column needs to be read from main map
			dc = (dc+1) % view_map_size
		}

		; VERA load  - features
		mapOffset = (dest_row * view_map_sizew + 0)*2
		mapbaseptr = map1BaseAddr + mapOffset
		dc = 0
		cx16.VERA_ADDR_L =lsb(mapbaseptr) 
		cx16.VERA_ADDR_M = msb(mapbaseptr)
		cx16.VERA_ADDR_H = map1BaseBank | %00010000     ; increment 1
		for x in 0 to view_map_size-1 {
			cpuoffset = src_row * map_width_tilesw + cols_loaded[lsb(dc)]
			cpuptr = bankedRAM + (cpuoffset % $2000)
			cx16.rambank( lsb((cpuoffset / $2000) + map0rambank) )

			feat = (@(cpuptr) & $F0) >> 4
			paloff = PAL_features
			if feat == 0 {
				cx16.rambank( lsb((cpuoffset / $2000) + map1rambank) )
				feat = @(cpuptr)
				paloff = PAL_belt
				if feat < tiles_machine_furnace paloff = PAL_belt
				if feat >= tiles_machine_furnace and feat < tiles_machine_miner paloff = PAL_fur_asmb
				if feat >= tiles_machine_miner paloff = PAL_miner
			}
			cx16.VERA_DATA0 = feat
			cx16.VERA_DATA0 = 0 | paloff << 4

			; keep track of the map offset, even though it will be auto incremented
			mapOffset+=2

			; Check if the VERA address is going outside of the View tile map (32x32 tiles)
			if mapOffset > view_map_size_bytesw {
				; if so, wrap the address
				mapOffset -= view_map_size_bytesw
				mapbaseptr = map1BaseAddr + mapOffset
				cx16.VERA_ADDR_L =lsb(mapbaseptr) 
				cx16.VERA_ADDR_M = msb(mapbaseptr)
				cx16.VERA_ADDR_H = map1BaseBank | %00010000     ; increment 1
			}

			; increment the column index so we can look up what column needs to be read from main map
			dc = (dc+1) % view_map_size
		}
		
		rows_loaded[lsb(dest_row)] = lsb(src_row)
		update_low_hi_row_index()
	}
	sub load_map_col(uword src_col, uword dest_col) {
		ubyte y
		uword mapbaseptr =  0
		uword dr = 0
		uword cpuoffset, cpuptr, mapOffset
		ubyte paloff, feat
		; VERA load 
		for y in 0 to view_map_size-1 {
			cpuoffset = rows_loaded[lsb(dr)] * map_width_tilesw + src_col
			cpuptr = bankedRAM + (cpuoffset % $2000)
			cx16.rambank( lsb((cpuoffset / $2000) + map0rambank) )
			mapOffset = (dr * view_map_sizew + dest_col)*2
			if mapOffset > view_map_size_bytesw {
				mapOffset -= view_map_size_bytesw
			}
			mapbaseptr = map0BaseAddr + mapOffset

			; slow, but write the exact address each time with a inc-1 to be able to write the 2 byte field
			cx16.VERA_ADDR_L =lsb(mapbaseptr) 
			cx16.VERA_ADDR_M = msb(mapbaseptr)
			cx16.VERA_ADDR_H = map0BaseBank | %00010000     ; increment 1
			cx16.VERA_DATA0 = @(cpuptr) & $0F
			cx16.VERA_DATA0 = 0 | PAL_terrain << 4
			dr = (dr+1) % view_map_size
		}
		mapbaseptr =  0
		dr = 0
		; VERA load 
		for y in 0 to view_map_size-1 {
			cpuoffset = rows_loaded[lsb(dr)] * map_width_tilesw + src_col
			cpuptr = bankedRAM + (cpuoffset % $2000)
			cx16.rambank( lsb((cpuoffset / $2000) + map0rambank) )
			mapOffset = (dr * view_map_sizew + dest_col)*2
			if mapOffset > view_map_size_bytesw {
				mapOffset -= view_map_size_bytesw
			}
			mapbaseptr = map1BaseAddr + mapOffset

			; slow, but write the exact address each time with a inc-1 to be able to write the 2 byte field
			cx16.VERA_ADDR_L =lsb(mapbaseptr) 
			cx16.VERA_ADDR_M = msb(mapbaseptr)

			cx16.VERA_ADDR_H = map1BaseBank | %00010000     ; increment 1
			feat = (@(cpuptr) & $F0) >> 4
			paloff = PAL_features
			if feat == 0 {
				cx16.rambank( lsb((cpuoffset / $2000) + map1rambank) )
				feat = @(cpuptr)
				paloff = PAL_belt
				if feat < tiles_machine_furnace paloff = PAL_belt
				if feat >= tiles_machine_furnace and feat < tiles_machine_miner paloff = PAL_fur_asmb
				if feat >= tiles_machine_miner paloff = PAL_miner
			}
			cx16.VERA_DATA0 = feat
			cx16.VERA_DATA0 = 0 | paloff << 4

			dr = (dr+1) % view_map_size
		}

		cols_loaded[lsb(dest_col)] = lsb(src_col)
		update_low_hi_col_index()
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

	sub is_real_tx_onscreen(ubyte real_tx) -> bool {
		ubyte a = screen_pos_to_real_tx(0)
		ubyte b = screen_pos_to_real_tx(screen_width_pixels+15)
		if real_tx >= a and real_tx < b {
			return true
		}
		return false
	}
	sub is_real_ty_onscreen(ubyte real_ty) -> bool {
		ubyte a = screen_pos_to_real_ty(0)
		ubyte b = screen_pos_to_real_ty(screen_height_pixels+15)
		if real_ty >= a and real_ty < b {
			return true
		}
		return false
	}

	sub real_tx_to_screen_pos(ubyte real_tx) -> uword {
		uword screen_px = 512
		if is_real_tx_onscreen(real_tx)
		{
			uword screen_left = screen_pos_to_real_tx(0) as uword
			screen_px = (real_tx - screen_left) << 4
			screen_px -= screen_offset_px % 16
		}
		return screen_px
	}
	sub real_ty_to_screen_pos(ubyte real_ty) -> uword {
		uword screen_py = 512
		if is_real_ty_onscreen(real_ty)
		{
			uword screen_top = screen_pos_to_real_ty(0) as uword
			screen_py = (real_ty - screen_top) << 4
			screen_py -= screen_offset_py % 16
		}
		return screen_py
	}

	sub update_vera_vscroll(uword val) {
		val &= $FFF 		; 12 bit register
		cx16.VERA_L0_VSCROLL_L = lsb(val)
		cx16.VERA_L0_VSCROLL_H = msb(val)
		cx16.VERA_L1_VSCROLL_L = lsb(val)
		cx16.VERA_L1_VSCROLL_H = msb(val)
	}
	sub update_vera_hscroll(uword val) {
		val &= $FFF 		; 12 bit register
		cx16.VERA_L0_HSCROLL_L = lsb(val)
		cx16.VERA_L0_HSCROLL_H = msb(val)
		cx16.VERA_L1_HSCROLL_L = lsb(val)
		cx16.VERA_L1_HSCROLL_H = msb(val)
	}

;============================================================
; Tile checking
;============================================================

	sub is_tile_land(uword tx, uword ty) -> bool
	{
		bool ret = true
		uword cpuoffset = ty * map_width_tilesw + tx
		uword cpuptr = bankedRAM + (cpuoffset % $2000)
		cx16.rambank( lsb((cpuoffset / $2000) + map0rambank) )
		ubyte terr = @(cpuptr) & $0F
		ubyte feat = (@(cpuptr) & $F0) >> 4
		if terr == 0 or terr == 14 ret = false
		if feat > 0 ret = false
		
		return true
	}

;============================================================
; Machines
;============================================================

	; machine_data 
	;	ubyte type  ; machine type 255=empty, 0=furnace, 1=assembler, 2=miner
	;	ubyte dir	; 0=u, 1=r, 2=d, 3=l
	;	ubyte tx	; tile
	;	ubyte ty	; tile

	ubyte[256] mach_data ; space for 64 machines

	sub init_machines()
	{
		ubyte m
		for m in 0 to 63 {
			uword machp = &mach_data[m*4]
			machp[0] = 255
			machp[1] = 0
			machp[2] = 0
		}
	}

	sub find_free_mach_data_slot() -> ubyte {
		ubyte i
		for i in 0 to 255 step 4 {
			if mach_data[i] == 255 return i
		}
		return 255
	}

	;  type = 1 : furnace
	;  type = 2 : assembler
	sub add_machine(ubyte type, ubyte dir, ubyte tx, ubyte ty)
	{
		ubyte slot = find_free_mach_data_slot()
		uword machp = &mach_data[slot]
		
		ubyte mach_type

		when type {
			1 -> mach_type = tiles_machine_furnace + dir
			2 -> mach_type = tiles_machine_assembler + dir
			3 -> mach_type = tiles_machine_miner + dir
		}

		machp[0] = mach_type
		machp[1] = tx
		machp[2] = ty

		uword cpuoffset = ty * map_width_tilesw + tx
		uword cpuptr = bankedRAM + (cpuoffset % $2000)
		cx16.rambank( lsb((cpuoffset / $2000) + map1rambank) )
		@(cpuptr) = mach_type 
	}
	;                    0    1    2    3    4    5    6    7    8    9    10   11
	;ubyte[] belt_dir = [1,3, 2,0, 3,1, 0,2, 1,0, 3,0, 0,1, 0,3, 1,2, 2,1, 2,3, 3,2]
	ubyte[] belt_dir = [ 255, 6,   3,   7,
						 4,   255, 8,   0,
						 1,   9,   255, 10,
						 5,   2,   11,  255 ]
	sub add_belt(ubyte fromdir, ubyte todir, ubyte tx, ubyte ty)
	{
		if fromdir==todir or fromdir > 3 or todir > 3 return

		ubyte slot = find_free_mach_data_slot()
		uword machp = &mach_data[slot]

		ubyte mach_type = tiles_belts_start + belt_dir[fromdir*4 +todir ]

		machp[0] = mach_type
		machp[1] = tx
		machp[2] = ty

		uword cpuoffset = ty * map_width_tilesw + tx
		uword cpuptr = bankedRAM + (cpuoffset % $2000)
		cx16.rambank( lsb((cpuoffset / $2000) + map1rambank) )
		@(cpuptr) = mach_type 
	}

	ubyte[] colcycle_belt_colindex = [8,9,3,2]
	ubyte[] colcycle_belt_cols = [$F0,$0F,$A0,$0A,$AA,$0A,$AA,$0A]
	ubyte colcycle_belt_current = 0
	sub cycle_belt_palette()
	{
		ubyte i
		for i in 0 to 3 {
			ubyte index = (i + colcycle_belt_current) % 4
			ubyte colindex = colcycle_belt_colindex[ index ] 
			cx16.VERA_ADDR_L = $00 + 2*(16*PAL_belt + colindex)
			cx16.VERA_ADDR_M = $FA
			cx16.VERA_ADDR_H = 1 | %00010000     ; bank=1, increment 1
			cx16.VERA_DATA0 = colcycle_belt_cols[i*2]
			cx16.VERA_DATA0 = colcycle_belt_cols[i*2+1]
		}
		colcycle_belt_current++
	}
	ubyte[] colcycle_mach_colindex = [4,15,10]
	ubyte[] colcycle_mach_cols = [$00,$0F,$F0,$0F,$50,$0F]
	ubyte colcycle_mach_current = 0
	sub cycle_mach_palette()
	{
		ubyte i
		for i in 0 to 2 {
			ubyte index = (i + colcycle_mach_current) % 3
			ubyte colindex = colcycle_mach_colindex[ index ] 
			cx16.VERA_ADDR_L = $00 + 2*(16*PAL_fur_asmb + colindex)
			cx16.VERA_ADDR_M = $FA
			cx16.VERA_ADDR_H = 1 | %00010000     ; bank=1, increment 1
			cx16.VERA_DATA0 = colcycle_mach_cols[i*2]
			cx16.VERA_DATA0 = colcycle_mach_cols[i*2+1]
		}
		colcycle_mach_current++
	}
	ubyte[] colcycle_miner_colindex = [3,2,6]
	ubyte[] colcycle_miner_cols = [$FF,$0F,$AA,$0A,$55,$05]
	ubyte colcycle_miner_current = 0
	sub cycle_miner_palette()
	{
		ubyte i
		for i in 0 to 2 {
			ubyte index = (i + colcycle_miner_current) % 3
			ubyte colindex = colcycle_miner_colindex[ index ] 
			cx16.VERA_ADDR_L = $00 + 2*(16*PAL_miner + colindex)
			cx16.VERA_ADDR_M = $FA
			cx16.VERA_ADDR_H = 1 | %00010000     ; bank=1, increment 1
			cx16.VERA_DATA0 = colcycle_miner_cols[i*2]
			cx16.VERA_DATA0 = colcycle_miner_cols[i*2+1]
		}
		colcycle_miner_current++
	}

;============================================================
; END OF main()

}
