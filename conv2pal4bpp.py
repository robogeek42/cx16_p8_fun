# Use by piping list of .rgb2 file to this script, e.g. :
#   ls ~/agon/fac/img/belt16/* | python3 conv2pal.py
#

import fileinput
import sys
import os

pal = []
infiles = []
outfiles = []

inp = fileinput.input()
for line in inp:
    sline = line.strip('\n')
    with open(sline, "rb") as in_binfile:
        data = in_binfile.read()

    infiles.append(sline)

    col_list = sorted(set(data))
    pal = pal + col_list
    print("file:",sline, ". ", len(col_list), " colours: ", col_list )
    
    pathsplit = os.path.normpath(sline).split(os.path.sep)
    outfname_orig = pathsplit[len(pathsplit)-1]
    outfname_orig_split = outfname_orig.split('.')
    new_outfname = outfname_orig_split[0]+".bin"
    outfiles.append(new_outfname)

pal_uniq = sorted(set(pal))

print(len(pal_uniq), "unique cols: ", pal_uniq)

# output palette
with open("pal.bin","wb") as pal_file:
    for p in pal_uniq:
        r = p & 0x3
        r = r | r << 2
        g = p & 0xc
        g = g | g >> 2

        b = p & 0x30
        b = b >> 4
        b = b | b << 2

        b1 = b | g << 4
        b2 = r
        
        pal_file.write(b1.to_bytes(1,"little"))
        pal_file.write(b2.to_bytes(1,"little"))


# output files with palette index

for index in range(0,len(infiles)):
    print(infiles[index], "->", outfiles[index])

    with open(infiles[index], "rb") as in_binfile:
        data = in_binfile.read()

    with open(outfiles[index], "wb") as out_binfile:
        #out_binfile.write(0)
        #out_binfile.write(0)
        outnibbles = [0, 0]
        cnt = 0
        for d in data:
            colindex = pal_uniq.index(d)
            b = colindex.to_bytes(1,"little")
            outnibbles[cnt] = b[0]
            cnt += 1
            if cnt == 2:
                outbyte = outnibbles[1] & 0xF
                outbyte = outbyte | ( outnibbles[0] & 0xF ) << 4
                out_binfile.write(outbyte.to_bytes(1,"little"))
                cnt = 0

