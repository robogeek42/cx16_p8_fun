#!/bin/bash

P8COMPILER=~/x16/prog8/prog8compiler-10.3.1-all.jar
X16EMU=~/x16/x16emu/x16emu

P8SRC=$1
if [ ! -f $P8SRC ]
then
	echo "No such prog8 file"
	exit
fi
PRGPATH=${P8SRC%.p8}.prg
PRG=${PRGPATH##*/}

if [ ! -d build ]
then
	mkdir build
fi

# compile
java -jar $P8COMPILER -target cx16 -out build $P8SRC 

# if successful
if [ $? -eq 0 ]
then
	cp build/$PRG .
	# run
	$X16EMU -scale 2 -run -prg $PRG
fi
