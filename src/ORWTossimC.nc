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
#include <stdlib.h>
#include <float.h>
#include <assert.h>
#include "simclist.h"
#include "ORWTossim.h"
#include "AM.h"
#include "Mask.h"
#include "TossimRadioMsg.h"

module ORWTossimC @safe(){
	uses interface Boot;
	uses interface Timer<TMilli> as packetTimer;
	uses interface Timer<TMilli> as forwardPacketTimer;
	uses interface Timer<TMilli> as wakeTimer;
	uses interface Timer<TMilli> as sleepTimer;
	uses interface Timer<TMilli> as forwardPauseTimer;
	uses interface ParameterInit<uint16_t> as SeedInit;
	uses interface Packet;
	uses interface AMSend;
	uses interface Random;
	uses interface Receive;
	uses interface SplitControl as RadioControl;
	uses interface PacketAcknowledgements as ACKs;
	uses interface NeighborDiscovery;
}

implementation {
	list_t neighborSet;//NeighborSet 邻居节点集合
	int forwardreplicacount=0;//转发重复计数
	int msgreplicacount=0;//数据包发送重复计数
	int WAKE_PERIOD_MILLI=WAKE_PERIOD_MILLI_BASE;//节点休眠周期
	message_t pkt;
	unsigned char flags;//标志位，与掩码运算可知相应位置是否置位
	volatile float nodeedc;
	uint16_t index = 0;	//数据包序号
	uint16_t sendingdsn = 0;
	bool judge = FALSE;
	bool sinkacked = FALSE;
	bool isForwardRequest = FALSE;
	uint8_t lastforwarderid = 0;
	volatile bool shouldAck=TRUE;
	DataPayload * forwardBuffer = NULL;//作为下游节点暂存刚接到拟转发的包
	uint16_t currentForwardingDsn = 0;//当前正在转发或正在请求中的包识别号
	int vacantAckOffset = 0;
	int energy = 0;//节点能耗，每收发一次+1

	list_t ocl;//overheardcountlistnode表，overheard计数表，记录overheard到某个节点的次数以及其中转发的次数，用于计算Linkquality

	/**
	 * 获取消息包的头部.
	 *
	 * 用于TOSSIM仿真环境中，获取给定消息包的头部，返回包装成TOSSIM消息包的头部.
	 *
	 * @param amsg   message_t类型的消息包
	 * @return      返回tossim_header_t类型的消息包头部指针
	 */
	inline tossim_header_t* getPktHeader(message_t* amsg) {
    	return (tossim_header_t*)(amsg->data - sizeof(tossim_header_t));
    }

    /**
	 * 获取消息包的metadata域.
	 *
	 * 用于TOSSIM仿真环境中，获取给定消息包的metadata，返回包装成TOSSIM消息包的metadata.
	 *
	 * @param amsg   message_t类型的消息包
	 * @return      返回tossim_metadata_t类型的消息包metadata指针
	 */
	inline tossim_metadata_t* getPktMetadata(message_t* amsg) {
    	return (tossim_metadata_t*)(&amsg->metadata);
	}

	/**
	 * 获取包的源地址.
	 *
	 * 从接到的数据包头部中找出包的源地址（发送方）.
	 *
	 * @param msg   数据包指针
	 * @return    发送方节点号
	 *
	 * @see	_getHeader()
	 */
	inline uint8_t getPktMessageSource(message_t* msg){
		tossim_header_t* header = getPktHeader(msg);
		return (uint8_t)header->src;
	}

	/**
	 * 将接收到的消息包加入消息缓存区.
	 *
	 * 这里的Buffer暂时只有一个包的空间.
	 *
	 * @param data   需要加入缓存的数据包
	 * @return      成功加入缓存返回1，否则返回-1
	 *
	 * @see element_comparator()
	 */
	int addToBuffer(const DataPayload* data);

	/**
	 * 对比两个DataPayload（转发中的数据包），是否出自同一节点的同一数据包.
	 *
	 * 依次比较两个给定的包识别符，相同则认为是同一个数据包.
	 *
	 * @param nm1   第一个数据包中的识别号
	 * @param nm2   第二个数据包中的识别号
	 * @return      相同则返回TRUE，否则返回FALSE
	 */
	inline bool cmpDataPayload(const uint8_t nm1, const uint8_t nm2);

	/**
	 * 两个NeighborSet结构体的比较函数.
	 *
	 * 比较两个NeighborSet结构体中edc成员的大小，用于NeighborSet列表的排序.
	 *
	 * @param a   待比较的第一个结构体
	 * @param b   待比较的第二个结构体
	 * @return    a>b则返回-1，否则返回1
	 */
	int cmpNeighborSetByEDC(const void* a, const void* b);

	/**
	 * 构造数据负载包中的数据.
	 *
	 * 模拟应用层数据负载的产生，填入例如包序号等数据.
	 *
	 * @param priority   是否产生高优先级包
	 *
	 * @see convertEdc2uint()
	 */
	void constructData(bool priority);

	/**
	 * 构造要转发的数据包中的数据.
	 *
	 * 将接收到的数据包从缓存取出，修改包中的信息，准备转发.
	 *
	 * @param priority   是否产生高优先级包
	 *
	 * @see convertEdc2uint()
	 */
	void constructForwardData(bool priority);

	/**
	 * 将EDC值从float转换成uint8_t.
	 *
	 * 根据ORW,取edc为0.0-25.5,step 0.1，将其扩大10倍，变成整数，便于填入数据包头部.
	 *
	 * @param edc   float类型的节点edc值
	 * @return      uint8_t类型的节点edc值
	 *
	 * @see resumeEdc()
	 */
	inline uint8_t convertEdc2uint(float edc);

	/**
	 * 将链路质量值从float转换成uint8_t.
	 *
	 * 将原值乘以255从原有的[0,1]映射到[0,255].
	 *
	 * @param linkq   float类型的节点linkq值
	 * @return      uint8_t类型的节点linkq值
	 *
	 * @see resumeLinkQ()
	 */
	inline uint8_t convertLinkQ2uint(float linkq);

	/**
	 * 根据nodeid在邻居集（neighborSet）中查找该数据包.
	 *
	 * 从邻居集中根据nodeid查找相应的一个数据包（NeighborSet），并返回这个结构体.
	 *
	 * @param nodeid   需要取回数据包的nodeid
	 * @return      返回相应nodeid的NeighborSet结构体，否则返回NULL
	 *
	 * @see matchIDinNeighborSet()
	 */
	NeighborSet* findinNeighborSet(uint8_t nodeid);

	/**
	 * 根据nodeid在OCL中查找该数据包.
	 *
	 * 从OCL(OverheardCountList)中根据nodeid查找相应的一个数据包(overheardcountlistnode)，并返回这个结构体.
	 *
	 * @param nodeid   需要取回数据包的nodeid
	 * @return      返回相应nodeid的overheardcountlistnode结构体，否则返回NULL
	 *
	 * @see matchIDinOCL()
	 */
	overheardcountlistnode* findinOCL(uint8_t nodeid);

	/**
	 * 获取本节点转发率.
	 *
	 * 获取根据ORW文中给出的公式计算得出的本节点转发率.
	 *
	 * @return  本节点转发率
	 */
	inline float getForwardingRate();

	/**
	 * 根据nodeid获取该节点与本节点间链路质量.
	 *
	 * 从OCL(OverheardCountList)中根据nodeid查找相应的一个数据包(overheardcountlistnode)，
	 * 并获取该数据包中节点链路质量的值，此处的链路质量是ORW文中所定义的，而非熟识的LQ.
	 *
	 * @param nodeid   需要获取链路质量节点的nodeid
	 * @return      返回相应nodeid节点与本节点所构成链路的链路质量
	 *
	 * @see findinOCL()
	 */
	float getLinkQ(uint8_t nodeid);

	/**
	 * 判断是否需要回复ack.
	 *
	 * 根据数据包中的唯一识别符DSN及包发送者的id判断是否需要回复ack.
	 *
	 * @param msg   数据包
	 * @return      需要返回ack返回TRUE，否则返回FALSE
	 *
	 * @see getPktMetadata()
	 * @see setVacantAck()
	 * @see endForwardTask()
	 * @see cmpDataPayload()
	 * @see clearBuffer()
	 */
	bool isAckNeeded(message_t* msg);

	/**
	 * 判断该ack的事件触发是否是我们关注的消息类型.
	 *
	 * 在多个数据类型需要ack的使用场景，比如包含邻居探测包和普通数据包两种类型的AM消息使用场景，
	 * 由于ack收发是绑定在radiocontrol的，所以触发事件时，多种数据包的ack事件会被同时触发，
	 * 所以需要利用消息类型（am_id_t，AMSenderC中指定的包类型号）来判断是否是自己类型的包触发的.
	 *
	 * @param msg   AM消息包
	 * @return      是否Data类型的数据包
	 */
	bool isDataAck(message_t* msg);

	/**
	 * 在NeighborSet中判断两个数据包是否为同一节点发出的包.
	 *
	 * 比较两个NeighborSet结构体的nodeid成员是否相同.
	 *
	 * @param a   待比较的第一个结构体
	 * @param b   待比较的第二个结构体
	 * @return    如果相同返回0，否则返回1（注意，如果用在标准GCC编译器，则需要相反的值，相同返1，否则返0）
	 */
	int matchIDinNeighborSet(const void* a, const void* b);

	/**
	 * 在OCL中判断两个数据包是否为同一节点发出的包.
	 *
	 * 比较两个overheardcountlistnode结构体的nodeid成员是否相同.
	 *
	 * @param a   待比较的第一个结构体
	 * @param b   待比较的第二个结构体
	 * @return    如果相同返回0，否则返回1（注意，如果用在标准GCC编译器，则需要相反的值，相同返1，否则返0）
	 */
	int matchIDinOCL(const void* a, const void* b);

	/**
	 * 标记以不接收数据包.
	 *
	 * 节点在ack回复时回复的是空ack（形式上的），所以标记应用层不需要接收.
	 */
	inline void noACK();

	/**
	 * 根据本节点的edc值判断接到的包是否值得被转发.
	 *
	 * 根据ORW文中，从本节点edc中减去WEIGHT值，与该节点的edc比较，从而决定是否向下转发该数据包.
	 * 实际上是判断本节点是否在位置上处于“下游”.
	 *
	 * @param edc   带判断上游节点的edc值
	 * @return      可以转发则返回TRUE，否则返回FALSE
	 */
	inline bool qualify(float edc);

	/**
	 * 将EDC值从uint8_t恢复成float.
	 *
	 * 将整数形式的edc值恢复float类型，此处仅将其除以10得到.
	 *
	 * @param intedc   uint8_t类型的节点edc值
	 * @return float类型的节点edc值
	 *
	 * @see convertEdc2uint()
	 */
	inline float resumeEdc(uint8_t intedc);

	/**
	 * 将链路质量值从uint8_t恢复成float.
	 *
	 * 将原值除以255来映射回[0,1].
	 *
	 * @param intlinkq   uint8_t类型的节点链路质量值
	 * @return float类型的节点链路质量值
	 *
	 * @see convertLinkQ2uint()
	 */
	inline float resumeLinkQ(uint8_t intlinkq);

	/**
	 * 构造空的ack包.
	 *
	 * 构造一个空ack包，即只是形式上发送ack，接收方接到该ack后直接丢弃.
	 *
	 * @param msg   数据包指针
	 *
	 * @see noACK()
	 */
	void setVacantAck(message_t* msg);

	/**
	 * 更新OCL列表.
	 *
	 * 根据所给的nodeid，找到OCL列表中的位置（如果没有则加入），并按照ORW，根据节点转
	 * 发率(forwardingrate)更新.
	 *
	 * @param nodeid   需要更新的节点id
	 * @param forwardingrate   需要更新节点的转发率
	 *
	 * @see findinOCL()
	 */
	void updateOCL(uint8_t nodeid, int method);

	/**
	 * 更新邻居节点集合中对应节点的参数.
	 *
	 * 根据nodeid在邻居集中找到该节点(如果没有则新加)，更新其edc和linkq，然后重新按edc排序（升序）.
	 *
	 * @param nodeid   需要更新的节点id
	 * @param edc   需更新节点的edc
	 * @param linkq   需更新节点的linkq
	 *
	 * @see findinNeighborSet()
	 */
	void updateNeighborSet(uint8_t nodeid, float edc, float linkq);



	/**
	 * 清空消息缓存区.
	 *
	 * 清空缓冲区.
	 */
	task void clearBuffer() {
		if(forwardBuffer){
			free(forwardBuffer);
			forwardBuffer = NULL;
		}
	}

	/**
	 * 结束产生数据包的任务.
	 *
	 * 结束当次发送数据包的任务，如果是数据源，则定时启动下一次发送.
	 */
	task void endDataTask(){
		judge = FALSE;
		UNSETFLAG(flags, DATATASK);
		msgreplicacount = 0;
		sinkacked = FALSE;
		call packetTimer.stop();
		call SeedInit.init((uint16_t)sim_time());
		call packetTimer.startOneShot(PAYLOAD_PERIOD_MILLI+((unsigned int)call Random.rand16())/100+TOS_NODE_ID%10);
	}

	/**
	 * 结束当前数据包转发任务.
	 *
	 * 结束当次数据包的转发.
	 *
	 * @see clearBuffer()
	 */
	task void endForwardTask(){
		judge = FALSE;
		post clearBuffer();
		UNSETFLAG(flags, FORWARDTASK);
		forwardreplicacount = 0;
		currentForwardingDsn = 0;
		lastforwarderid = 0;
		sinkacked = FALSE;
		call forwardPacketTimer.stop();
		call forwardPauseTimer.stop();
		if(!call wakeTimer.isRunning())
			signal wakeTimer.fired();
	}

	/**
	 * 向下游转发缓存中的数据包.
	 *
	 * 判断是否超过最大转发次数，如果没有，从forwardBuffer中获取数据包，随机休眠一段时间，并将其发送.
	 *
	 * @see endForwardTask()
	 * @see constructForwardData()
	 */
	task void forward() {
		bool priority = FALSE;
		bool readyToEndForwardTask = FALSE;

		if(!call wakeTimer.isRunning()){//节点已经用完醒了的时间，立刻休眠
			post endForwardTask();
			signal wakeTimer.fired();
			return;
		}

		do{
			if(forwardreplicacount > MAX_REPLICA_COUNT){
				if(judge){
					judge = FALSE;
					dbg("ORWTossimC", "%s ERROR max_replica_#_reached while judging\n",sim_time_string());
					priority = TRUE;
					readyToEndForwardTask = TRUE;
					break;
				}else{
					dbg("ORWTossimC", "%s ERROR max_replica_#_reached due to no-ack\n",sim_time_string());
				}
				post endForwardTask();
				return;
			}
		}while(0);

		if(sinkacked){
			priority = TRUE;
			readyToEndForwardTask = TRUE;
			dbg("ORWTossimC", "%s REPLICA# %d\n",sim_time_string(),forwardreplicacount);
		}
		constructForwardData(priority);

		if(readyToEndForwardTask)
			post endForwardTask();
		vacantAckOffset = 0;
		dbg("ORWTossimC", "%s forward.\n",sim_time_string(),forwardreplicacount);
		call ACKs.requestAck(&pkt);
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(DataPayload));
	}

	/**
	 * 发送模拟的数据负载包.
	 *
	 * 只有被随机指定为数据源节点（PAYLOADSOURCE位置1）才能发送数据负载.
	 *
	 * @see endDataTask()
	 * @see constructData()
	 */
	task void sendDataPayload() {
		//产生周期性的数据，用于模拟数据负载
		bool priority = FALSE;
		bool readyToEndDataTask = FALSE;

		do{//此处使用do while0，方便执行时跳出，避免使用goto语句
			if(msgreplicacount > MAX_REPLICA_COUNT){//超过最大重复发送次数限制
				if(judge){
					//！！！！！！存在竞争者，此时如果结束数据包的发送，那么会导致所有竞争者认为自己取得转发权！！！！！
					//（**************************待解决****************************）
					//此处采取方案：发送一个高优先级包，是的所有竞争者都不接收
					//备用方案一：选取竞争者中edc最小的，指派转发者
					//备用方案二：在每次重复包发送过程中，都丢弃一个edc最大的，使每次都有落选的
					judge = FALSE;
					dbg("ORWTossimC", "%s ERROR reach_Max_replica while judging\n",sim_time_string());
					priority = TRUE;//准备发送高优先级包，让所有转发者打消转发的意图
					readyToEndDataTask = TRUE;//此处不能直接post结束任务，因为DATATASK位还需要在后面用到。只能先标记，准备post
					break;//跳出do while，使得可以再发送一个高优先级包
				}else{
					dbg("ORWTossimC", "%s ERROR reach_Max_replica due to no-ack\n",sim_time_string());
				}
				post endDataTask();
				return;
			}
		}while(0);

		//sink节点已经发送了ack
		if(sinkacked){
			priority = TRUE;
			readyToEndDataTask = TRUE;
			dbg("ORWTossimC", "%s REPLICA# %d\n",sim_time_string(),msgreplicacount);
		}
		constructData(priority);

		msgreplicacount += 1;

		if(readyToEndDataTask)
			post endDataTask();

		dbg("ORWTossimC", "send data\n");

		vacantAckOffset = 0;
		call ACKs.requestAck(&pkt);
		call AMSend.send(AM_BROADCAST_ADDR, &pkt, sizeof(DataPayload));
	}

	/**
	 * 开始节点周期性的Duty Cycle.
	 *
	 * 如果开启了Duty Cycle机制（SLEEPALLOWED被置位），则开始.
	 */
	task void startDutyCycle(){
		if(TESTFLAG(flags, SLEEPALLOWED)){
			call wakeTimer.stop();
			call SeedInit.init((uint16_t)sim_time());
			RANDOMDELAY(((unsigned int)call Random.rand16())%1000+TOS_NODE_ID%10);
			call wakeTimer.startOneShot(WAKE_PERIOD_MILLI);
			if(TESTFLAG(flags, PAYLOADSOURCE)){
				signal packetTimer.fired();
			}
		}
	}

	/**
	 * 开始转发数据包前的等待.
	 *
	 * 启动转发前的等待，为了判断是否接到了重复包，如果接到了，则认为存在竞争，重新发送请求；
	 * 如果没有收到，则说明本节点获得了转发权.
	 */
	task void startForwardRequestPause(){
		isForwardRequest = TRUE;
		call forwardPauseTimer.startOneShot(160);
	}

	/**
	 * 更新节点的EDC值.
	 *
	 * 根据ORW文中的方式，根据转发集，计算并更新本节点的EDC值.
	 */
	task void updateEDC(){
		//根据文中的公示计算EDC值
		int i;
		float EDCpart1 = 0.0f;
		float EDCpart2 = 0.0f;
		float currentedc = FLT_MAX;
		int maxForwarderNo = 0;
		bool cal = TRUE;
		NeighborSet *neighbornode = NULL;
		int neighborsize = list_size(&neighborSet);
		nodeedc = FLT_MAX;
 		atomic {
	 		for(i = 0;i<neighborsize;i++){
				currentedc = FLT_MAX;
				if(cal){
					neighbornode = (NeighborSet*)list_get_at(&neighborSet, i);
					EDCpart1 += neighbornode->p;
					EDCpart2 += neighbornode->p * neighbornode->edc;
					assert(EDCpart1 > 0);
					currentedc = 1.0f/EDCpart1 + EDCpart2/EDCpart1 + WEIGHT;
				}
				if(currentedc < (nodeedc - WEIGHT)){
					nodeedc = currentedc;
					neighbornode->use = TRUE;
					maxForwarderNo = i+1;
				}else{
					cal = FALSE;
					neighbornode->use = FALSE;
				}
				dbg("Neighbor", "NeighborSet #%d:Node %d, EDC %f, LQ %f, is use:%d\n",i+1,neighbornode->nodeid,neighbornode->edc,neighbornode->p,neighbornode->use);
			}
		}
		dbg("Neighbor", "%s Node EDC %f, maxForwarderNo %d.\n",sim_time_string(),nodeedc,maxForwarderNo);
		neighbornode = NULL;
	}


	event void Boot.booted(){
		flags = 0x0;//初始化标志位
		call SeedInit.init((uint16_t)sim_time());
		flags = ((unsigned int)(call Random.rand16())%100)/PAYLOAD_PRODUCE_RATIO==0 ? (flags | PAYLOADSOURCE) : (flags & ~PAYLOADSOURCE);
		SETFLAG(flags, SLEEPALLOWED);		//启用休眠机制
		//UNSETFLAG(flags, SLEEPALLOWED);	//关闭休眠机制
		WAKE_PERIOD_MILLI = WAKE_PERIOD_MILLI_BASE + (call Random.rand16())%100;//初始化随机休眠周期
		call RadioControl.start();
		if(TOS_NODE_ID == 1){
			SETFLAG(flags, INITIALIZED);	//sink节点一开始就是初始化的
			UNSETFLAG(flags, PAYLOADSOURCE);//sink不能作为数据源
		}
		if(TESTFLAG(flags, PAYLOADSOURCE)){
			dbg("Bootinfo", "is DataSource, %s.\n", sim_time_string());
		}
		//初始化forwarder节点集合
		list_init(&neighborSet);
		nodeedc = (TOS_NODE_ID ==1) ? 0.0f : FLT_MAX;
		list_init(&ocl);
	}

	void constructData(bool priority){
		DataPayload * btrpkt = NULL;
		message_t* pktp = &pkt;
		tossim_metadata_t* metadata = getPktMetadata(pktp);
		btrpkt = (DataPayload * )(call Packet.getPayload(&pkt, sizeof(DataPayload)));
		if(btrpkt == NULL)
			return;
		if(!TESTFLAG(flags, DATATASK)){
			SETFLAG(flags, DATATASK);
			index += 1;
			sendingdsn = (uint8_t)(sim_time()*TOS_NODE_ID);//产生唯一的数据包识别号
			dbg("ORWTossimC", "%s CREATE %d\n",sim_time_string(),index);
		}
		if(priority)
			metadata->ackNode = 0xFA;
		else
			metadata->ackNode = 0;
		metadata->other1 = convertEdc2uint(nodeedc);
		metadata->other2 = sendingdsn;
		dbg("ORWTossimC", "Packet DSN:%d\n",sendingdsn);
		btrpkt->sourceid = (nx_int8_t)TOS_NODE_ID;
		btrpkt->index = index;
		btrpkt->hops = 0;
		sinkacked = FALSE;
		return;
	}

	int cmpNeighborSetByEDC(const void *a ,const void *b){
		//使用simclist库中list_sort()函数所用的比较函数element_comparator
		return (*(NeighborSet *)a).edc > (*(NeighborSet *)b).edc ? -1 : 1;
	}

	int matchIDinNeighborSet(const void *el, const void *indicator){
		return (*(NeighborSet *)el).nodeid == *(int*)indicator ? 1 : 0;
	}

	NeighborSet* findinNeighborSet(uint8_t nodeiduint){
		NeighborSet *listnode = NULL;
		int nodeid = (int)nodeiduint;
		list_attributes_seeker(&neighborSet, matchIDinNeighborSet);//指定查找匹配函数
		listnode = list_seek(&neighborSet, &nodeid);
		return listnode;
	}

	void updateNeighborSet(uint8_t nodeid, float edc, float linkq){
		NeighborSet* neighbornode = findinNeighborSet(nodeid);
		if(!neighbornode){
			if(list_size(&neighborSet)>255)
				return;
			neighbornode = (NeighborSet*)malloc(sizeof(NeighborSet));
			neighbornode->nodeid = nodeid;
			list_append(&neighborSet, neighbornode);
		}
		neighbornode->edc = edc;
		neighbornode->p = linkq;
		//按照EDC值升序排序
		list_attributes_comparator(&neighborSet, cmpNeighborSetByEDC);//指定比较函数
		list_sort(&neighborSet, 1);//从小到大排序
		if(TOS_NODE_ID != 1)
			post updateEDC();
		neighbornode = NULL;
		return;
	}

	event void AMSend.sendDone(message_t * msg, error_t err) {
		int acks=0;
		energy++;
		if(energy % 10 == 0)
			dbg("Radio", "%s ENERGY %d.\n",sim_time_string(), energy);
		acks = (call ACKs.wasAcked(msg)) - vacantAckOffset;
		if(acks > 1){
			//存在多个ack,重新发送数据包来重新发起竞争。(*如果超过最大重复次数，则指定edc最小者转发该数据包。待定)
			if(sinkacked){
				dbg("ORWTossimC", "%s REPLICA# %d\n",sim_time_string(),(msgreplicacount|forwardreplicacount));
			}
			dbg("ORWTossimC", "%s Acked from %d nodes\n",sim_time_string(),acks);
			judge = TRUE;
			if(TESTFLAG(flags, DATATASK))
				post sendDataPayload();
			else if(TESTFLAG(flags, FORWARDTASK))
				post forward();
			else
				return;
		}else if(acks == 1){
			//没有竞争，发送成功
			if(TESTFLAG(flags, DATATASK)){
				dbg("ORWTossimC", "%s REPLICA# %d\n",sim_time_string(),msgreplicacount);
				post endDataTask();
			}else if(TESTFLAG(flags, FORWARDTASK)){
				dbg("ORWTossimC", "%s REPLICA# %d\n",sim_time_string(),forwardreplicacount);
				post endForwardTask();
			}else{
				return;
			}
		}else{
			//没有ack，如果没有超过最大重发次数则启动重复定时器准备重发，否则判定丢包
			dbg("ORWTossimC", "%s NO ACK\n",sim_time_string());
			judge = FALSE;
			if(TESTFLAG(flags, DATATASK))
				call packetTimer.startOneShot(PACKET_DUPLICATE_MILLI);
			else if(TESTFLAG(flags, FORWARDTASK))
				call forwardPacketTimer.startOneShot(PACKET_DUPLICATE_MILLI);
			else
				return;
		}
		vacantAckOffset = 0;
	}

	int addToBuffer(const DataPayload* data) {
		if(forwardBuffer)
			return -1;
		forwardBuffer = (DataPayload*)malloc(sizeof(DataPayload));
		memcpy(forwardBuffer, data, sizeof(DataPayload));
		return 1;
	}

	int matchIDinOCL(const void *el, const void *indicator){
		//使用simclist库中的比较函数element_comparator，用于在队列里查找
		return (*(overheardcountlistnode *)el).nodeid == *(int*)indicator ? 1 : 0;
	}

	overheardcountlistnode *findinOCL(uint8_t nodeiduint){
		overheardcountlistnode *listnode = NULL;
		int nodeid = (int)nodeiduint;
		list_attributes_seeker(&ocl, matchIDinOCL);
		return list_seek(&ocl, &nodeid);
	}

	void updateOCL(uint8_t nodeid, int method){
		//method为0表示overheard增加一次，1表示forward增加一次
		overheardcountlistnode *listnode = NULL;
		if(method != 0 && method != 1)
			return;
		listnode = findinOCL(nodeid);
		if(!listnode){//OCL表中没有，插入
			listnode = (overheardcountlistnode*)malloc(sizeof(overheardcountlistnode));
			listnode->nodeid = nodeid;
			listnode->overheardcount = 1;
			listnode->forwardcount = method;
			list_append(&ocl,listnode);
		} else {//已在OCL表中
			listnode->overheardcount += (int)(method^1);
			listnode->forwardcount += method;
		}
	}

	float getLinkQ(uint8_t nodeid){
		overheardcountlistnode *listnode = NULL;
		listnode = findinOCL(nodeid);
		if(TOS_NODE_ID == 1)
			return 1.0f;
		if(listnode){
			if(listnode->overheardcount == 1 && listnode->forwardcount == 0)
				return 1.0f;
			return (listnode->forwardcount*1.0f)/(listnode->overheardcount*1.0f);
		}else{
			return 0.0f;
		}
	}

	void constructForwardData(bool priority){
		DataPayload *btrpkt = (DataPayload * )(call Packet.getPayload(&pkt,sizeof(DataPayload)));
		DataPayload *datatoforward = NULL;
		message_t* pktp = &pkt;
		tossim_metadata_t* metadata = getPktMetadata(pktp);

		datatoforward = forwardBuffer;
		if(datatoforward == NULL)
			return;
		forwardreplicacount++;
		memcpy(btrpkt, datatoforward, sizeof(DataPayload));

		metadata->other1 = convertEdc2uint(nodeedc);
		//metadata->other2 中的包识别号保持原有。
		if(priority)
			metadata->ackNode = 0xFA;//高优先级包，只能sink接收，意在告诉其它节点该包竞争者中存在sink
		else
			metadata->ackNode = 0;
		call SeedInit.init((uint16_t)sim_time());
		RANDOMDELAY(((unsigned int)call Random.rand16())%100+TOS_NODE_ID%10);
		if((!TESTFLAG(flags, FORWARDTASK)) && (!priority)) {
			SETFLAG(flags, FORWARDTASK);
			updateOCL(lastforwarderid, 1);
			dbg("ORWTossimC", "%s FORWARD %d %d %d\n",sim_time_string(), btrpkt->sourceid,btrpkt->index,btrpkt->hops);
		}
	}

	inline bool qualify(float edc) {
		//判断接到的包需不需要被转发，本节点比转发一次的代价小，则转发；否则，由本节点不合适转发
		return (nodeedc <= (edc - WEIGHT));
	}

	inline bool cmpDataPayload(const uint8_t nm1, const uint8_t nm2){
		return (nm1 == nm2);
	}

	bool isAckNeeded(message_t* msg){
		tossim_metadata_t* metadata = getPktMetadata(msg);
		uint8_t packetDsn = 0;
		packetDsn = metadata->other2;
		if(TOS_NODE_ID == 1)
			return TRUE;
		//所接到的包为高优先级包，说明该包是用于包含sink的多个竞争者再次竞争的包，只能由sink接收，无权转发，丢弃
		//如果本节点就是sink节点，那么收到0xFA的包说明之前已接过相同的包，无需再接收。
		//综上，无论是sink或是其它节点，0xFA的包直接丢弃
		if(metadata->ackNode == 0xFA){
			dbg("ORWTossimC", "rcv 0xFA pkt. descard\n");
			setVacantAck(msg);
			if(TOS_NODE_ID == 1)
				return FALSE;
			//结束forward.
			post endForwardTask();
			return FALSE;
		}
		//若EDC还没初始化或该节点的数据包值不值得被转发，则不回复ack（实际上是回复了，但是接受ack的一方不计入ack总数）。
		if((!TESTFLAG(flags, INITIALIZED)) || (!qualify(resumeEdc(metadata->other1)))){
			setVacantAck(msg);
			return FALSE;
		}
		if((!TESTFLAG(flags, DATATASK))&&(!TESTFLAG(flags, FORWARDTASK))) {

			if(!forwardBuffer){
				;//仅此一个入口向上进入应用层。
			}else if (cmpDataPayload(currentForwardingDsn, packetDsn)){
				//接到完全相同的duplicate包，则说明正在进行forward竞争，再次尝试转发请求
				call forwardPauseTimer.stop();
				dbg("ORWTossimC", "%s JUDGING...RESEND REQUEST\n", sim_time_string());
				return FALSE;
			}else{
				dbg("ORWTossimC", "other error, currentF:%d. descard\n", currentForwardingDsn);
				post clearBuffer();
				setVacantAck(msg);
				return FALSE;
			}
			currentForwardingDsn = packetDsn;
			return TRUE;
		}
		setVacantAck(msg);
		return FALSE;
	}

	event message_t * Receive.receive(message_t * msg, void * payload, uint8_t len) {//用于接收上一跳发来的信息，作为下游节点时触发
		uint8_t forwarderid = getPktMessageSource(msg);
		DataPayload * btrpkt = (DataPayload *) payload;

		energy++;
		if(energy % 10 == 0)
			dbg("Radio", "%s ENERGY %d.\n",sim_time_string(), energy);
		shouldAck = TRUE;
		if(len == sizeof(DataPayload)) {
			{//=====================是否需要回复ack的判断处理，注意，先触发reveive再触发prepareAckAddtionalMsg=========
				if(!isAckNeeded(msg)){
					return msg;
				}
			}//=====================================END===========================================
			{//================================应用层数据包的处理=================================
				if((btrpkt->sourceid-TOS_NODE_ID == 0)||(forwarderid-TOS_NODE_ID == 0))	//接到自己转发出的包，丢弃
					return msg;
				btrpkt->hops += 1;
				if(TOS_NODE_ID-1 == 0){
					//sink 节点的处理
					updateOCL(forwarderid ,1);
					dbg("ORWTossimC", "%s Sink %d %d %d %d\n",sim_time_string(),forwarderid,btrpkt->sourceid,btrpkt->index,btrpkt->hops);
					return msg;
				}
				//其它节点的处理
				//接到一个包，更新OCL，判断是否为duplicate，是则继续发送转发请求，否则加入缓存并发转发请求(即ack)
				updateOCL(forwarderid, 0);
				lastforwarderid = forwarderid;
				if(addToBuffer(btrpkt) < 0)
					return msg;
				dbg("ORWTossimC", "%s RECEIVE %d %d %d\n",sim_time_string(),forwarderid,btrpkt->sourceid,btrpkt->index);
			}//=======================================END===========================================
		}
		return msg;
	}

	event void RadioControl.startDone(error_t err){
		if(err != SUCCESS){
			call RadioControl.start();
			return;
		}
		call NeighborDiscovery.startNeighborDiscover();
		if(TESTFLAG(flags, INITIALIZED))
			dbg("Radio", "%s RADIO STARTED.\n",sim_time_string());
	}

	event void RadioControl.stopDone(error_t error){
		dbg("Radio", "%s RADIO STOPED.\n",sim_time_string());
	}


	event void wakeTimer.fired(){//唤醒时长到，节点进入休眠
		if(TOS_NODE_ID == 1)//sink节点不休眠
			return;
		if(isForwardRequest){//处于转发请求等待期，延迟休眠
			call wakeTimer.startOneShot(WAKE_PERIOD_MILLI);//延迟两个周期休眠，请求等待为160ms，唤醒周期为2个周期
				return;
		}
		//如果节点是数据源，则需要等到数据发送任务完成才能休眠
		//if(TESTFLAG(flags, DATATASK)){
		if(TESTFLAG(flags, DATATASK)||TESTFLAG(flags, FORWARDTASK)){
			//处于数据包产生任务阶段，不休眠
			//call wakeTimer.stop();//但是结束定时器，暗示已经超时
			call wakeTimer.startOneShot(WAKE_PERIOD_MILLI);
			return;
		}
		//普通节点，结束一切任务（如果处在转发态，则判为丢包），进入休眠.注意，数据源节点也能充当普通节点
		/*if(TESTFLAG(flags, FORWARDTASK))
			post endForwardTask();*/

		call RadioControl.stop();
		call sleepTimer.startOneShot(SLEEP_PERIOD_MILLI);

	}

	event void sleepTimer.fired(){//休眠结束，唤醒节点
		call RadioControl.start();
	    call wakeTimer.startOneShot(WAKE_PERIOD_MILLI);
	}

	event void packetTimer.fired() {
		if(!TESTFLAG(flags, FORWARDTASK)){ //若有转发任务则该周期不产生数据
			if(!(call wakeTimer.isRunning())){//如果节点处于休眠状态，立即唤醒
				call sleepTimer.stop();
				signal sleepTimer.fired();
			}
			post sendDataPayload();
		}
	}

	/*数据包转发过程的上游节点触发
	 * 连续发送待转数据包等待结束，判断是否需要继续重复转发
	 */
	event void forwardPacketTimer.fired(){
		if(!call wakeTimer.isRunning())
			call forwardPacketTimer.startOneShot(PACKET_DUPLICATE_MILLI);
		post forward();
	}

	/*数据包转发过程下游节点触发
	 * 数据包带转发等待结束，转发数据包
	 * */
	event void forwardPauseTimer.fired(){
			//此处无需考虑节点是否接到过用于消除竞争的duplicate包。既然定时器触发，说明仲裁已结束，在此时间内无duplicate包
			//updateOCL(lastforwarderid, 1);
			isForwardRequest = FALSE;
			post forward();
	}

	inline uint8_t convertEdc2uint(float edc){
		//根据ORW,取edc为0.0-25.5,step0.1,转成int
		int intedc = 0;
		intedc = (int)(edc*10);
		intedc = (intedc>255) ? 255 : intedc;
		return (uint8_t)intedc;
	}

	inline float resumeEdc(uint8_t intedc){
		return intedc/10.0f;
	}

	inline uint8_t convertLinkQ2uint(float linkq){
		//映射到[0,255]
		int intlinkq = (int)(linkq*255);
		intlinkq = intlinkq > 255 ? 255 : intlinkq;
		intlinkq = intlinkq <= 0 ? 1 : intlinkq;
		return (uint8_t)(intlinkq);
	}

	inline float resumeLinkQ(uint8_t intlinkq){
		return intlinkq/255.0f;
	}

	inline void noACK(){
		shouldAck = FALSE;
	}

	void setVacantAck(message_t* msg){
		tossim_metadata_t* metadata = getPktMetadata(msg);
		if(TOS_NODE_ID == 1){
			metadata->ackNode = 1;
			return;
		}
		metadata->ackNode = 0xFF;
		noACK();
	}

	bool isDataAck(message_t* msg){
    	tossim_header_t* header = getPktHeader(msg);
    	return (header->type == DATAPAYLOAD);
    }

	event void NeighborDiscovery.PrepareAckAddtionalMsg(message_t* msg){
		//接到其它节点发的probe包，需要回ack，准备额外携带的数据
		tossim_metadata_t* metadata = getPktMetadata(msg);
		//若EDC还没初始化，则不做都不做。sink一开始就是初始化的
		if(!TESTFLAG(flags, INITIALIZED))
			return;
		metadata->ackNode = (uint8_t)TOS_NODE_ID;
		metadata->other1 = convertEdc2uint(nodeedc);
		//metadata->other2 = (uint8_t)255;//链路质量q=(0,1],通过*255取整映射到[0-255],即other2=[q*255]，此处probe包的q=1,所以可以不传
	}

	event void NeighborDiscovery.AckAddtionalMsg(message_t* ackMessage){
		//节点收到其它节点回复自己probe包的ack，提取其中额外的数据
		tossim_metadata_t* metadata = getPktMetadata(ackMessage);
		float ackedc =  metadata->other1/10.0f;
		//收到ack后应用层所做的操作
		updateNeighborSet(metadata->ackNode, ackedc, 1.0f);
		SETFLAG(flags, INITIALIZED);
		post startDutyCycle();
	}

	event void ACKs.PrepareAckAddtionalMsg(message_t* msg){
		tossim_metadata_t* metadata = getPktMetadata(msg);
		if(!isDataAck(msg))
			return;
		if(!shouldAck){
			setVacantAck(msg);
			return;
		}
		metadata->ackNode = (uint8_t)TOS_NODE_ID;
		metadata->other1 = convertEdc2uint(nodeedc);
		metadata->other2 = convertLinkQ2uint(getLinkQ(getPktMessageSource(msg)));
		post startForwardRequestPause();
	}

	event void ACKs.AckAddtionalMsg(message_t* ackMessage){
		tossim_metadata_t* metadata = getPktMetadata(ackMessage);
		uint8_t requester = metadata->ackNode;
		float requesterEdc;
		float requesterLinkQ;
		if(!isDataAck(ackMessage))
			return;
		requesterEdc = resumeEdc(metadata->other1);
		requesterLinkQ = resumeLinkQ(metadata->other2);
		dbg("ORWTossimC", "rcv ack from: %d\n",requester);
		if((NULL == requester) || (requester == 0)){
			return;
		}else if (requester == 0xFF){
			vacantAckOffset++;
			return;
		}
		updateNeighborSet(requester, requesterEdc, requesterLinkQ);
		//收到sink回复的ack
		if(requester == 1)
			sinkacked = TRUE;
	}

}
