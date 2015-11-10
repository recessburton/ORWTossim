/**
 Copyright (C),2014-2015, YTC, www.bjfulinux.cn
 Copyright (C),2014-2015, ENS Lab, ens.bjfu.edu.cn
 Created on  2015-10-16 14:15
 
 @author: ytc recessburton@gmail.com
 @version: 0.4
 
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
 **/

#include <Timer.h>
#include "ORWTossim.h"

configuration ORWTossimAppC {
}

implementation {
	components ORWTossimC as App, MainC;
	components new TimerMilliC() as packetTimer;
	components new TimerMilliC() as wakeTimer;
	components new TimerMilliC() as sleepTimer;
	components new TimerMilliC() as forwardpacketTimer;
	components new AMSenderC(ORWMSG);
	components new AMReceiverC(ORWMSG);
	components ActiveMessageC as RadioControl;
	components RandomC;

	App.Boot               -> MainC;
	App.packetTimer        -> packetTimer;
	App.forwardpacketTimer -> forwardpacketTimer;
	App.wakeTimer          -> wakeTimer;
	App.sleepTimer         -> sleepTimer;
	App.Packet             -> AMSenderC;
	App.AMSend             -> AMSenderC;
	App.Receive            -> AMReceiverC;
	App.RadioControl       -> RadioControl;
	App.Random             -> RandomC;
}
