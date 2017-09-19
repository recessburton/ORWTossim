#!/bin/bash
single_sim() {
	echo START SIM \#$1
	mkdir $1
	cd ./$1
	cp  ../ORWTest.py ./
	cp -r ../simbuild ./
	cp ../grid_5_by_20_footballfield_2.txt ./
	cp ../meyer-short.txt ./
	cp ../TOSSIM.py .
#	cp ../app.xml ./
#	cp ../TinyOS_Plugin_Makefile ./
	cp ../_TOSSIMmodule.so ./
	python ./ORWTest.py
	echo SIM \#$1 COMPLETED!
	rm -rf *.py *.pyc ./simbuild *.txt *.xml *Makefile *.so
	cd ..
	tar -jcvf $1.tar.bz2 ./$1
	rm -rf ./$1
}
cp -r ./src/* ./
cp -r ./NeighborDiscovery/* ./
make micaz sim || echo "*** !!! FAILED to built micaz TOSSIM library. Stop simulation!!!***";exit 1
export -f single_sim
#paralle 并行工具。 -N1 每次读取1个参数， --jobs 0 尽可能多的并行执行任务 {1..10}参数1~10,10为仿真次数
parallel -N1 --jobs 0 single_sim ::: {1..4}
parallel -N1 --jobs 0 single_sim ::: {5..8}
parallel -N1 --jobs 0 single_sim ::: {9..12}
parallel -N1 --jobs 0 single_sim ::: {13..16}
parallel -N1 --jobs 0 single_sim ::: {17..20}
parallel -N1 --jobs 0 single_sim ::: {21..24}
parallel -N1 --jobs 0 single_sim ::: {25..28}
parallel -N1 --jobs 0 single_sim ::: {29..32}
parallel -N1 --jobs 0 single_sim ::: {33..36}
parallel -N1 --jobs 0 single_sim ::: {37..40}
parallel -N1 --jobs 0 single_sim ::: {41..44}
parallel -N1 --jobs 0 single_sim ::: {45..48}
parallel -N1 --jobs 0 single_sim ::: {49..52}
parallel -N1 --jobs 0 single_sim ::: {53..56}
parallel -N1 --jobs 0 single_sim ::: {57..60}
parallel -N1 --jobs 0 single_sim ::: {61..64}
parallel -N1 --jobs 0 single_sim ::: {65..68}
parallel -N1 --jobs 0 single_sim ::: {69..72}
parallel -N1 --jobs 0 single_sim ::: {73..76}
parallel -N1 --jobs 0 single_sim ::: {77..80}
parallel -N1 --jobs 0 single_sim ::: {81..84}
parallel -N1 --jobs 0 single_sim ::: {85..88}
parallel -N1 --jobs 0 single_sim ::: {89..92}
parallel -N1 --jobs 0 single_sim ::: {93..96}
parallel -N1 --jobs 0 single_sim ::: {97..99}
