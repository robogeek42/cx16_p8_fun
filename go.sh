#!/bin/bash

P8COMPILER=~/x16/prog8/prog8compiler-10.3.1-all.jar
X16EMU=~/x16/x16emu/x16emu

PARAM1=$1
if [ "X$PARAM1" == "X" ]
then
	echo "Pass .p8 file or .prg file"
	exit
fi

PARAM1BASE=${PARAM1%.*}
P8SRC=${PARAM1BASE}.p8
P8PRG=${PARAM1BASE}.prg
PRG=${P8PRG###*/}

if [ "$PARAM1" == "$P8SRC" ]
then

	if [ ! -f $P8SRC ]
	then
		echo "No such file $P8SRC"
		exit
	fi


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
fi

if [ "$PARAM1" == "$P8PRG" ]
then
	if [ ! -f $P8PRG ]
	then
		echo "No such file $P8PRG"
		exit
	fi

	$X16EMU -scale 2 -run -prg $P8PRG
fi
