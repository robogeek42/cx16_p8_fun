%import syslib
%import textio
%import string
%import conv
%import diskio
%zeropage basicsafe

main {

	sub start() {
		cx16.set_screen_mode(0)

		str filename = " "*20

		ubyte n
		for n in 0 to 8 {
			gen_filename(filename, "tr", ".bin", n)
			txt.print(filename)
			txt.print("\n")
		}
	}

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
