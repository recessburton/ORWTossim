/**
 Copyright (C),2014-2016, YTC, www.bjfulinux.cn
 Copyright (C),2014-2016, ENS Lab, ens.bjfu.edu.cn
 Created on  2016-01-27 13:40
 
 @author: ytc recessburton@gmail.com
 @version: 1.1
 
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
	uses interface ParameterInit<uint16_t> as SeedInit;
	uses interface Packet;
	uses interface AMSend;
	uses interface Random;
	uses interface Receive;
	uses interface Packet as CTRLPacket;
	uses interface AMSend as CTRLSender;
	uses interface Receive as CTRLReceiver;
	uses interface SplitControl as RadioControl;
	uses interface LocalTime<TMilli> as LocalTime; 	
}

implementation {
	NeighborSet neighborSet[MAX_NEIGHBOR_NUM];
	int neighborSetSize=0;
	int forwardCount=0; //由本节点负责转发的数据包总数，用于计算放在包头中的forwardingrate
	int forwardreplicacount=0;//转发重复计数
	int msgreplicacount=0;//数据包发送重复计数
	message_t pkt,packet;
	NeighborMsg *forwardBuffer[MAX_NEIGHBOR_NUM];//数据包缓冲区，暂存待判定的包
	uint8_t glbforwardmsgid = 0;
	unsigned char flags;//标志位，与掩码运算可知相应位置是否置位
	volatile float nodeedc;
	volatile uint16_t index = 0;	//数据包序号
	typedef struct overheadcountlist{
		int nodeid;
		int count;
		float forwardingrate;
	}overheadcountlist;
	
	overheadcountlist ocl[MAX_NEIGHBOR_NUM*5];//overhead计数表，记录overhead到某个节点的次数，用于计算Linkquality

/*位运算之掩码使用：
 * 打开位： flags = flags | MASK
 * 关闭位： flags = flags & ~MASK	
 * 转置位： flags = flags ^ MASK
 * 查看位： (flags&MASK) == MASK
 * */
	
	event void Boot.booted(){
		int i;
		flags = 0x0;//初始化标志位
		call SeedInit.init((uint16_t)sim_time());
		flags = ((unsigned int)(call Random.rand16())%100)/MESSAGE_PRODUCE_RATIO==0 ? (flags | MSGSENDER) : (flags & ~MSGSENDER);
		flags |= SLEEPALLOWED;		//启用休眠机制
		//flags &= ~SLEEPALLOWED;	//关闭休眠机制
		if((flags & MSGSENDER) == MSGSENDER){
			dbg("Bootinfo", "is Msg Sendor.\n");
		}
		call RadioControl.start();
		if(TOS_NODE_ID == 1)
			flags |= INITIALIZED;	//sink节点一开始就是初始化的
		else
			call packetTimer.startOneShot(PROBE_PERIOD_MILLI);
		//初始化forwarder节点集合
		for(i=0; i<MAX_NEIGHBOR_NUM; i++){
			neighborSet[i].nodeID = -1;
			neighborSet[i].edc = 1.0f;
			neighborSet[i].p = 1.0f;
			neighborSet[i].use = FALSE;
		}
		nodeedc = (TOS_NODE_ID ==1) ? 0.0f : FLT_MAX;
		//初始化buffer和OCL
		for(i=0;i<MAX_NEIGHBOR_NUM;i++){
			forwardBuffer[i] = NULL;
		}
		for(i=0;i<MAX_NEIGHBOR_NUM*5;i++){
			ocl[i].nodeid = -1;
			ocl[i].count = 0;
			ocl[i].forwardingrate = 0.0f;
		}
		forwardCount = 0;
	}
	
	float getforwardingrate() {
		float forwardingrate = 1.0f/(forwardCount>0?forwardCount:1);
		return (forwardingrate == 0) ? 1.0f:forwardingrate;
	}
	
	task void sendProbe() {
		ProbeMsg * btrpkt = (ProbeMsg * )(call Packet.getPayload(&pkt, sizeof(ProbeMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = 0xFF;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->edc = 0;
		btrpkt->linkq = 0;
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(ProbeMsg));
		dbg("Probe", "Probe Send done.\n");
	}
	
	void sendMsg() {
		//周期产生数据包
		NeighborMsg * btrpkt = NULL;
		if(msgreplicacount > MAX_REPLICA_COUNT){
			msgreplicacount = 0;
			flags &= ~DATATASK;
			dbg("ORWTossimC", "%s ERROR rechieve_Max_replica\n",sim_time_string());
			call packetTimer.stop();
			call packetTimer.startOneShot(PACKET_PERIOD_MILLI);
			return;
		}
		msgreplicacount +=1;
		btrpkt = (NeighborMsg * )(call Packet.getPayload(&pkt, sizeof(NeighborMsg)));
		if(btrpkt == NULL)
			return;
		forwardCount+=1;
		if((flags & DATATASK) != DATATASK){
			flags |= DATATASK;
			index+=1;
			dbg("ORWTossimC", "%s CREATE %d\n",sim_time_string(),index);
		}else{
			;//dbg("ORWTossimC", "%s Resend NeighborMsg index %d...\n",sim_time_string(),index);
		}
		btrpkt->dstid = 0xFF;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwarderid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwardingrate = getforwardingrate();
		btrpkt->index = index;
		btrpkt->edc=nodeedc;
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(NeighborMsg));
		call wakeTimer.stop();	//关闭休眠，等待转发请求
	}
	
	event void packetTimer.fired() {
		if(neighborSetSize == 0){
			post sendProbe();
			call packetTimer.startOneShot(PACKET_PERIOD_MILLI);
		}else if((flags & MSGSENDER) == MSGSENDER){
			//总共1/MESSAGE_PRODUCE_RATIO的节点产生数据包，其余节点不产生
			call packetTimer.startOneShot(PACKET_DUPLICATE_MILLI);
			sendMsg();
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
 		atomic { 
	 		for(i = 0;i<neighborSetSize;i++){
	 				if(!neighborSet[i].use)		//只在forwarder集中进行
	 					break;
					EDCpart1 += neighborSet[i].p;
					EDCpart2 += neighborSet[i].p * neighborSet[i].edc;
			}
			if(EDCpart1<=0)
				return;
			nodeedc = 1.0f/EDCpart1 + EDCpart2/EDCpart1 + WEIGHT;
		}
		//打印邻居集，判定forwarderSet资格
		dbg("Neighbor", "%s The node EDC is %f.\n",sim_time_string(),nodeedc);
		for(i = 0;i<neighborSetSize;i++){
			neighborSet[i].use = (neighborSet[i].edc <= (nodeedc - WEIGHT)) ? TRUE : FALSE;
			dbg("Neighbor", "NeighborSet #%d:Node %d, EDC %f, LQ %f, is use:%d\n",i+1,neighborSet[i].nodeID,neighborSet[i].edc,neighborSet[i].p,neighborSet[i].use);
		}
	}
	
	void updateSet(uint8_t nodeid, float edc, float linkq){
		int i;
		if(neighborSetSize >= MAX_NEIGHBOR_NUM)
			return;
		for(i = 0;i<neighborSetSize;i++){
			if(neighborSet[i].nodeID == nodeid){
			neighborSet[i].p = linkq;
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
		neighborSet[i].p = linkq;
		neighborSet[i].use = (neighborSet[i].edc <= (nodeedc - WEIGHT)) ? TRUE : FALSE;
		neighborSetSize++;
		//按照EDC值升序排序
		qsort(neighborSet,neighborSetSize,sizeof(NeighborSet),edccmp);
		if(TOS_NODE_ID != 1)
					post updateEDC();
	}

	event void AMSend.sendDone(message_t * msg, error_t err) {
		if(((flags&SLEEPALLOWED) == SLEEPALLOWED) && ((flags&DATATASK)!=DATATASK) && ((flags&FORWARDTASK)!=FORWARDTASK)){
			call wakeTimer.stop();
			if(TOS_NODE_ID !=1)
				call wakeTimer.startOneShot(WAKE_DELAY_MILLI);//重置休眠触发时钟，向后延迟一段时间
		}
	}
	
	int addtobuffer(NeighborMsg* neimsg) {
		//返回值：-1 加入失败，或已有相同的包，duplicate； >=0 加入成功，返回buffer中index值
		int i;
		for(i=0;i<MAX_NEIGHBOR_NUM;i++){
			if(forwardBuffer[i] == NULL)
			{	//此buffer位置无内容
				atomic {
					forwardBuffer[i] = (NeighborMsg*)malloc(sizeof(NeighborMsg));
					if(forwardBuffer[i]==NULL){
						dbg("ORWTossimC", "%s ERROR fail_to_allocate_space_in_buffer\n");
						return -1;
					}
					memcpy(forwardBuffer[i],neimsg,sizeof(NeighborMsg)); 
					return i;
				}
			}else if(forwardBuffer[i]->sourceid == neimsg->sourceid){
				//此buffer位置已有该节点内容
				if (forwardBuffer[i]->index == neimsg->index){
					dbg("ORWTossimC", "%s ERROR has_same_SOURCE_msg_in_buffer\n");
					return -1;
				}
				else{
					memcpy(forwardBuffer[i],neimsg,sizeof(NeighborMsg)); 
					return i;
				}
			}
			//此buffer位置有其它内容，继续下一个位置的遍历
		}
		dbg("ORWTossimC", "%s ERROR the_buffer_is_FULL\n",sim_time_string());
		return -1;
	}
	
	NeighborMsg* getmsgfrombuffer(uint8_t sourceid) {
		int i;
		for(i=0;i<MAX_NEIGHBOR_NUM;i++){
			if(forwardBuffer[i] != NULL && forwardBuffer[i]->sourceid == sourceid)
				return forwardBuffer[i];
		}
		return NULL;
	}
	
	void deletefrombuffer(uint8_t sourceid) {
		int i; 
		atomic {
			for(i=0;i<MAX_NEIGHBOR_NUM;i++){
				if(forwardBuffer[i] != NULL && forwardBuffer[i]->sourceid == sourceid) {
					free(forwardBuffer[i]);
					forwardBuffer[i] = NULL;
					return;
				}
			}
		}
	}
	
	void updateOCL(uint8_t nodeid, float forwardingrate){
		int i;
		bool found = FALSE;
		for(i=0;i<MAX_NEIGHBOR_NUM*5 && !found;i++){
			if((ocl[i].nodeid == -1)||(ocl[i].nodeid == nodeid)){
				found = TRUE;
				ocl[i].nodeid = nodeid;
				if(ocl[i].forwardingrate!=forwardingrate)
					ocl[i].count += 1;
				ocl[i].forwardingrate = forwardingrate;
			}
		}
		if(!found){
			dbg("ORWTossimC", "%s ERROR update_OCL_with_i:%d\n",sim_time_string(),i);
			/*for(i=0;i<MAX_NEIGHBOR_NUM*5;i++){
				dbg("ORWTossimC", "i:%d,nodeid:%d,c:%d,fr:%f.\n",i,ocl[i].nodeid,ocl[i].count,ocl[i].forwardingrate);
			}*/
		}
	}
	
	float getLinkQ(uint8_t nodeid){
		int i;
		for(i=0;i<MAX_NEIGHBOR_NUM*5;i++){
			if(ocl[i].nodeid == nodeid){
				return 1.0f/(1.0f/ocl[i].count/ocl[i].forwardingrate);
			}
		}
		return -1.0f;	
	}
	
	void sendACK(uint8_t sourceid) {
		ProbeMsg * btrpkt = (ProbeMsg * )(call Packet.getPayload(&pkt,sizeof(ProbeMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = (nx_int8_t)sourceid;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->edc = (nx_float)nodeedc;
		btrpkt->linkq = 1;
		//dbg("ORWTossimC", ">>>>>>>>>before %ld %s\n",sim_time(),sim_time_string());
		call SeedInit.init((uint16_t)sim_time());
		RANDOMDELAY(((unsigned int)call Random.rand16())%100);
		//dbg("ORWTossimC", ">>>>>>>>>after %ld %s\n",sim_time(),sim_time_string());
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(ProbeMsg));
	}
	
	void sendforwardrequest(uint8_t forwarderid, uint8_t msgsource) {
		ControlMsg * btrpkt = (ControlMsg * )(call CTRLPacket.getPayload(&pkt,sizeof(ControlMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = (nx_int8_t)forwarderid;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwardcontrol = 0x1;
		btrpkt->msgsource = msgsource;
		btrpkt->edc = nodeedc;
		btrpkt->linkq = getLinkQ(forwarderid);
		dbg("ORWTossimC", "%s ACK %d %f\n",sim_time_string(),forwarderid,btrpkt->linkq);
		call SeedInit.init((uint16_t)sim_time());
		RANDOMDELAY(((unsigned int)call Random.rand16())%100);
		call CTRLSender.send(AM_BROADCAST_ADDR, &pkt, sizeof(ControlMsg));
	}
	
	void forward() {
		NeighborMsg *btrpkt = (NeighborMsg * )(call Packet.getPayload(&pkt,sizeof(NeighborMsg)));
		NeighborMsg *neimsg = NULL;
		neimsg = getmsgfrombuffer(glbforwardmsgid);
		if(neimsg == NULL)
			return;
		forwardCount++;
		memcpy(btrpkt, neimsg, sizeof(NeighborMsg));
		btrpkt->forwarderid    = (nx_int8_t)TOS_NODE_ID;
		btrpkt->dstid          = 0xFF;
		btrpkt->forwardingrate = getforwardingrate();
		btrpkt->edc            = nodeedc;
		call SeedInit.init((uint16_t)sim_time());
		RANDOMDELAY(((unsigned int)call Random.rand16())%100);
		if((flags&FORWARDTASK)!=FORWARDTASK) {
			flags |= FORWARDTASK;
			dbg("ORWTossimC", "%s FORWARD %d %d %d %f\n",sim_time_string(),neimsg->forwarderid, btrpkt->sourceid,btrpkt->index,btrpkt->forwardingrate);
		}else{
			;//dbg("ORWTossimC", "%s Reforwarding packet from %d, source:%d, index:%d, fr:%f...\n",sim_time_string(),neimsg->forwarderid, btrpkt->sourceid,btrpkt->index,btrpkt->forwardingrate);
		}
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(NeighborMsg));
		call wakeTimer.stop();	//停止休眠，等待转发请求
	}
	
	bool qualify(float edc) {
		//判断接到的包需不需要被转发，本节点比转发一次的代价小，则转发；否则，由本节点不合适转发
		//注意，此处与节点邻居表中判断是否use的条件正好相反。（ (neighborSet[i].edc <= (nodeedc - WEIGHT))）
		return (nodeedc <= (edc - WEIGHT)) ? TRUE : FALSE;
	}

	event message_t * Receive.receive(message_t * msg, void * payload,uint8_t len) {
		/* 按照不同长度的包区分包的类型，在此处为特例，因为不是所有不同种类的包恰好都有不同的长度。
		 * 另外，在用sizeof计算结构体长度时，本应注意字节对齐问题，比如第一个成员为uint8_t，第二个成员为uint16_t，则其长度为32
		 * 但此处用到的是网络类型数据nx_，不存在这种情况，结构体在内存中存储是无空隙的。
		 * */
		if(((flags&SLEEPALLOWED) == SLEEPALLOWED) && ((flags&INITIALIZED) != INITIALIZED)){
			call wakeTimer.stop();
			if(TOS_NODE_ID !=1){
				call SeedInit.init((uint16_t)sim_time());
				call wakeTimer.startOneShot(WAKE_DELAY_MILLI+((unsigned int)call Random.rand16())%100);//重置休眠触发时钟，向后延迟一段时间
			}
		}
		if(len == sizeof(ProbeMsg)) {
			//probe 探测包处理
			ProbeMsg* btrpkt1 = (ProbeMsg*) payload;
			if(btrpkt1->dstid - TOS_NODE_ID == 0) {
				//接到自己probe包的回包
				updateSet(btrpkt1->sourceid, btrpkt1->edc, 1.0f);
				dbg("Probe", "%s Received ACK from %d.\n",sim_time_string(),btrpkt1->sourceid);
				flags |= INITIALIZED;
				if((flags&SLEEPALLOWED) == SLEEPALLOWED){
					call wakeTimer.stop();
					if(TOS_NODE_ID !=1){
						call SeedInit.init((uint16_t)sim_time());
						call wakeTimer.startOneShot(WAKE_DELAY_MILLI+((unsigned int)call Random.rand16())%100);//重置休眠触发时钟，向后延迟一段时间
					}
				}
				return msg;
			}
			//若EDC还没初始化，则不做都不做。
			if((flags&INITIALIZED) != INITIALIZED)
				return msg;
			if(btrpkt1->dstid == 0xFF && (btrpkt1->sourceid-TOS_NODE_ID != 0)) {
				//接到其它节点发的probe包，回ack包
				dbg("Probe", "%s Sending ACK to %d...\n",sim_time_string(),btrpkt1->sourceid);
				sendACK(btrpkt1->sourceid);
				return msg;
			}
			return msg;
		}
		//若EDC还没初始化，则不做都不做。只有sink节点会回应别人的probe包来完成网络的初始化
		if(((flags&INITIALIZED) != INITIALIZED) && (TOS_NODE_ID-1!=0))
			return msg;
		if(len == sizeof(NeighborMsg)) {
			//正常数据包处理
			NeighborMsg * btrpkt2 = (NeighborMsg *) payload;
			if((btrpkt2->sourceid-TOS_NODE_ID == 0)||(btrpkt2->forwarderid-TOS_NODE_ID == 0))	//接到自己转发出的包，丢弃
				return msg;
			if(TOS_NODE_ID-1==0){
				//sink 节点的处理
				updateOCL(btrpkt2->forwarderid,btrpkt2->forwardingrate);
				dbg("ORWTossimC", "%s Sink %d %d %d\n",sim_time_string(),btrpkt2->forwarderid,btrpkt2->sourceid,btrpkt2->index);
				sendforwardrequest(btrpkt2->forwarderid,btrpkt2->sourceid);
				return msg;
			}
			//其它节点的处理
			//接到一个包，更新，存入缓冲，判断是否为duplicate，是则丢弃，否则转发，并发送转发请求(即ack)
			updateOCL(btrpkt2->forwarderid,btrpkt2->forwardingrate);
			if(!qualify(btrpkt2->edc))	//如果该节点的数据包值不值得被转发
				return msg;
			if(((flags&DATATASK) != DATATASK)&&((flags&FORWARDTASK) != FORWARDTASK)) {
				sendforwardrequest(btrpkt2->forwarderid,btrpkt2->sourceid);
				if(addtobuffer(btrpkt2) < 0)
					return msg;
				dbg("ORWTossimC", "%s RECEIVE %d %d %d\n",sim_time_string(),btrpkt2->forwarderid,btrpkt2->sourceid,btrpkt2->index);
				glbforwardmsgid = btrpkt2->sourceid;
				forwardreplicacount++;
				forward();
				call forwardpacketTimer.startPeriodic(PACKET_DUPLICATE_MILLI);
			}
			return msg;
		}
		return msg;
	}

	event void RadioControl.startDone(error_t err){
		if(err != SUCCESS)
			call RadioControl.start();
		dbg("Radio", "%s RADIO STARTED.\n",sim_time_string());
	}

	event void RadioControl.stopDone(error_t error){
		dbg("Radio", "%s RADIO STOPED.\n",sim_time_string());
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
		if(forwardreplicacount > MAX_REPLICA_COUNT){
			forwardreplicacount = 0;
			deletefrombuffer(glbforwardmsgid);
			flags &= ~FORWARDTASK;
			dbg("ORWTossimC", "%s ERROR max_replica_#_rechieved\n",sim_time_string());
			call forwardpacketTimer.stop();
		}else{
			forwardreplicacount++;
			forward();
		}
	}

	event void CTRLSender.sendDone(message_t *msg, error_t error){
		if(((flags&SLEEPALLOWED) == SLEEPALLOWED) && ((flags&DATATASK)!=DATATASK) && ((flags&FORWARDTASK)!=FORWARDTASK)){
			call wakeTimer.stop();
			if(TOS_NODE_ID !=1){
				call SeedInit.init((uint16_t)sim_time());
				call wakeTimer.startOneShot(WAKE_DELAY_MILLI+((unsigned int)call Random.rand16())%100);//重置休眠触发时钟，向后延迟一段时间
			}
		}
	}

	event message_t * CTRLReceiver.receive(message_t *msg, void *payload, uint8_t len){
		if(len == sizeof(ControlMsg)){
			//转发请求控制信息包处理
			ControlMsg* btrpkt = (ControlMsg*) payload;
			if(btrpkt->forwardcontrol == 0x1){
				//收到某个转发请求
				if(btrpkt->dstid - TOS_NODE_ID == 0){
					updateSet(btrpkt->sourceid, btrpkt->edc, btrpkt->linkq);
					//dbg("ORWTossimC", "%s Received forward request from %d with lq:%f, Stop sending MSG\n",sim_time_string(),btrpkt->sourceid,btrpkt->linkq);
					//有人转发了数据包，停止周期性发送
					if(btrpkt->msgsource - TOS_NODE_ID == 0) {		    //若为本节点产生的包被成功转发，准备下一次数据发送
						flags &= ~DATATASK;
						dbg("ORWTossimC", "%s REPLICA# %d\n",sim_time_string(),msgreplicacount);
						msgreplicacount = 0;
						call packetTimer.stop();
						call SeedInit.init((uint16_t)sim_time());
						call packetTimer.startOneShot(PACKET_PERIOD_MILLI+((unsigned int)call Random.rand16())/100);
					}else{		    //转发的包被成功转发
						deletefrombuffer(btrpkt->msgsource);
						flags &= ~FORWARDTASK;
						dbg("ORWTossimC", "%s REPLICA# %d\n",sim_time_string(),forwardreplicacount);
						forwardreplicacount = 0;
						call forwardpacketTimer.stop();
					}
					
					if((flags&SLEEPALLOWED) == SLEEPALLOWED){	
						call wakeTimer.stop();
						if(TOS_NODE_ID !=1){
							call SeedInit.init((uint16_t)sim_time());
							call wakeTimer.startOneShot(WAKE_DELAY_MILLI+((unsigned int)call Random.rand16())%100);//恢复休眠触发时钟，向后延迟一段时间
						}
					}
				}
				return msg;
			}else{
			}
			return msg;
		}
		return msg;
	}
}