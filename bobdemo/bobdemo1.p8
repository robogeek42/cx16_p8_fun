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

	ubyte[8] v
	bool main_exit = false

	; filled in at load_map() time
	uword screen_width_pixels		; size of screen in pixels
	uword screen_height_pixels
	ubyte screen_width_tiles		; size of screen in tiles
	ubyte screen_height_tiles
	ubyte screen_map_width			; size of map enabled in L0_CONFIG (32x32)
	ubyte screen_map_height
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

	ubyte[32] rows_loaded
	ubyte[32] cols_loaded
	ubyte low_row_index = 0
	ubyte low_col_index = 0
	ubyte hi_row_index = 0
	ubyte hi_col_index = 0

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

		screen_width_pixels = 320
		screen_height_pixels = 240
		screen_width_tiles = lsb(screen_width_pixels >> 4)
		screen_height_tiles = lsb(screen_height_pixels >> 4)
		screen_map_width = 32
		screen_map_height = 32
	}

;============================================================
; MAIN START
;============================================================
	sub start() {

		setup_screen()

		diskio.chdir("assets")
		load_tiles()

		; place bob in the centre
		bob_screen_pos_px = screen_width_pixels / 2
		bob_screen_pos_py = screen_height_pixels / 2

		load_sprites()

		load_map()
		
        sys.set_irqd()
        uword old_keyhdl = cx16.KEYHDL
        cx16.KEYHDL = &keyboard_handler
        sys.clear_irqd()

		uword bob_anim_time = cbm.RDTIM16()
		const uword bob_anim_rate = 6 ; in jiffies

		;============================================================
		; GAME LOOP
		;============================================================

		const ubyte speed=2
		ubyte bobframe = 0
		do {
			sys.wait(1);
			ubyte bob_dir = 255

			if (key_bits & KEY_BITS_W) != 0 {
				if can_scroll(0, speed) {
					do_scroll(0, speed)
					bob_dir = 1
				}
			}
			if (key_bits & KEY_BITS_S) != 0 {
				if can_scroll(1, speed) {
					do_scroll(1, speed)
					bob_dir = 0
				}
			}
			if (key_bits & KEY_BITS_A) != 0 {
				if can_scroll(2, speed) {
					do_scroll(2, speed)
					bob_dir = 2
				}
			}
			if (key_bits & KEY_BITS_D) != 0 {
				if can_scroll(3, speed) {
					do_scroll(3, speed)
					bob_dir = 3
				}
			}
			if ((key_bits & KEY_BITS_X) != 0) {
				main_exit = true
			}

			if (bob_dir != 255)
			{
				/*
				emudbg.console_write(conv.str_uw0(screen_offset_px))
				emudbg.console_write(" ")
				emudbg.console_write(conv.str_uw0(screen_offset_py))
				emudbg.console_write(" ")
				emudbg.console_write("\n")
				*/
				uword tm = cbm.RDTIM16()
				if (bob_anim_time < tm)
				{
					bobframe = (bobframe+1) %4
					bob_anim_time = tm + bob_anim_rate
				}
				bob_anim(bob_dir, bobframe)
			}
		} until (main_exit == true)

        sys.set_irqd()
        cx16.KEYHDL = old_keyhdl
        sys.clear_irqd()
	}

	sub can_scroll(ubyte dir, ubyte speed) -> bool
	{
		when dir {
			0 -> return can_scroll_up(speed)
			1 -> return can_scroll_down(speed)
			2 -> return can_scroll_left(speed)
			3 -> return can_scroll_right(speed)
		}
	}
	sub can_scroll_up(uword speed) -> bool
	{
		ubyte off_ty = lsb(screen_offset_py >> 4)
		if screen_offset_py >= speed or rows_loaded[off_ty] > 0 {
			return true
		}
		return false
	}
	sub can_scroll_down(uword speed) -> bool
	{
		ubyte endofscreen_tile = screen_pos_to_real_ty(screen_height_pixels + speed)
		if endofscreen_tile+1 < map_height_tiles {
			return true
		}
		return false
	}
	sub can_scroll_left(uword speed) -> bool
	{
		ubyte off_tx = lsb(screen_offset_px >> 4)
		if screen_offset_px >= speed or cols_loaded[off_tx] > 0 {
			return true
		}
		return false
	}
	sub can_scroll_right(uword speed) -> bool
	{
		ubyte endofscreen_tile = screen_pos_to_real_tx(screen_width_pixels + speed)
		if endofscreen_tile+1 < map_width_tiles {
			return true
		}
		return false
	}


	sub do_scroll(ubyte dir, ubyte speed)
	{
		when dir {
			0 -> do_scroll_left_up(0, speed)
			1 -> do_scroll_right_down(0, speed)
			2 -> do_scroll_left_up(speed, 0)
			3 -> do_scroll_right_down(speed, 0)
		}
	}
	sub do_scroll_right_down(uword speed_px, uword speed_py)
	{
		ubyte view_tx = screen_pos_to_view_tx(screen_width_pixels-1)
		ubyte view_ty = screen_pos_to_view_ty(screen_height_pixels-1)
		ubyte real_tx = screen_pos_to_real_tx(screen_width_pixels-1)
		ubyte real_ty = screen_pos_to_real_ty(screen_height_pixels-1)
		ubyte next_view_col = view_tx
		ubyte next_view_row = view_ty
		ubyte next_real_col = real_tx
		ubyte next_real_row = real_ty

		if (speed_px > 0) {
			screen_offset_px += speed_px
			screen_offset_px &= $1FF
			update_vera_hscroll(screen_offset_px)
			next_view_col = (view_tx + 1) % 32
			next_real_col = (real_tx + 1) % map_width_tiles
		}
		if (speed_py > 0) {
			screen_offset_py += speed_py
			screen_offset_py &= $1FF
			update_vera_vscroll(screen_offset_py)
			next_view_row = (view_ty + 1) % 32
			next_real_row = (real_ty + 1) % map_height_tiles
		}

		emudbg.console_write(conv.str_ub(view_tx))
		emudbg.console_write(" ")
		emudbg.console_write(conv.str_ub(view_ty))
		emudbg.console_write(" ")
		emudbg.console_write(conv.str_ub(real_tx))
		emudbg.console_write(" ")
		emudbg.console_write(conv.str_ub(real_ty))
		emudbg.console_write("   ")

		; check col,row after the one at the right of the screen
		; make sure it contains the correct col,row from the original map
		; if not, load it

		if speed_px > 0 and cols_loaded[next_view_col] != next_real_col {
			ubyte from_row = screen_pos_to_real_ty(0)
			ubyte to_row = screen_pos_to_view_ty(0)
			load_map_col(next_real_col, from_row, next_view_col, to_row)

			emudbg.console_write(" load col ")
			emudbg.console_write(conv.str_uw(next_view_col))
			emudbg.console_write(" with ")
			emudbg.console_write(conv.str_ub(next_real_col))
			emudbg.console_write(" from row ")
			emudbg.console_write(conv.str_ub(from_row))
			emudbg.console_write("  ")
		}
		if speed_py > 0 and rows_loaded[next_view_row] != next_real_row {
			ubyte from_col = screen_pos_to_real_tx(0)
			ubyte to_col = screen_pos_to_view_tx(0)
			load_map_row(from_col, next_real_row, to_col, next_view_row)

			emudbg.console_write(" load row ")
			emudbg.console_write(conv.str_uw(next_view_row))
			emudbg.console_write(" with ")
			emudbg.console_write(conv.str_ub(next_real_row))
			emudbg.console_write(" from col ")
			emudbg.console_write(conv.str_ub(from_col))
			emudbg.console_write("  ")
		}
		emudbg.console_write("\n")
	}
	sub do_scroll_left_up(uword speed_px, uword speed_py)
	{
		ubyte view_tx = screen_pos_to_view_tx(0)
		ubyte view_ty = screen_pos_to_view_ty(0)
		ubyte real_tx = screen_pos_to_real_tx(0)
		ubyte real_ty = screen_pos_to_real_ty(0)

		ubyte prev_view_col = view_tx
		ubyte prev_view_row = view_ty
		ubyte prev_real_col = real_tx
		ubyte prev_real_row = real_ty
		if (speed_px > 0) {
			screen_offset_px -= speed_px
			screen_offset_px &= $1FF
			update_vera_hscroll(screen_offset_px)
			prev_view_col = (view_tx - 1) % 32
			prev_real_col = (real_tx - 1) % map_width_tiles
		}
		if (speed_py > 0) {
			screen_offset_py -= speed_py
			screen_offset_py &= $1FF
			update_vera_vscroll(screen_offset_py)
			prev_view_row = (view_ty - 1) % 32
			prev_real_row = (real_ty - 1) % map_height_tiles
		}

		emudbg.console_write(conv.str_ub(view_tx))
		emudbg.console_write(" ")
		emudbg.console_write(conv.str_ub(view_ty))
		emudbg.console_write(" ")
		emudbg.console_write(conv.str_ub(real_tx))
		emudbg.console_write(" ")
		emudbg.console_write(conv.str_ub(real_ty))
		emudbg.console_write("    ")

		if speed_px > 0 and cols_loaded[prev_view_col] != prev_real_col {
			load_map_col(prev_real_col, real_ty, prev_view_col, view_ty)
			emudbg.console_write(" load col ")
			emudbg.console_write(conv.str_uw(prev_view_col))
			emudbg.console_write(" with ")
			emudbg.console_write(conv.str_ub(prev_real_col))
			emudbg.console_write(" from row ")
			emudbg.console_write(conv.str_ub(real_ty))
			emudbg.console_write("   ")
		}
		if speed_py > 0 and rows_loaded[prev_view_row] != prev_real_row {
			load_map_row(real_tx, prev_real_row, view_tx, prev_view_row)
			emudbg.console_write(" load row ")
			emudbg.console_write(conv.str_uw(prev_view_row))
			emudbg.console_write(" with ")
			emudbg.console_write(conv.str_ub(prev_real_row))
			emudbg.console_write(" from col ")
			emudbg.console_write(conv.str_ub(real_tx))
			emudbg.console_write("   ")
		}
		emudbg.console_write("\n")
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

		; load the unified palette
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

		; Set sprite attributes for 1 sprite
		const ubyte spriteBase12_5 = lsb( spriteBaseAddr  >> 5)
		const ubyte spriteBase16_13 = msb( spriteBaseAddr >> 5) | spriteBaseBank << 3

		const ubyte ZDEPTH = 3 ; In front of LAYER1
		const ubyte FLIP = 0 ; Not flipped or mirrored

		cx16.VERA_ADDR_L = $00
		cx16.VERA_ADDR_M = $FC
		cx16.VERA_ADDR_H = 1 | %00010000     ; bank=1, increment 1
		cx16.VERA_DATA0 = spriteBase12_5
		cx16.VERA_DATA0 = spriteBase16_13  ; mode is 0 = 4bpp
		cx16.VERA_DATA0 = lsb(bob_screen_pos_px) ; X
		cx16.VERA_DATA0 = msb(bob_screen_pos_px)
		cx16.VERA_DATA0 = lsb(bob_screen_pos_py) ; Y
		cx16.VERA_DATA0 = msb(bob_screen_pos_py)
		cx16.VERA_DATA0 = FLIP | (ZDEPTH<<2)
		cx16.VERA_DATA0 = %01010001 ; 16x16, use palette offset 1

		; turn on sprites
		cx16.VERA_DC_VIDEO |= %01000000
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
		
		cx16.VERA_ADDR_L = $00 ; sprite attribute #0 (BOB sprite)
		cx16.VERA_ADDR_M = $FC
		cx16.VERA_ADDR_H = 1 | %00010000     ; bank=1, increment 1
		cx16.VERA_DATA0 = spriteBase12_5
		cx16.VERA_DATA0 = spriteBase16_13  ; mode is 0 = 4bpp
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
		; a 64x64 map is 4k - a single (window ino a) bank can contain 8k
		; for now just store this data into bank 1

		cx16.rambank(1) 
		void  diskio.load_raw("map64.dat", $A000)
		map_width_tiles = 64
		map_height_tiles = 64
		map_width_tilesw = map_width_tiles as uword
		map_height_tilesw = map_height_tiles as uword
		map_data_loaded = true
	}

	sub load_map() {
		if map_data_loaded==false {
			load_map_raw()
		}
		; load the screen portion of the map with map data
		ubyte x
		ubyte y
		uword cpuptr = $A000 
		low_row_index = 0
		; VERA load 
		cx16.VERA_ADDR_L =lsb(mapBaseAddr) 
		cx16.VERA_ADDR_M = msb(mapBaseAddr)
		cx16.VERA_ADDR_H = mapBaseBank | %00010000     ; bank=1, increment 1
		for y in 0 to screen_map_height-1 {
			uword yw = y as uword
			cpuptr = $A000 + yw * map_width_tilesw
			for x in 0 to screen_map_width-1 {
				cx16.VERA_DATA0 = @(cpuptr)
				cx16.VERA_DATA0 = 0
				cpuptr += 1
			}
			rows_loaded[y] = y
		}
		update_low_hi_row_index()
		for x in 0 to screen_map_width-1 {
			cols_loaded[x] = x
		}
		update_low_hi_col_index()
	}
	
	sub load_map_row(uword src_col, uword src_row, uword dest_col, uword dest_row) {
		ubyte x
		uword cpuptr = $A000 + src_row * map_width_tilesw + src_col
		uword screen_map_widthw = screen_map_width as uword
		uword mapbaseptr = mapBaseAddr + (dest_row * screen_map_widthw + dest_col)*2
		; VERA load 
		cx16.VERA_ADDR_L =lsb(mapbaseptr) 
		cx16.VERA_ADDR_M = msb(mapbaseptr)
		cx16.VERA_ADDR_H = mapBaseBank | %00010000     ; bank=1, increment 1
		for x in 0 to screen_map_width-1 {
			cx16.VERA_DATA0 = @(cpuptr)
			cx16.VERA_DATA0 = 0
			cpuptr++
		}
		rows_loaded[lsb(dest_row)] = lsb(src_row)
		update_low_hi_row_index()
	}
	sub load_map_col(uword src_col, uword src_row, uword dest_col, uword dest_row) {
		ubyte y
		uword cpuptr = $A000 + src_row * map_width_tilesw + src_col
		uword screen_map_widthw = screen_map_width as uword
		uword mapbaseptr = mapBaseAddr + (dest_row * screen_map_widthw + dest_col)*2
		; VERA load 
		cx16.VERA_ADDR_L =lsb(mapbaseptr) 
		cx16.VERA_ADDR_M = msb(mapbaseptr)
		cx16.VERA_ADDR_H = mapBaseBank | %01110000     ; bank=1, increment 32 * 2
		for y in 0 to screen_map_height-1 {
			cx16.VERA_DATA0 = @(cpuptr)
			cpuptr += map_width_tilesw
		}
		cpuptr = $A000 + src_row * map_width_tilesw + src_col
		cx16.VERA_ADDR_L =lsb(mapbaseptr+1) 
		cx16.VERA_ADDR_M = msb(mapbaseptr+1)
		cx16.VERA_ADDR_H = mapBaseBank | %01110000     ; bank=1, increment 32 * 2
		for y in 0 to screen_map_height-1 {
			cx16.VERA_DATA0 = 0
			cpuptr += map_width_tilesw
		}
		cols_loaded[lsb(dest_col)] = lsb(src_col)
		update_low_hi_col_index()
	}

	sub update_low_hi_row_index() {
		ubyte low_row_value = 255
		ubyte hi_row_value = 0

		ubyte i
		; TODO make this more efficient - shouldn't be a loop
		for i in 0 to (screen_map_height-1) {
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
		for i in 0 to screen_map_width-1 {
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
			for i in 0 to screen_map_width-1 {
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
			for i in 0 to screen_map_height-1 {
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
		view_tx %= screen_map_width
		return view_tx
	}
	sub screen_pos_to_view_ty(uword screen_py) -> ubyte {
		ubyte view_ty
		uword view_py = screen_offset_py + screen_py 
		view_ty = lsb(view_py >> 4)
		view_ty %= screen_map_height
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
; END OF main()

}
