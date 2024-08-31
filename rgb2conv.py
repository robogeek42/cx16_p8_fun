import sys

if len(sys.argv) < 3:
    print("usage: ", sys.argv[0:], " <infile> <outfile>")
    exit()

infile = sys.argv[1]
outfile = sys.argv[2]

with open(infile, "rb") as in_binfile:
    data = in_binfile.read()

col_list = sorted(set(data))

print(len(col_list), " colours: ", col_list )

#with open(outfile, "wb") as out_binfile:
#    out_binfile.write(bytes(item for item in data))
