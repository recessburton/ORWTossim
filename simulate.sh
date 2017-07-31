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
make micaz sim
export -f single_sim
#paralle 并行工具。 -N1 每次读取1个参数， --jobs 0 尽可能多的并行执行任务 {1..10}参数1~10,10为仿真次数
parallel -N1 --jobs 0 single_sim ::: {1..7}
parallel -N1 --jobs 0 single_sim ::: {8..14}
parallel -N1 --jobs 0 single_sim ::: {15..21}
#parallel -N1 --jobs 0 single_sim ::: {22..28}
#parallel -N1 --jobs 0 single_sim ::: {29..35}
#parallel -N1 --jobs 0 single_sim ::: {36..42}
#parallel -N1 --jobs 0 single_sim ::: {43..49}
#parallel -N1 --jobs 0 single_sim ::: {50..56}
#parallel -N1 --jobs 0 single_sim ::: {57..63}
#parallel -N1 --jobs 0 single_sim ::: {64..70}
#parallel -N1 --jobs 0 single_sim ::: {71..77}
#parallel -N1 --jobs 0 single_sim ::: {78..84}
#parallel -N1 --jobs 0 single_sim ::: {85..91}
#parallel -N1 --jobs 0 single_sim ::: {92..99}
