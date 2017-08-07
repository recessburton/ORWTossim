/**
 Copyright (C),2014-2017, YTC, www.bjfulinux.cn
 Copyright (C),2014-2017, ENS Lab, ens.bjfu.edu.cn
 Created on  2017-08-07 09:58

 @author: ytc recessburton@gmail.com
 @version: 1.8
 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 * - Neither the name of the University of California nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
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
	components new TimerMilliC() as forwardPacketTimer;
	components new TimerMilliC() as forwardPauseTimer;
	components new AMSenderC(DATAPAYLOAD);
	components new AMReceiverC(DATAPAYLOAD);
	components ActiveMessageC as RadioControl;
	components RandomC;
	components NeighborDiscoveryC;

	App.Boot               -> MainC;
	App.packetTimer        -> packetTimer;
	App.forwardPacketTimer -> forwardPacketTimer;
	App.forwardPauseTimer  -> forwardPauseTimer;
	App.wakeTimer          -> wakeTimer;
	App.sleepTimer         -> sleepTimer;
	App.Packet             -> AMSenderC;
	App.AMSend             -> AMSenderC;
	App.ACKs               -> RadioControl;
	App.Receive            -> AMReceiverC;
	App.RadioControl       -> RadioControl;
	App.Random             -> RandomC;
	App.SeedInit           -> RandomC;
	App.NeighborDiscovery  -> NeighborDiscoveryC;
}
