#!/usr/bin/python
'''
 Copyright (C),2014-2015, YTC, www.bjfulinux.cn
 Copyright (C),2014-2015, ENS Lab, ens.bjfu.edu.cn
 Created on  2015-11-30 13:58
 
 @author: ytc recessburton@gmail.com
 @version: 0.7
 
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

#n = NescApp("TestNetwork", "app.xml")
#t = Tossim(n.variables.variables())
t = Tossim([])
r = t.radio()

f = open("linkgain.out", "r")
lines = f.readlines()
for line in lines:
  s = line.split()
  if (len(s) > 0):
    if s[0] == "gain" and int(s[1]) !=0  and int(s[2]) != 0:
      r.add(int(s[1]), int(s[2]), float(s[3]))
'''    elif s[0] == "noise":
      if int(s[1])>100:
      	continue
      m = t.getNode(int(s[1]));
      m.addNoiseTraceReading(int(float(s[2])))'''


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

t.addChannel("Probe", sys.stdout)
t.addChannel("ORWTossimC", sys.stdout)
f1 = open("logs_radio","w")
t.addChannel("Radio", f1)

while (t.time() < 500000 * t.ticksPerSecond()):
  t.runNextEvent()

print "Simulation completed."
