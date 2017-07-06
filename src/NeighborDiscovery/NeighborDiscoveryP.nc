#include <Timer.h>
#include "TossimRadioMsg.h"
#include "AM.h"
#include "bitArray.h"
#include "NeighborDiscovery.h"

module NeighborDiscoveryP{
	provides interface NeighborDiscovery;
	
	uses interface Timer<TMilli> as packetTimer;
	uses interface Packet as ProbePacket;
	uses interface AMSend as ProbeSender;
	uses interface Receive as ProbeReceiver;
	uses interface PacketAcknowledgements as probeACKs;
	uses interface Packet;
}
implementation{
	
	message_t probepkt;
	bool initialized = FALSE;
	char currentAckedNodeid[BITNSLOTS(MAX_NODE_SIZE)]={0};//在一次probe的send过程中，记录已经回复ack的所有节点
	
	command void NeighborDiscovery.startNeighborDiscover(){
		if(TOS_NODE_ID != 1){
			call packetTimer.startPeriodic(PROBE_PERIOD_MILLI);
		}else{
			initialized = TRUE;
		}
	}
	
	task void sendProbe() {
		//probe为空数据包即可。
		call probeACKs.requestAck(&probepkt);
		call ProbeSender.send(AM_BROADCAST_ADDR, &probepkt, 0);
		dbg("Probe", "%s Probe Send done.\n", sim_time_string());
	}
	
	event void packetTimer.fired() {
		if(!initialized)
			post sendProbe();
		else
			call packetTimer.stop();
	}
	
	event message_t * ProbeReceiver.receive(message_t *msg, void *payload, uint8_t len){
		return msg;
	}

	event void ProbeSender.sendDone(message_t *msg, error_t error){
		//本次send结束，清空暂存的ack节点号记录
		int acknum = call probeACKs.wasAcked(msg);
		dbg("Probe", "Acked # %d.\n", acknum);
		CLEARALLBITS(currentAckedNodeid, MAX_NODE_SIZE);
	}
	
	inline tossim_metadata_t* _getMetadata(message_t* amsg) {
    	return (tossim_metadata_t*)(&amsg->metadata);
	}
	
	inline tossim_header_t* _getHeader(message_t* amsg) {
    	return (tossim_header_t*)(amsg->data - sizeof(tossim_header_t));
    }
    
    /**
	 * 判断该ack的事件触发是否是我们关注的消息类型.
	 *
	 * 在多个数据类型需要ack的使用场景，比如包含邻居探测包和普通数据包两种类型的AM消息使用场景，
	 * 由于ack收发是绑定在radiocontrol的，所以触发事件时，多种数据包的ack事件会被同时触发，
	 * 所以需要利用消息类型（am_id_t，AMSenderC中指定的包类型号）来判断是否是自己类型的包触发的.
	 *
	 * @param msg   AM消息包
	 * @return      是否Probe类型的数据包
	 */
    bool isProbeAck(message_t* msg){
    	tossim_header_t* header = _getHeader(msg);
    	return (header->type == PROBEMSG);
    }
	
	event void probeACKs.PrepareAckAddtionalMsg(message_t* msg){
		tossim_metadata_t* metadata = _getMetadata(msg);
		//若EDC还没初始化，则不做都不做。sink一开始就是初始化的
		if(!initialized)
			return;
		if(!isProbeAck(msg))
			return;
		//发送ack的操作由系统完成
		metadata->ackNode = (uint8_t)TOS_NODE_ID;
		dbg("Probe", "%s Sending ACK.\n",sim_time_string());
		signal NeighborDiscovery.PrepareAckAddtionalMsg(msg);
	}
  
	event void probeACKs.AckAddtionalMsg(message_t* ackMessage){	
		//节点收到自己probe包的ack
		tossim_metadata_t* metadata = _getMetadata(ackMessage);
		if(!isProbeAck(ackMessage))
			return;
		atomic{
		if((NULL == metadata->ackNode) && (metadata->ackNode == 0))
			return;
		if(BITTEST(currentAckedNodeid, (int)metadata->ackNode))//bug: 同时收到同一节点的两个edc,设置currentAckedNodeid解决
			return;
		else
			BITSET(currentAckedNodeid, (int)metadata->ackNode);
		}
		dbg("Probe", "%s Received ACK from %d.\n",sim_time_string(),metadata->ackNode);
		dbg("Probe", "%d Initialized.\n",metadata->ackNode);
		initialized = TRUE;
		call packetTimer.stop();
		signal NeighborDiscovery.AckAddtionalMsg(ackMessage);
	}
}