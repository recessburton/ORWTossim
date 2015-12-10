/**
 Copyright (C),2014-2015, YTC, www.bjfulinux.cn
 Copyright (C),2014-2015, ENS Lab, ens.bjfu.edu.cn
 Created on  2015-12-7 14:15
 
 @author: ytc recessburton@gmail.com
 @version: 0.8
 
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
#include "queue.h"

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
	int forwardCount=0; //由本节点负责转发的数据包总数，用于计算放在包头中的forwardingrate
	message_t pkt,packet;
	NeighborMsg *forwardBuffer[MAX_NEIGHBOR_NUM];//数据包缓冲区，暂存待判定的包
	unsigned char flags;//标志位，与掩码运算可知相应位置是否置位
	volatile float nodeedc;
	volatile uint16_t index = 0;	//数据包序号
	struct forwardtasklist{  //'sys/queue.h'链表使用：http://www.thinksaas.cn/group/topic/347706/
	    int bufferindex;  
	    LIST_ENTRY(forwardtasklist)  list_entry;
	}; 
	//构造链表头
    LIST_HEAD(list_head, forwardtasklist) head;
	

/*位运算之掩码使用：
 * 打开位： flags = flags | MASK
 * 关闭位： flags = flags & ~MASK	
 * 转置位： flags = flags ^ MASK
 * 查看位： (flags&MASK) == MASK
 * */
	
	event void Boot.booted(){
		int i;
		flags = 0x0;//初始化标志位
		flags = (call Random.rand16() & MESSAGE_PRODUCE_RATIO)==0 ? (flags | MSGSENDER) : (flags & ~MSGSENDER);
		flags |= SLEEPALLOWED;		//启用休眠机制
		//flags &= ~SLEEPALLOWED;	//关闭休眠机制
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
			neighborSet[i].overheadcount = 0;
		}
		nodeedc = (TOS_NODE_ID ==1) ? 0.0f : FLT_MAX;
		//初始化buffer
		for(i=0;i<MAX_NEIGHBOR_NUM;i++)
			forwardBuffer[i] == NULL;
		//构造队列
		LIST_INIT(&head);
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
		btrpkt->edc = nodeedc;
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(ProbeMsg));
		dbg("Probe", "Probe Send done.\n");
	}
	
	task void sendMsg() {
		//周期产生数据包
		NeighborMsg * btrpkt = (NeighborMsg * )(call Packet.getPayload(&pkt, sizeof(NeighborMsg)));
		if(btrpkt == NULL)
			return;
		if((flags & DATATASK) != DATATASK){
			flags |= DATATASK;
			index++;
			dbg("ORWTossimC", "%s Create & Send NeighborMsg index %d...\n",sim_time_string(),index);
			//forwardCount++;
		}
		forwardCount++;
		btrpkt->dstid = 0xFF;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwarderid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwardingrate = getforwardingrate();
		btrpkt->edc = nodeedc;
		btrpkt->index = index;
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
		dbg("ORWTossimC", "The node EDC is %f.\n",nodeedc);
		for(i = 0;i<neighborSetSize;i++){
			neighborSet[i].use = (neighborSet[i].edc < (nodeedc - WEIGHT)) ? TRUE : FALSE;
			//dbg("ORWTossimC", "NeighborSet #%d:Node %d, EDC %f, LQ %f, is use:%d\n",i+1,neighborSet[i].nodeID,neighborSet[i].edc,neighborSet[i].p,neighborSet[i].use);
		}
	}
	
	void updateSet(uint8_t nodeid, float edc, float forwardingrate, bool isprobe){
		int i,j=1;
		if(neighborSetSize >= MAX_NEIGHBOR_NUM)
			return;
		for(i = 0;i<neighborSetSize;i++){
			if(neighborSet[i].nodeID == nodeid){
				//链路质量计算：从该节点串听到的包率/邻居包头部中的节点平均包转发率
				//其中：串听到的包率=1/串听到的包数
				if(!isprobe){
					neighborSet[i].overheadcount += 1;
					j=0;
				}else
					dbg("ORWTossimC", "is Probe!.\n");	
				neighborSet[i].p = 1.0f/(1.0f/neighborSet[i].overheadcount/forwardingrate);
				//dbg("ORWTossimC", "Update p node %d oh:%d, fc:%f.\n",nodeid,neighborSet[i].overheadcount, 1.0f/forwardingrate);
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
					if(forwardBuffer[i]==NULL)
						return -1;
					memcpy(forwardBuffer[i],neimsg,sizeof(NeighborMsg)); 
					return i;
				}
			}else if(forwardBuffer[i]->sourceid == neimsg->sourceid){
				//此buffer位置已有该节点内容
				if (forwardBuffer[i]->index == neimsg->index)
					return -1;
				else{
					memcpy(forwardBuffer[i],neimsg,sizeof(NeighborMsg)); 
					return i;
				}
			}
			//此buffer位置有其它内容，继续下一个位置的遍历
		}
		return -1;
	}
	
	void deletefrombuffer(uint8_t sourceid) {
		int i;
		struct forwardtasklist *forwardmsg = (struct forwardtasklist *)calloc(1, sizeof(struct forwardtasklist));  
		atomic {
			for(i=0;i<MAX_NEIGHBOR_NUM;i++){
				if(forwardBuffer[i] != NULL && forwardBuffer[i]->sourceid == sourceid) {
					free(forwardBuffer[i]);
					forwardBuffer[i] = NULL;
					forwardmsg->bufferindex = i;
					LIST_REMOVE(forwardmsg, list_entry);
					return;
				}
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
	
	void sendforwardrequest(uint8_t forwarderid, uint8_t msgsource) {
		ControlMsg * btrpkt = (ControlMsg * )(call Packet.getPayload(&pkt,sizeof(ControlMsg)));
		if(btrpkt == NULL)
			return;
		btrpkt->dstid = (nx_int8_t)forwarderid;
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->forwardcontrol = 0x1;
		btrpkt->msgsource = msgsource;
		dbg("ORWTossimC", "Sending ACK to %d...\n",forwarderid);
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(ControlMsg));
	}
	
	void forward() {
		struct forwardtasklist *queuedata = NULL;
		NeighborMsg *btrpkt = (NeighborMsg * )(call Packet.getPayload(&pkt,sizeof(NeighborMsg)));
		NeighborMsg *neimsg = NULL;
		LIST_FOREACH(queuedata, &head, list_entry) {
			neimsg = forwardBuffer[queuedata->bufferindex];
			if(neimsg == NULL)
				return;
			forwardCount++;
			memcpy(btrpkt, neimsg, sizeof(NeighborMsg));
			btrpkt->forwarderid    = (nx_int8_t)TOS_NODE_ID;
			btrpkt->dstid          = 0xFF;
			btrpkt->forwardingrate = getforwardingrate();
			btrpkt->edc            = nodeedc;
			if((flags&FORWARDTASK)!=FORWARDTASK) {
				flags |= FORWARDTASK;
				dbg("ORWTossimC", "%s Forwarding packet from %d, source:%d, index:%d...\n",sim_time_string(),neimsg->forwarderid, btrpkt->sourceid,btrpkt->index);
			}
			call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(NeighborMsg));
			call wakeTimer.stop();	//停止休眠，等待转发请求
		}
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

	event message_t * Receive.receive(message_t * msg, void * payload,uint8_t len) {
		/* 按照不同长度的包区分包的类型，在此处为特例，因为不是所有不同种类的包恰好都有不同的长度。
		 * 另外，在用sizeof计算结构体长度时，本应注意字节对齐问题，比如第一个成员为uint8_t，第二个成员为uint16_t，则其长度为32
		 * 但此处用到的是网络类型数据nx_，不存在这种情况，结构体在内存中存储是无空隙的。
		 * */
		int bufferindex=0;
		struct forwardtasklist *forwardmsg = NULL;
		if(((flags&SLEEPALLOWED) == SLEEPALLOWED) && ((flags&INITIALIZED) != INITIALIZED)){
			call wakeTimer.stop();
			if(TOS_NODE_ID !=1)
				call wakeTimer.startOneShot(WAKE_DELAY_MILLI);//重置休眠触发时钟，向后延迟一段时间
		}
		if(len == sizeof(ProbeMsg)) {
			//probe 探测包处理
			ProbeMsg* btrpkt1 = (ProbeMsg*) payload;
			if(btrpkt1->dstid - TOS_NODE_ID == 0) {
				//接到自己probe包的回包
				updateSet(btrpkt1->sourceid, btrpkt1->edc, 1.0f, TRUE);
				dbg("Probe", "Received ACK from %d.\n",btrpkt1->sourceid);
				flags |= INITIALIZED;
				if((flags&SLEEPALLOWED) == SLEEPALLOWED){
					call wakeTimer.stop();
					if(TOS_NODE_ID !=1)
						call wakeTimer.startOneShot(WAKE_DELAY_MILLI);//重置休眠触发时钟，向后延迟一段时间
				}
				return msg;
			}
			//若EDC还没初始化，则不做都不做。
			if((flags&INITIALIZED) != INITIALIZED)
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
		if(((flags&INITIALIZED) != INITIALIZED) && (TOS_NODE_ID-1!=0))
			return msg;
		if(len == sizeof(NeighborMsg)) {
			//正常数据包处理
			NeighborMsg * btrpkt2 = (NeighborMsg *) payload;
			if((btrpkt2->sourceid-TOS_NODE_ID == 0)||(btrpkt2->forwarderid-TOS_NODE_ID == 0))	//接到自己转发出的包，丢弃
				return msg;
			if(TOS_NODE_ID-1==0){
				//sink 节点的处理
				dbg("ORWTossimC", "%s Sink Node received a packet from %d,source:%d,index:%d.\n",sim_time_string(),btrpkt2->forwarderid,btrpkt2->sourceid,btrpkt2->index);
				sendforwardrequest(btrpkt2->forwarderid,btrpkt2->sourceid);
				return msg;
			}
			//其它节点的处理
			//接到一个包，更新，存入缓冲，判断是否为duplicate，是则丢弃，否则转发，并发送转发请求(即ack)
			if(qualify(btrpkt2->forwarderid))	//如果该节点是本节点的下一跳，则无需做任何处理（不用为它转发数据包）
				return msg;
			if((bufferindex = addtobuffer(btrpkt2))>=0){
				updateSet(btrpkt2->forwarderid, btrpkt2->edc, btrpkt2->forwardingrate,FALSE);
				sendforwardrequest(btrpkt2->forwarderid,btrpkt2->sourceid);
				//加入转发列表
				forwardmsg = (struct forwardtasklist *)calloc(1, sizeof(struct forwardtasklist));  
    			forwardmsg->bufferindex = bufferindex;
    			LIST_INSERT_HEAD(&head, forwardmsg, list_entry); 
				//转发
				dbg("ORWTossimC", "Received a packet from %d, source:%d, index:%d, sending ack & forwarding...\n",btrpkt2->forwarderid,btrpkt2->sourceid,btrpkt2->index);
				forward();
				call forwardpacketTimer.startPeriodic(PACKET_DUPLICATE_MILLI);
			}
			return msg;
		}
		if(len == sizeof(ControlMsg)){
			//转发请求控制信息包处理
			ControlMsg* btrpkt3 = (ControlMsg*) payload;
			if(btrpkt3->forwardcontrol == 0x1){
				//收到某个转发请求
				if(btrpkt3->dstid - TOS_NODE_ID == 0){
					dbg("ORWTossimC", "Received forward request from %d, Stop sending MSG\n",btrpkt3->sourceid);
					//有人转发了数据包，停止周期性发送
					if((flags&DATATASK)==DATATASK) {		    //若为本节点产生的包被成功转发，准备下一次数据发送
						flags &= ~DATATASK;
						call packetTimer.stop();
						call packetTimer.startOneShot(PACKET_PERIOD_MILLI);
					}
					if((flags&FORWARDTASK)==FORWARDTASK) {		//转发的包被成功转发
						deletefrombuffer(btrpkt3->msgsource);
						if (LIST_EMPTY(&head)){
							flags &= ~FORWARDTASK;
							call forwardpacketTimer.stop();
						}
						
					}
					if((flags&SLEEPALLOWED) == SLEEPALLOWED){	
						call wakeTimer.stop();
						if(TOS_NODE_ID !=1)
							call wakeTimer.startOneShot(WAKE_DELAY_MILLI);//恢复休眠触发时钟，向后延迟一段时间
					}
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
		forward();
	}

}