#!/usr/bin/python
'''
 Copyright (C),2014-2015, YTC, www.bjfulinux.cn
 Copyright (C),2014-2015, ENS Lab, ens.bjfu.edu.cn
 Created on  2015-12-10 16:15
 
 @author: ytc recessburton@gmail.com
 @version: 0.9
 
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>
'''
from TOSSIM import *
from tinyos.tossim.TossimApp import *
from random import *
import sys

emulatehours = 10.0
emulatetimeseconds = int(emulatehours*3687)
#n = NescApp("TestNetwork", "app.xml")
#t = Tossim(n.variables.variables())
t = Tossim([])
r = t.radio()
tickspersencond = t.ticksPerSecond()

f = open("15-15-tight-mica2-grid.txt", "r")
lines = f.readlines()
for line in lines:
  s = line.split()
  if (len(s) > 0):
    if s[0] == "gain" and int(s[1]) !=0  and int(s[2]) != 0:
      r.add(int(s[1]), int(s[2]), float(s[3]))


noise = open("meyer-short.txt", "r")
lines = noise.readlines()
for line in lines:
  str = line.strip()
  if (str != ""):
    val = int(str)
    for i in range(1, 100):
      m = t.getNode(i);
      m.addNoiseTraceReading(val)



for i in range(1, 100):
  m = t.getNode(i);
  m.createNoiseModel();
  time = randint(t.ticksPerSecond(), 20 * t.ticksPerSecond())
  m.bootAtTime(time)
  print "Booting ", i, " at time ", time

print "Starting simulation."

f1 = open("logs_radio","w")
f2 = open("logs_probe","w")
f3 = open("logs_ORW","w")
f4 = open("logs_neighbor","w")
t.addChannel("Radio", f1)
t.addChannel("Probe", f2)
t.addChannel("ORWTossimC", f3)
t.addChannel("Neighbor", f4)

while (t.time() < emulatetimeseconds * tickspersencond):
	t.runNextEvent()

print "Simulation completed."
