/**
 Copyright (C),2014-2015, YTC, www.bjfulinux.cn
 Copyright (C),2014-2015, ENS Group, ens.bjfu.edu.cn
 Created on  2015-10-16 14:15
 
 @author: ytc recessburton@gmail.com
 @version: 0.2
 
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
#include <stdlib.h>
#include <float.h>
#include "ORWTossim.h"

module ORWTossimC @safe(){
	uses interface Boot;
	uses interface Timer<TMilli> as packetTimer;
	uses interface Timer<TMilli> as forwardpacketTimer;
	uses interface Timer<TMilli> as wakeTimer;
	uses interface Timer<TMilli> as sleepTimer;
	uses interface Packet;
	uses interface AMSend;
	uses interface Random;
	uses interface Receive;
	uses interface SplitControl as RadioControl;	
}

implementation {
	NeighborSet neighborSet[MAX_NEIGHBOR_NUM];
	int neighborSetSize=0;
	int packetCount=0;	//总共的收包数，包括串听到的和转发的包，用于计算放在包头中的forwardingrate
	int forwardCount=0; //由本节点负责转发的数据包总数，用于计算放在包头中的forwardingrate
	message_t pkt,packet;
	NeighborMsg *forwardBuffer[5];//数据包缓冲区，暂存待判定的包
	int buffersize=0;
	bool indatatask = FALSE;//是否处于发送数据包的过程中（自己产生的）
	bool initialized = FALSE;//节点是否已经被初始化
	bool inforwardtask = FALSE;//节点是否处在转发数据包的过程中（别人产生的）
	uint8_t glbforwarderid = 0;
	volatile float nodeedc;
	
	event void Boot.booted(){
		int i;
		call RadioControl.start();
		if(TOS_NODE_ID !=1)
			call wakeTimer.startOneShot(WAKE_PERIOD_MILLI);
		if(TOS_NODE_ID !=1 && (call Random.rand16() & 0xa)==0)
			call packetTimer.startPeriodic(PROBE_PERIOD_MILLI);
		//初始化forwarder节点集合
		for(i=0; i<MAX_NEIGHBOR_NUM; i++){
			neighborSet[i].nodeID = -1;
			neighborSet[i].edc = 1.0f;
			neighborSet[i].p = 1.0f;
			neighborSet[i].use = FALSE;
			neighborSet[i].overheadcount = 0;
		}
		nodeedc = (TOS_NODE_ID ==1) ? 1.0f : FLT_MAX;
	}
	
	float getforwardingrate() {
		float forwardingreate = 1.0f*forwardCount/(packetCount==0?1:packetCount);
		return (forwardingreate == 0) ? 1.0f:forwardingreate;	
	}
	
	task void sendProbe() {
		ProbeMsg * btrpkt = (ProbeMsg * )(call Packet.getPayload(&pkt, sizeof(ProbeMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = 0xFF;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->edc = 1;
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(ProbeMsg));
		dbg("Probe", "Probe Send done.\n");
	}
	
	task void sendMsg() {
		NeighborMsg * btrpkt = (NeighborMsg * )(call Packet.getPayload(&pkt, sizeof(NeighborMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = 0xFF;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwarderid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwardingrate = getforwardingrate();
		btrpkt->edc = nodeedc;
		if(!indatatask){
			indatatask = TRUE;
			dbg("ORWTossimC", "Create & Send NeighborMsg...\n");
		}
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(NeighborMsg));
	}
	
	event void packetTimer.fired() {
		if(neighborSetSize == 0){
			post sendProbe();
			call packetTimer.startOneShot(PACKET_PERIOD_MILLI);
		}else{
			call packetTimer.startOneShot(PACKET_DUPLICATE_MILLI);
			post sendMsg();
		}
	}
	
	int edccmp(const void *a ,const void *b){
		//库函数qsort()所用到的比较函数，此处按照结构体ForwarderSet中edc值“从小到大”排序
		//qsort()函数很好的例子：https://www.slyar.com/blog/stdlib-qsort.html
		return (*(NeighborSet *)a).edc > (*(NeighborSet *)b).edc ? 1 : -1;
	}
	
	task void updateEDC(){
		//根据文中的公示计算EDC值
		int i;
		float EDCpart1 = 0.0f;
		float EDCpart2 = 0.0f;
 		for(i = 0;i<neighborSetSize;i++){
 				if(!neighborSet[i].use)		//只在forwarder集中进行
 					break;
				EDCpart1 += neighborSet[i].p;
				EDCpart2 += neighborSet[i].p * neighborSet[i].edc;
		}
		if(EDCpart1<=0 || EDCpart2<=0)
			return;
		nodeedc = 1.0f/EDCpart1 + EDCpart2/EDCpart1 + WEIGHT;
		//打印邻居集，判定forwarderSet资格
		dbg("ORWTossimC", "The node EDC is %f.\n",nodeedc);
		for(i = 0;i<neighborSetSize;i++){
			neighborSet[i].use = (neighborSet[i].edc < (nodeedc - WEIGHT)) ? TRUE : FALSE;
			dbg("ORWTossimC", "NeighborSet #%d:Node %d, EDC %f, LQ %f, is use:%d\n",i+1,neighborSet[i].nodeID,neighborSet[i].edc,neighborSet[i].p,neighborSet[i].use);
		}
	}
	
	void updateSet(uint8_t nodeid, float edc, float forwardingrate){
		int i;
		if(neighborSetSize >= 20 || edc<=0 || forwardingrate <= 0)
			return;
		for(i = 0;i<neighborSetSize;i++){
			if(neighborSet[i].nodeID == nodeid){
				//链路质量计算：从该节点串听到的包率/邻居包头部中的节点平均包转发率
				//其中：串听到的包率=1/串听到的包数
				neighborSet[i].overheadcount += 1;
				neighborSet[i].p = 1.0f/neighborSet[i].overheadcount/forwardingrate;
				neighborSet[i].edc = edc;
				//按照EDC值升序排序
				qsort(neighborSet,neighborSetSize,sizeof(NeighborSet),edccmp);
				if(TOS_NODE_ID != 1)
					post updateEDC();
				return;
			}
		}
		//运行到此处说明转发节点集中尚无此节点，加入
		neighborSet[i].nodeID = nodeid;
		neighborSet[i].edc = edc;
		neighborSet[i].p = 1.0f;
		neighborSet[i].overheadcount = 1;
		neighborSet[i].use = (neighborSet[i].edc < nodeedc) ? TRUE : FALSE;
		neighborSetSize++;
		//按照EDC值升序排序
		qsort(neighborSet,neighborSetSize,sizeof(NeighborSet),edccmp);
		if(TOS_NODE_ID != 1)
					post updateEDC();
	}

	event void AMSend.sendDone(message_t * msg, error_t err) {
		call wakeTimer.stop();
		if(TOS_NODE_ID !=1)
			call wakeTimer.startOneShot(WAKE_DELAY_MILLI);//重置休眠触发时钟，向后延迟一段时间
	}
	
	void addtobuffer(NeighborMsg* neimsg) {
		if(buffersize >=5)
			return;
		forwardBuffer[buffersize] = (NeighborMsg*)malloc(sizeof(NeighborMsg));
		if(forwardBuffer[buffersize]==NULL)
			return;
		memcpy(forwardBuffer[buffersize],neimsg,sizeof(NeighborMsg)); 
		buffersize++;
	}
	
	NeighborMsg* getmsgfrombuffer(uint8_t forwarderid) {
		int i;
		for(i=0;i<buffersize;i++){
			if(forwardBuffer[i]->forwarderid == forwarderid)
				return forwardBuffer[i];
		}
		return NULL;
	}
	
	void deletefrombuffer(uint8_t forwarderid) {
		int i;
		for(i=0;i<buffersize;i++){
			if(forwardBuffer[i] == NULL)
				return;
			if(forwardBuffer[i]->forwarderid == forwarderid) {
				free(forwardBuffer[i]);
				//forwardBuffer[i] = NULL;
				buffersize--;
				return;
			}
		}
	}
	
	void sendACK(uint8_t sourceid) {
		ProbeMsg * btrpkt = (ProbeMsg * )(call Packet.getPayload(&pkt,sizeof(ProbeMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = (nx_int8_t)sourceid;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->edc = (nx_float)nodeedc;
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(ProbeMsg));
	}
	
	void sendforwardrequest(uint8_t forwarderid) {
		ControlMsg * btrpkt = (ControlMsg * )(call Packet.getPayload(&pkt,sizeof(ControlMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = (nx_int8_t)forwarderid;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwardcontrol = 0x1;
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(ControlMsg));
	}
	
	void forward(uint8_t forwarderid) {
		NeighborMsg *btrpkt = (NeighborMsg * )(call Packet.getPayload(&pkt,sizeof(NeighborMsg)));
		NeighborMsg *neimsg = getmsgfrombuffer(forwarderid);
		if(neimsg == NULL)
			return;
		memcpy(btrpkt, neimsg, sizeof(NeighborMsg));
		btrpkt->forwarderid    = (nx_int8_t)TOS_NODE_ID;
		btrpkt->dstid          = 0xFF;
		btrpkt->forwardingrate = getforwardingrate();
		btrpkt->edc            = nodeedc;
		dbg("ORWTossimC", "Forwarding packet from %d to %d...\n",btrpkt->sourceid, btrpkt->dstid);
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(NeighborMsg));
	}
	
	bool qualify(uint8_t sourceid) {
		//判断节点是否在转发表中（具有转发资格）
		int i;
		for(i = 0;i<neighborSetSize;i++){
			if(neighborSet[i].nodeID == sourceid)
				return neighborSet[i].use;
		}
		return FALSE;
	}
	
	void sendresponse(uint8_t sourceid, bool rst) {
		ControlMsg * btrpkt = (ControlMsg * )(call Packet.getPayload(&pkt,sizeof(ControlMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = (nx_int8_t)sourceid;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		if(sourceid == 1)
			rst = TRUE;
		btrpkt->forwardcontrol = rst ? 0x2 : 0x3;
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(ControlMsg));	
		if(rst && indatatask) {			//产生的包被成功转发后，准备下一次数据发送
			indatatask = FALSE;
			call packetTimer.stop();
			call packetTimer.startOneShot(PACKET_PERIOD_MILLI);
		}
		if(rst && inforwardtask) {			//转发的包被成功转发
			inforwardtask = FALSE;
			call forwardpacketTimer.stop();
			deletefrombuffer(sourceid);
		}
	}

	event message_t * Receive.receive(message_t * msg, void * payload,uint8_t len) {
		/* 按照不同长度的包区分包的类型，在此处为特例，因为不是所有不同种类的包恰好都有不同的长度。
		 * 另外，在用sizeof计算结构体长度时，本应注意字节对齐问题，比如第一个成员为uint8_t，第二个成员为uint16_t，则其长度为32
		 * 但此处用到的是网络类型数据nx_，不存在这种情况，结构体在内存中存储是无空隙的。
		 * */
		call wakeTimer.stop();
		if(TOS_NODE_ID !=1)
			call wakeTimer.startOneShot(WAKE_DELAY_MILLI);//重置休眠触发时钟，向后延迟一段时间
		if(len == sizeof(ProbeMsg)) {
			//probe 探测包处理
			ProbeMsg* btrpkt1 = (ProbeMsg*) payload;
			if(btrpkt1->dstid - TOS_NODE_ID == 0) {
				//接到自己probe包的回包
				updateSet(btrpkt1->sourceid, btrpkt1->edc, 1.0f);
				dbg("Probe", "Received ACK from %d.\n",btrpkt1->sourceid);
				initialized = TRUE;
				return msg;
			}
			//若EDC还没初始化，则不做都不做。只有sink节点会回应别人的probe包来完成网络的初始化
			if(!initialized && (TOS_NODE_ID - 1!=0))
				return msg;
			if(btrpkt1->dstid == 0xFF && (btrpkt1->sourceid-TOS_NODE_ID != 0)) {
				//接到其它节点发的probe包，回ack包
				dbg("Probe", "Sending ACK to %d...\n",btrpkt1->sourceid);
				sendACK(btrpkt1->sourceid);
				return msg;
			}
			return msg;
		}
		//若EDC还没初始化，则不做都不做。只有sink节点会回应别人的probe包来完成网络的初始化
		if(!initialized && (TOS_NODE_ID-1!=0))
			return msg;
		if(len == sizeof(NeighborMsg)) {
			//正常数据包处理
			NeighborMsg * btrpkt2 = (NeighborMsg *) payload;
			if(TOS_NODE_ID-1==0){
				//sink 节点的处理
				dbg("ORWTossimC", "Sink Node received a packet from %d,source:%d.\n",btrpkt2->forwarderid,btrpkt2->sourceid);
				sendforwardrequest(btrpkt2->forwarderid);
				return msg;
			}
			//其它节点的处理
			//接到一个包，更新，存入缓冲，发送转发请求
			if(qualify(btrpkt2->forwarderid))	//如果该节点是本节点的下一跳，则无需做任何处理（不用为它转发数据包）
				return msg;
			packetCount++;
			updateSet(btrpkt2->forwarderid, btrpkt2->edc, btrpkt2->forwardingrate);
			dbg("ORWTossimC", "Received a packet from %d, source:%d, sending forward request...\n",btrpkt2->forwarderid,btrpkt2->sourceid);
			if(!indatatask) {
				addtobuffer(btrpkt2);
				sendforwardrequest(btrpkt2->forwarderid);
			}
			return msg;
		}
		if(len == sizeof(ControlMsg)){
			//控制信息包处理
			ControlMsg* btrpkt3 = (ControlMsg*) payload;
			if(btrpkt3->forwardcontrol == 0x1){
				//收到某个转发请求
				if(btrpkt3->dstid - TOS_NODE_ID == 0){
					forwardCount++;
					dbg("ORWTossimC", "Received forward request from %d, QUALIFYING...\n",btrpkt3->sourceid);
					sendresponse(btrpkt3->sourceid,qualify(btrpkt3->sourceid));
				}
				return msg;
			}else if(btrpkt3->forwardcontrol == 0x2){
				//收到某个同意转发的包
				if(btrpkt3->dstid - TOS_NODE_ID == 0){
					forwardCount++;
					dbg("ORWTossimC", "Forwarding permitted from %d, FORWARDING...\n",btrpkt3->sourceid);
					forward(btrpkt3->sourceid);
					glbforwarderid = btrpkt3->sourceid;
					inforwardtask = TRUE;
					call packetTimer.startPeriodic(PACKET_DUPLICATE_MILLI);
				}
				return msg;
			}else if(btrpkt3->forwardcontrol == 0x3){
				//收到某个不同意转发的包
				if(btrpkt3->dstid -TOS_NODE_ID == 0){
					dbg("ORWTossimC", "Forwarding denied from %d, DISCARD.\n",btrpkt3->sourceid);
					deletefrombuffer(btrpkt3->sourceid);
				}
				return msg;
			}else{
			}
			return msg;
		}
		return msg;
	}

	event void RadioControl.startDone(error_t err){
		if(err != SUCCESS)
			call RadioControl.start();
		dbg("Radio", "RADIO STARTED.\n");
	}

	event void RadioControl.stopDone(error_t error){
		dbg("Radio", "RADIO STOPED.\n");
	}
		

	event void wakeTimer.fired(){
		if(SUCCESS == (call RadioControl.stop())){	
		   call sleepTimer.startOneShot(SLEEP_PERIOD_MILLI);
		}
	}

	event void sleepTimer.fired(){
		if(SUCCESS == (call RadioControl.start())){
	   		call wakeTimer.startOneShot(WAKE_PERIOD_MILLI);
		}
	}
	
	event void forwardpacketTimer.fired(){
		forward(glbforwarderid);
	}

}