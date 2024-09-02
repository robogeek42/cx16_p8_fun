%import syslib
%import textio
%import diskio
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

	const ubyte tileBaseBank = 1
	const uword tileBaseAddr = $B000
	ubyte tileBase16_11 = 0
	const ubyte mapBaseBank = 1
	const uword mapBaseAddr = $7000
	ubyte mapBase16_9 = 0
	const ubyte palBaseBank = 1
	const uword palBaseAddr = $FA00

	const ubyte spriteBaseBank = 1
	const uword spriteBaseAddr = $3000

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

;============================================================
; MAIN START
;============================================================
	sub start() {

		setup_screen()

		diskio.chdir("assets")
		load_tiles()
		load_sprites()

		; Load the tile map. 64x64 is 8k
		void  diskio.vload_raw("maps64x64.bin", mapBaseBank, mapBaseAddr)
		
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
				cx16.VERA_L1_VSCROLL -= speed
				bob_dir = 1
			}
			if (key_bits & KEY_BITS_S) != 0 {
				cx16.VERA_L1_VSCROLL += speed
				bob_dir = 0
			}
			if (key_bits & KEY_BITS_A) != 0 {
				cx16.VERA_L1_HSCROLL -= speed
				bob_dir = 2
			}
			if (key_bits & KEY_BITS_D) != 0 {
				cx16.VERA_L1_HSCROLL += speed
				bob_dir = 3
			}
			if ((key_bits & KEY_BITS_X) != 0) {
				main_exit = true
			}

			if (bob_dir != 255)
			{
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

;============================================================
; KEYBOARD HANDLER
;============================================================
    sub keyboard_handler(ubyte keynum) -> ubyte {
        ; NOTE: this handler routine expects the keynum in A and return value in A
        ;       which is thankfully how prog8 translates this subroutine's calling convention.
		ubyte keycode = keynum & $7F
        if keynum & $80 ==0 {
			when keycode {
				$12 -> key_bits |= KEY_BITS_W ; w - up
				$20 -> key_bits |= KEY_BITS_S ; s - down
				$1F -> key_bits |= KEY_BITS_A ; a - left
				$21 -> key_bits |= KEY_BITS_D ; d - right
				$2F -> key_bits |= KEY_BITS_X ; x - exit
			}
		}
        else {
			when keycode {
				$12 -> key_bits &= KEY_MASK_W ; w - up
				$20 -> key_bits &= KEY_MASK_S ; s - down
				$1F -> key_bits &= KEY_MASK_A ; a - left
				$21 -> key_bits &= KEY_MASK_D ; d - right
				$2F -> key_bits &= KEY_MASK_X ; x - exit
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
; SCREEN SETUP FOR 4BPP
;============================================================
	sub setup_screen() {
        tileBase16_11 = (tileBaseBank<<5) | (tileBaseAddr>>11)
		mapBase16_9 = (mapBaseBank<<7) | (mapBaseAddr>>9)
	
		save_vera()

        ; enable 320*240  8bpp tile-mode
        cx16.VERA_CTRL=0
        cx16.VERA_DC_VIDEO = (cx16.VERA_DC_VIDEO & %11001111) | %00100000      ; enable only layer 1
        cx16.VERA_DC_HSCALE = 64
        cx16.VERA_DC_VSCALE = 64
        cx16.VERA_L1_CONFIG = %01010010 ; map h/w (0,0) = 64x64, color depth (10) = 4bpp, 256c should be off to use pallete
        cx16.VERA_L1_MAPBASE = mapBase16_9
        cx16.VERA_L1_TILEBASE = tileBase16_11<<2 | %11 ; tile size 16x16
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
		cx16.VERA_DATA0 = 160 ; X
		cx16.VERA_DATA0 = 0
		cx16.VERA_DATA0 = 120 ; Y
		cx16.VERA_DATA0 = 0
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

}
