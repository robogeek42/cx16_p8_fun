# Use by piping list of .rgb2 file to this script, e.g. :
#   ls ~/agon/fac/img/belt16/* | python3 countcols.py
#

import fileinput

pal = []

for line in fileinput.input():
    sline = line.strip('\n')
    with open(sline, "rb") as in_binfile:
        data = in_binfile.read()

    col_list = sorted(set(data))
    pal = pal + col_list
    print("file:",sline, ". ", len(col_list), " colours: ", col_list )


pal_uniq = sorted(set(pal))

print(len(pal_uniq), "unique cols: ", pal_uniq)

