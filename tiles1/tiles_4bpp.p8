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

	ubyte[8] v

	sub start() {
        tileBase16_11 = (tileBaseBank<<5) | (tileBaseAddr>>11)
		mapBase16_9 = (mapBaseBank<<7) | (mapBaseAddr>>9)
	
		save_vera()

        ; enable 320*240  8bpp tile-mode
        cx16.VERA_CTRL=0
        cx16.VERA_DC_VIDEO = (cx16.VERA_DC_VIDEO & %11001111) | %00100000      ; enable only layer 1
        cx16.VERA_DC_HSCALE = 64
        cx16.VERA_DC_VSCALE = 64
        cx16.VERA_L1_CONFIG = %00000010 ; map h/w (0,0) = 32x32, color depth (10) = 4bpp, 256c should be off to use pallete
        cx16.VERA_L1_MAPBASE = mapBase16_9
        cx16.VERA_L1_TILEBASE = tileBase16_11<<2 | %11 ; tile size 16x16

		; load tile data

		diskio.chdir("dat")
		diskio.chdir("16x164bpp")

		str[] filenames = [ "tr02.bin", "tr03.bin", "tr04.bin", "tr05.bin", "tr06.bin", "tr07.bin", "tr08.bin", "tr09.bin", "tr01.bin"  ]
		ubyte n
		bool ret
		uword tbaddr = tileBaseAddr ; tileBaseAddr is a constant

		for n in 0 to 8 {
			ret =  diskio.vload_raw(filenames[n], tileBaseBank, tbaddr)
			if ret == false {
				restore_vera()
				txt.print("error loading ")
				txt.print( filenames[n] )
				return
			}
			tbaddr += 128
		}

		; load the palette
		void diskio.vload_raw( "pal.bin", palBaseBank, palBaseAddr )

		; write some data to the tile map
		cx16.VERA_CTRL = 0
        cx16.VERA_ADDR_L = lsb(mapBaseAddr)
        cx16.VERA_ADDR_M = msb(mapBaseAddr)
        cx16.VERA_ADDR_H = mapBaseBank | %00010000     ; bank=1, increment 1

		uword i
		for i in 0 to (32*32) {
			ubyte tile = math.rnd() % 4
			if i > 255 {
				tile += 4
			}

			uword c = i % 32
			uword r = i / 32

			if (c > 4) and (c < 12) and (r > 5) and (r < 10) {
				tile = 8
			}

			cx16.VERA_DATA0 = tile
			cx16.VERA_DATA0 = 0
		}

		; setup the keyboard handler

		ubyte key
		ubyte speed=4
		do {
			sys.wait(1);
			void, key = cbm.GETIN()

			when key {
				'w' -> cx16.VERA_L1_VSCROLL -= speed
				's' -> cx16.VERA_L1_VSCROLL += speed
				'a' -> cx16.VERA_L1_HSCROLL -= speed
				'd' -> cx16.VERA_L1_HSCROLL += speed
			}
		} until key == 'x'
	}

	sub save_vera() {
		v[0] = cx16.VERA_CTRL
		v[1] = cx16.VERA_DC_VIDEO
		v[2] = cx16.VERA_L1_CONFIG
		v[3] = cx16.VERA_L1_MAPBASE
		v[4] = cx16.VERA_L1_TILEBASE
	}
	sub restore_vera() {
		cx16.VERA_CTRL = v[0]
		cx16.VERA_DC_VIDEO = v[1]
		cx16.VERA_L1_CONFIG = v[2]
		cx16.VERA_L1_MAPBASE = v[3]
		cx16.VERA_L1_TILEBASE = v[4]
	}
}
